import SwiftUI
import AVKit
import UniformTypeIdentifiers
import Combine

/// 视频联动播放器（ViewModel）
final class VideoSyncPlayer: ObservableObject {
    @Published var player: AVPlayer?
    @Published var script: TimelineScript?
    @Published var scriptName: String = "未载入脚本"
    @Published var videoName: String = "未选择视频"
    @Published var isPlaying = false
    @Published var statusLine: String = "—"
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0

    /// 单次联动最长 30 分钟，超时自动停
    static let maxSessionSeconds: TimeInterval = 30 * 60

    private var timer: Timer?
    private var lastActive = ActiveChannels.zero
    private weak var ble: BLEManager?
    /// 状态订阅（attach 可安全重建）；播放器订阅（duration/timeControlStatus）单独管理，
    /// 只在换播放器时清理 —— attach 挂在 Section.onAppear 上，滚动重触发时不会
    /// 把还没回来的 duration 订阅一起清掉（修 N4）
    private var stateCancellables = Set<AnyCancellable>()
    private var playerCancellables = Set<AnyCancellable>()
    private var sessionStart: Date?

    /// seek 代次：拖进度条会连发多个 seek，只有最新的回调有效（修 #5 的小尾巴）
    private var seekGen = 0
    private var seekInFlight = 0

    /// 重连后强制重发首帧（修 N6：避免被"没有变化"吞掉）
    private var needsResync = false

    func attach(ble: BLEManager) {
        // N4：切 Tab 回来会重复 attach，只清状态订阅；
        // 播放器订阅在 playerCancellables 里，不受影响
        stateCancellables.removeAll()
        self.ble = ble
        // 意外断开：停掉 Timer，界面不再显示"播放中"
        ble.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self = self else { return }
                if s == .ready {
                    self.needsResync = true
                } else if self.isPlaying {
                    self.player?.pause()
                    self.isPlaying = false
                    // 断开了，发也发不出去，直接停 Timer 不补发
                    self.stopTimer(sendZero: false)
                    self.statusLine = "设备已断开，联动已停止"
                }
            }
            .store(in: &stateCancellables)
        // 被动停机（看门狗/退后台/30 分钟上限）：只归零 UI，不补发停止帧
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.passiveStop() }
            .store(in: &stateCancellables)
        // 修 M5：timeControlStatus 订阅只在 loadVideo 里挂一次，attach 不再重复添加
    }

    private func observeTimeControlStatus(_ p: AVPlayer) {
        p.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                // 外部把播放器停了，但 vm 还以为在播：同步停机
                if status == .paused, self.isPlaying, self.seekInFlight == 0 {
                    // 修 M4：最后 0.5 秒内停下（自然播完，或来电/耳机暂停）同样必须停机，
                    // 只是提示文案不同；直接 return 会让设备停在最后一帧强度上
                    if self.durationSeconds > 0,
                       self.currentSeconds >= self.durationSeconds - 0.5 {
                        self.stopAll()
                        self.statusLine = "播放结束，设备已停止"
                        return
                    }
                    self.isPlaying = false
                    self.stopTimer(sendZero: true)
                    self.statusLine = "外部暂停，设备已停止"
                }
            }
            .store(in: &playerCancellables)
    }

    func loadVideo(url: URL) {
        // N3：换视频前先停掉旧的，避免旧 Timer 读新 player 的 t=0 误驱动设备
        stopAll()
        // 修 N4：旧播放器的订阅在这里释放，KVO 不再持有旧 player
        playerCancellables.removeAll()
        videoName = url.lastPathComponent
        let p = AVPlayer(url: url)
        player = p
        observeTimeControlStatus(p)
        if let dur = p.currentItem?.duration.seconds, dur.isFinite {
            durationSeconds = dur
        } else {
            p.currentItem?.publisher(for: \.duration)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] d in
                    if d.seconds.isFinite { self?.durationSeconds = d.seconds }
                }
                .store(in: &playerCancellables)
        }
        currentSeconds = 0
    }

    func loadScript(url: URL) {
        // N3：换脚本前先停
        stopAll()
        do {
            let data = try Data(contentsOf: url)
            script = try JSONDecoder().decode(TimelineScript.self, from: data)
            scriptName = url.lastPathComponent
            if let s = script {
                // 高6 建议：刻度声明写错回退自动判断时明确提示
                let warn = s.scaleFallback ? "（intensityScale 无法识别，已自动判断）" : ""
                statusLine = "脚本就绪：\(s.commands.count) 条命令，\(s.scaleDescription)刻度\(warn)"
            }
        } catch {
            scriptName = "解析失败：\(error.localizedDescription)"
        }
    }

    func togglePlay() {
        guard let p = player, script != nil, ble?.state == .ready else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            stopTimer(sendZero: true)
            statusLine = "已暂停"
        } else {
            let t = p.currentTime().seconds
            let needsRestart = durationSeconds > 0 && t.isFinite && t >= durationSeconds - 0.5
            sessionStart = Date()
            isPlaying = true
            // 修 C：用户点"播放"才显式开闸；tick 自己不会开闸
            ble?.userResumeOutput()
            if needsRestart {
                // 播完了从头来：等 seek 完成再开播（修 #5 的小尾巴）
                seekGen += 1
                let gen = seekGen
                seekInFlight += 1
                p.seek(to: .zero) { [weak self] _ in
                    // 修 CC L4：AVPlayer 不保证回调线程，回到主线程再改状态
                    DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.seekInFlight = max(0, self.seekInFlight - 1)
                    // 修 B：seek 完成前用户点了暂停/停止/切 Tab，或设备断开，
                    // 不许把播放复活 —— 否则界面显示已停，设备却继续跟视频走，
                    // 且 sessionStart 已是 nil，30 分钟上限和看门狗都管不到
                    guard gen == self.seekGen, self.isPlaying else { return }
                    self.lastActive = .zero
                    self.currentSeconds = 0
                    p.play()
                    self.startTimer()
                    }
                }
            } else {
                p.play()
                startTimer()
            }
        }
    }

    /// 用户拖进度条：走 vm，seek 完成后立即同步一次设备状态
    func seek(to seconds: Double) {
        guard let p = player else { return }
        seekGen += 1
        let gen = seekGen
        seekInFlight += 1
        let wasPlaying = isPlaying
        p.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in // 修 CC L4
            guard let self = self else { return }
            self.seekInFlight = max(0, self.seekInFlight - 1)
            // 被更新的 seek 抢先了，这个回调作废
            guard gen == self.seekGen else { return }
            self.currentSeconds = seconds
            // 以回调时的状态为准：seek 期间用户点了暂停/停止，不再发帧
            guard wasPlaying, self.isPlaying else { return }
            // 修 M3：重播的 seek 被这次拖动抢掉时，重播回调不会 play/启动 Timer，
            // 这里补上，避免"按钮显示在播、视频不动、设备卡在一帧上"
            if self.timer == nil {
                p.play()
                self.startTimer()
            }
            // seek 后强制算一次，避免设备停在旧强度
            self.tick(force: true)
            }
        }
    }

    func stopAll() {
        player?.pause()
        isPlaying = false
        stopTimer(sendZero: true)
        sessionStart = nil
        statusLine = "—"
    }

    /// 被动停机（看门狗/退后台/30 分钟上限）：只归零 UI，不补发停止帧
    /// （停止帧已经发出去了，再发一次反而可能把闸重新打开）
    private func passiveStop() {
        player?.pause()
        isPlaying = false
        stopTimer(sendZero: false)
        lastActive = .zero
        sessionStart = nil
        statusLine = "已自动停止"
    }

    var canPlay: Bool {
        player != nil && script != nil && ble?.state == .ready
    }

    // MARK: - 内部

    private func startTimer() {
        stopTimer(sendZero: false)
        // N5：用 common modes，滚动 Form 时 tick 不暂停
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer(sendZero: Bool) {
        timer?.invalidate()
        timer = nil
        if sendZero {
            ble?.sendStop()
            lastActive = .zero
        }
    }

    /// 每 100ms 按当前播放时间计算激活通道，变化时才发帧
    private func tick(force: Bool = false) {
        guard let p = player, let s = script, let ble = ble else { return }
        // 修 CC L6：拖进度条期间界面是活的，心跳照发，避免长时间拖动误触看门狗
        ble.heartbeat()
        guard seekInFlight == 0 else { return }
        let t = p.currentTime().seconds
        guard t.isFinite else { return }

        // 会话超时保护：先停，再写提示（修 N11：提示不被 stopAll 覆盖）
        if let start = sessionStart,
           Date().timeIntervalSince(start) > Self.maxSessionSeconds {
            sessionStart = nil
            stopAll()
            statusLine = "单次联动超过 30 分钟，已自动停止"
            return
        }


        currentSeconds = t

        var vals = [0, 0, 0, 0]
        for cmd in s.commands {
            guard t >= cmd.startTimeSeconds, t < cmd.endTime,
                  let ch = cmd.channel else { continue }
            vals[ch.rawValue] = max(vals[ch.rawValue], s.intensity99(for: cmd))
        }
        let active = ActiveChannels(values: vals)
        if force || needsResync || active != lastActive {
            needsResync = false
            lastActive = active
            // 修 C：tick 走不开闸的发送路径，看门狗锁住的闸不会被自动帧打开
            ble.sendTick(channels: vals)
            let names = ["伸缩", "震动", "吮吸", "旋转"]
            let desc = vals.enumerated().map { "\(names[$0.offset]):\($0.element)" }.joined(separator: " ")
            statusLine = String(format: "t=%.1fs %@", t, desc)
        }
        if durationSeconds > 0, t >= durationSeconds {
            stopAll()
        }
    }
}

/// 无系统控件的视频预览（系统自带播放/暂停/拖动会绕过 vm，必须禁用）
struct NoControlsPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

/// 视频联动：播本地视频，按时间轴脚本自动发 0x06 帧
struct VideoSyncView: View {
    @EnvironmentObject var ble: BLEManager
    @StateObject private var vm = VideoSyncPlayer()
    @State private var showVideoPicker = false
    @State private var showScriptPicker = false

    var body: some View {
        Form {
            Section("设备") {
                HStack {
                    Text(ble.state.rawValue)
                        .foregroundColor(ble.state == .ready ? .green : .secondary)
                    Spacer()
                    if ble.state != .ready {
                        Button("连接") { ble.startScan() }
                            .disabled(ble.state == .scanning || ble.state == .connecting || ble.state == .discovering || ble.state == .disconnecting)
                    }
                }
                if let err = ble.lastError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }
            .onAppear { vm.attach(ble: ble) }

            Section("素材") {
                HStack {
                    Text("视频"); Spacer()
                    Text(vm.videoName).foregroundColor(.secondary).lineLimit(1)
                    Button("选择") { showVideoPicker = true }
                }
                HStack {
                    Text("脚本"); Spacer()
                    Text(vm.scriptName).foregroundColor(.secondary).lineLimit(1)
                    Button("载入") { showScriptPicker = true }
                }
                if let s = vm.script {
                    Text("\(s.commands.count) 条命令")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            Section("播放控制") {
                HStack {
                    Button(vm.isPlaying ? "暂停" : "播放") { vm.togglePlay() }
                        .disabled(!vm.canPlay)
                    Spacer()
                    Button("停止", role: .destructive) { vm.stopAll() }
                }
                // 自建进度条：拖动走 vm.seek，设备状态同步跟上
                if vm.durationSeconds > 0 {
                    Slider(
                        value: Binding(
                            get: { vm.currentSeconds },
                            set: { vm.seek(to: $0) }
                        ),
                        in: 0...vm.durationSeconds
                    )
                    .disabled(!vm.canPlay)
                    Text("\(formatTime(vm.currentSeconds)) / \(formatTime(vm.durationSeconds))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text(vm.statusLine)
                    .font(.caption).foregroundColor(.secondary)
            }

            if let p = vm.player {
                Section("预览") {
                    NoControlsPlayerView(player: p)
                        .frame(height: 220)
                }
            }
        }
        .navigationTitle("视频联动")
        .sheet(isPresented: $showVideoPicker) {
            DocumentPicker(contentTypes: [UTType.movie, UTType.video]) { url in
                vm.loadVideo(url: url)
            }
        }
        .sheet(isPresented: $showScriptPicker) {
            DocumentPicker(contentTypes: [UTType.json]) { url in
                vm.loadScript(url: url)
            }
        }
        .onDisappear { vm.stopAll() }
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

/// 系统文件选择器（asCopy: true，文件拷进沙盒，不玩 security-scoped 杂技）
struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
