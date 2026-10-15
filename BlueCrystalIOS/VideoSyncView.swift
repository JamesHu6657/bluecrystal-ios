import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import Combine

/// 视频联动播放器（ViewModel）：本地视频 + 声音 / 画面联动。
/// 强度来源二选一（VisualSyncSettings.source）：
/// - 声音（默认）：MTAudioProcessingTap 实时分析的音轨响度（AudioLevelTap / AudioLevelMeter），
///   经 AudioReactiveShaper（灵敏度、噪声门、平滑、上限）后每 0.3 秒走 BLEManager.sendTick（和以前逐位相同）；
/// - 画面：AVPlayerItemVideoOutput 拉帧的运动能量（VideoMotionTap / VideoMotionMeter），经 MotionNormalizer /
///   MotionShaper / SyncOutputStage（最低强度 / 上限 / 升幅限速 / 归零保持）后同样只经 tick() 发出。
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
    /// 画面条：归一化之后、噪声门之前的运动量（0~100），纯展示
    @Published private(set) var motionLevel: Double = 0
    /// 实际输出的强度（0 ~ 强度上限）
    @Published private(set) var intensity: Int = 0
    @Published private(set) var audioStatus: AudioLevelTap.Status = .none
    @Published private(set) var motionStatus: VideoMotionTap.Status = .none
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
    /// 最低强度只在 tap 真的有新鲜样本、播放器真的在播时生效
    private var audioFlow = AudioFlowWatch()
    /// 画面联动：只在跟随画面时安装取帧（声音模式零开销）。安装代次作废旧视频 / 已拆掉的 tap 晚到的回调
    private var motionMeter: VideoMotionMeter?
    private var motionTap: VideoMotionTap?
    private var motionGen = 0
    private var motionNormalizer = MotionNormalizer()
    private var motionShaper = MotionShaper()
    /// 画面模式的最低强度只在最近 1 秒确实有画面样本时生效
    private var motionFlow = MotionFlowWatch()
    /// 画面模式的出口：上限 / 最低强度（与声音侧逐位一致）+ 升幅限速 + 归零保持
    private var outputStage = SyncOutputStage()
    private var visualSettings = VisualSyncSettings()
    /// 播放中切换来源的交接（algo-opt-1）：声音→画面 4 秒内用声音补画面热身的空档（只淡出），
    /// 画面→声音先走出口限速追上声音直出（最多 10 拍）。不新增发送路径，仍只在 tick 里 sendTick
    private var handover = SourceHandover()
    /// 系统控件开播：只认"暂停 → 播放"的边沿；停止后锁存一次
    private var externalPlay = ExternalPlayGate()
    /// App 自己 seek 引起的 timeJumped 回声
    private var ownSeekEcho = OwnSeekEcho()
    /// vm 停着是因为系统控件暂停（含拖进度条时的暂停）：这时停止 / 被动停机要锁存，松手续播不能复活输出
    private var pausedByExternal = false
    /// seek 进行中看到过系统控件开播（之后的暂停是用户的，不是 seek 自己的）
    private var seekSawPlay = false
    /// 隐私锁（页面出现时传进来）。系统全屏是 UIKit 弹出层，盖在隐私锁之上，只靠界面遮挡拦不住
    private weak var privacy: PrivacyLock?

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func attachPrivacy(_ lock: PrivacyLock) { privacy = lock }

    /// 系统控件开播的拦截原因：隐私锁盖着或 App 不在前台。开播那一刻现查，
    /// 不依赖页面刷新（系统全屏盖着时下面的页面未必更新）
    private var externalPlayBlockReason: String? {
        if let lock = privacy, let ble = ble, lock.isCovering(ble) { return "App 已锁定：先解锁再播放" }
        if UIApplication.shared.applicationState != .active { return "App 不在前台，不开始联动" }
        return nil
    }

    /// 界面设置变化（@AppStorage）。关掉联动立刻归零但视频继续播；其余变化下一拍生效
    func applySettings(_ s: AudioSyncSettings) {
        let wasEnabled = settings.enabled
        settings = s
        if wasEnabled && !s.enabled {
            shaper.reset()
            motionShaper.reset()
            outputStage.reset()
            handover.cancel()
            intensity = 0
            // 全零帧在运行中会换成完整停止帧对、运行继续（OutputGate），设备没在输出时不发
            ble?.sendTick(levels: ActiveChannels.zero.values)
            lastActive = .zero
            if isPlaying { statusLine = "联动已关闭，视频继续播放" }
        }
        needsResync = true
    }

    /// 画面联动设置变化。切换来源不停播、不归零：下一拍按新来源算，升幅从设备现在的实际输出算起；
    /// 切到画面才安装取帧，切回声音就拆掉（声音模式零开销）
    func applyVisualSettings(_ v: VisualSyncSettings) {
        let previous = visualSettings.source
        visualSettings = v
        if v.source != previous {
            switch v.source {
            case .motion:
                if let item = player?.currentItem { installMotion(on: item, asset: item.asset) }
            case .audio:
                uninstallMotion()
            }
            outputStage.seed(lastActive.values)
            motionShaper.reset()
            motionFlow.reset()
            // 正在输出时才交接；没在播 / 联动关着时下一次开播本来就从 0 起
            if isPlaying, settings.enabled { handover.begin(v.source) } else { handover.cancel() }
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
                } else {
                    // 断开时在联动（或正被系统控件暂停着）：重连后系统控件续播不能直接复活输出
                    self.latchIfActive()
                    guard self.isPlaying else { return }
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
                // seek 进行中：seek 自己先暂停了播放器；之后系统控件先播再停 = 用户的暂停，不能被吞掉，
                // 否则 seek 完成回调会 p.play() 把输出恢复
                if self.isSeeking {
                    // 现查播放器：receive(on:) 送来的可能是上一次 seek 续播时排队的旧状态
                    if p.timeControlStatus != .paused || p.rate > 0 {
                        self.seekSawPlay = true
                    } else if self.seekSawPlay, self.isPlaying {
                        self.seekSawPlay = false
                        self.isPlaying = false
                        self.pausedByExternal = false
                        self.stopTimer(sendZero: true)
                        self.zeroDisplay()
                        self.statusLine = "已暂停"
                    }
                }
                // 系统播放器控件（播放键 / 拖完自动续播 / 重播）把视频播起来了，vm 还没在联动：跟上。
                // 只认暂停 → 播放的边沿：只放视频（设备没连）或 seek 中开播时边沿已用掉，
                // 之后缓冲 / 跳转引起的等待 ↔ 播放来回不会在没人点播放时开始输出
                let decision = self.externalPlay.observe(paused: status == .paused || p.rate <= 0)
                guard decision != .ignore, !self.isPlaying else { return }
                if decision == .rejectAfterStop {
                    p.pause()
                    self.statusLine = "已停止；要继续请再点一次播放"
                    return
                }
                guard !self.isSeeking else {
                    self.statusLine = "正在跳转；跳完后再点播放开始联动"
                    return
                }
                self.handleExternalPlay(p)
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

    /// 系统控件开播：等同用户点了播放（同样先过准入 / 锁存检查，再显式开闸）。
    /// 设备没连上时只放视频、不输出；被安全状态拦下时把视频也停住，让原因看得见
    private func handleExternalPlay(_ p: AVPlayer) {
        guard p === player else { return }
        // 隐私锁盖着 / 不在前台：系统全屏盖在锁之上也不许开播
        if let reason = externalPlayBlockReason {
            p.pause()
            statusLine = reason
            return
        }
        guard ble?.state == .ready else {
            // 边沿已用掉：连上设备后不会因缓冲 / 跳转自动开始输出，要再点播放
            statusLine = "设备未连接，只播放视频（连上后点播放开始联动）"
            return
        }
        if let reason = ble?.safety.blockReason {
            p.pause()
            statusLine = reason
            return
        }
        isPlaying = true
        pausedByExternal = false
        externalPlay.clearLatch()
        ble?.userResumeOutput()
        meter?.reset()
        shaper.reset()
        resetMotionSide()
        lastActive = .zero
        // 系统控件开播时播放器多半还在等（拖完续播 / 跳转 / 播完重播）：等播放头真正前进再输出
        if p.timeControlStatus != .playing {
            let t = p.currentTime().seconds
            if t.isFinite { progressWatch.awaitSeekProgress(from: t, now: Self.now()) }
        }
        startTimer()
        statusLine = "播放中"
    }

    /// 系统控件跳转（拖进度条、快进 / 快退 10 秒）：跳过的区间不分析，设备先归零，等播放头真正前进再恢复
    private func handleTimeJump(_ p: AVPlayer) {
        guard p === player, !isSeeking else { return }
        let landed = p.currentTime().seconds
        // App 自己 seek 的通知晚于完成回调到达：已经按落点处理过了
        if ownSeekEcho.consumeIfEcho(position: landed, now: Self.now()) { return }
        if landed.isFinite { currentSeconds = landed }
        meter?.reset()
        shaper.reset()
        audioFlow.reset()
        // 画面侧同样不和跳转前的画面做差
        resetMotionSide()
        needsResync = true
        // 暂停中跳转也记下落点（同 seek()）：之后不论哪个播放键开播，都等播放头真正前进
        if landed.isFinite { progressWatch.awaitSeekProgress(from: landed, now: Self.now()) }
        guard isPlaying else { return }
        ble?.sendTick(levels: ActiveChannels.zero.values)
        lastActive = .zero
        intensity = 0
        statusLine = "正在跳转，设备暂停输出"
    }

    /// 外部暂停：只停止设备
    private func handleExternalPause() {
        isPlaying = false
        pausedByExternal = true
        stopTimer(sendZero: true)
        zeroDisplay()
        statusLine = "外部暂停，设备已停止"
    }

    /// 用户停止 / 被动停机 / 断开时还在联动（或正被系统控件暂停着）：锁存一次，
    /// 系统控件随后的开播（拖动松手后的自动续播）先拦下
    private func latchIfActive() {
        if isPlaying || pausedByExternal { externalPlay.latchStop() }
        pausedByExternal = false
    }

    /// 播放中播放头卡住：画面不动时设备不能停在当前强度上
    private func handleStall() {
        isPlaying = false
        pausedByExternal = false
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
        pausedByExternal = false
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
        shaper.resetAdaptation()
        audioFlow.reset()
        // 画面侧：旧视频的取帧拆掉，重新学这个视频的运动范围
        uninstallMotion()
        motionNormalizer.resetAdaptation()
        outputStage.reset()
        handover.cancel()
        // 新播放器从暂停开始；旧视频的停止锁存和 seek 回声不带过来
        externalPlay = ExternalPlayGate()
        ownSeekEcho.clear()
        pausedByExternal = false
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
        // 不走 AirPlay：外部播放时 tap 拿不到样本，遥控器 / 控制中心也成了绕过页面的入口
        p.allowsExternalPlayback = false
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
                // 跟随画面时音轨有没有不影响输出
                if self.visualSettings.source == .audio { self.statusLine = "视频没有音轨，联动没有输出" }
            case .failed(let why):
                if self.visualSettings.source == .audio { self.statusLine = "音频分析不可用（\(why)），联动没有输出" }
            case .none, .loading:
                break
            }
        }
        // 画面联动：只在跟随画面时挂取帧
        installMotion(on: item, asset: asset)
        observeTimeControlStatus(p)
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak p] _ in
                guard let self = self, let p = p else { return }
                self.handleNaturalCompletion(p)
            }
            .store(in: &playerCancellables)
        NotificationCenter.default.publisher(for: AVPlayerItem.timeJumpedNotification, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak p] _ in
                guard let self = self, let p = p else { return }
                self.handleTimeJump(p)
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

    /// 跟随画面时给当前 item 挂取帧（已经挂着就不重复挂）。回调到主线程时核对还是不是当前视频、当前安装
    private func installMotion(on item: AVPlayerItem, asset: AVAsset) {
        guard visualSettings.source == .motion, motionTap == nil else { return }
        motionGen += 1
        let gen = motionGen
        let m = VideoMotionMeter()
        motionMeter = m
        motionStatus = .loading
        motionFlow.reset()
        motionTap = VideoMotionTap.install(on: item, asset: asset, meter: m) { [weak self, weak item] status in
            guard let self = self, let item = item,
                  item === self.player?.currentItem, gen == self.motionGen else { return }
            self.motionStatus = status
            guard self.visualSettings.source == .motion else { return }
            switch status {
            case .ready:
                if self.statusLine == "—" { self.statusLine = "视频就绪" }
                if self.statusLine.hasPrefix("手机发热") { self.statusLine = "画面分析已恢复" }
            case .noVideo:
                self.statusLine = "视频没有画面轨，画面联动没有输出"
            case .failed(let why):
                self.statusLine = "画面分析不可用（\(why)），联动没有输出"
            case .degraded(let why), .thermalPaused(let why):
                self.statusLine = why
            case .none, .loading:
                break
            }
        }
        // 正在联动时切到画面：立刻开始拉帧
        motionTap?.setActive(timer != nil)
    }

    /// 拆掉取帧（停定时器、item.remove(output)），智晚到的回调按代次作废
    private func uninstallMotion() {
        motionGen += 1
        motionTap?.uninstall()
        motionTap = nil
        motionMeter = nil
        motionStatus = .none
        motionLevel = 0
        motionShaper.reset()
        motionFlow.reset()
    }

    /// 画面侧跟声音侧一起清：丢掉没取走的画面窗口（分析器也丢掉参考帧，不和之前的画面做差），
    /// 平滑 / 升幅基准从 0 起，旧样本不算新鲜
    private func resetMotionSide() {
        motionMeter?.reset()
        motionShaper.reset()
        motionFlow.reset()
        outputStage.reset()
        handover.cancel()
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
        pausedByExternal = false
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
            // 本页播放键就是明确的重新开始：停止锁存作废
            externalPlay.clearLatch()
            // 用户点"播放"才显式开闸；tick 自己不会开闸
            ble?.userResumeOutput()
            meter?.reset()
            shaper.reset()
            resetMotionSide()
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

    /// 本页进度条 / 播完重播共用。seek 和之后的缓冲保持设备为 0，不分析跳过的区间。
    func seek(to seconds: Double) {
        guard let p = player, seconds.isFinite else { return }
        let target = max(0, durationSeconds > 0 ? min(seconds, durationSeconds) : seconds)
        seekGen += 1
        let gen = seekGen
        isSeeking = true
        currentSeconds = target
        // seek 造成采样不连续：旧位置还没取走的声音 / 画面不能算进新窗口
        meter?.reset()
        shaper.reset()
        audioFlow.reset()
        resetMotionSide()
        seekSawPlay = false
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
                    self.pausedByExternal = false
                    p.pause()
                    self.stopTimer(sendZero: true)
                    self.zeroDisplay()
                    self.statusLine = "跳转未完成，设备已停止；请重试"
                    return
                }
                self.meter?.reset()
                self.motionMeter?.reset()
                self.needsResync = true
                self.progressWatch.awaitSeekProgress(from: landed, now: Self.now())
                // 这次 seek 的 timeJumped 若晚于本回调到达，按回声忽略
                self.ownSeekEcho.record(landed: landed, now: Self.now())
                // 停止 / 暂停 / 断开 / 被动停机期间回调不得复活输出
                guard self.isPlaying else { return }
                self.statusLine = "等待视频继续，设备暂停输出"
                p.play()
                self.startTimer()
            }
        }
    }

    func stopAll() {
        latchIfActive()
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
        latchIfActive()
        player?.pause()
        isPlaying = false
        stopTimer(sendZero: false)
        zeroDisplay()
        statusLine = reason ?? "已自动停止"
    }

    private func zeroDisplay() {
        lastActive = .zero
        level = 0
        motionLevel = 0
        intensity = 0
        shaper.reset()
        motionShaper.reset()
        outputStage.reset()
        handover.cancel()
    }

    var canPlay: Bool {
        player != nil && ble?.state == .ready
    }

    // MARK: - 内部

    private func startTimer() {
        stopTimer(sendZero: false)
        // 开播前的样本不作数：首拍还没有新鲜样本时不加最低强度
        audioFlow.reset()
        motionFlow.reset()
        // 普通播放从头监视；seek 等待不因点播放或重建 Timer 被清掉
        progressWatch.startPlayback(at: player?.currentTime().seconds ?? .nan, now: Self.now())
        // 用 common modes，滚动页面时 tick 不暂停
        let t = Timer(timeInterval: AudioReactiveShaper.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        motionTap?.setActive(true)
    }

    private func stopTimer(sendZero: Bool) {
        timer?.invalidate()
        timer = nil
        motionTap?.setActive(false)
        lastTickAt = nil
        if sendZero {
            ble?.sendStop()
            lastActive = .zero
        }
    }

    /// 每 0.3 秒：取走音频窗口 → 灵敏度 / 噪声门 / 平滑 / 上限 → 变化时才发帧（约 3.3 Hz，低于节流能力）。
    /// 跟随画面时声音照常分析（自动灵敏度继续学），输出改由 motionTick 决定；跟随声音时这条路和以前逐位相同
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
            // 等待落点前进期间 tap 可能已经在走：丢掉这几帧，恢复时不把跳转处的旧声音 / 旧画面当成一阵强输出
            _ = meter?.drain()
            _ = motionMeter?.drain()
            return
        case .stalled:
            handleStall()
            return
        case .moving:
            break
        case .paused:
            return
        }
        // 缓冲 / 等待中：立刻归零（不等平滑慢慢落下），丢掉这段样本；卡住计时照常由 progressWatch 算
        if p.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            _ = meter?.drain()
            shaper.reset()
            _ = motionMeter?.drain()
            motionShaper.reset()
            outputStage.reset()
            handover.cancel()
            level = 0
            motionLevel = 0
            intensity = 0
            if lastActive != .zero, settings.enabled {
                ble.sendTick(levels: ActiveChannels.zero.values)
                lastActive = .zero
                statusLine = "视频缓冲中，设备暂停输出"
            }
            needsResync = true
            return
        }
        guard t.isFinite else { return }
        currentSeconds = t

        let now = Self.now()
        let dt = lastTickAt.map { now - $0 } ?? AudioReactiveShaper.interval
        lastTickAt = now
        let window = meter?.drain() ?? .silent
        audioFlow.note(window, now: now)
        // 最低强度：tap 就绪 + 播放器确实在播（缓冲中不算）+ 最近确实有样本流过
        let floorAllowed = audioFlow.allowsFloor(tapReady: audioStatus == .ready,
                                                 playerPlaying: p.timeControlStatus == .playing, now: now)
        let out = shaper.step(window, settings: settings, dt: dt, hasAudio: floorAllowed)
        level = out.level
        if visualSettings.source == .motion {
            motionTick(p, ble: ble, t: t, now: now, dt: dt)
            return
        }
        intensity = out.percent
        guard settings.enabled else { return }
        var vals = settings.channels.levels(percent: out.percent)
        if handover.isCatchingUp {
            // 画面→声音：先按出口的升幅限速 / 归零保持从设备现在的输出追上声音直出，追上（或 10 拍）后回到原路径
            let limited = outputStage.step(shaper.smoothed, settings: settings, hasSignal: floorAllowed)
            handover.noteCatchUp(limited: limited, direct: vals)
            vals = limited
            intensity = vals.max() ?? 0
        }
        let active = ActiveChannels(values: vals)
        if needsResync || active != lastActive {
            needsResync = false
            lastActive = active
            // tick 走不开闸的发送路径，看门狗锁住的闸不会被自动帧打开
            ble.sendTick(levels: vals)
            statusLine = String(format: "t=%.1fs 强度 %d", t, out.percent)
        }
    }

    /// 跟随画面的一拍：画面窗口 → 自适应归一化 → 门 / 平滑 → 出口（最低强度 / 上限 / 升幅限速 / 归零保持 / 夹紧）
    /// → 变化才发。最低强度只在分析在跑、播放器确实在播、最近 1 秒有画面样本时生效；没有新鲜画面就是 0
    private func motionTick(_ p: AVPlayer, ble: BLEManager, t: Double, now: TimeInterval, dt: TimeInterval) {
        let window = motionMeter?.drain() ?? .empty
        motionFlow.note(window, now: now)
        let target = motionNormalizer.step(window, gainDb: visualSettings.motionGainDb,
                                           auto: visualSettings.autoMotion, dt: dt)
        let shaped = motionShaper.step(target: target, dt: dt)
        motionLevel = shaped.level
        let motionSignal = motionFlow.allowsFloor(analyzerRunning: motionStatus.isAnalyzing,
                                                  playerPlaying: p.timeControlStatus == .playing, now: now)
        // 没有交接时就是 hasSignal ? confidence × smoothed : 0（和以前逐位相同）；
        // 刚从声音切过来：画面还在热身的那部分用声音补上，4 秒内淡出，不会高于两者中较大的那个
        let audioSignal = audioFlow.allowsFloor(tapReady: audioStatus == .ready,
                                                playerPlaying: p.timeControlStatus == .playing, now: now)
        let blended = handover.blend(motion: shaped.smoothed, confidence: motionNormalizer.confidence,
                                     motionSignal: motionSignal, audio: shaper.smoothed, audioSignal: audioSignal, dt: dt)
        let value = blended.value
        let hasSignal = blended.hasSignal
        guard settings.enabled else {
            // 联动关着：不发、升幅基准留在 0；强度条只预览打开后会是多少
            outputStage.reset()
            handover.cancel()
            intensity = SyncOutputStage.preview(value, settings: settings, hasSignal: hasSignal)
            return
        }
        let vals = outputStage.step(value, settings: settings, hasSignal: hasSignal)
        let shown = vals.max() ?? 0
        intensity = shown
        let active = ActiveChannels(values: vals)
        if needsResync || active != lastActive {
            needsResync = false
            lastActive = active
            // 同声音侧：只走不开闸的 sendTick
            ble.sendTick(levels: vals)
            statusLine = String(format: "t=%.1fs 画面强度 %d", t, shown)
        }
    }
}

/// 苹果自带播放器（播放 / 暂停、快进快退、进度条、倍速、系统全屏）。
/// 控件直接操作 AVPlayer，vm 通过 timeControlStatus / timeJumped / 播完通知跟随：
/// 暂停 = 设备立刻停止，跳转 = 先归零再恢复，开播 = 先过安全 / 隐私检查。
/// 关掉画中画、锁屏「正在播放」控件和 AirPlay（AVPlayer 上）：退到后台本来就会停机，不留一个绕过 vm 的入口
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// 隐私锁盖着 / 退后台：系统全屏是 UIKit 弹出层，盖在隐私层之上，只能把画面撤掉（多任务截图是黑的）
    var hidesVideo = false
    /// 现查隐私锁是否盖着（回前台时页面未必已刷新，不能只信 hidesVideo）
    var isCovered: () -> Bool = { false }
    /// 设备需要用户处理：在系统全屏里就退出来，让设备卡片露出来
    var attentionNeeded = false
    /// 全屏盖着时 SwiftUI 不一定再调 updateUIViewController：协调器直接订阅设备状态变化，现查是否需要处理
    var attentionChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    var attentionCheck: () -> Bool = { false }
    /// 系统全屏进出（全屏弹出时 SwiftUI 页面可能收到 onDisappear，不能因此停机）
    var onFullScreenChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onFullScreenChange: onFullScreenChange) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = false
        vc.updatesNowPlayingInfoCenter = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = true
        vc.delegate = context.coordinator
        context.coordinator.playerViewController = vc
        context.coordinator.player = player
        context.coordinator.hidesVideo = hidesVideo
        context.coordinator.isCovered = isCovered
        context.coordinator.attentionCheck = attentionCheck
        context.coordinator.watchAttention(attentionChanged)
        context.coordinator.applyPlayer()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.onFullScreenChange = onFullScreenChange
        // 换视频后换成新播放器；需要遮挡时撤掉画面（AVPlayer 本身不受影响）
        context.coordinator.playerViewController = uiViewController
        context.coordinator.player = player
        context.coordinator.hidesVideo = hidesVideo
        context.coordinator.isCovered = isCovered
        context.coordinator.attentionCheck = attentionCheck
        context.coordinator.applyPlayer()
        context.coordinator.exitFullScreenIfNeeded(attentionNeeded)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onFullScreenChange: (Bool) -> Void
        weak var playerViewController: AVPlayerViewController?
        weak var player: AVPlayer?
        /// 页面给的遮挡要求
        var hidesVideo = false
        var isCovered: () -> Bool = { false }
        /// 自己监听的退后台：系统全屏盖着时页面未必刷新，多任务截图前必须把画面撤掉
        private var inBackground = false
        /// AVKit 弹出的全屏 VC（只关它，不关别的弹层）
        weak var fullScreenVC: UIViewController?
        /// 页面最近一次给的「设备需要处理」
        var attentionNeeded = false
        var attentionCheck: () -> Bool = { false }
        private var attentionSub: AnyCancellable?

        /// 设备状态一变就现查（下一轮主队列，等 @Published 的新值落地）：在全屏里需要处理就退出
        func watchAttention(_ changed: AnyPublisher<Void, Never>) {
            attentionSub = changed
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.fullScreenVC != nil else { return }
                        self.exitFullScreenIfNeeded(self.attentionCheck())
                    }
                }
        }

        init(onFullScreenChange: @escaping (Bool) -> Void) {
            self.onFullScreenChange = onFullScreenChange
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                                   name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                                   name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        func applyPlayer() {
            guard let vc = playerViewController else { return }
            let shown: AVPlayer? = (hidesVideo || inBackground || isCovered()) ? nil : player
            if vc.player !== shown { vc.player = shown }
        }

        @objc private func didEnterBackground() {
            inBackground = true
            applyPlayer()
        }

        @objc private func willEnterForeground() {
            // 回前台时锁着（isCovered 现查）就继续撤着，解锁后页面刷新再放回来
            inBackground = false
            applyPlayer()
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            onFullScreenChange(true)
            let target = coordinator.viewController(forKey: .to)
            coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                guard let self = self else { return }
                // 捏合进全屏中途松手 = 取消：不会再有 willEnd，必须在这里把标志改回来，
                // 否则离开页面时 onDisappear 会把它当成全屏而不停机
                if ctx.isCancelled {
                    self.fullScreenVC = nil
                    self.onFullScreenChange(false)
                    return
                }
                self.fullScreenVC = target
                // 进全屏时设备已经需要处理：弹出动画中 dismiss 会被忽略，转场彻底结束后（下一轮主队列）补一次
                self.retryExitSoon()
            }
        }

        /// 设备需要处理（停止未确认 / 要物理关机 / 断开后可能仍在输出）时退出系统全屏：
        /// 全屏盖在设备卡片和隐私层之上，警告和「解除锁定 / 强制断开」必须看得见
        func retryExitSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.exitFullScreenIfNeeded(self.attentionNeeded || self.attentionCheck())
            }
        }

        func exitFullScreenIfNeeded(_ needed: Bool) {
            attentionNeeded = needed
            // 只关 AVKit 自己的全屏：presentedViewController 也可能是页面上的 sheet / 确认框，不能误关
            guard needed, let vc = playerViewController, let fs = fullScreenVC,
                  let presented = vc.presentedViewController, presented === fs,
                  !presented.isBeingPresented, !presented.isBeingDismissed else { return }
            // 由弹出者关闭：全屏上面若还压着别的层，也连同全屏一起关掉
            guard let presenter = fs.presentingViewController else { return }
            presenter.dismiss(animated: true) { [weak self, weak fs] in
                // 程序化关闭不保证回调 willEnd：真关掉了才把标志落回，离开页面时照常停机
                guard fs?.presentingViewController == nil else { return }
                self?.fullScreenVC = nil
                self?.onFullScreenChange(false)
            }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] ctx in
                // 取消了退出全屏就还在全屏
                if !ctx.isCancelled {
                    self?.fullScreenVC = nil
                    self?.onFullScreenChange(false)
                } else {
                    // 下滑退出中途取消：退出过程中错过的「需要处理」在这里补上
                    self?.retryExitSoon()
                }
            }
        }
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

/// 一起看：播本地视频，声音的响度（或画面的动作）实时变成伸缩 / 震动的强度（官方 0x08 帧）。
/// 没有脚本：强度只来自音轨或画面，暂停 / 跳转 / 缓冲 / 播完都归零。
struct VideoSyncView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var privacy: PrivacyLock
    @StateObject private var vm = VideoSyncPlayer()
    /// 文件选择器（只有视频一种素材）
    @State private var showPicker = false
    /// 苹果播放器自己的全屏：onDisappear 不把全屏误判成离开页面
    @State private var systemFullScreen = false
    @Environment(\.scenePhase) private var scenePhase
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
    @AppStorage(AudioSyncSettings.Keys.minPercent) private var minPercent = AudioSyncSettings.defaultMinPercent
    @AppStorage(AudioSyncSettings.Keys.autoGain) private var autoGain = AudioSyncSettings.defaultAutoGain
    @AppStorage(AudioSyncSettings.Keys.softDuck) private var softDuck = AudioSyncSettings.defaultSoftDuck
    // 画面联动设置（同上；来源默认声音，老用户无感升级）
    @AppStorage(VisualSyncSettings.Keys.source) private var visualSourceRaw = VisualSyncSettings.defaultSource.rawValue
    @AppStorage(VisualSyncSettings.Keys.motionGainDb) private var motionGainDb = VisualSyncSettings.defaultMotionGainDb
    @AppStorage(VisualSyncSettings.Keys.autoMotion) private var autoMotion = VisualSyncSettings.defaultAutoMotion

    private var audioSettings: AudioSyncSettings {
        AudioSyncSettings(enabled: syncEnabled, sensitivityDb: sensitivityDb,
                          maxPercent: maxPercent,
                          channels: AudioSyncChannels(rawValue: channelsRaw) ?? .both,
                          minPercent: minPercent, autoGain: autoGain, softDuck: softDuck)
    }

    /// 存储里认不出的来源（含 P2 才有的「声音+画面」）按声音
    private var visualSource: VisualSyncSource { VisualSyncSettings.resolveSource(rawValue: visualSourceRaw) }

    private var followsMotion: Bool { visualSource == .motion }

    private var visualSettings: VisualSyncSettings {
        VisualSyncSettings(source: visualSource, motionGainDb: motionGainDb, autoMotion: autoMotion)
    }

    private var sourceBinding: Binding<VisualSyncSource> {
        Binding(get: { VisualSyncSettings.resolveSource(rawValue: visualSourceRaw) },
                set: { visualSourceRaw = $0.rawValue })
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

    /// 和隐私遮罩（PrivacyCover）同一条规则撤掉画面：锁着、退后台、或暂时不活跃且设备不需要处理。
    /// 系统全屏盖着时页面未必刷新，退后台那一下由 SystemPlayerView 自己监听补上
    private var hidesVideo: Bool {
        privacy.isCovering(ble) || scenePhase == .background
            || (scenePhase == .inactive && !ble.privacyCoverBlocked)
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
                PageHeader(title: "一起看", subtitle: followsMotion ? "画面起伏，身体也跟着一起" : "声音起伏，身体也跟着一起")

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
            vm.applyVisualSettings(visualSettings)
            vm.attachPrivacy(privacy)
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
        .onChange(of: minPercent) { _ in vm.applySettings(audioSettings) }
        .onChange(of: autoGain) { _ in vm.applySettings(audioSettings) }
        .onChange(of: softDuck) { _ in vm.applySettings(audioSettings) }
        // 跟随来源 / 画面灵敏度 / 自动适应画面：播放中即时生效，不停播
        .onChange(of: visualSettings) { v in vm.applyVisualSettings(v) }
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
        // 系统全屏弹出时部分系统版本也会触发 onDisappear：全屏中不停机
        .onDisappear { if !systemFullScreen { vm.stopAll() } }
        // 解锁页上的停止：和本页停止键同一个 stopAll
        .onReceive(privacy.stopAllRequested) { _ in vm.stopAll() }
    }

    /// 预览画面：没有视频时是一块邀请选择的幕布
    @ViewBuilder private var stage: some View {
        if let p = vm.player {
            // 苹果自带控件：播放 / 暂停、快进快退、进度条、倍速、全屏。
            // 现查用的是对象本身（不在 body 之外读环境属性）
            let lock: PrivacyLock = privacy
            let manager: BLEManager = ble
            SystemPlayerView(player: p, hidesVideo: hidesVideo,
                             isCovered: { lock.isCovering(manager) },
                             attentionNeeded: ble.needsAttentionCard || pickerBlocked,
                             attentionChanged: manager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                             attentionCheck: {
                                 manager.needsAttentionCard || manager.safety.needsPhysicalAck ||
                                 manager.safety.stopRetrying || manager.forceDisconnectOffered
                             }) { systemFullScreen = $0 }
                .frame(height: 240)
                .frame(maxWidth: .infinity)
                .background(Color.black)
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
                        Text(followsMotion ? "视频的画面会实时变成她的节奏" : "视频的声音会实时变成她的节奏")
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

    /// 视频联动：开关、跟随（声音 / 画面）、实时电平、灵敏度、上限、最低强度、输出通道
    private var link: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $syncEnabled) {
                Label("视频联动", systemImage: followsMotion ? "eye.fill" : "speaker.wave.2.fill")
                    .font(Velvet.display(.headline, .medium))
                    .foregroundColor(Velvet.text)
            }
            .tint(Velvet.rose)
            .accessibilityHint(followsMotion ? "打开后，视频画面的动作实时变成设备强度" : "打开后，视频声音的响度实时变成设备强度")

            sourcePicker

            meters

            sensitivityControls

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
                HStack {
                    Text("最低强度（安静时不归零）")
                        .font(.subheadline)
                        .foregroundColor(Velvet.text)
                    Spacer()
                    Text("\(Int(min(minPercent, maxPercent)))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Velvet.textSecondary)
                }
                Slider(value: $minPercent,
                       in: AudioSyncSettings.minPercentRange, step: 1)
                    .tint(Velvet.gold)
                    .accessibilityLabel("最低强度")
                    .accessibilityValue("\(Int(min(minPercent, maxPercent)))%")
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

            statusNotes
        }
        .velvetCard()
    }

    /// 跟随：声音 / 画面（P1 只有这两个）
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("跟随")
                .font(.subheadline)
                .foregroundColor(Velvet.text)
            Picker("跟随", selection: sourceBinding) {
                ForEach(VisualSyncSource.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("跟随")
            .accessibilityValue(visualSource.title)
        }
    }

    /// 电平（跟随声音）或画面（跟随画面）+ 实际强度
    private var meters: some View {
        VStack(alignment: .leading, spacing: 14) {
            if followsMotion {
                MeterBar(title: "画面", fraction: vm.motionLevel / 100, color: Velvet.gold,
                         valueText: "\(Int(vm.motionLevel.rounded()))")
            } else {
                MeterBar(title: "电平", fraction: vm.level / 100, color: Velvet.blush,
                         valueText: "\(Int(vm.level.rounded()))")
            }
            MeterBar(title: "强度", fraction: Double(vm.intensity) / 100, color: Velvet.rose,
                     valueText: "\(vm.intensity)%")
        }
    }

    /// 灵敏度 + 自动适应：跟随声音时是音量的，跟随画面时是动作幅度的
    @ViewBuilder private var sensitivityControls: some View {
        if followsMotion {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("画面灵敏度")
                            .font(.subheadline)
                            .foregroundColor(Velvet.text)
                        Spacer()
                        Text(motionGainText)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(Velvet.textSecondary)
                    }
                    Slider(value: $motionGainDb,
                           in: VisualSyncSettings.motionGainRange, step: 1)
                        .tint(Velvet.rose)
                        .accessibilityLabel("画面灵敏度")
                        .accessibilityValue(motionGainText)
                    HStack {
                        Text("小动作也能带动")
                        Spacer()
                        Text("大动作不顶满")
                    }
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                }
                Toggle(isOn: $autoMotion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动适应画面")
                            .font(.subheadline)
                            .foregroundColor(Velvet.text)
                        Text("按这个视频自己的动作幅度自动调整，画面灵敏度变成微调")
                            .font(.caption2)
                            .foregroundColor(Velvet.textMuted)
                    }
                }
                .tint(Velvet.gold)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
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
                Toggle(isOn: $autoGain) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动灵敏度")
                            .font(.subheadline)
                            .foregroundColor(Velvet.text)
                        Text("按这个视频自己的音量自动调整，灵敏度滑块变成微调")
                            .font(.caption2)
                            .foregroundColor(Velvet.textMuted)
                    }
                }
                .tint(Velvet.gold)
                Toggle(isOn: $softDuck) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("轻柔声音降权")
                            .font(.subheadline)
                            .foregroundColor(Velvet.text)
                        Text("持续平稳的小声音（底噪、环境声、轻音乐）输出更轻，只会变轻不会变强")
                            .font(.caption2)
                            .foregroundColor(Velvet.textMuted)
                    }
                }
                .tint(Velvet.gold)
            }
        }
    }

    /// 当前来源的状态提示（没有音轨 / 画面轨、分析不可用、发热降频）
    @ViewBuilder private var statusNotes: some View {
        if let note = linkStatusNote {
            Label(note.text, systemImage: note.icon)
                .font(.caption)
                .foregroundColor(Velvet.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var linkStatusNote: (text: String, icon: String)? {
        if followsMotion {
            switch vm.motionStatus {
            case .noVideo:
                return ("这个视频没有画面轨，画面联动没有输出", "video.slash")
            case .failed:
                return ("画面分析不可用，联动没有输出", "exclamationmark.triangle")
            case .degraded(let why), .thermalPaused(let why):
                return (why, "thermometer.sun")
            case .none, .loading, .ready:
                return nil
            }
        }
        if vm.audioStatus == .noAudio {
            return ("这个视频没有音轨，联动没有输出", "speaker.slash")
        }
        if case .failed = vm.audioStatus {
            return ("音频分析不可用，联动没有输出", "exclamationmark.triangle")
        }
        return nil
    }

    private var sensitivityText: String {
        // 自动模式下手动灵敏度只做 ±6 dB 微调：读数显示实际生效的倍数
        let r = AudioReactiveShaper.autoTrimRange
        let db = autoGain ? min(r.upperBound, max(r.lowerBound, sensitivityDb)) : sensitivityDb
        return String(format: autoGain ? "微调 ×%.1f" : "×%.1f", pow(10, db / 20))
    }

    private var motionGainText: String {
        String(format: "×%.1f", pow(10, motionGainDb / 20))
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
            // 拖动只预览，松手后精确 seek（系统播放器的进度条由 vm 的 timeJumped 跟随）
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

/// 本页进度条：Timer / seek 回调不改拖动预览，旁白离散调整也能 seek。
private struct PlaybackProgressSlider: View {
    @ObservedObject var vm: VideoSyncPlayer

    var body: some View {
        Slider(
            value: Binding(get: { vm.displaySeconds }, set: { vm.updateScrubPosition($0) }),
            in: 0...vm.durationSeconds,
            onEditingChanged: { editing in vm.setScrubbing(editing) }
        )
        .tint(Velvet.rose)
        .disabled(!vm.canPlay)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatTime(vm.displaySeconds))，共 \(formatTime(vm.durationSeconds))")
        .onDisappear { vm.cancelScrubbing() }
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
