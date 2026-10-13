import Foundation
import CoreBluetooth
import Combine

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
    private var outputLocked = false

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
    }
    /// 发出未回执的写入，按发出顺序排队；回执按 FIFO 配对
    private var pendingWrites: [PendingWrite] = []
    private var writeSeq = 0

    // MARK: - 看门狗（心跳版，修 N1）
    /// 界面心跳：视频页 tick（100ms）、手动页心跳定时器（1s）调用
    private var lastHeartbeat: Date?
    /// 当前是否有非零输出在设备上生效
    private var isActive = false
    private var activeSince: Date?
    /// 停止帧最终写失败（重试也失败/超时）：设备可能还在输出，
    /// 看门狗不再重复发停止帧刷屏，只保留"请关电源"提示
    private var stopWriteFailed = false

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
            self.setError("未找到 mizzzee_0032，请确认设备开机且未被官方 App 占用")
        }
    }

    /// 用户在确认框点了"连接"
    func confirmPendingDevice() {
        bleQueue.async { [weak self] in
            guard let self = self, let p = self.pendingPeripheral else { return }
            self.pendingPeripheral = nil
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

    /// 断开：先发停止帧，等它自己的最终结果（或 1.5s 超时）再真正断开；随后锁死输出闸门
    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.peripheral != nil, self.writeChar != nil else {
                self.finishDisconnect()
                return
            }
            self.outputLocked = true
            let stopId = self.enqueueFrame(Protocol.stopFrame, onAck: { [weak self] in
                self?.finishDisconnect()
            })
            guard stopId >= 0 else {
                // 发都发不出去，直接断开
                self.finishDisconnect()
                return
            }
            // 超时兜底：1.5s 还没出最终结果就直接断开。
            // 只把 onAck 作废，不从队列中间删条目（修 D）；finishDisconnect 会整体清空。
            self.bleQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                let stillPending = self.pendingWrites.contains {
                    $0.isStop && !$0.timedOut && $0.onAck != nil
                }
                if stillPending {
                    for i in self.pendingWrites.indices where self.pendingWrites[i].isStop {
                        self.pendingWrites[i].onAck = nil
                    }
                    self.finishDisconnect()
                }
                // 已出最终结果：onAck 自己调过 finishDisconnect，这里什么都不做
            }
        }
    }

    /// App 退后台/锁屏时的紧急停止：同步尽力把停止帧发出去（最多等 2 秒），随后锁死输出闸门
    func emergencyStop() {
        let done = DispatchSemaphore(value: 0)
        bleQueue.async { [weak self] in
            // 修 A：weak self 必须先解包，否则下面全是编译错误
            guard let self = self else { done.signal(); return }
            guard self.peripheral != nil,
                  self.writeChar != nil,
                  self.queueState == .ready else {
                done.signal()
                return
            }
            self.outputLocked = true
            self.enqueueFrame(Protocol.stopFrame, onAck: { done.signal() })
            self.bleQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { done.signal(); return }
                let stillPending = self.pendingWrites.contains {
                    $0.isStop && !$0.timedOut && $0.onAck != nil
                }
                if stillPending {
                    for i in self.pendingWrites.indices where self.pendingWrites[i].isStop {
                        self.pendingWrites[i].onAck = nil
                    }
                    done.signal()
                }
                // 已出最终结果：onAck 已经 signal 过了，这里不再补
            }
            // 被动停机：通知 VM 把界面输出归零（修 高1）
            self.notifyForceZero()
        }
        _ = done.wait(timeout: .now() + 2.0)
    }

    // MARK: - 用户主动发送（会重新打开输出闸门）

    /// 发送 0x06 控制帧（四通道强度 0~99）
    func send(channels: [Int]) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.outputLocked = false
            self.enqueueFrame(Protocol.frame(channels: channels))
        }
    }

    /// 节流延迟帧专用：不重新开闸（修 N2 —— 停机后排队的尾帧必须丢掉）
    func sendThrottled(channels: [Int]) {
        bleQueue.async { [weak self] in
            guard let self = self, !self.outputLocked else { return }
            self.enqueueFrame(Protocol.frame(channels: channels))
        }
    }

    /// 视频 tick 专用：不开闸（修 C）。
    /// 看门狗 / emergencyStop 锁住闸后，tick 的自动帧不许再把它打开；
    /// 只有用户点"播放"（userResumeOutput）才能开闸。
    func sendTick(channels: [Int]) {
        bleQueue.async { [weak self] in
            guard let self = self, !self.outputLocked else { return }
            self.enqueueFrame(Protocol.frame(channels: channels))
        }
    }

    /// 用户在视频页点了"播放"：显式打开输出闸门（修 C）
    func userResumeOutput() {
        bleQueue.async { [weak self] in
            self?.outputLocked = false
        }
    }

    func sendStop() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.outputLocked = false
            self.enqueueFrame(Protocol.stopFrame)
        }
    }

    func sendOfficialStart() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.outputLocked = false
            self.enqueueFrame(Protocol.officialStartFrame)
        }
    }

    // MARK: - 内部（bleQueue 上）

    /// 入队并发送一帧，返回该笔写入的 id（发不出去返回 -1）；调用方保证在 bleQueue 上
    @discardableResult
    private func enqueueFrame(_ data: Data, onAck: (() -> Void)? = nil) -> Int {
        guard let p = peripheral,
              let c = writeChar,
              queueState == .ready else { return -1 }
        writeSeq += 1
        let id = writeSeq
        pendingWrites.append(PendingWrite(
            id: id,
            hex: Protocol.hex(data),
            data: data,
            isStop: data == Protocol.stopFrame,
            retryCount: 0,
            onAck: onAck,
            timedOut: false
        ))
        p.writeValue(data, for: c, type: .withResponse)
        if data != Protocol.stopFrame {
            // 修 F：isActive 只在停止帧回执成功后才清零；
            // 发出时不清，否则写失败会被当成"已停止"
            isActive = true
            stopWriteFailed = false
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
            enqueueRetry(w)
        } else {
            // 停止帧两次都没结果：按"设备可能还在输出"处理（修 F）
            stopWriteFailed = true
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "停止帧写入超时，设备可能仍在输出，请直接关闭设备电源"
            }
        }
    }

    /// 停止帧重试：新 id、队尾追加、继承 onAck（修 D：不插队头）
    private func enqueueRetry(_ w: PendingWrite) {
        guard let p = peripheral, let c = writeChar, queueState == .ready else {
            // 连发都发不出去了：按最终失败处理
            stopWriteFailed = true
            w.onAck?()
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "停止帧写入失败，设备可能仍在输出，请直接关闭设备电源"
            }
            return
        }
        writeSeq += 1
        let id = writeSeq
        pendingWrites.append(PendingWrite(
            id: id, hex: w.hex, data: w.data, isStop: true,
            retryCount: w.retryCount + 1, onAck: w.onAck, timedOut: false
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
        peripheral = nil
        writeChar = nil
        pendingPeripheral = nil
        pendingWrites = []
        isActive = false
        activeSince = nil
        stopWriteFailed = false
        lastHeartbeat = nil
        outputLocked = true
        updateState(.idle)
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
        queueState = .failed
        DispatchQueue.main.async { [weak self] in
            self?.lastError = msg
            self?.state = .failed
        }
    }

    /// 清掉界面上的旧红字（修 N8）；调用方保证在 bleQueue 上
    private func clearError() {
        DispatchQueue.main.async { [weak self] in self?.lastError = nil }
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
        if queueState == .ready, isActive, !stopWriteFailed {
            // 全局 30 分钟上限
            if let since = activeSince, now.timeIntervalSince(since) > Self.maxActiveSeconds {
                enqueueFrame(Protocol.stopFrame)
                outputLocked = true
                notifyForceZero()
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "单次连续输出超过 30 分钟，已自动停止"
                }
            } else if let hb = lastHeartbeat,
                      now.timeIntervalSince(hb) > Self.watchdogInterval,
                      peripheral != nil, writeChar != nil {
                // 有非零输出在设备上，但界面心跳断了 >5s：UI 线程可能卡死，自动停机
                enqueueFrame(Protocol.stopFrame)
                outputLocked = true // 修 高1：看门狗停机也要锁闸
                notifyForceZero()   // 修 高1：通知 VM 把界面输出归零
                DispatchQueue.main.async { [weak self] in
                    self?.lastError = "看门狗：界面心跳丢失，已自动停止"
                }
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
            peripheral = nil
            writeChar = nil
            pendingPeripheral = nil
            pendingWrites = []
            isActive = false
            activeSince = nil
            stopWriteFailed = false
            lastHeartbeat = nil
            outputLocked = true
            updateState(.idle)
            // 修 N9 小尾巴：unauthorized 和 poweredOff 的文案分开
            let msg = central.state == .unauthorized
                ? "蓝牙权限未授权，请去系统设置里打开"
                : "蓝牙已关闭"
            DispatchQueue.main.async { [weak self] in
                self?.lastError = msg
                self?.showDeviceConfirm = false
            }
            return
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
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
        clearError() // 修 N8：连上就清掉旧红字
        updateState(.discovering)
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        setError("连接失败：\(error?.localizedDescription ?? "未知")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // 修 G：只处理当前这台外设的回调；
        // finishDisconnect 里 cancelPeripheralConnection 的迟到回调会被忽略，
        // 不会把用户新发起的扫描状态冲回"未连接"
        guard let cur = self.peripheral, cur.identifier == peripheral.identifier else { return }
        // 意外断开：清理并通知 UI（VM 会订阅 state 变化停掉 Timer、归零滑杆）
        self.peripheral = nil
        self.writeChar = nil
        self.pendingWrites = []
        self.isActive = false
        self.activeSince = nil
        self.stopWriteFailed = false
        self.lastHeartbeat = nil
        self.outputLocked = true
        if let error = error {
            setError("设备意外断开：\(error.localizedDescription)")
        } else {
            updateState(.idle)
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { setError("发现服务失败：\(error.localizedDescription)"); return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            setError("未找到 FFA0 服务")
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error { setError("发现特征值失败：\(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            if c.uuid == Self.writeUUID {
                writeChar = c
            } else if c.uuid == Self.notifyUUID {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        if writeChar != nil {
            clearError() // 修 N8：真正连上后清掉旧红字
            updateState(.ready)
        } else {
            setError("未找到 FFA1 写特征值")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.writeUUID else { return }
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
                // 停止帧写失败立刻重试一次，追加到队尾（修 #3、D）
                enqueueRetry(w)
            } else {
                w.onAck?()
                if w.isStop {
                    // 修 F：停止帧最终失败，按"设备可能还在输出"处理
                    stopWriteFailed = true
                    DispatchQueue.main.async { [weak self] in
                        self?.lastError = "停止帧写入失败，设备可能仍在输出，请直接关闭设备电源"
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.lastError = "写入失败：\(error.localizedDescription)"
                    }
                }
            }
            return
        }
        // 成功：这个回执对应的那一帧才是"最后一帧"
        if w.isStop {
            // 修 F：只有回执成功才算真的停了
            isActive = false
            activeSince = nil
            stopWriteFailed = false
        }
        let hex = w.hex
        DispatchQueue.main.async { [weak self] in
            self?.lastSentHex = hex
        }
        w.onAck?()
    }
}
