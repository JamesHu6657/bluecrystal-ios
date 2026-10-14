import Foundation

/// 醉清风 aa 协议（参数全部取自官方 App 3.5.1 源码，app-service.js）
///
/// 通用帧（官方 be(cmd, arr)）：AA <cmd> <len> <payload...> <checksum>
/// checksum = 前面所有字节相加取低 8 位
/// 写特征值 FFA1，Write With Response
///
/// - 0x06 模式帧（官方 Tt()，技能 / 变频 tab）：AA 06 05 <伸缩> <震动> <吮吸> <旋转> 00 <cs>
///   变频滑杆官方默认范围 0~9；技能预设最高也是 9
/// - 0x08 帧（官方 at(arr, t)）：AA 08 06 <伸缩> <震动> <吮吸> <旋转> <t 高字节> <t 低字节> <cs>
///   手动 tab、全屏视频页、video.js 脚本指令都用 t = 0；手动滑杆官方范围 0~99
/// - 停止：官方全屏视频页退出时先发 0x08 归零帧 at([0,0,0,0],0)，100ms 后再发 0x06 停止帧 Tt([0,0,0,0])
enum BCProtocol {

    static let header: UInt8 = 0xAA
    static let modeCmd: UInt8 = 0x06
    static let manualCmd: UInt8 = 0x08

    /// 四通道索引（官方 getSlideProtocolIndex：伸缩 0 / 震动 1 / 吮吸 2 / 旋转 3）
    enum Channel: Int, CaseIterable {
        case thrust = 0    // 伸缩
        case vibration = 1 // 震动
        case suction = 2   // 吮吸
        case rotation = 3  // 旋转

        var displayName: String {
            switch self {
            case .thrust: return "伸缩"
            case .vibration: return "震动"
            case .suction: return "吮吸"
            case .rotation: return "旋转"
            }
        }

        /// 旋转通道只留在协议里、恒发 0（修 N5）：官方面板默认滑杆只有伸缩/震动/吮吸，
        /// 内置的 mizzzee 配置和五个技能预设都没用到它，0032 的服务端配置也没拿到
        var isUsed: Bool { self != .rotation }

        /// 界面上显示的通道
        static var uiChannels: [Channel] { allCases.filter { $0.isUsed } }

        /// 时间轴脚本里的 commandType 映射（官方 xi 表的键：Thrust / Vibration / Suction / Rotation）
        static func from(commandType: String) -> Channel? {
            switch commandType.lowercased() {
            case "thrust", "stretch": return .thrust
            case "vibration": return .vibration
            case "suction", "sucking": return .suction
            case "rotation", "rotate": return .rotation
            default: return nil
            }
        }
    }

    /// 控制方式，对应官方 PlayPanel 的三个 tab
    enum Mode: Int, CaseIterable, Identifiable {
        case skill = 1    // 技能：固定预设，0x06
        case frequency = 2 // 变频：滑杆 0~9，0x06
        case manual = 3   // 手动：滑杆 0~99，0x08

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .skill: return "技能"
            case .frequency: return "变频"
            case .manual: return "手动"
            }
        }
        var maxLevel: Int {
            switch self {
            case .skill, .frequency: return BCProtocol.maxModeLevel
            case .manual: return BCProtocol.maxManualLevel
            }
        }
        func frame(channels: [Int]) -> Data {
            switch self {
            case .skill, .frequency: return BCProtocol.modeFrame(channels: channels)
            case .manual: return BCProtocol.manualFrame(channels: channels)
            }
        }
    }

    /// 官方技能预设（ts / n_ 表，原值）
    struct Preset: Identifiable {
        let key: String
        let title: String
        let channels: [Int]
        var id: String { key }
    }

    static let presets: [Preset] = [
        Preset(key: "shadow_follow", title: "如影随形", channels: [4, 6, 5, 0]),
        Preset(key: "wind_spin", title: "疾风旋舞", channels: [8, 9, 9, 0]),
        Preset(key: "phantom_follow", title: "幻影随行", channels: [6, 6, 8, 0]),
        Preset(key: "water_ring", title: "水光环绕", channels: [2, 2, 3, 0]),
        Preset(key: "dragon_tail", title: "神龙摆尾", channels: [3, 9, 3, 0]),
    ]

    /// 0x06 帧每通道上限（官方变频滑杆默认 [0, 9]）
    static let maxModeLevel = 9
    /// 0x08 帧每通道上限（官方手动滑杆 [0, 99]，脚本换算也夹到 99）
    static let maxManualLevel = 99
    /// 官方脚本强度加权：BV(…, 10) / VV(…, 10) 的第三个参数，非零值 +10
    static let scriptWeighting = 10

    /// 官方 be(cmd, arr)：AA cmd len payload checksum
    static func frame(cmd: UInt8, payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [header, cmd, UInt8(payload.count)]
        bytes.append(contentsOf: payload)
        let checksum = bytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        bytes.append(UInt8(checksum))
        return Data(bytes)
    }

    private static func clampChannels(_ channels: [Int], max maxV: Int) -> [UInt8] {
        (0..<4).map { (i: Int) -> UInt8 in
            // 修 N5：旋转通道恒为 0
            guard i != Channel.rotation.rawValue else { return 0 }
            let v = i < channels.count ? channels[i] : 0
            return UInt8(Swift.max(0, Swift.min(maxV, v)))
        }
    }

    /// 0x06 模式帧（官方 Tt(arr)：[...arr, 0]，末位标志官方恒为 0）
    static func modeFrame(channels: [Int]) -> Data {
        frame(cmd: modeCmd, payload: clampChannels(channels, max: maxModeLevel) + [0x00])
    }

    /// 0x08 帧（官方 at(arr, 0)：[...arr, 0x00, 0x00]）
    static func manualFrame(channels: [Int]) -> Data {
        frame(cmd: manualCmd, payload: clampChannels(channels, max: maxManualLevel) + [0x00, 0x00])
    }

    /// 视频联动帧（修 N2）：官方给迷姬（名字含 mizzzee 的设备 devType 2）发脚本/视频强度一律走 0x08：
    /// video.js executeIntensityCommand 是 at(BV(…), 0)，全屏视频页是 at([a,a,a,a], 0)。
    /// levels 用 officialScriptLevel 换算过的 0~99
    static func videoFrame(levels: [Int]) -> Data { manualFrame(channels: levels) }

    /// 官方脚本强度换算（video.js executeIntensityCommand → BV 的 directiveType "2" 分支）：
    /// status = 强度 × 10，u = parseInt(status)，u > 0 时 u += 10，u > 99 时 u = 99。
    /// 传入的就是 status（十档值 × 10，或百分制原值）
    static func officialScriptLevel(status: Double) -> Int {
        // NaN、负数、不到 1（parseInt 后为 0）都按 0，不加权
        guard status >= 1 else { return 0 }
        // 先在 Double 域夹紧再转 Int，超大值/无穷大不会溢出崩溃
        guard status < Double(maxManualLevel) else { return maxManualLevel }
        return min(Int(status) + scriptWeighting, maxManualLevel)
    }

    /// 停止帧：官方 be("06",[0,0,0,0,0]) = Tt([0,0,0,0]) = AA 06 05 00 00 00 00 00 B5（与实抓一致）
    static var stopFrame: Data { modeFrame(channels: [0, 0, 0, 0]) }

    /// 0x08 归零帧：官方 at([0,0,0,0], 0) = AA 08 06 00 00 00 00 00 00 B8。
    /// 每次停止都先发它，100ms 后再发 stopFrame
    static var manualZeroFrame: Data { manualFrame(channels: [0, 0, 0, 0]) }

    /// 官方默认技能"如影随形"：AA 06 05 04 06 05 00 00 C4（与实抓的官方启动帧一致）
    static var officialStartFrame: Data { modeFrame(channels: presets[0].channels) }

    /// 调试用：Data 转 HEX 字符串
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
