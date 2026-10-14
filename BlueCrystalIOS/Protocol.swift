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
/// - 停止：照官方迷姬专用停止（video.js handleSlide）先发 0x08 停止帧 at([0,0,0,0],255)，100ms 后再发 0x06 停止帧 Tt([0,0,0,0])
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

    /// 0x08 帧（官方 at(arr, t)：[...arr, t 高字节, t 低字节]；普通输出 t = 0）
    static func manualFrame(channels: [Int], tail: UInt16 = 0) -> Data {
        frame(cmd: manualCmd,
              payload: clampChannels(channels, max: maxManualLevel) + [UInt8(tail >> 8), UInt8(tail & 0xFF)])
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

    /// 0x08 停止帧：官方迷姬（devType 2）专用停止 video.js handleSlide：
    /// at([0,0,0,0], 255) = AA 08 06 00 00 00 00 00 FF B7，100ms 后再发 Tt([0,0,0,0])。
    /// 1.7.4 起改用它：at([0,0,0,0], 0) 只是"强度 0"，真机上点停止后设备不停。
    static var manualZeroFrame: Data { manualFrame(channels: [0, 0, 0, 0], tail: 0x00FF) }

    /// 官方默认技能"如影随形"：AA 06 05 04 06 05 00 00 C4（与实抓的官方启动帧一致）
    static var officialStartFrame: Data { modeFrame(channels: presets[0].channels) }

    /// 调试用：Data 转 HEX 字符串
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

/// 停止帧对的纯状态：首帧失败不能取消 100ms 后的第二帧（F1）。
/// 调度、写入 ID 和重试仍由 BLEManager 在 bleQueue 上管理。
struct StopPairAttempt {
    enum Phase {
        case gap
        case awaitingAcks
        case backoff
    }

    var phase: Phase = .gap
    var zeroAcked = false
    var stopAcked = false
    private(set) var failureReason: String?

    var confirmed: Bool { failureReason == nil && zeroAcked && stopAcked }

    /// gap 中只记下失败；第二帧发出后才进入整对重试。
    mutating func recordFailure(_ reason: String) -> Bool {
        if failureReason == nil { failureReason = reason }
        return phase != .gap
    }

    mutating func didSendStopFrame() -> String? {
        phase = .awaitingAcks
        return failureReason
    }
}

extension BCProtocol {
    /// 四个通道全为 0 的输出帧（0x08 任意尾部，或 0x06）
    static func isAllZeroOutput(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == header, b[1] == manualCmd || b[1] == modeCmd else { return false }
        return b[3...6].allSatisfy { $0 == 0 }
    }
}

/// 输出准入中和停止帧对有关的纯决策（BLEManager.submitOutput 用，ProtocolChecks 覆盖）。
///
/// 全零输出不当普通帧发：at([0,0,0,0],0) 在真机上只是"强度 0"，设备不停（见 manualZeroFrame）。
/// - 设备没在输出：直接丢掉，不开始一次运行（不占额度、不产生冷却）；
/// - 设备在输出：发完整停止帧对 at(0,255) → 100ms → Tt(0)，运行保持（不结束记账、不锁闸），
///   之后的非零帧照常经过准入继续输出；
/// - 已经为这次全零发过停止帧对、之后还没有非零帧：重复的全零帧不再发。
enum OutputGate {
    enum Decision: Equatable {
        case write
        case skipIdleZero
        case alreadyZeroed
        case zeroStopPair
    }

    static func decide(allZero: Bool, isActive: Bool, zeroHeld: Bool) -> Decision {
        guard allZero else { return .write }
        if !isActive { return .skipIdleZero }
        return zeroHeld ? .alreadyZeroed : .zeroStopPair
    }
}

/// 输出写入合并（纯状态，BLEManager 在 bleQueue 上用）：
/// - 同一时间最多一笔非停止帧在途（写入回执、失败或超时之前不发下一笔）；
/// - 在途期间到来的帧只保留最新一帧；
/// - 停止帧对不经过这里，发停止前先 dropPending()，停止帧永远排在待发输出前面。
struct OutputWriteCoalescer {
    enum Action: Equatable {
        case write(Data)
        case coalesced
    }

    private(set) var inFlight = false
    private(set) var pending: Data?

    mutating func submit(_ frame: Data) -> Action {
        if inFlight {
            pending = frame
            return .coalesced
        }
        inFlight = true
        return .write(frame)
    }

    /// 在途那笔有了结果。canSend 为 false 时丢掉待发帧；返回值是现在要写的下一帧（已标记在途）
    mutating func writeFinished(canSend: Bool) -> Data? {
        inFlight = false
        guard let next = pending else { return nil }
        pending = nil
        guard canSend else { return nil }
        inFlight = true
        return next
    }

    mutating func dropPending() { pending = nil }

    mutating func reset() {
        inFlight = false
        pending = nil
    }
}
