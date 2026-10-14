import Foundation

/// 时间轴脚本里的一条命令（兼容官方服务端格式）
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
}

/// 时间轴脚本文件
struct TimelineScript: Decodable {
    let commands: [TimelineCommand]
    /// 可选：强度刻度声明，"ten"（0~10）或 "percent"（0~100）。
    /// 不填则自动判断：任一命令 >10 → 百分制；否则按官方十档处理。
    /// 注意：一份全是小值的百分制脚本（如 3/5/8）会被误判成十档，
    /// 这种脚本请显式写 "intensityScale": "percent"。
    let intensityScale: String?

    /// 缓存的刻度判断结果，避免每 tick O(n)（修 N10）
    let useTenScale: Bool
    /// intensityScale 写了但不是 "ten"/"percent"，已回退自动判断（用于界面提示）
    let scaleFallback: Bool

    enum CodingKeys: String, CodingKey {
        case commands
        case intensityScale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commands = try c.decode([TimelineCommand].self, forKey: .commands)
        intensityScale = try c.decodeIfPresent(String.self, forKey: .intensityScale)
        // 修 高6：只有 "ten"/"percent" 是合法声明；写成其他值时回退到自动判断，
        // 不再静默当成百分制
        if let s = intensityScale?.lowercased() {
            if s == "ten" {
                useTenScale = true
                scaleFallback = false
            } else if s == "percent" {
                useTenScale = false
                scaleFallback = false
            } else {
                useTenScale = commands.allSatisfy { $0.intensityLevel <= 10 }
                scaleFallback = true
            }
        } else {
            scaleFallback = false
            // 自动判断：整个脚本统一用一种刻度，避免 10→99、10.5→11 这种断层
            useTenScale = commands.allSatisfy { $0.intensityLevel <= 10 }
        }
    }

    /// 命令强度换算成设备档位 0~BCProtocol.maxLevel
    /// 十档脚本直接用档位（10 夹到最高档）；百分制按比例换算，非零值至少 1 档
    func deviceLevel(for cmd: TimelineCommand) -> Int {
        let maxL = Double(BCProtocol.maxLevel)
        let raw = cmd.intensityLevel
        guard raw.isFinite, raw > 0 else { return 0 }
        let v = useTenScale ? raw : raw / 100.0 * maxL
        // 修 高6：先在 Double 域夹紧再转 Int，1e20 这种值不会溢出崩溃
        let clamped = min(max(v.rounded(), 1), maxL)
        return Int(clamped)
    }

    var scaleDescription: String {
        useTenScale ? "十档（0~10）" : "百分（0~100）"
    }
}

/// 播放中的激活命令集合（用于判断是否需要重发）
struct ActiveChannels: Equatable {
    var values: [Int] // [ch0, ch1, ch2, ch3]，0~BCProtocol.maxLevel

    static var zero: ActiveChannels { ActiveChannels(values: [0, 0, 0, 0]) }

    static func == (lhs: ActiveChannels, rhs: ActiveChannels) -> Bool {
        lhs.values == rhs.values
    }
}
