import SwiftUI
import Combine

/// 手动控制的 ViewModel：带后缘节流的强度发送
final class ManualControlVM: ObservableObject {
    @Published var channels: [Double] = [0, 0, 0, 0]
    /// 当前控制方式（官方三个 tab：技能 / 变频 / 手动）
    @Published private(set) var mode: BCProtocol.Mode = .frequency
    /// 技能 tab 当前选中的预设
    @Published private(set) var selectedPreset: String?

    private weak var ble: BLEManager?
    /// 上次发送时间（单调时钟，修 L7）
    private var lastSend = -Double.infinity
    private var pendingWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// 手动页心跳定时器：滑杆停住不动时也要告诉看门狗"我还活着"，
    /// 否则 5 秒就被误杀（修 N1）
    private var heartbeatTimer: Timer?
    /// 上次停止以来发过输出（有输出才需要空闲停机）
    private var outputSinceStop = false
    /// 最近一次用户操作（单调时钟）
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    /// 空闲停机后的提示；用户再操作时清掉
    @Published private(set) var idleNotice: String?

    static let throttleInterval: TimeInterval = 0.12
    /// 手动页这么久没有任何操作就自动停止输出（L7）：心跳只证明界面活着，不证明有人在操作
    static let idleTimeout: TimeInterval = 300

    func attach(ble: BLEManager) {
        // N4：切 Tab 回来会重复 attach，先清掉旧的订阅
        cancellables.removeAll()
        self.ble = ble
        // 断开后滑杆归零，避免 UI 显示和设备实际状态不一致
        ble.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                if s != .ready { self?.reset() }
            }
            .store(in: &cancellables)
        // 被动停机（看门狗/退后台/上限/输出被拒）：滑杆归零（修 高1）；原因由 BLEManager 显示在红字里
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reset() }
            .store(in: &cancellables)
        startHeartbeatTimer()
    }

    /// 离开手动页时调用：停心跳、清订阅（stopAll 另行调用）
    func detach() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        cancellables.removeAll()
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let idle = ProcessInfo.processInfo.systemUptime - self.lastInteraction
            if self.outputSinceStop, idle >= Self.idleTimeout {
                self.stopAll()
                self.idleNotice = "\(Int(Self.idleTimeout / 60)) 分钟没有操作，已自动停止输出"
                return
            }
            self.ble?.heartbeat()
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func noteInteraction() {
        lastInteraction = ProcessInfo.processInfo.systemUptime
        idleNotice = nil
    }

    func setChannel(_ index: Int, _ value: Double) {
        guard mode != .skill else { return }
        noteInteraction()
        outputSinceStop = true
        channels[index] = value
        scheduleSend()
    }

    /// 切换控制方式：先停机归零，避免 0~9 和 0~99 的值串用
    func setMode(_ newMode: BCProtocol.Mode) {
        guard newMode != mode else { return }
        noteInteraction()
        stopAll()
        mode = newMode
    }

    /// 技能 tab：发官方预设（0x06）
    func selectPreset(_ preset: BCProtocol.Preset) {
        noteInteraction()
        outputSinceStop = true
        pendingWork?.cancel()
        pendingWork = nil
        selectedPreset = preset.key
        channels = preset.channels.map(Double.init)
        ble?.send(frame: BCProtocol.modeFrame(channels: preset.channels))
        ble?.heartbeat()
    }

    func stopAll() {
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        selectedPreset = nil
        outputSinceStop = false
        // 停止会锁闸（M3）：下一次拖动必须是开闸的前沿帧，不能落进节流尾帧
        lastSend = -Double.infinity
        // 停止帧对：0x08 归零帧 → 100ms → 0x06 停止帧（BLEManager 统一处理）
        ble?.sendStop()
    }

    func reset() {
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        selectedPreset = nil
        outputSinceStop = false
        lastSend = -Double.infinity
    }

    /// 后缘节流：120ms 内只发一帧，但最后一次的值一定补发（降强度不能丢）
    private func scheduleSend() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSend
        if elapsed >= Self.throttleInterval {
            lastSend = now
            pendingWork?.cancel()
            pendingWork = nil
            sendNow()
        } else {
            pendingWork?.cancel()
            let snapshot = channels
            let snapMode = mode
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastSend = ProcessInfo.processInfo.systemUptime
                // 延迟帧走 sendThrottled：不断开输出闸门。
                // 停机/断开后这帧会被丢掉，避免"停止帧之后又来一帧非零"（修 N2）
                self.ble?.sendThrottled(frame: snapMode.frame(channels: snapshot.map { Int($0) }))
                self.ble?.heartbeat()
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.throttleInterval - elapsed),
                execute: work
            )
        }
    }

    private func sendNow() {
        ble?.send(frame: mode.frame(channels: channels.map { Int($0) }))
        ble?.heartbeat()
    }
}

/// 手动控制：四通道强度滑杆 + 启动/停止
struct ManualControlView: View {
    @EnvironmentObject var ble: BLEManager
    @StateObject private var vm = ManualControlVM()

    private var modeFooter: String {
        switch vm.mode {
        case .skill: return "官方 App 的五个固定技能，0x06 帧"
        case .frequency: return "官方变频：每通道 0~9，0x06 帧"
        case .manual: return "官方手动：每通道 0~99，0x08 帧"
        }
    }

    /// 连上了且现在允许开始/继续输出（冷却、额度、锁存、停止未确认时禁用；停止按钮不受影响）
    private var canOutput: Bool {
        ble.state == .ready && ble.safety.blockReason == nil
    }

    /// 版本号 + 构建提交（修 L14：CI 构建时写入 BCGitCommit）
    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["BCGitCommit"] as? String ?? "").prefix(7)
        return commit.isEmpty ? "版本 \(ver) (\(build))" : "版本 \(ver) (\(build)) · \(commit)"
    }

    var body: some View {
        Form {
            DeviceStatusSection(allowDisconnect: true, connectTitle: "连接 mizzzee_0032")

            Section {
                Picker("控制方式", selection: Binding(
                    get: { vm.mode },
                    set: { vm.setMode($0) }
                )) {
                    ForEach(BCProtocol.Mode.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(ble.state != .ready)
            } footer: {
                Text(modeFooter)
            }

            if vm.mode == .skill {
                Section("官方技能") {
                    ForEach(BCProtocol.presets) { p in
                        Button {
                            vm.selectPreset(p)
                        } label: {
                            HStack {
                                Text(p.title)
                                Spacer()
                                Text(p.channels.map(String.init).joined(separator: " "))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                                if vm.selectedPreset == p.key {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                        .disabled(!canOutput)
                    }
                }
            } else {
                Section {
                    // 修 N5：旋转通道不显示（协议里恒发 0）
                    ForEach(BCProtocol.Channel.uiChannels, id: \.rawValue) { ch in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(ch.displayName)
                                Spacer()
                                Text("\(Int(vm.channels[ch.rawValue]))")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { vm.channels[ch.rawValue] },
                                    set: { vm.setChannel(ch.rawValue, $0) }
                                ),
                                in: 0...Double(vm.mode.maxLevel), step: 1
                            )
                        }
                        .disabled(!canOutput)
                    }
                } header: {
                    Text("通道强度（0~\(vm.mode.maxLevel)）")
                } footer: {
                    Text("旋转通道官方 mizzzee 配置未使用，已隐藏（恒发 0）")
                }
            }

            Section {
                Button("停止", role: .destructive) { vm.stopAll() }
                    .frame(maxWidth: .infinity)
                    .disabled(ble.state != .ready)
            } footer: {
                if let notice = vm.idleNotice {
                    Text(notice).foregroundColor(.orange)
                } else {
                    Text("\(Int(ManualControlVM.idleTimeout / 60)) 分钟没有操作会自动停止")
                }
            }

            Section("最后一帧") {
                Text(ble.lastSentHex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("仅在收到写入回执后更新（链路层回执，不代表设备已执行）")
                    .font(.caption2).foregroundColor(.secondary)
                // 修 L1：FFA2 通知原样显示（含义未知，只记录）
                Text("设备通知（FFA2）：\(ble.lastNotifyHex)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(versionText)
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .navigationTitle("手动控制")
        // 修 CC r2 L7：attach 挂在整个 Form 上，与 detach 对称；设备区块滚出屏幕也能重新挂上
        .onAppear { vm.attach(ble: ble) }
        // 切走 Tab 时停机：避免滑杆显示 50、设备实际跟视频走的不一致（修 #6 的小尾巴）
        .onDisappear {
            vm.stopAll()
            vm.detach()
        }
    }
}
