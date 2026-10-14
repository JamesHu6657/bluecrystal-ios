import Foundation
import CoreBluetooth
import Combine
import UserNotifications
import UIKit
import os

/// mizzzee_0032 的 BLE 连接管理
///
/// Service: 0000FFA0-0000-1000-8000-00805F9B34FB
/// Write:   0000FFA1-0000-1000-8000-00805F9B34FB（Write With Response）
/// Notify:  0000FFA2-0000-1000-8000-00805F9B34FB
///
/// 停止（修 N1/N3/N4）：任何停止（用户停止、看门狗、上限、退后台、进程退出、重连确认、断开）
/// 都是"0x08 停止帧 at(0,255) → 100ms → 0x06 停止帧"一对，照官方迷姬 video.js handleSlide
/// （onWriteOrder(0) 后 setTimeout(Tt([0,0,0,0]), 100)）。两帧都拿到写入回执才算停；
/// 任何一帧失败/超时就整对重发，按 1→2→4→8→16→30 秒退避一直重试到确认；
/// 30 秒仍未确认时拉起操作员锁存，只有用户确认已物理关机才解除（修 M4，legacy watchdog.py）。
/// 停止进行中绝不发非停止帧：期间到来的输出帧先记下，停止确认后再重新走准入。
///
/// 输出准入（修 M2/M3/L5）：手动、技能、视频的每一帧非停止帧都只经过 submitOutput：
/// 锁存/设备可能仍在输出时拒绝；停机状态下开始新一次运行要过冷却和 30 分钟额度检查，
/// 本次最长 min(1200 秒, 剩余额度)，到点自动停止（结构同 legacy limits.py / duty_cycle.py）。
/// 准入顺序是纯决策 OutputAdmission（ProtocolChecks 覆盖，Brain 审查 M3）。
final class BLEManager: NSObject, ObservableObject {

    static let serviceUUID = CBUUID(string: "0000FFA0-0000-1000-8000-00805F9B34FB")
    static let writeUUID = CBUUID(string: "0000FFA1-0000-1000-8000-00805F9B34FB")
    static let notifyUUID = CBUUID(string: "0000FFA2-0000-1000-8000-00805F9B34FB")
    /// 设备名必须完全一致（修 L2：之前"包含"即可）
    static let deviceName = "mizzzee_0032"
    static let bondedDeviceKey = "BlueCrystal.bondedDeviceUUID"

    /// 看门狗：界面心跳超过这么久没来，说明 UI 线程卡死，自动停机
    static let watchdogInterval: TimeInterval = 5.0
    /// 看门狗 / 安全状态刷新周期
    static let watchdogTickInterval: TimeInterval = 1.0
    /// 单笔写入超时（修 L3：与 legacy device.py write_timeout_seconds 一致）。
    /// 只标记、不从队列中间删除（修 D）。数值在 StopTiming（ProtocolChecks 钉住，第二轮审查 L2）
    static let writeTimeout: TimeInterval = StopTiming.writeTimeout
    /// 停止帧对两帧之间的间隔（修 N4：官方 setTimeout(…, 100)）
    static let stopPairGap: TimeInterval = StopTiming.pairGap
    /// 停止重试退避（修 M4：legacy watchdog.py retry_initial_seconds / retry_max_seconds）
    static let stopRetryInitial: TimeInterval = StopTiming.retryInitial
    static let stopRetryMax: TimeInterval = StopTiming.retryMax
    /// 停止持续这么久仍未确认就拉起操作员锁存（legacy retry_deadline_seconds）
    static let stopRetryDeadline: TimeInterval = StopTiming.deadline
    /// 断开时停止迟迟未确认：过这么久才提供"强制断开"（修 M5 / L3：两轮写超时 + 0.5 秒）
    static let forceDisconnectOfferAfter: TimeInterval = writeTimeout * 2 + 0.5
    /// 退后台时最多持有后台任务这么久等停止确认
    static let backgroundStopDeadline: TimeInterval = 20.0

    enum State: String {
        case idle = "未连接"
        case scanning = "扫描中…"
        case connecting = "连接中…"
        case discovering = "发现服务…"
        case ready = "已连接"
        /// 断开流程中：停止帧对还没确认。只发给界面（控件禁用），
        /// bleQueue 内部的 queueState 仍是 ready，停止帧对的重试才能发出去
        case disconnecting = "断开中…"
        case failed = "连接失败"
    }

    /// 给界面看的安全状态（bleQueue 上算好，主线程发布）
    struct SafetyStatus: Equatable {
        /// 正在输出时本次剩余秒数；没在输出时为 nil
        var runRemaining: Int?
        /// 本次运行上限（≤1200 秒，30 分钟额度不够时更短）
        var runAllowed = 0
        /// 冷却剩余秒数
        var cooldownRemaining = 0
        /// 30 分钟滚动窗口剩余额度（秒）
        var budgetRemaining = Int(SafetyLimits.dutyBudgetSeconds)
        /// 额度不够开始新运行时，还要等多久
        var budgetWait = 0
        /// 停止至少失败过一次、仍在重试
        var stopRetrying = false
        /// 需要用户确认设备已物理停止（断链/重启后未确认停止，或停止重试超过 30 秒）
        var needsPhysicalAck = false

        /// 现在不能开始新输出的原因（界面预检用；真正的拦截在 BLEManager.submitOutput）
        var blockReason: String? {
            if needsPhysicalAck { return "设备可能仍在输出：先停止并等确认，或关闭设备电源后点「已物理关机，解除锁定」" }
            if stopRetrying { return "停止尚未得到设备确认，暂不能输出" }
            if runRemaining != nil { return nil }
            if cooldownRemaining > 0 { return "冷却中，还需 \(cooldownRemaining) 秒才能再次输出" }
            if budgetRemaining < Int(SafetyLimits.minRunSeconds) {
                return "30 分钟内累计输出已达 \(Int(SafetyLimits.dutyBudgetSeconds)) 秒上限，还需 \(budgetWait) 秒才能再次输出"
            }
            return nil
        }

        /// 设备区块里的一行说明
        var summary: String {
            if let r = runRemaining { return "本次输出剩余 \(r) 秒（本次上限 \(runAllowed) 秒）" }
            if let reason = blockReason { return reason }
            let maxRun = min(Int(SafetyLimits.maxRunSeconds), budgetRemaining)
            return "单次最长 \(maxRun) 秒；30 分钟内还可输出 \(budgetRemaining) 秒"
        }
    }

    @Published var state: State = .idle
    @Published var lastError: String?
    @Published var lastSentHex: String = "—"
    /// FFA2 最近一条通知的 HEX（修 L1）
    @Published var lastNotifyHex: String = "—"
    /// 单次上限 / 冷却 / 额度 / 停止确认 / 锁存，看门狗每秒刷新
    @Published var safety = SafetyStatus()
    /// 断开时停止迟迟未确认：界面显示"强制断开"（修 M5）
    @Published var forceDisconnectOffered = false
    /// 被动停机代次的主线程镜像（Brain 审查 M5）：AI 执行前读一次，开闸时 bleQueue 上再核对
    @Published private(set) var gateEpoch = 0

    /// 发现未绑定过的设备时弹确认框用
    @Published var pendingDeviceName: String?
    @Published var pendingDeviceUUID: String?
    @Published var showDeviceConfirm = false

    /// 被动停机（看门狗 / 退后台 / 上限 / 写失败 / 输出被拒）后通知 VM：把界面输出归零，附带原因。
    /// VM 收到后只归零 UI，不要再补发停止帧（需要的停止已经由 BLEManager 发出）。
    /// 只在主线程 send，和 gateEpoch 在同一个 block 里更新（第二轮审查 M1：AI VM 直接订阅、同步作废授权）
    let forceZeroOutputs = PassthroughSubject<String?, Never>()

    private static let log = Logger(subsystem: "com.bluecrystal.ios", category: "ble")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pendingPeripheral: CBPeripheral?

    /// 只在 bleQueue 上读写的状态镜像，消除跨线程竞争
    private var queueState: State = .idle

    /// 发送队列串行化，避免 Write With Response 冲突
    private let bleQueue = DispatchQueue(label: "com.bluecrystal.ble")

    // MARK: - 输出闸门（修 N2）
    /// 停机（断开 / 退后台 / 看门狗 / 上限 / 写失败 / 输出被拒）后锁死：自动帧（节流尾帧、视频 tick）不许再出去。
    /// 只有用户主动操作（send / 视频页点"播放"）才能重新打开；停止不开闸（修 C）。
    /// 冷启动时闸门是关的（修 Factory L1）
    private var outputLocked = true
    /// 被动停机代次（M5，只在 bleQueue 上）：每次被动停机/断链 +1。带代次的开闸请求对不上就不开闸
    private var queueGateEpoch = 0
    /// 断开流程进行中：除停止帧对外一律拒发（修 N1）
    private var disconnecting = false
    private var disconnectGen = 0

    // MARK: - 写入回执 FIFO（修 #3、D）
    private enum WriteKind {
        case output    // 非停止帧（手动 / 技能 / 视频）
        case stopZero  // 停止帧对的 0x08 归零帧
        case stopFrame // 停止帧对的 0x06 停止帧
    }
    private struct PendingWrite {
        let id: Int
        let hex: String
        let kind: WriteKind
        /// 超时标记：结果已按失败处理，迟到的回执直接丢弃。
        /// 绝不从队列中间删除条目，否则后面的回执会全部错位
        var timedOut: Bool
    }
    /// 发出未回执的写入，按发出顺序排队；回执按 FIFO 配对
    /// （CoreBluetooth 对同一特征值的 withResponse 写是串行回调的，顺序有保证）
    private var pendingWrites: [PendingWrite] = []
    private var writeSeq = 0
    /// 最近一次发出的写入（单调时间、写入 id、HEX）：只给 FFA2 通知日志做对照（L6）
    private var lastWriteLog: (at: TimeInterval, id: Int, hex: String)?

    // MARK: - 停止帧对（修 N1/N3/N4/M4）
    private enum StopResult {
        /// 两帧都确认
        case confirmed
        /// 冗余停止（设备之前已确认停着）没确认：不报警、不重试（修 L4）
        case idleUnconfirmed
        /// 用户确认已物理关机
        case acknowledged
        /// 断链 / 强制断开，停止没有结果
        case aborted
    }
    private struct StopOp {
        let gen: Int
        let startedAt: TimeInterval
        /// 请求时设备可能在输出（或断开流程要求必须确认）；false 时失败不报警、不重试（修 L4）
        var needed: Bool
        /// 全零输出触发的停止：确认后设备停了，但本次运行不结束（不记账、不冷却、不锁闸）。
        /// 任何真正的停止请求并入时置为 false；输出被拒、拉起锁存（被动停机）时同样置为 false（第二轮审查 L1）
        var keepRun: Bool
        var completions: [(StopResult) -> Void]
        var pair = StopPairAttempt()
        var attempts = 0
        var failures = 0
        var zeroId = -1
        var stopId = -1
        var retryDelay: TimeInterval
        /// 本次停止已经拉起过操作员锁存
        var latched = false

        init(gen: Int, startedAt: TimeInterval, needed: Bool, keepRun: Bool,
             completions: [(StopResult) -> Void]) {
            self.gen = gen
            self.startedAt = startedAt
            self.needed = needed
            self.keepRun = keepRun
            self.completions = completions
            self.retryDelay = BLEManager.stopRetryInitial
        }
    }
    private var stopOp: StopOp?
    private var stopGen = 0
    /// 停止进行中到来的输出帧（最新的覆盖旧的）：停止确认后重新走 submitOutput
    private var deferredFrame: Data?
    /// deferredFrame 的升幅上限（M1），和 deferredFrame 一起设置
    private var deferredMaxRise: Int?
    /// 非停止帧最多一笔在途，在途期间只留最新一帧（M2）；AI 帧按实际发出的上一帧限升幅（Brain 审查 M1）、
    /// 按距上次实际升高的时间限升幅并压到 70（第二轮审查 M2）
    private var outputWrites = OutputWriteCoalescer()
    /// 运行中收到全零输出、已为它发了停止帧对，之后还没有非零帧（见 OutputGate）
    private var zeroHeld = false

    // MARK: - 运行上限 / 占空比（修 M2/M3）
    private let ledger = DutyCycleLedger()
    /// 运行代次：每次开始/结束运行 +1，作废旧的到点定时器
    private var runGen = 0
    static let ledgerKey = "bc.dutyCycleLedger"

    // MARK: - 看门狗（心跳版，修 N1）
    /// 界面心跳（单调时钟，修 L7）：视频页 tick（100ms）、手动页心跳定时器（1s）调用
    private var lastHeartbeat: TimeInterval?
    /// 当前连接上有非零/输出帧在设备上生效（停止帧对确认后才清零）
    private var isActive = false {
        didSet { persistMayBeActive() } // 修 CC M2：被杀/崩溃后重启也要知道设备可能还在输出
    }
    /// 停止至少失败过一次、还没确认（重试中）
    private var stopUnconfirmed = false {
        didSet { persistMayBeActive() }
    }
    /// 当前红字是不是停止相关的提示：之后停止确认成功时自动清掉
    private var stopErrorShown = false
    /// 当前红字是冷却/额度提示：条件解除后自动清掉
    private var lastLimitText: String?
    /// 修 Factory H1：上次连接结束时设备可能还在输出（断链 / 蓝牙关闭 / 强制断开 / 进程被杀）。
    /// 跨连接、跨进程保留；重新连上后停止帧对确认成功，或用户确认已物理关机才清除。
    /// 期间拒绝新的输出（修 L5）
    private var deviceMayBeActive = false {
        didSet { persistMayBeActive() }
    }
    static let mayBeActiveKey = "bc.deviceMayBeActive"
    /// 操作员锁存（修 M4，legacy SafetyStateStore）：停止 30 秒仍未确认后置位并持久化，
    /// 只有用户确认已物理关机才清除；期间拒绝新的输出
    private var physicalAckRequired = false {
        didSet { UserDefaults.standard.set(physicalAckRequired, forKey: Self.physicalAckKey) }
    }
    static let physicalAckKey = "bc.physicalStopAckRequired"
    /// App 在后台：此时发生"设备可能仍在输出"要发本地通知，红字用户看不到（修 CC M1）
    private var appInBackground = false
    static let mayBeActiveMsg = "连接已断开，设备可能仍在输出，请关闭设备电源"
    /// 连接代次：连接超时只对本次连接有效（修 Factory L6）
    private var connectGen = 0
    static let connectTimeout: TimeInterval = 10
    private var notificationAuthRequested = false
    private var lastPublishedSafety: SafetyStatus?

    /// 扫描代次：防止旧扫描的超时把新扫描提前停掉（修 N9）
    private var scanGen = 0

    /// 本轮扫描中用户点"取消"拒绝过的设备 UUID：不再弹确认框（修 E）。
    /// 用户手动点"连接"重新扫描时会清空。
    private var rejectedUUIDs = Set<String>()

    /// 单调时钟（修 L7：安全计时不受改系统时间影响）。
    /// 第二轮审查 M3：和账本用同一个睡眠期间也走的时钟（看门狗有用 ledger.openStart 兜底比较，不能混用两种时钟）
    private static func now() -> TimeInterval { SafetyClock.continuousSeconds() }

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        bleQueue.sync {
            // 恢复后立即保存新锚点、未知状态和已验证时长下界。
            if let data = defaults.data(forKey: Self.ledgerKey) {
                ledger.restore(from: data)
                persistLedger()
            }
            ledger.onChange = { [weak self] in self?.persistLedger() }
            // 未知时长必须走物理停机确认；即使之后停止帧对成功也不清除此锁存。
            physicalAckRequired = defaults.bool(forKey: Self.physicalAckKey) || ledger.openElapsedUnknown
            // 修 CC M2：上次进程结束时设备可能还在输出，启动即提示
            if defaults.bool(forKey: Self.mayBeActiveKey) || ledger.hasOpenRun {
                deviceMayBeActive = true
                DispatchQueue.main.async { [weak self] in self?.lastError = Self.mayBeActiveMsg }
            }
        }
        central = CBCentralManager(delegate: self, queue: bleQueue)
        startWatchdog()
        // 修 CC M2：从多任务界面划掉 App 不一定收到 .background，退出前尽力发停止帧对
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: UIApplication.willTerminateNotification, object: nil)
    }

    /// 持久化"设备可能仍在输出"；属性 didSet 调用（bleQueue 上），UserDefaults 线程安全
    private func persistMayBeActive() {
        // 修 CC r2 L5：值变了才写
        let v = isActive || stopUnconfirmed || deviceMayBeActive
        guard v != lastPersistedMayBeActive else { return }
        lastPersistedMayBeActive = v
        UserDefaults.standard.set(v, forKey: Self.mayBeActiveKey)
    }
    private var lastPersistedMayBeActive: Bool?

    private func persistLedger() {
        if let data = ledger.snapshotData() {
            UserDefaults.standard.set(data, forKey: Self.ledgerKey)
        }
    }

    /// 进程即将退出：同步等最多 1.5 秒，让停止帧对尽量拿到回执（修 CC M2、N3）
    @objc private func appWillTerminate() {
        let done = DispatchSemaphore(value: 0)
        bleQueue.async { [weak self] in
            guard let self = self, self.canWrite else { done.signal(); return }
            self.outputLocked = true
            self.deferredFrame = nil
            self.requestStop(needed: self.stopNeeded) { _ in done.signal() }
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    // MARK: - 对外接口（可在任意线程调用）

    /// 界面心跳：VideoSyncPlayer 的 tick、手动页心跳定时器调用
    func heartbeat() {
        bleQueue.async { [weak self] in
            self?.lastHeartbeat = Self.now()
        }
    }

    func startScan() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.beginScan(clearRejected: true)
        }
    }

    /// 实际开始扫描；clearRejected=false 时保留本轮拒绝过的设备（修 E）
    /// 调用方保证在 bleQueue 上
    private func beginScan(clearRejected: Bool) {
        // 修 Factory H2：只有空闲/失败且没有外设时才允许扫描。
        // 已连接、发现服务中、断开中点"连接"都不能把状态机打回扫描/空闲
        guard queueState == .idle || queueState == .failed,
              peripheral == nil, !disconnecting else { return }
        guard central.state == .poweredOn else {
            setError("蓝牙未就绪")
            return
        }
        scanGen += 1
        let gen = scanGen
        if clearRejected {
            // 用户手动重新扫描：允许之前拒绝过的设备再次弹框
            rejectedUUIDs.removeAll()
        }
        clearError()
        updateState(.scanning)
        // 不按 Service UUID 过滤：mizzzee_0032 不在广播包里带 FFA0，过滤会扫不到
        central.scanForPeripherals(withServices: nil, options: nil)
        // 10 秒超时：只对本次扫描有效
        bleQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self,
                  self.scanGen == gen,
                  self.queueState == .scanning else { return }
            self.central.stopScan()
            // 修 E 小尾巴：附近只有被拒绝过的设备时，文案不能说"没找到"
            if self.rejectedUUIDs.isEmpty {
                self.setError("未找到 mizzzee_0032，请确认设备开机且未被官方 App 占用")
            } else {
                self.setError("没有找到其他 mizzzee_0032（已跳过你取消的设备），需要连它请重新点\"连接\"")
            }
        }
    }

    /// 用户在确认框点了"连接"
    func confirmPendingDevice() {
        bleQueue.async { [weak self] in
            guard let self = self, let p = self.pendingPeripheral else { return }
            self.pendingPeripheral = nil
            // 修 Factory H2：已有外设时不许覆盖它的引用
            guard self.peripheral == nil else {
                DispatchQueue.main.async {
                    self.pendingDeviceName = nil
                    self.pendingDeviceUUID = nil
                    self.showDeviceConfirm = false
                }
                return
            }
            // 记住这次连的设备，下次自动连
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.bondedDeviceKey)
            DispatchQueue.main.async {
                self.pendingDeviceName = nil
                self.pendingDeviceUUID = nil
                self.showDeviceConfirm = false
            }
            self.central.stopScan()
            self.peripheral = p
            self.clearError()
            self.updateState(.connecting)
            self.central.connect(p, options: nil)
            self.scheduleConnectTimeout(for: p)
        }
    }

    /// 用户在确认框点了"取消"：记住这台，本轮不再弹框，继续扫描找别的设备（修 E）
    func cancelPendingDevice() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            if let p = self.pendingPeripheral {
                self.rejectedUUIDs.insert(p.identifier.uuidString)
            }
            self.pendingPeripheral = nil
            DispatchQueue.main.async {
                self.pendingDeviceName = nil
                self.pendingDeviceUUID = nil
                self.showDeviceConfirm = false
            }
            // 之前停了扫描，继续扫别的设备；不清掉刚拒绝的 UUID
            if self.queueState == .idle, self.central.state == .poweredOn {
                self.beginScan(clearRejected: false)
            }
        }
    }

    /// 断开（修 M5）：先发停止帧对，两帧都确认后才断开；确认不了就一直重试，绝不静默断开。
    /// 迟迟确认不了时界面提供"强制断开"（需要用户在警告框里确认）
    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.canWrite else {
                // 还没连好（连接中/发现服务中）：没有发过任何帧，直接取消
                self.finishDisconnect(forced: false)
                return
            }
            guard !self.disconnecting else { return } // 已在断开中，不重复发起
            self.disconnecting = true
            self.disconnectGen += 1
            let gen = self.disconnectGen
            self.outputLocked = true
            self.deferredFrame = nil
            self.notifyForceZero(nil)
            DispatchQueue.main.async { [weak self] in self?.state = .disconnecting }
            // 断开前的停止必须确认：needed 恒为 true（失败时重试，不按冗余停止放过）
            self.requestStop(needed: true) { [weak self] result in
                guard let self = self, self.disconnecting, self.disconnectGen == gen else { return }
                switch result {
                case .confirmed, .acknowledged:
                    self.finishDisconnect(forced: false)
                case .idleUnconfirmed, .aborted:
                    // needed=true 不会出现 idleUnconfirmed；aborted 由断链 / 强制断开流程自己收尾
                    break
                }
            }
            guard let stopIdentity = self.stopOp?.gen else { return }
            self.bleQueue.asyncAfter(deadline: .now() + Self.forceDisconnectOfferAfter) { [weak self] in
                guard let self = self, self.disconnecting, self.disconnectGen == gen,
                      let op = self.stopOp, op.gen == stopIdentity else { return }
                self.showStopError("断开前的停止还没有得到设备确认，设备可能仍在输出。App 会继续重试停止；也可以「强制断开」，但断开后 App 无法再停止设备，请立即关闭设备电源")
                DispatchQueue.main.async { [weak self] in self?.forceDisconnectOffered = true }
            }
        }
    }

    /// 用户在警告框里确认了"强制断开"（修 M5）：停止未确认就断开，记下"设备可能仍在输出"
    func forceDisconnect() {
        bleQueue.async { [weak self] in
            guard let self = self, self.disconnecting else { return }
            Self.log.error("用户强制断开，停止未确认")
            self.finishDisconnect(forced: true)
        }
    }

    /// 用户确认设备已物理关机（修 M4/L5，legacy acknowledge_physical_stop）：
    /// 解除锁存，结束本次运行（未知时长耗尽完整窗口额度），放弃仍在重试的停止
    func acknowledgePhysicalStop() {
        bleQueue.async { [weak self] in
            guard let self = self, self.physicalAckRequired || self.deviceMayBeActive else { return }
            Self.log.notice("用户确认设备已物理关机")
            self.physicalAckRequired = false
            self.isActive = false
            self.zeroHeld = false
            self.stopUnconfirmed = false
            self.runGen += 1
            self.ledger.end()
            self.clearMayBeActive()
            self.outputLocked = true
            self.outputWrites.dropPending()
            self.outputWrites.resetBaseline()
            if self.stopErrorShown {
                self.stopErrorShown = false
                DispatchQueue.main.async { [weak self] in self?.lastError = nil }
            }
            if let op = self.stopOp {
                self.stopOp = nil
                self.deferredFrame = nil
                op.completions.forEach { $0(.acknowledged) }
            }
            self.publishSafety()
        }
    }

    /// App 退后台/锁屏时的紧急停止（修 Factory M1：异步）。
    /// 立刻锁闸并通知界面归零，发停止帧对；确认、或最多 20 秒后回调 completion，
    /// 调用方据此结束后台任务。没确认时发本地通知提示关电源。completion 在主线程回调，只回调一次。
    func emergencyStop(completion: @escaping () -> Void) {
        bleQueue.async { [weak self] in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async(execute: completion)
            }
            guard let self = self else { finish(); return }
            self.appInBackground = true
            // 修 Factory M2：不管停止帧发不发得出去，都先锁闸并让界面归零
            self.outputLocked = true
            self.deferredFrame = nil
            self.notifyForceZero("App 已退到后台，输出已停止")
            guard self.canWrite else {
                // 发不出去：设备上还有输出就明确提示（修 Factory M2）
                if self.isActive {
                    self.reportStopUnconfirmed()
                    self.postStopFailureNotification(then: finish)
                } else {
                    finish()
                }
                return
            }
            let needed = self.stopNeeded
            self.requestStop(needed: needed) { [weak self] result in
                switch result {
                case .confirmed, .idleUnconfirmed, .acknowledged:
                    finish()
                case .aborted:
                    if needed, let self = self {
                        self.postStopFailureNotification(then: finish)
                    } else {
                        finish()
                    }
                }
            }
            // 后台时间有限：到点还没确认就提示关电源并结束后台任务；重试在 App 被唤醒时继续
            self.bleQueue.asyncAfter(deadline: .now() + Self.backgroundStopDeadline) { [weak self] in
                guard !finished else { return }
                guard let self = self else { finish(); return }
                if needed, self.stopOp != nil {
                    self.postStopFailureNotification(then: finish)
                } else {
                    finish()
                }
            }
        }
    }

    /// 回到前台（修 Factory M1）：设备可能还在输出时补发一对停止帧。
    /// 第二轮审查 M4：停止还在进行（退避中、含断开流程的停止）也立刻整对重发——退避定时器在挂起/睡眠期间不走，
    /// 之前这里 stopOp != nil 就返回，用户回到前台还要等退避最多 30 秒。并入进行中的停止时 requestStop 在退避阶段立即重发
    func resumeFromBackground() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            // 修 CC r2 L1：只有真的从后台回来才补发；下拉控制中心等 inactive→active 不发
            let wasBackground = self.appInBackground
            self.appInBackground = false
            guard BackgroundResume.shouldRequestStop(wasBackground: wasBackground, linkWritable: self.canWrite,
                                                     stopInProgress: self.stopOp != nil,
                                                     stopNeeded: self.stopNeeded) else { return }
            self.requestStop(needed: self.stopNeeded)
        }
    }

    // MARK: - 输出（全部经过 submitOutput 准入）

    /// 用户主动发送的帧（手动页滑杆前沿帧、技能预设、AI 每条回复的第一帧）：会重新开闸。
    /// 全零帧在运行中会换成停止帧对、运行继续计时（见 OutputGate）；结束运行请用 sendStop。
    /// maxRise：AI 帧的每通道升幅上限，按实际发出的上一帧再夹一次（M1）、按时间限并压到 70（第二轮 M2）；nil = 不限。
    /// epoch：AI 执行前读到的 gateEpoch，中间发生过被动停机就不开闸（M5）；nil = 用户直接操作
    func send(frame: Data, maxRise: Int? = nil, epoch: Int? = nil) {
        bleQueue.async { [weak self] in
            self?.submitOutput(frame, opensGate: true, maxRise: maxRise, epoch: epoch)
        }
    }

    /// 节流尾帧 / AI 后续步骤：不开闸（修 N2 —— 停机后排队的尾帧必须丢掉）
    func sendThrottled(frame: Data, maxRise: Int? = nil) {
        bleQueue.async { [weak self] in
            self?.submitOutput(frame, opensGate: false, maxRise: maxRise)
        }
    }

    /// 视频 tick：0x08 帧（修 N2），不开闸（修 C）。
    /// 只有用户点"播放"（userResumeOutput）才能开闸
    func sendTick(levels: [Int]) {
        bleQueue.async { [weak self] in
            self?.submitOutput(BCProtocol.videoFrame(levels: levels), opensGate: false)
        }
    }

    /// 用户在视频页点了"播放"、或 AI 开始执行一条回复：显式打开输出闸门（修 C）。
    /// AI 带 epoch：执行前检查之后发生过被动停机就不开（M5，不再只靠冷却兜底）
    func userResumeOutput(epoch: Int? = nil) {
        bleQueue.async { [weak self] in
            guard let self = self,
                  OutputGate.mayOpen(requestEpoch: epoch, currentEpoch: self.queueGateEpoch) else { return }
            self.outputLocked = false
        }
    }

    /// 停止（用户停止、暂停、切 Tab、切模式、播完）：发停止帧对并锁闸（M3）。
    /// 不受闸门限制，也不打开闸门（修 C 备注）：它会被外部暂停/播完等自动路径调用。
    /// 之后只有用户操作（send / userResumeOutput）能重新开闸，排着的尾帧、tick 都会被丢掉
    func sendStop() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.outputLocked = true
            // 停止之前排着的输出请求作废
            self.deferredFrame = nil
            self.outputWrites.dropPending()
            guard self.canWrite else { return }
            self.requestStop(needed: self.stopNeeded)
        }
    }

    // MARK: - 内部（bleQueue 上）

    private var canWrite: Bool {
        peripheral != nil && writeChar != nil && queueState == .ready
    }

    /// 设备可能在输出、需要确认的停止（修 L4：否则只是冗余停止）
    private var stopNeeded: Bool {
        isActive || stopUnconfirmed || deviceMayBeActive || physicalAckRequired || ledger.hasOpenRun
    }

    /// 唯一的输出准入点（修 M2/M3/L5/N1）：手动、技能、视频、AI 的每一帧非停止帧都从这里过。
    /// 准入顺序见 OutputAdmission（纯决策，ProtocolChecks 覆盖）
    private func submitOutput(_ data: Data, opensGate: Bool, maxRise: Int? = nil, epoch: Int? = nil) {
        // 后台期间（emergencyStop 之后、resumeFromBackground 之前）任何输出都不许开闸，
        // 主线程上迟到的回复/定时器在这里兜底
        let linkWritable = canWrite && !disconnecting && !appInBackground
        // M5：带代次的开闸请求，中间发生过被动停机就不开
        if linkWritable, opensGate, OutputGate.mayOpen(requestEpoch: epoch, currentEpoch: queueGateEpoch) {
            outputLocked = false
        }
        let decision = OutputAdmission.decide(OutputAdmission.Inputs(
            linkWritable: linkWritable,
            gateOpen: !outputLocked,
            mayStillBeOutputting: physicalAckRequired || deviceMayBeActive,
            stopInProgress: stopOp != nil,
            stopFailed: (stopOp?.failures ?? 0) > 0,
            allZero: BCProtocol.isAllZeroOutput(data),
            isActive: isActive,
            zeroHeld: zeroHeld))
        switch decision {
        case .drop, .skipIdleZero, .alreadyZeroed:
            return
        case .rejectMayBeActive:
            // 修 L5 / M4：设备可能仍在输出、或锁存未解除：确认停止前不许新的输出
            rejectOutput("设备可能仍在输出：请先按「停止」并等设备确认，或关闭设备电源后点「已物理关机，解除锁定」")
        case .rejectStopUnconfirmed:
            rejectOutput("停止尚未得到设备确认，暂不能输出")
        case .deferUntilStopped:
            // 修 N1/N4：停止帧对还在路上，期间不许插入非停止帧；等它确认后再按这次请求处理
            deferredFrame = data
            deferredMaxRise = maxRise
        case .zeroStopPair:
            // H1 / L5：运行中的全零输出换成完整停止帧对、运行继续
            zeroHeld = true
            requestStop(needed: true, keepRun: true)
        case .write(let startsRun):
            if startsRun {
                // 修 M2/M3：停机状态下开始新一次运行：冷却 + 30 分钟额度，本次最长 min(1200 秒, 剩余额度)
                if let denial = ledger.checkAdmissible() {
                    rejectOutput(Self.denialText(denial))
                    return
                }
                guard let allowed = ledger.begin() else {
                    rejectOutput("暂时不能输出")
                    return
                }
                armRunDeadline(after: allowed)
                // 从开始输出算心跳，避免旧心跳让看门狗立刻误判
                lastHeartbeat = Self.now()
            }
            zeroHeld = false
            writeOutput(data, maxRise: maxRise)
            // 修 F：isActive 只在停止帧对确认后才清零
            isActive = true
            publishSafety()
        }
    }

    /// 非停止帧经过合并器：没有在途写入就立刻发，否则只记下最新一帧（M2）；
    /// AI 帧按实际发出的上一帧限升幅（M1），并按距上次实际升高的时间限幅、压到 70（第二轮审查 M2）
    private func writeOutput(_ data: Data, maxRise: Int?) {
        guard case .write(let frame) = outputWrites.submit(data, maxRise: maxRise, now: Self.now()) else { return }
        if enqueueWrite(frame, kind: .output) < 0 { outputWrites.reset() }
    }

    /// 在途的非停止帧有了结果（回执 / 失败 / 超时）：条件仍允许时发合并下来的最新一帧
    private func outputWriteSettled() {
        let canSend = canWrite && !outputLocked && !disconnecting && !appInBackground && stopOp == nil
            && !physicalAckRequired && !deviceMayBeActive && isActive
        guard let next = outputWrites.writeFinished(canSend: canSend, now: Self.now()) else { return }
        if enqueueWrite(next, kind: .output) < 0 { outputWrites.reset() }
    }

    private static func denialText(_ denial: DutyCycleLedger.Denial) -> String {
        switch denial {
        case .cooldown(let s):
            return "冷却中，还需 \(Int(s.rounded(.up))) 秒才能再次输出（每次停止后至少休息 \(Int(SafetyLimits.minCooldownSeconds)) 秒，且不少于上次输出时长的一半）"
        case .budget(let s):
            return "30 分钟内累计输出已达 \(Int(SafetyLimits.dutyBudgetSeconds)) 秒上限，还需 \(Int(s.rounded(.up))) 秒才能再次输出"
        case .openRun:
            return "上一次输出还没有确认停止，请先停止"
        }
    }

    /// 输出请求被拒：锁闸、界面归零并说明原因。
    /// 第二轮审查 L1：被拒也是被动停机（VM 收到 forceZero 就当已停止）。进行中的全零停止（keepRun）要升级成真正的停止：
    /// 确认后结束本次运行、记账并冷却，不再留下"设备在 0、运行还开着、闸门锁着"的半截状态
    /// （之前下一条 AI 回复还能不经冷却接着输出，或者心跳停了之后报一条误导的"看门狗"）
    private func rejectOutput(_ msg: String) {
        outputLocked = true
        deferredFrame = nil
        stopOp?.keepRun = false
        outputWrites.dropPending()
        notifyForceZero(msg)
        showLimitError(msg)
    }

    /// 入队并发送一帧，返回该笔写入的 id（发不出去返回 -1）
    @discardableResult
    private func enqueueWrite(_ data: Data, kind: WriteKind) -> Int {
        guard let p = peripheral, let c = writeChar, queueState == .ready else { return -1 }
        writeSeq += 1
        let id = writeSeq
        let hex = BCProtocol.hex(data)
        pendingWrites.append(PendingWrite(id: id, hex: hex, kind: kind, timedOut: false))
        lastWriteLog = (at: Self.now(), id: id, hex: hex)
        p.writeValue(data, for: c, type: .withResponse)
        // 每笔写入单独超时（修 D）
        bleQueue.asyncAfter(deadline: .now() + Self.writeTimeout) { [weak self] in
            self?.writeTimedOut(id: id)
        }
        return id
    }

    /// 发起一次停止，或并入正在进行的停止（修 N1/N3/N4）。
    /// keepRun 只给全零输出用（见 OutputGate）；其他停止都结束本次运行
    private func requestStop(needed: Bool, keepRun: Bool = false, completion: ((StopResult) -> Void)? = nil) {
        // 停止帧排在所有待发输出前面：合并器里没发出去的帧直接作废（M2）
        outputWrites.dropPending()
        if var op = stopOp {
            let becameNeeded = needed && !op.needed
            op.needed = op.needed || needed
            op.keepRun = op.keepRun && keepRun
            if let c = completion { op.completions.append(c) }
            stopOp = op
            if becameNeeded { armStopDeadline(gen: op.gen, startedAt: op.startedAt) }
            // 正在退避等待：新的停止请求立刻整对重发，不用等
            if op.pair.phase == .backoff { startStopAttempt() }
            return
        }
        guard canWrite else {
            completion?(.aborted)
            return
        }
        stopGen += 1
        stopOp = StopOp(gen: stopGen, startedAt: Self.now(), needed: needed, keepRun: keepRun,
                        completions: completion.map { [$0] } ?? [])
        if let op = stopOp, needed { armStopDeadline(gen: op.gen, startedAt: op.startedAt) }
        startStopAttempt()
    }

    /// 独立于写超时和退避，在本次停止的 30s 截止点锁存（F4）。
    private func armStopDeadline(gen: Int, startedAt: TimeInterval) {
        let delay = max(0, Self.stopRetryDeadline - (Self.now() - startedAt))
        bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, var op = self.stopOp, op.gen == gen,
                  op.needed, !op.latched else { return }
            op.latched = true
            // 第二轮审查 L1：锁存是被动停机，全零停止也升级成真正的停止（确认后结束运行）
            op.keepRun = false
            self.stopOp = op
            self.physicalAckRequired = true
            self.outputLocked = true
            self.deferredFrame = nil
            self.notifyForceZero(nil)
            self.showStopError("停止超过 \(Int(Self.stopRetryDeadline)) 秒仍未得到设备确认：请立即关闭设备电源，确认设备已停止后点「已物理关机，解除锁定」（App 会继续发送停止）")
            if self.appInBackground { self.postStopFailureNotification(then: {}) }
            self.publishSafety()
        }
    }

    /// 发一轮停止帧对：先 0x08 归零帧，100ms 后 0x06 停止帧（修 N4）
    private func startStopAttempt() {
        guard var op = stopOp else { return }
        guard canWrite else {
            abortStopOp()
            return
        }
        op.attempts += 1
        op.pair = StopPairAttempt()
        op.stopId = -1
        // L1：上一轮剩下的全是已超时的停止帧（回执丢了）时清空重新对齐，避免之后的配对永久错位
        if WriteAckFIFO.canRealign(pendingWrites.map { (isStop: $0.kind != .output, timedOut: $0.timedOut) }) {
            let dropped = pendingWrites.count
            Self.log.notice("写入回执队列重新对齐：丢弃 \(dropped) 笔已超时的停止帧")
            pendingWrites.removeAll()
        }
        op.zeroId = enqueueWrite(BCProtocol.manualZeroFrame, kind: .stopZero)
        stopOp = op
        let gen = op.gen
        let attempt = op.attempts
        bleQueue.asyncAfter(deadline: .now() + Self.stopPairGap) { [weak self] in
            self?.sendStopFrameOfPair(gen: gen, attempt: attempt)
        }
        publishSafety()
    }

    private func sendStopFrameOfPair(gen: Int, attempt: Int) {
        // 首帧即使提前失败仍发 0x06；只丢弃已经作废的连接/操作/轮次（F1）。
        guard var op = stopOp, op.gen == gen, op.attempts == attempt, op.pair.phase == .gap,
              canWrite else { return }
        op.stopId = enqueueWrite(BCProtocol.stopFrame, kind: .stopFrame)
        let earlyFailure = op.pair.didSendStopFrame()
        stopOp = op
        if let reason = earlyFailure { stopAttemptFailed(reason: reason) }
    }

    /// 本轮有一帧失败/超时：gap 中先记下错误，第二帧发出后整对按退避重发。
    private func stopAttemptFailed(reason: String) {
        guard var op = stopOp, op.pair.phase != .backoff else { return }
        let canRetry = op.pair.recordFailure(reason)
        stopOp = op
        guard canRetry else { return }
        guard op.needed else {
            // 修 L4：设备已确认停着时的冗余停止（切 Tab、切模式等）没确认：不报警、不重试
            Self.log.info("冗余停止未确认：\(reason, privacy: .public)")
            finishStopOp(.idleUnconfirmed)
            return
        }
        op.failures += 1
        op.pair.phase = .backoff
        stopUnconfirmed = true
        let delay = op.retryDelay
        op.retryDelay = StopTiming.nextRetryDelay(after: op.retryDelay)
        stopOp = op
        Self.log.error("停止帧对未确认（\(reason, privacy: .public)），第 \(op.failures) 次失败，\(delay) 秒后重试")
        if !op.latched {
            showStopError("停止未得到设备确认（\(reason)），\(Int(delay)) 秒后重发（已失败 \(op.failures) 次）。设备可能仍在输出，必要时请直接关闭设备电源")
        }
        let gen = op.gen
        let attempt = op.attempts
        bleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, let cur = self.stopOp, cur.gen == gen,
                  cur.attempts == attempt, cur.pair.phase == .backoff else { return }
            self.startStopAttempt()
        }
        publishSafety()
    }

    /// 停止出了结果：通知各调用方；确认成功时再处理停止期间到来的输出请求。
    /// 用户停止（sendStop）已清掉 deferredFrame 并锁闸，这里的重放只会是停止后用户新开闸的帧，
    /// 或全零停止期间到来的帧（闸门开着、运行继续）
    private func finishStopOp(_ result: StopResult) {
        guard let op = stopOp else { return }
        stopOp = nil
        if result == .confirmed {
            if op.keepRun { applyZeroStopSuccess() } else { applyStopSuccess() }
        }
        let deferred = deferredFrame
        let deferredRise = deferredMaxRise
        deferredFrame = nil
        deferredMaxRise = nil
        op.completions.forEach { $0(result) }
        if result == .confirmed || result == .idleUnconfirmed, let d = deferred, !outputLocked {
            submitOutput(d, opensGate: false, maxRise: deferredRise)
        }
        publishSafety()
    }

    /// 全零输出的停止帧对确认：设备停了，运行继续（记账、单次上限、看门狗照旧），闸门保持打开
    private func applyZeroStopSuccess() {
        stopUnconfirmed = false
        // M1：设备在 0，之后的升幅限速从 0 算
        outputWrites.resetBaseline()
        if stopErrorShown {
            stopErrorShown = false
            DispatchQueue.main.async { [weak self] in self?.lastError = nil }
        }
    }

    /// 断链 / 强制断开：停止没有结果
    private func abortStopOp() {
        guard let op = stopOp else { return }
        stopOp = nil
        deferredFrame = nil
        op.completions.forEach { $0(.aborted) }
    }

    /// 停止帧对两帧都确认：设备停了；调用方保证在 bleQueue 上
    private func applyStopSuccess() {
        isActive = false
        zeroHeld = false
        stopUnconfirmed = false
        runGen += 1 // 作废本次运行的到点定时器
        ledger.end() // 修 M3：按实际时长记账并开始冷却
        clearMayBeActive()
        // M1：设备在 0，之后的升幅限速从 0 算
        outputWrites.resetBaseline()
        // 停止其实确认成功了，清掉之前"停止未确认"的红字（锁存另有界面，不在这里清）
        if stopErrorShown {
            stopErrorShown = false
            DispatchQueue.main.async { [weak self] in self?.lastError = nil }
        }
    }

    /// 某笔写入超时：只打标记，不从队列中间删除（修 D）
    private func writeTimedOut(id: Int) {
        guard let idx = pendingWrites.firstIndex(where: { $0.id == id }),
              !pendingWrites[idx].timedOut else { return }
        pendingWrites[idx].timedOut = true
        switch pendingWrites[idx].kind {
        case .output:
            outputWriteFailed("写入超时（\(Int(Self.writeTimeout)) 秒没有回执）")
            outputWriteSettled()
        case .stopZero, .stopFrame:
            if let op = stopOp, op.pair.phase != .backoff, id == op.zeroId || id == op.stopId {
                stopAttemptFailed(reason: "写入超时")
            }
        }
    }

    /// 修 L6：非停止帧写失败/超时 —— 设备停在哪一档不确定：锁闸、界面归零、发停止帧对
    private func outputWriteFailed(_ why: String) {
        outputLocked = true
        deferredFrame = nil
        notifyForceZero("\(why)，已自动停止")
        showError("\(why)，已自动发送停止")
        requestStop(needed: true)
    }

    /// 停止未确认（发不出去）：标记并提示关电源；调用方保证在 bleQueue 上
    private func reportStopUnconfirmed() {
        stopUnconfirmed = true
        showStopError("停止帧未得到设备确认，设备可能仍在输出，请直接关闭设备电源")
    }

    /// 显示停止相关红字并记下来源；调用方保证在 bleQueue 上
    private func showStopError(_ msg: String) {
        stopErrorShown = true
        lastLimitText = nil
        DispatchQueue.main.async { [weak self] in self?.lastError = msg }
    }

    /// 冷却/额度/上限提示：条件解除后由看门狗自动清掉；调用方保证在 bleQueue 上
    private func showLimitError(_ msg: String) {
        stopErrorShown = false
        let text = deviceMayBeActive ? "\(msg)\n\(Self.mayBeActiveMsg)" : msg
        lastLimitText = text
        DispatchQueue.main.async { [weak self] in self?.lastError = text }
    }

    /// 冷却结束、额度恢复后清掉之前的冷却/额度红字（只清自己那条）
    private func clearLimitErrorIfExpired() {
        guard let text = lastLimitText, !isActive, ledger.checkAdmissible() == nil,
              !physicalAckRequired, !deviceMayBeActive else { return }
        lastLimitText = nil
        DispatchQueue.main.async { [weak self] in
            if self?.lastError == text { self?.lastError = nil }
        }
    }

    /// 结束连接（用户断开 / 强制断开 / 还没连好时取消）。
    /// forced=true：停止未确认就断开，记下"设备可能仍在输出"
    private func finishDisconnect(forced: Bool) {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        // 修 Factory H1/M2：断开时设备可能还在输出（停止没确认）
        let mayBeActive = forced || isActive || stopUnconfirmed
        resetLinkState()
        pendingPeripheral = nil
        updateState(.idle)
        if mayBeActive {
            markDeviceMayBeActive(prefix: forced ? "已强制断开，停止没有得到设备确认" : nil)
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingDeviceName = nil
            self?.pendingDeviceUUID = nil
            self?.showDeviceConfirm = false
        }
    }

    /// 链路没了（断开 / 断链 / 蓝牙关闭）时的统一清理；调用方先记下 mayBeActive。
    /// 进行中的运行不结束：等重新连上确认停止，或用户确认已物理关机时再按实际时长记账
    private func resetLinkState() {
        peripheral = nil
        writeChar = nil
        pendingWrites = []
        outputWrites.reset()
        isActive = false
        zeroHeld = false
        stopUnconfirmed = false
        lastHeartbeat = nil
        outputLocked = true
        disconnecting = false
        disconnectGen += 1
        runGen += 1
        // M5：断链也算被动停机，之前读到的代次全部作废
        let epoch = bumpGateEpoch()
        DispatchQueue.main.async { [weak self] in
            self?.forceDisconnectOffered = false
            self?.gateEpoch = epoch
        }
        abortStopOp()
        publishSafety()
    }

    private func updateState(_ s: State) {
        // 调用方保证在 bleQueue 上
        queueState = s
        DispatchQueue.main.async { [weak self] in self?.state = s }
    }

    private func setError(_ msg: String) {
        // 调用方保证在 bleQueue 上
        stopErrorShown = false // 修 L2：红字换成别的了，标记不能残留
        lastLimitText = nil
        queueState = .failed
        // 修 Factory H1：设备可能还在输出时，警告不能被别的红字盖掉
        let text = deviceMayBeActive ? "\(msg)\n\(Self.mayBeActiveMsg)" : msg
        DispatchQueue.main.async { [weak self] in
            self?.lastError = text
            self?.state = .failed
        }
    }

    /// 清掉界面上的旧红字（修 N8）；调用方保证在 bleQueue 上
    private func clearError() {
        stopErrorShown = false // 修 L2
        lastLimitText = nil
        // 修 Factory H1：设备可能还在输出时保留警告，直到重新连上并确认停止
        let text: String? = deviceMayBeActive ? Self.mayBeActiveMsg : nil
        DispatchQueue.main.async { [weak self] in self?.lastError = text }
    }

    /// 记下"设备可能仍在输出"并提示关电源、让界面归零；调用方保证在 bleQueue 上（修 Factory H1）
    private func markDeviceMayBeActive(prefix: String?) {
        deviceMayBeActive = true
        stopErrorShown = false
        lastLimitText = nil
        notifyForceZero(nil)
        let text = prefix.map { "\($0)\n\(Self.mayBeActiveMsg)" } ?? Self.mayBeActiveMsg
        DispatchQueue.main.async { [weak self] in self?.lastError = text }
        if appInBackground { postStopFailureNotification(then: {}) } // 修 CC M1
        publishSafety()
    }

    /// 停止确认成功：清除"可能仍在输出"，红字只删这条警告，不动别的提示（修 CC L1）
    private func clearMayBeActive() {
        guard deviceMayBeActive else { return }
        deviceMayBeActive = false
        let warn = Self.mayBeActiveMsg
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let cur = self.lastError, cur.contains(warn) else { return }
            if cur == warn {
                self.lastError = nil
            } else {
                self.lastError = cur.replacingOccurrences(of: "\n" + warn, with: "")
            }
        }
    }

    /// 停止最终未确认时发本地通知（App 可能已在后台，红字用户看不到）（修 Factory M1）
    private func postStopFailureNotification(then done: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = "BlueCrystal"
        content.body = "停止帧未得到设备确认，设备可能仍在输出，请关闭设备电源"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "bluecrystal.stopFailed", content: content, trigger: nil)
        // 修 CC r2 L2：回到 bleQueue 再回调，emergencyStop 的 finished 标记只在 bleQueue 上读写
        UNUserNotificationCenter.current().add(req) { [weak self] _ in
            if let q = self?.bleQueue { q.async(execute: done) } else { done() }
        }
    }

    /// 连接建立后服务/特征值发现失败：断开并清空外设，否则 peripheral 残留会让之后的扫描被拒（修 Factory H2 配套）
    private func failConnection(_ msg: String) {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        pendingWrites = []
        outputWrites.reset()
        setError(msg)
    }

    /// 连接超时（修 Factory L6）：10 秒还没到 ready 就取消连接；调用方保证在 bleQueue 上
    private func scheduleConnectTimeout(for p: CBPeripheral) {
        connectGen += 1
        let gen = connectGen
        bleQueue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self = self, self.connectGen == gen,
                  self.queueState == .connecting || self.queueState == .discovering,
                  let cur = self.peripheral, cur.identifier == p.identifier else { return }
            self.central.cancelPeripheralConnection(cur)
            self.peripheral = nil
            self.writeChar = nil
            self.setError("连接超时，请靠近设备、确认没被官方 App 占用后重试")
        }
    }

    /// 显示非停止类的红字（看门狗/写失败等），并重置 stopErrorShown（修 L2），
    /// 避免之后停止确认成功时把这条提示误删；调用方保证在 bleQueue 上
    private func showError(_ msg: String) {
        stopErrorShown = false
        lastLimitText = nil
        // 修 CC r2 L6：设备可能还在输出时保留警告
        let text = deviceMayBeActive ? "\(msg)\n\(Self.mayBeActiveMsg)" : msg
        DispatchQueue.main.async { [weak self] in self?.lastError = text }
    }

    // MARK: - 看门狗（心跳 + 单次上限）

    private func startWatchdog() {
        bleQueue.asyncAfter(deadline: .now() + Self.watchdogTickInterval) { [weak self] in
            self?.watchdogTick()
        }
    }

    /// 每秒一次。停止进行中时不另发停止（停止自己会一直重试到确认，修 M4：看门狗不会失明）
    private func watchdogTick() {
        ledger.checkpoint()
        if canWrite, isActive, stopOp == nil, !disconnecting {
            if let rem = ledger.runRemaining(), rem <= 0 {
                autoStopForLimit()
            } else if let hb = lastHeartbeat ?? ledger.openStart,
                      Self.now() - hb > Self.watchdogInterval {
                // 有输出在设备上，但界面心跳断了 >5s：UI 线程可能卡死，自动停机
                autoStop("看门狗：界面心跳丢失，已自动停止")
            }
        }
        clearLimitErrorIfExpired()
        publishSafety()
        bleQueue.asyncAfter(deadline: .now() + Self.watchdogTickInterval) { [weak self] in
            self?.watchdogTick()
        }
    }

    /// 本次运行到点（单次 1200 秒，或 30 分钟额度用完）时准时停止；看门狗每秒再兜底检查一次
    private func armRunDeadline(after allowed: TimeInterval) {
        runGen += 1
        let gen = runGen
        bleQueue.asyncAfter(deadline: .now() + allowed + 0.05) { [weak self] in
            guard let self = self, self.runGen == gen, self.canWrite, self.isActive,
                  self.stopOp == nil, !self.disconnecting,
                  let rem = self.ledger.runRemaining(), rem <= 0 else { return }
            self.autoStopForLimit()
        }
    }

    private func autoStopForLimit() {
        let fullRun = ledger.openAllowed >= SafetyLimits.maxRunSeconds
        let msg = fullRun
            ? "单次连续输出已达 \(Int(SafetyLimits.maxRunSeconds)) 秒上限，已自动停止"
            : "30 分钟内累计输出已达 \(Int(SafetyLimits.dutyBudgetSeconds)) 秒上限，已自动停止"
        autoStop(msg + "；冷却结束前不能再次输出", isLimit: true)
    }

    /// 被动停机：锁闸、界面归零、发停止帧对
    private func autoStop(_ msg: String, isLimit: Bool = false) {
        outputLocked = true // 修 高1：看门狗停机也要锁闸
        deferredFrame = nil
        notifyForceZero(msg) // 修 高1：通知 VM 把界面输出归零
        if isLimit { showLimitError(msg) } else { showError(msg) }
        requestStop(needed: true)
    }

    /// 算好安全状态，变了才发到主线程
    private func publishSafety() {
        var s = SafetyStatus()
        if isActive, let rem = ledger.runRemaining() {
            s.runRemaining = max(0, Int(rem.rounded(.up)))
            s.runAllowed = Int(ledger.openAllowed.rounded(.down))
        }
        s.cooldownRemaining = Int(ledger.cooldownRemaining().rounded(.up))
        let budget = ledger.remainingBudget()
        s.budgetRemaining = Int(budget.rounded(.down))
        s.budgetWait = budget < SafetyLimits.minRunSeconds ? Int(ledger.secondsUntilBudget().rounded(.up)) : 0
        s.stopRetrying = (stopOp?.failures ?? 0) > 0
        s.needsPhysicalAck = physicalAckRequired || deviceMayBeActive
        guard s != lastPublishedSafety else { return }
        lastPublishedSafety = s
        DispatchQueue.main.async { [weak self] in self?.safety = s }
    }

    /// 被动停机代次 +1（M5）；调用方保证在 bleQueue 上，并负责把返回值同步到主线程的 gateEpoch
    private func bumpGateEpoch() -> Int {
        queueGateEpoch &+= 1
        return queueGateEpoch
    }

    /// 在主线程发送 forceZeroOutputs；调用方保证在 bleQueue 上。
    /// 所有被动停机都经过这里，所以顺带把被动停机代次 +1（M5），和通知一起同步到主线程。
    /// 代次和通知必须在同一个主线程 block 里：AI VM 直接订阅，在这里同步作废授权（第二轮审查 M1）
    private func notifyForceZero(_ reason: String?) {
        let epoch = bumpGateEpoch()
        DispatchQueue.main.async { [weak self] in
            self?.gateEpoch = epoch
            self?.forceZeroOutputs.send(reason)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // N9：蓝牙关闭时系统不会回调 didDisconnect，必须在这里清理一切
        guard central.state == .poweredOn else {
            // 修 Factory H1：清理前先记下设备是否可能还在输出
            let mayBeActive = isActive || stopUnconfirmed || (stopOp?.needed ?? false)
            resetLinkState()
            pendingPeripheral = nil
            updateState(.idle)
            // 修 N9 小尾巴 / Factory L7：按实际状态给文案
            let msg: String
            switch central.state {
            case .unauthorized: msg = "蓝牙权限未授权，请去系统设置里打开"
            case .poweredOff: msg = "蓝牙已关闭"
            case .unsupported: msg = "这台设备不支持蓝牙 BLE"
            case .resetting: msg = "蓝牙正在重置…"
            default: msg = "蓝牙暂不可用"
            }
            DispatchQueue.main.async { [weak self] in self?.showDeviceConfirm = false }
            if mayBeActive {
                markDeviceMayBeActive(prefix: msg)
            } else {
                stopErrorShown = false // 修 L2
                lastLimitText = nil
                let text = deviceMayBeActive ? "\(msg)\n\(Self.mayBeActiveMsg)" : msg
                DispatchQueue.main.async { [weak self] in self?.lastError = text }
            }
            return
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // 修 Factory H2：只在扫描中处理；stopScan 前已排队的迟到回调直接忽略
        guard queueState == .scanning, self.peripheral == nil else { return }
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // 修 L2：名字必须完全等于 mizzzee_0032
        guard peripheral.name == Self.deviceName || advName == Self.deviceName else { return }
        let name = Self.deviceName

        // 已绑定的设备才自动连；首次使用也要弹确认框（修 #1 的小尾巴）
        let bonded = UserDefaults.standard.string(forKey: Self.bondedDeviceKey)
        if let bonded = bonded, bonded == peripheral.identifier.uuidString {
            central.stopScan()
            self.peripheral = peripheral
            clearError()
            updateState(.connecting)
            central.connect(peripheral, options: nil)
            scheduleConnectTimeout(for: peripheral)
            return
        }
        // 本轮用户点"取消"拒绝过的设备，不再弹框（修 E）
        let uuidStr = peripheral.identifier.uuidString
        guard !rejectedUUIDs.contains(uuidStr) else { return }
        // 未绑定过：弹确认框，不自动连
        guard pendingPeripheral == nil else { return }
        pendingPeripheral = peripheral
        central.stopScan()
        updateState(.idle)
        DispatchQueue.main.async { [weak self] in
            self?.pendingDeviceName = name
            self?.pendingDeviceUUID = uuidStr
            self?.showDeviceConfirm = true
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // 迟到的连接回调（已超时取消/已换外设）忽略
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        central.stopScan() // 修 Factory H2
        clearError() // 修 N8：连上就清掉旧红字
        updateState(.discovering)
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // 修 G 小尾巴：只处理当前外设；失败后置空，避免残留引用
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        self.peripheral = nil
        self.writeChar = nil
        setError("连接失败：\(error?.localizedDescription ?? "未知")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // 修 G：只处理当前这台外设的回调；
        // finishDisconnect 里 cancelPeripheralConnection 的迟到回调会被忽略，
        // 不会把用户新发起的扫描状态冲回"未连接"
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        // 修 Factory H1：清理前先记下设备是否可能还在输出（断开流程中的停止也算没确认）
        let mayBeActive = isActive || stopUnconfirmed || (stopOp?.needed ?? false)
        // 意外断开：清理并通知 UI（VM 会订阅 state 变化停掉 Timer、归零滑杆）
        resetLinkState()
        if let error = error {
            setError("设备意外断开：\(error.localizedDescription)")
        } else {
            updateState(.idle)
        }
        if mayBeActive { markDeviceMayBeActive(prefix: error.map { "设备意外断开：\($0.localizedDescription)" }) }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        if let error = error { failConnection("发现服务失败：\(error.localizedDescription)"); return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failConnection("未找到 FFA0 服务")
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        if let error = error { failConnection("发现特征值失败：\(error.localizedDescription)"); return }
        var write: CBCharacteristic?
        var notify: CBCharacteristic?
        for c in service.characteristics ?? [] {
            if c.uuid == Self.writeUUID {
                write = c
            } else if c.uuid == Self.notifyUUID {
                notify = c
            }
        }
        // 修 L2：照真机 GATT（legacy mizzzee_0032_gatt_profile.json）检查属性，对不上就不连
        guard let w = write, w.properties.contains(.write) else {
            failConnection("FFA1 写特征值缺失或不支持带回执写入，不是预期的设备")
            return
        }
        guard let n = notify, n.properties.contains(.notify) else {
            failConnection("FFA2 通知特征值缺失或不支持通知，不是预期的设备")
            return
        }
        writeChar = w
        peripheral.setNotifyValue(true, for: n)
        // 修 Factory L5：每次重新 ready 都清空写入队列，FIFO 从零对齐
        pendingWrites = []
        outputWrites.reset()
        clearError() // 修 N8：真正连上后清掉旧红字（"可能仍在输出"除外）
        updateState(.ready)
        // 修 Factory H1 / N3：连上先发一对带确认的停止帧，设备停在旧强度上（含 0x08 手动帧）也能归零；
        // 上次可能仍在输出时必须确认成功（失败会一直重试）
        requestStop(needed: deviceMayBeActive || physicalAckRequired || ledger.hasOpenRun)
        if !notificationAuthRequested {
            notificationAuthRequested = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// 修 L1：记录 FFA2 订阅结果
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.notifyUUID,
              let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        if let error = error {
            let desc = error.localizedDescription
            Self.log.error("FFA2 订阅失败：\(desc, privacy: .public)")
            DispatchQueue.main.async { [weak self] in self?.lastNotifyHex = "订阅失败：\(desc)" }
        } else {
            let on = characteristic.isNotifying
            Self.log.info("FFA2 订阅状态：\(on ? "已开启" : "已关闭", privacy: .public)")
        }
    }

    /// 修 L1：记录 FFA2 每条通知的 HEX（目前协议含义未知，只记录不解析）。
    /// L6：日志带单调时间戳和距最近一次写入的间隔，便于之后对照真机判断它能不能当停止确认用；
    /// 用 notice 级别，Console / sysdiagnose 里能留下来
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.notifyUUID,
              let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        let t = Self.now()
        let stamp = String(format: "%.3f", t)
        let since: String
        if let w = lastWriteLog {
            since = String(format: "距写入 #%ld（%@）%.0f ms", w.id, w.hex, (t - w.at) * 1000)
        } else {
            since = "此前没有写入"
        }
        let pending = pendingWrites.count
        if let error = error {
            let desc = error.localizedDescription
            Self.log.error("FFA2 通知出错 t=\(stamp, privacy: .public)：\(desc, privacy: .public)；\(since, privacy: .public)")
            return
        }
        let hex = characteristic.value.map { BCProtocol.hex($0) } ?? "（空）"
        Self.log.notice("FFA2 通知 t=\(stamp, privacy: .public) \(hex, privacy: .public)；\(since, privacy: .public)，待回执 \(pending)")
        DispatchQueue.main.async { [weak self] in self?.lastNotifyHex = hex }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.writeUUID else { return }
        // 修 Factory L5：只认当前外设的回执
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        guard !pendingWrites.isEmpty else { return }
        // FIFO：这个回执属于最早发出的那一笔
        let w = pendingWrites.removeFirst()
        // 超时标记过的条目：已按失败处理（停止帧对已安排整对重发），迟到的回执作废（修 D）
        guard !w.timedOut else { return }
        switch w.kind {
        case .output:
            if let error = error {
                outputWriteFailed("写入失败：\(error.localizedDescription)")
            } else {
                publishSentHex(w.hex)
            }
            outputWriteSettled()
        case .stopZero, .stopFrame:
            // 只认当前这一轮的两帧；旧一轮的结果已由新一轮承担
            guard var op = stopOp, op.pair.phase != .backoff,
                  w.id == op.zeroId || w.id == op.stopId else { return }
            if let error = error {
                stopAttemptFailed(reason: error.localizedDescription)
                return
            }
            if w.id == op.zeroId { op.pair.zeroAcked = true } else { op.pair.stopAcked = true }
            stopOp = op
            publishSentHex(w.hex)
            // 修 N1：两帧都确认才算停
            if op.pair.confirmed { finishStopOp(.confirmed) }
        }
    }

    private func publishSentHex(_ hex: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastSentHex = hex
        }
    }
}
