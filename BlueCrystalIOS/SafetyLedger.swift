import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum SafetyClock {
    /// 优先使用不随墙钟变化的启动 UUID；旧系统回退到 kern.boottime。
    /// 回退值改变或读不到时，账本走保守恢复，不信任墙钟流逝（F3）。
    static func bootIdentity() -> String? {
        #if canImport(Darwin)
        var bytes = [CChar](repeating: 0, count: 128)
        var size = bytes.count
        let result = bytes.withUnsafeMutableBytes {
            sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &size, nil, 0)
        }
        if result == 0, size > 1, size <= bytes.count {
            bytes[bytes.count - 1] = 0
            let uuid = String(cString: bytes)
            if !uuid.isEmpty { return "uuid:\(uuid)" }
        }
        var boot = timeval()
        size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            return "time:\(boot.tv_sec):\(boot.tv_usec)"
        }
        #endif
        return nil
    }
}

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
/// 时间用 systemUptime；持久化墙钟 + 单调锚点 + 启动标识，跨进程也不依赖可变墙钟（F3）。
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

    /// 时间点保留旧版墙钟格式，新增可选锚点以兼容旧账本。
    private struct Snapshot: Codable {
        var completed: [Entry]
        var openStart: TimeInterval?
        var openAllowed: TimeInterval
        var lastEnd: TimeInterval?
        var appliedCooldown: TimeInterval
        var savedWall: TimeInterval?
        var savedUptime: TimeInterval?
        var bootIdentity: String?
    }

    private let clock: () -> TimeInterval
    private let wallClock: () -> TimeInterval
    private let bootIdentity: () -> String?
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
         wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         bootIdentity: @escaping () -> String? = { SafetyClock.bootIdentity() }) {
        self.clock = clock
        self.wallClock = wallClock
        self.bootIdentity = bootIdentity
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
        // 进程不在时无法执行 300s 截止停机；直到确认/物理确认停止都按实际推断时长记账（F2）。
        let elapsed = max(0, now - start)
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
            appliedCooldown: appliedCooldown,
            savedWall: wall,
            savedUptime: now,
            bootIdentity: bootIdentity()
        )
        return try? JSONEncoder().encode(s)
    }

    /// 从持久化数据恢复（只在启动时调用一次）
    func restore(from data: Data) {
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let now = clock()
        let wall = wallClock()
        let currentBoot = bootIdentity()
        // 同一次启动只用快照中的墙钟/uptime 对应关系，完全忽略当前墙钟跳变。
        var anchor: (wall: TimeInterval, uptime: TimeInterval)?
        if let savedWall = s.savedWall, savedWall.isFinite,
           let savedUptime = s.savedUptime, savedUptime.isFinite, savedUptime >= 0,
           let savedBoot = s.bootIdentity, !savedBoot.isEmpty,
           savedBoot == currentBoot, now >= savedUptime {
            anchor = (savedWall, savedUptime)
        }
        func toUptime(_ w: TimeInterval) -> TimeInterval {
            if let a = anchor { return a.uptime - (a.wall - w) }
            // 启动标识不明/重启/uptime 倒退：不能让前拨墙钟清掉记账或冷却。
            return now
        }
        func valid(_ v: TimeInterval) -> Bool { v.isFinite && v >= 0 }
        completed = s.completed
            .filter { $0.end.isFinite && valid($0.charge) }
            .map { Entry(end: toUptime($0.end), charge: $0.charge) }
        if let start = s.openStart, start.isFinite, valid(s.openAllowed) {
            if anchor != nil {
                openStart = toUptime(start)
            } else {
                let knownElapsed = s.savedWall.map { max(0, $0 - start) } ?? 0
                let bootChanged = s.bootIdentity != nil && currentBoot != nil && s.bootIdentity != currentBoot
                let uptimeReset = s.savedUptime.map { now < $0 } ?? false
                // 跨设备重启时，当前启动以来的 uptime 也属于尚未确认停止的区间。
                let inferredElapsed = knownElapsed + ((bootChanged || uptimeReset) ? now : 0)
                // 时钟不可靠时，至少计入预留上限；future openStart 绝不按零秒结束。
                let elapsed = max(SafetyLimits.maxRunSeconds,
                                  max(inferredElapsed, max(0, wall - start)))
                openStart = now - elapsed
            }
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
