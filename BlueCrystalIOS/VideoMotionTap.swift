import Foundation
import AVFoundation
import CoreVideo
import QuartzCore
import os

/// 一个视频的画面运动计：motion 队列上的分析结果写进来，主线程每 0.3 秒取走一次（照 AudioLevelMeter）。
/// 两边只在 os_unfair_lock 里交换几个数。reset() 让代次 +1：分析器下一帧丢掉参考帧（不和跳转前的画面做差），
/// 跨 reset 算出来的样本也写不进新窗口
final class VideoMotionMeter {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var accumulator = MotionWindowAccumulator()
    private var generation = 0

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// 取走上次以来的窗口并清零（主线程）
    func drain() -> MotionWindow {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return accumulator.drain()
    }

    /// 丢掉还没取走的样本，并让分析器丢掉参考帧（开播 / seek / 跳转）
    func reset() {
        os_unfair_lock_lock(lock)
        accumulator = MotionWindowAccumulator()
        generation &+= 1
        os_unfair_lock_unlock(lock)
    }

    fileprivate var currentGeneration: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return generation
    }

    fileprivate func add(_ sample: MotionSample, generation g: Int) {
        os_unfair_lock_lock(lock)
        if g == generation { accumulator.add(sample) }
        os_unfair_lock_unlock(lock)
    }
}

/// 给 AVPlayerItem 挂一个 AVPlayerItemVideoOutput（420f，只读 Y 平面），独立串行队列上 15 Hz 拉帧分析。
/// 只在跟随画面时安装（声音模式零开销）。上一帧还没算完就丢掉这一拍，永远不阻塞主线程；
/// 发热 .serious 降到 8 Hz，.critical 暂停分析。这里不碰 BLE、不判断该不该输出：那全由 VideoSyncPlayer 决定
final class VideoMotionTap {
    enum Status: Equatable {
        case none
        case loading
        case ready
        case noVideo
        case failed(String)
        /// 发热降频（文字是界面提示）
        case degraded(String)
        /// 发热过高，画面分析暂停：不算在分析，最低强度立刻撤（不等新鲜度超时）
        case thermalPaused(String)

        /// 分析器在跑（降频也算）；暂停时有没有新鲜样本由 VM 的 MotionFlowWatch 判断
        var isAnalyzing: Bool {
            switch self {
            case .ready, .degraded: return true
            case .none, .loading, .noVideo, .failed, .thermalPaused: return false
            }
        }
    }

    /// 没有新帧时补零样本的最短间隔（低于分析器 0.5 s 的断档上限）
    static let stillFillInterval: CFTimeInterval = 0.25
    /// 距上一帧真实画面最多补这么久：视频轨比音轨短、空段、解码冻住时，之后照常 1 s 撤最低强度
    static let stillFillLimit: CFTimeInterval = 10

    private static var pixelAttributes: [String: Any] {
        // 两种 420 都接受：多数片源是 video range，只要 full range 会每帧多一次格式转换
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
    }

    private let meter: VideoMotionMeter
    private weak var item: AVPlayerItem?
    private var completion: ((Status) -> Void)?
    private var output: AVPlayerItemVideoOutput?
    private var timer: DispatchSourceTimer?
    private var thermalObserver: NSObjectProtocol?
    private var timerRate: Double = 0
    private var lastStatus: Status = .loading
    private let timerQueue = DispatchQueue(label: "com.bluecrystal.motion.timer", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "com.bluecrystal.motion", qos: .userInitiated)
    /// inFlight / paused / cancelled 跨队列读写，锁保护
    private let flagLock: UnsafeMutablePointer<os_unfair_lock>
    private var inFlight = false
    private var paused = false
    private var cancelled = false
    /// VM 没在联动时（暂停 / 离开页面 / 后台）不拉帧，省电
    private var active = false
    // 下面只在 workQueue 上用
    private var downscaler = LumaDownscaler()
    private var analyzer = MotionAnalyzer()
    private var frame = LumaFrame()
    private var analyzedGeneration = -1
    /// 帧的内容时间戳（algo-opt-1）：24 / 25 / 30 fps 片源 15 Hz 拉帧时能量不再一大一小地抖
    private var displayClock = MotionDisplayClock()
    /// Instruments「Points of Interest」里看每帧降采样 / 帧差耗时（不开 Instruments 时几乎零开销）
    private static let signpostLog = OSLog(subsystem: "BlueCrystal.VisualSync", category: .pointsOfInterest)
    /// 上一拍的播放位置、上一次出样本的 host 时间：VFR 静止段（没有新帧但播放头在走）补零能量样本
    private var lastItemSeconds: Double = .nan
    private var lastSampleHost: CFTimeInterval = 0
    private var lastRealFrameHost: CFTimeInterval = 0

    private init(item: AVPlayerItem, meter: VideoMotionMeter, completion: @escaping (Status) -> Void) {
        self.item = item
        self.meter = meter
        self.completion = completion
        flagLock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        flagLock.initialize(to: os_unfair_lock())
    }

    deinit {
        timer?.cancel()
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        flagLock.deinitialize(count: 1)
        flagLock.deallocate()
    }

    /// completion 在主线程回调。调用方负责核对 item 还是不是当前播放的那个（照 AudioLevelTap.install）
    static func install(on item: AVPlayerItem, asset: AVAsset, meter: VideoMotionMeter,
                        completion: @escaping (Status) -> Void) -> VideoMotionTap {
        let tap = VideoMotionTap(item: item, meter: meter, completion: completion)
        tap.loadTrack(asset)
        return tap
    }

    /// 停定时器、摘掉 output（主线程）。之后不再回调
    func uninstall() {
        os_unfair_lock_lock(flagLock)
        cancelled = true
        os_unfair_lock_unlock(flagLock)
        timer?.cancel()
        timer = nil
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
        thermalObserver = nil
        if let out = output, let item = item, item.outputs.contains(where: { $0 === out }) {
            item.remove(out)
        }
        output = nil
        completion = nil
    }

    /// 主线程：VM 开始 / 停止联动时开关拉帧
    func setActive(_ on: Bool) {
        os_unfair_lock_lock(flagLock)
        let changed = active != on
        active = on
        os_unfair_lock_unlock(flagLock)
        guard changed else { return }
        reschedule()
    }

    /// 主线程：不联动时定时器停在远期（不用 suspend，cancel 挂起的 source 会崩），联动时按当前频率跑
    private func reschedule() {
        guard let t = timer, timerRate > 0 else { return }
        os_unfair_lock_lock(flagLock)
        let on = active
        os_unfair_lock_unlock(flagLock)
        if on {
            t.schedule(deadline: .now(), repeating: 1.0 / timerRate, leeway: .milliseconds(10))
        } else {
            t.schedule(deadline: .distantFuture, repeating: .never)
        }
    }

    private var isCancelled: Bool {
        os_unfair_lock_lock(flagLock)
        defer { os_unfair_lock_unlock(flagLock) }
        return cancelled
    }

    private func loadTrack(_ asset: AVAsset) {
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, error in
            let hasTrack = !(tracks ?? []).isEmpty
            let reason = error?.localizedDescription
            DispatchQueue.main.async { [weak self] in
                self?.attach(hasTrack: hasTrack, error: reason)
            }
        }
    }

    private func attach(hasTrack: Bool, error: String?) {
        guard !isCancelled else { return }
        guard hasTrack else {
            report(error.map { Status.failed($0) } ?? .noVideo)
            return
        }
        guard let item = item else { return }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: Self.pixelAttributes)
        item.add(out)
        output = out
        startTimer(output: out)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.applyThermal(ProcessInfo.processInfo.thermalState)
            }
        applyThermal(ProcessInfo.processInfo.thermalState)
    }

    private func report(_ status: Status) {
        guard status != lastStatus else { return }
        lastStatus = status
        completion?(status)
    }

    private func startTimer(output: AVPlayerItemVideoOutput) {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.setEventHandler { [weak self] in self?.fire(output: output) }
        timer = t
        timerRate = MotionThermalPolicy.normalRate
        reschedule()
        t.resume()
    }

    /// 主线程：按发热状态调拉帧频率；.critical 时暂停分析（定时器 1 Hz 空转，只查标志）
    private func applyThermal(_ state: ProcessInfo.ThermalState) {
        guard !isCancelled, timer != nil else { return }
        let rate = MotionThermalPolicy.frameRate(for: state)
        os_unfair_lock_lock(flagLock)
        paused = rate <= 0
        os_unfair_lock_unlock(flagLock)
        let tickRate = rate > 0 ? rate : 1
        if tickRate != timerRate {
            timerRate = tickRate
            reschedule()
        }
        let note = MotionThermalPolicy.note(for: state)
        report(note.map { rate > 0 ? Status.degraded($0) : Status.thermalPaused($0) } ?? .ready)
    }

    /// timerQueue：上一帧还在算 / 暂停 / 已拆掉就丢掉这一拍
    private func fire(output: AVPlayerItemVideoOutput) {
        os_unfair_lock_lock(flagLock)
        let skip = cancelled || paused || inFlight || !active
        if !skip { inFlight = true }
        os_unfair_lock_unlock(flagLock)
        guard !skip else { return }
        let host = CACurrentMediaTime()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.analyze(output: output, hostTime: host)
            os_unfair_lock_lock(self.flagLock)
            self.inFlight = false
            os_unfair_lock_unlock(self.flagLock)
        }
    }

    /// workQueue：拉一帧（暂停时 hasNewPixelBuffer 为 false，自然没有样本）→ Y 平面降采样 → 帧差 → 写进电平计。
    /// 时间戳用 host 时间轴（人眼看到的速度，倍速时能量跟着变快），按帧的显示时间校正到「这帧该显示的时刻」
    private func analyze(output: AVPlayerItemVideoOutput, hostTime: CFTimeInterval) {
        let generation = meter.currentGeneration
        if generation != analyzedGeneration {
            analyzer.reset()
            displayClock.reset()
            analyzedGeneration = generation
        }
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isValid else { return }
        let itemSeconds = itemTime.seconds
        let advancing = itemSeconds.isFinite && lastItemSeconds.isFinite && itemSeconds > lastItemSeconds + 0.001
        lastItemSeconds = itemSeconds
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            // 录屏 / 幻灯片这类 VFR 片源静止时没有新帧：播放头在走、超过 0.25 s 没出样本，就补一个零能量样本，
            // 保住参考帧和「安静时不归零」。暂停时播放头不走，不会误补。
            // 补样时间和真实帧同一条显示时刻时间轴（host − 上一帧滞后），之后第一帧的间隔不会被压短
            let stillTime = displayClock.stillTime(host: hostTime)
            if advancing, hostTime - lastSampleHost >= Self.stillFillInterval,
               hostTime - lastRealFrameHost <= Self.stillFillLimit,
               let still = analyzer.still(at: stillTime) {
                displayClock.noteStill(at: stillTime)
                lastSampleHost = hostTime
                meter.add(still, generation: generation)
            }
            return
        }
        var shown = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown) else { return }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isYUV = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isYUV, CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0, rowBytes >= width else { return }
        let luma = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: rowBytes * height)
        os_signpost(.begin, log: Self.signpostLog, name: "MotionDownscale")
        let scaled = downscaler.downscale(luma, width: width, height: height, bytesPerRow: rowBytes, into: &frame)
        os_signpost(.end, log: Self.signpostLog, name: "MotionDownscale")
        guard scaled else { return }
        // 真实帧（含开播 / seek 后的参考帧）都算：之后的静止段照常补零
        lastRealFrameHost = hostTime
        // 这一帧真正的显示时刻（换算到 host 时间轴；拿不到 / 不可信时就是 hostTime）
        let frameTime = displayClock.time(host: hostTime, item: itemSeconds,
                                          shown: shown.isValid ? shown.seconds : .nan)
        os_signpost(.begin, log: Self.signpostLog, name: "MotionAnalyze")
        let analyzed = analyzer.analyze(frame, time: frameTime)
        os_signpost(.end, log: Self.signpostLog, name: "MotionAnalyze")
        guard let sample = analyzed else { return }
        lastSampleHost = hostTime
        meter.add(sample, generation: generation)
    }
}
