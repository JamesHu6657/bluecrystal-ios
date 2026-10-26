import Foundation
import AVFoundation
import CoreVideo
import QuartzCore
import ImageIO
import Vision
import UIKit
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

#if targetEnvironment(simulator)
/// 模拟器诊断（motion-zero-diag，只在模拟器构建里有；真机构建没有这段）：姿态这一路跑了几次、认到人几次、是不是在省电放宽
struct PoseDiag {
    var runs = 0
    var seenRuns = 0
    var backoff = false
    var lastTookMs = 0.0
    var failures = 0
    /// Vision 原始认到人的次数 / 有候选人过门槛（置信度 ≥ 0.3 且 11 个关节里 ≥ 4 个 ≥ 0.3）的次数 / 读数 present 的次数
    var rawPeopleRuns = 0
    var candidateRuns = 0
    var presentRuns = 0
    /// 最近一次：最高的人置信度、11 个关节里 ≥ 0.3 的个数（最多的那个人）、全部 19 个里 ≥ 0.1 的个数
    var lastPersonConf = 0.0
    var lastJoints11 = 0
    var lastJointsLow = 0
    var lastError = ""
}
#endif

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
    /// 省电（pose-idle-backoff）：连续 absentAfter 秒（host 时间）一个人都没认到（动作识别开着时手 / 脸也没认到），
    /// 提交间隔放宽到 absentInterval；一认到人立刻回到约 9 Hz，换视频 / 跳转（generation 变）也立刻回到 9 Hz。
    /// 代价：人刚入画时最多晚约 1 秒认出来。没人时姿态读数本来就是空的，放宽间隔对输出影响很小
    static let absentAfter: Double = 3
    static let absentInterval: Double = 1

    private let queue = DispatchQueue(label: "com.bluecrystal.motion.pose", qos: .utility)
    /// inFlight / thermalOK / orientation / failures / idleUntil 跨队列读写，锁保护
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var inFlight = false
    /// host 时间（CACurrentMediaTime）：上一次跑完 + 空闲时间，之前不提交
    private var idleUntil: CFTimeInterval = 0
    /// 上一次提交的 generation（锁保护）：换视频 / 跳转后不等省电放宽的空闲期，马上提交
    private var submittedGeneration = Int.min
    private var thermalOK = true
    private var failures = 0
    private var orientation = PoseOrientation.up
    /// host 时间：最近一次认到人（或开始计没人）的时刻；-1 = 还没开始计。只在 queue 上读写
    private var lastSeenHost: CFTimeInterval = -1
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

    #if targetEnvironment(simulator)
    private var diagState = PoseDiag()
    func diagSnapshot() -> PoseDiag {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        var d = diagState
        d.failures = failures
        return d
    }
    #endif

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
                phaseFit: Bool = false, context: Bool = false, closeUp: Bool = false) -> Bool {
        guard frameWidth > 0, frameHeight > 0, time.isFinite else { return false }
        let now = CACurrentMediaTime()
        os_unfair_lock_lock(lock)
        let go = !inFlight && (now >= idleUntil || generation != submittedGeneration)
            && thermalOK && failures < Self.maxFailures
        if go {
            inFlight = true
            submittedGeneration = generation
        }
        let o = orientation
        os_unfair_lock_unlock(lock)
        guard go else { return false }
        queue.async { [weak self] in
            guard let self = self else { return }
            let start = CACurrentMediaTime()
            let seen = self.run(buffer, time: time, camera: camera, continuous: continuous, orientation: o,
                     frameWidth: frameWidth, frameHeight: frameHeight, generation: generation, meter: meter,
                     phaseFit: phaseFit, context: context, closeUp: closeUp)
            let end = CACurrentMediaTime()
            let took = end - start
            var idle = took.isFinite ? min(Self.maxIdle, max(0, took * Self.idleShare)) : 0
            if seen || self.lastSeenHost < 0 { self.lastSeenHost = end }
            if !seen, end - self.lastSeenHost >= Self.absentAfter {
                let took0 = took.isFinite ? max(0, took) : 0
                idle = max(idle, Self.absentInterval - took0)
            }
            os_unfair_lock_lock(self.lock)
            self.inFlight = false
            self.idleUntil = end + idle
            #if targetEnvironment(simulator)
            self.diagState.runs += 1
            if seen { self.diagState.seenRuns += 1 }
            self.diagState.backoff = !seen && end - self.lastSeenHost >= Self.absentAfter
            self.diagState.lastTookMs = took.isFinite ? took * 1000 : -1
            #endif
            os_unfair_lock_unlock(self.lock)
        }
        return true
    }

    /// queue：Vision → 分析帧像素坐标的候选人 → PoseMotionTracker → 电平计。
    /// 返回这一帧有没有认到人（身体，或动作识别开着时的手 / 脸）；出错不算没人（返回 true，不触发省电放宽）
    private func run(_ buffer: CVPixelBuffer, time: Double, camera: CameraTransform, continuous: Bool,
                     orientation o: PoseOrientation, frameWidth: Int, frameHeight: Int, generation: Int,
                     meter: VideoMotionMeter, phaseFit: Bool, context: Bool, closeUp: Bool) -> Bool {
        if generation != trackedGeneration {
            tracker.reset()
            handTracker.reset()
            faceTracker.reset()
            trackedGeneration = generation
            lastSeenHost = -1
        }
        tracker.phaseFitEnabled = phaseFit
        tracker.contextEnabled = context
        // rhythm-action tune：近景只认到身体一部分时按解剖比例估尺度、另一个人的髋也攒节奏（跟动作识别开关走）
        tracker.actionTuned = context
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
            #if targetEnvironment(simulator)
            diagState.lastError = String(describing: error).prefix(80).description
            #endif
            os_unfair_lock_unlock(lock)
            // 这一帧当作没人：下一次不和更早的帧算速度
            let reading = tracker.update(time: time, candidates: [], camera: .identity, continuous: false,
                                         frameHeight: h)
            meter.addPose(reading, generation: generation)
            if context {
                _ = handTracker.update(time: time, candidates: [], camera: .identity, continuous: false)
                _ = faceTracker.update(time: time, candidates: [], camera: .identity, continuous: false)
            }
            return true
        }
        os_unfair_lock_lock(lock)
        failures = 0
        os_unfair_lock_unlock(lock)
        candidates.removeAll(keepingCapacity: true)
        var rawJoints = 0
        var rawLowJoints = 0
        var rawConfidence = 0.0
        for observation in request.results ?? [] {
            rawConfidence = max(rawConfidence, Double(observation.confidence))
            guard let points = try? observation.recognizedPoints(.all) else { continue }
            rawJoints = max(rawJoints, points.values.reduce(0) { $0 + ($1.confidence >= 0.3 ? 1 : 0) })
            rawLowJoints = max(rawLowJoints, points.values.reduce(0) { $0 + ($1.confidence >= 0.1 ? 1 : 0) })
            var person = PoseCandidate()
            // 近景姿态放宽（默认关）：[0.1, 0.3) 的置信度抬到 0.3，其余原样
            person.confidence = closeUp ? PoseCloseUp.lift(Double(observation.confidence)) : Double(observation.confidence)
            for (joint, name) in Self.joints {
                guard let p = points[name], p.confidence > 0 else { continue }
                let b = o.bufferPoint(visionX: Double(p.location.x), visionY: Double(p.location.y))
                let c = closeUp ? PoseCloseUp.lift(Double(p.confidence)) : Double(p.confidence)
                person.set(joint, x: b.x * w, y: b.y * h, confidence: c)
            }
            candidates.append(person)
        }
        var reading = tracker.update(time: time, candidates: candidates, camera: camera, continuous: continuous,
                                     frameHeight: h)
        // 调试列（只进表格）：Vision 原始认到几个人、关节最多的人有几个可信关节
        reading.rawPeople = request.results?.count ?? 0
        reading.rawJoints = rawJoints
        reading.rawConfidence = rawConfidence
        reading.rawLowJoints = rawLowJoints
        #if targetEnvironment(simulator)
        var bestConf = 0.0
        var best11 = 0
        var bestLow = 0
        var passes = false
        for observation in request.results ?? [] {
            bestConf = max(bestConf, Double(observation.confidence))
            if let points = try? observation.recognizedPoints(.all) {
                bestLow = max(bestLow, points.values.reduce(0) { $0 + ($1.confidence >= 0.1 ? 1 : 0) })
            }
        }
        for person in candidates {
            let n = person.c.reduce(0) { $0 + ($1 >= PoseMotionTracker.minJointConfidence ? 1 : 0) }
            best11 = max(best11, n)
            if person.confidence >= PoseMotionTracker.minPersonConfidence, n >= PoseMotionTracker.minJoints { passes = true }
        }
        os_unfair_lock_lock(lock)
        if reading.rawPeople > 0 { diagState.rawPeopleRuns += 1 }
        if passes { diagState.candidateRuns += 1 }
        if reading.present { diagState.presentRuns += 1 }
        diagState.lastPersonConf = bestConf
        diagState.lastJoints11 = best11
        diagState.lastJointsLow = bestLow
        os_unfair_lock_unlock(lock)
        #endif
        guard context else {
            meter.addPose(reading, generation: generation)
            return !candidates.isEmpty
        }
        // 自审 L3：手 / 脸检测让每帧姿态开销约翻倍，只在 .nominal 跑；.fair 起只留人体姿态（手 / 脸当没检测到）
        if ProcessInfo.processInfo.thermalState == .nominal {
            runContext(handler, time: time, camera: camera, continuous: continuous, orientation: o, width: w, height: h)
        } else {
            handTracker.reset()
            faceTracker.reset()
            handCandidates.removeAll(keepingCapacity: true)
            faceCandidates.removeAll(keepingCapacity: true)
        }
        reading.rawHands = handCandidates.count
        reading.rawFaces = faceCandidates.count
        meter.addPose(reading, generation: generation)
        let c = PoseContext(valid: true, time: time, frameWidth: w, frameHeight: h, body: tracker.bodyContext,
                            hand: handTracker.reading, face: faceTracker.reading)
        meter.addContext(c, generation: generation)
        return !candidates.isEmpty || !handCandidates.isEmpty || !faceCandidates.isEmpty
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
    #if targetEnvironment(simulator)
    /// 模拟器诊断（motion-zero-diag，只在模拟器构建里有）：取帧这条路每一步走了几次。flagLock 保护
    struct Diag {
        var analyzeCalls = 0
        var badItemTime = 0
        var noNewBuffer = 0
        var stillFills = 0
        var copyNil = 0
        var badFormat = 0
        var lastFormat: UInt32 = 0
        var scaleFail = 0
        var analyzed = 0
        var samples = 0
        var width = 0
        var height = 0
        var lastItem = Double.nan
        var pose = PoseDiag()
    }
    private var diagState = Diag()
    private func diagNote(_ f: (inout Diag) -> Void) {
        os_unfair_lock_lock(flagLock)
        f(&diagState)
        os_unfair_lock_unlock(flagLock)
    }
    /// 主线程：读一份诊断计数
    func diagSnapshot() -> Diag {
        os_unfair_lock_lock(flagLock)
        var d = diagState
        os_unfair_lock_unlock(flagLock)
        d.pose = pose.diagSnapshot()
        return d
    }
    #endif
    /// rhythm-context P3：相位拟合 / 动作识别开关（主线程设，workQueue 读；默认都关 = P2 关着时的行为）
    private var phaseFitFlag = false
    private var contextFlag = false
    /// 近景姿态放宽（实验，默认关）
    private var closeUpFlag = false
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
    func setRhythmFlags(phaseFit: Bool, context: Bool, closeUp: Bool = false) {
        os_unfair_lock_lock(flagLock)
        phaseFitFlag = phaseFit
        contextFlag = context
        closeUpFlag = closeUp
        os_unfair_lock_unlock(flagLock)
    }

    private var rhythmFlags: (phaseFit: Bool, context: Bool, closeUp: Bool) {
        os_unfair_lock_lock(flagLock)
        defer { os_unfair_lock_unlock(flagLock) }
        return (phaseFitFlag, contextFlag, closeUpFlag)
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
        // rhythm-action tune：块运动噪声防护 + 周期区域稳定性（跟动作识别开关走；关着时逐位不变）
        if analyzer.actionTuned != flags.context { analyzer.actionTuned = flags.context }
        roiTracker.noiseGuard = flags.context
        roiTracker.phaseFitEnabled = flags.phaseFit
        if !flags.context, roiWasOn { roiTracker.reset() }
        roiWasOn = flags.context
        let itemTime = output.itemTime(forHostTime: hostTime)
        #if targetEnvironment(simulator)
        diagNote { $0.analyzeCalls += 1; if !itemTime.isValid { $0.badItemTime += 1 } else { $0.lastItem = itemTime.seconds } }
        #endif
        guard itemTime.isValid else { return }
        let itemSeconds = itemTime.seconds
        let advancing = itemSeconds.isFinite && lastItemSeconds.isFinite && itemSeconds > lastItemSeconds + 0.001
        lastItemSeconds = itemSeconds
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            #if targetEnvironment(simulator)
            diagNote { $0.noNewBuffer += 1 }
            #endif
            // 录屏 / 幻灯片这类 VFR 片源静止时没有新帧：播放头在走、超过 0.25 s 没出样本，就补一个零能量样本，
            // 保住参考帧和「安静时不归零」。暂停时播放头不走，不会误补。
            // 补样时间和真实帧同一条显示时刻时间轴（host − 上一帧滞后），之后第一帧的间隔不会被压短
            let stillTime = displayClock.stillTime(host: hostTime)
            if advancing, hostTime - lastSampleHost >= Self.stillFillInterval,
               hostTime - lastRealFrameHost <= Self.stillFillLimit,
               let still = analyzer.still(at: stillTime) {
                displayClock.noteStill(at: stillTime)
                #if targetEnvironment(simulator)
                diagNote { $0.stillFills += 1 }
                #endif
                lastSampleHost = hostTime
                meter.add(still, generation: generation)
            }
            return
        }
        var shown = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &shown) else {
            #if targetEnvironment(simulator)
            diagNote { $0.copyNil += 1 }
            #endif
            return
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        #if targetEnvironment(simulator)
        diagNote { $0.lastFormat = format }
        #endif
        let isYUV = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isYUV, CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            #if targetEnvironment(simulator)
            diagNote { $0.badFormat += 1 }
            #endif
            return
        }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0, rowBytes >= width else { return }
        let luma = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: rowBytes * height)
        os_signpost(.begin, log: Self.signpostLog, name: "MotionDownscale")
        let scaled = downscaler.downscale(luma, width: width, height: height, bytesPerRow: rowBytes, into: &frame)
        os_signpost(.end, log: Self.signpostLog, name: "MotionDownscale")
        #if targetEnvironment(simulator)
        diagNote { $0.width = width; $0.height = height; if !scaled { $0.scaleFail += 1 } }
        #endif
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
        #if targetEnvironment(simulator)
        diagNote { $0.analyzed += 1; if analyzed != nil { $0.samples += 1 } }
        #endif
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
                          flags: (phaseFit: Bool, context: Bool, closeUp: Bool)) {
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
                          meter: meter, phaseFit: flags.phaseFit, context: flags.context,
                          closeUp: flags.closeUp) else { return }
        poseCamera = .identity
        poseContinuous = true
        poseNext = poseNext.isFinite ? max(poseNext + PoseWorker.interval, time + PoseWorker.interval * 0.5)
                                     : time + PoseWorker.interval
    }
}

/// rhythm-lookahead P4（默认关）：另开一路 AVAssetReader 解码同一个本地视频文件，做两件事（各自有开关）：
/// - 前瞻：从播放头起往后最多读 LookaheadTimeline.horizon 秒，跑同一套 LumaDownscaler + MotionAnalyzer（块运动主体 / 节奏 / 相位拟合，
///   不跑 Vision），按视频时间写进 LookaheadTimeline；主线程每个完整拍取一份快照交给 LookaheadCoordinator。
///   往回 seek / 往前跳 / 解码跟不上时从播放头重读；10 秒内重读 4 次以上算「跟不上」，停 5 秒（这期间只用实时）。
/// - 预扫描：前瞻不缺帧时，从头到尾按 15 Hz 分析一遍，攒 MotionPrescan，扫完回调主线程（MotionNormalizer.seed 只在还没学过时用）。
///   播放中每 20 ms 最多解码 1 帧（每秒约 50 帧，30 fps 片源不到 2 倍速），暂停时每步最多 10 帧；
///   可随时取消（关开关 / 换视频 / 离开画面联动）；结果用不上时（已经有结果 / 播放已经开始学）播放器也会把这一路关掉。
/// 全部在一个 .utility 串行队列上按小步做（每步 ≤ 约 12 ms 后让出），不阻塞主线程和实时分析队列；
/// 发热 .serious 起两路都停（LookaheadThermalPolicy），App 进后台也停，回来后从播放头 / 预扫描停下的地方接着读。
/// 读不了这个文件（创建 / 读取失败 3 次）就放弃，主线程退回只用实时。这里不碰 BLE、不决定输出
final class LookaheadReader {
    struct Snapshot {
        var timeline: LookaheadTimeline
        /// 两路都停着的原因（发热 / 后台 / 没有画面轨）；正常时 nil
        var blocked: String?
        /// 前瞻这一路不能用的原因（解码跟不上 / 读不了这个文件）；正常时 nil
        var lookNote: String?
        /// 前瞻能不能用（没有停着、前瞻这一路也没出问题）
        var lookUsable: Bool { blocked == nil && lookNote == nil }
        /// 预扫描进度 0~1（没开 / 还不知道时长时 nil）
        var prescanProgress: Double?
        var prescanFailed: Bool
    }

    static let frameInterval: Double = 1.0 / 15
    static let pumpBusy: Double = 0.02
    static let pumpIdle: Double = 0.1
    static let pumpBlocked: Double = 1
    static let sliceSeconds: CFTimeInterval = 0.012
    static let lookFramesPerSlice = 24
    static let prescanFramesPlaying = 1
    static let prescanFramesPaused = 10
    static let maxFailures = 3
    static let thrashRestarts = 4
    static let thrashWindow: CFTimeInterval = 10
    static let thrashBackoff: CFTimeInterval = 5

    private let asset: AVAsset
    private let queue = DispatchQueue(label: "com.bluecrystal.motion.lookahead", qos: .utility)
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// 主线程回调（扫完）。只在主线程读写
    private var onPrescanDone: ((MotionPrescan.Summary) -> Void)?
    // 下面跨线程，lock 保护
    private var cancelled = false
    private var wantLookahead = false
    private var wantPrescan = false
    private var phaseFit = false
    private var playhead: Double = .nan
    private var playing = false
    private var duration: Double = .nan
    private var background = false
    private var shared = LookaheadTimeline()
    private var sharedBlocked: String?
    private var sharedLookNote: String?
    private var sharedProgress: Double?
    private var sharedPrescanFailed = false
    // 下面只在 queue 上用
    private var track: AVAssetTrack?
    private var trackLoaded = false
    private var lookReader: AVAssetReader?
    private var lookOutput: AVAssetReaderTrackOutput?
    private var lookEnded = false
    private var lookAnalyzer = MotionAnalyzer()
    private var lookScaler = LumaDownscaler()
    private var lookFrame = LumaFrame()
    private var lookLast: Double = -.infinity
    private var timeline = LookaheadTimeline()
    private var lookFailures = 0
    private var restarts: [CFTimeInterval] = []
    private var backoffUntil: CFTimeInterval = 0
    private var preReader: AVAssetReader?
    private var preOutput: AVAssetReaderTrackOutput?
    private var preAnalyzer = MotionAnalyzer()
    private var preScaler = LumaDownscaler()
    private var preFrame = LumaFrame()
    private var preLast: Double = -.infinity
    private var prescan = MotionPrescan()
    private var preResumeAt: Double = 0
    private var prescanFinished = false
    private var preFailures = 0
    private var preFailedAt: Double = -.infinity
    private var pumpScheduled = false
    private var observers: [NSObjectProtocol] = []

    init(asset: AVAsset, onPrescanDone: @escaping (MotionPrescan.Summary) -> Void) {
        self.asset = asset
        self.onPrescanDone = onPrescanDone
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        restarts.reserveCapacity(8)
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// 主线程：开始（读视频轨，之后按开关做事）
    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.setBackground(true) })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.setBackground(false) })
        setBackground(UIApplication.shared.applicationState == .background)
        asset.loadTracks(withMediaType: .video) { [weak self] tracks, _ in
            guard let self = self else { return }
            self.queue.async {
                self.track = tracks?.first
                self.trackLoaded = true
                self.schedulePump(after: 0)
            }
        }
    }

    /// 主线程：拆掉。之后不再回调；读帧在队列上下一步时取消
    func cancel() {
        onPrescanDone = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        os_unfair_lock_lock(lock)
        cancelled = true
        os_unfair_lock_unlock(lock)
        queue.async { [self] in self.teardown() }
    }

    /// 主线程：开关（前瞻 / 预扫描 / 相位拟合）。下一步起生效
    func configure(lookahead: Bool, prescan: Bool, phaseFit: Bool) {
        os_unfair_lock_lock(lock)
        wantLookahead = lookahead
        wantPrescan = prescan
        self.phaseFit = phaseFit
        os_unfair_lock_unlock(lock)
        queue.async { [weak self] in self?.schedulePump(after: 0) }
    }

    /// 主线程：每个完整拍 / seek 后报一下播放头（视频秒）、在不在播、时长
    func notePlayhead(_ seconds: Double, playing: Bool, duration: Double) {
        os_unfair_lock_lock(lock)
        playhead = seconds
        self.playing = playing
        if duration.isFinite, duration > 0 { self.duration = duration }
        os_unfair_lock_unlock(lock)
    }

    /// 主线程：这一拍用的快照（值拷贝；时间轴最多 200 帧）
    func snapshot() -> Snapshot {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Snapshot(timeline: shared, blocked: sharedBlocked, lookNote: sharedLookNote, prescanProgress: sharedProgress,
                        prescanFailed: sharedPrescanFailed)
    }

    private func setBackground(_ on: Bool) {
        os_unfair_lock_lock(lock)
        background = on
        os_unfair_lock_unlock(lock)
        queue.async { [weak self] in self?.schedulePump(after: 0) }
    }

    // MARK: queue

    private func schedulePump(after delay: Double) {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.pumpScheduled = false
            if let next = self.pump() { self.schedulePump(after: next) }
        }
    }

    private func publish(blocked: String?, look: String?) {
        let progress: Double?
        os_unfair_lock_lock(lock)
        let total = duration
        if wantPrescan {
            progress = prescanFinished ? 1 : (total.isFinite && total > 0 ? min(1, max(0, prescan.scanned / total)) : nil)
        } else {
            progress = nil
        }
        // 时间轴没变就不换快照（换了以后读帧这边下一次追加要整份拷贝）
        if shared.records.count != timeline.records.count || shared.head != timeline.head
            || shared.first != timeline.first || shared.segment != timeline.segment
            || shared.origin.bitPattern != timeline.origin.bitPattern {
            shared = timeline
        }
        sharedBlocked = blocked
        sharedLookNote = look
        sharedProgress = progress
        sharedPrescanFailed = preFailures >= Self.maxFailures
        os_unfair_lock_unlock(lock)
    }

    private func teardown() {
        lookReader?.cancelReading()
        lookReader = nil
        lookOutput = nil
        preReader?.cancelReading()
        preReader = nil
        preOutput = nil
        timeline = LookaheadTimeline()
    }

    /// 停掉两路读帧（发热 / 后台）：前瞻清空（回来后从播放头重读），预扫描记下停在哪（回来后接着扫）
    private func suspend() {
        lookReader?.cancelReading()
        lookReader = nil
        lookOutput = nil
        lookEnded = false
        if !timeline.isEmpty || timeline.origin.isFinite { timeline = LookaheadTimeline() }
        if preReader != nil {
            preReader?.cancelReading()
            preReader = nil
            preOutput = nil
            preResumeAt = max(preResumeAt, prescan.scanned)
        }
    }

    /// 一小步；返回下一步多久后做（nil = 不再做）
    private func pump() -> Double? {
        os_unfair_lock_lock(lock)
        let stop = cancelled
        let look = wantLookahead
        let pre = wantPrescan
        let fit = phaseFit
        let v = playhead
        let isPlaying = playing
        let bg = background
        os_unfair_lock_unlock(lock)
        if stop {
            teardown()
            return nil
        }
        guard trackLoaded else { return nil }
        guard track != nil else {
            publish(blocked: "这个视频没有画面轨", look: nil)
            return nil
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if let why = LookaheadThermalPolicy.note(thermal) {
            suspend()
            publish(blocked: why, look: nil)
            return Self.pumpBlocked
        }
        if bg {
            suspend()
            publish(blocked: "App 在后台，已暂停提前读视频", look: nil)
            return Self.pumpBlocked
        }
        let sliceEnd = CACurrentMediaTime() + Self.sliceSeconds
        var note: String?
        var busy = false
        // 1. 前瞻（优先）
        if look, lookFailures < Self.maxFailures {
            let now = CACurrentMediaTime()
            if now < backoffUntil {
                note = "解码跟不上播放，暂停一会儿"
            } else if v.isFinite {
                if lookReader == nil || timeline.needsRestart(playhead: v) {
                    if lookReader != nil || timeline.origin.isFinite { restarts.append(now) }
                    restarts.removeAll { now - $0 > Self.thrashWindow }
                    if restarts.count >= Self.thrashRestarts {
                        restarts.removeAll()
                        backoffUntil = now + Self.thrashBackoff
                        lookReader?.cancelReading()
                        lookReader = nil
                        lookOutput = nil
                        timeline = LookaheadTimeline()
                        note = "解码跟不上播放，暂停一会儿"
                    } else {
                        restartLookahead(at: max(0, v), phaseFit: fit)
                    }
                }
                lookAnalyzer.phaseFitEnabled = fit
                timeline.prune(playhead: v)
                var n = 0
                while lookReader != nil, !lookEnded, timeline.wantsMore(playhead: v), n < Self.lookFramesPerSlice,
                      CACurrentMediaTime() < sliceEnd {
                    pullLookahead()
                    n += 1
                }
                if lookReader != nil, !lookEnded, timeline.wantsMore(playhead: v) { busy = true }
                if lookFailures >= Self.maxFailures { note = "读不了这个视频文件" }
            }
        } else if !look, lookReader != nil || !timeline.isEmpty {
            lookReader?.cancelReading()
            lookReader = nil
            lookOutput = nil
            lookEnded = false
            timeline = LookaheadTimeline()
        } else if look {
            note = "读不了这个视频文件"
        }
        // 2. 预扫描（前瞻不缺帧时）
        if pre, !prescanFinished, preFailures < Self.maxFailures, !busy {
            if preReader == nil { startPrescan() }
            let budget = isPlaying ? Self.prescanFramesPlaying : Self.prescanFramesPaused
            var n = 0
            while preReader != nil, n < budget, CACurrentMediaTime() < sliceEnd {
                pullPrescan()
                n += 1
            }
            if !prescanFinished, preFailures < Self.maxFailures { busy = true }
        } else if !pre, preReader != nil || prescan.windows > 0 || prescanFinished {
            preReader?.cancelReading()
            preReader = nil
            preOutput = nil
            prescan = MotionPrescan()
            preResumeAt = 0
            prescanFinished = false
            preFailures = 0
            preFailedAt = -.infinity
        }
        publish(blocked: nil, look: note)
        // 自审 M：只剩预扫描且已经扫完 / 放弃时没事可做，1 秒醒一次就够（不每 0.1 秒空转）
        let lookIdle = !look || lookFailures >= Self.maxFailures
        let preIdle = !pre || prescanFinished || preFailures >= Self.maxFailures
        if lookIdle && preIdle { return Self.pumpBlocked }
        return busy ? Self.pumpBusy : Self.pumpIdle
    }

    private func makeReader(from start: Double) -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput)? {
        guard let track = track, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        if start > 0.001 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        }
        guard reader.startReading() else { return nil }
        return (reader, output)
    }

    private func restartLookahead(at v: Double, phaseFit fit: Bool) {
        lookReader?.cancelReading()
        lookReader = nil
        lookOutput = nil
        lookEnded = false
        timeline.restart(at: v)
        lookAnalyzer = MotionAnalyzer()
        lookAnalyzer.phaseFitEnabled = fit
        lookLast = -.infinity
        guard let made = makeReader(from: v) else {
            lookFailures += 1
            return
        }
        lookReader = made.reader
        lookOutput = made.output
    }

    private func startPrescan() {
        preAnalyzer = MotionAnalyzer()
        preLast = -.infinity
        guard let made = makeReader(from: preResumeAt) else {
            preFailures += 1
            return
        }
        preReader = made.reader
        preOutput = made.output
    }

    /// 解码下一帧；按 15 Hz 挑帧降采样。返回 (视频时间, 降采样好了没有)；读完 / 出错返回 nil
    private func decode(_ output: AVAssetReaderTrackOutput, last: Double, scaler: inout LumaDownscaler,
                        into frame: inout LumaFrame) -> (time: Double, ok: Bool)? {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard pts.isFinite else { return (last, false) }
        guard pts >= last + Self.frameInterval - 0.004 || pts < last - 1 else { return (pts, false) }
        guard let buffer = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return (pts, false) }
        defer { _ = CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isYUV = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isYUV, CVPixelBufferIsPlanar(buffer), CVPixelBufferGetPlaneCount(buffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return (pts, false) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width > 0, height > 0, rowBytes >= width else { return (pts, false) }
        let luma = UnsafeRawBufferPointer(start: UnsafeRawPointer(base), count: rowBytes * height)
        return (pts, scaler.downscale(luma, width: width, height: height, bytesPerRow: rowBytes, into: &frame))
    }

    private func pullLookahead() {
        guard let output = lookOutput, let reader = lookReader else { return }
        guard let d = decode(output, last: lookLast, scaler: &lookScaler, into: &lookFrame) else {
            if reader.status == .failed {
                lookFailures += 1
                lookReader = nil
                lookOutput = nil
            } else {
                lookEnded = true
            }
            return
        }
        guard d.ok else { return }
        // 自审 M：失败次数只数「连着」的（进后台那一刻读失败之类偶发的不累计到放弃）
        lookFailures = 0
        lookLast = d.time
        if let s = lookAnalyzer.analyze(lookFrame, time: d.time) { timeline.append(s) }
    }

    private func pullPrescan() {
        guard let output = preOutput, let reader = preReader else { return }
        guard let d = decode(output, last: preLast, scaler: &preScaler, into: &preFrame) else {
            preReader = nil
            preOutput = nil
            if reader.status == .completed {
                prescan.finish()
                prescanFinished = true
                let summary = prescan.summary
                DispatchQueue.main.async { [weak self] in self?.onPrescanDone?(summary) }
            } else {
                preFailures += 1
                preResumeAt = max(preResumeAt, prescan.scanned)
                preFailedAt = prescan.scanned
            }
            return
        }
        guard d.ok else { return }
        // 读过上次出错的地方 1 秒以后才清失败次数（同一处反复出错照样 3 次放弃，不会无限重试）
        if d.time > preFailedAt + 1 { preFailures = 0 }
        preLast = d.time
        if let s = preAnalyzer.analyze(preFrame, time: d.time) { prescan.add(s) }
    }
}
