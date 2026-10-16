import Foundation
import AVFoundation
import CoreVideo
import QuartzCore
import ImageIO
import Vision
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

    /// 姿态队列上的一次姿态读数（algo-opt-3）。跨 reset 的照样作废
    fileprivate func addPose(_ reading: PoseReading, generation g: Int) {
        os_unfair_lock_lock(lock)
        if g == generation { accumulator.addPose(reading) }
        os_unfair_lock_unlock(lock)
    }

    /// rhythm-context P3：姿态队列上的一次手 / 脸 / 身体上下文（只在「动作识别」开着时有）。跨 reset 的照样作废
    fileprivate func addContext(_ context: PoseContext, generation g: Int) {
        os_unfair_lock_lock(lock)
        if g == generation { accumulator.addContext(context) }
        os_unfair_lock_unlock(lock)
    }
}

/// 视频轨方向 → Vision 的图像方向（algo-opt-3）
private extension PoseOrientation {
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}

/// 姿态辅助（algo-opt-3）：独立 .utility 串行队列上约 9 Hz 跑 Vision 人体姿态（VNDetectHumanBodyPoseRequest，
/// 缩放由 Vision 自己做），关键点换回分析帧像素坐标，扣掉相机运动后算速度 / 节奏，写进电平计。
/// 上一次还没跑完就跳过这一拍（不排队、不阻塞画面分析）；发热 .serious 起不提交；Vision 连续出错 3 次就停用。
/// 只读像素缓冲，不碰 BLE、不判断该不该输出
private final class PoseWorker {
    /// 提交间隔：15 Hz 拉帧时大约每 5 帧提交 3 帧
    static let interval: Double = 1.0 / 9
    static let maxFailures = 3
    /// 慢设备节流（复审 L2）：一次 Vision 跑完后至少空闲「这次耗时 × 0.5」再提交下一次（最多空 1 秒），
    /// 单次超过 1/9 秒时姿态队列最多约 2/3 的时间在跑，不会一直满负荷。
    /// 不取 × 1：单次 0.2 秒时间隔就到 0.4 秒以上，超过 PoseMotionTracker.maxGap，姿态就一直连不上
    static let idleShare: Double = 0.5
    static let maxIdle: Double = 1

    private let queue = DispatchQueue(label: "com.bluecrystal.motion.pose", qos: .utility)
    /// inFlight / thermalOK / orientation / failures / idleUntil 跨队列读写，锁保护
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var inFlight = false
    /// host 时间（CACurrentMediaTime）：上一次跑完 + 空闲时间，之前不提交
    private var idleUntil: CFTimeInterval = 0
    private var thermalOK = true
    private var failures = 0
    private var orientation = PoseOrientation.up
    // 下面只在 queue 上用
    private let request = VNDetectHumanBodyPoseRequest()
    private var tracker = PoseMotionTracker()
    private var trackedGeneration = -1
    private var candidates: [PoseCandidate] = []
    /// rhythm-context P3（「动作识别」开着时才跑）：手 / 脸检测 + 各自的节奏。关着时一次都不跑、不建结果
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 4
        return r
    }()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var handTracker = PartMotionTracker()
    private var faceTracker = PartMotionTracker()
    private var handCandidates: [PartCandidate] = []
    private var faceCandidates: [PartCandidate] = []
    private var contextWasOn = false
    private static let handPalm: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]

    private static let joints: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .nose), (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.root, .root), (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee),
        (.rightKnee, .rightKnee), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist)]

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        candidates.reserveCapacity(4)
        handCandidates.reserveCapacity(4)
        faceCandidates.reserveCapacity(4)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// 任意线程：视频轨的 preferredTransform 读到以后（竖拍视频的缓冲是横的，要摆正了 Vision 才认得出人）
    func setOrientation(_ o: PoseOrientation) {
        os_unfair_lock_lock(lock)
        orientation = o
        os_unfair_lock_unlock(lock)
    }

    /// 主线程：只在 .nominal / .fair 跑姿态（画面分析本身在 .serious 降频、.critical 暂停）
    func setThermalOK(_ ok: Bool) {
        os_unfair_lock_lock(lock)
        thermalOK = ok
        os_unfair_lock_unlock(lock)
    }

    /// workQueue：能提交就提交（返回 true），上一次还在跑 / 还在空闲期 / 发热 / 已停用就返回 false。
    /// camera：上一次提交的那帧到这一帧的相机运动（分析帧像素）；continuous == false：中间断过
    /// phaseFit / context：rhythm-context P3 的两个开关（相位拟合 / 动作识别），由画面分析那边按设置带过来
    func submit(_ buffer: CVPixelBuffer, time: Double, camera: CameraTransform, continuous: Bool,
                frameWidth: Int, frameHeight: Int, generation: Int, meter: VideoMotionMeter,
                phaseFit: Bool = false, context: Bool = false) -> Bool {
        guard frameWidth > 0, frameHeight > 0, time.isFinite else { return false }
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(lock)
        let go = !inFlight && now >= idleUntil && thermalOK && failures < Self.maxFailures
        if go { inFlight = true }
        let o = orientation
        os_unfair_lock_unlock(lock)
        guard go else { return false }
        queue.async { [weak self] in
            guard let self = self else { return }
            let start = CACurrentMediaTime()
            self.run(buffer, time: time, camera: camera, continuous: continuous, orientation: o,
                     frameWidth: frameWidth, frameHeight: frameHeight, generation: generation, meter: meter,
                     phaseFit: phaseFit, context: context)
            let end = CACurrentMediaTime()
            let took = end - start
            let idle = took.isFinite ? min(Self.maxIdle, max(0, took * Self.idleShare)) : 0
            os_unfair_lock_lock(self.lock)
            self.inFlight = false
            self.idleUntil = end + idle
            os_unfair_lock_unlock(self.lock)
        }
        return true
    }

    /// queue：Vision → 分析帧像素坐标的候选人 → PoseMotionTracker → 电平计
    private func run(_ buffer: CVPixelBuffer, time: Double, camera: CameraTransform, continuous: Bool,
                     orientation o: PoseOrientation, frameWidth: Int, frameHeight: Int, generation: Int,
                     meter: VideoMotionMeter, phaseFit: Bool, context: Bool) {
        if generation != trackedGeneration {
            tracker.reset()
            handTracker.reset()
            faceTracker.reset()
            trackedGeneration = generation
        }
        tracker.phaseFitEnabled = phaseFit
        tracker.contextEnabled = context
        handTracker.phaseFitEnabled = phaseFit
        faceTracker.phaseFitEnabled = phaseFit
        if !context, contextWasOn {
            handTracker.reset()
            faceTracker.reset()
        }
        contextWasOn = context
        let w = Double(frameWidth)
        let h = Double(frameHeight)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: o.imageOrientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            os_unfair_lock_lock(lock)
            failures += 1
            os_unfair_lock_unlock(lock)
            // 这一帧当作没人：下一次不和更早的帧算速度
            let reading = tracker.update(time: time, candidates: [], camera: .identity, continuous: false,
                                         frameHeight: h)
            meter.addPose(reading, generation: generation)
            if context {
                _ = handTracker.update(time: time, candidates: [], camera: .identity, continuous: false)
                _ = faceTracker.update(time: time, candidates: [], camera: .identity, continuous: false)
            }
            return
        }
        os_unfair_lock_lock(lock)
        failures = 0
        os_unfair_lock_unlock(lock)
        candidates.removeAll(keepingCapacity: true)
        for observation in request.results ?? [] {
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            var person = PoseCandidate()
            person.confidence = Double(observation.confidence)
            for (joint, name) in Self.joints {
                guard let p = points[name], p.confidence > 0 else { continue }
                let b = o.bufferPoint(visionX: Double(p.location.x), visionY: Double(p.location.y))
                person.set(joint, x: b.x * w, y: b.y * h, confidence: Double(p.confidence))
            }
            candidates.append(person)
        }
        let reading = tracker.update(time: time, candidates: candidates, camera: camera, continuous: continuous,
                                     frameHeight: h)
        meter.addPose(reading, generation: generation)
        guard context else { return }
        runContext(handler, time: time, camera: camera, continuous: continuous, orientation: o, width: w, height: h)
        let c = PoseContext(valid: true, time: time, frameWidth: w, frameHeight: h, body: tracker.bodyContext,
                            hand: handTracker.reading, face: faceTracker.reading)
        meter.addContext(c, generation: generation)
    }

    /// queue（rhythm-context P3）：同一个 handler 再跑手 / 脸检测。出错只当这一帧没检测到（不计入停用次数、不影响人体姿态）
    private func runContext(_ handler: VNImageRequestHandler, time: Double, camera: CameraTransform, continuous: Bool,
                            orientation o: PoseOrientation, width w: Double, height h: Double) {
        handCandidates.removeAll(keepingCapacity: true)
        faceCandidates.removeAll(keepingCapacity: true)
        let ok = (try? handler.perform([handRequest, faceRequest])) != nil
        if ok {
            for observation in handRequest.results ?? [] {
                guard let points = try? observation.recognizedPoints(.all) else { continue }
                var sx = 0.0
                var sy = 0.0
                var n = 0
                var wrist: (x: Double, y: Double)?
                var middle: (x: Double, y: Double)?
                for name in Self.handPalm {
                    guard let p = points[name], p.confidence >= 0.3 else { continue }
                    let b = o.bufferPoint(visionX: Double(p.location.x), visionY: Double(p.location.y))
                    let q = (x: b.x * w, y: b.y * h)
                    sx += q.x
                    sy += q.y
                    n += 1
                    if name == .wrist { wrist = q }
                    if name == .middleMCP { middle = q }
                }
                guard n >= 3 else { continue }
                var size = 0.0
                if let a = wrist, let b = middle {
                    size = 3 * ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
                }
                guard size.isFinite, size >= 2 else { continue }
                handCandidates.append(PartCandidate(x: sx / Double(n), y: sy / Double(n), size: size,
                                                    confidence: Double(observation.confidence)))
            }
            for observation in faceRequest.results ?? [] {
                let r = observation.boundingBox
                guard r.width > 0, r.height > 0 else { continue }
                let a = o.bufferPoint(visionX: Double(r.minX), visionY: Double(r.minY))
                let b = o.bufferPoint(visionX: Double(r.maxX), visionY: Double(r.maxY))
                let extent = max(abs(a.x - b.x) * w, abs(a.y - b.y) * h)
                guard extent.isFinite, extent >= 2 else { continue }
                faceCandidates.append(PartCandidate(x: (a.x + b.x) / 2 * w, y: (a.y + b.y) / 2 * h, size: 2.5 * extent,
                                                    confidence: Double(observation.confidence)))
            }
        }
        _ = handTracker.update(time: time, candidates: handCandidates, camera: ok ? camera : .identity,
                               continuous: ok && continuous)
        _ = faceTracker.update(time: time, candidates: faceCandidates, camera: ok ? camera : .identity,
                               continuous: ok && continuous)
    }
}

/// 给 AVPlayerItem 挂一个 AVPlayerItemVideoOutput（420f，只读 Y 平面），独立串行队列上 15 Hz 拉帧分析。
/// 只在跟随画面时安装（声音模式零开销）。上一帧还没算完就丢掉这一拍，永远不阻塞主线程；
/// 发热 .serious 降到 8 Hz，.critical 暂停分析。这里不碰 BLE、不判断该不该输出：那全由 VideoSyncPlayer 决定。
/// algo-opt-3：另有姿态辅助（PoseWorker），把拉到的帧约 9 Hz 交给 Vision 认人体关键点，块运动给的相机运动一并带过去
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
    /// rhythm-context P3：相位拟合 / 动作识别开关（主线程设，workQueue 读；默认都关 = P2 关着时的行为）
    private var phaseFitFlag = false
    private var contextFlag = false
    // 下面只在 workQueue 上用
    private var downscaler = LumaDownscaler()
    private var analyzer = MotionAnalyzer()
    private var frame = LumaFrame()
    private var analyzedGeneration = -1
    /// rhythm-context P3（只在 workQueue 上用）：周期区域放大跟踪。动作识别关着时不裁剪、不分析
    private var roiTracker = RoiFlowTracker()
    private var cropDownscaler = LumaCropDownscaler()
    private var roiFrame = LumaFrame()
    private var roiWasOn = false
    /// 帧的内容时间戳（algo-opt-1）：24 / 25 / 30 fps 片源 15 Hz 拉帧时能量不再一大一小地抖
    private var displayClock = MotionDisplayClock()
    /// Instruments「Points of Interest」里看每帧降采样 / 帧差耗时（不开 Instruments 时几乎零开销）
    private static let signpostLog = OSLog(subsystem: "BlueCrystal.VisualSync", category: .pointsOfInterest)
    /// 上一拍的播放位置、上一次出样本的 host 时间：VFR 静止段（没有新帧但播放头在走）补零能量样本
    private var lastItemSeconds: Double = .nan
    private var lastSampleHost: CFTimeInterval = 0
    private var lastRealFrameHost: CFTimeInterval = 0
    /// 姿态辅助（algo-opt-3）。poseCamera / poseContinuous / poseNext 只在 workQueue 上用：
    /// 上一次提交姿态的那帧到现在的相机运动（逐帧合成），中间断过（参考帧 / 切镜 / reset）就记为不连续
    private let pose = PoseWorker()
    private var poseCamera = CameraTransform.identity
    private var poseContinuous = false
    private var poseNext: Double = -.infinity

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

    /// 主线程（rhythm-context P3）：相位拟合跟「相位脉动」开关走，动作识别跟「动作识别」开关走。下一帧起生效
    func setRhythmFlags(phaseFit: Bool, context: Bool) {
        os_unfair_lock_lock(flagLock)
        phaseFitFlag = phaseFit
        contextFlag = context
        os_unfair_lock_unlock(flagLock)
    }

    private var rhythmFlags: (phaseFit: Bool, context: Bool) {
        os_unfair_lock_lock(flagLock)
        defer { os_unfair_lock_unlock(flagLock) }
        return (phaseFitFlag, contextFlag)
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
            // 姿态辅助要知道视频轨方向（竖拍视频的缓冲是横的）；读不到就按 .up
            if let track = tracks?.first {
                Task { [weak self] in
                    guard let t = try? await track.load(.preferredTransform) else { return }
                    self?.pose.setOrientation(PoseOrientation.from(a: Double(t.a), b: Double(t.b),
                                                                   c: Double(t.c), d: Double(t.d)))
                }
            }
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
        pose.setThermalOK(state == .nominal || state == .fair)
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
            poseCamera = .identity
            poseContinuous = false
            poseNext = -.infinity
            roiTracker.reset()
        }
        let flags = rhythmFlags
        analyzer.phaseFitEnabled = flags.phaseFit
        if analyzer.contextEnabled != flags.context { analyzer.contextEnabled = flags.context }
        roiTracker.phaseFitEnabled = flags.phaseFit
        if !flags.context, roiWasOn { roiTracker.reset() }
        roiWasOn = flags.context
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
        notePose(buffer, time: frameTime, generation: generation, flags: flags)
        guard var sample = analyzed else { return }
        if flags.context {
            noteRoi(&sample, luma: luma, width: width, height: height, rowBytes: rowBytes, time: frameTime)
        }
        lastSampleHost = hostTime
        meter.add(sample, generation: generation)
    }

    /// workQueue（rhythm-context P3）：周期区域够小就从原始 Y 平面裁出来放大成分析帧大小，再算一遍主体运动。
    /// 切镜 / 补帧那一拍不跟（下一次重新攒）
    private func noteRoi(_ sample: inout MotionSample, luma: UnsafeRawBufferPointer, width: Int, height: Int,
                         rowBytes: Int, time: Double) {
        let region = analyzer.periodicity.roi
        if sample.isCut || sample.isHeld {
            roiTracker.noteCut()
            sample.roi.region = region
            return
        }
        guard let crop = roiTracker.plan(region, now: time) else {
            sample.roi.region = region
            return
        }
        os_signpost(.begin, log: Self.signpostLog, name: "MotionRoi")
        let ok = cropDownscaler.downscale(luma, width: width, height: height, bytesPerRow: rowBytes, crop: crop,
                                          outWidth: frame.width, outHeight: frame.height, into: &roiFrame)
        var reading = RoiReading()
        if ok {
            reading = roiTracker.update(time: time, frame: roiFrame, camera: analyzer.lastCamera,
                                        cameraContinuous: analyzer.cameraContinuous,
                                        analysisWidth: frame.width, analysisHeight: frame.height)
        } else {
            roiTracker.noteCut()
        }
        os_signpost(.end, log: Self.signpostLog, name: "MotionRoi")
        sample.roi = reading
        sample.roi.region = region
    }

    /// workQueue：把这一帧的相机运动合进「上次提交姿态以来」那一段，到点就把这一帧交给姿态辅助（algo-opt-3）
    private func notePose(_ buffer: CVPixelBuffer, time: Double, generation: Int,
                          flags: (phaseFit: Bool, context: Bool)) {
        if analyzer.cameraContinuous {
            poseCamera = poseCamera.then(analyzer.lastCamera)
        } else {
            poseCamera = .identity
            poseContinuous = false
        }
        if time < poseNext - 1 { poseNext = -.infinity }
        guard time.isFinite, time >= poseNext - 0.005 else { return }
        guard pose.submit(buffer, time: time, camera: poseCamera, continuous: poseContinuous,
                          frameWidth: frame.width, frameHeight: frame.height, generation: generation,
                          meter: meter, phaseFit: flags.phaseFit, context: flags.context) else { return }
        poseCamera = .identity
        poseContinuous = true
        poseNext = poseNext.isFinite ? max(poseNext + PoseWorker.interval, time + PoseWorker.interval * 0.5)
                                     : time + PoseWorker.interval
    }
}
