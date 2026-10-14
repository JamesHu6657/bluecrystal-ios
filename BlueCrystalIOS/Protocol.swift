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

    /// 完整 0x08 帧的四通道强度；不是 0x08 帧（含 0x06）时返回 nil（M1 限速基准用）
    static func manualLevels(_ data: Data) -> [Int]? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == header, b[1] == manualCmd else { return nil }
        return (3...6).map { Int(b[$0]) }
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

    /// 开闸请求是否仍然有效（M5）：AI 带着执行前读到的被动停机代次来开闸，
    /// 中间发生过被动停机（看门狗/上限/输出被拒/写失败/锁存/退后台/断开/断链）代次就变了，不开。
    /// nil = 用户直接操作（手动页拖动、视频页点播放），不比代次
    static func mayOpen(requestEpoch: Int?, currentEpoch: Int) -> Bool {
        guard let e = requestEpoch else { return true }
        return e == currentEpoch
    }

    /// 开闸的完整前提（第三轮 L2）：链路可写（已连接、不在断开流程、不在后台）且代次对得上。
    /// submitOutput 和 userResumeOutput 共用：之前 userResumeOutput 不看链路，断链 / 断开中 / 后台期间到的
    /// 开闸请求会把闸门打开，一直开到重连 / 回到前台之后，下一帧自动帧（tick、节流尾帧、AI 后续步）不用用户操作就能出去
    static func mayResume(linkWritable: Bool, requestEpoch: Int?, currentEpoch: Int) -> Bool {
        linkWritable && mayOpen(requestEpoch: requestEpoch, currentEpoch: currentEpoch)
    }
}

/// BLEManager.submitOutput 的完整准入顺序（纯决策，M3）。顺序本身就是安全约束：
/// 链路/后台 → 闸门 → 设备可能仍在输出 → 停止进行中（绝不插进停止帧对两帧之间）→ 运行到点（第三轮 L1）
/// → 全零 → 写入（空闲时开始一次运行）。
/// BLEManager 只负责把决策落地（锁闸、提示、记账、写入）。
enum OutputAdmission {
    struct Inputs {
        /// canWrite && !disconnecting && !appInBackground
        var linkWritable = true
        /// 处理完本次开闸请求后闸门是否开着
        var gateOpen = true
        /// physicalAckRequired || deviceMayBeActive
        var mayStillBeOutputting = false
        /// 有停止帧对在进行
        var stopInProgress = false
        /// 进行中的停止已经失败过（重试中）
        var stopFailed = false
        var allZero = false
        var isActive = false
        var zeroHeld = false
        /// 本次运行已经到点（单次上限或额度用完，ledger.runRemaining() ≤ 0）（第三轮 L1）
        var runExpired = false
    }

    enum Decision: Equatable {
        /// 静默丢弃：链路不可写/后台/断开中，或闸门关着（停止后的尾帧、tick）
        case drop
        /// 锁闸、界面归零并提示：设备可能仍在输出（锁存未解除）
        case rejectMayBeActive
        /// 锁闸、界面归零并提示：停止失败过、仍未确认
        case rejectStopUnconfirmed
        /// 停止帧对在路上：记下最新一帧，确认后重新走准入
        case deferUntilStopped
        /// 运行已经到点：这一帧不写（全零也不再走保持运行的停止帧对），直接按上限停机（第三轮 L1）。
        /// 到点定时器和看门狗在停止进行中都会跳过检查，之前停止帧对确认后重放挂起的帧会让设备越过上限再输出到下一次 tick
        case stopForLimit
        /// 全零：见 OutputGate
        case skipIdleZero
        case alreadyZeroed
        case zeroStopPair
        /// 写入；startsRun 为 true 时先过冷却/额度并开始一次运行
        case write(startsRun: Bool)
    }

    static func decide(_ i: Inputs) -> Decision {
        guard i.linkWritable, i.gateOpen else { return .drop }
        if i.mayStillBeOutputting { return .rejectMayBeActive }
        if i.stopInProgress { return i.stopFailed ? .rejectStopUnconfirmed : .deferUntilStopped }
        if i.isActive, i.runExpired { return .stopForLimit }
        switch OutputGate.decide(allZero: i.allZero, isActive: i.isActive, zeroHeld: i.zeroHeld) {
        case .skipIdleZero: return .skipIdleZero
        case .alreadyZeroed: return .alreadyZeroed
        case .zeroStopPair: return .zeroStopPair
        case .write: return .write(startsRun: !i.isActive)
        }
    }
}

/// 输出写入合并（纯状态，BLEManager 在 bleQueue 上用）：
/// - 同一时间最多一笔非停止帧在途（写入回执、失败或超时之前不发下一笔）；
/// - 在途期间到来的帧只保留最新一帧；
/// - 停止帧对不经过这里，发停止前先 dropPending()，停止帧永远排在待发输出前面；
/// - 升幅限速（M1）：带 maxRise 的帧（AI）在真正发出前，按实际发出的上一笔 0x08 帧再夹一次，
///   每通道最多升 maxRise。在途合并把中间的爬升步覆盖掉时，设备也不会一步跳过上限；
///   夹掉的差距不自动补（偏低是安全方向），由下一步/下一条回复继续爬。降低不受限制。
///   基准在启动、reset、停止帧对确认（resetBaseline）后按全 0 算；上一笔是 0x06 帧时也按全 0 算（刻度不同，偏保守）。
/// - 出口按时间限速 + 绝对上限（第二轮审查 M2）：只按帧限时，回执慢的在途合并会把两次升高压到不足 1 秒
///   （20 在 t=0、40 因在途拖到 t=1.5 才发、60 准点 t=2.0 → 设备 0.5 秒内升了 20）。带 maxRise 的帧还要满足：
///   距上次实际升高不到 riseInterval 时升幅按比例缩小（向下取整），每通道不超过 limitedMaxLevel（70）。
///   时间由调用方传入（BLEManager 一律传单调时钟）；nil 表示不按时间限（纯按帧的检查）。
struct OutputWriteCoalescer {
    enum Action: Equatable {
        case write(Data)
        case coalesced
    }

    /// AI 帧在出口的绝对上限（VM 的 AISafety 已经压过一次，这里兜底）
    static let limitedMaxLevel = AISafety.maxLevel
    /// AI 帧两次升高的最短间隔（和 AISafety 的"每秒每通道最多 +maxStepIncrease"一致）
    static let riseInterval: TimeInterval = AISafety.rampStepSeconds
    /// 调度抖动余量：距上次升高 ≥ riseInterval - riseJitterSlack 就给满升幅，几毫秒的抖动不至于少升 1 档
    static let riseJitterSlack: TimeInterval = 0.05

    private(set) var inFlight = false
    private(set) var pending: Data?
    /// pending 的升幅上限；nil = 不限（手动、技能、视频）
    private var pendingMaxRise: Int?
    /// 最近一笔发出的 0x08 帧的四通道强度（限速基准）；nil 按全 0 算
    private(set) var baseline: [Int]?
    /// 最近一次实际发出升高的时间（调用方的单调时钟）；nil = 还没升过 / 断链重置后
    private(set) var lastRiseAt: TimeInterval?

    mutating func submit(_ frame: Data, maxRise: Int? = nil, now: TimeInterval? = nil) -> Action {
        if inFlight {
            pending = frame
            pendingMaxRise = maxRise
            return .coalesced
        }
        return .write(markWritten(frame, maxRise: maxRise, now: now))
    }

    /// 在途那笔有了结果。canSend 为 false 时丢掉待发帧；返回值是现在要写的下一帧（已标记在途、已限速）
    mutating func writeFinished(canSend: Bool, now: TimeInterval? = nil) -> Data? {
        inFlight = false
        guard let next = pending else { return nil }
        let rise = pendingMaxRise
        pending = nil
        pendingMaxRise = nil
        guard canSend else { return nil }
        return markWritten(next, maxRise: rise, now: now)
    }

    mutating func dropPending() {
        pending = nil
        pendingMaxRise = nil
    }

    /// 停止帧对确认后设备在 0：之后的限速从 0 算（上次升高的时间保留：停了马上再升也要隔够）
    mutating func resetBaseline() { baseline = nil }

    mutating func reset() {
        inFlight = false
        dropPending()
        baseline = nil
        lastRiseAt = nil
    }

    private mutating func markWritten(_ frame: Data, maxRise: Int?, now: TimeInterval?) -> Data {
        let base = baseline ?? [0, 0, 0, 0]
        var out = frame
        if let rise = maxRise {
            var since: TimeInterval?
            if let n = now, let last = lastRiseAt { since = n - last }
            out = Self.limitRise(frame, from: base,
                                 maxRise: Self.allowedRise(maxRise: rise, sinceLastRise: since),
                                 maxLevel: Self.limitedMaxLevel)
        }
        inFlight = true
        let levels = BCProtocol.manualLevels(out)
        if let n = now, let lv = levels, (0..<4).contains(where: { lv[$0] > base[$0] }) {
            lastRiseAt = n
        }
        baseline = levels
        return out
    }

    /// 距上次实际升高 elapsed 秒时每通道最多还能升多少（第二轮审查 M2）：
    /// 满 riseInterval（扣抖动余量）给满 maxRise，不到就按比例向下取整，
    /// 所以任意一段时间里的总升幅不超过 maxRise × 秒数（加抖动余量）。
    /// elapsed 为 nil（没有时间信息，或还没升过）时不按时间限；倒退/NaN 按 0
    static func allowedRise(maxRise: Int, sinceLastRise elapsed: TimeInterval?) -> Int {
        let step = max(0, maxRise)
        guard let e = elapsed else { return step }
        if e >= riseInterval - riseJitterSlack { return step }
        guard e > 0 else { return 0 }
        return min(step, Int((Double(step) * e / riseInterval).rounded(.down)))
    }

    /// 0x08 帧每通道最多比 base 高 maxRise、且不超过 maxLevel（降低不受限）；不是 0x08 帧原样返回（AI 只发 0x08）
    static func limitRise(_ frame: Data, from base: [Int], maxRise: Int, maxLevel: Int? = nil) -> Data {
        guard let target = BCProtocol.manualLevels(frame) else { return frame }
        let step = max(0, maxRise)
        let cap = max(0, maxLevel ?? BCProtocol.maxManualLevel)
        let limited = (0..<4).map { (i: Int) -> Int in
            let from = i < base.count ? base[i] : 0
            return min(target[i], from + step, cap)
        }
        guard limited != target else { return frame }
        let b = [UInt8](frame)
        let tail = UInt16(b[7]) << 8 | UInt16(b[8])
        return BCProtocol.manualFrame(channels: limited, tail: tail)
    }
}

/// 写入回执按 FIFO 配对（L1）。某个回执丢了（不是迟到）会让之后的配对永久错位，停止帧对永远凑不齐。
/// 新一轮停止帧对发出前，如果队里剩下的全是已超时的停止帧，就清空重新对齐。
/// 理由：ATT 写请求是串行的，后面任何一笔的回执都意味着前面的已经处理完；清空后可能被误配的
/// 只会是更早那几笔停止帧的迟到回执（同样是停止帧，在最后一笔输出之后发出），不会把输出帧的回执当成停止确认。
/// 队里还有输出帧（哪怕已超时）或还没超时的条目就不清：宁可确认不了、走 30 秒锁存。
enum WriteAckFIFO {
    static func canRealign(_ entries: [(isStop: Bool, timedOut: Bool)]) -> Bool {
        !entries.isEmpty && entries.allSatisfy { $0.isStop && $0.timedOut }
    }
}

/// 手动页空闲停机（L7 / M3）：心跳只证明界面活着，不证明有人在操作。
/// 上次停止以来发过输出、且这么久没有任何操作就停止。
enum ManualIdle {
    static let timeoutSeconds: TimeInterval = 300

    static func expired(now: TimeInterval, lastInteraction: TimeInterval, outputSinceStop: Bool) -> Bool {
        outputSinceStop && now - lastInteraction >= timeoutSeconds
    }
}

/// 停止相关的时限（第二轮审查 L2：原来散在 BLEManager 里，CI 编不到、没有检查钉住）。
/// BLEManager 直接引用这里的值；ProtocolChecks 钉住数值和退避序列
enum StopTiming {
    /// 停止帧对两帧之间的间隔（官方 handleSlide：onWriteOrder(0) 后 setTimeout(Tt([0,0,0,0]), 100)）
    static let pairGap: TimeInterval = 0.1
    /// 单笔写入超时（legacy device.py write_timeout_seconds）
    static let writeTimeout: TimeInterval = 5.0
    /// 停止重试退避（legacy watchdog.py retry_initial_seconds / retry_max_seconds）
    static let retryInitial: TimeInterval = 1.0
    static let retryMax: TimeInterval = 30.0
    /// 停止持续这么久仍未确认就拉起操作员锁存（legacy retry_deadline_seconds）
    static let deadline: TimeInterval = 30.0

    /// 退避：1 → 2 → 4 → 8 → 16 → 30 → 30…
    static func nextRetryDelay(after delay: TimeInterval) -> TimeInterval {
        min(max(delay, retryInitial) * 2, retryMax)
    }
}

/// 回到前台时要不要（再）发停止（第二轮审查 M4）。
/// 退避定时器和 30 秒截止在 App 挂起 / 手机睡眠时不走：停止正在退避时回到前台，下一次重发可能还要等最多 30 秒。
/// 所以只要停止还在进行（含退避中、含断开流程的停止），或设备可能仍在输出，就立刻整对重发。
/// 下拉控制中心等 inactive→active（没进过后台）不发（修 CC r2 L1）
enum BackgroundResume {
    static func shouldRequestStop(wasBackground: Bool, linkWritable: Bool,
                                  stopInProgress: Bool, stopNeeded: Bool) -> Bool {
        wasBackground && linkWritable && (stopInProgress || stopNeeded)
    }
}

/// 设备可能仍在输出、链路却没了时自动重连（第三轮 M1）。
/// 之前意外断链 / 蓝牙重新打开 / 被杀后重启只提示"请关闭设备电源"，要等用户自己点"连接"才会发停止帧对。
/// 只连绑定过的那台（retrievePeripherals，不扫描、不弹框，陌生设备照旧必须确认）；连上后 didDiscoverCharacteristicsFor
/// 照常先发一对必须确认的停止帧。用户点"断开"/"强制断开"的那一刻不触发（没有断链回调）；之后蓝牙重新打开或重启 App 时
/// 设备仍可能在输出，照样重连去停。连接失败 / 超时不自动重试（不做重连循环），用户仍可手动点"连接"
enum AutoReconnect {
    static func shouldReconnect(mayBeActive: Bool, poweredOn: Bool, linkIdle: Bool,
                                hasPeripheral: Bool, disconnecting: Bool, hasBondedDevice: Bool) -> Bool {
        mayBeActive && poweredOn && linkIdle && !hasPeripheral && !disconnecting && hasBondedDevice
    }
}

/// 用户确认已物理关机时要不要补发一对冗余停止（第三轮 L3）。
/// 解除锁定会放弃进行中的停止：如果正好在两帧之间的 100ms 里点，0x06 那一帧再也不会发出去。
/// 链路还在就补一对（不报警、不重试、不锁存），不让设备停在只收到半对停止帧的状态
enum PhysicalAck {
    static func shouldResendStop(abandonedStop: Bool, linkWritable: Bool) -> Bool {
        abandonedStop && linkWritable
    }
}
