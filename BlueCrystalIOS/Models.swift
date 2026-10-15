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
    enum Observation { case moving, waitingAfterSeek, stalled }
    private var position: Double = .nan
    private var progressedAt: TimeInterval = 0
    private(set) var awaitingSeekProgress = false

    mutating func reset(now: TimeInterval) {
        position = .nan
        progressedAt = now
        awaitingSeekProgress = false
    }

    mutating func awaitSeekProgress(from seconds: Double, now: TimeInterval) {
        reset(now: now)
        position = seconds
        awaitingSeekProgress = true
    }

    mutating func observe(at seconds: Double, now: TimeInterval) -> Observation {
        if seconds.isFinite, position.isNaN || abs(seconds - position) > 0.01 {
            position = seconds
            progressedAt = now
            awaitingSeekProgress = false
            return .moving
        }
        if awaitingSeekProgress { return .waitingAfterSeek }
        return now - progressedAt > Self.stallLimit ? .stalled : .moving
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

    /// 脚本里旋转通道的命令数（旋转恒为 0，这些命令会被忽略，修 N5）
    var ignoredRotationCount: Int {
        commands.filter { $0.channel == .rotation }.count
    }

    var scaleDescription: String {
        useTenScale ? "十档（0~10）" : "百分（0~100）"
    }
}

/// 播放中的激活命令集合（用于判断是否需要重发）
struct ActiveChannels: Equatable {
    var values: [Int] // [ch0, ch1, ch2, ch3]，0x08 帧强度 0~99（ch3 旋转恒为 0）

    static var zero: ActiveChannels { ActiveChannels(values: [0, 0, 0, 0]) }

    static func == (lhs: ActiveChannels, rhs: ActiveChannels) -> Bool {
        lhs.values == rhs.values
    }
}

// MARK: - 我的收藏（手感页）：纯数据和换算，ProtocolChecks 覆盖。
// 只是"记住滑杆位置"：召回时走手动页同一条发送路径（ManualControlVM → BLEManager.send / sendThrottled），
// 准入、额度、看门狗、单次上限一个不少；这里只负责把存下来的值夹回各自模式的范围。

/// 一条收藏：控制方式（变频 / 手动）+ 三个通道的强度
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

    /// 召回用的强度：补齐 4 个通道、夹到该模式的 0~maxLevel、旋转恒 0；
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
        let valid = read.filter { $0.clampedLevels != nil }
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
        let start = (0..<4).map { $0 < from.count ? max(0, from[$0]) : 0 }
        let target = (0..<4).map { $0 < to.count ? max(0, to[$0]) : 0 }
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
