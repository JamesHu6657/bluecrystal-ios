import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import Combine

/// 视频联动播放器（ViewModel）
final class VideoSyncPlayer: ObservableObject {
    @Published var player: AVPlayer?
    @Published var script: TimelineScript? {
        // 曲线用的只读索引，换脚本时建一次（不参与联动发帧）
        didSet { chartIndex = script.map(ScriptChartIndex.init(script:)) }
    }
    @Published private(set) var chartIndex: ScriptChartIndex?
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
            .sink { [weak self, weak p] status in
                guard let self = self, let p = p, p === self.player else { return }
                // 外部把播放器停了，但 vm 还以为在播：同步停机
                if status == .paused, self.isPlaying, self.seekInFlight == 0 {
                    self.handlePausedPlayer(p)
                } else if status == .paused, self.isPlaying {
                    // 修 CC r3 L3：seek 期间先记下，由 seek 回调处理
                    self.pausedDuringSeek = true
                }
            }
            .store(in: &playerCancellables)
    }

    /// KVO/Timer 可能比播完通知先到：读实际位置，先覆盖终点再停采样。
    private func handlePausedPlayer(_ p: AVPlayer) {
        let duration = p.currentItem?.duration.seconds ?? durationSeconds
        if PlaybackCompletion.reachedEnd(position: p.currentTime().seconds, duration: duration) {
            handleNaturalCompletion(p)
            return
        }
        handleExternalPause()
    }

    /// 外部暂停和 seek 停顿不补发跨越区间，只停止设备。
    private func handleExternalPause() {
        isPlaying = false
        stopTimer(sendZero: true)
        statusLine = "外部暂停，设备已停止"
    }

    private func handleNaturalCompletion(_ p: AVPlayer) {
        guard p === player, isPlaying, seekInFlight == 0 else { return }
        let end = p.currentTime().seconds
        if end.isFinite { sample(at: end, force: true) }
        // sendTick 和 sendStop 按顺序进入 bleQueue，停止帧对仍由 BLEManager 原样发送。
        isPlaying = false
        stopTimer(sendZero: true)
        statusLine = "播放结束，设备已停止"
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
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak p] _ in
                guard let self = self, let p = p else { return }
                self.handleNaturalCompletion(p)
            }
            .store(in: &playerCancellables)
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
        lastSampleTime = nil
        samplingFromPlaybackStart = false
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

    /// 打开文件选择器之前（修：选择器是一整页弹出层，会盖住底部停止键）：
    /// 正在联动就先停下（和 AI 页打开设置前先停止一样）；选完新素材本来也会 stopAll
    func stopBeforePicker() {
        guard isPlaying else { return }
        stopAll()
        statusLine = "打开文件前已停止"
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
        guard let p = player, let ble = ble else { return }
        // 修 CC L6：拖进度条期间界面是活的，心跳照发，避免长时间拖动误触看门狗
        ble.heartbeat()
        guard seekInFlight == 0 else { return }
        // 修 CC r3 L3：心跳只证明 Timer 活着；播放器已停而 vm 仍以为在播时立即停机，
        // 不让心跳替一个不动的画面续命
        if isPlaying, p.timeControlStatus == .paused {
            handlePausedPlayer(p)
            return
        }
        let t = p.currentTime().seconds
        guard t.isFinite else { return }
        let duration = p.currentItem?.duration.seconds ?? durationSeconds
        if PlaybackCompletion.reachedEnd(position: t, duration: duration) {
            handleNaturalCompletion(p)
            return
        }
        sample(at: t, force: force)
    }

    private func sample(at t: Double, force: Bool = false) {
        guard let s = script, let ble = ble else { return }
        // 单次上限（SafetyLimits.maxRunSeconds）、30 分钟额度、冷却都由 BLEManager 统一执行（修 M2/M3），这里不再单独计时

        currentSeconds = t
        // 修 L11：从播放起点覆盖整个连续播放区间，包括 >0.5s 的采样延迟；seek 另行重置。
        let prev = lastSampleTime
        let fromPlaybackStart = samplingFromPlaybackStart
        lastSampleTime = t
        samplingFromPlaybackStart = false

        let vals = s.levels(at: t, previous: prev, fromPlaybackStart: fromPlaybackStart)
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

/// 一起看：播本地视频，按时间轴脚本自动发官方 0x08 帧（强度按官方 video.js 换算）
struct VideoSyncView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var privacy: PrivacyLock
    @StateObject private var vm = VideoSyncPlayer()
    /// 同一时间只弹一个选择器；用 sheet(item:) 代替两个 sheet(isPresented:)，
    /// 避免第二次点"选择"弹不出来或回调落到错的选择器上
    private enum PickerKind: Int, Identifiable {
        case video, script
        var id: Int { rawValue }
    }
    @State private var picker: PickerKind?
    /// 全屏播放中：内嵌预览让出播放器，onDisappear 不把全屏误判成离开页面
    @State private var isFullScreen = false
    /// 选择器被拦下的那句说明：钉在停止键上方一小会儿（设备卡片可能在屏幕外——素材区在页面下部），
    /// 把话说在手边，不只震一下
    @State private var pickerNotice: String?
    /// 提示代次：重复点被拦下的入口时重新计时
    @State private var pickerNoticeGen = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 设备需要用户处理（停止重试中、需要确认物理关机、提供强制断开）时不弹选择器：
    /// 选择器是整页弹出层，会盖住红字和「解除锁定 / 强制断开」这些只在设备卡片上的按钮
    private var pickerBlocked: Bool {
        ble.safety.needsPhysicalAck || ble.safety.stopRetrying || ble.forceDisconnectOffered
    }

    /// 同手感页的规则：连上或有任何提示（红字 / 冷却等 / 锁存 / 停止重试 / 断开中 / 强制断开）时才显示设备卡片；
    /// 平常没连上时不让技术卡片抢画面。卡片不摆连接键（showsConnect: false）：
    /// 没连上时播放键下面的「设备」准备项就是唯一的连接入口，不再两个按钮管同一件事
    private var showsDeviceStatus: Bool {
        ble.state == .ready || ble.lastError != nil || ble.safety.needsPhysicalAck ||
        ble.safety.blockReason != nil || ble.safety.stopRetrying ||
        ble.state == .disconnecting || ble.forceDisconnectOffered
    }

    /// 选择器被拦下时的那句话：先处理什么、再选什么，一个出处
    /// （旁白播的、钉在停止键上显示的、幕布和素材区写的都是同一句）。kind 为 nil：视频和脚本一起说
    private func pickerBlockedMessage(_ kind: PickerKind?) -> String {
        let what: String
        switch kind {
        case .video?: what = "视频"
        case .script?: what = "脚本"
        case nil: what = "视频或脚本"
        }
        return "先处理上方设备卡片的提示，再选\(what)"
    }

    /// 选择器弹出前先停（选择器会盖住页面底部的停止键；选择器里另有一个停止键）。
    /// blockedReasonShown：这个入口自己把被拦的原因写在旁边了（幕布），不再往停止键上钉第二份
    private func openPicker(_ kind: PickerKind, blockedReasonShown: Bool = false) {
        guard !pickerBlocked else {
            Haptics.warning()
            UIAccessibility.post(notification: .announcement, argument: pickerBlockedMessage(kind))
            if !blockedReasonShown { flashPickerNotice(kind) }
            return
        }
        vm.stopBeforePicker()
        picker = kind
    }

    /// 被拦下的说明只显示一小会儿（3 秒）；减弱动态效果时只淡入淡出
    private func flashPickerNotice(_ kind: PickerKind) {
        pickerNoticeGen += 1
        let gen = pickerNoticeGen
        let settle: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
        withAnimation(settle) {
            pickerNotice = pickerBlockedMessage(kind)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard gen == pickerNoticeGen else { return }
            withAnimation(settle) { pickerNotice = nil }
        }
    }

    /// 选择器底部：停止键（停止帧对可能还在路上）；有红字或锁存时连设备卡片一起带上
    private var pickerStopBar: some View {
        let showCard: Bool = ble.lastError != nil || ble.safety.needsPhysicalAck || ble.safety.stopRetrying
        return VStack(spacing: 0) {
            if showCard {
                DeviceStatusCard(allowDisconnect: false, connectTitle: "连接", compact: true, showsConnect: false)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            StopDockBar { vm.stopAll() }
        }
        .background(Velvet.ink.ignoresSafeArea())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "一起看", subtitle: "画面起伏，身体也跟着一起")

                // 警告 / 锁存 / 断开中不带动画：一出现就完整可见。没连上时连接走「设备」准备项
                if showsDeviceStatus {
                    DeviceStatusCard(allowDisconnect: false, connectTitle: "连接", showsConnect: false)
                }

                stage

                if let idx = vm.chartIndex {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(title: "脚本曲线", systemImage: "waveform.path")
                        // 只读展示：按脚本画出播放头前后的强度，不发帧、不影响联动。
                        // 全屏时被盖住，停下不画（全屏里有自己的一份）
                        ScriptIntensityChart(index: idx, player: vm.player, fallbackTime: vm.currentSeconds,
                                             isPlaying: vm.isPlaying && !isFullScreen)
                    }
                    .velvetCard()
                }

                playback

                materials
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(VelvetBackground(glow: vm.isPlaying ? 0.6 : 0.15).ignoresSafeArea())
        // 停止常驻底部，任何时候一下就停（和原来的停止键一样不受连接状态限制）。
        // 选择器被拦下时的一句说明就贴在停止键上面：滚到哪儿都看得见，也不盖住停止键
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let n = pickerNotice {
                    Label(n, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(Velvet.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Velvet.ink.opacity(0.95)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Velvet.warning.opacity(0.4), lineWidth: 1))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
                StopDockBar { vm.stopAll() }
            }
        }
        // 修 CC r3 L4：attach 挂在整个页面上，与 onDisappear 对称（同 ManualControlView）
        .onAppear { vm.attach(ble: ble) }
        // 设备那边处理好了：钉着的"先处理设备卡片"立刻收掉，不再指向一张已经不在的卡片
        .onChange(of: pickerBlocked) { blocked in
            guard !blocked, pickerNotice != nil else { return }
            pickerNoticeGen += 1
            let settle: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
            withAnimation(settle) { pickerNotice = nil }
        }
        // 弹出层（选择器、全屏）盖在根视图的入口页 / 解锁页 / 隐私模糊之上，各自也挂一份
        .sheet(item: $picker) { kind in
            // 选择器和底部停止条上下排（不用 safeAreaInset：系统选择器是远程界面，未必让出底部的
            // 「最近使用 / 浏览」标签栏，停止条可能压在上面）
            VStack(spacing: 0) {
                Group {
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
                pickerStopBar
            }
            .privacyCover()
            .environmentObject(privacy)
            .environmentObject(ble)
        }
        // 全屏控制同样走 vm（播放/暂停/拖动/停止），设备联动不受影响
        .fullScreenCover(isPresented: $isFullScreen) {
            FullScreenVideoView(vm: vm) { isFullScreen = false }
                .privacyCover()
                .environmentObject(privacy)
                .environmentObject(ble)
        }
        // 弹出全屏时部分系统版本也会触发 onDisappear：全屏中不停机
        .onDisappear { if !isFullScreen { vm.stopAll() } }
        // 解锁页上的停止：和本页停止键同一个 stopAll
        .onReceive(privacy.stopAllRequested) { _ in vm.stopAll() }
    }

    /// 预览画面（原"预览"区块）：没有视频时是一块邀请选择的幕布
    @ViewBuilder private var stage: some View {
        if let p = vm.player {
            ZStack(alignment: .topTrailing) {
                if !isFullScreen {
                    NoControlsPlayerView(player: p)
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)
                } else {
                    Color.black.frame(height: 220)
                }
                Button {
                    isFullScreen = true
                } label: {
                    Label("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundColor(.white)
                        // 点击区域至少 44pt，外观不变
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Velvet.stroke, lineWidth: 1))
            .shadow(color: Velvet.rose.opacity(vm.isPlaying ? 0.35 : 0.1), radius: 24)
        } else {
            // 幕布自己把被拦的原因写在上面（blockedReasonShown）：点它被拦下时不再往停止键上钉同一句
            Button { openPicker(.video, blockedReasonShown: true) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Velvet.roseGradient)
                    Text("选一段视频，和她一起看")
                        .font(Velvet.display(.title3, .medium))
                        .foregroundColor(Velvet.text)
                    if pickerBlocked {
                        // 设备需要先处理时选择器不弹：写明原因，不只是震一下（和钉在停止键上的那句同一出处）
                        Label(pickerBlockedMessage(.video), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(Velvet.warning)
                    } else {
                        Text("再载入时间轴脚本，画面和身体就会同步")
                            .font(.caption)
                            .foregroundColor(Velvet.textSecondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(RadialGradient(colors: [Velvet.wine.opacity(0.8), Velvet.plum.opacity(0.4)],
                                             center: .center, startRadius: 0, endRadius: 220))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Velvet.rose.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                )
            }
            .buttonStyle(PressableStyle())
            // 不用 disabled：变灰会把原因那行字一起压暗。点了由 openPicker 拦下（震动 + 旁白说明）
            .accessibilityHint(pickerBlocked ? "先处理设备卡片上的提示" : "选择视频")
        }
    }

    /// 播放控制（原"播放控制"区块）
    private var playback: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Velvet.roseGradient))
                        .shadow(color: Velvet.rose.opacity(0.5), radius: vm.isPlaying ? 16 : 6)
                }
                .buttonStyle(PressableStyle())
                .disabled(!vm.canPlay)
                .accessibilityLabel(vm.isPlaying ? "暂停" : "播放")

                VStack(alignment: .leading, spacing: 4) {
                    Text(playbackTitle)
                        .font(Velvet.display(.headline, .medium))
                        .foregroundColor(Velvet.text)
                    if vm.durationSeconds > 0 {
                        Text("\(formatTime(vm.currentSeconds)) / \(formatTime(vm.durationSeconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(Velvet.textSecondary)
                            // 下面滑杆的旁白值读的就是这两个时间，这行字不再让旁白单独停一次
                            .accessibilityHidden(true)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    vm.stopAll()
                    Haptics.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Velvet.stopGradient))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("停止")
                .accessibilityHint("立即停止所有输出")
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
                .tint(Velvet.rose)
                .disabled(!vm.canPlay)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(formatTime(vm.currentSeconds))，共 \(formatTime(vm.durationSeconds))")
            }
            if !vm.canPlay {
                readiness
            } else if !vm.isPlaying, let reason = ble.safety.blockReason {
                // 三样都齐了但安全规则暂时不许输出（冷却 / 额度 / 锁存）：就在播放键旁边说清楚
                Label(reason, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundColor(Velvet.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(vm.statusLine)
                .font(.caption)
                .foregroundColor(Velvet.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .velvetCard()
    }

    /// 播放键旁边的标题：三样齐了但冷却 / 额度暂时不许输出时不说"准备好了"
    private var playbackTitle: String {
        if vm.isPlaying { return "正在一起看" }
        guard vm.canPlay else { return "播放控制" }
        return ble.safety.blockReason == nil ? "准备好了" : "稍等片刻"
    }

    /// 还差什么才能播：设备 / 视频 / 脚本，缺哪个点哪个（之前播放键只是灰着，不说为什么）
    private var readiness: some View {
        let state: BLEManager.State = ble.state
        let connected: Bool = state == .ready
        let connecting: Bool = state == .scanning || state == .connecting || state == .discovering
        let busy: Bool = connecting || state == .disconnecting
        let deviceTitle: String = busy ? state.rawValue : "设备"
        let hasVideo: Bool = vm.player != nil
        let hasScript: Bool = vm.script != nil
        return HStack(spacing: 8) {
            ReadinessChip(title: deviceTitle, done: connected, icon: "dot.radiowaves.left.and.right",
                          hint: busy ? "" : "连接设备", enabled: !busy, tappableWhenDone: false) {
                if !connected && !busy { ble.startScan() }
            }
            // 设备需要处理时不灰掉视频 / 脚本准备项：点了由 openPicker 拦下并说明，和选视频幕布一致
            ReadinessChip(title: "视频", done: hasVideo, icon: "film",
                          hint: "选择视频") { openPicker(.video) }
            ReadinessChip(title: "脚本", done: hasScript, icon: "doc.text",
                          hint: "载入时间轴脚本") { openPicker(.script) }
        }
    }

    /// 素材（原"素材"区块）
    private var materials: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "素材", systemImage: "film.stack")
            // 被拦下的原因常驻写在本卡片底部（blockedReasonShown）：点这两行时不再往停止键上钉第二份
            materialRow(icon: "film", title: "视频", value: vm.videoName, action: "选择") {
                openPicker(.video, blockedReasonShown: true)
            }
            Divider().overlay(Velvet.stroke)
            materialRow(icon: "doc.text", title: "脚本", value: vm.scriptName, action: "载入") {
                openPicker(.script, blockedReasonShown: true)
            }
            if let s = vm.script {
                Text("\(s.commands.count) 条命令")
                    .font(.caption).foregroundColor(Velvet.textMuted)
            }
            if pickerBlocked {
                // 已选过视频后幕布不在了，素材行是唯一入口：被拦的原因常驻写在这里（和幕布上那句同一个意思），
                // 不只靠停止键上方那 3 秒的提示
                Label(pickerBlockedMessage(nil), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(Velvet.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .velvetCard()
    }

    private func materialRow(icon: String, title: String, value: String, action: String,
                             perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(Velvet.gold)
                .frame(width: 22)
            Text(title).foregroundColor(Velvet.text)
            Text(value)
                .font(.footnote)
                .foregroundColor(Velvet.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // 同上：设备需要处理时不用 disabled（灰了不知道为什么），点一下由 openPicker 拦下并说明
            Button(action, action: perform)
                .buttonStyle(PillButtonStyle(kind: .secondary))
        }
    }

    private func formatTime(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}

/// 曲线用的脚本索引（只读）：每个通道的命令按开始时间排好、强度用 TimelineScript.deviceLevel
/// （和联动发帧同一个换算，纯函数）预先算好，再配一列"到这条为止最晚的结束时间"二分出可见窗口。
/// 载入脚本时建一次；每帧只看窗口里的几条命令，不再遍历整份脚本和主线程上的发帧抢时间
struct ScriptChartIndex {
    struct Segment {
        let start: Double
        let end: Double
        let level: Int
    }

    /// 按 Channel.rawValue 存；强度为 0 的命令不画也不影响读数，直接不收
    private var segments: [[Segment]] = [[], [], [], []]
    private var prefixMaxEnd: [[Double]] = [[], [], [], []]

    init(script: TimelineScript) {
        for ch in BCProtocol.Channel.uiChannels {
            let segs = script.commands
                .filter { $0.channel == ch }
                .map { Segment(start: $0.startTimeSeconds, end: $0.endTime, level: script.deviceLevel(for: $0)) }
                .filter { $0.level > 0 }
                .sorted { $0.start < $1.start }
            var latest = -Double.infinity
            prefixMaxEnd[ch.rawValue] = segs.map { seg -> Double in
                latest = max(latest, seg.end)
                return latest
            }
            segments[ch.rawValue] = segs
        }
    }

    /// 和 [from, to] 有交集的命令（结束 ≥ from 且开始 ≤ to）
    func visible(_ ch: BCProtocol.Channel, from: Double, to: Double) -> ArraySlice<Segment> {
        let segs = segments[ch.rawValue]
        let ends = prefixMaxEnd[ch.rawValue]
        // 第一条"到这里为止最晚结束 ≥ from"的位置：它之前的命令都在窗口左边结束了
        var lo = 0, hi = segs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] >= from { hi = mid } else { lo = mid + 1 }
        }
        let first = lo
        // 第一条开始 > to 的位置
        hi = segs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segs[mid].start > to { hi = mid } else { lo = mid + 1 }
        }
        return segs[first..<lo]
    }

    /// 脚本在某一刻的强度，和 TimelineScript.levels(at: t, previous: nil) 相同（只用于显示）
    func levels(at t: Double) -> [Int] {
        var vals = [0, 0, 0, 0]
        for ch in BCProtocol.Channel.uiChannels {
            for seg in visible(ch, from: t, to: t) where t >= seg.start && t < seg.end {
                vals[ch.rawValue] = max(vals[ch.rawValue], seg.level)
            }
        }
        return vals
    }
}

/// 脚本强度曲线（只读展示）：播放头前后一段时间里每个通道的强度，随播放滚动。
/// 数据来自 ScriptChartIndex；播放头只读 AVPlayer.currentTime()。不发帧、不改任何联动或安全状态
struct ScriptIntensityChart: View {
    let index: ScriptChartIndex
    let player: AVPlayer?
    let fallbackTime: Double
    let isPlaying: Bool
    var height: CGFloat = 120
    var compact = false

    /// 播放头左边显示多少秒、右边预告多少秒
    static let pastSeconds: Double = 6
    static let aheadSeconds: Double = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { _ in
            let t = playhead()
            let levels = index.levels(at: t)
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                Canvas { ctx, size in
                    draw(in: &ctx, size: size, at: t)
                }
                .frame(height: height)
                if !compact {
                    HStack {
                        Text("−\(Int(Self.pastSeconds))s")
                        Spacer()
                        Text("此刻")
                        Spacer()
                        Text("+\(Int(Self.aheadSeconds))s")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Velvet.textMuted)
                }
                legend(levels)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("脚本强度曲线")
        .accessibilityValue(levelSummary(index.levels(at: playhead())))
    }

    private func playhead() -> Double {
        if let p = player {
            let s = p.currentTime().seconds
            if s.isFinite { return s }
        }
        return fallbackTime.isFinite ? fallbackTime : 0
    }

    /// 图例兼直接读数：通道色点 + 名字 + 脚本此刻的强度（文字用正文色，颜色只在点上）
    private func legend(_ levels: [Int]) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            ForEach(BCProtocol.Channel.uiChannels, id: \.rawValue) { ch in
                HStack(spacing: 5) {
                    Circle().fill(Velvet.channel(ch)).frame(width: 8, height: 8)
                    Text(ch.displayName)
                        .foregroundColor(compact ? Color.white.opacity(0.8) : Velvet.textSecondary)
                    Text("\(levels[ch.rawValue])")
                        .monospacedDigit()
                        .foregroundColor(compact ? Color.white : Velvet.text)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
    }

    private func levelSummary(_ levels: [Int]) -> String {
        BCProtocol.Channel.uiChannels
            .map { "\($0.displayName) \(levels[$0.rawValue])" }
            .joined(separator: "，")
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, at t: Double) {
        let w = size.width, h = size.height
        guard w > 0, h > 0 else { return }
        let span = Self.pastSeconds + Self.aheadSeconds
        let start = t - Self.pastSeconds
        let end = t + Self.aheadSeconds
        let top: CGFloat = 4
        let usable = h - top
        func x(_ time: Double) -> CGFloat { CGFloat((time - start) / span) * w }
        func y(_ level: Int) -> CGFloat {
            h - CGFloat(min(99, max(0, level))) / 99 * usable
        }

        // 极淡的参考线：50、99
        for level in [50, 99] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(level)))
            line.addLine(to: CGPoint(x: w, y: y(level)))
            ctx.stroke(line, with: .color(Color.white.opacity(0.06)), lineWidth: 1)
        }
        var base = Path()
        base.move(to: CGPoint(x: 0, y: h - 0.5))
        base.addLine(to: CGPoint(x: w, y: h - 0.5))
        ctx.stroke(base, with: .color(Color.white.opacity(0.12)), lineWidth: 1)

        // 每条命令画成一段：淡填充 + 2px 顶线，端点圆角
        for ch in BCProtocol.Channel.uiChannels {
            let color = Velvet.channel(ch)
            for seg in index.visible(ch, from: start, to: end) {
                // visible() 按"到这里为止最晚结束"查找，会带出窗口左边已经结束的段：跳过，不画 2px 残条
                guard seg.end > start else { continue }
                let x0 = max(0, x(seg.start))
                let x1 = min(w, max(x0 + 2, x(seg.end)))
                let yy = y(seg.level)
                let rect = CGRect(x: x0, y: yy, width: x1 - x0, height: h - yy)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.18)))
                var topLine = Path()
                topLine.move(to: CGPoint(x: x0 + 1, y: yy))
                topLine.addLine(to: CGPoint(x: x1 - 1, y: yy))
                ctx.stroke(topLine, with: .color(color),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }

        // 已经过去的部分压暗一点
        let px = x(t)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: px, height: h)),
                 with: .color(Velvet.ink.opacity(compact ? 0.25 : 0.35)))

        // 播放头
        var head = Path()
        head.move(to: CGPoint(x: px, y: 0))
        head.addLine(to: CGPoint(x: px, y: h))
        ctx.stroke(head, with: .color(Velvet.blush.opacity(0.35)), lineWidth: 6)
        ctx.stroke(head, with: .color(Velvet.blush), lineWidth: 1.5)
        ctx.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: -1, width: 7, height: 7)), with: .color(Velvet.blush))
    }
}

/// 播放前的准备项：好了打勾，没好点一下去补
private struct ReadinessChip: View {
    let title: String
    let done: Bool
    let icon: String
    /// 没就绪时点一下会做什么（旁白读）
    let hint: String
    /// 已就绪的不变灰（勾要看得清），只有"现在点了也没用"的才禁用
    var enabled = true
    /// 就绪后再点还有没有意义（视频 / 脚本可以换；设备连上了再点什么也不做，就不当按钮）
    var tappableWhenDone = true
    let action: () -> Void

    var body: some View {
        if done && !tappableWhenDone {
            chipLabel
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue("已就绪")
        } else {
            Button(action: action) {
                chipLabel
            }
            .buttonStyle(PressableStyle())
            .disabled(!done && !enabled)
            .accessibilityLabel(title)
            .accessibilityValue(done ? "已就绪" : "未就绪")
            .accessibilityHint(done ? "点一下更换" : hint)
        }
    }

    private var chipLabel: some View {
        let fill: Color = Color.white.opacity(done ? 0.04 : 0.08)
        let stroke: Color = done ? Velvet.ok.opacity(0.35) : Velvet.stroke
        return HStack(spacing: 5) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
            Text(title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(done ? Velvet.ok : Velvet.text)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
        .contentShape(Capsule())
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

/// 全屏里设备卡片的高度（纯布局）
private struct WarningCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 全屏里底部控制条的高度（纯布局）：设备卡片最多长到它的上沿
private struct BottomPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 全屏播放：黑底铺满，点画面显示/隐藏控制条；所有控制都走 VideoSyncPlayer，
/// 不用系统播放控件（会绕过联动和安全逻辑）。
/// 停止键只有一个、永远在右下角同一个位置：控制条显示或收起（含 4 秒自动收起）都不挪地方，
/// 伸手去点的那一下不会因为控制条刚好收起而落空
struct FullScreenVideoView: View {
    @EnvironmentObject var ble: BLEManager
    @ObservedObject var vm: VideoSyncPlayer
    let onClose: () -> Void
    @State private var showControls = true
    /// 自动收起控制条的代次：任何一次显示 / 播放状态变化都重新计时
    @State private var hideGen = 0
    /// 正在拖进度条：拖动期间不收起
    @State private var scrubbing = false
    /// 设备卡片的实际高度（量出来之前为 0）：滚动区只占这么高，不多拦一块点击
    @State private var warningCardHeight: CGFloat = 0
    /// 底部控制条的实际高度（量出来之前为 0）
    @State private var bottomPanelHeight: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 设备卡片离顶部的距离（让出退出键）；放不下时至少留这么高给红字（再多就滚动）
    private static let warningTop: CGFloat = 60
    private static let minWarningBand: CGFloat = 120

    /// 横屏有提示时不画只读的强度曲线：把高度让给设备卡片，进度条和播放键不被盖住
    private var hidesChartForWarning: Bool {
        needsDeviceAttention && verticalSizeClass == .compact
    }

    /// 停止键直径、离边缘的距离；控制条右侧给它让出的宽度（控制条的内容不压到停止键下面）
    private static let stopSize: CGFloat = 60
    private static let stopInset: CGFloat = 20
    private static let stopReserve: CGFloat = stopSize + stopInset + 8

    private var needsDeviceAttention: Bool {
        ble.lastError != nil || ble.safety.needsPhysicalAck ||
        ble.safety.stopRetrying || ble.forceDisconnectOffered
    }

    /// 旁白、切换控制开着时不自动收起（找不到控件）。全键盘控制系统没有公开的检测接口，
    /// 点任何地方都会把控制条叫回来，停止键也一直在
    private static var assistiveTechRunning: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    /// 播放中 4 秒没碰屏幕就收起控制条（停止键不受影响）；暂停 / 被自动停止 / 拖动中不收
    private func scheduleAutoHide() {
        hideGen += 1
        let gen = hideGen
        if needsDeviceAttention {
            showControls = true
            return
        }
        guard vm.isPlaying, !scrubbing, !Self.assistiveTechRunning else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard gen == hideGen, vm.isPlaying, !scrubbing,
                  !Self.assistiveTechRunning, !needsDeviceAttention else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let warningHeight: CGFloat = min(260, geo.size.height * 0.5)
            ZStack {
                Color.black.ignoresSafeArea()
                if let p = vm.player {
                    NoControlsPlayerView(player: p)
                        .ignoresSafeArea()
                }
                // 透明点击层：切换控制条
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        guard !needsDeviceAttention else {
                            showControls = true
                            return
                        }
                        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                        if showControls { scheduleAutoHide() }
                    }
                if showControls || needsDeviceAttention {
                    controls
                        .transition(.opacity)
                }
                // 独立于控制条的淡入淡出：警告不动画、不自动收起。长红字 / 大字号可滚动，
                // 上方留出退出键，下方的固定停止键仍最后绘制、始终可点。
                // 卡片多高就占多高、贴着顶部；最多 warningHeight，也最多长到底部控制条上沿（横屏时不盖住进度条和播放键），
                // 但至少留 minWarningBand 给红字；放不下才滚动。
                // 始终只有这一张卡片：高度变化时「解除锁定 / 强制断开」的确认框不会因为换了一份卡片而被收掉
                if needsDeviceAttention {
                    let measured: CGFloat = warningCardHeight
                    let roomAbovePanel: CGFloat = bottomPanelHeight > 0
                        ? geo.size.height - Self.warningTop - bottomPanelHeight - 8
                        : warningHeight
                    let floorHeight: CGFloat = min(Self.minWarningBand, warningHeight)
                    let cap: CGFloat = max(floorHeight, min(warningHeight, roomAbovePanel))
                    let fits: Bool = measured > 0 && measured <= cap
                    let bandHeight: CGFloat = measured > 0 ? min(measured, cap) : cap
                    VStack(spacing: 0) {
                        ScrollView {
                            warningCard
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(key: WarningCardHeightKey.self, value: g.size.height)
                                    }
                                )
                        }
                        .scrollDisabled(fits)
                        .frame(height: bandHeight)
                        // 放不下时（横屏常见）底边淡出并挂一个向下的小箭头：iOS 的滚动条不动时不显示，
                        // 不提示的话「解除锁定」露半截也看不出能往上滑。只是提示，不拦点击
                        .overlay(alignment: .bottom) {
                            if !fits && measured > 0 {
                                ZStack(alignment: .bottom) {
                                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                   startPoint: .top, endPoint: .bottom)
                                        .frame(height: 28)
                                    Image(systemName: "chevron.compact.down")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.85))
                                        .padding(.bottom, 2)
                                }
                                .padding(.horizontal, 16)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, Self.warningTop)
                    .onPreferenceChange(WarningCardHeightKey.self) { h in
                        if abs(h - warningCardHeight) > 0.5 { warningCardHeight = h }
                    }
                }
                // 最后画：永远在最上层、永远在同一个位置
                stopButton
            }
            // 控制条收起时量到 0：保留上一次的高度
            .onPreferenceChange(BottomPanelHeightKey.self) { h in
                if h > 0, abs(h - bottomPanelHeight) > 0.5 { bottomPanelHeight = h }
            }
        }
        .statusBarHidden(!showControls && !needsDeviceAttention)
        .preferredColorScheme(.dark)
        .onAppear { scheduleAutoHide() }
        .onChange(of: needsDeviceAttention) { _ in
            // 作废已经排队的自动收起；有提示时不动画，提示消失后才重新计时。
            scheduleAutoHide()
        }
        // 开始播放后开始计时收起；停下（含被动停机）就把控制条和状态说明拿出来
        .onChange(of: vm.isPlaying) { playing in
            if playing {
                scheduleAutoHide()
            } else {
                hideGen += 1
                if needsDeviceAttention {
                    showControls = true
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                }
            }
        }
    }

    private var warningCard: some View {
        DeviceStatusCard(allowDisconnect: false, connectTitle: "连接", compact: true, showsConnect: false)
            .padding(.horizontal, 16)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("退出全屏")
                Spacer()
                Text(vm.videoName).font(.footnote).lineLimit(1)
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .background(
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            Spacer()
            bottomPanel
        }
        .foregroundColor(.white)
        .buttonStyle(.borderless)
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if let idx = vm.chartIndex, !hidesChartForWarning {
                // 只读展示，同内嵌页
                ScriptIntensityChart(index: idx, player: vm.player, fallbackTime: vm.currentSeconds,
                                     isPlaying: vm.isPlaying, height: 44, compact: true)
            }
            if vm.durationSeconds > 0 {
                Slider(
                    value: Binding(
                        get: { vm.currentSeconds },
                        set: { (t: Double) in vm.seek(to: t) }
                    ),
                    in: 0...vm.durationSeconds,
                    onEditingChanged: { (editing: Bool) in
                        // 拖动期间不许自动收起；松手后重新计时
                        scrubbing = editing
                        if !editing { scheduleAutoHide() }
                    }
                )
                .tint(Velvet.rose)
                .disabled(!vm.canPlay)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(Self.formatTime(vm.currentSeconds))，共 \(Self.formatTime(vm.durationSeconds))")
            }
            HStack(spacing: 18) {
                // 颜色写在标签上：.borderless 下按钮的 tint / 角色色会盖过外层的白色
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(Velvet.roseGradient))
                }
                .disabled(!vm.canPlay)
                .accessibilityLabel(vm.isPlaying ? "暂停" : "播放")
                Text("\(Self.formatTime(vm.currentSeconds)) / \(Self.formatTime(vm.durationSeconds))")
                    .font(.caption.monospacedDigit())
                    // 上面滑杆的旁白值读的就是这两个时间，这行字不再让旁白单独停一次；
                    // 时长还没读出来（滑杆还没出现）时这行字是旁白唯一的时间来源，不能藏
                    .accessibilityHidden(vm.durationSeconds > 0)
                Spacer()
            }
            Text(vm.statusLine)
                .font(.caption2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading)
        .padding(.vertical)
        // 右边让给常驻的停止键
        .padding(.trailing, Self.stopReserve)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: BottomPanelHeightKey.self, value: g.size.height)
            }
        )
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.35))
    }

    /// 常驻停止键：带"停止"两个字，控制条收起时也一眼认得出
    private var stopButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(role: .destructive) {
                    vm.stopAll()
                    Haptics.stop()
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("停止")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(width: Self.stopSize, height: Self.stopSize)
                    .background(Circle().fill(Velvet.stopGradient))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: Velvet.danger.opacity(0.5), radius: 10)
                    .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("停止")
                .accessibilityHint("立即停止所有输出")
                .accessibilitySortPriority(10)
                // 字号固定（圆里放不下更大的字）：大字号用户长按能看到放大的"停止"（点按照常立刻停）
                .accessibilityShowsLargeContentViewer()
            }
        }
        .padding(Self.stopInset)
    }

    private static func formatTime(_ s: Double) -> String {
        guard s.isFinite else { return "--:--" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
