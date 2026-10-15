import Foundation

/// 自然结束必须到达实际终点；靠近末尾的外部暂停不能算播完。
enum PlaybackCompletion {
    static func reachedEnd(position: Double, duration: Double) -> Bool {
        position.isFinite && duration.isFinite && duration > 0 && position >= duration
    }
}

/// 拖动时只更新预览，松手才交给播放器；旁白的离散调整没有拖动回调，直接 seek。
struct PlaybackScrubber {
    private(set) var isEditing = false
    private(set) var position: Double?

    mutating func begin(at current: Double) {
        isEditing = true
        position = current
    }

    mutating func update(to seconds: Double) -> Double? {
        guard isEditing else { return seconds }
        position = seconds
        return nil
    }

    mutating func end() -> Double? {
        let target = position
        cancel()
        return target
    }

    mutating func cancel() {
        isEditing = false
        position = nil
    }
}

/// seek / seek 后缓冲期间设备保持 0，等播放头真正前进才恢复采样和 1.5 秒卡住检测。
struct PlaybackProgressWatch {
    static let stallLimit: TimeInterval = 1.5
    /// 等待落点前进时，一次采样（约 0.3 秒，最快 2 倍速）里正常播放最多前进这么多秒；
    /// 往回走或跳得更远都算又一次跳转，不算恢复
    static let maxResumeStep: Double = 1.0
    enum Observation { case moving, waitingAfterSeek, stalled, paused }
    private var position: Double = .nan
    private var progressedAt: TimeInterval = 0
    private(set) var awaitingSeekProgress = false

    mutating func reset(now: TimeInterval) {
        position = .nan
        progressedAt = now
        awaitingSeekProgress = false
    }

    /// 暂停中完成的 seek 也保留落点；点播放不能把第一次静止采样误认成前进。
    mutating func startPlayback(at seconds: Double, now: TimeInterval) {
        if awaitingSeekProgress {
            // 等待中被外部暂停前可能已走过几帧；再次播放须从这次的停点重新等前进。
            if seconds.isFinite { position = seconds }
            progressedAt = now
        } else {
            reset(now: now)
        }
    }

    mutating func awaitSeekProgress(from seconds: Double, now: TimeInterval) {
        reset(now: now)
        position = seconds
        awaitingSeekProgress = true
    }

    mutating func observe(at seconds: Double, now: TimeInterval, isPaused: Bool = false) -> Observation {
        // 外部暂停优先于位置变化和 seek 等待；绝不因暂停前走过几帧就恢复输出。
        if isPaused { return .paused }
        if seconds.isFinite, position.isNaN || abs(seconds - position) > 0.01 {
            let delta = seconds - position
            if awaitingSeekProgress, !position.isNaN, !(delta > 0 && delta <= Self.maxResumeStep) {
                // 等待期间又跳了（系统进度条连续拖动、再次快进 / 快退）或往回走：不是正常播放，
                // 记下新落点继续等
                position = seconds
                progressedAt = now
                return .waitingAfterSeek
            }
            position = seconds
            progressedAt = now
            awaitingSeekProgress = false
            return .moving
        }
        if awaitingSeekProgress { return .waitingAfterSeek }
        return now - progressedAt > Self.stallLimit ? .stalled : .moving
    }
}

/// 最低强度只在"声音真的在流过 tap"时生效。tap 装好（.ready）不代表有样本：
/// 开播首拍、缓冲、AirPlay 时窗口是空的，这时不加最低强度（没有信号就是 0）
struct AudioFlowWatch {
    /// 最近一次有样本的窗口离现在不超过这么久才算在流（约两拍，容一拍抖动）
    static let freshSeconds: TimeInterval = 0.7
    private(set) var lastFramesAt: TimeInterval?

    /// 开播 / seek / 跳转：之前的样本不作数
    mutating func reset() { lastFramesAt = nil }

    mutating func note(_ w: AudioWindow, now: TimeInterval) {
        if w.frames > 0, now.isFinite { lastFramesAt = now }
    }

    func isFlowing(now: TimeInterval) -> Bool {
        guard let t = lastFramesAt, now.isFinite else { return false }
        let age = now - t
        return age >= 0 && age < Self.freshSeconds
    }

    /// tap 就绪、播放器确实在播（不是缓冲）、样本是新鲜的：三者都满足才允许最低强度
    func allowsFloor(tapReady: Bool, playerPlaying: Bool, now: TimeInterval) -> Bool {
        tapReady && playerPlaying && isFlowing(now: now)
    }
}

/// 系统播放器控件开播的判定：只在"暂停 → 非暂停"的那一下接管（缓冲 / 跳转引起的
/// 等待 ↔ 播放来回不算开播）。用户停止 / 被动停机后锁存一次：拖动进度条时停止、
/// 松手后系统按拖动前的速率续播，这一下不能把输出复活，先拦下并说明
struct ExternalPlayGate {
    enum Decision: Equatable {
        /// 不是开播边沿
        case ignore
        /// 按用户点了播放处理（仍要过设备 / 安全 / 隐私检查）
        case takeOver
        /// 停止后的第一次外部开播：把视频停住，要求再点一次
        case rejectAfterStop
    }

    private var wasPaused = true
    private(set) var stopLatched = false

    mutating func latchStop() { stopLatched = true }
    mutating func clearLatch() { stopLatched = false }

    /// paused：播放器现在是不是停着（KVO 值为暂停或实际 rate 为 0）
    mutating func observe(paused: Bool) -> Decision {
        if paused {
            wasPaused = true
            return .ignore
        }
        guard wasPaused else { return .ignore }
        wasPaused = false
        if stopLatched {
            stopLatched = false
            return .rejectAfterStop
        }
        return .takeOver
    }
}

/// App 自己 seek 也会发 timeJumped；通知和 seek 完成回调各自切回主线程，先后不定。
/// 完成回调记下落点，紧随其后、落在落点附近的那一条通知当作回声忽略（只消费一次）
struct OwnSeekEcho {
    static let window: TimeInterval = 0.5
    static let tolerance: Double = 0.05
    /// 回声晚到时播放头可能已经走了一点（最快 2 倍速）
    static let maxRate: Double = 2

    private var landed: Double = .nan
    private var at: TimeInterval = -.infinity

    mutating func record(landed seconds: Double, now: TimeInterval) {
        landed = seconds
        at = now
    }

    mutating func clear() {
        landed = .nan
        at = -.infinity
    }

    mutating func consumeIfEcho(position: Double, now: TimeInterval) -> Bool {
        let elapsed = now - at
        guard landed.isFinite, position.isFinite, elapsed.isFinite,
              elapsed >= 0, elapsed < Self.window else { return false }
        let echo = position >= landed - Self.tolerance
            && position <= landed + Self.tolerance + elapsed * Self.maxRate
        if echo { clear() }
        return echo
    }
}

/// 时间轴脚本的合理范围（第四轮）：宁可整份拒绝，也不按坏数据输出、不把界面卡死。
/// 强度本来就在 officialScriptLevel 里夹到 0~99，这里只管时间和规模
enum TimelineLimits {
    /// 脚本文件最大字节数（读文件前先查，超了不读）
    static let maxFileBytes = 10 * 1024 * 1024
    /// 最多命令数：每次采样都要扫一遍命令，这个量级在手机上仍是毫秒级
    static let maxCommands = 50_000
    /// 开始时间 / 时长 / 结束时间都不能超过 24 小时
    static let maxSeconds: Double = 24 * 3600
}

/// 脚本内容不合理：界面直接显示 message
struct TimelineScriptError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// 时间轴脚本里的一条命令（字段对应官方 video.js 的 commandType / intensity / duration）
struct TimelineCommand: Decodable {
    /// Thrust / Vibration / Suction / Rotation（大小写不敏感）
    let commandType: String
    let startTimeSeconds: Double
    let durationSeconds: Double
    /// 原始强度：官方格式是 0~10 十档，也可能是 0~100 百分制
    let intensityLevel: Double

    var channel: BCProtocol.Channel? {
        BCProtocol.Channel.from(commandType: commandType)
    }

    var endTime: Double { startTimeSeconds + durationSeconds }

    /// 连续播放的整个采样间隔都要覆盖；显式 seek 用 previous=nil 重置（L11）。
    func isCovered(at time: Double, previous: Double?, fromPlaybackStart: Bool = false) -> Bool {
        let activeNow = time >= startTimeSeconds && time < endTime
        let crossed = previous.map {
            $0 < time && durationSeconds > 0 && endTime <= time &&
                (startTimeSeconds > $0 || (fromPlaybackStart && endTime > $0))
        } ?? false
        return activeNow || crossed
    }
}

/// 时间轴脚本文件
struct TimelineScript: Decodable {
    let commands: [TimelineCommand]
    /// 强度刻度声明，"ten"（0~10，官方格式）或 "percent"（0~100）。
    /// 修 L9：不写时只有出现 >10 的值才能确定是百分制；全部 ≤10 时分不清
    /// （3/5/8 可能是十档，也可能是很小的百分比），按较弱的百分制处理并提示
    let intensityScale: String?

    /// 缓存的刻度判断结果，避免每 tick O(n)（修 N10）
    let useTenScale: Bool
    /// intensityScale 写了但不是 "ten"/"percent"
    let scaleFallback: Bool
    /// 没有可用的刻度声明且所有值都 ≤10：已按较弱的百分制处理（修 L9）
    let scaleAmbiguous: Bool

    enum CodingKeys: String, CodingKey {
        case commands
        case intensityScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commands = try c.decode([TimelineCommand].self, forKey: .commands)
        // 第四轮：时间和规模不合理的脚本整份拒绝（负的开始时间 + 超长时长会从第 0 秒一直覆盖到结束）
        if let why = Self.validationError(commands) { throw TimelineScriptError(message: why) }
        intensityScale = try c.decodeIfPresent(String.self, forKey: .intensityScale)
        let declared = intensityScale?.lowercased()
        if declared == "ten" {
            useTenScale = true
            scaleFallback = false
            scaleAmbiguous = false
        } else if declared == "percent" {
            useTenScale = false
            scaleFallback = false
            scaleAmbiguous = false
        } else {
            // 没写或写错：只认百分制（任一值 >10 时确定是百分制，否则是较弱的那种读法）
            useTenScale = false
            scaleFallback = declared != nil
            scaleAmbiguous = commands.allSatisfy { $0.intensityLevel <= 10 }
        }
    }

    /// 第四轮：脚本不合理的原因（第一处）；nil 表示可以用
    static func validationError(_ commands: [TimelineCommand]) -> String? {
        if commands.count > TimelineLimits.maxCommands {
            return "脚本命令太多（\(commands.count) 条，最多 \(TimelineLimits.maxCommands) 条）"
        }
        let maxSeconds = TimelineLimits.maxSeconds
        let hours = Int(maxSeconds / 3600)
        for (i, cmd) in commands.enumerated() {
            let n = i + 1
            let start = cmd.startTimeSeconds
            let duration = cmd.durationSeconds
            guard start.isFinite, start >= 0, start <= maxSeconds else {
                return "第 \(n) 条命令的开始时间不对（要在 0 秒到 \(hours) 小时之间）"
            }
            guard duration.isFinite, duration >= 0, duration <= maxSeconds else {
                return "第 \(n) 条命令的时长不对（要在 0 秒到 \(hours) 小时之间）"
            }
            guard cmd.endTime <= maxSeconds else {
                return "第 \(n) 条命令的结束时间超过 \(hours) 小时"
            }
            guard cmd.intensityLevel.isFinite else {
                return "第 \(n) 条命令的强度不是有效数字"
            }
        }
        return nil
    }

    /// 命令强度换算成 0x08 帧强度 0~99（修 N2），照官方 video.js executeIntensityCommand：
    /// 十档值 × 10（百分制直接用）→ 取整 → 非零 +10 → 最高 99
    func deviceLevel(for cmd: TimelineCommand) -> Int {
        guard cmd.channel?.isUsed == true else { return 0 }
        let raw = cmd.intensityLevel
        let status = useTenScale ? raw * 10 : raw
        return BCProtocol.officialScriptLevel(status: status)
    }

    /// 普通采样和自然结束共用覆盖逻辑；seek 的 previous=nil 不覆盖跳过区间。
    func levels(at time: Double, previous: Double?, fromPlaybackStart: Bool = false) -> [Int] {
        var vals = [0, 0, 0, 0]
        for cmd in commands {
            guard let ch = cmd.channel, ch.isUsed,
                  cmd.isCovered(at: time, previous: previous, fromPlaybackStart: fromPlaybackStart) else { continue }
            vals[ch.rawValue] = max(vals[ch.rawValue], deviceLevel(for: cmd))
        }
        return vals
    }

    /// 未使用或无法识别的通道只兼容加载，不参与输出。
    var ignoredChannelCount: Int {
        commands.filter { $0.channel?.isUsed != true }.count
    }

    var ignoredOnlyNote: String? {
        !commands.isEmpty && ignoredChannelCount == commands.count
            ? "脚本只有未使用通道，设备不会输出" : nil
    }

    var scaleDescription: String {
        useTenScale ? "十档（0~10）" : "百分（0~100）"
    }
}

/// 播放中的激活命令集合（用于判断是否需要重发）
struct ActiveChannels: Equatable {
    var values: [Int] // [ch0, ch1, ch2, ch3]，0x08 帧强度 0~99（ch2 / ch3 恒为 0）

    static var zero: ActiveChannels { ActiveChannels(values: [0, 0, 0, 0]) }

    static func == (lhs: ActiveChannels, rhs: ActiveChannels) -> Bool {
        lhs.values == rhs.values
    }
}

// MARK: - 我的收藏（手感页）：纯数据和换算，ProtocolChecks 覆盖。
// 只是"记住滑杆位置"：召回时走手动页同一条发送路径（ManualControlVM → BLEManager.send / sendThrottled），
// 准入、额度、看门狗、单次上限一个不少；这里只负责把存下来的值夹回各自模式的范围。

/// 一条收藏：控制方式（变频 / 手动）+ 两个通道的强度，存储数组仍保留四个位置。
struct FavoriteSetting: Codable, Identifiable, Equatable {
    static let maxCount = 8
    static let maxNameLength = 12
    /// 打字过程中的草稿上限：远超 12 字成品名的任何输入法组合长度（拼音还没上屏时不回写不同长度的字符串，
    /// 组合不会被截断打断）；真正的字数限制在 finalizeNames 里收（完成 / 切走 / 下次启动）
    static let maxDraftLength = 200
    /// 自动起的名字（按顺序取第一个没用过的）
    static let suggestedNames = ["微醺", "心动", "缠绵", "悸动", "沉溺", "迷离", "余温", "失控边缘"]

    var id: UUID
    var name: String
    /// BCProtocol.Mode.rawValue；技能预设本来就是一键，不收藏
    var modeRaw: Int
    var levels: [Int]

    /// 只认变频 / 手动；技能或无法识别的值为 nil（这条收藏不能用）
    var mode: BCProtocol.Mode? {
        guard let m = BCProtocol.Mode(rawValue: modeRaw), m != .skill else { return nil }
        return m
    }

    /// 召回用的强度：补齐 4 个通道、夹到该模式的 0~maxLevel、未使用通道恒 0；
    /// 模式无效或全为 0 时为 nil（全零收藏没有意义，也不会被存下来）
    var clampedLevels: [Int]? {
        guard let m = mode else { return nil }
        let out = Self.clamp(levels, maxLevel: m.maxLevel)
        return out.contains(where: { $0 > 0 }) ? out : nil
    }

    static func clamp(_ levels: [Int], maxLevel: Int) -> [Int] {
        (0..<4).map { (i: Int) -> Int in
            guard BCProtocol.Channel(rawValue: i)?.isUsed == true, i < levels.count else { return 0 }
            return min(maxLevel, max(0, levels[i]))
        }
    }

    /// 名字：去掉首尾空白和换行，最多 maxNameLength 个字；空的用 fallback
    static func sanitizedName(_ raw: String, fallback: String) -> String {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(maxNameLength))
    }

    /// 下一个自动名字：建议名都用过了就"我的手感 N"
    static func nextName(existing: [String]) -> String {
        if let n = suggestedNames.first(where: { !existing.contains($0) }) { return n }
        var i = existing.count + 1
        while existing.contains("我的手感 \(i)") { i += 1 }
        return "我的手感 \(i)"
    }

    /// 新建：技能模式或全零时为 nil
    static func make(name: String, mode: BCProtocol.Mode, levels: [Int]) -> FavoriteSetting? {
        guard mode != .skill else { return nil }
        let clamped = clamp(levels, maxLevel: mode.maxLevel)
        guard clamped.contains(where: { $0 > 0 }) else { return nil }
        return FavoriteSetting(id: UUID(), name: name, modeRaw: mode.rawValue, levels: clamped)
    }

    /// 同一模式、同样的强度算重复
    func sameSetting(as other: FavoriteSetting) -> Bool {
        modeRaw == other.modeRaw && clampedLevels == other.clampedLevels
    }
}

enum FavoriteCodec {
    /// 逐条解码用的外壳：解不出来的那一条变成 nil，不连累整个数组
    private struct Lossy: Decodable {
        let value: FavoriteSetting?
        init(from decoder: Decoder) throws {
            value = try? FavoriteSetting(from: decoder)
        }
    }

    struct Decoded: Equatable {
        /// 读出来的有效收藏（最多 maxCount 条）
        var items: [FavoriteSetting]
        /// 读不出来的记录数（整体不是数组时算 1）；技能 / 全零 / 未知模式这类有意丢掉的不算
        var unreadable: Int
    }

    /// 第四轮：逐条解码。一条坏记录（字段缺失 / 类型不对 / 以后的新格式）只丢那一条，其余照常保留
    /// （之前整个数组一起解，一条坏了全部收藏都没了）。无效条目（技能 / 全零 / 未知模式）丢掉，最多 maxCount 条
    static func decodeReport(_ data: Data?) -> Decoded {
        guard let d = data else { return Decoded(items: [], unreadable: 0) }
        guard let rows = try? JSONDecoder().decode([Lossy].self, from: d) else {
            return Decoded(items: [], unreadable: 1)
        }
        let read = rows.compactMap { $0.value }
        let valid = read.compactMap { item -> FavoriteSetting? in
            guard let levels = item.clampedLevels else { return nil }
            var clean = item
            clean.levels = levels
            return clean
        }
        return Decoded(items: Array(valid.prefix(FavoriteSetting.maxCount)), unreadable: rows.count - read.count)
    }

    /// 解不出来就当没有；见 decodeReport
    static func decode(_ data: Data?) -> [FavoriteSetting] {
        decodeReport(data).items
    }

    static func encode(_ items: [FavoriteSetting]) -> Data? {
        try? JSONEncoder().encode(Array(items.prefix(FavoriteSetting.maxCount)))
    }
}

/// 撤销删除时放回的位置（第四轮，ProtocolChecks / Round4Checks 覆盖）。
/// 之前只记了原下标：连续删 B、A 后先撤销 B 会插到 C 后面，全部撤销得到 [A, C, B]。
/// 现在按删除那一刻的顺序快照放：放在快照里排在它前面、现在还在的最后一条之后；前面的都不在了就放最前。
/// 快照里没有它（旧数据）时退回原下标，夹到范围内
enum FavoriteRestore {
    static func insertionIndex(of id: UUID, order: [UUID], current: [UUID], fallback: Int) -> Int {
        guard let pos = order.firstIndex(of: id) else { return min(max(0, fallback), current.count) }
        for pred in order[..<pos].reversed() {
            if let i = current.firstIndex(of: pred) { return i + 1 }
        }
        return 0
    }
}

/// 召回收藏时的"缓缓推上去"：升高的通道分几步爬到目标，降低的通道第一步就到位（降低永远立即生效）。
/// 只算每一步的值；发送由 ManualControlVM 做：第一步是用户这次点按（send，开闸），
/// 后面的步骤走 sendThrottled（不开闸）：中途有任何停止（用户 / 看门狗 / 上限 / 断开），后面的步骤都会被丢掉。
/// 用时跟着升幅走：小幅调整约 0.75 秒，从 0 推到满档约 3 秒（一下点到满强度也不会"猛地一下"）
enum FavoriteGlide {
    /// 最少步数：(6 - 1) × 0.15 = 0.75 秒
    static let minSteps = 6
    /// 最多步数：(21 - 1) × 0.15 = 3 秒（升幅等于整个量程时）
    static let maxSteps = 21
    static let stepInterval: TimeInterval = 0.15

    /// 按最大升幅占量程的比例决定步数（只升不降、或不变时取 minSteps）
    static func stepCount(from: [Int], to: [Int], maxLevel: Int) -> Int {
        let rises: [Int] = (0..<4).map { (i: Int) -> Int in
            guard BCProtocol.Channel(rawValue: i)?.isUsed == true else { return 0 }
            let a: Int = i < from.count ? max(0, from[i]) : 0
            let b: Int = i < to.count ? max(0, to[i]) : 0
            return max(0, b - a)
        }
        let maxRise: Int = rises.max() ?? 0
        guard maxLevel > 0, maxRise > 0 else { return minSteps }
        let fraction: Double = min(1.0, Double(maxRise) / Double(maxLevel))
        let extraSpan: Double = Double(maxSteps - minSteps)
        let extra: Int = Int((extraSpan * fraction).rounded(.up))
        return min(maxSteps, minSteps + extra)
    }

    /// 按该模式量程自动定步数的缓推
    static func plan(from: [Int], to: [Int], maxLevel: Int) -> [[Int]] {
        plan(from: from, to: to, steps: stepCount(from: from, to: to, maxLevel: maxLevel))
    }

    /// 从 from 到 to 的每个计时步骤（不含起点，最后一步恰好是 to；重复值也保留等待时间）。
    /// 没有升高时只有一步（降低立即生效，或重新发一次目标值）
    static func plan(from: [Int], to: [Int], steps: Int) -> [[Int]] {
        let n = max(1, steps)
        let start = (0..<4).map { BCProtocol.Channel(rawValue: $0)?.isUsed == true && $0 < from.count ? max(0, from[$0]) : 0 }
        let target = (0..<4).map { BCProtocol.Channel(rawValue: $0)?.isUsed == true && $0 < to.count ? max(0, to[$0]) : 0 }
        guard (0..<4).contains(where: { target[$0] > start[$0] }) else { return [target] }
        var out: [[Int]] = []
        for k in 1...n {
            let step = (0..<4).map { (i: Int) -> Int in
                let a = start[i]
                let b = target[i]
                guard b > a else { return b }
                // 第一档至少 +1，避免全零停止帧；之后向下取整，让满档在最后一个计时步骤才到位。
                let scaledRise: Int = (b - a) * k
                let rise: Int = max(1, scaledRise / n)
                return a + rise
            }
            out.append(step)
        }
        return out
    }
}

/// 收藏现在能不能点、为什么（纯展示规则，ProtocolChecks 覆盖）。真正的拦截仍在 ManualControlVM.applyFavorite
/// 和 BLEManager 的准入里；这里只决定卡片灰不灰、旁边写什么
struct FavoriteRecallRules {
    let mode: BCProtocol.Mode
    /// 滑杆当前值（技能模式下是预设的值）
    let levels: [Int]
    /// 已连接且安全规则允许输出
    let canOutput: Bool
    /// 不能输出的原因（未连接 / 额度 / 锁存）；canOutput 为 true 时为 nil
    let blockReason: String?
    /// 本次运行还开着（runRemaining != nil）
    let running: Bool

    /// 正在运行时别的模式的收藏：切模式要先确认停机，所以先锁住
    func locked(_ fav: FavoriteSetting) -> Bool {
        running && fav.mode != mode
    }

    func usable(_ fav: FavoriteSetting) -> Bool {
        canOutput && fav.clampedLevels != nil && !locked(fav)
    }

    /// 一张卡片的旁白提示
    func hint(for fav: FavoriteSetting) -> String {
        if let r = blockReason { return r }
        if locked(fav) { return "正在输出，切换模式要先停止并等确认" }
        if let m = fav.mode, m != mode { return "切到\(m.title)，再缓缓推到这组强度" }
        return "缓缓推到这组强度"
    }

    /// 收藏区下面的一句状态（不能点时说为什么）；都能点时为 nil
    func status(for items: [FavoriteSetting]) -> String? {
        if let r = blockReason { return r }
        guard running, items.contains(where: { $0.mode != mode }) else { return nil }
        // 滑杆都拉到 0 时运行仍在计时（设备停在 0）：别说"正在输出"，说清楚要先点停止
        if !levels.contains(where: { $0 > 0 }) {
            return "本次运行仍在计时：先点停止，确认后再点其他模式的收藏"
        }
        return "正在输出：其他模式的收藏要先停止，确认后再点"
    }
}

/// 热度对应的一个词（手感页中央的"心"下面，纯展示）
enum HeatMood {
    static func word(for heat: Double) -> String {
        if !(heat > 0) { return "静候" }
        if heat < 0.3 { return "微热" }
        if heat < 0.6 { return "升温" }
        if heat < 0.85 { return "炽热" }
        return "沸点"
    }
}

/// 「她」页输入栏上方的快捷话：一点就发，和自己打字发出去完全一样（同一条发送路径）。
/// 这里的每一句都不能碰到本地停止词（ProtocolChecks 钉住），否则点"再快一点"反而会停
enum AIQuickReplies {
    /// 还没开始时：邀请她开始
    static let idle = ["开始吧", "温柔一点", "慢慢来", "逗逗我"]
    /// 她正在带节奏时：调快慢、换花样
    static let running = ["慢一点", "再快一点", "就是这样", "换个节奏", "温柔一点"]
    /// 全部（ProtocolChecks 逐条检查不是停止词）
    static var phrases: [String] { idle + running }

    static func current(running isRunning: Bool) -> [String] {
        isRunning ? Self.running : Self.idle
    }
}
// MARK: - 声音联动（视频页）：纯计算，Round4Checks 覆盖。
// 实时线程只做 AudioChannelStats / AudioWindowAccumulator 这种不分配内存的累加；
// 灵敏度、噪声门、平滑、上限都在主线程每 0.3 秒算一次（AudioReactiveShaper），结果走 BLEManager.sendTick。

/// 音轨采样格式（MTAudioProcessingTap prepare 回调里的 ASBD）。
/// 常量照 CoreAudioBaseTypes.h 抄过来：这个文件只依赖 Foundation，测试才能直接编译
enum AudioSampleFormat: Equatable {
    case float32, float64, int16, int32

    static let linearPCM: UInt32 = 0x6C70_636D // 'lpcm'
    static let flagIsFloat: UInt32 = 1 << 0
    static let flagIsBigEndian: UInt32 = 1 << 1
    static let flagIsSignedInteger: UInt32 = 1 << 2

    /// 认不出的格式（压缩、大端、24 位打包、无符号整数等）返回 nil：不分析，设备不输出
    static func resolve(formatID: UInt32, flags: UInt32, bitsPerChannel: UInt32) -> AudioSampleFormat? {
        guard formatID == linearPCM, flags & flagIsBigEndian == 0 else { return nil }
        if flags & flagIsFloat != 0 {
            switch bitsPerChannel {
            case 32: return .float32
            case 64: return .float64
            default: return nil
            }
        }
        guard flags & flagIsSignedInteger != 0 else { return nil }
        switch bitsPerChannel {
        case 16: return .int16
        case 32: return .int32
        default: return nil
        }
    }

    var bytesPerSample: Int {
        switch self {
        case .float32, .int32: return 4
        case .float64: return 8
        case .int16: return 2
        }
    }

    /// 整数样本归一化到 ±1 的系数
    var scale: Double {
        switch self {
        case .float32, .float64: return 1
        case .int16: return 1.0 / 32_768
        case .int32: return 1.0 / 2_147_483_648
        }
    }
}

/// 一个声道一段样本的峰峰值和均方（非有限值跳过）
struct AudioChannelStats {
    private(set) var minimum = Double.infinity
    private(set) var maximum = -Double.infinity
    private(set) var sumSquares: Double = 0
    private(set) var count = 0

    @inline(__always)
    mutating func add(_ v: Double) {
        guard v.isFinite else { return }
        if v < minimum { minimum = v }
        if v > maximum { maximum = v }
        sumSquares += v * v
        count += 1
    }

    var peakToPeak: Double { count > 0 ? maximum - minimum : 0 }
    var meanSquare: Double { count > 0 ? sumSquares / Double(count) : 0 }
}

/// 一个分析窗口（约 0.3 秒）的结果。frames == 0 表示这段时间没有音频经过（暂停 / 缓冲 / 没有音轨）
struct AudioWindow: Equatable {
    var peakToPeak: Double = 0
    var rms: Double = 0
    var frames: Int = 0

    static let silent = AudioWindow()
}

/// 窗口累加：每次 tap 回调交来"最响那个声道"的峰峰值 / 均方，多声道不相加（反相声道不会互相抵消）
struct AudioWindowAccumulator {
    private(set) var peakToPeak: Double = 0
    private var weightedMeanSquare: Double = 0
    private(set) var frames = 0

    mutating func add(peakToPeak p2p: Double, meanSquare: Double, frames n: Int) {
        guard n > 0, p2p.isFinite, meanSquare.isFinite, p2p >= 0, meanSquare >= 0 else { return }
        peakToPeak = max(peakToPeak, p2p)
        weightedMeanSquare += meanSquare * Double(n)
        frames += n
    }

    /// 取走本窗口的结果并清零
    mutating func drain() -> AudioWindow {
        let window = frames > 0
            ? AudioWindow(peakToPeak: peakToPeak, rms: (weightedMeanSquare / Double(frames)).squareRoot(), frames: frames)
            : .silent
        self = AudioWindowAccumulator()
        return window
    }
}

/// 声音联动输出到哪个通道。设备只有伸缩 / 震动：吮吸（索引 2）和索引 3 恒为 0
enum AudioSyncChannels: Int, CaseIterable, Identifiable {
    case both = 0
    case thrust = 1
    case vibration = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .both: return "伸缩 + 震动"
        case .thrust: return "仅伸缩"
        case .vibration: return "仅震动"
        }
    }

    /// 0~100 的强度换成 0x08 帧四通道（0~99）
    func levels(percent: Int) -> [Int] {
        let v = max(0, min(BCProtocol.maxManualLevel, percent))
        switch self {
        case .both: return [v, v, 0, 0]
        case .thrust: return [v, 0, 0, 0]
        case .vibration: return [0, v, 0, 0]
        }
    }
}

/// 声音联动设置（视频页 @AppStorage 持久化）。取值一律夹回范围，存储里的坏值不会放大输出
struct AudioSyncSettings: Equatable {
    /// 键名不带点：@AppStorage 走 KVO，点会被当成路径
    enum Keys {
        static let enabled = "bcAudioSyncEnabled"
        static let sensitivityDb = "bcAudioSyncSensitivityDb"
        static let maxPercent = "bcAudioSyncMaxPercent"
        static let channels = "bcAudioSyncChannels"
        static let minPercent = "bcAudioSyncMinPercent"
        static let autoGain = "bcAudioSyncAutoGain"
    }

    static let defaultEnabled = true
    /// 灵敏度 = 增益（dB）：-12 dB（×0.25）~ +18 dB（约 ×7.9）
    static let sensitivityRange: ClosedRange<Double> = -12...18
    static let defaultSensitivityDb: Double = 0
    /// 强度上限（%）：最响的时候到这里
    static let maxPercentRange: ClosedRange<Double> = 10...100
    static let defaultMaxPercent: Double = 60
    static let defaultChannels = AudioSyncChannels.both
    /// 最低强度（%）：播放中安静片段也不归零，保持在这里（用户要求"不归零"）；0 = 允许归零
    static let minPercentRange: ClosedRange<Double> = 0...50
    /// App 里没存过时的默认值（init 参数默认 0，纯逻辑测试沿用原行为）
    static let defaultMinPercent: Double = 10
    /// 自动灵敏度：跟踪当前视频最近的响度，自动把它的响段映射到接近上限，安静的视频和响的视频都用满范围
    static let defaultAutoGain = true

    var enabled: Bool
    var sensitivityDb: Double
    var maxPercent: Double
    var channels: AudioSyncChannels
    var minPercent: Double
    var autoGain: Bool

    init(enabled: Bool = defaultEnabled, sensitivityDb: Double = defaultSensitivityDb,
         maxPercent: Double = defaultMaxPercent, channels: AudioSyncChannels = defaultChannels,
         minPercent: Double = 0, autoGain: Bool = false) {
        self.enabled = enabled
        self.sensitivityDb = Self.clamp(sensitivityDb, to: Self.sensitivityRange, fallback: Self.defaultSensitivityDb)
        self.maxPercent = Self.clamp(maxPercent, to: Self.maxPercentRange, fallback: Self.defaultMaxPercent)
        self.channels = channels
        // 最低强度不超过上限
        self.minPercent = min(self.maxPercent, Self.clamp(minPercent, to: Self.minPercentRange, fallback: 0))
        self.autoGain = autoGain
    }

    static func load(from defaults: UserDefaults) -> AudioSyncSettings {
        let channels = (defaults.object(forKey: Keys.channels) as? Int).flatMap(AudioSyncChannels.init(rawValue:))
        return AudioSyncSettings(
            enabled: defaults.object(forKey: Keys.enabled) as? Bool ?? defaultEnabled,
            sensitivityDb: defaults.object(forKey: Keys.sensitivityDb) as? Double ?? defaultSensitivityDb,
            maxPercent: defaults.object(forKey: Keys.maxPercent) as? Double ?? defaultMaxPercent,
            channels: channels ?? defaultChannels,
            minPercent: defaults.object(forKey: Keys.minPercent) as? Double ?? defaultMinPercent,
            autoGain: defaults.object(forKey: Keys.autoGain) as? Bool ?? defaultAutoGain)
    }

    /// 灵敏度的倍数写法（界面显示）
    var gainMultiplier: Double { pow(10, sensitivityDb / 20) }

    private static func clamp(_ v: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, v))
    }
}

/// 响度 → 设备强度（0~100）。官方「赛博联动」只取 300 ms 窗口里的峰峰值 ×100、不钳位不平滑；
/// 这里改成：RMS 为主、峰值补瞬态的 dB 电平 → 灵敏度（增益）→ 映射到 0~100 → 噪声门（带回差）
/// → 攻击快 / 释放慢的平滑 → 按强度上限等比缩放 → 钳位
struct AudioReactiveShaper {
    /// 采样间隔（约 3.3 Hz，低于 BLE 写入合并器的吞吐）
    static let interval: TimeInterval = 0.3
    /// 增益之后，这个电平映射为 0%、这个电平映射为 100%
    static let floorDb: Double = -45
    static let ceilingDb: Double = -3
    /// 增益之前低于这个电平一律当静音（灵敏度开到最大也不放大底噪）
    static let absoluteGateDb: Double = -60
    /// 噪声门：映射值到这么高才打开，低于关闭值才关上（回差避免在门槛附近反复启停）
    static let gateOpenPercent: Double = 8
    static let gateClosePercent: Double = 4
    /// 平滑时间常数：变响几乎立刻跟上，变轻慢慢落下
    static let attackSeconds: TimeInterval = 0.08
    static let releaseSeconds: TimeInterval = 0.8
    /// dB 加权里 RMS 的比重（其余给峰值）
    static let rmsWeight: Double = 0.7
    /// 自动灵敏度：参考响度（视频最近的"响段"电平）的起始值、上升 / 下降时间常数，
    /// 以及参考响度要映射到的位置（0~100）
    static let autoInitialRefDb: Double = -20
    static let autoRiseSeconds: TimeInterval = 1.5
    static let autoFallSeconds: TimeInterval = 20
    static let autoTargetPercent: Double = 85
    /// 自动增益的范围（dB）：再安静的视频也最多放大这么多，避免把纯底噪放大成强输出
    static let autoGainRange: ClosedRange<Double> = -12...24
    /// 自动模式下手动灵敏度只做微调（±6 dB），总增益仍夹在 autoGainRange 内
    static let autoTrimRange: ClosedRange<Double> = -6...6
    /// 自动模式的相对噪声门：比参考响度低这么多以上算底噪，不放大成输出
    static let autoRelativeGateDb: Double = 24
    /// 低于相对噪声门的样本学习得很慢（下降时间常数）
    static let autoBelowGateFallSeconds: TimeInterval = 180

    struct Output: Equatable {
        /// 灵敏度之后、噪声门之前的电平（0~100），界面电平条用
        var level: Double
        /// 最终强度（0 ~ 强度上限）
        var percent: Int
    }

    private(set) var smoothed: Double = 0
    private(set) var gateOpen = false
    /// 自动灵敏度跟踪的参考响度（dB）；暂停 / 跳转不清零，换视频时 resetAdaptation()
    private(set) var refDb: Double = autoInitialRefDb
    /// 这个视频是否已经出现过高于相对噪声门的声音；换视频时清掉
    private(set) var heardAboveGate = false
    private(set) var aboveGateSeconds: TimeInterval = 0

    mutating func reset() {
        smoothed = 0
        gateOpen = false
    }

    /// 换视频：重新学习响度
    mutating func resetAdaptation() {
        reset()
        refDb = Self.autoInitialRefDb
        heardAboveGate = false
        aboveGateSeconds = 0
    }

    /// 当前自动增益（dB）：把参考响度放到 autoTargetPercent
    var autoGainDb: Double {
        let targetDb = Self.floorDb + Self.autoTargetPercent / 100 * (Self.ceilingDb - Self.floorDb)
        let g = targetDb - refDb
        guard g.isFinite else { return 0 }
        return min(Self.autoGainRange.upperBound, max(Self.autoGainRange.lowerBound, g))
    }

    /// 跟踪参考响度：变响较快跟上，变轻很慢地落（一段安静不会立刻把增益拉满）
    private mutating func adapt(loudnessDb db: Double, dt: TimeInterval) {
        guard db.isFinite, db > Self.absoluteGateDb else { return }
        // 远低于参考响度的（安静段底噪）只极慢地学：否则十几秒就把参考拉下来，相对噪声门失效。
        // 整段都很安静的视频仍能在几分钟内学到自己的响度
        let belowGate = db < refDb - Self.autoRelativeGateDb
        // 听到过这个视频的「响段」之后，安静段底噪不再训练参考响度（否则几分钟的安静段后门会失效、底噪被顶满增益）。
        // 从没听到过高于门的内容（整段都很安静的视频）才允许慢慢往下学
        if belowGate && heardAboveGate { return }
        if !belowGate {
            // 要累计够一个下降时间常数的门上内容才算「听到过响段」：片头一声 / 关门声不能把安静视频锁死
            aboveGateSeconds += dt
            if aboveGateSeconds >= Self.autoFallSeconds { heardAboveGate = true }
        }
        let tau = db > refDb ? Self.autoRiseSeconds
            : (belowGate ? Self.autoBelowGateFallSeconds : Self.autoFallSeconds)
        refDb += (db - refDb) * (1 - exp(-dt / tau))
        if !refDb.isFinite { refDb = Self.autoInitialRefDb }
    }

    /// 增益前的电平（dBFS 量级）。满幅正弦 ≈ 0 dB；没有音频或全静音返回 -inf
    static func loudnessDb(_ w: AudioWindow) -> Double {
        guard w.frames > 0, w.peakToPeak.isFinite, w.rms.isFinite else { return -.infinity }
        let peak = min(1, max(0, w.peakToPeak / 2))
        let rms = min(1, max(0, w.rms * 2.0.squareRoot()))
        guard peak > 0, rms > 0 else { return -.infinity }
        return rmsWeight * 20 * log10(rms) + (1 - rmsWeight) * 20 * log10(peak)
    }

    /// 电平加上灵敏度后映射到 0~100
    static func targetPercent(loudnessDb db: Double, sensitivityDb: Double) -> Double {
        guard db.isFinite, db > absoluteGateDb, sensitivityDb.isFinite else { return 0 }
        let frac = (db + sensitivityDb - floorDb) / (ceilingDb - floorDb)
        return min(100, max(0, frac * 100))
    }

    /// hasAudio = false（没有音轨 / 分析失败 / 还没就绪 / 缓冲中 / 没有新鲜样本，见 AudioFlowWatch）
    /// 时不加最低强度：没有信号就不输出
    mutating func step(_ w: AudioWindow, settings: AudioSyncSettings, dt: TimeInterval,
                       hasAudio: Bool = true) -> Output {
        // 计时抖动 / 主线程卡顿：步长夹在 10 ms ~ 1 s
        let step = dt.isFinite ? min(1, max(0.01, dt)) : Self.interval
        let db = Self.loudnessDb(w)
        var gain = settings.sensitivityDb
        // 开关关着也一直学：中途打开自动灵敏度时参考响度已经是这个视频的
        adapt(loudnessDb: db, dt: step)
        if settings.autoGain {
            // 自动增益 + 手动灵敏度作微调
            let trim = min(Self.autoTrimRange.upperBound, max(Self.autoTrimRange.lowerBound, settings.sensitivityDb))
            gain = min(Self.autoGainRange.upperBound, max(Self.autoGainRange.lowerBound, autoGainDb + trim))
        }
        var level = Self.targetPercent(loudnessDb: db, sensitivityDb: gain)
        // 自动模式：远低于这个视频响段的声音（安静段底噪）不输出，只剩最低强度
        if settings.autoGain, db.isFinite, db < refDb - Self.autoRelativeGateDb { level = 0 }
        if gateOpen {
            if level < Self.gateClosePercent { gateOpen = false }
        } else if level >= Self.gateOpenPercent {
            gateOpen = true
        }
        let target = gateOpen ? level : 0
        let tau = target > smoothed ? Self.attackSeconds : Self.releaseSeconds
        smoothed += (target - smoothed) * (1 - exp(-step / tau))
        smoothed = smoothed.isFinite ? min(100, max(0, smoothed)) : 0
        let cap = settings.maxPercent
        let floor = hasAudio ? min(cap, settings.minPercent) : 0
        let percent: Int
        if floor >= 1 {
            // 不归零：0~100 映射到 最低强度 ~ 上限
            let scaled = floor + smoothed * (cap - floor) / 100
            percent = min(Int(cap.rounded(.down)), max(Int(floor.rounded()), Int(scaled.rounded())))
        } else {
            let scaled = smoothed * cap / 100
            percent = scaled < 1 ? 0 : min(Int(cap.rounded(.down)), Int(scaled.rounded()))
        }
        return Output(level: level, percent: max(0, min(100, percent)))
    }
}
