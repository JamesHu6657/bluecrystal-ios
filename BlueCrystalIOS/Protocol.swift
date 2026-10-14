import Foundation

/// 醉清风 aa 协议 0x06 模式命令（mizzzee_0032 实抓验证）
///
/// 帧格式：AA 06 05 <ch0> <ch1> <ch2> <ch3> <flag=00> <checksum>
/// 共 9 字节，checksum = 前 8 字节相加取低 8 位
/// 写特征值 FFA1，需 Write With Response
enum BCProtocol {

    static let header: UInt8 = 0xAA
    static let cmd: UInt8 = 0x06
    static let len: UInt8 = 0x05

    /// 四通道索引
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

        /// 时间轴脚本里的 commandType 映射
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

    /// 设备每通道最高档位。官方 App 实抓启动帧为 04 06 05 00（个位数档位），
    /// 设备按 0~9 档解释：之前按 0~99 发，1% 以上就会被设备当成高档（用户实测"一档跑到九档"）
    static let maxLevel = 9

    /// 构造 0x06 控制帧，每通道档位 0~maxLevel
    static func frame(channels: [Int]) -> Data {
        var bytes: [UInt8] = [header, cmd, len]
        for i in 0..<4 {
            let v = i < channels.count ? channels[i] : 0
            bytes.append(UInt8(max(0, min(maxLevel, v))))
        }
        bytes.append(0x00) // flag，恒 0
        let checksum = bytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        bytes.append(UInt8(checksum))
        return Data(bytes)
    }

    /// 停止帧：AA 06 05 00 00 00 00 00 B5（实抓验证）
    static var stopFrame: Data {
        frame(channels: [0, 0, 0, 0])
    }

    /// 官方 UI 启动帧：AA 06 05 04 06 05 00 00 C4（实抓验证）
    static var officialStartFrame: Data {
        Data([0xAA, 0x06, 0x05, 0x04, 0x06, 0x05, 0x00, 0x00, 0xC4])
    }

    /// 调试用：Data 转 HEX 字符串
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}
