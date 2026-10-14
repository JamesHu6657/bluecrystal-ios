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

    private var timer: Timer?
    private var lastActive = ActiveChannels.zero
    private weak var ble: BLEManager?
    /// 状态订阅（attach 可安全重建）；播放器订阅（duration/timeControlStatus）单独管理，
    /// 只在换播放器时清理 —— attach 每次 onAppear 都会重跑（修 CC r3 L4：已移到 Form 上），重触发时不会
    /// 把还没回来的 duration 订阅一起清掉（修 N4）
    private var stateCancellables = Set<AnyCancellable>()
    private var playerCancellables = Set<AnyCancellable>()
    /// 上一次 tick 采样的播放时间（修 L11：两次采样之间整段结束的短命令也要发一次）
    private var lastSampleTime: Double?
    /// 播放起点尚未采样：覆盖当时已经开始的短命令；正常采样不延长已发命令。
    private var samplingFromPlaybackStart = false

    /// seek 代次：拖进度条会连发多个 seek，只有最新的回调有效（修 #5 的小尾巴）
    private var seekGen = 0
    private var seekInFlight = 0
    /// 修 CC r3 L3：seek 期间 KVO 看到的外部暂停（此时被 seekInFlight 跳过），重播回调据此不再 play
    private var pausedDuringSeek = false

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
        // 被动停机（看门狗/退后台/单次上限/输出被拒）：只归零 UI，不补发停止帧
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in self?.passiveStop(reason: reason) }
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
                    self.handleExternalPause()
                } else if status == .paused, self.isPlaying {
                    // 修 CC r3 L3：seek 期间先记下，由 seek 回调处理
                    self.pausedDuringSeek = true
                }
            }
            .store(in: &playerCancellables)
    }

    /// 外部暂停/播完的停机处理；seek 完成时也会补查一次（修 CC r2 L4）
    private func handleExternalPause() {
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

    func loadVideo(url: URL) {
        // N3：换视频前先停掉旧的，避免旧 Timer 读新 player 的 t=0 误驱动设备
        stopAll()
        // 修 N4：旧播放器的订阅在这里释放，KVO 不再持有旧 player
        playerCancellables.removeAll()
        // 修 CC r2 L4：旧播放器未完成的 seek 回调作废
        seekGen += 1
        seekInFlight = 0
        // 换视频：先把上一个视频的时长/进度清掉，新时长回来前不显示旧值
        durationSeconds = 0
        currentSeconds = 0
        lastActive = .zero
        let displayName = url.lastPathComponent
        // 拷到 App 自己的目录、文件名加唯一前缀：选择器给的临时副本可能被系统清掉，
        // 同名文件也不会互相覆盖
        guard let local = Self.importVideo(from: url) else {
            if let old = currentVideoFile { try? FileManager.default.removeItem(at: old) }
            currentVideoFile = nil
            player = nil
            videoName = "导入失败：\(displayName)"
            statusLine = "视频文件无法读取，请重新选择"
            return
        }
        if let old = currentVideoFile, old != local {
            try? FileManager.default.removeItem(at: old)
        }
        currentVideoFile = local
        videoName = displayName
        let item = AVPlayerItem(asset: AVURLAsset(url: local))
        let p = AVPlayer(playerItem: item)
        player = p
        observeTimeControlStatus(p)
        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak p] d in
                guard let self = self, let p = p, p === self.player else { return }
                if d.seconds.isFinite, d.seconds > 0 { self.durationSeconds = d.seconds }
            }
            .store(in: &playerCancellables)
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak p] st in
                guard let self = self, let p = p, p === self.player else { return }
                switch st {
                case .failed:
                    self.stopAll()
                    let reason = p.currentItem?.error?.localizedDescription ?? "未知错误"
                    self.statusLine = "视频无法播放：\(reason)"
                case .readyToPlay:
                    if self.statusLine == "—" { self.statusLine = "视频就绪" }
                default:
                    break
                }
            }
            .store(in: &playerCancellables)
    }

    /// 当前视频在 App 目录里的副本（换视频时删旧的，避免占空间）
    private var currentVideoFile: URL?

    init() {
        // 上次运行留下的视频副本清掉
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncVideos", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private static func importVideo(from url: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SyncVideos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // 选择器 asCopy 已经给了一份临时副本，优先移动，失败再拷贝
            do { try fm.moveItem(at: url, to: dest) } catch { try fm.copyItem(at: url, to: dest) }
            return dest
        } catch {
            return nil
        }
    }

    func loadScript(url: URL) {
        // N3：换脚本前先停
        stopAll()
        // 修 M6：解析失败时不能留着旧脚本继续可播
        script = nil
        do {
            let data = try Data(contentsOf: url)
            script = try JSONDecoder().decode(TimelineScript.self, from: data)
            scriptName = url.lastPathComponent
            if let s = script {
                var notes: [String] = []
                // 高6 建议：刻度声明写错时明确提示
                if s.scaleFallback { notes.append("intensityScale 无法识别") }
                // 修 L9：刻度分不清时按较弱的百分制，提示用户声明
                if s.scaleAmbiguous {
                    notes.append("未声明刻度且所有值 ≤10，已按较弱的百分制处理；十档脚本请加 \"intensityScale\": \"ten\"")
                }
                // 修 N5：旋转通道恒为 0
                if s.ignoredRotationCount > 0 { notes.append("\(s.ignoredRotationCount) 条旋转命令已忽略") }
                let warn = notes.isEmpty ? "" : "（" + notes.joined(separator: "；") + "）"
                statusLine = "脚本就绪：\(s.commands.count) 条命令，\(s.scaleDescription)刻度\(warn)"
            }
        } catch {
            scriptName = "解析失败：\(error.localizedDescription)"
            statusLine = "脚本解析失败，请重新选择"
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
            // 修 M2/M3：冷却 / 额度 / 锁存 / 停止未确认时不开播（BLEManager 也会拦截）
            if let reason = ble?.safety.blockReason {
                statusLine = reason
                return
            }
            let t = p.currentTime().seconds
            let needsRestart = durationSeconds > 0 && t.isFinite && t >= durationSeconds - 0.5
            lastSampleTime = t.isFinite ? t : nil
            samplingFromPlaybackStart = true
            isPlaying = true
            // 修 C：用户点"播放"才显式开闸；tick 自己不会开闸
            ble?.userResumeOutput()
            if needsRestart {
                // 播完了从头来：等 seek 完成再开播（修 #5 的小尾巴）
                seekGen += 1
                let gen = seekGen
                seekInFlight += 1
                pausedDuringSeek = false // 修 CC r3 L3
                p.seek(to: .zero) { [weak self] _ in
                    // 修 CC L4：AVPlayer 不保证回调线程，回到主线程再改状态
                    DispatchQueue.main.async { [weak self] in
                    // 修 CC r3 L2：换过视频后旧播放器的回调不许碰新播放器的计数和状态
                    guard let self = self, p === self.player else { return }
                    self.seekInFlight = max(0, self.seekInFlight - 1)
                    // 修 B：seek 完成前用户点了暂停/停止/切 Tab，或设备断开，
                    // 不许把播放复活 —— 否则界面显示已停，设备却继续跟视频走
                    guard gen == self.seekGen, self.isPlaying else { return }
                    self.lastActive = .zero
                    self.currentSeconds = 0
                    // 修 CC r3 L3：seek 期间被外部暂停过，不复活播放，按外部暂停停机
                    if self.pausedDuringSeek {
                        self.pausedDuringSeek = false
                        self.handleExternalPause()
                        return
                    }
                    self.lastSampleTime = p.currentTime().seconds
                    self.samplingFromPlaybackStart = true
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
            // 修 CC r3 L2：换过视频后旧播放器的回调不许碰新播放器的计数和状态
            guard let self = self, p === self.player else { return }
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
            } else if p.timeControlStatus == .paused {
                // 修 CC r2 L4：seek 期间的外部暂停被跳过了，这里补上
                self.handleExternalPause()
                return
            }
            // seek 后强制算一次，避免设备停在旧强度；跳过的那段不算"采样间漏掉的命令"
            self.lastSampleTime = nil
            self.samplingFromPlaybackStart = false
            self.tick(force: true)
            }
        }
    }

    func stopAll() {
        player?.pause()
        isPlaying = false
        stopTimer(sendZero: true)
        lastSampleTime = nil
        statusLine = "—"
    }

    /// 被动停机（看门狗/退后台/单次上限/输出被拒）：只归零 UI，不补发停止帧
    /// （需要的停止 BLEManager 已经发出去了）
    private func passiveStop(reason: String?) {
        player?.pause()
        isPlaying = false
        stopTimer(sendZero: false)
        lastActive = .zero
        lastSampleTime = nil
        statusLine = reason ?? "已自动停止"
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
        // 修 CC r3 L3：心跳只证明 Timer 活着；播放器已停而 vm 仍以为在播时立即停机，
        // 不让心跳替一个不动的画面续命
        if isPlaying, p.timeControlStatus == .paused {
            handleExternalPause()
            return
        }
        let t = p.currentTime().seconds
        guard t.isFinite else { return }
        // 单次 300 秒上限、30 分钟额度、冷却都由 BLEManager 统一执行（修 M2/M3），这里不再单独计时

        currentSeconds = t
        // 修 L11：从播放起点覆盖整个连续播放区间，包括 >0.5s 的采样延迟；seek 另行重置。
        let prev = lastSampleTime
        let fromPlaybackStart = samplingFromPlaybackStart
        lastSampleTime = t
        samplingFromPlaybackStart = false

        var vals = [0, 0, 0, 0]
        for cmd in s.commands {
            // 修 N5：旋转通道恒为 0，脚本里的旋转命令忽略
            guard let ch = cmd.channel, ch.isUsed else { continue }
            guard cmd.isCovered(at: t, previous: prev, fromPlaybackStart: fromPlaybackStart) else { continue }
            vals[ch.rawValue] = max(vals[ch.rawValue], s.deviceLevel(for: cmd))
        }
        let active = ActiveChannels(values: vals)
        if force || needsResync || active != lastActive {
            needsResync = false
            lastActive = active
            // 修 N2：官方 0x08 帧；修 C：tick 走不开闸的发送路径，看门狗锁住的闸不会被自动帧打开
            ble.sendTick(levels: vals)
            let desc = BCProtocol.Channel.uiChannels
                .map { "\($0.displayName):\(vals[$0.rawValue])" }
                .joined(separator: " ")
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

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // 修 CC r2 L3：换视频后预览也要换成新播放器
        if uiViewController.player !== player { uiViewController.player = player }
    }
}

/// 视频联动：播本地视频，按时间轴脚本自动发官方 0x08 帧（强度按官方 video.js 换算）
struct VideoSyncView: View {
    @EnvironmentObject var ble: BLEManager
    @StateObject private var vm = VideoSyncPlayer()
    /// 同一时间只弹一个选择器；用 sheet(item:) 代替两个 sheet(isPresented:)，
    /// 避免第二次点"选择"弹不出来或回调落到错的选择器上
    private enum PickerKind: Int, Identifiable {
        case video, script
        var id: Int { rawValue }
    }
    @State private var picker: PickerKind?

    var body: some View {
        Form {
            DeviceStatusSection(allowDisconnect: false, connectTitle: "连接")

            Section("素材") {
                HStack {
                    Text("视频"); Spacer()
                    Text(vm.videoName).foregroundColor(.secondary).lineLimit(1)
                    Button("选择") { picker = .video }
                }
                .buttonStyle(.borderless)
                HStack {
                    Text("脚本"); Spacer()
                    Text(vm.scriptName).foregroundColor(.secondary).lineLimit(1)
                    Button("载入") { picker = .script }
                }
                .buttonStyle(.borderless)
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
                // 一行两个按钮：Form 默认把整行当一个点击区域，点"播放"会连"停止"一起触发，
                // 表现就是播放键点了没反应
                .buttonStyle(.borderless)
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
        // 修 CC r3 L4：attach 挂在整个 Form 上，与 onDisappear 对称（同 ManualControlView）
        .onAppear { vm.attach(ble: ble) }
        .sheet(item: $picker) { kind in
            switch kind {
            case .video:
                DocumentPicker(contentTypes: [UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie],
                               onCancel: { picker = nil }) { url in
                    picker = nil
                    vm.loadVideo(url: url)
                }
            case .script:
                DocumentPicker(contentTypes: [UTType.json], onCancel: { picker = nil }) { url in
                    picker = nil
                    vm.loadScript(url: url)
                }
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
    var onCancel: () -> Void = {}
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
