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
