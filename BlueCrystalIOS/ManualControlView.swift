import SwiftUI
import Combine

/// 手动控制的 ViewModel：带后缘节流的强度发送
final class ManualControlVM: ObservableObject {
    @Published var channels: [Double] = [0, 0, 0, 0]

    private weak var ble: BLEManager?
    private var lastSend = Date.distantPast
    private var pendingWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// 手动页心跳定时器：滑杆停住不动时也要告诉看门狗"我还活着"，
    /// 否则 5 秒就被误杀（修 N1）
    private var heartbeatTimer: Timer?

    static let throttleInterval: TimeInterval = 0.12

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
        // 被动停机（看门狗/退后台）：滑杆归零（修 高1）
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reset() }
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
            self?.ble?.heartbeat()
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    func setChannel(_ index: Int, _ value: Double) {
        channels[index] = value
        scheduleSend()
    }

    func stopAll() {
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        ble?.sendStop()
    }

    func reset() {
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        lastSend = .distantPast
    }

    /// 后缘节流：120ms 内只发一帧，但最后一次的值一定补发（降强度不能丢）
    private func scheduleSend() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSend)
        if elapsed >= Self.throttleInterval {
            lastSend = now
            pendingWork?.cancel()
            pendingWork = nil
            sendNow()
        } else {
            pendingWork?.cancel()
            let snapshot = channels
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastSend = Date()
                // 延迟帧走 sendThrottled：不断开输出闸门。
                // 停机/断开后这帧会被丢掉，避免"停止帧之后又来一帧非零"（修 N2）
                self.ble?.sendThrottled(channels: snapshot.map { Int($0) })
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
        ble?.send(channels: channels.map { Int($0) })
        ble?.heartbeat()
    }
}

/// 手动控制：四通道强度滑杆 + 启动/停止
struct ManualControlView: View {
    @EnvironmentObject var ble: BLEManager
    @StateObject private var vm = ManualControlVM()

    var body: some View {
        Form {
            Section("设备") {
                HStack {
                    Text(ble.state.rawValue)
                        .foregroundColor(ble.state == .ready ? .green : .secondary)
                    Spacer()
                    if ble.state == .ready {
                        Button("断开") { ble.disconnect() }
                    } else {
                        Button("连接 mizzzee_0032") { ble.startScan() }
                            .disabled(ble.state == .scanning || ble.state == .connecting)
                    }
                }
                if let err = ble.lastError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }
            .onAppear { vm.attach(ble: ble) }

            Section("四通道强度") {
                ForEach(Protocol.Channel.allCases, id: \.rawValue) { ch in
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
                            in: 0...99, step: 1
                        )
                    }
                    .disabled(ble.state != .ready)
                }
            }

            Section("快捷") {
                HStack {
                    Button("官方启动帧") {
                        ble.sendOfficialStart()
                        ble.heartbeat()
                    }
                    Spacer()
                    Button("停止", role: .destructive) { vm.stopAll() }
                }
                .disabled(ble.state != .ready)
            }

            Section("最后一帧") {
                Text(ble.lastSentHex)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("仅在设备确认收到后更新")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .navigationTitle("手动控制")
        // 切走 Tab 时停机：避免滑杆显示 50、设备实际跟视频走的不一致（修 #6 的小尾巴）
        .onDisappear {
            vm.stopAll()
            vm.detach()
        }
    }
}
