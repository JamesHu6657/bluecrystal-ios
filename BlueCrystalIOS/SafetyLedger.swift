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

    /// 安全计时用的单调时钟（秒，自本次开机起）：手机睡眠期间继续走（Darwin CLOCK_MONOTONIC = mach_continuous_time）。
    /// 第二轮审查 M3：之前用 systemUptime，它在睡眠时停走。锁屏睡着、设备却可能还在输出（停止没确认 / 断链 / 进程被杀
    /// 后同一次开机内重启）时，运行时长少算，确认停止后的冷却和记账跟着变少
    static func continuousSeconds() -> TimeInterval {
        #if canImport(Darwin)
        return TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }

    /// 快照里记录的时钟种类：时间轴不同的旧快照（systemUptime）不能拿来对齐锚点
    static let continuousClockKind = "continuous"
}

/// 安全上限（结构沿用 legacy src/safety/limits.py；1.7.4 起按用户要求把单次上限调到 20 分钟，不可在 App 内配置）
enum SafetyLimits {
    /// 单次连续输出上限：20 分钟（legacy 原值 300 秒）
    static let maxRunSeconds: TimeInterval = 20 * 60
    /// 一次运行至少要能跑 1 秒才允许开始（validate_duration 下限 1）
    static let minRunSeconds: TimeInterval = 1
    /// 滚动 30 分钟内最多输出 1200 秒（与单次上限相同，保证能跑满一次 20 分钟；legacy 原值 600 秒）
    static let dutyWindowSeconds: TimeInterval = 30 * 60
    static let dutyBudgetSeconds: TimeInterval = 20 * 60
    /// 每次确认停止后的冷却 = max(60 秒, 本次运行时长 × 0.5)（MIN_COOLDOWN_SECONDS / COOLDOWN_RATIO）
    static let minCooldownSeconds: TimeInterval = 60
    static let cooldownRatio: Double = 0.5
    /// 未知时长恢复：耗尽完整窗口额度，冷却按全部 1200 秒额度计算；也是任何一次冷却的上限（M1）。
    static let unknownElapsedCooldownSeconds = dutyBudgetSeconds * cooldownRatio
    static let checkpointIntervalSeconds: TimeInterval = 5
}

/// 滚动窗口占空比账本（移植 legacy src/safety/duty_cycle.py 的 DutyCycleLedger）。
///
/// iOS 的一次"运行"：从停机状态下第一帧输出开始，到停止帧对确认（或用户确认已物理关机）为止。
/// 开始时预留 min(1200 秒, 剩余额度) 作为本次上限；结束时按实际时长记账，并开始冷却。
/// 记账条目在结束后保留整整一个窗口（与 legacy 一样偏保守）。
///
/// 不是线程安全的：BLEManager 只在 bleQueue 上用它。
/// 时间用 SafetyClock.continuousSeconds（睡眠期间也走，第二轮审查 M3）；持久化墙钟 + 单调锚点 + 启动标识 + 时钟种类，
/// 跨进程也不依赖可变墙钟（F3）。字段名里的 uptime 沿用旧名，指的就是这个单调时钟
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
        var openElapsedUnknown: Bool?
        var openElapsedLowerBound: TimeInterval?
        /// savedUptime 所在的时钟（M3）；没有 = 旧版 systemUptime 时间轴，不拿来对齐
        var clockKind: String?
    }

    private let clock: () -> TimeInterval
    private let wallClock: () -> TimeInterval
    private let bootIdentity: () -> String?
    private let clockKind: String
    private var completed: [Entry] = []
    /// 进行中运行的开始时间（单调时钟）；nil = 没有进行中的运行
    private(set) var openStart: TimeInterval?
    /// 进行中运行的上限秒数
    private(set) var openAllowed: TimeInterval = 0
    /// 进行中运行是上次进程留下来的：App 不在时设备跑了多久不可知
    private(set) var openOrphaned = false
    /// true 时 openStart 只表示已验证时长的下界，绝不当成完整运行时长。
    private(set) var openElapsedUnknown = false
    private var lastCheckpointUptime: TimeInterval?
    private var lastEnd: TimeInterval?
    private(set) var appliedCooldown: TimeInterval = 0

    /// 状态变化回调（BLEManager 用来持久化）
    var onChange: (() -> Void)?

    init(clock: @escaping () -> TimeInterval = { SafetyClock.continuousSeconds() },
         wallClock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         bootIdentity: @escaping () -> String? = { SafetyClock.bootIdentity() },
         clockKind: String = SafetyClock.continuousClockKind) {
        self.clock = clock
        self.wallClock = wallClock
        self.bootIdentity = bootIdentity
        self.clockKind = clockKind
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
        let now = clock()
        openStart = now
        openAllowed = allowed
        openOrphaned = false
        openElapsedUnknown = false
        lastCheckpointUptime = now
        onChange?()
        return allowed
    }

    /// 进行中运行的剩余秒数（到点后为负）；没有运行时为 nil
    func runRemaining() -> TimeInterval? {
        guard let start = openStart else { return nil }
        if openElapsedUnknown { return 0 }
        return openAllowed - (clock() - start)
    }

    /// bleQueue 看门狗调用；断链/停止重试时仍保存已验证的单调时长下界。
    func checkpoint() {
        guard hasOpenRun else { return }
        let now = clock()
        if let last = lastCheckpointUptime, now - last < SafetyLimits.checkpointIntervalSeconds { return }
        lastCheckpointUptime = now
        onChange?()
    }

    /// 确认停止后记账/冷却；未知时长至少耗尽完整窗口额度，已验证下界更长则保留。
    /// 冷却最多 unknownElapsedCooldownSeconds（M1）：正常运行不超过 1200 秒，冷却本来就 ≤600 秒；
    /// 超过的只会是恢复出来的 / 未知的 / 断链期间的时长，被杀 10 小时后再确认停止不能因此锁 5 小时。
    /// 额度照实际推断时长保守记账，不封顶
    func end() {
        guard let start = openStart else { return }
        let now = clock()
        // 进程不在时无法执行单次上限截止停机；直到确认/物理确认停止都按实际推断时长记账（F2）。
        let elapsed = max(0, now - start)
        let charge = openElapsedUnknown ? max(SafetyLimits.dutyBudgetSeconds, elapsed) : elapsed
        completed.append(Entry(end: now, charge: charge))
        let cooldown = openElapsedUnknown
            ? SafetyLimits.unknownElapsedCooldownSeconds
            : min(SafetyLimits.unknownElapsedCooldownSeconds,
                  max(SafetyLimits.minCooldownSeconds, elapsed * SafetyLimits.cooldownRatio))
        openStart = nil
        openAllowed = 0
        openOrphaned = false
        openElapsedUnknown = false
        lastCheckpointUptime = nil
        lastEnd = now
        appliedCooldown = cooldown
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
            bootIdentity: bootIdentity(),
            openElapsedUnknown: openElapsedUnknown,
            openElapsedLowerBound: openStart.map { max(0, now - $0) },
            clockKind: clockKind
        )
        return try? JSONEncoder().encode(s)
    }

    /// 从持久化数据恢复（只在启动时调用一次）
    func restore(from data: Data) {
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let now = clock()
        let currentBoot = bootIdentity()
        // 同一次启动只用快照中的墙钟/uptime 对应关系，完全忽略当前墙钟跳变。
        // M3：锚点还必须是同一种时钟；旧版 systemUptime 时间轴的快照走保守恢复
        var anchor: (wall: TimeInterval, uptime: TimeInterval)?
        if let savedWall = s.savedWall, savedWall.isFinite,
           let savedUptime = s.savedUptime, savedUptime.isFinite, savedUptime >= 0,
           let savedBoot = s.bootIdentity, !savedBoot.isEmpty,
           savedBoot == currentBoot, now >= savedUptime,
           s.clockKind == clockKind {
            anchor = (savedWall, savedUptime)
        }
        func toUptime(_ w: TimeInterval) -> TimeInterval {
            if let a = anchor { return a.uptime - (a.wall - w) }
            // 启动标识不明/重启/uptime 倒退/换了时钟：不能让前拨墙钟清掉记账或冷却。
            return now
        }
        func valid(_ v: TimeInterval) -> Bool { v.isFinite && v >= 0 }
        completed = s.completed
            .filter { $0.end.isFinite && valid($0.charge) }
            .map { Entry(end: toUptime($0.end), charge: $0.charge) }
        if let start = s.openStart {
            let anchoredStart = toUptime(start)
            if anchor != nil, start.isFinite, anchoredStart.isFinite,
               let savedUptime = s.savedUptime, anchoredStart <= savedUptime,
               valid(s.openAllowed) {
                openStart = toUptime(start)
                // 重新保存锚点不能把未知状态洗成已知时长。
                openElapsedUnknown = s.openElapsedUnknown ?? false
            } else {
                var knownElapsed: TimeInterval = 0
                if let lowerBound = s.openElapsedLowerBound, valid(lowerBound) {
                    knownElapsed = lowerBound
                }
                // 兼容旧快照：只有保存时墙钟/uptime 对应关系完整才验证快照前时长。
                if start.isFinite, let savedWall = s.savedWall, savedWall.isFinite,
                   let savedUptime = s.savedUptime, valid(savedUptime) {
                    let savedElapsed = savedWall - start
                    if valid(savedElapsed) { knownElapsed = max(knownElapsed, savedElapsed) }
                }
                let bootChanged = s.bootIdentity != nil && currentBoot != nil && s.bootIdentity != currentBoot
                let uptimeReset = s.savedUptime.map { now < $0 } ?? false
                // 跨设备重启时，当前启动以来的 uptime 也属于尚未确认停止的区间。
                let lowerBound = knownElapsed + ((bootChanged || uptimeReset) ? now : 0)
                openStart = now - lowerBound
                openElapsedUnknown = true
            }
            openAllowed = valid(s.openAllowed) ? min(s.openAllowed, SafetyLimits.maxRunSeconds) : 0
            openOrphaned = true
            lastCheckpointUptime = now
        }
        if let end = s.lastEnd, end.isFinite, valid(s.appliedCooldown) {
            lastEnd = toUptime(end)
            appliedCooldown = min(s.appliedCooldown, SafetyLimits.unknownElapsedCooldownSeconds)
        }
        prune()
    }

    // MARK: - 内部

    private func usedSeconds() -> TimeInterval {
        let reservation = openElapsedUnknown ? SafetyLimits.dutyBudgetSeconds : openAllowed
        return completed.reduce(0.0) { $0 + $1.charge } + (openStart == nil ? 0 : reservation)
    }

    /// 丢掉结束时间已经滑出 30 分钟窗口的条目（legacy _prune）
    private func prune() {
        let cutoff = clock() - SafetyLimits.dutyWindowSeconds
        completed.removeAll { $0.end <= cutoff }
    }
}
