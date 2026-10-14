import Foundation

/// 自然结束必须到达实际终点；靠近末尾的外部暂停不能算播完。
enum PlaybackCompletion {
    static func reachedEnd(position: Double, duration: Double) -> Bool {
        position.isFinite && duration.isFinite && duration > 0 && position >= duration
    }
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
// 准入、冷却、额度、看门狗、单次上限一个不少；这里只负责把存下来的值夹回各自模式的范围。

/// 一条收藏：控制方式（变频 / 手动）+ 三个通道的强度
struct FavoriteSetting: Codable, Identifiable, Equatable {
    static let maxCount = 8
    static let maxNameLength = 12
    /// 打字过程中的草稿上限：比 maxNameLength 宽松得多，拼音还没上屏时不会被截断（完成时再截到 maxNameLength）
    static let maxDraftLength = 40
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
    /// 解不出来就当没有；无效条目（技能 / 全零 / 未知模式）丢掉，最多 maxCount 条
    static func decode(_ data: Data?) -> [FavoriteSetting] {
        guard let d = data, let items = try? JSONDecoder().decode([FavoriteSetting].self, from: d) else { return [] }
        let valid = items.filter { $0.clampedLevels != nil }
        return Array(valid.prefix(FavoriteSetting.maxCount))
    }

    static func encode(_ items: [FavoriteSetting]) -> Data? {
        try? JSONEncoder().encode(Array(items.prefix(FavoriteSetting.maxCount)))
    }
}

/// 召回收藏时的"缓缓推上去"：升高的通道分几步爬到目标，降低的通道第一步就到位（降低永远立即生效）。
/// 只算每一步的值；发送由 ManualControlVM 做：第一步是用户这次点按（send，开闸），
/// 后面的步骤走 sendThrottled（不开闸）：中途有任何停止（用户 / 看门狗 / 上限 / 断开），后面的步骤都会被丢掉
enum FavoriteGlide {
    static let steps = 6
    static let stepInterval: TimeInterval = 0.15

    /// 从 from 到 to 的每一步（不含起点，最后一步恰好是 to；相邻重复的步骤合并）。
    /// from == to 时只有一步（重新发一次目标值）
    static func plan(from: [Int], to: [Int], steps: Int = steps) -> [[Int]] {
        let n = max(1, steps)
        let start = (0..<4).map { $0 < from.count ? max(0, from[$0]) : 0 }
        let target = (0..<4).map { $0 < to.count ? max(0, to[$0]) : 0 }
        var out: [[Int]] = []
        for k in 1...n {
            let step = (0..<4).map { (i: Int) -> Int in
                let a = start[i]
                let b = target[i]
                guard b > a else { return b }
                // 向上取整：升高的通道第一步至少 +1，中间步骤不会出现"全零"（全零会被当成停止帧对）
                let rise = ((b - a) * k + n - 1) / n
                return a + rise
            }
            if out.last != step { out.append(step) }
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
    /// 不能输出的原因（未连接 / 冷却 / 额度 / 锁存）；canOutput 为 true 时为 nil
    let blockReason: String?
    /// 本次运行还开着（runRemaining != nil）
    let running: Bool

    /// 正在运行时别的模式的收藏：切模式要先停机，停机后还要冷却，点了也只会停下，所以先锁住
    func locked(_ fav: FavoriteSetting) -> Bool {
        running && fav.mode != mode
    }

    func usable(_ fav: FavoriteSetting) -> Bool {
        canOutput && fav.clampedLevels != nil && !locked(fav)
    }

    /// 一张卡片的旁白提示
    func hint(for fav: FavoriteSetting) -> String {
        if let r = blockReason { return r }
        if locked(fav) { return "正在输出，切换模式要先停止并冷却" }
        return "缓缓推到这组强度"
    }

    /// 收藏区下面的一句状态（不能点时说为什么）；都能点时为 nil
    func status(for items: [FavoriteSetting]) -> String? {
        if let r = blockReason { return r }
        guard running, items.contains(where: { $0.mode != mode }) else { return nil }
        // 滑杆都拉到 0 时运行仍在计时（设备停在 0）：别说"正在输出"，说清楚要先点停止
        if !levels.contains(where: { $0 > 0 }) {
            return "本次运行仍在计时：先点停止，冷却结束后再点其他模式的收藏"
        }
        return "正在输出：其他模式的收藏要先停止，冷却结束后再点"
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
