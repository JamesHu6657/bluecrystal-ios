import Foundation

/// 安全上限（照搬 legacy src/safety/limits.py 的数值，不可配置）
enum SafetyLimits {
    /// 单次连续输出上限（MAX_DURATION_SECONDS = 300）
    static let maxRunSeconds: TimeInterval = 300
    /// 一次运行至少要能跑 1 秒才允许开始（validate_duration 下限 1）
    static let minRunSeconds: TimeInterval = 1
    /// 滚动 30 分钟内最多输出 600 秒（DUTY_CYCLE_WINDOW_SECONDS / DUTY_CYCLE_BUDGET_SECONDS）
    static let dutyWindowSeconds: TimeInterval = 30 * 60
    static let dutyBudgetSeconds: TimeInterval = 600
    /// 每次确认停止后的冷却 = max(60 秒, 本次运行时长 × 0.5)（MIN_COOLDOWN_SECONDS / COOLDOWN_RATIO）
    static let minCooldownSeconds: TimeInterval = 60
    static let cooldownRatio: Double = 0.5
}

/// 滚动窗口占空比账本（移植 legacy src/safety/duty_cycle.py 的 DutyCycleLedger）。
///
/// iOS 的一次"运行"：从停机状态下第一帧输出开始，到停止帧对确认（或用户确认已物理关机）为止。
/// 开始时预留 min(300 秒, 剩余额度) 作为本次上限；结束时按实际时长记账，并开始冷却。
/// 记账条目在结束后保留整整一个窗口（与 legacy 一样偏保守）。
///
/// 不是线程安全的：BLEManager 只在 bleQueue 上用它。
/// 时间用单调时钟 systemUptime（修 L7）；持久化时换成墙钟，重启 App 后换回来（修 M3：杀掉 App 不能清零）。
final class DutyCycleLedger {

    enum Denial: Equatable {
        /// 冷却中，还剩多少秒
        case cooldown(TimeInterval)
        /// 额度不够，还要等多少秒
        case budget(TimeInterval)
        /// 上一次运行还没确认停止
        case openRun
    }

    private struct Entry: Codable {
        var end: TimeInterval
        var charge: TimeInterval
    }

    /// 持久化格式：时间点一律存墙钟秒数
    private struct Snapshot: Codable {
        var completed: [Entry]
        var openStart: TimeInterval?
        var openAllowed: TimeInterval
        var lastEnd: TimeInterval?
        var appliedCooldown: TimeInterval
    }

    private let clock: () -> TimeInterval
    private let wallClock: () -> TimeInterval
    private var completed: [Entry] = []
    /// 进行中运行的开始时间（单调时钟）；nil = 没有进行中的运行
    private(set) var openStart: TimeInterval?
    /// 进行中运行的上限秒数
    private(set) var openAllowed: TimeInterval = 0
    /// 进行中运行是上次进程留下来的：App 不在时设备跑了多久不可知
    private(set) var openOrphaned = false
    private var lastEnd: TimeInterval?
    private(set) var appliedCooldown: TimeInterval = 0

    /// 状态变化回调（BLEManager 用来持久化）
    var onChange: (() -> Void)?

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.clock = clock
        self.wallClock = wallClock
    }

    var hasOpenRun: Bool { openStart != nil }

    /// 冷却剩余秒数（legacy cooldown_remaining_seconds）
    func cooldownRemaining() -> TimeInterval {
        guard let end = lastEnd else { return 0 }
        return max(0, end + appliedCooldown - clock())
    }

    /// 剩余额度，含进行中运行的整段预留（legacy remaining_budget_seconds）
    func remainingBudget() -> TimeInterval {
        prune()
        return max(0, SafetyLimits.dutyBudgetSeconds - usedSeconds())
    }

    /// 能否开始新一次运行；nil = 可以（legacy check_admissible）
    func checkAdmissible() -> Denial? {
        prune()
        let cd = cooldownRemaining()
        if cd > 0 { return .cooldown(cd) }
        if openStart != nil { return .openRun }
        if remainingBudget() < SafetyLimits.minRunSeconds { return .budget(secondsUntilBudget()) }
        return nil
    }

    /// 开始一次运行，返回本次上限秒数；不允许时返回 nil（legacy begin）
    @discardableResult
    func begin() -> TimeInterval? {
        guard checkAdmissible() == nil else { return nil }
        let allowed = min(SafetyLimits.maxRunSeconds, remainingBudget())
        openStart = clock()
        openAllowed = allowed
        openOrphaned = false
        onChange?()
        return allowed
    }

    /// 进行中运行的剩余秒数（到点后为负）；没有运行时为 nil
    func runRemaining() -> TimeInterval? {
        guard let start = openStart else { return nil }
        return openAllowed - (clock() - start)
    }

    /// 结束进行中的运行：按实际时长记账并开始冷却（legacy end）
    func end() {
        guard let start = openStart else { return }
        let now = clock()
        var elapsed = max(0, now - start)
        // 上次进程留下的运行：App 被杀/崩溃期间设备跑了多久不可知，
        // 最多按本次上限记账（App 活着时会在上限处自动停止）
        if openOrphaned { elapsed = min(elapsed, openAllowed) }
        completed.append(Entry(end: now, charge: elapsed))
        openStart = nil
        openAllowed = 0
        openOrphaned = false
        lastEnd = now
        appliedCooldown = max(SafetyLimits.minCooldownSeconds, elapsed * SafetyLimits.cooldownRatio)
        onChange?()
    }

    /// 额度不够时，还要等多久才有至少 minRunSeconds 的额度
    func secondsUntilBudget() -> TimeInterval {
        let now = clock()
        var used = usedSeconds()
        for e in completed.sorted(by: { $0.end < $1.end }) {
            used -= e.charge
            if SafetyLimits.dutyBudgetSeconds - used >= SafetyLimits.minRunSeconds {
                return max(0, e.end + SafetyLimits.dutyWindowSeconds - now)
            }
        }
        return 0
    }

    // MARK: - 持久化

    func snapshotData() -> Data? {
        let now = clock()
        let wall = wallClock()
        func toWall(_ t: TimeInterval) -> TimeInterval { wall - (now - t) }
        let s = Snapshot(
            completed: completed.map { Entry(end: toWall($0.end), charge: $0.charge) },
            openStart: openStart.map(toWall),
            openAllowed: openAllowed,
            lastEnd: lastEnd.map(toWall),
            appliedCooldown: appliedCooldown
        )
        return try? JSONEncoder().encode(s)
    }

    /// 从持久化数据恢复（只在启动时调用一次）
    func restore(from data: Data) {
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let now = clock()
        let wall = wallClock()
        // 墙钟换回单调时钟；墙钟被往回调、看起来在"未来"的时间点按刚刚发生处理（偏保守）
        func toUptime(_ w: TimeInterval) -> TimeInterval { now - max(0, wall - w) }
        func valid(_ v: TimeInterval) -> Bool { v.isFinite && v >= 0 }
        completed = s.completed
            .filter { $0.end.isFinite && valid($0.charge) }
            .map { Entry(end: toUptime($0.end), charge: $0.charge) }
        if let start = s.openStart, start.isFinite, valid(s.openAllowed) {
            openStart = toUptime(start)
            openAllowed = min(s.openAllowed, SafetyLimits.maxRunSeconds)
            openOrphaned = true
        }
        if let end = s.lastEnd, end.isFinite, valid(s.appliedCooldown) {
            lastEnd = toUptime(end)
            appliedCooldown = s.appliedCooldown
        }
        prune()
    }

    // MARK: - 内部

    private func usedSeconds() -> TimeInterval {
        completed.reduce(0.0) { $0 + $1.charge } + (openStart == nil ? 0 : openAllowed)
    }

    /// 丢掉结束时间已经滑出 30 分钟窗口的条目（legacy _prune）
    private func prune() {
        let cutoff = clock() - SafetyLimits.dutyWindowSeconds
        completed.removeAll { $0.end <= cutoff }
    }
}
