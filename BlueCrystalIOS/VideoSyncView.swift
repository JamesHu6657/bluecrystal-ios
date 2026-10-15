import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import Combine

/// 视频联动播放器（ViewModel）：本地视频 + 声音联动。
/// 强度来源只有一个：MTAudioProcessingTap 实时分析的音轨响度（AudioLevelTap / AudioLevelMeter），
/// 经 AudioReactiveShaper（灵敏度、噪声门、平滑、上限）后每 0.3 秒走 BLEManager.sendTick。
/// 暂停、缓冲、seek、播完、页面消失、退后台、蓝牙断开都立刻归零；所有输出都过 BLEManager 的准入 / 额度 / 看门狗。
final class VideoSyncPlayer: ObservableObject {
    @Published var player: AVPlayer?
    @Published var videoName: String = "未选择视频"
    @Published var isPlaying = false
    @Published var statusLine: String = "—"
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    /// 电平条：灵敏度之后、噪声门之前的响度（0~100），纯展示
    @Published private(set) var level: Double = 0
    /// 实际输出的强度（0 ~ 强度上限）
    @Published private(set) var intensity: Int = 0
    @Published private(set) var audioStatus: AudioLevelTap.Status = .none
    @Published private var scrubber = PlaybackScrubber()

    var displaySeconds: Double { scrubber.position ?? currentSeconds }

    func updateScrubPosition(_ seconds: Double) {
        if let target = scrubber.update(to: seconds) { seek(to: target) }
    }

    func setScrubbing(_ editing: Bool) {
        if editing {
            scrubber.begin(at: currentSeconds)
        } else if let target = scrubber.end() {
            seek(to: target)
        }
    }

    func cancelScrubbing() { scrubber.cancel() }

    private var timer: Timer?
    private var lastActive = ActiveChannels.zero
    private weak var ble: BLEManager?
    /// 状态订阅（attach 可安全重建）；播放器订阅单独管理，只在换播放器时清理
    private var stateCancellables = Set<AnyCancellable>()
    private var playerCancellables = Set<AnyCancellable>()

    /// seek 代次：只有最新的回调有效；停止期间不允许回调复活播放或输出
    private var seekGen = 0
    private var isSeeking = false

    /// 重连 / 设置变化后强制重发一帧（避免被"没有变化"吞掉）
    private var needsResync = false

    /// 播放中播放头卡住（缓冲 / 解码卡住）超过 stallLimit 就停机
    private var progressWatch = PlaybackProgressWatch()

    /// 声音联动：每个视频一个电平计，安装代次作废旧视频晚到的回调
    private var meter: AudioLevelMeter?
    private var meterGen = 0
    private var shaper = AudioReactiveShaper()
    private var settings = AudioSyncSettings()
    /// 上一次 tick 的单调时间：平滑步长按真实间隔算
    private var lastTickAt: TimeInterval?

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 界面设置变化（@AppStorage）。关掉联动立刻归零但视频继续播；其余变化下一拍生效
    func applySettings(_ s: AudioSyncSettings) {
        let wasEnabled = settings.enabled
        settings = s
        if wasEnabled && !s.enabled {
            shaper.reset()
            intensity = 0
            // 全零帧在运行中会换成完整停止帧对、运行继续（OutputGate），设备没在输出时不发
            ble?.sendTick(levels: ActiveChannels.zero.values)
            lastActive = .zero
            if isPlaying { statusLine = "联动已关闭，视频继续播放" }
        }
        needsResync = true
    }

    func attach(ble: BLEManager) {
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
                    self.zeroDisplay()
                    self.statusLine = "设备已断开，联动已停止"
                }
            }
            .store(in: &stateCancellables)
        // 被动停机（看门狗/退后台/单次上限/输出被拒）：只归零 UI，不补发停止帧
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in self?.passiveStop(reason: reason) }
            .store(in: &stateCancellables)
    }

    private func observeTimeControlStatus(_ p: AVPlayer) {
        p.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak p] status in
                guard let self = self, let p = p, p === self.player else { return }
                // 外部把播放器停了，但 vm 还以为在播：同步停机。
                // 只豁免 seek 自己的暂停；等待落点前进期间的真正外部暂停仍立即停机。
                if status == .paused, p.timeControlStatus == .paused, self.isPlaying,
                   !self.isSeeking {
                    self.handlePausedPlayer(p)
                }
                // 缓冲（waitingToPlayAtSpecifiedRate）不在这里单独处理：tick 看播放头有没有前进
            }
            .store(in: &playerCancellables)
    }

    /// KVO/Timer 可能比播完通知先到：读实际位置识别终点，再停止设备。
    private func handlePausedPlayer(_ p: AVPlayer) {
        let duration = p.currentItem?.duration.seconds ?? durationSeconds
        if PlaybackCompletion.reachedEnd(position: p.currentTime().seconds, duration: duration) {
            handleNaturalCompletion(p)
            return
        }
        handleExternalPause()
    }

    /// 外部暂停：只停止设备
    private func handleExternalPause() {
        isPlaying = false
        stopTimer(sendZero: true)
        zeroDisplay()
        statusLine = "外部暂停，设备已停止"
    }

    /// 播放中播放头卡住：画面不动时设备不能停在当前强度上
    private func handleStall() {
        isPlaying = false
        player?.pause()
        stopTimer(sendZero: true)
        zeroDisplay()
        statusLine = "视频卡住了（缓冲或读取变慢），设备已停止；准备好后再点播放"
    }

    private func handleNaturalCompletion(_ p: AVPlayer) {
        guard p === player, isPlaying, !isSeeking else { return }
        let end = p.currentTime().seconds
        if end.isFinite { currentSeconds = end }
        // tap 已经把到终点为止的声音都分析完了，直接发停止帧对
        isPlaying = false
        stopTimer(sendZero: true)
        zeroDisplay()
        statusLine = "播放结束，设备已停止"
    }

    func loadVideo(url: URL) {
        // 换视频前先停掉旧的，避免旧 Timer 读新 player 的 t=0 误驱动设备
        stopAll()
        playerCancellables.removeAll()
        seekGen += 1
        isSeeking = false
        meterGen += 1
        progressWatch.reset(now: Self.now())
        cancelScrubbing()
        durationSeconds = 0
        currentSeconds = 0
        lastActive = .zero
        audioStatus = .loading
        let displayName = url.lastPathComponent
        // 拷到 App 自己的目录、文件名加唯一前缀：选择器给的临时副本可能被系统清掉，
        // 同名文件也不会互相覆盖
        guard let local = Self.importVideo(from: url) else {
            if let old = currentVideoFile { try? FileManager.default.removeItem(at: old) }
            currentVideoFile = nil
            player = nil
            meter = nil
            audioStatus = .none
            videoName = "导入失败：\(displayName)"
            statusLine = "视频文件无法读取，请重新选择"
            return
        }
        if let old = currentVideoFile, old != local {
            try? FileManager.default.removeItem(at: old)
        }
        currentVideoFile = local
        videoName = displayName
        let asset = AVURLAsset(url: local)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p
        // 声音联动：给第一条音轨挂只读 tap。回调到主线程时核对还是不是当前视频
        let gen = meterGen
        let m = AudioLevelMeter()
        meter = m
        AudioLevelTap.install(on: item, asset: asset, meter: m) { [weak self, weak item] status in
            guard let self = self, let item = item,
                  item === self.player?.currentItem, gen == self.meterGen else { return }
            self.audioStatus = status
            switch status {
            case .ready:
                if self.statusLine == "—" { self.statusLine = "视频就绪" }
            case .noAudio:
                self.statusLine = "视频没有音轨，联动没有输出"
            case .failed(let why):
                self.statusLine = "音频分析不可用（\(why)），联动没有输出"
            case .none, .loading:
                break
            }
        }
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

    func togglePlay() {
        guard let p = player, ble?.state == .ready else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
            stopTimer(sendZero: true)
            zeroDisplay()
            statusLine = "已暂停"
        } else {
            // 额度 / 锁存 / 停止未确认时不开播（BLEManager 也会拦截）
            if let reason = ble?.safety.blockReason {
                statusLine = reason
                return
            }
            let t = p.currentTime().seconds
            let needsRestart = durationSeconds > 0 && t.isFinite && t >= durationSeconds - 0.5
            isPlaying = true
            // 用户点"播放"才显式开闸；tick 自己不会开闸
            ble?.userResumeOutput()
            meter?.reset()
            shaper.reset()
            lastActive = .zero
            // 暂停中的 seek 还没完成：完成回调会按最新的播放意图开始，不先播放旧位置
            guard !isSeeking else { return }
            if needsRestart {
                seek(to: 0)
            } else {
                p.play()
                startTimer()
            }
        }
    }

    /// 全屏 / 内嵌 / 播完重播共用。seek 和之后的缓冲保持设备为 0，不分析跳过的区间。
    func seek(to seconds: Double) {
        guard let p = player, seconds.isFinite else { return }
        let target = max(0, durationSeconds > 0 ? min(seconds, durationSeconds) : seconds)
        seekGen += 1
        let gen = seekGen
        isSeeking = true
        currentSeconds = target
        // seek 造成采样不连续：旧位置还没取走的声音不能算进新窗口
        meter?.reset()
        shaper.reset()
        p.pause()
        if isPlaying {
            // 全零走完整停止帧对但保留本次运行和闸门；不改 STOP / 上限 / 额度语义
            ble?.sendTick(levels: ActiveChannels.zero.values)
            lastActive = .zero
            intensity = 0
            statusLine = "正在跳转，设备暂停输出"
        }
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, p === self.player, gen == self.seekGen else { return }
                self.isSeeking = false
                let landed = p.currentTime().seconds
                if landed.isFinite { self.currentSeconds = landed }
                guard finished, landed.isFinite else {
                    self.isPlaying = false
                    p.pause()
                    self.stopTimer(sendZero: true)
                    self.zeroDisplay()
                    self.statusLine = "跳转未完成，设备已停止；请重试"
                    return
                }
                self.meter?.reset()
                self.needsResync = true
                self.progressWatch.awaitSeekProgress(from: landed, now: Self.now())
                // 停止 / 暂停 / 断开 / 被动停机期间回调不得复活输出
                guard self.isPlaying else { return }
                self.statusLine = "等待视频继续，设备暂停输出"
                p.play()
                self.startTimer()
            }
        }
    }

    func stopAll() {
        player?.pause()
        isPlaying = false
        stopTimer(sendZero: true)
        zeroDisplay()
        statusLine = "—"
    }

    /// 打开文件选择器之前：选择器是一整页弹出层，会盖住底部停止键，正在联动就先停下
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
        zeroDisplay()
        statusLine = reason ?? "已自动停止"
    }

    private func zeroDisplay() {
        lastActive = .zero
        level = 0
        intensity = 0
        shaper.reset()
    }

    var canPlay: Bool {
        player != nil && ble?.state == .ready
    }

    // MARK: - 内部

    private func startTimer() {
        stopTimer(sendZero: false)
        // 普通播放从头监视；seek 等待不因点播放或重建 Timer 被清掉
        progressWatch.startPlayback(at: player?.currentTime().seconds ?? .nan, now: Self.now())
        // 用 common modes，滚动页面时 tick 不暂停
        let t = Timer(timeInterval: AudioReactiveShaper.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer(sendZero: Bool) {
        timer?.invalidate()
        timer = nil
        lastTickAt = nil
        if sendZero {
            ble?.sendStop()
            lastActive = .zero
        }
    }

    /// 每 0.3 秒：取走音频窗口 → 灵敏度 / 噪声门 / 平滑 / 上限 → 变化时才发帧（约 3.3 Hz，低于节流能力）
    private func tick() {
        guard let p = player, let ble = ble else { return }
        // 拖进度条期间界面是活的，心跳照发，避免长时间拖动误触看门狗
        ble.heartbeat()
        guard !isSeeking, isPlaying else { return }
        // 心跳只证明 Timer 活着；播放器已停而 vm 仍以为在播时立即停机
        let t = p.currentTime().seconds
        let observation = progressWatch.observe(at: t, now: Self.now(), isPaused: p.timeControlStatus == .paused)
        if observation == .paused {
            handlePausedPlayer(p)
            return
        }
        let duration = p.currentItem?.duration.seconds ?? durationSeconds
        if PlaybackCompletion.reachedEnd(position: t, duration: duration) {
            handleNaturalCompletion(p)
            return
        }
        // 播放器没停、播放头却不走（缓冲 / 解码卡住 / 时间读不出来）：超过 stallLimit 就停机
        switch observation {
        case .waitingAfterSeek:
            // 等待落点前进期间 tap 可能已经在走：丢掉这几帧，恢复时不把跳转处的旧声音当成一阵强音
            _ = meter?.drain()
            return
        case .stalled:
            handleStall()
            return
        case .moving:
            break
        case .paused:
            return
        }
        guard t.isFinite else { return }
        currentSeconds = t

        let now = Self.now()
        let dt = lastTickAt.map { now - $0 } ?? AudioReactiveShaper.interval
        lastTickAt = now
        let window = meter?.drain() ?? .silent
        let out = shaper.step(window, settings: settings, dt: dt)
        level = out.level
        intensity = out.percent
        guard settings.enabled else { return }
        let vals = settings.channels.levels(percent: out.percent)
        let active = ActiveChannels(values: vals)
        if needsResync || active != lastActive {
            needsResync = false
            lastActive = active
            // tick 走不开闸的发送路径，看门狗锁住的闸不会被自动帧打开
            ble.sendTick(levels: vals)
            statusLine = String(format: "t=%.1fs 强度 %d", t, out.percent)
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
        // 换视频后预览也要换成新播放器
        if uiViewController.player !== player { uiViewController.player = player }
    }
}

/// 电平 / 强度条：只读展示
private struct MeterBar: View {
    let title: String
    /// 0~1
    let fraction: Double
    var color: Color = Velvet.rose
    var valueText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(Velvet.textSecondary)
                Spacer()
                if let valueText {
                    Text(valueText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Velvet.text)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color)
                        .frame(width: max(0, min(1, fraction)) * g.size.width)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueText ?? "\(Int(max(0, min(1, fraction)) * 100))%")
    }
}

/// 一起看：播本地视频，声音的响度实时变成伸缩 / 震动的强度（官方 0x08 帧）。
/// 没有脚本：强度只来自音轨，暂停 / 跳转 / 缓冲 / 播完都归零。
struct VideoSyncView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var privacy: PrivacyLock
    @StateObject private var vm = VideoSyncPlayer()
    /// 文件选择器（只有视频一种素材）
    @State private var showPicker = false
    /// 全屏播放中：内嵌预览让出播放器，onDisappear 不把全屏误判成离开页面
    @State private var isFullScreen = false
    /// 选择器被拦下的那句说明：钉在停止键上方一小会儿
    @State private var pickerNotice: String?
    /// 提示代次：重复点被拦下的入口时重新计时
    @State private var pickerNoticeGen = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 声音联动设置（@AppStorage 持久化，默认值保守；键名不带点）
    @AppStorage(AudioSyncSettings.Keys.enabled) private var syncEnabled = AudioSyncSettings.defaultEnabled
    @AppStorage(AudioSyncSettings.Keys.sensitivityDb) private var sensitivityDb = AudioSyncSettings.defaultSensitivityDb
    @AppStorage(AudioSyncSettings.Keys.maxPercent) private var maxPercent = AudioSyncSettings.defaultMaxPercent
    @AppStorage(AudioSyncSettings.Keys.channels) private var channelsRaw = AudioSyncSettings.defaultChannels.rawValue

    private var audioSettings: AudioSyncSettings {
        AudioSyncSettings(enabled: syncEnabled, sensitivityDb: sensitivityDb,
                          maxPercent: maxPercent,
                          channels: AudioSyncChannels(rawValue: channelsRaw) ?? .both)
    }

    /// 设备需要用户处理（停止重试中、需要确认物理关机、提供强制断开）时不弹选择器：
    /// 选择器是整页弹出层，会盖住红字和「解除锁定 / 强制断开」这些只在设备卡片上的按钮
    private var pickerBlocked: Bool {
        ble.safety.needsPhysicalAck || ble.safety.stopRetrying || ble.forceDisconnectOffered
    }

    /// 同手感页的规则：连上或有任何提示时才显示设备卡片；没连上时连接走「设备」准备项
    private var showsDeviceStatus: Bool {
        ble.state == .ready || ble.lastError != nil || ble.safety.needsPhysicalAck ||
        ble.safety.blockReason != nil || ble.safety.stopRetrying ||
        ble.state == .disconnecting || ble.forceDisconnectOffered
    }

    private var pickerBlockedMessage: String {
        "先处理上方设备卡片的提示，再选视频"
    }

    /// 选择器弹出前先停（选择器会盖住页面底部的停止键；选择器里另有一个停止键）。
    /// blockedReasonShown：这个入口自己把被拦的原因写在旁边了（幕布），不再往停止键上钉第二份
    private func openPicker(blockedReasonShown: Bool = false) {
        guard !pickerBlocked else {
            Haptics.warning()
            UIAccessibility.post(notification: .announcement, argument: pickerBlockedMessage)
            if !blockedReasonShown { flashPickerNotice() }
            return
        }
        vm.stopBeforePicker()
        showPicker = true
    }

    /// 被拦下的说明只显示一小会儿（3 秒）；减弱动态效果时只淡入淡出
    private func flashPickerNotice() {
        pickerNoticeGen += 1
        let gen = pickerNoticeGen
        let settle: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
        withAnimation(settle) {
            pickerNotice = pickerBlockedMessage
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard gen == pickerNoticeGen else { return }
            withAnimation(settle) { pickerNotice = nil }
        }
    }

    /// 选择器底部：停止键（停止帧对可能还在路上）；设备需要处理时连设备卡片一起带上
    private var pickerStopBar: some View {
        let showCard: Bool = ble.needsAttentionCard
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
                PageHeader(title: "一起看", subtitle: "声音起伏，身体也跟着一起")

                // 警告 / 锁存 / 断开中不带动画：一出现就完整可见。没连上时连接走「设备」准备项
                if showsDeviceStatus {
                    DeviceStatusCard(allowDisconnect: false, connectTitle: "连接", showsConnect: false)
                }

                stage

                link

                playback

                materials
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(VelvetBackground(glow: vm.isPlaying ? 0.6 : 0.15).ignoresSafeArea())
        // 停止常驻底部，任何时候一下就停。选择器被拦下时的一句说明就贴在停止键上面
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
        .onAppear {
            vm.attach(ble: ble)
            vm.applySettings(audioSettings)
        }
        // 设备那边处理好了：钉着的"先处理设备卡片"立刻收掉
        .onChange(of: pickerBlocked) { blocked in
            guard !blocked, pickerNotice != nil else { return }
            pickerNoticeGen += 1
            let settle: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.2)
            withAnimation(settle) { pickerNotice = nil }
        }
        // 设置改动立即生效（关掉联动会立刻归零）
        .onChange(of: syncEnabled) { _ in vm.applySettings(audioSettings) }
        .onChange(of: sensitivityDb) { _ in vm.applySettings(audioSettings) }
        .onChange(of: maxPercent) { _ in vm.applySettings(audioSettings) }
        .onChange(of: channelsRaw) { _ in vm.applySettings(audioSettings) }
        // 弹出层盖在根视图的入口页 / 解锁页 / 隐私模糊之上，各自也挂一份
        .sheet(isPresented: $showPicker) {
            // 选择器和底部停止条上下排：系统选择器是远程界面，未必让出底部标签栏
            VStack(spacing: 0) {
                DocumentPicker(contentTypes: [UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie],
                               onCancel: { showPicker = false }) { url in
                    showPicker = false
                    vm.loadVideo(url: url)
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

    /// 预览画面：没有视频时是一块邀请选择的幕布
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
            Button { openPicker(blockedReasonShown: true) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 44, weight: .thin))
                        .foregroundStyle(Velvet.roseGradient)
                    Text("选一段视频，和她一起看")
                        .font(Velvet.display(.title3, .medium))
                        .foregroundColor(Velvet.text)
                    if pickerBlocked {
                        Label(pickerBlockedMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(Velvet.warning)
                    } else {
                        Text("视频的声音会实时变成她的节奏")
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

    /// 声音联动：开关、灵敏度、上限、输出通道和实时电平
    private var link: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $syncEnabled) {
                Label("声音联动", systemImage: "speaker.wave.2.fill")
                    .font(Velvet.display(.headline, .medium))
                    .foregroundColor(Velvet.text)
            }
            .tint(Velvet.rose)
            .accessibilityHint("打开后，视频声音的响度实时变成设备强度")

            MeterBar(title: "电平", fraction: vm.level / 100, color: Velvet.blush,
                     valueText: "\(Int(vm.level.rounded()))")
            MeterBar(title: "强度", fraction: Double(vm.intensity) / 100, color: Velvet.rose,
                     valueText: "\(vm.intensity)%")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("灵敏度")
                        .font(.subheadline)
                        .foregroundColor(Velvet.text)
                    Spacer()
                    Text(sensitivityText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Velvet.textSecondary)
                }
                Slider(value: $sensitivityDb,
                       in: AudioSyncSettings.sensitivityRange, step: 1)
                    .tint(Velvet.rose)
                    .accessibilityLabel("灵敏度")
                    .accessibilityValue(sensitivityText)
                HStack {
                    Text("安静的视频也能带动")
                    Spacer()
                    Text("响的视频不顶满")
                }
                .font(.caption2)
                .foregroundColor(Velvet.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("强度上限")
                        .font(.subheadline)
                        .foregroundColor(Velvet.text)
                    Spacer()
                    Text("\(Int(maxPercent))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Velvet.textSecondary)
                }
                Slider(value: $maxPercent,
                       in: AudioSyncSettings.maxPercentRange, step: 5)
                    .tint(Velvet.gold)
                    .accessibilityLabel("强度上限")
                    .accessibilityValue("\(Int(maxPercent))%")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("输出到")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Picker("输出到", selection: $channelsRaw) {
                    ForEach(AudioSyncChannels.allCases) { ch in
                        Text(ch.title).tag(ch.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("输出到")
            }

            if vm.audioStatus == .noAudio {
                Label("这个视频没有音轨，联动没有输出", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundColor(Velvet.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed = vm.audioStatus {
                Label("音频分析不可用，联动没有输出", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(Velvet.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .velvetCard()
    }

    private var sensitivityText: String {
        String(format: "×%.1f", pow(10, sensitivityDb / 20))
    }

    /// 播放控制
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
                        Text("\(formatTime(vm.displaySeconds)) / \(formatTime(vm.durationSeconds))")
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
            // 拖动只预览，松手后精确 seek；与全屏共用同一条路径
            if vm.durationSeconds > 0 {
                PlaybackProgressSlider(vm: vm)
            }
            if !vm.canPlay {
                readiness
            } else if !vm.isPlaying, let reason = ble.safety.blockReason {
                // 都齐了但安全规则暂时不许输出（额度 / 锁存）：就在播放键旁边说清楚
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

    /// 播放键旁边的标题：齐了但额度暂时不许输出时不说"准备好了"
    private var playbackTitle: String {
        if vm.isPlaying { return "正在一起看" }
        guard vm.canPlay else { return "播放控制" }
        return ble.safety.blockReason == nil ? "准备好了" : "稍等片刻"
    }

    /// 还差什么才能播：设备 / 视频，缺哪个点哪个
    private var readiness: some View {
        let state: BLEManager.State = ble.state
        let connected: Bool = state == .ready
        let connecting: Bool = state == .scanning || state == .connecting || state == .discovering
        let busy: Bool = connecting || state == .disconnecting
        let deviceTitle: String = busy ? state.rawValue : "设备"
        let hasVideo: Bool = vm.player != nil
        return HStack(spacing: 8) {
            ReadinessChip(title: deviceTitle, done: connected, icon: "dot.radiowaves.left.and.right",
                          hint: busy ? "" : "连接设备", enabled: !busy, tappableWhenDone: false) {
                if !connected && !busy { ble.startScan() }
            }
            // 设备需要处理时不灰掉视频准备项：点了由 openPicker 拦下并说明，和选视频幕布一致
            ReadinessChip(title: "视频", done: hasVideo, icon: "film",
                          hint: "选择视频") { openPicker() }
        }
    }

    /// 素材
    private var materials: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "素材", systemImage: "film.stack")
            // 被拦下的原因常驻写在本卡片底部（blockedReasonShown）：点这一行时不再往停止键上钉第二份
            materialRow(icon: "film", title: "视频", value: vm.videoName, action: "选择") {
                openPicker(blockedReasonShown: vm.player != nil)
            }
            if pickerBlocked && vm.player != nil {
                // 已选过视频后幕布不在了，素材行是唯一入口：被拦的原因常驻写在这里
                Label(pickerBlockedMessage, systemImage: "exclamationmark.triangle.fill")
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

/// 两个播放界面共用：Timer / seek 回调不改拖动预览，旁白离散调整也能 seek。
private struct PlaybackProgressSlider: View {
    @ObservedObject var vm: VideoSyncPlayer
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Slider(
            value: Binding(get: { vm.displaySeconds }, set: { vm.updateScrubPosition($0) }),
            in: 0...vm.durationSeconds,
            onEditingChanged: { editing in
                vm.setScrubbing(editing)
                onEditingChanged(editing)
            }
        )
        .tint(Velvet.rose)
        .disabled(!vm.canPlay)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatTime(vm.displaySeconds))，共 \(formatTime(vm.durationSeconds))")
        .onDisappear {
            vm.cancelScrubbing()
            onEditingChanged(false)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
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
    /// 就绪后再点还有没有意义（视频可以换；设备连上了再点什么也不做，就不当按钮）
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

/// 全屏里设备卡片往上滚了多少（纯布局）：滚到底就收起"下面还有"的提示
private struct WarningScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    /// 设备卡片往上滚了多少
    @State private var warningScrollOffset: CGFloat = 0
    /// 底部控制条的实际高度（量出来之前为 0）
    @State private var bottomPanelHeight: CGFloat = 0

    /// 设备卡片离顶部的距离（让出退出键）
    private static let warningTop: CGFloat = 60
    /// 控制条上沿以上实在没地方时，设备卡片至少留这么高（露出一两行红字，其余滚动）
    private static let minWarningBand: CGFloat = 60
    private static let warningScrollSpace = "fullscreen-warning-scroll"

    /// 停止键直径、离边缘的距离；控制条右侧给它让出的宽度（控制条的内容不压到停止键下面）
    private static let stopSize: CGFloat = 60
    private static let stopInset: CGFloat = 20
    private static let stopReserve: CGFloat = stopSize + stopInset + 8

    private var needsDeviceAttention: Bool { ble.needsAttentionCard }

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
                // 卡片多高就占多高、贴着顶部；最多 warningHeight，也最多长到底部控制条上沿
                // （横屏 / 大字号时不盖住进度条和播放键），实在没地方也留 minWarningBand；放不下就滚动。
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
                    let atEnd: Bool = warningScrollOffset + bandHeight >= measured - 4
                    VStack(spacing: 0) {
                        ScrollView {
                            warningCard
                                .background(
                                    GeometryReader { g in
                                        Color.clear
                                            .preference(key: WarningCardHeightKey.self, value: g.size.height)
                                            .preference(key: WarningScrollOffsetKey.self,
                                                        value: -g.frame(in: .named(Self.warningScrollSpace)).minY)
                                    }
                                )
                        }
                        .coordinateSpace(name: Self.warningScrollSpace)
                        .scrollDisabled(fits)
                        .frame(height: bandHeight)
                        // 放不下时（横屏常见）底边淡出并挂一个向下的小箭头：iOS 的滚动条不动时不显示，
                        // 不提示的话「解除锁定」露半截也看不出能往上滑。滚到底就收起，不再盖着最后一个键。只是提示，不拦点击
                        .overlay(alignment: .bottom) {
                            if !fits && measured > 0 && !atEnd {
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
                    .onPreferenceChange(WarningScrollOffsetKey.self) { y in
                        if abs(y - warningScrollOffset) > 0.5 { warningScrollOffset = y }
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
            if vm.durationSeconds > 0 {
                PlaybackProgressSlider(vm: vm) { editing in
                    // 拖动期间不许自动收起；松手后重新计时。
                    scrubbing = editing
                    if !editing { scheduleAutoHide() }
                }
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
                Text("\(Self.formatTime(vm.displaySeconds)) / \(Self.formatTime(vm.durationSeconds))")
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
