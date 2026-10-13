import Foundation
import CoreBluetooth
import Combine
import UserNotifications

/// mizzzee_0032 的 BLE 连接管理
///
/// Service: 0000FFA0-0000-1000-8000-00805F9B34FB
/// Write:   0000FFA1-0000-1000-8000-00805F9B34FB（Write With Response）
/// Notify:  0000FFA2-0000-1000-8000-00805F9B34FB
final class BLEManager: NSObject, ObservableObject {

    static let serviceUUID = CBUUID(string: "0000FFA0-0000-1000-8000-00805F9B34FB")
    static let writeUUID = CBUUID(string: "0000FFA1-0000-1000-8000-00805F9B34FB")
    static let notifyUUID = CBUUID(string: "0000FFA2-0000-1000-8000-00805F9B34FB")
    static let deviceNameKeyword = "mizzzee_0032"
    static let bondedDeviceKey = "BlueCrystal.bondedDeviceUUID"

    /// 看门狗：界面心跳超过这么久没来，说明 UI 线程卡死，自动停机
    static let watchdogInterval: TimeInterval = 5.0
    /// 全局单次激活上限 30 分钟
    static let maxActiveSeconds: TimeInterval = 30 * 60
    /// 单笔写入超时：回执 2s 没回来就标记超时（只标记、不从队列中间删除，修 D）
    static let writeTimeout: TimeInterval = 2.0

    enum State: String {
        case idle = "未连接"
        case scanning = "扫描中…"
        case connecting = "连接中…"
        case discovering = "发现服务…"
        case ready = "已连接"
        /// 断开流程中：停止帧还没出最终结果。只发给界面（控件禁用），
        /// bleQueue 内部的 queueState 仍是 ready，停止帧的重试才能发出去（修 N1）
        case disconnecting = "断开中…"
        case failed = "连接失败"
    }

    @Published var state: State = .idle
    @Published var lastError: String?
    @Published var lastSentHex: String = "—"

    /// 发现未绑定过的设备时弹确认框用
    @Published var pendingDeviceName: String?
    @Published var pendingDeviceUUID: String?
    @Published var showDeviceConfirm = false

    /// 被动停机（看门狗 / 退后台 / 30 分钟上限）后通知 VM：把界面输出归零。
    /// VM 收到后只归零 UI，不要再补发停止帧（停止帧已经发出去了）。
    let forceZeroOutputs = PassthroughSubject<Void, Never>()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var pendingPeripheral: CBPeripheral?

    /// 只在 bleQueue 上读写的状态镜像，消除跨线程竞争
    private var queueState: State = .idle

    /// 发送队列串行化，避免 Write With Response 冲突
    private let bleQueue = DispatchQueue(label: "com.bluecrystal.ble")

    // MARK: - 输出闸门（修 N2）
    /// 停机（disconnect/emergencyStop/看门狗）后锁死：排队中的延迟帧不许再出去。
    /// 只有用户主动操作（send/sendStop/sendOfficialStart/视频页点"播放"）才能重新打开。
    /// 视频 tick 走 sendTick，不开闸（修 C）。
    /// 修 Factory L1：冷启动时闸门是关的，必须等用户第一次主动操作才开
    private var outputLocked = true
    /// 断开流程进行中：除停止帧外一律拒发，避免断开期间被重新开闸（修 N1）
    private var disconnecting = false

    // MARK: - 写入回执 FIFO（修 #3、D）
    private struct PendingWrite {
        let id: Int
        let hex: String
        let data: Data
        let isStop: Bool
        var retryCount: Int
        var onAck: (() -> Void)?
        /// 超时标记：回执回来时直接丢弃，结果由重试帧承担。
        /// 绝不从队列中间删除条目，否则后面的回执会全部错位。
        var timedOut: Bool
        /// 所属链：首发帧的 id，重试帧继承。兜底只处理自己这条链（修 N2）
        let chain: Int
    }
    /// 发出未回执的写入，按发出顺序排队；回执按 FIFO 配对
    private var pendingWrites: [PendingWrite] = []
    private var writeSeq = 0
    /// 最后一次入队的非停止帧的写入 id（修 H1）：
    /// 停止帧回执成功时，只有它的 id 比这个大（物理上排在最后一个非零帧之后）才算真的停了
    private var lastNonStopId = 0
    /// 断开/退后台兜底：必须晚于"首发 + 一次重试"两轮写超时，停止帧才有机会重试（修 M1）
    static let disconnectFallback: TimeInterval = writeTimeout * 2 + 0.5

    // MARK: - 看门狗（心跳版，修 N1）
    /// 界面心跳：视频页 tick（100ms）、手动页心跳定时器（1s）调用
    private var lastHeartbeat: Date?
    /// 当前是否有非零输出在设备上生效
    private var isActive = false
    private var activeSince: Date?
    /// 停止帧最终写失败（重试也失败/超时）：设备可能还在输出，
    /// 看门狗不再重复发停止帧刷屏，只保留"请关电源"提示
    private var stopWriteFailed = false
    /// 当前红字是不是停止帧失败/未确认的提示：之后停止帧真正确认成功时自动清掉（v1.4 低危）
    private var stopErrorShown = false
    /// 修 Factory H1：上次连接结束时设备可能还在输出（断链/蓝牙关闭/停止帧未确认）。
    /// 跨连接保留；期间红字不会被普通的 clearError 清掉，重新连上后发一帧停止帧并确认成功才清除
    private var deviceMayBeActive = false
    static let mayBeActiveMsg = "连接已断开，设备可能仍在输出，请关闭设备电源"
    /// 连接代次：连接超时只对本次连接有效（修 Factory L6）
    private var connectGen = 0
    static let connectTimeout: TimeInterval = 10
    private var notificationAuthRequested = false

    /// 扫描代次：防止旧扫描的超时把新扫描提前停掉（修 N9）
    private var scanGen = 0

    /// 本轮扫描中用户点"取消"拒绝过的设备 UUID：不再弹确认框（修 E）。
    /// 用户手动点"连接"重新扫描时会清空。
    private var rejectedUUIDs = Set<String>()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue)
        startWatchdog()
    }

    // MARK: - 对外接口（可在任意线程调用）

    /// 界面心跳：VideoSyncPlayer 的 tick、手动页心跳定时器调用
    func heartbeat() {
        bleQueue.async { [weak self] in
            self?.lastHeartbeat = Date()
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

    /// 断开：先发停止帧，等它自己的最终结果（含一次重试，或 4.5s 兜底）再真正断开；随后锁死输出闸门
    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.peripheral != nil, self.writeChar != nil else {
                self.finishDisconnect()
                return
            }
            guard !self.disconnecting else { return } // 已在断开中，不重复发起
            self.outputLocked = true
            let stopId = self.enqueueFrame(BCProtocol.stopFrame, onAck: { [weak self] in
                guard let self = self else { return }
                // 修 N1 兜底：停止帧确认了，但设备上仍有更晚的非零帧（isActive 未被清零），
                // 不能当成已停，提示关电源后再断开
                if self.isActive, !self.stopWriteFailed {
                    self.reportStopUnconfirmed()
                }
                self.finishDisconnect()
            })
            guard stopId >= 0 else {
                // 发都发不出去，直接断开
                self.finishDisconnect()
                return
            }
            // 修 N1：断开期间锁死非停止帧，界面显示"断开中…"并禁用控件
            self.disconnecting = true
            DispatchQueue.main.async { [weak self] in self?.state = .disconnecting }
            // 超时兜底：晚于两轮写超时（修 M1），停止帧的重试有机会跑完。
            // 兜底触发时停止帧仍未确认：按"设备可能还在输出"处理，先提示关电源再断开。
            // 只把 onAck 作废，不从队列中间删条目（修 D）；finishDisconnect 会整体清空。
            self.bleQueue.asyncAfter(deadline: .now() + Self.disconnectFallback) { [weak self] in
                guard let self = self else { return }
                // 修 N2：只看自己这条停止帧链，不碰 emergencyStop 等其他流程的回调
                guard self.disconnecting,
                      self.cancelChainCallbacks(chain: stopId) else { return }
                self.reportStopUnconfirmed()
                self.finishDisconnect()
                // 已出最终结果：onAck 自己调过 finishDisconnect，这里什么都不做
            }
        }
    }

    /// App 退后台/锁屏时的紧急停止（修 Factory M1：改为异步）。
    /// 立刻锁闸并通知界面归零；停止帧整条链（含一次重试）出最终结果或 4.5s 兜底后才回调 completion，
    /// 调用方据此结束后台任务。最终未确认时发本地通知提示关电源。completion 在主线程回调，只回调一次。
    func emergencyStop(completion: @escaping () -> Void) {
        bleQueue.async { [weak self] in
            var finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async(execute: completion)
            }
            guard let self = self else { finish(); return }
            // 修 Factory M2：不管停止帧发不发得出去，都先锁闸并让界面归零
            self.outputLocked = true
            self.notifyForceZero()
            let stopId: Int
            if self.peripheral != nil, self.writeChar != nil, self.queueState == .ready {
                stopId = self.enqueueFrame(BCProtocol.stopFrame, onAck: { [weak self] in
                    guard let self = self else { finish(); return }
                    // 修 Factory L4：停止帧之后还有更晚的非零帧，不能当成已停
                    if self.isActive, !self.stopWriteFailed {
                        self.reportStopUnconfirmed()
                    }
                    if self.stopWriteFailed { self.postStopFailureNotification() }
                    finish()
                })
            } else {
                stopId = -1
            }
            guard stopId >= 0 else {
                // 发不出去：设备上还有输出就明确提示（修 Factory M2）
                if self.isActive {
                    self.reportStopUnconfirmed()
                    self.postStopFailureNotification()
                }
                finish()
                return
            }
            // 兜底：晚于两轮写超时，只处理自己这条链（修 N2）
            self.bleQueue.asyncAfter(deadline: .now() + Self.disconnectFallback) { [weak self] in
                if let self = self, self.cancelChainCallbacks(chain: stopId) {
                    self.reportStopUnconfirmed()
                    self.postStopFailureNotification()
                }
                finish()
            }
        }
    }

    /// 回到前台（修 Factory M1）：设备可能还在输出时再补发一帧带确认的停止帧
    func resumeFromBackground() {
        bleQueue.async { [weak self] in
            guard let self = self, self.queueState == .ready,
                  self.isActive || self.stopWriteFailed || self.deviceMayBeActive else { return }
            self.sendConfirmingStop()
        }
    }

    // MARK: - 用户主动发送（会重新打开输出闸门）

    /// 发送 0x06 控制帧（四通道强度 0~99）
    func send(channels: [Int]) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.outputLocked = false
            self.enqueueFrame(BCProtocol.frame(channels: channels))
        }
    }

    /// 节流延迟帧专用：不重新开闸（修 N2 —— 停机后排队的尾帧必须丢掉）
    func sendThrottled(channels: [Int]) {
        bleQueue.async { [weak self] in
            guard let self = self, !self.outputLocked else { return }
            self.enqueueFrame(BCProtocol.frame(channels: channels))
        }
    }

    /// 视频 tick 专用：不开闸（修 C）。
    /// 看门狗 / emergencyStop 锁住闸后，tick 的自动帧不许再把它打开；
    /// 只有用户点"播放"（userResumeOutput）才能开闸。
    func sendTick(channels: [Int]) {
        bleQueue.async { [weak self] in
            guard let self = self, !self.outputLocked else { return }
            self.enqueueFrame(BCProtocol.frame(channels: channels))
        }
    }

    /// 用户在视频页点了"播放"：显式打开输出闸门（修 C）
    func userResumeOutput() {
        bleQueue.async { [weak self] in
            self?.outputLocked = false
        }
    }

    /// 停止帧不受闸门限制，也不再打开闸门（修 C 备注）：
    /// 它会被外部暂停/播完等自动路径调用，"只有用户操作才能开闸"必须严格成立
    func sendStop() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.enqueueFrame(BCProtocol.stopFrame)
        }
    }

    func sendOfficialStart() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.outputLocked = false
            self.enqueueFrame(BCProtocol.officialStartFrame)
        }
    }

    // MARK: - 内部（bleQueue 上）

    /// 入队并发送一帧，返回该笔写入的 id（发不出去返回 -1）；调用方保证在 bleQueue 上
    @discardableResult
    private func enqueueFrame(_ data: Data, onAck: (() -> Void)? = nil) -> Int {
        guard let p = peripheral,
              let c = writeChar,
              queueState == .ready else { return -1 }
        // 修 N1：断开流程中只放行停止帧
        if disconnecting, data != BCProtocol.stopFrame { return -1 }
        writeSeq += 1
        let id = writeSeq
        pendingWrites.append(PendingWrite(
            id: id,
            hex: BCProtocol.hex(data),
            data: data,
            isStop: data == BCProtocol.stopFrame,
            retryCount: 0,
            onAck: onAck,
            timedOut: false,
            chain: id
        ))
        p.writeValue(data, for: c, type: .withResponse)
        if data != BCProtocol.stopFrame {
            // 修 F：isActive 只在停止帧回执成功后才清零；
            // 发出时不清，否则写失败会被当成"已停止"
            isActive = true
            stopWriteFailed = false
            lastNonStopId = id // 修 H1
            if activeSince == nil { activeSince = Date() }
        }
        // 每笔写入单独 2s 超时（修 D）
        bleQueue.asyncAfter(deadline: .now() + Self.writeTimeout) { [weak self] in
            self?.writeTimedOut(id: id)
        }
        return id
    }

    /// 某笔写入超时：只打标记，不从队列中间删除（修 D）。
    /// 停止帧追加重试到队尾（物理顺序不乱）；超时的旧条目回执回来直接丢弃。
    private func writeTimedOut(id: Int) {
        guard let idx = pendingWrites.firstIndex(where: { $0.id == id }) else { return }
        var w = pendingWrites[idx]
        guard !w.timedOut else { return }
        w.timedOut = true
        pendingWrites[idx] = w
        guard w.isStop else { return }
        if w.retryCount < 1 {
            if shouldRetryStop(w) {
                pendingWrites[idx].onAck = nil // onAck 转交给重试帧
                enqueueRetry(w)
            }
        } else {
            // 停止帧两次都没结果：按"设备可能还在输出"处理（修 F）
            stopWriteFailed = true
            showStopError("停止帧写入超时，设备可能仍在输出，请直接关闭设备电源")
            // 最终结果出来了：把 onAck 交还调用方（断开流程据此立刻断开，不用干等兜底）
            pendingWrites[idx].onAck = nil
            w.onAck?()
        }
    }

    /// 修 M2：停止帧失败/超时后是否重试。
    /// S 之后已经有更新的帧入队（用户新操作或新的停止帧），重试 S' 会排到它后面、把它覆盖掉，
    /// 结果"设备停了，滑杆还显示原值"，这时丢弃重试，以更新的帧为准。
    /// 断开/退后台流程（带 onAck）例外：那里停止帧必须是最后一帧，必须重试。
    private func shouldRetryStop(_ w: PendingWrite) -> Bool {
        if w.onAck != nil { return true }
        return writeSeq == w.id
    }

    /// 兜底时停止帧仍未确认：标记失败并提示关电源（修 M1）；调用方保证在 bleQueue 上
    private func reportStopUnconfirmed() {
        stopWriteFailed = true
        showStopError("停止帧未得到设备确认，设备可能仍在输出，请直接关闭设备电源")
    }

    /// 显示停止帧相关红字并记下来源；调用方保证在 bleQueue 上
    private func showStopError(_ msg: String) {
        stopErrorShown = true
        DispatchQueue.main.async { [weak self] in self?.lastError = msg }
    }

    /// 修 N2：兜底只处理自己这条停止帧链。
    /// 链上还有未出结果、仍带回调的条目时把回调作废并返回 true；否则返回 false（已出最终结果）。
    private func cancelChainCallbacks(chain: Int) -> Bool {
        let stillPending = pendingWrites.contains {
            $0.chain == chain && !$0.timedOut && $0.onAck != nil
        }
        guard stillPending else { return false }
        for i in pendingWrites.indices where pendingWrites[i].chain == chain {
            pendingWrites[i].onAck = nil
        }
        return true
    }

    /// 停止帧重试：新 id、队尾追加、继承 onAck（修 D：不插队头）
    private func enqueueRetry(_ w: PendingWrite) {
        guard let p = peripheral, let c = writeChar, queueState == .ready else {
            // 连发都发不出去了：按最终失败处理
            stopWriteFailed = true
            showStopError("停止帧写入失败，设备可能仍在输出，请直接关闭设备电源")
            w.onAck?()
            return
        }
        writeSeq += 1
        let id = writeSeq
        pendingWrites.append(PendingWrite(
            id: id, hex: w.hex, data: w.data, isStop: true,
            retryCount: w.retryCount + 1, onAck: w.onAck, timedOut: false,
            chain: w.chain
        ))
        p.writeValue(w.data, for: c, type: .withResponse)
        bleQueue.asyncAfter(deadline: .now() + Self.writeTimeout) { [weak self] in
            self?.writeTimedOut(id: id)
        }
    }

    private func finishDisconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        // 修 Factory H1/M2：断开时设备可能还在输出（停止帧没确认、或根本没发出去）
        let mayBeActive = isActive || stopWriteFailed
        peripheral = nil
        writeChar = nil
        pendingPeripheral = nil
        pendingWrites = []
        isActive = false
        activeSince = nil
        stopWriteFailed = false
        lastHeartbeat = nil
        outputLocked = true
        disconnecting = false
        updateState(.idle)
        if mayBeActive { markDeviceMayBeActive(prefix: nil) }
        DispatchQueue.main.async { [weak self] in
            self?.pendingDeviceName = nil
            self?.pendingDeviceUUID = nil
            self?.showDeviceConfirm = false
        }
    }

    private func updateState(_ s: State) {
        // 调用方保证在 bleQueue 上
        queueState = s
        DispatchQueue.main.async { [weak self] in self?.state = s }
    }

    private func setError(_ msg: String) {
        // 调用方保证在 bleQueue 上
        stopErrorShown = false // 修 L2：红字换成别的了，标记不能残留
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
        // 修 Factory H1：设备可能还在输出时保留警告，直到重新连上并确认停止帧
        let text: String? = deviceMayBeActive ? Self.mayBeActiveMsg : nil
        DispatchQueue.main.async { [weak self] in self?.lastError = text }
    }

    /// 记下"设备可能仍在输出"并提示关电源、让界面归零；调用方保证在 bleQueue 上（修 Factory H1）
    private func markDeviceMayBeActive(prefix: String?) {
        deviceMayBeActive = true
        stopErrorShown = false
        notifyForceZero()
        let text = prefix.map { "\($0)\n\(Self.mayBeActiveMsg)" } ?? Self.mayBeActiveMsg
        DispatchQueue.main.async { [weak self] in self?.lastError = text }
    }

    /// 发一帧带确认的停止帧；确认成功且之后没有非零帧时清除"可能仍在输出"（修 Factory H1）。
    /// 调用方保证在 bleQueue 上
    private func sendConfirmingStop() {
        enqueueFrame(BCProtocol.stopFrame, onAck: { [weak self] in
            guard let self = self else { return }
            if !self.stopWriteFailed, !self.isActive, self.deviceMayBeActive {
                self.deviceMayBeActive = false
                self.clearError()
            }
        })
    }

    /// 停止帧最终未确认时发本地通知（App 可能已在后台，红字用户看不到）（修 Factory M1）
    private func postStopFailureNotification() {
        let content = UNMutableNotificationContent()
        content.title = "BlueCrystal"
        content.body = "停止帧未得到设备确认，设备可能仍在输出，请关闭设备电源"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "bluecrystal.stopFailed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 连接建立后服务/特征值发现失败：断开并清空外设，否则 peripheral 残留会让之后的扫描被拒（修 Factory H2 配套）
    private func failConnection(_ msg: String) {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeChar = nil
        pendingWrites = []
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

    /// 显示非停止帧类的红字（看门狗/30 分钟/写失败等），并重置 stopErrorShown（修 L2），
    /// 避免之后停止帧确认成功时把这条提示误删；调用方保证在 bleQueue 上
    private func showError(_ msg: String) {
        stopErrorShown = false
        DispatchQueue.main.async { [weak self] in self?.lastError = msg }
    }

    // MARK: - 看门狗（心跳版）

    private func startWatchdog() {
        bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.watchdogTick()
        }
    }

    private func watchdogTick() {
        let now = Date()
        // stopWriteFailed 时不再重复发停止帧刷屏（修 F）
        // 修 Factory L3：已有停止帧在等结果时不重复入队、不重复通知
        let hasPendingStop = pendingWrites.contains { $0.isStop && !$0.timedOut }
        if queueState == .ready, isActive, !stopWriteFailed, !hasPendingStop {
            // 全局 30 分钟上限
            if let since = activeSince, now.timeIntervalSince(since) > Self.maxActiveSeconds {
                enqueueFrame(BCProtocol.stopFrame)
                outputLocked = true
                notifyForceZero()
                showError("单次连续输出超过 30 分钟，正在自动停止")
            } else if let hb = lastHeartbeat ?? activeSince, // 修 Factory L2：没有心跳时从开始输出算起
                      now.timeIntervalSince(hb) > Self.watchdogInterval,
                      peripheral != nil, writeChar != nil {
                // 有非零输出在设备上，但界面心跳断了 >5s：UI 线程可能卡死，自动停机
                enqueueFrame(BCProtocol.stopFrame)
                outputLocked = true // 修 高1：看门狗停机也要锁闸
                notifyForceZero()   // 修 高1：通知 VM 把界面输出归零
                showError("看门狗：界面心跳丢失，正在自动停止")
            }
        }
        bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.watchdogTick()
        }
    }

    /// 在主线程发送 forceZeroOutputs；调用方保证在 bleQueue 上
    private func notifyForceZero() {
        DispatchQueue.main.async { [weak self] in
            self?.forceZeroOutputs.send(())
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // N9：蓝牙关闭时系统不会回调 didDisconnect，必须在这里清理一切
        guard central.state == .poweredOn else {
            // 修 Factory H1：清理前先记下设备是否可能还在输出
            let mayBeActive = isActive || stopWriteFailed || disconnecting
            peripheral = nil
            writeChar = nil
            pendingPeripheral = nil
            pendingWrites = []
            isActive = false
            activeSince = nil
            stopWriteFailed = false
            lastHeartbeat = nil
            outputLocked = true
            disconnecting = false
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
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.contains(Self.deviceNameKeyword) else { return }

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
        // 修 Factory H1：清理前先记下设备是否可能还在输出
        let mayBeActive = isActive || stopWriteFailed || disconnecting
        // 意外断开：清理并通知 UI（VM 会订阅 state 变化停掉 Timer、归零滑杆）
        self.peripheral = nil
        self.writeChar = nil
        self.pendingWrites = []
        self.isActive = false
        self.activeSince = nil
        self.stopWriteFailed = false
        self.lastHeartbeat = nil
        self.outputLocked = true
        self.disconnecting = false
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
        for c in service.characteristics ?? [] {
            if c.uuid == Self.writeUUID {
                writeChar = c
            } else if c.uuid == Self.notifyUUID {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        if writeChar != nil {
            // 修 Factory L5：每次重新 ready 都清空写入队列，FIFO 从零对齐
            pendingWrites = []
            clearError() // 修 N8：真正连上后清掉旧红字（"可能仍在输出"除外）
            updateState(.ready)
            // 修 Factory H1：连上先发一帧带确认的停止帧，设备停在旧强度上也能归零
            sendConfirmingStop()
            if !notificationAuthRequested {
                notificationAuthRequested = true
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        } else {
            failConnection("未找到 FFA1 写特征值")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.writeUUID else { return }
        // 修 Factory L5：只认当前外设的回执
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        guard !pendingWrites.isEmpty else { return }
        // FIFO：这个回执属于最早发出的那一笔。
        // CoreBluetooth 对同一特征值的 withResponse 写是串行回调的，顺序有保证。
        let w = pendingWrites.removeFirst()
        if w.timedOut {
            // 超时标记过的条目：结果已由队尾的重试帧承担，这个回执作废（修 D）
            return
        }
        if let error = error {
            if w.isStop, w.retryCount < 1 {
                // 停止帧写失败立刻重试一次，追加到队尾（修 #3、D）；
                // 之后已有更新的帧入队则丢弃重试，以更新的帧为准（修 M2）
                if shouldRetryStop(w) { enqueueRetry(w) }
            } else {
                // 修 L1：先置标记、再调 onAck（与 writeTimedOut 一致），
                // 否则断开流程走完后标记又被置回 true，带进下一次连接
                if w.isStop {
                    // 修 F：停止帧最终失败，按"设备可能还在输出"处理
                    stopWriteFailed = true
                    showStopError("停止帧写入失败，设备可能仍在输出，请直接关闭设备电源")
                } else {
                    showError("写入失败：\(error.localizedDescription)")
                }
                w.onAck?()
            }
            return
        }
        // 成功：这个回执对应的那一帧才是"最后一帧"
        if w.isStop {
            // 修 F：只有回执成功才算真的停了。
            // 修 H1：而且这个停止帧必须排在最后一个非零帧之后 ——
            // "S 发出 → N 发出 → S 回执"时设备实际在跑 N，不能清零，否则看门狗和 30 分钟上限失明
            stopWriteFailed = false
            if w.id > lastNonStopId {
                isActive = false
                activeSince = nil
                // v1.4 低危：停止帧其实只是回执来晚、确认成功了，清掉之前的"请关电源"误报
                if stopErrorShown {
                    stopErrorShown = false
                    DispatchQueue.main.async { [weak self] in self?.lastError = nil }
                }
            }
        }
        let hex = w.hex
        DispatchQueue.main.async { [weak self] in
            self?.lastSentHex = hex
        }
        w.onAck?()
    }
}
