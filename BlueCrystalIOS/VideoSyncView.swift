import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import PhotosUI
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
    /// 画面条下的提示：姿态辅助在起作用（algo-opt-3，姿态融合权重 ≥ 0.2），纯展示
    @Published private(set) var motionPoseAssist = false
    /// 实际输出的强度（0 ~ 强度上限）
    @Published private(set) var intensity: Int = 0
    @Published private(set) var audioStatus: AudioLevelTap.Status = .none
    @Published private(set) var motionStatus: VideoMotionTap.Status = .none
    /// rhythm-follow P1：伸缩跟随动作频率时的状态（没打开 / 没在跟画面时 nil）
    @Published private(set) var rhythmStatus: String?
    /// rhythm-phase P2：相位脉动的状态（没打开时 nil）
    @Published private(set) var pulseStatus: String?
    /// rhythm-context P3：动作识别 / 撞击声相位校正的状态行（开着时才有）
    @Published private(set) var contextStatus: String?
    @Published private(set) var anchorStatus: String?
    /// rhythm-lookahead P4：前瞻 / 预扫描的状态行（开着时才有）
    @Published private(set) var lookaheadStatus: String?
    @Published private(set) var prescanStatus: String?
    /// av-fusion F1：「声画：」状态行（声画融合开着才有；只显示，不改输出）
    @Published private(set) var fusionStatus: String?
    /// av-fusion F2：「节奏确认：」状态行（节奏由声音确认开着才有）
    @Published private(set) var voteStatus: String?
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
    /// rhythm-follow P1：画面里的往复频率 → 伸缩档位（设置里打开才用；只改目标档位，出口 / 发送路径不变）
    private var rhythm = RhythmFollower()
    /// rhythm-phase P2：画面往复的相位锁（PLL）+ 0.1 秒子拍脉动（设置里打开才用；没锁上 / 没标定 = P1 原样）。
    /// 子拍只在 tick() 里、只经 outputStage（上限 / 升幅按时间折算 ≤ +20 / 0.3 秒 / 归零保持）→ sendTick，不新增发送路径
    private var phaseLock = RhythmPhaseLock()
    private var pulse = RhythmPulseDriver()
    /// rhythm-context P3（默认关）：动作识别只改交给频率跟随器 / 相位锁的那份窗口副本（强度那条路不看）；
    /// 撞击声相位校正只给脉动的相位加一个有界偏移（RhythmPulseDriver.phaseOffset）。都不新增发送路径
    private var actionContext = ActionContext()
    /// av-fusion F1（默认关）：声音特征 + 耦合度，每个完整拍算一次，只出状态行和调试列（不改任何交给出口的值、不新增发送路径）。
    /// bandBacklog：融合和撞击声校正都开着时，融合先取走的 P3 频带块存在这里，校正取的时候原样接上（校正的输入逐位不变）
    private var fusion = AVFusionEngine()
    private var fusionBeat: AVFusionBeat?
    /// av-fusion F2（默认关）：声音给画面节奏投票——只在上一拍融合状态 = 耦合时改交给跟随器 / 相位锁的窗口副本
    /// （P4 前瞻之后、P3 动作识别之前）和跟随器这一拍的跳变确认拍数；不改出口、不新增发送路径
    private var rhythmVote = AVRhythmVote()
    /// av-fusion（F1 复审 L2）：电平计现在算没算 6 段扩展特征（fusionFeaturesWanted 上次交给电平计的值）
    private var fusionAudioOn = false
    private var bandBacklog = AudioBandBacklog()
    /// 调试记录（默认关）：只记数字，不存画面；只读不改控制路径，关着时不做任何事
    let debugLog = MotionDebugLog()
    var debugRecording = false {
        didSet {
            guard debugRecording != oldValue else { return }
            // av-fusion F0：tap 回调时间只在调试记录开着时记（关着时实时线程只多看一个布尔）
            meter?.setTimingEnabled(debugRecording)
            resetAVDebug()
        }
    }
    /// av-fusion F0（观测与标定，只在调试记录开着时动）：tap 提前量、这一拍取走的频带块汇总、上一行记到的视频时间
    private var tapLead = AudioTapLeadEstimator()
    private var beatBands = AudioBandSummary()
    private var avLoggedItem = -Double.infinity
    private var onsetDetector = AudioOnsetDetector()
    private var audioAnchor = AudioPhaseAnchor()
    /// rhythm-lookahead P4（默认关）：前瞻 / 预扫描另开一路解码（LookaheadReader，只在设置生效时建；关着时不建、不解码）。
    /// 前瞻只改交给频率跟随器 / 相位锁的那份窗口副本，外加脉动指令相位的有界提前量（LookaheadCoordinator）；
    /// 预扫描只给 MotionNormalizer 一个起点（还没学过时才用）。都不新增发送路径，输出仍只经 tick() → outputStage → sendTick
    private var lookaheadReader: LookaheadReader?
    private var lookaheadGen = 0
    private var lookahead = LookaheadCoordinator()
    /// 这一拍前瞻用的快照（给之后的提前量用；这一拍没用前瞻时 nil）
    private var lookaheadBeat: (timeline: LookaheadTimeline, clock: RhythmLookahead.Clock, latency: TimeInterval)?
    private var prescanSummary: MotionPrescan.Summary?
    private var prescanTried = false
    private var prescanSeeded = false
    /// 上一次交给读帧那边的预扫描开关（复审 M1：结果用不上了就把这一路停掉）
    private var readerPrescan = false
    /// 预扫描进度在暂停时也要刷新（Timer 只在扫的时候跑，1 秒一次，只读快照、不发帧）
    private var prescanPoll: Timer?
    /// Timer 间隔：平时 0.3 秒（和以前逐位相同）；相位脉动打开时 0.1 秒，每 3 次里 1 次走完整拍
    private var tickInterval: TimeInterval = AudioReactiveShaper.interval
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
            resetRhythm()
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
        let previousRhythm = visualSettings.rhythmFollow
        let previousPulse = visualSettings.rhythmPulse
        let previousContext = visualSettings.usesRhythmContext
        let previousAnchor = visualSettings.usesAudioAnchor
        let previousLookahead = visualSettings.usesLookahead
        let previousPrescan = visualSettings.usesPrescan
        let previousFusion = visualSettings.usesAVFusion
        let previousVote = visualSettings.usesAVRhythmConfirm
        // F1 复审 L2：上一次交给电平计的「融合要不要声音特征 / 频带」
        let previousFusionAudio = fusionAudioOn
        visualSettings = v
        // F1：融合开关一变就从头来（关掉 = 状态行消失）
        if v.usesAVFusion != previousFusion { resetFusion() }
        // F2：节奏确认一变就从头来（关掉 = 窗口副本原样、状态行消失）
        if v.usesAVRhythmConfirm != previousVote { resetVote() }
        // P3：动作识别 / 撞击声校正开关一变就从头确认（关掉 = 回到 P2 行为）
        if v.usesRhythmContext != previousContext { resetContext() }
        if v.usesAudioAnchor != previousAnchor { resetAnchor() }
        // P4：前瞻一变就从头核对；预扫描关掉就作废这个视频已扫的结果（再打开重扫）
        if v.usesLookahead != previousLookahead { resetLookahead() }
        if v.usesPrescan != previousPrescan, !v.usesPrescan { clearPrescan() }
        applyRhythmFlags()
        // F1：融合开着时频带一直在分，撞击声校正这时才打开——照融合关着时「频带从关到开」那样从头分（校正输入逐位不变）
        if v.usesAudioAnchor, !previousAnchor, previousFusionAudio { meter?.restartBands() }
        // 打开 / 关掉频率跟随：从头确认节奏（打开后 weight 1 秒内交接，关掉时伸缩回到按动作强度，降不限速）
        if v.rhythmFollow != previousRhythm { resetRhythm() }
        // P2：打开 / 关掉相位脉动从头锁相位；Timer 间隔跟着换（只重建 Timer，不动其余状态）
        if v.rhythmPulse != previousPulse { resetPulse() }
        retimeIfNeeded(v.tickInterval)
        if v.source != previous {
            switch v.source {
            case .motion:
                if let item = player?.currentItem { installMotion(on: item, asset: item.asset) }
            case .audio:
                uninstallMotion()
            }
            outputStage.seed(lastActive.values)
            motionShaper.reset()
            resetRhythm()
            motionFlow.reset()
            // 正在输出时才交接；没在播 / 联动关着时下一次开播本来就从 0 起
            if isPlaying, settings.enabled { handover.begin(v.source) } else { handover.cancel() }
        }
        updateLookaheadReader()
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
        bandBacklog.clear()
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
        bandBacklog.clear()
        shaper.reset()
        audioFlow.reset()
        // 画面侧同样不和跳转前的画面做差
        resetMotionSide()
        notePlayheadToReader(playing: false)
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
        lookahead.resetVideo()
        clearPrescan()
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
        applyFusionAudioFlags()
        m.setTimingEnabled(debugRecording)
        bandBacklog.clear()
        resetFusion()
        resetAVDebug()
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
                if d.seconds.isFinite, d.seconds > 0 {
                    self.durationSeconds = d.seconds
                    // 复审 M3：读帧那边只从 notePlayhead 知道时长；装读帧时时长多半还没读出来，暂停着时进度一直出不来
                    if self.lookaheadReader != nil {
                        self.notePlayheadToReader(playing: self.isPlaying)
                        self.refreshPrescanStatus()
                    }
                }
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
            // F1 复审 L2：画面分析停了 / 恢复了，声音特征跟着关 / 开
            self.applyFusionAudioFlags()
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
        applyRhythmFlags()
        motionTap?.setActive(timer != nil)
        updateLookaheadReader()
    }

    /// rhythm-context P3：分析那边的两个开关（相位拟合只在相位脉动用得上时算；动作识别开着才跑手 / 脸 / 周期区域），
    /// 撞击声频带只在校正开着时分
    private func applyRhythmFlags() {
        motionTap?.setRhythmFlags(phaseFit: visualSettings.usesPulseTiming, context: visualSettings.usesRhythmContext)
        applyFusionAudioFlags()
        configureReader()
    }

    /// av-fusion（F1 复审 L2）：6 段扩展特征（+ 融合自己要的频带）只在用得上时算——融合生效、在联动（Timer 跑着）、
    /// 画面分析在跑（有画面轨、没发热暂停）。暂停 / 停止 / 没画面 / 不在跟随画面 / 开关关着时实时线程不跑 6 段带通，
    /// 主线程也不做 FFT。撞击声校正的频带照旧只看 usesAudioAnchor（融合关着时这里和 f706431 逐位相同）
    private var fusionFeaturesWanted: Bool {
        visualSettings.usesAVFusion && timer != nil && motionStatus.isAnalyzing
    }

    /// av-fusion：把 fusionFeaturesWanted 交给电平计（变了才动；电平计自己也只在变化时清缓冲）
    private func applyFusionAudioFlags() {
        let want = fusionFeaturesWanted
        fusionAudioOn = want
        meter?.setBandsEnabled(visualSettings.usesAudioAnchor || want)
        meter?.setFeaturesEnabled(want)
    }

    /// rhythm-lookahead P4（复审 M1）：预扫描的结果还用得上——开关生效、这个视频还没有结果、MotionNormalizer 还一拍都没学过。
    /// 学过以后 seed 一定不用（只在 warmElapsed == 0 时生效），再扫就是白费一路解码；已经有结果时（切来源再切回来）也不重扫
    private var prescanWanted: Bool {
        visualSettings.usesPrescan && prescanSummary == nil && motionNormalizer.warmElapsed == 0
    }

    /// 读帧那边的开关（没建读帧时什么都不做）
    private func configureReader() {
        guard let r = lookaheadReader else { return }
        let pre = prescanWanted
        readerPrescan = pre
        r.configure(lookahead: visualSettings.usesLookahead, prescan: pre, phaseFit: visualSettings.usesPulseTiming)
    }

    /// rhythm-lookahead P4：前瞻生效或预扫描还用得上、而且画面取帧装着时才建另一路解码；否则拆掉（关着时一帧都不多解）
    private func updateLookaheadReader() {
        guard visualSettings.usesLookahead || prescanWanted, motionTap != nil, let item = player?.currentItem else {
            cancelLookaheadReader()
            refreshPrescanStatus()
            return
        }
        if lookaheadReader == nil {
            lookaheadGen += 1
            let gen = lookaheadGen
            let reader = LookaheadReader(asset: item.asset) { [weak self] summary in
                guard let self = self, gen == self.lookaheadGen else { return }
                self.prescanSummary = summary
                self.refreshPrescanStatus()
                // M1：有结果了，预扫描那一路停掉（只剩预扫描时整个读帧拆掉）。放到下一轮主线程做：别在读帧自己的回调里拆它
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, gen == self.lookaheadGen else { return }
                    self.updateLookaheadReader()
                }
            }
            lookaheadReader = reader
            reader.start()
        }
        configureReader()
        notePlayheadToReader(playing: isPlaying)
        refreshPrescanStatus()
    }

    private func cancelLookaheadReader() {
        if let r = lookaheadReader {
            lookaheadGen += 1
            r.cancel()
            lookaheadReader = nil
        }
        readerPrescan = false
        resetLookahead()
        stopPrescanPoll()
        if prescanStatus != nil { prescanStatus = nil }
    }

    /// 报播放头给读帧那边（完整拍 / seek 落地 / 跳转 / 建读帧时）
    private func notePlayheadToReader(playing: Bool) {
        guard let r = lookaheadReader, let p = player else { return }
        r.notePlayhead(p.currentTime().seconds, playing: playing, duration: durationSeconds)
    }

    /// 这个视频的预扫描结果作废（换视频 / 关掉预扫描）
    private func clearPrescan() {
        prescanSummary = nil
        prescanTried = false
        prescanSeeded = false
        stopPrescanPoll()
        if prescanStatus != nil { prescanStatus = nil }
    }

    private func stopPrescanPoll() {
        prescanPoll?.invalidate()
        prescanPoll = nil
    }

    /// 预扫描状态行；还在扫时开一个 1 秒的刷新 Timer（只读快照）
    private func refreshPrescanStatus() {
        // 有结果 / 已经停扫时读帧可能已经拆了（只开预扫描时）：状态行不靠读帧，只要画面取帧装着就显示
        guard visualSettings.usesPrescan, motionTap != nil else {
            stopPrescanPoll()
            if prescanStatus != nil { prescanStatus = nil }
            return
        }
        var running = false
        let text: String
        if let s = prescanSummary {
            if !s.isValid {
                text = "预扫描：扫完了，可用的画面太少，按实时学"
            } else if !prescanTried {
                text = "预扫描：扫完了，开始播放时按整段视频的动作范围起步"
            } else if prescanSeeded {
                text = "预扫描：已按整段视频的动作范围起步"
            } else {
                text = "预扫描：扫完时已经开始播放，这次按实时学"
            }
        } else if motionNormalizer.warmElapsed > 0 {
            // M1：播放已经开始学了（扫到一半开播，或开播后才打开开关），这次的结果用不上，预扫描那一路已停 / 不开
            text = "预扫描：已经开始播放，这次按实时学（不再扫描，换视频后重新扫）"
        } else if let r = lookaheadReader, readerPrescan {
            let snap = r.snapshot()
            if snap.prescanFailed {
                text = "预扫描：读不了这个视频文件，按实时学"
            } else if let why = snap.blocked {
                text = "预扫描：\(why)"
                running = true
            } else if let pr = snap.prescanProgress {
                text = String(format: "预扫描：已扫 %d%%（关掉开关可随时停）", Int((pr * 100).rounded(.down)))
                running = true
            } else {
                text = "预扫描：准备中…"
                running = true
            }
        } else {
            stopPrescanPoll()
            if prescanStatus != nil { prescanStatus = nil }
            return
        }
        if text != prescanStatus { prescanStatus = text }
        if running, prescanPoll == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPrescanStatus() }
            RunLoop.main.add(t, forMode: .common)
            prescanPoll = t
        } else if !running {
            stopPrescanPoll()
        }
    }

    /// 拆掉取帧（停定时器、item.remove(output)），智晚到的回调按代次作废
    private func uninstallMotion() {
        motionGen += 1
        motionTap?.uninstall()
        motionTap = nil
        cancelLookaheadReader()
        motionMeter = nil
        motionStatus = .none
        applyFusionAudioFlags()
        motionLevel = 0
        motionPoseAssist = false
        motionNormalizer.reset()
        motionShaper.reset()
        resetRhythm()
        motionFlow.reset()
    }

    /// 画面侧跟声音侧一起清：丢掉没取走的画面窗口（分析器也丢掉参考帧，不和之前的画面做差），
    /// 平滑 / 升幅基准从 0 起，旧样本不算新鲜
    private func resetMotionSide() {
        motionMeter?.reset()
        // 姿态融合从头确认（seek / 跳转后可能已经不是同一个人）；运动范围和热身保留
        motionNormalizer.reset()
        motionShaper.reset()
        resetRhythm()
        motionFlow.reset()
        outputStage.reset()
        handover.cancel()
        resetFusion()
    }

    /// 当前视频在 App 目录里的副本（换视频时删旧的，避免占空间）
    private var currentVideoFile: URL?

    init() {
        // 上次运行留下的视频副本清掉
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncVideos", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        // 同样清掉上次没导完的相册视频副本、导出过的调试表格
        PhotoVideoPicker.purgeImports()
        MotionDebugLog.purgeExports()
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
            bandBacklog.clear()
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
        bandBacklog.clear()
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
                self.bandBacklog.clear()
                self.motionMeter?.reset()
                self.notePlayheadToReader(playing: false)
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

    /// 导出调试表格之前：分享面板同样会盖住底部停止键，正在联动就先停下
    func stopBeforeExport() {
        guard isPlaying else { return }
        stopAll()
        statusLine = "导出表格前已停止"
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
        motionPoseAssist = false
        intensity = 0
        shaper.reset()
        motionShaper.reset()
        resetRhythm()
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
        tickInterval = visualSettings.tickInterval
        installTickTimer()
        motionTap?.setActive(true)
        applyFusionAudioFlags()
    }

    private func installTickTimer() {
        // 用 common modes，滚动页面时 tick 不暂停
        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// P2：播放中开关相位脉动 → 只换 Timer 间隔（0.3 ↔ 0.1 秒），不发帧、不清样本、不动 lastTickAt
    private func retimeIfNeeded(_ interval: TimeInterval) {
        guard interval != tickInterval else { return }
        tickInterval = interval
        pulse.reset()
        guard let old = timer else { return }
        old.invalidate()
        installTickTimer()
    }

    private func stopTimer(sendZero: Bool) {
        timer?.invalidate()
        timer = nil
        motionTap?.setActive(false)
        applyFusionAudioFlags()
        lastTickAt = nil
        if sendZero {
            ble?.sendStop()
            lastActive = .zero
        }
        // P4（复审 L2）：停播 / 暂停后读帧那边按「没在播」排预扫描（停止帧先发，这里只是报个状态；没建读帧时什么都不做）
        notePlayheadToReader(playing: false)
    }

    /// 每 0.3 秒：取走音频窗口 → 灵敏度 / 噪声门 / 平滑 / 上限 → 变化时才发帧（约 3.3 Hz，低于节流能力）。
    /// 跟随画面时声音照常分析（自动灵敏度继续学），输出改由 motionTick 决定；跟随声音时这条路和以前逐位相同
    private func tick() {
        guard let p = player, let ble = ble else { return }
        // 拖进度条期间界面是活的，心跳照发，避免长时间拖动误触看门狗
        ble.heartbeat()
        // P2 子拍（Timer 0.1 秒时，完整拍之间的两次）：只按相位锁的预测改伸缩，过同一个出口，变化才发
        let host = CACurrentMediaTime()
        if tickInterval == AudioReactiveShaper.interval {
            pulse.noteFullBeat(at: host)
        } else if !pulse.takesFullBeat(at: host) {
            pulseSubTick(p, ble: ble)
            return
        }
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
            resetRhythm()
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
        lookaheadReader?.notePlayhead(t, playing: p.timeControlStatus == .playing, duration: durationSeconds)

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
            let limited = outputStage.step(shaper.smoothed, settings: settings, hasSignal: floorAllowed,
                                           now: CACurrentMediaTime())
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
            // 显示实际发出的值（画面→声音追赶期间是限速后的，不是 out.percent）
            statusLine = String(format: "t=%.1fs 强度 %d", t, vals.max() ?? 0)
        }
    }

    /// rhythm-follow P1：节奏从头确认、状态清掉（和 motionShaper.reset() 同时调用）
    private func resetRhythm() {
        rhythm.reset()
        if rhythmStatus != nil { rhythmStatus = nil }
        resetVote()
        resetContext()
        resetPulse()
        resetLookahead()
    }

    /// rhythm-lookahead P4：方向 / 提前量从头来（核对历史保留；读帧那边重读时 RhythmLookahead 自己清，换视频全清）
    private func resetLookahead() {
        lookahead.reset()
        lookaheadBeat = nil
        if lookaheadStatus != nil { lookaheadStatus = nil }
    }

    /// rhythm-lookahead P4：这一拍的前瞻（读帧那边停着 / 出问题 = 原样，等同 P4 关着）
    private func refineLookahead(_ window: MotionWindow, reader: LookaheadReader, player p: AVPlayer) -> MotionWindow {
        let snap = reader.snapshot()
        let clock = RhythmLookahead.Clock(hostNow: CACurrentMediaTime(), itemNow: p.currentTime().seconds, rate: Double(p.rate))
        let latency = visualSettings.pulseLatencyMs / 1000
        let out = lookahead.refine(window, enabled: snap.lookUsable, timeline: snap.timeline, clock: clock, latency: latency)
        lookaheadBeat = snap.lookUsable ? (snap.timeline, clock, latency) : nil
        let text = lookahead.statusText(reader: snap.blocked ?? snap.lookNote)
        if text != lookaheadStatus { lookaheadStatus = text }
        return out
    }

    /// rhythm-context P3：动作识别从头判断（未知 = P2 行为）
    private func resetContext() {
        actionContext.reset()
        if contextStatus != nil { contextStatus = nil }
    }

    /// rhythm-context P3：撞击声校正从头来，偏移立刻回 0（= P2 相位）
    private func resetAnchor() {
        audioAnchor.reset()
        onsetDetector.reset()
        pulse.phaseOffset = 0
        _ = meter?.drainBands()
        bandBacklog.clear()
        avLoggedItem = -Double.infinity
        if anchorStatus != nil { anchorStatus = nil }
    }

    /// av-fusion F0：调试记录的声画列从头来（换视频 / 开关调试记录）
    private func resetAVDebug() {
        tapLead.reset()
        beatBands = AudioBandSummary()
        avLoggedItem = -Double.infinity
    }

    /// av-fusion F0：这一拍的声画调试列（调试记录开着才调）：取走 tap 回调时间、读一次播放器时钟、
    /// 这一拍新出现的撞击时刻（撞击声校正开着才有）和频带汇总。只读，不改任何控制状态
    private func avDebugFields(_ p: AVPlayer) -> [String] {
        let clock = MediaClockSnapshot(host: CACurrentMediaTime(), item: p.currentTime().seconds, rate: Double(p.rate))
        let drained: (timings: [AudioTapTiming], valid: Int, invalid: Int) = meter?.drainTapTimings() ?? ([], 0, 0)
        tapLead.add(drained.timings, clock: clock)
        var onsets: [Double] = []
        if visualSettings.usesAudioAnchor {
            onsets = onsetDetector.onsets(since: avLoggedItem).filter { $0 > avLoggedItem }
            if let last = onsets.last { avLoggedItem = last }
        }
        let fields = AVDebugColumns.f0Fields(onsets: onsets, bands: beatBands, tapLead: tapLead.lead,
                                             tapValid: drained.valid, tapInvalid: drained.invalid, clock: clock)
        beatBands = AudioBandSummary()
        return fields
    }

    /// rhythm-phase P2：相位从头锁、脉动停掉（下一个完整拍按 P1 出口规则继续）
    private func resetPulse() {
        phaseLock.reset()
        pulse.reset()
        if pulseStatus != nil { pulseStatus = nil }
        resetAnchor()
    }

    /// rhythm-context P3：每个完整拍取走撞击声频带 → 撞击时刻（视频时间 → host 时间）→ 和相位锁比 → 脉动相位偏移。
    /// 没开 / 没锁 / 声音节奏和画面对不上 / 倍速读不出 → 偏移回 0（= P2）
    private func updateAudioAnchor(_ p: AVPlayer, dt: TimeInterval) {
        guard visualSettings.usesAudioAnchor, let m = meter else {
            if pulse.phaseOffset != 0 || anchorStatus != nil { resetAnchor() }
            return
        }
        // av-fusion F1：融合开着时这一拍新出的块也给融合；之前融合先取走的块原样接在前面（关着时 backlog 一直是空的）
        let fresh = m.drainBands()
        if visualSettings.usesAVFusion, fusionFeaturesWanted { fusion.addBands(fresh) }
        let drained = bandBacklog.take(adding: fresh)
        for band in drained { onsetDetector.add(band) }
        // av-fusion F0：调试记录开着时顺便汇总这一拍的频带块（只读；撞击检测照旧吃同一份）
        if debugRecording { beatBands.add(drained) }
        let now = CACurrentMediaTime()
        let rate = Double(p.rate)
        let itemNow = p.currentTime().seconds
        guard rate.isFinite, rate > 0.01, itemNow.isFinite else {
            audioAnchor.reset()
            pulse.phaseOffset = 0
            return
        }
        let since = itemNow - (AudioPhaseAnchor.windowSeconds + 0.5) * rate
        let onsets = onsetDetector.onsets(since: since).map { now + ($0 - itemNow) / rate }
        // 声音节奏按视频时间算，画面频率是 host 时间上看到的快慢：乘倍速再比
        let r = onsetDetector.rhythm()
        let known = visualSettings.usesRhythmContext && actionContext.directionKnown
        // av-fusion F2：节奏确认开着时还要声画耦合（这一拍的融合状态；像配乐 / 人声 / 还没证明同步就不对齐）；关着时 nil = P3 原样
        let coupled: Bool? = visualSettings.usesAVRhythmConfirm ? fusionBeat?.state == .coupled : nil
        pulse.phaseOffset = audioAnchor.step(onsets: onsets, audioHz: r.hz * rate, audioConfidence: r.confidence,
                                             lock: phaseLock, directionKnown: known, now: now, dt: dt, coupled: coupled)
        let text = audioAnchor.statusText(lockHz: phaseLock.hz)
        if text != anchorStatus { anchorStatus = text }
    }

    /// av-fusion F1：融合从头来（开关 / 换视频 / seek / 画面侧重置），状态行消失。backlog 不清（那是撞击声校正的输入）
    private func resetFusion() {
        fusion.reset()
        fusionBeat = nil
        if fusionStatus != nil { fusionStatus = nil }
        resetVote()
    }

    /// av-fusion F2：投票从头来（下一拍按当时的融合状态重新判断；不耦合 = 窗口原样）
    private func resetVote() {
        rhythmVote.reset()
        if voteStatus != nil { voteStatus = nil }
    }

    /// av-fusion F2：这一拍的投票（P4 前瞻之后、P3 动作识别之前）。S2 = 上一拍融合状态是耦合（时间可用、声音在场、没在切镜考验）；
    /// 跟随器的频率 / 锁定是上一拍的。不在 S2 时窗口原样交回
    private func refineVote(_ window: MotionWindow, player p: AVPlayer) -> MotionWindow {
        let clock = MediaClockSnapshot(host: CACurrentMediaTime(), item: p.currentTime().seconds, rate: Double(p.rate))
        let out = rhythmVote.refine(window, enabled: true, coupled: fusionBeat?.state == .coupled,
                                    events: fusion.extractor.events, impactHz: fusionBeat?.fa ?? 0, clock: clock,
                                    followerHz: rhythm.hz, followerLocked: rhythm.locked)
        let text = rhythmVote.statusText
        if text != voteStatus { voteStatus = text }
        return out
    }

    /// av-fusion F1：每个完整拍一次（跟随画面 + 融合开着才算）：取走频带块（撞击声校正也开着时存进 backlog 留给它）和特征，
    /// 读一次播放器时钟 → 耦合度 / 配乐 / 人声的判断 → 状态行和调试列。只读相位锁和画面强度，不改任何控制状态
    private func updateFusion(_ p: AVPlayer, window: MotionWindow, activity: Double, dt: TimeInterval) {
        guard visualSettings.usesAVFusion, fusionFeaturesWanted, let m = meter else {
            if fusionBeat != nil || fusionStatus != nil { resetFusion() }
            return
        }
        let fresh = m.drainBands()
        if visualSettings.usesAudioAnchor { bandBacklog.keep(fresh) }
        fusion.addBands(fresh)
        fusion.addFeatures(m.drainFeatures())
        let clock = MediaClockSnapshot(host: CACurrentMediaTime(), item: p.currentTime().seconds, rate: Double(p.rate))
        let b = fusion.beat(clock: clock, lock: phaseLock, activity: activity, cut: window.cutCount > 0,
                            audioReady: audioStatus == .ready, dt: dt)
        fusionBeat = b
        let text = b.statusText
        if text != fusionStatus { fusionStatus = text }
    }

    /// rhythm-phase P2 子拍：播放器确实在播、联动开着、跟随画面 + 频率跟随 + 相位脉动都开着，且上一个完整拍在脉动，
    /// 才按相位锁预测的这一刻相位改伸缩（震动 / 通道 3、4 不变），经 outputStage 按时间限速后变化才发。
    /// 其余任何情况都不发：暂停 / 缓冲 / seek / 播完 / 停止由下一个完整拍（≤ 0.3 秒）照旧处理
    private func pulseSubTick(_ p: AVPlayer, ble: BLEManager) {
        guard isPlaying, !isSeeking, settings.enabled, visualSettings.usesPulseTiming,
              p.timeControlStatus == .playing,
              let vals = pulse.subBeat(lock: phaseLock, settings: settings, now: CACurrentMediaTime(),
                                       stage: &outputStage) else { return }
        let shown = vals.max() ?? 0
        if shown != intensity { intensity = shown }
        let active = ActiveChannels(values: vals)
        if needsResync || active != lastActive {
            needsResync = false
            lastActive = active
            // 同完整拍：只走不开闸的 sendTick
            ble.sendTick(levels: vals)
        }
    }

    /// rhythm-follow P1：这一拍的节奏档位（没打开 / 没锁定 / 没有新鲜画面时 nil = 伸缩照旧按动作强度）。
    /// activity：画面自己的强度能让节奏用几成（RhythmOutput.motionActivity）；0 = 画面没在动，当拍不加伸缩，
    /// 跟随器连续 2 拍（有帧）不动才解锁（这一拍一帧都没分析到不算，r3 复审 L1）。
    /// 频率按画面帧的显示时刻（host 时间轴）算，倍速播放时已经是实际看到的快慢，不再乘倍速
    private func rhythmLevel(_ window: MotionWindow, motionSignal: Bool, activity: Double, dt: TimeInterval) -> Int? {
        guard visualSettings.rhythmFollow else {
            if rhythmStatus != nil { resetRhythm() }
            return nil
        }
        // P3：动作识别开着时，跟随器 / 相位锁吃按动作改写过的窗口副本（未知 = 原窗口）；关着时就是原窗口（= P2）
        var input = window
        // P4：前瞻开着才换成没有检测延迟的读数（核对没通过 / 读不到 / 停着 = 原样）；关着时 input 就是原窗口
        if visualSettings.usesLookahead, motionSignal, let reader = lookaheadReader, let p = player {
            input = refineLookahead(window, reader: reader, player: p)
        } else if lookaheadBeat != nil || lookaheadStatus != nil {
            resetLookahead()
        }
        // av-fusion F2：节奏由声音确认开着才投票（P4 之后、P3 之前；不耦合 = 原样）；关着时 input / fastJump 和以前逐位相同
        var fastJump = false
        if visualSettings.usesAVRhythmConfirm, motionSignal, let p = player {
            input = refineVote(input, player: p)
            fastJump = rhythmVote.fastJump
        } else if rhythmVote.active || voteStatus != nil {
            resetVote()
        }
        if visualSettings.usesRhythmContext, motionSignal {
            // rhythm-action tune：跟随器上一拍牢牢锁着的频率（轻抚判断：锁在别的往复上就不算轻抚）
            let lockHz = ActionContext.lockedHz(locked: rhythm.locked, weight: rhythm.weight, hz: rhythm.hz)
            input = actionContext.refine(input, now: CACurrentMediaTime(), followerHz: lockHz)
            let text = actionContext.statusText()
            if text != contextStatus { contextStatus = text }
        } else if contextStatus != nil {
            resetContext()
        }
        // rhythm-action tune：认出轻抚 / 摸自己时当成「画面不在往复」（跟随器 / 相位锁不锁、已锁的按不动放开）
        let moving = activity > 0 && !(visualSettings.usesRhythmContext && actionContext.suppressesRhythm)
        if motionSignal { rhythm.step(input, dt: dt, active: moving, fastJump: fastJump) } else { rhythm.reset() }
        if visualSettings.rhythmPulse {
            // P2：相位锁跟在频率跟随器后面（跟随器没锁 / 镜头切换 / 不动 2 拍 → 相位锁立刻放开）
            if motionSignal {
                phaseLock.step(input, followerHz: rhythm.hz, followerLocked: rhythm.locked,
                               followerSource: rhythm.source, now: CACurrentMediaTime(), dt: dt, active: moving)
            } else {
                phaseLock.reset()
            }
        }
        return rhythm.weight > 0 && rhythm.hz > 0 ? visualSettings.rateMap.level(forHz: rhythm.hz) : nil
    }

    /// 界面上的一行节奏状态（thrust：这一拍伸缩实际发出 / 预览的档位；变化才刷新）
    private func updateRhythmStatus(rateLevel: Int?, activity: Double, thrust: Int, value: Double, hasSignal: Bool) {
        let text = RhythmOutput.statusText(hz: rhythm.hz, weight: rhythm.weight, locked: rhythm.locked,
                                           rateLevel: rateLevel, activity: activity, thrust: thrust,
                                           value: value, hasSignal: hasSignal,
                                           map: visualSettings.rateMap,
                                           calibrated: visualSettings.calibratedRateMap != nil, settings: settings)
        if text != rhythmStatus { rhythmStatus = text }
    }

    /// 跟随画面的一拍：画面窗口 → 自适应归一化 → 门 / 平滑 → 出口（最低强度 / 上限 / 升幅限速 / 归零保持 / 夹紧）
    /// → 变化才发。最低强度只在分析在跑、播放器确实在播、最近 1 秒有画面样本时生效；没有新鲜画面就是 0
    private func motionTick(_ p: AVPlayer, ble: BLEManager, t: Double, now: TimeInterval, dt: TimeInterval) {
        let window = motionMeter?.drain() ?? .empty
        motionFlow.note(window, now: now)
        // P4 预扫描：扫完了、这个视频还没学过时用全片分位数当参考值起点（只试一次；关着时不走）
        if visualSettings.usesPrescan, !prescanTried, let s = prescanSummary {
            prescanTried = true
            prescanSeeded = motionNormalizer.seed(s)
            refreshPrescanStatus()
        }
        // rhythm-action tune（动作识别开着才生效；关着时这几行和以前逐位相同）：慢 / 轻动作按绝对刻度压低、
        // 姿态不能比画面本身的运动高太多；认出轻抚 / 摸自己时强度最多到 ActionContext.caressCeiling（上一拍的判断，只降不升）
        let tuned = visualSettings.usesRhythmContext
        motionNormalizer.actionTuned = tuned
        // 慢 / 轻动作的压低只给轻抚 / 还没认出动作且没锁节奏的（上一拍的判断；关着时不看）
        if tuned { motionNormalizer.gentleAllowed = actionContext.allowsGentle(followerLocked: rhythm.locked) }
        var target = motionNormalizer.step(window, gainDb: visualSettings.motionGainDb,
                                           auto: visualSettings.autoMotion, dt: dt)
        if tuned, let ceiling = actionContext.intensityCeiling { target = min(target, ceiling) }
        // P4 预扫描（复审 M1）：这一拍开始学了，预扫描的结果这次用不上，停掉那一路解码（前瞻开着时照常读；关着时不走）
        if readerPrescan, !prescanWanted { updateLookaheadReader() }
        let shaped = motionShaper.step(target: target, dt: dt)
        motionLevel = shaped.level
        let poseAssist = motionNormalizer.poseWeight >= 0.2
        if poseAssist != motionPoseAssist { motionPoseAssist = poseAssist }
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
        // 节奏只认画面自己的新鲜样本和画面自己的强度（交接期间声音补的那部分没有频率，也不算「在动」）；
        // 下降跟门前的即时强度走（r2 复审 M1）：动作一停节奏马上不加伸缩，不等 0.7 秒释放平滑
        let motionActivity = RhythmOutput.motionActivity(level: shaped.level, smoothed: shaped.smoothed,
                                                         confidence: motionNormalizer.confidence,
                                                         motionSignal: motionSignal)
        let rateLevel = rhythmLevel(window, motionSignal: motionSignal, activity: motionActivity, dt: dt)
        // rhythm-action tune：认出轻抚时这一拍伸缩不跟节奏（activity 当 0；关着时就是 motionActivity）
        let rhythmActivity = tuned && actionContext.suppressesRhythm ? 0 : motionActivity
        // av-fusion F1：只显示（关着时什么都不做）
        updateFusion(p, window: window, activity: rhythmActivity, dt: dt)
        guard settings.enabled else {
            // 联动关着：不发、升幅基准留在 0；强度条只预览打开后会是多少
            outputStage.reset()
            handover.cancel()
            if visualSettings.rhythmFollow {
                let levels = RhythmOutput.target(value: value, settings: settings, hasSignal: hasSignal,
                                                 rateLevel: rateLevel, weight: rhythm.weight, activity: rhythmActivity)
                intensity = min(SyncOutputStage.hardCap(settings), levels.max() ?? 0)
                updateRhythmStatus(rateLevel: rateLevel, activity: rhythmActivity, thrust: levels[0],
                                   value: value, hasSignal: hasSignal)
            } else {
                intensity = SyncOutputStage.preview(value, settings: settings, hasSignal: hasSignal)
            }
            return
        }
        let vals: [Int]
        if visualSettings.rhythmFollow {
            // 伸缩按动作频率（weight × 画面强度交接），震动照旧；同一个出口：上限 / 升幅 ≤ +20 / 归零保持
            let levels = RhythmOutput.target(value: value, settings: settings, hasSignal: hasSignal,
                                             rateLevel: rateLevel, weight: rhythm.weight, activity: rhythmActivity)
            if visualSettings.rhythmPulse {
                // P4：上一拍加的前瞻提前量先撤掉（没加过时原样），撞击声校正照旧按自己的值算。
                // 防御性：updateAudioAnchor 现在每拍都整个改写 phaseOffset，撤不撤结果一样（见 LookaheadCoordinator.removeLead）
                pulse.phaseOffset = lookahead.removeLead(from: pulse.phaseOffset)
                // P3：撞击声校正（开着才有）只调脉动相位，有界、对不上就回 0
                updateAudioAnchor(p, dt: dt)
                // P4：这一拍用了前瞻才加提前量（±60°，每秒最多变 90°，总偏移 ±90°；相位锁不用时立刻 0）
                if let b = lookaheadBeat, visualSettings.usesLookahead {
                    pulse.phaseOffset = lookahead.applyLead(to: pulse.phaseOffset, enabled: true, timeline: b.timeline,
                                                            clock: b.clock, latency: b.latency, lock: phaseLock, dt: dt)
                }
                // P2：锁上相位才在 P1 档位上叠加脉动（往里时加强）；没锁 / 没标定 / 太快 / 太弱 = P1 原样
                vals = pulse.beat(levels: levels, lock: phaseLock, visual: visualSettings, settings: settings,
                                  hasSignal: hasSignal, value: value, activity: rhythmActivity,
                                  followerWeight: rhythm.weight, now: CACurrentMediaTime(), stage: &outputStage)
                let text = pulse.statusText(lock: phaseLock, visual: visualSettings)
                if text != pulseStatus { pulseStatus = text }
            } else {
                vals = outputStage.step(levels: levels, settings: settings, now: CACurrentMediaTime(), timed: false)
            }
            updateRhythmStatus(rateLevel: rateLevel, activity: rhythmActivity, thrust: vals[0],
                               value: value, hasSignal: hasSignal)
        } else {
            vals = outputStage.step(value, settings: settings, hasSignal: hasSignal, now: CACurrentMediaTime())
        }
        let shown = vals.max() ?? 0
        intensity = shown
        if debugRecording {
            debugLog.append(t: t, window: window, normalizer: motionNormalizer, target: target,
                            shapedLevel: shaped.level, value: value, hasSignal: hasSignal,
                            kind: actionContext.kind.rawValue, context: contextStatus,
                            rhythmHz: rhythm.hz, rhythmWeight: rhythm.weight, rhythmLocked: rhythm.locked,
                            activity: rhythmActivity, rateLevel: rateLevel, out: vals,
                            av: avDebugFields(p) + (fusionBeat.map(AVDebugColumns.f1Fields) ?? AVDebugColumns.f1Empty)
                                + (rhythmVote.active ? AVDebugColumns.f2Fields(rhythmVote) : AVDebugColumns.f2Empty))
        }
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
    /// 相册选择器（PHPicker，只列视频，不需要相册权限）
    @State private var showPhotoPicker = false
    /// 选来源：相册 / 文件
    @State private var showSourceChoice = false
    /// 相册视频正在拷出来（iCloud 视频可能要下载一会儿）：期间选视频的入口都不可用，素材卡片上显示进度和取消
    @State private var photoImporting = false
    /// 正在拷的那次的进度（取消 = 换视频 / 离开页面 / 点取消）
    @State private var photoProgress: Progress?
    /// 相册导入的代数：每次开始 / 取消 +1，回调带着发起时的代数，不一样就不认（拷出来的文件删掉）
    @State private var photoImportGen = 0
    /// 调试记录（默认关，只记数字）
    @AppStorage("bcMotionDebugLog") private var debugLogOn = false
    @State private var debugExportURL: URL?
    @State private var debugRows = 0
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
    // rhythm-follow P1：伸缩跟随动作频率（默认关）+ 设备档位→每秒往复次数标定表（docs/rhythm-calibration.md）
    @AppStorage(VisualSyncSettings.Keys.rhythmFollow) private var rhythmFollow = VisualSyncSettings.defaultRhythmFollow
    @AppStorage(VisualSyncSettings.Keys.rateTable) private var rateTable = VisualSyncSettings.defaultRateTable
    // rhythm-phase P2：相位脉动（实验，默认关）+ 深度 / 延迟补偿 / 方向反转（真机标定见 docs/rhythm-calibration.md）
    @AppStorage(VisualSyncSettings.Keys.rhythmPulse) private var rhythmPulse = VisualSyncSettings.defaultRhythmPulse
    @AppStorage(VisualSyncSettings.Keys.pulseDepth) private var pulseDepth = VisualSyncSettings.defaultPulseDepth
    @AppStorage(VisualSyncSettings.Keys.pulseLatencyMs) private var pulseLatencyMs = VisualSyncSettings.defaultPulseLatencyMs
    @AppStorage(VisualSyncSettings.Keys.pulseInvert) private var pulseInvert = VisualSyncSettings.defaultPulseInvert
    // rhythm-context P3：动作识别（手 / 头 / 髋 + 周期区域）/ 撞击声相位校正（实验，默认都关）
    @AppStorage(VisualSyncSettings.Keys.rhythmContext) private var rhythmContext = VisualSyncSettings.defaultRhythmContext
    @AppStorage(VisualSyncSettings.Keys.rhythmAudioAnchor) private var rhythmAudioAnchor = VisualSyncSettings.defaultRhythmAudioAnchor
    // rhythm-lookahead P4：前瞻（提前读后面的画面）/ 预扫描整段视频（实验，默认都关）
    @AppStorage(VisualSyncSettings.Keys.rhythmLookahead) private var rhythmLookahead = VisualSyncSettings.defaultRhythmLookahead
    @AppStorage(VisualSyncSettings.Keys.prescan) private var prescan = VisualSyncSettings.defaultPrescan
    // av-fusion F1：声画融合（实验，默认关；只显示「声画：」状态行，不改输出）
    @AppStorage(VisualSyncSettings.Keys.avFusion) private var avFusion = VisualSyncSettings.defaultAVFusion
    // av-fusion F2：节奏由声音确认（实验，默认关；融合 + 伸缩跟随动作频率都开着才显示）
    @AppStorage(VisualSyncSettings.Keys.avRhythmConfirm) private var avRhythmConfirm = VisualSyncSettings.defaultAVRhythmConfirm
    /// 标定表的编辑稿：按「完成」/ 收起键盘 / 输入框消失时才写回 rateTable（播放中不按半截的表出档位）
    @State private var rateTableDraft = VisualSyncSettings.defaultRateTable
    @FocusState private var rateTableFocused: Bool

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
        VisualSyncSettings(source: visualSource, motionGainDb: motionGainDb, autoMotion: autoMotion,
                           rhythmFollow: rhythmFollow, rateTable: rateTable, rhythmPulse: rhythmPulse,
                           pulseDepth: pulseDepth, pulseLatencyMs: pulseLatencyMs, pulseInvert: pulseInvert,
                           rhythmContext: rhythmContext, rhythmAudioAnchor: rhythmAudioAnchor,
                           rhythmLookahead: rhythmLookahead, prescan: prescan, avFusion: avFusion,
                           avRhythmConfirm: avRhythmConfirm)
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
        // 相册视频还在导入：先取消导入（素材卡片上的取消键）才能再选
        guard !photoImporting else { return }
        guard !pickerBlocked else {
            Haptics.warning()
            UIAccessibility.post(notification: .announcement, argument: pickerBlockedMessage)
            if !blockedReasonShown { flashPickerNotice() }
            return
        }
        vm.stopBeforePicker()
        showSourceChoice = true
    }

    /// 相册里选中了一个（主线程）：开始拷贝，记下进度和代数
    private func startPhotoImport(_ provider: NSItemProvider) {
        cancelPhotoImport()
        let gen = photoImportGen
        let progress = PhotoVideoPicker.copyVideo(from: provider) { url in
            finishPhotoImport(url, gen: gen)
        }
        guard let progress else {
            loadPhotoVideo(nil)
            return
        }
        photoProgress = progress
        photoImporting = true
        vm.statusLine = "正在从相册导入视频…"
    }

    /// 拷贝回调（主线程）：过期的（取消过 / 又开始了新的）不认，拷出来的文件删掉
    private func finishPhotoImport(_ url: URL?, gen: Int) {
        guard gen == photoImportGen else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        photoImportGen += 1
        photoProgress = nil
        photoImporting = false
        loadPhotoVideo(url)
    }

    /// 取消正在进行的相册导入（换视频 / 离开页面 / 点取消；没在导入时只让代数 +1）
    private func cancelPhotoImport() {
        photoImportGen += 1
        photoProgress?.cancel()
        photoProgress = nil
        if photoImporting {
            photoImporting = false
            vm.statusLine = "已取消相册导入"
        }
    }

    /// 相册视频拷出来之后（主线程）：和文件选择器同一条 loadVideo
    private func loadPhotoVideo(_ url: URL?) {
        guard let url else {
            vm.videoName = "导入失败：相册视频"
            vm.statusLine = "相册视频无法读取（iCloud 视频请先在相册里下载），请重新选择"
            return
        }
        vm.loadVideo(url: url)
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
            vm.debugRecording = debugLogOn
        }
        .onChange(of: debugLogOn) { on in
            vm.debugRecording = on
            if !on { vm.debugLog.clear(); debugRows = 0 }
        }
        // 分享面板同其它弹出层：先停（导出键里），底部带停止条，挂隐私遮挡
        .sheet(isPresented: Binding(get: { debugExportURL != nil }, set: { if !$0 { debugExportURL = nil } })) {
            VStack(spacing: 0) {
                if let url = debugExportURL { ActivityShareSheet(items: [url]) }
                pickerStopBar
            }
            .privacyCover()
            .environmentObject(privacy)
            .environmentObject(ble)
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
                    // 换成文件里的视频：还在拷的相册视频作废
                    cancelPhotoImport()
                    vm.loadVideo(url: url)
                }
                pickerStopBar
            }
            .privacyCover()
            .environmentObject(privacy)
            .environmentObject(ble)
        }
        // 选来源：相册 / 文件
        .confirmationDialog("选择视频来源", isPresented: $showSourceChoice, titleVisibility: .visible) {
            Button("从相册选择") { if !pickerBlocked { showPhotoPicker = true } }
            Button("从文件选择") { if !pickerBlocked { showPicker = true } }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPhotoPicker) {
            VStack(spacing: 0) {
                PhotoVideoPicker(onCancel: { showPhotoPicker = false }) { provider in
                    showPhotoPicker = false
                    startPhotoImport(provider)
                }
                pickerStopBar
            }
            .privacyCover()
            .environmentObject(privacy)
            .environmentObject(ble)
        }
        // 系统全屏弹出时部分系统版本也会触发 onDisappear：全屏中不停机
        .onDisappear {
            if !systemFullScreen {
                vm.stopAll()
                cancelPhotoImport()
            }
        }
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
            // 不用 disabled：变灰会把原因那行字一起压暗。点了由 openPicker 拦下（震动 + 旁白说明）。
            // 相册视频导入中才禁用（进度在素材卡片上）
            .disabled(photoImporting)
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
                if vm.motionPoseAssist {
                    Text("已识别人体姿态，按动作幅度和节奏跟随")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if rhythmFollow, let rhythm = vm.rhythmStatus {
                    Text(rhythm)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rhythmFollow, rhythmPulse, let pulse = vm.pulseStatus {
                    Text(pulse)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rhythmFollow, rhythmContext, let context = vm.contextStatus {
                    Text(context)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rhythmFollow, rhythmPulse, rhythmAudioAnchor, let anchor = vm.anchorStatus {
                    Text(anchor)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if rhythmFollow, rhythmLookahead, let look = vm.lookaheadStatus {
                    Text(look)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if autoMotion, prescan, let scan = vm.prescanStatus {
                    Text(scan)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if avFusion, let fusion = vm.fusionStatus {
                    Text(fusion)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if avFusion, rhythmFollow, avRhythmConfirm, let vote = vm.voteStatus {
                    Text(vote)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                if autoMotion { prescanControls }
                rhythmControls
                fusionControls
                debugLogControls
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

    /// av-fusion F1：声画融合（实验，默认关；只在跟随画面时显示）。只显示「声画：」状态行，不改输出
    @ViewBuilder private var fusionControls: some View {
        Toggle(isOn: $avFusion) {
            VStack(alignment: .leading, spacing: 2) {
                Text("声画融合（实验）")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("同时听视频的声音，判断撞击声是不是跟画面同步（还是配乐 / 人声），只显示「声画：」状态行，不改输出；判断耦合要同时开「伸缩跟随动作频率」和「相位脉动」")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Velvet.gold)
        if avFusion, rhythmFollow {
            Toggle(isOn: $avRhythmConfirm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("节奏由声音确认（实验）")
                        .font(.subheadline)
                        .foregroundColor(Velvet.text)
                    Text("声画耦合时用撞击声确认画面的往复快慢：一致时更快锁上、读成一半 / 两倍时改正、跳频更早跟上；配乐 / 人声 / 画面不动时不起作用，频率仍以画面为准")
                        .font(.caption2)
                        .foregroundColor(Velvet.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Velvet.gold)
        }
    }

    /// 调试记录：画面联动每一拍的数字（运动量、归一化、动作类型、节奏、输出）存成表格导出；不存画面
    @ViewBuilder private var debugLogControls: some View {
        Toggle(isOn: $debugLogOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("调试记录")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("播放时把每一拍的运动量、识别结果和输出强度记成表格（只有数字，没有画面），最多约 30 分钟")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Velvet.gold)
        if debugLogOn {
            HStack {
                Button("导出表格") {
                    vm.stopBeforeExport()
                    debugRows = vm.debugLog.count
                    debugExportURL = vm.debugLog.writeCSV()
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("清空", role: .destructive) {
                    vm.debugLog.clear()
                    debugRows = 0
                }
                .buttonStyle(.borderless)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
    }

    /// rhythm-follow P1：伸缩跟随动作频率 + 标定表（只在跟随画面时显示）
    @ViewBuilder private var rhythmControls: some View {
        Toggle(isOn: $rhythmFollow) {
            VStack(alignment: .leading, spacing: 2) {
                Text("伸缩跟随动作频率")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("画面里动作每秒几下，设备也尽量每秒几下（只跟快慢，不对进出的时机）；震动照旧跟动作强度")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
            }
        }
        .tint(Velvet.gold)
        if rhythmFollow {
            VStack(alignment: .leading, spacing: 6) {
                Text("设备标定表（档位:每秒往复次数）")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                // 编辑稿：打字过程中半截的表（如「…, 99:2」）不生效，按「完成」/ 收起键盘 / 输入框消失时才写回
                TextField("例 20:0.6, 60:1.8, 99:2.8", text: $rateTableDraft)
                    .font(.caption.monospacedDigit())
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundColor(Velvet.text)
                    .submitLabel(.done)
                    .focused($rateTableFocused)
                    .onSubmit { commitRateTable() }
                    .onChange(of: rateTableFocused) { focused in
                        if !focused { commitRateTable() }
                    }
                    .onChange(of: rateTable) { stored in
                        if !rateTableFocused { rateTableDraft = stored }
                    }
                    .onAppear { rateTableDraft = rateTable }
                    .onDisappear { commitRateTable() }
                    .frame(minHeight: 44)
                    .accessibilityLabel("设备标定表")
                Text(rateTableHint)
                    .font(.caption2)
                    .foregroundColor(rateTableIsBad ? Velvet.warning : Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            contextControls
            lookaheadControls
            pulseControls
        }
    }

    /// rhythm-lookahead P4：预扫描（实验，默认关；只在自动适应画面打开时显示）
    @ViewBuilder private var prescanControls: some View {
        Toggle(isOn: $prescan) {
            VStack(alignment: .leading, spacing: 2) {
                Text("预扫描整段视频（实验）")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("选好视频后在后台先把整段画面看一遍，开播时直接按这个视频的动作范围起步（开头 3 秒照旧慢慢升）。"
                     + "另开一路解码、更耗电；关掉开关随时停，手机发热 / 切到后台时自动暂停")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Velvet.gold)
        .accessibilityValue(prescan ? "开" : "关")
    }

    /// rhythm-lookahead P4：前瞻（实验，默认关；只在频率跟随打开时显示）
    @ViewBuilder private var lookaheadControls: some View {
        Toggle(isOn: $rhythmLookahead) {
            VStack(alignment: .leading, spacing: 2) {
                Text("前瞻（实验）")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("另开一路解码提前读后面 3 秒的画面：频率和相位不用等检测延迟，脉动时机按画面实际会走的相位修正（最多 ±60°）。"
                     + "要先标定；和实时画面核对不上、手机发热、切到后台时自动只用实时。更耗电")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Velvet.gold)
        .accessibilityValue(rhythmLookahead ? "开" : "关")
    }

    /// rhythm-context P3：动作识别（实验，默认关；只在频率跟随打开时显示）
    @ViewBuilder private var contextControls: some View {
        Toggle(isOn: $rhythmContext) {
            VStack(alignment: .leading, spacing: 2) {
                Text("动作识别（实验）")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("另外认手、脸、髋部和画面里一直在往复的那块区域，判断是插入 / 口 / 手的动作，只按真正在做的那个部位跟频率和相位。"
                     + "认不出时和不开一样；更耗电，手机发热时自动不认姿态")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Velvet.gold)
    }

    private var pulseDepthText: String { "\(Int(pulseDepth.rounded())) 档" }
    private var pulseLatencyText: String { "\(Int(pulseLatencyMs.rounded())) ms" }

    /// rhythm-phase P2：相位脉动（实验，默认关；只在频率跟随打开时显示）
    @ViewBuilder private var pulseControls: some View {
        Toggle(isOn: $rhythmPulse) {
            VStack(alignment: .leading, spacing: 2) {
                Text("相位脉动（实验）")
                    .font(.subheadline)
                    .foregroundColor(Velvet.text)
                Text("对上画面往复的时机后，画面往里时伸缩加强、往外时减弱。开环预测，设备没有位置反馈；"
                     + "需要先标定，没标定 / 没对上 / 动作太快（每秒 2.5 下以上）时只跟频率")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Velvet.gold)
        if rhythmPulse {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("脉动深度（峰谷差）")
                        .font(.subheadline)
                        .foregroundColor(Velvet.text)
                    Spacer()
                    Text(pulseDepthText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Velvet.textSecondary)
                }
                Slider(value: $pulseDepth, in: VisualSyncSettings.pulseDepthRange, step: 5)
                    .tint(Velvet.rose)
                    .accessibilityLabel("脉动深度")
                    .accessibilityValue(pulseDepthText)
                HStack {
                    Text("延迟补偿")
                        .font(.subheadline)
                        .foregroundColor(Velvet.text)
                    Spacer()
                    Text(pulseLatencyText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Velvet.textSecondary)
                }
                Slider(value: $pulseLatencyMs, in: VisualSyncSettings.pulseLatencyRange, step: 20)
                    .tint(Velvet.rose)
                    .accessibilityLabel("延迟补偿")
                    .accessibilityValue(pulseLatencyText)
                Text("设备总比画面晚就往大调，总比画面早就往小调（按标定文档用慢动作视频对一次）")
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $pulseInvert) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("方向反转")
                            .font(.subheadline)
                            .foregroundColor(Velvet.text)
                        Text("画面往里时设备反而在减弱就打开")
                            .font(.caption2)
                            .foregroundColor(Velvet.textMuted)
                    }
                }
                .tint(Velvet.gold)
                Toggle(isOn: $rhythmAudioAnchor) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("撞击声相位校正（实验）")
                            .font(.subheadline)
                            .foregroundColor(Velvet.text)
                        Text("视频里有和画面同节奏的拍打 / 撞击声时，用声音的时刻微调脉动时机（认出动作方向时最多 ±60°）。"
                             + "声音节奏和画面对不上（背景音乐、说话）就不用")
                            .font(.caption2)
                            .foregroundColor(Velvet.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Velvet.gold)
            }
        }
    }

    /// 编辑稿写回存储（只有这里改 rateTable；VideoSyncPlayer 经 onChange(of: visualSettings) 下一拍用新表）
    private func commitRateTable() {
        if rateTableDraft != rateTable { rateTable = rateTableDraft }
    }

    private var rateTableIsBad: Bool {
        !rateTableDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && DeviceRateMap.parse(rateTableDraft) == nil
    }

    /// 提示按编辑稿算（打字时就能看到格式对不对）；还没写回时注明
    private var rateTableHint: String {
        let pending = rateTableDraft != rateTable ? "（按「完成」或收起键盘后生效）" : ""
        if let map = DeviceRateMap.parse(rateTableDraft) {
            return String(format: "已标定：%d~%d 档 ≈ 每秒 %.1f~%.1f 次", map.minLevel, map.maxLevel, map.minHz, map.maxHz)
                + pending
        }
        let guess = DeviceRateMap.uncalibrated
        let head = rateTableIsBad ? "格式不对（2~12 组「档位:次数」，档位和次数都要递增），先按" : "还没标定，先按"
        return head + String(format: "估计值 %d 档 %.1f 次 ~ %d 档 %.1f 次；在手动页每档跑 10 秒数一下每秒几次再填",
                              guess.minLevel, guess.minHz, guess.maxLevel, guess.maxHz) + pending
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
                          hint: "选择视频", enabled: !photoImporting) { openPicker() }
        }
    }

    /// 素材
    private var materials: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "素材", systemImage: "film.stack")
            // 被拦下的原因常驻写在本卡片底部（blockedReasonShown）：点这一行时不再往停止键上钉第二份
            materialRow(icon: "film", title: "视频", value: vm.videoName, action: "选择",
                        enabled: !photoImporting) {
                openPicker(blockedReasonShown: vm.player != nil)
            }
            if photoImporting {
                // 相册视频导入中（iCloud 视频可能要先下载）：进度 + 取消
                HStack(spacing: 10) {
                    if let progress = photoProgress {
                        ProgressView(progress)
                            .tint(Velvet.gold)
                    } else {
                        ProgressView()
                    }
                    Button("取消导入", role: .cancel) { cancelPhotoImport() }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("正在从相册导入视频")
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

    private func materialRow(icon: String, title: String, value: String, action: String, enabled: Bool = true,
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
                .disabled(!enabled)
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

/// 系统相册选择器（PHPicker：只列视频、不需要相册权限）。选中后只把 NSItemProvider 交出去（主线程），
/// 拷贝由页面用 copyVideo 发起：页面持有 Progress（换视频 / 离开页面时取消）和代数（过期的回调不认）。
struct PhotoVideoPicker: UIViewControllerRepresentable {
    var onCancel: () -> Void = {}
    /// 选中了一个（主线程）
    let onPick: (NSItemProvider) -> Void

    /// 相册视频拷出来的临时目录（loadVideo 再移进 SyncVideos；启动时清掉上次留下的）
    static var importDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhotoImports", isDirectory: true)
    }

    static func purgeImports() {
        try? FileManager.default.removeItem(at: importDirectory)
    }

    /// loadFileRepresentation 给的临时文件在回调返回后就删，所以在回调里（后台）同步拷到 importDirectory；
    /// 拷失败删掉半截文件。completion 回主线程，nil = 读不出来 / 被取消。没有视频类型时返回 nil、不回调
    static func copyVideo(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) -> Progress? {
        let types = [UTType.movie, UTType.video, UTType.mpeg4Movie, UTType.quickTimeMovie]
        guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return nil
        }
        let dir = importDirectory
        return provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
            var copied: URL?
            if let url {
                let fm = FileManager.default
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let dest = dir.appendingPathComponent("相册视频-" + String(UUID().uuidString.prefix(8)) + "." + ext)
                do {
                    try fm.copyItem(at: url, to: dest)
                    copied = dest
                } catch {
                    try? fm.removeItem(at: dest)
                }
            }
            DispatchQueue.main.async { completion(copied) }
        }
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (NSItemProvider) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (NSItemProvider) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                onCancel()
                return
            }
            onPick(provider)
        }
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


/// 画面联动调试记录：每一拍一行数字，环形缓冲（最多 maxRows 行），只在主线程用。不存画面，不参与控制
final class MotionDebugLog {
    static let maxRows = 6000
    static let header = "video_t,host_t,frames,mean_energy,peak_energy,coverage,near_field,cut_count,"
        + "subject_score,subject_hz,pose_frames,pose_present,pose_score,pose_conf,pose_trust,"
        + "pose_rhythm_hz,pose_rhythm_conf,pose_rhythm_part,subject_follow_hz,roi_valid,roi_x0,roi_y0,roi_x1,roi_y1,roi_hz,roi_share,"
        + "ref_low,ref_high,norm_conf,pose_weight,target,shaped_level,value,has_signal,action_kind,context,"
        + "rhythm_hz,rhythm_weight,rhythm_locked,activity,rate_level,out_ch0,out_ch1,"
        + AVDebugColumns.f0Header + "," + AVDebugColumns.f1Header + "," + AVDebugColumns.f2Header
    private var rows: [String] = []
    private var start = 0

    var count: Int { rows.count }

    func clear() {
        rows.removeAll(keepingCapacity: false)
        start = 0
    }

    func append(t: Double, window w: MotionWindow, normalizer n: MotionNormalizer, target: Double,
                shapedLevel: Double, value: Double, hasSignal: Bool, kind: Int, context: String?,
                rhythmHz: Double, rhythmWeight: Double, rhythmLocked: Bool, activity: Double,
                rateLevel: Int?, out: [Int], av: [String] = AVDebugColumns.f0Empty + AVDebugColumns.f1Empty
                    + AVDebugColumns.f2Empty) {
        func f(_ x: Double) -> String { x.isFinite ? String(format: "%.4f", x) : "" }
        let r = w.roi.region
        let ctx = (context ?? "").replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
        let fields: [String] = [
            f(t), f(CACurrentMediaTime()), String(w.frames), f(w.meanEnergy), f(w.peakEnergy), f(w.coverage),
            f(w.nearField), String(w.cutCount), f(w.subjectScore), f(w.subjectHz), String(w.poseFrames),
            String(w.posePresentFrames), f(w.poseScore), f(w.poseConfidence), f(w.poseTrust),
            f(w.poseRhythmHz), f(w.poseRhythmConfidence), String(w.poseRhythmPart), f(w.subjectFollowHz),
            r.valid ? "1" : "0", f(r.x0), f(r.y0), f(r.x1), f(r.y1), f(r.hz), f(r.share),
            f(n.refLow), f(n.refHigh), f(n.confidence), f(n.poseWeight), f(target), f(shapedLevel), f(value),
            hasSignal ? "1" : "0", String(kind), ctx,
            f(rhythmHz), f(rhythmWeight), rhythmLocked ? "1" : "0", f(activity), rateLevel.map(String.init) ?? "",
            String(out.count > 0 ? out[0] : 0), String(out.count > 1 ? out[1] : 0)
        ] + av
        let line = fields.joined(separator: ",")
        if rows.count < Self.maxRows {
            rows.append(line)
        } else {
            rows[start] = line
            start = (start + 1) % Self.maxRows
        }
    }

    /// 导出的表格放这里（每次导出前清掉上一份；启动时也清）
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MotionDebug", isDirectory: true)
    }

    static func purgeExports() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    /// 写到临时目录（先删掉以前导出的），返回文件地址（失败 nil）
    func writeCSV() -> URL? {
        var text = Self.header + "\n"
        for i in 0..<rows.count { text += rows[(start + i) % rows.count] + "\n" }
        let stamp = Int(Date().timeIntervalSince1970)
        let fm = FileManager.default
        Self.purgeExports()
        try? fm.createDirectory(at: Self.exportDirectory, withIntermediateDirectories: true)
        let url = Self.exportDirectory.appendingPathComponent("bluecrystal-motion-\(stamp).csv")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// 系统分享面板（导出调试表格）
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
