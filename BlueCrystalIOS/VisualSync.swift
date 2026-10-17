import Foundation

// MARK: - 画面联动（视频页 P1）：纯计算，VisualSyncChecks 覆盖。
// 只依赖 Foundation（和 Models.swift 一起能被 swiftc 直接编进检查程序）。取帧在 VideoMotionTap.swift：
// motion 队列 15 Hz 拉一帧 → LumaDownscaler 降到 64×36 → MotionAnalyzer 出一个 MotionSample → VideoMotionMeter 累加；
// 主线程每 0.3 秒取走一次 → MotionNormalizer → MotionShaper → SyncOutputStage → VideoSyncPlayer.tick() 里的
// BLEManager.sendTick（唯一出口，不在这个文件里）。设计见 docs/visual-sync-design.md §4 与 §10 P1：
// 平移补偿、黑边裁剪、字幕降权、声音+画面混合、节奏都是 P2 / P3，P1 不做。

/// 一帧亮度小图（行优先，width × height 个字节）
struct LumaFrame: Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init() {
        width = 0
        height = 0
        pixels = []
    }

    init(width: Int, height: Int, fill: UInt8 = 0) {
        self.width = max(0, width)
        self.height = max(0, height)
        pixels = [UInt8](repeating: fill, count: self.width * self.height)
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Y 平面 → 小图：长边 64，短边按比例取整到 [18, 64]（16:9 → 64×36，9:16 → 36×64）。
/// 每个输出像素只读源块里均匀分布的 4×4 = 16 个点求平均：每帧读的字节数和源分辨率无关。
/// 采样位置表按源尺寸缓存，换尺寸才重算；输出写进调用方给的 frame（尺寸对就复用）
struct LumaDownscaler {
    static let longSide = 64
    static let minShortSide = 18
    static let tapsPerAxis = 4

    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourceRowBytes = 0
    private var columnTaps: [Int] = []
    private var rowOffsets: [Int] = []

    static func outputSize(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let long = Double(longSide)
        if width >= height {
            let h = Int((long * Double(height) / Double(width)).rounded())
            return (longSide, min(longSide, max(minShortSide, h)))
        }
        let w = Int((long * Double(width) / Double(height)).rounded())
        return (min(longSide, max(minShortSide, w)), longSide)
    }

    /// 一个轴上 n 个输出像素 × 4 个采样点在源图里的坐标（块内均匀分布，源图比输出小时重复取同一点，不越界）
    static func tapPositions(output n: Int, source s: Int) -> [Int] {
        let k = tapsPerAxis
        return (0..<(n * k)).map { i in min(s - 1, (2 * i + 1) * s / (2 * n * k)) }
    }

    /// src：plane 0 的基址开始、至少 (height - 1) × bytesPerRow + width 个字节。尺寸不对返回 false，frame 不动
    mutating func downscale(_ src: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                            into frame: inout LumaFrame) -> Bool {
        guard let size = Self.outputSize(width: width, height: height), bytesPerRow >= width,
              src.baseAddress != nil else { return false }
        let (lastRow, overflow) = (height - 1).multipliedReportingOverflow(by: bytesPerRow)
        guard !overflow, lastRow <= Int.max - width, lastRow + width <= src.count else { return false }
        let k = Self.tapsPerAxis
        if width != sourceWidth || height != sourceHeight || bytesPerRow != sourceRowBytes
            || columnTaps.count != size.width * k || rowOffsets.count != size.height * k {
            columnTaps = Self.tapPositions(output: size.width, source: width)
            rowOffsets = Self.tapPositions(output: size.height, source: height).map { $0 * bytesPerRow }
            sourceWidth = width
            sourceHeight = height
            sourceRowBytes = bytesPerRow
        }
        if frame.width != size.width || frame.height != size.height || frame.pixels.count != size.width * size.height {
            frame = LumaFrame(width: size.width, height: size.height)
        }
        let ow = size.width
        let oh = size.height
        let area = k * k
        // 采样表用裸指针读（algo-opt-1 性能卫生：省掉数组下标的边界检查 / 引用计数，结果逐位不变）
        columnTaps.withUnsafeBufferPointer { cols in
            rowOffsets.withUnsafeBufferPointer { rows in
                frame.pixels.withUnsafeMutableBufferPointer { out in
                    for oy in 0..<oh {
                        for ox in 0..<ow {
                            var sum = 0
                            for j in 0..<k {
                                let row = rows[oy * k + j]
                                for i in 0..<k {
                                    sum += Int(src[row + cols[ox * k + i]])
                                }
                            }
                            out[oy * ow + ox] = UInt8((sum + area / 2) / area)
                        }
                    }
                }
            }
        }
        return true
    }
}

/// 一帧的分析结果（相对上一帧）
struct MotionSample: Equatable {
    /// 取帧时刻（host 时间，秒）
    var time: Double
    /// 主体运动能量（亮度级；切换 / 保持期内是最近 1 秒的中位数）
    var energy: Double
    /// 8×6 格里有明显运动的格子占比 0...1
    var coverage: Double
    /// 这一帧判为镜头切换 / 闪白闪黑
    var isCut: Bool
    /// 切换之后的保持期（新镜头前两帧编码质量差，能量也用中位数）
    var isHeld: Bool
    /// 近场 / 遮挡分数 0~1（algo-opt-1）：手 / 物体贴近镜头、大面积遮挡、贴脸晃动的镜头。
    /// 只用来让 MotionNormalizer 少放大、少学习：同一拍里只降不升；不学参考值会让之后的正常画面比不跳过时略高，
    /// 但仍在 上限 / 升幅限速 / 夹紧 之内
    var nearField: Double = 0
    /// 主体运动读数（algo-opt-3）：块运动扣掉相机运动后的速度 + 往复节奏。手搭的样本不填 = 无效，走原来的能量映射
    var subject = SubjectReading()
    /// rhythm-context P3：周期区域里的高分辨率块运动读数（动作识别关着 / 没有可信区域时无效）
    var roi = RoiReading()
}

/// 整体位移搜索的结果
struct MotionShift: Equatable {
    var dx = 0
    var dy = 0
    /// 这一帧满足条件、真的搜过
    var searched = false
    /// 最好的对齐后差异 / 不对齐差异（搜过才有意义；越小越像纯平移）
    var ratio: Double = 1

    var accepted: Bool { dx != 0 || dy != 0 }
}

/// 帧差 → 运动能量（§4.3），直方图 + 均值突变判镜头切换 / 闪白（§4.5）。
/// 镜头平移 / 手持晃动补偿（§4.4 简化版）：大半画面都在变时，试 ±3 像素整体位移，能明显对齐就按对齐后的帧差算
/// 第一帧、reset 之后、尺寸变了、相邻样本 Δt 不在 [0.03, 0.5] 秒（倒退 / 跳跃 / 长时间没帧）都只当参考帧，不出样本
struct MotionAnalyzer {
    /// 每像素噪声门（0~255 亮度级；4×4 平均后压缩噪声约 ±2~3）
    static let noiseGate: Double = 4
    static let gridColumns = 8
    static let gridRows = 6
    /// 格平均能量超过它算「这一格在动」
    static let activeCellEnergy: Double = 2
    static let histogramBins = 16
    /// 切换：直方图距离 > 0.45 且能量 > 2.5 × 最近 2 秒中位数；或直方图距离 > 0.65；或整体均值一帧突变 > 60（闪白 / 闪黑）
    static let cutDistance: Double = 0.45
    static let cutDistanceAlways: Double = 0.65
    static let cutEnergyRatio: Double = 2.5
    static let flashMeanJump: Double = 60
    /// 切换后再有这么多个样本用中位数
    static let holdSamples = 2
    static let gapRange: ClosedRange<Double> = 0.03...0.5
    /// 拉帧间隔不稳时按真实间隔归一能量（1/15 秒为基准，系数夹在 0.5~2）
    static let nominalInterval: Double = 1.0 / 15
    static let rateCorrection: ClosedRange<Double> = 0.5...2
    /// 切换帧的替代值取最近 1 秒中位数；切换判定的基准取最近 2 秒中位数
    static let substituteWindow: Double = 1
    static let baselineWindow: Double = 2
    static let historyCapacity = 64
    /// 整体位移搜索范围（分析帧像素，64×36 上 ±3 ≈ 原画面 ±5%）
    static let maxShift = 3
    /// 有变化的格子超过这个比例才试补偿（小物体移动不碰）
    static let shiftChangedCells: Double = 0.5
    /// 对齐后的差异要低于不对齐的这个比例才采用
    static let shiftAcceptRatio: Double = 0.75
    /// 近场 / 遮挡分数（algo-opt-1）：背景直方图 / 清晰度按 4 秒跟踪；判为近场时最多冻结 6 秒不学；
    /// 平移采用率 / 对齐残差按 1 秒跟踪
    static let backgroundSeconds: TimeInterval = 4
    static let nearFreezeLimit: TimeInterval = 6
    static let cameraSeconds: TimeInterval = 1
    /// 背景清晰度低于这个（本来就糊 / 纯色画面）不用「变糊」这一项
    static let minBackgroundSharpness: Double = 2
    static let nearFieldDeadzone: Double = 0.05
    /// 切镜 / 闪变之后（第二轮审查 M1）：手一下盖住镜头也会触发切镜判定，所以切镜不立刻把新画面当背景，
    /// 而是保留切镜前的背景继续比（最长 nearFreezeLimit）。新画面「安静」（近场 ≤ 0.5 或覆盖率 < 0.35）
    /// 连续这么久才采用为背景；超过 nearFreezeLimit 无条件采用
    static let cutAdoptSeconds: TimeInterval = 0.5
    static let cutCalmCoverage: Double = 0.35
    /// 切镜待定期间直方图项要「同时变糊」才算数：真实切到清晰的新场景（颜色分布也变了）很快恢复，
    /// 手 / 物体贴镜头（失焦）照样判为近场。width 0.07、center 0.15 的变糊门
    static let cutBlurCenter: Double = 0.15
    static let cutBlurWidth: Double = 0.07
    /// 帧差中位数用的直方图：差值 -255...255
    static let diffBins = 511
    /// 软切（algo-opt-2）：切镜待定 / 近场冻结期间，新画面「整幅都换了（出事前有纹理的格子原样留着的不超过 5%）
    /// + 帧间稳定（整体亮度、颜色分布、清晰度都没在跳）+ 动得不多 + 不是又暗又平」就当成切到本身偏糊的新镜头，
    /// 连续 cutAdoptSeconds 就采用为背景（约 0.6~0.75 秒恢复，原来最长 6 秒）。
    /// 手 / 物体贴镜头通常留着一部分原来的背景、边缘在动、亮度和清晰度一帧一帧跳，不满足
    static let softCutMaxEnergy: Double = 8
    static let softCutMeanStep: Double = 4
    static let softCutHistogramStep: Double = 0.12
    static let softCutSharpnessStep: Double = 0.2
    static let softCutMaxRetained: Double = 0.05
    /// 格平均 |现在 − 出事前| 不超过它、且出事前这一格有纹理（平均相邻差 ≥ retainedCellTexture，黑边 / 纯色不算）= 背景原样留着
    static let retainedCellDiff: Double = 6
    static let retainedCellTexture: Double = 4
    /// 平均亮度低于它且清晰度低于 minBackgroundSharpness：镜头被整个捂住，不算软切
    static let occluderMean: Double = 40
    /// 整体对比度变化补偿（algo-opt-2）：渐黑 / 渐亮、自动曝光、闪光这类「整幅按比例变亮变暗」，减中位数只能去掉加性的那部分，
    /// 有纹理的画面上会留下假运动。两帧亮度标准差之比 g 偏离 1 至少 8%（在 0.5~2 内、两帧标准差都 ≥ 4）时，
    /// 按 cur − g·prev 再算一次，残差不到原来的一半才采用（真实动作解释不掉，照旧）；偏离不到 8% 时逐位不变
    static let contrastEngage: Double = 0.08
    static let contrastRange: ClosedRange<Double> = 0.5...2
    static let contrastMinDeviation: Double = 4
    static let contrastAcceptRatio: Double = 0.5

    private var previous: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0
    private var previousMean: Double = 0
    private var previousSharpness: Double = 0
    private var previousHistogram: [Double] = []
    private var previousTime: Double?
    private var holdRemaining = 0
    private var historyTimes: [Double] = []
    private var historyEnergies: [Double] = []
    private var cellWidth = 0
    private var cellHeight = 0
    private var cellOf: [Int] = []
    private var cellPixels: [Double] = []
    // 近场跟踪
    private var backgroundHistogram = [Double](repeating: 0, count: MotionAnalyzer.histogramBins)
    private var backgroundSharpness: Double = 0
    private var backgroundValid = false
    private var backgroundFrozen: TimeInterval = 0
    /// 切镜之后背景待定：仍用切镜前的背景；elapsed 从第一次切镜起算，calm 是新画面连续安静的时长
    private var cutPending = false
    private var cutPendingElapsed: TimeInterval = 0
    private var cutPendingCalm: TimeInterval = 0
    private var shiftRate: Double = 0
    private var residualRatio: Double = 0
    /// 软切判定（algo-opt-2）：切镜待定 / 近场冻结开始时记下的上一帧（出事前的画面）和它每格的纹理；
    /// softRun 是近场冻结期间新画面连续像软切的时长
    private var suspectReference: [UInt8] = []
    private var suspectTexture = [Double](repeating: 0, count: MotionAnalyzer.gridColumns * MotionAnalyzer.gridRows)
    private var suspectValid = false
    private var softRun: TimeInterval = 0
    // 每帧复用的临时数组（algo-opt-1 / algo-opt-2 性能卫生：稳态不再每帧分配）
    private var histogram = [Double](repeating: 0, count: MotionAnalyzer.histogramBins)
    private var cellSums = [Double](repeating: 0, count: MotionAnalyzer.gridColumns * MotionAnalyzer.gridRows)
    private var cellSumsAlt = [Double](repeating: 0, count: MotionAnalyzer.gridColumns * MotionAnalyzer.gridRows)
    private var cellScratch = [Double](repeating: 0, count: MotionAnalyzer.gridColumns * MotionAnalyzer.gridRows)
    /// globalShift 的每格差异和 / 采样数（前后两半）
    private var shiftScratch = [Double](repeating: 0, count: 2 * MotionAnalyzer.gridColumns * MotionAnalyzer.gridRows)
    private var diffHistogram = [Int](repeating: 0, count: MotionAnalyzer.diffBins)
    private var medianScratch: [Double] = []

    // 主体运动（algo-opt-3）
    private var blocks = BlockMotionEstimator()
    private var subjectTracker = SubjectFlowTracker()
    /// 上一次 analyze 那个帧间隔的相机运动（algo-opt-3；姿态估计用它扣掉镜头运动）。没判为相机在动时 identity
    private(set) var lastCamera = CameraTransform.identity
    /// lastCamera 和上一帧连得上：参考帧 / 切镜 / 保持期 / reset 之后为 false（姿态不跨这些点算速度）
    private(set) var cameraContinuous = false
    /// 上一次块运动的结果（VisualSyncChecks 用）
    private(set) var lastBlockMotion = BlockMotionResult()

    /// 整体对比度补偿开关：只给 VisualSyncChecks 做对照（App 里一直开着）
    var compensatesContrast = true

    /// rhythm-context P3（L1）：主体相位拟合开关（VideoMotionTap 按「相位脉动」设；默认关 = 不算相位）
    var phaseFitEnabled: Bool {
        get { subjectTracker.phaseFitEnabled }
        set { subjectTracker.phaseFitEnabled = newValue }
    }
    /// rhythm-context P3：动作识别开着时才攒每块的运动、算周期区域（默认关 = 不攒、不算）
    var contextEnabled = false {
        didSet { if !contextEnabled { periodicity.reset() } }
    }
    /// rhythm-context P3：周期区域
    private(set) var periodicity = PeriodicityMap()
    /// rhythm-action tune：动作识别开着时 VideoMotionTap 打开（默认关 = 逐位不变）：
    /// 块运动的噪声防护（BlockMotionEstimator.noiseGuard）+ 周期区域要稳定、占主要份额才算（PeriodicityMap.stabilityGuard）
    var actionTuned: Bool {
        get { blocks.noiseGuard }
        set {
            blocks.noiseGuard = newValue
            periodicity.stabilityGuard = newValue
        }
    }

    var hasReference: Bool { previousTime != nil }
    /// 切镜后还在用切镜前的背景（新画面还没被采用为背景）
    var isBackgroundPending: Bool { cutPending }

    /// 每帧复用的缓冲的存储地址（VisualSyncChecks 用来确认稳态不重新分配；只在测试里调）
    var scratchAddresses: [Int] {
        func address<T>(_ a: [T]) -> Int { a.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        return [address(previous), address(previousHistogram), address(historyTimes), address(historyEnergies),
                address(suspectReference), address(suspectTexture), address(histogram), address(cellSums),
                address(cellSumsAlt), address(cellScratch), address(shiftScratch), address(diffHistogram),
                address(medianScratch)] + blocks.scratchAddresses + subjectTracker.scratchAddresses
    }

    init() {
        historyTimes.reserveCapacity(Self.historyCapacity + 1)
        historyEnergies.reserveCapacity(Self.historyCapacity + 1)
        medianScratch.reserveCapacity(Self.historyCapacity + 1)
    }

    /// 丢掉参考帧和历史（seek / 开播 / 不连续）：下一帧只当参考帧。参考帧的存储留着复用（previousTime == nil 就不会被读）
    mutating func reset() {
        previousTime = nil
        holdRemaining = 0
        historyTimes.removeAll(keepingCapacity: true)
        historyEnergies.removeAll(keepingCapacity: true)
        backgroundValid = false
        backgroundFrozen = 0
        cutPending = false
        suspectValid = false
        softRun = 0
        shiftRate = 0
        residualRatio = 0
        subjectTracker.reset()
        lastCamera = .identity
        cameraContinuous = false
        lastBlockMotion = BlockMotionResult()
        periodicity.reset()
    }

    private static func sigmoid(_ x: Double, _ center: Double, _ width: Double) -> Double {
        1 / (1 + exp(-(x - center) / width))
    }

    /// 清晰度：相邻像素横向 + 纵向亮度差的平均（手贴镜头 / 失焦遮挡时明显下降）
    static func sharpness(_ p: UnsafeBufferPointer<UInt8>, width w: Int, height h: Int) -> Double {
        guard w > 1, h > 1 else { return 0 }
        var total = 0
        for y in 0..<(h - 1) {
            let row = y * w
            for x in 0..<(w - 1) {
                let v = Int(p[row + x])
                total += abs(Int(p[row + x + 1]) - v) + abs(Int(p[row + w + x]) - v)
            }
        }
        return Double(total) / Double((w - 1) * (h - 1))
    }

    private mutating func resetBackground(sharpness g: Double) {
        for b in 0..<Self.histogramBins { backgroundHistogram[b] = histogram[b] }
        backgroundSharpness = g
        backgroundValid = true
        backgroundFrozen = 0
        cutPending = false
        cutPendingElapsed = 0
        cutPendingCalm = 0
        suspectValid = false
        softRun = 0
    }

    /// 切镜 / 切镜后的保持帧：背景不换成新画面，进入（或继续）待定。没有有效背景时才直接用新画面
    private mutating func noteCutForBackground(sharpness g: Double, gap: Double) {
        guard backgroundValid else {
            resetBackground(sharpness: g)
            return
        }
        if cutPending {
            cutPendingElapsed += gap
        } else {
            cutPending = true
            cutPendingElapsed = 0
            // 这时 previous 还是切镜前的最后一帧
            captureSuspectReference()
        }
        cutPendingCalm = 0
        if cutPendingElapsed >= Self.nearFreezeLimit { resetBackground(sharpness: g) }
    }

    mutating func analyze(_ frame: LumaFrame, time: Double) -> MotionSample? {
        let w = frame.width
        let h = frame.height
        let n = w * h
        guard w > 0, h > 0, frame.pixels.count == n, time.isFinite else {
            reset()
            return nil
        }
        let pixels = frame.pixels
        for b in 0..<Self.histogramBins { histogram[b] = 0 }
        var sum = 0
        var sharp = 0.0
        pixels.withUnsafeBufferPointer { p in
            histogram.withUnsafeMutableBufferPointer { hist in
                for v in p {
                    sum += Int(v)
                    hist[Int(v) >> 4] += 1
                }
            }
            sharp = Self.sharpness(p, width: w, height: h)
        }
        let inv = 1 / Double(n)
        for b in 0..<Self.histogramBins { histogram[b] *= inv }
        let mean = Double(sum) * inv

        guard let lastTime = previousTime, previousWidth == w, previousHeight == h, previous.count == n,
              previousHistogram.count == Self.histogramBins, Self.gapRange.contains(time - lastTime) else {
            reset()
            resetBackground(sharpness: sharp)
            remember(pixels, width: w, height: h, mean: mean, sharpness: sharp, time: time)
            return nil
        }
        let gap = time - lastTime
        if cellWidth != w || cellHeight != h { buildCells(width: w, height: h) }

        // 帧差 + 噪声门。整体位移的选择仍按去均值（保持原来的平移判定）；
        // 能量 / 覆盖率改减「对齐后帧差的中位数」（algo-opt-1）：整体变亮变暗照样几乎没有贡献，
        // 但局部变暗（窗帘、阴影、半边画面变化）不会再把另一半没动的画面也算成在动
        let prevMean = previousMean
        let gate = Self.noiseGate
        let shift = Self.globalShift(pixels, mean: mean, previous: previous, previousMean: prevMean,
                                     width: w, height: h, cells: cellOf, scratch: &shiftScratch)
        let dx = shift.dx
        let dy = shift.dy
        let x0 = max(0, dx)
        let x1 = min(w, w + dx)
        let y0 = max(0, dy)
        let y1 = min(h, h + dy)
        for b in 0..<Self.diffBins { diffHistogram[b] = 0 }
        for c in 0..<cellSums.count { cellSums[c] = 0 }
        var total = 0.0
        var valid = 0
        // 重叠区的一阶 / 二阶矩：整体对比度补偿用（algo-opt-2）
        var sumCur = 0
        var sumPrev = 0
        var sumCurSq = 0
        var sumPrevSq = 0
        previous.withUnsafeBufferPointer { prev in
            pixels.withUnsafeBufferPointer { cur in
                diffHistogram.withUnsafeMutableBufferPointer { dh in
                    for y in y0..<max(y0, y1) {
                        let row = y * w
                        let prow = (y - dy) * w - dx
                        for x in x0..<max(x0, x1) {
                            let c = Int(cur[row + x])
                            let p = Int(prev[prow + x])
                            dh[c - p + 255] += 1
                            sumCur += c
                            sumPrev += p
                            sumCurSq += c * c
                            sumPrevSq += p * p
                        }
                    }
                }
                valid = max(0, x1 - x0) * max(0, y1 - y0)
                let offset = Self.histogramMedian(diffHistogram, count: valid) - 255
                cellOf.withUnsafeBufferPointer { cells in
                    cellSums.withUnsafeMutableBufferPointer { cs in
                        for y in y0..<max(y0, y1) {
                            let row = y * w
                            let prow = (y - dy) * w - dx
                            for x in x0..<max(x0, x1) {
                                let d = Double(Int(cur[row + x]) - Int(prev[prow + x])) - offset
                                let e = abs(d) - gate
                                if e > 0 {
                                    total += e
                                    cs[cells[row + x]] += e
                                }
                            }
                        }
                    }
                }
            }
        }
        // 整体按比例变亮 / 变暗（渐黑、自动曝光、闪光）：按 cur − g·prev 再算一次，明显更小才采用（algo-opt-2）
        if compensatesContrast, total > 0,
           let model = Self.contrastModel(sumCur: sumCur, sumPrev: sumPrev, sumCurSq: sumCurSq,
                                          sumPrevSq: sumPrevSq, count: valid) {
            let alt = contrastResidual(pixels, gain: model.gain, bias: model.bias, dx: dx, dy: dy, width: w,
                                       x0: x0, x1: x1, y0: y0, y1: y1, valid: valid)
            if alt < Self.contrastAcceptRatio * total {
                total = alt
                for c in 0..<cellSums.count { cellSums[c] = cellSumsAlt[c] }
            }
        }
        var active = 0
        for c in 0..<cellSums.count where cellPixels[c] > 0 && cellSums[c] / cellPixels[c] > Self.activeCellEnergy {
            active += 1
        }
        let coverage = Double(active) / Double(cellSums.count)

        var distance = 0.0
        for b in 0..<Self.histogramBins { distance += abs(histogram[b] - previousHistogram[b]) }
        distance *= 0.5

        let correction = min(Self.rateCorrection.upperBound,
                             max(Self.rateCorrection.lowerBound, Self.nominalInterval / gap))
        let energy = valid > 0 ? total / Double(valid) * correction : 0
        let baseline = median(within: Self.baselineWindow, now: time)
        let jump = abs(mean - prevMean)
        let hardCut = distance > Self.cutDistanceAlways
        let likelyCut = distance > Self.cutDistance && energy > Self.cutEnergyRatio * baseline
        let flash = jump > Self.flashMeanJump
        let isCut = hardCut || likelyCut || flash

        var out = energy
        var held = false
        var near = 0.0
        var subject: SubjectReading
        if isCut {
            // 不出尖峰，也不突然掉到 0
            out = median(within: Self.substituteWindow, now: time)
            holdRemaining = Self.holdSamples
            noteCutForBackground(sharpness: sharp, gap: gap)
            // 主体读数保持切镜前的，新镜头重新攒（algo-opt-3）
            subjectTracker.noteCut()
            subject = subjectTracker.reading
            noteCameraBreak()
            periodicity.reset()
        } else if holdRemaining > 0 {
            out = median(within: Self.substituteWindow, now: time)
            holdRemaining -= 1
            held = true
            noteCutForBackground(sharpness: sharp, gap: gap)
            subject = subjectTracker.reading
            noteCameraBreak()
        } else {
            record(energy, at: time)
            var soft = false
            if suspectValid {
                soft = isSoftCut(pixels, mean: mean, sharpness: sharp, jump: jump, distance: distance, energy: energy)
            }
            near = updateNearField(coverage: coverage, sharpness: sharp, shift: shift, gap: gap, softCut: soft)
            // 块运动：扣掉相机运动后主体自己的速度 / 节奏（algo-opt-3）
            let flow = previous.withUnsafeBufferPointer { prev in
                pixels.withUnsafeBufferPointer { cur in
                    blocks.estimate(cur: cur, prev: prev, width: w, height: h, gap: gap)
                }
            }
            lastBlockMotion = flow
            lastCamera = flow.camera
            cameraContinuous = true
            subject = subjectTracker.update(time: time, speed: flow.speed, vx: flow.vx, vy: flow.vy)
            if contextEnabled {
                periodicity.add(time: time, blocks: blocks, gap: gap)
                periodicity.update(hz: subject.followHz > 0 ? subject.followHz : subject.hz, now: time)
            }
        }
        remember(pixels, width: w, height: h, mean: mean, sharpness: sharp, time: time)
        return MotionSample(time: time, energy: out, coverage: coverage, isCut: isCut, isHeld: held, nearField: near,
                            subject: subject)
    }

    private mutating func noteCameraBreak() {
        lastCamera = .identity
        cameraContinuous = false
        lastBlockMotion = BlockMotionResult()
    }

    /// 近场 / 遮挡分数（algo-opt-1）：
    /// 遮挡 = 大面积在动 × (画面颜色分布和最近背景差很多 或 明显变糊)；
    /// 贴脸晃动 = 大面积在动 × 经常需要平移补偿 × 补偿后仍对不齐（视差大）。两者取大，< 0.05 当 0。
    /// softCut：这一帧像「切到本身偏糊的新镜头」（algo-opt-2，见 isSoftCut），只用来更早采用新背景，不会让分数变高
    private mutating func updateNearField(coverage c: Double, sharpness g: Double, shift: MotionShift,
                                          gap: Double, softCut: Bool) -> Double {
        if !backgroundValid { resetBackground(sharpness: g) }
        var hDist = 0.0
        for b in 0..<Self.histogramBins { hDist += abs(histogram[b] - backgroundHistogram[b]) }
        hDist *= 0.5
        let blurTerm = backgroundSharpness >= Self.minBackgroundSharpness
            ? Self.sigmoid(1 - g / backgroundSharpness, 0.35, 0.1) : 0
        let wide = Self.sigmoid(c, 0.5, 0.1)
        var histTerm = Self.sigmoid(hDist, 0.35, 0.07)
        if cutPending {
            // 切镜待定：颜色分布变了还要同时变糊才算遮挡（清晰的新场景不算）
            let blurGate = backgroundSharpness >= Self.minBackgroundSharpness
                ? Self.sigmoid(1 - g / backgroundSharpness, Self.cutBlurCenter, Self.cutBlurWidth) : 0
            histTerm *= blurGate
        }
        let occlusion = wide * max(histTerm, blurTerm)

        let camA = 1 - exp(-gap / Self.cameraSeconds)
        shiftRate += ((shift.accepted ? 1 : 0) - shiftRate) * camA
        if shift.searched, shift.ratio.isFinite { residualRatio += (min(1, max(0, shift.ratio)) - residualRatio) * camA }
        let camera = wide * Self.sigmoid(shiftRate, 0.5, 0.15) * Self.sigmoid(residualRatio, 0.45, 0.08)

        var near = max(occlusion, camera)
        if !near.isFinite || near < Self.nearFieldDeadzone { near = 0 }
        near = min(1, near)

        if cutPending {
            // 切镜待定：背景不动；新画面连续安静 0.5 秒（真实切镜、手停住、软切）或待定满 nearFreezeLimit 才采用
            cutPendingElapsed += gap
            let calm = near <= 0.5 || c < Self.cutCalmCoverage || softCut
            cutPendingCalm = calm ? cutPendingCalm + gap : 0
            if cutPendingCalm >= Self.cutAdoptSeconds || cutPendingElapsed >= Self.nearFreezeLimit {
                resetBackground(sharpness: g)
            }
        } else {
            // 近场冻结开始时记下上一帧（出事前的画面），之后看新画面是不是整幅换成了稳定的偏糊镜头（没被识别成切镜的软切）
            if near > 0.5 {
                if !suspectValid { captureSuspectReference() }
                softRun = softCut ? softRun + gap : 0
            } else {
                suspectValid = false
                softRun = 0
            }
            if near > 0.5 && softRun >= Self.cutAdoptSeconds {
                // 软切：不等冻结满 6 秒，直接采用新画面为背景
                resetBackground(sharpness: g)
            } else if near > 0.5 && backgroundFrozen < Self.nearFreezeLimit {
                // 背景：判为近场时先冻结（最多 6 秒），否则按 4 秒跟上
                backgroundFrozen += gap
            } else {
                if near <= 0.5 { backgroundFrozen = 0 }
                let a = 1 - exp(-gap / Self.backgroundSeconds)
                for b in 0..<Self.histogramBins { backgroundHistogram[b] += (histogram[b] - backgroundHistogram[b]) * a }
                backgroundSharpness += (g - backgroundSharpness) * a
            }
        }
        if !shiftRate.isFinite || !residualRatio.isFinite || !backgroundSharpness.isFinite {
            shiftRate = 0
            residualRatio = 0
            backgroundValid = false
        }
        return near
    }

    /// 记下「出事前」的一帧（切镜 / 近场冻结开始时的上一帧）和它每格的纹理（平均横向 + 纵向相邻差）。
    /// 尺寸没变就拷进已有存储（不每次分配）
    private mutating func captureSuspectReference() {
        let cellCount = Self.gridColumns * Self.gridRows
        let w = previousWidth
        let h = previousHeight
        guard w > 0, h > 0, previous.count == w * h, cellOf.count == w * h, cellPixels.count == cellCount,
              suspectTexture.count == cellCount else {
            suspectValid = false
            return
        }
        if suspectReference.count == previous.count {
            suspectReference.withUnsafeMutableBufferPointer { dst in
                previous.withUnsafeBufferPointer { src in
                    if let d = dst.baseAddress, let s = src.baseAddress { d.update(from: s, count: src.count) }
                }
            }
        } else {
            suspectReference = previous
            suspectReference.reserveCapacity(previous.count)
        }
        for c in 0..<cellCount { suspectTexture[c] = 0 }
        suspectReference.withUnsafeBufferPointer { p in
            cellOf.withUnsafeBufferPointer { cells in
                suspectTexture.withUnsafeMutableBufferPointer { tex in
                    for y in 0..<h {
                        let row = y * w
                        for x in 0..<w {
                            let i = row + x
                            let v = Int(p[i])
                            var g = 0
                            if x + 1 < w { g += abs(Int(p[i + 1]) - v) }
                            if y + 1 < h { g += abs(Int(p[i + w]) - v) }
                            tex[cells[i]] += Double(g)
                        }
                    }
                }
            }
        }
        for c in 0..<cellCount where cellPixels[c] > 0 { suspectTexture[c] /= cellPixels[c] }
        suspectValid = true
        softRun = 0
    }

    /// 这一帧像不像「切到本身偏糊的新镜头」（algo-opt-2）：动得不多、和上一帧比整体亮度 / 颜色分布 / 清晰度都稳定、
    /// 不是又暗又平（镜头被捂住），而且出事前有纹理的格子几乎没有原样留着（整幅都换了，不是挡住一部分）
    private mutating func isSoftCut(_ pixels: [UInt8], mean: Double, sharpness g: Double, jump: Double,
                                    distance: Double, energy: Double) -> Bool {
        let sharpStep = abs(g - previousSharpness) / max(previousSharpness, Self.minBackgroundSharpness)
        guard energy.isFinite, energy <= Self.softCutMaxEnergy, jump <= Self.softCutMeanStep,
              distance <= Self.softCutHistogramStep, sharpStep.isFinite, sharpStep <= Self.softCutSharpnessStep else {
            return false
        }
        if mean < Self.occluderMean && g < Self.minBackgroundSharpness { return false }
        return retainedFraction(pixels) <= Self.softCutMaxRetained
    }

    /// 出事前有纹理、现在还原样留着的格子占全部格子的比例（手 / 物体只挡住一部分时，没挡住的背景还在原处）。
    /// 参考帧不可用时返回 1（当作留着，不判软切）
    private mutating func retainedFraction(_ pixels: [UInt8]) -> Double {
        let cellCount = Self.gridColumns * Self.gridRows
        guard suspectValid, suspectReference.count == pixels.count, cellOf.count == pixels.count,
              cellPixels.count == cellCount, cellScratch.count == cellCount, suspectTexture.count == cellCount else {
            return 1
        }
        for c in 0..<cellCount { cellScratch[c] = 0 }
        suspectReference.withUnsafeBufferPointer { ref in
            pixels.withUnsafeBufferPointer { cur in
                cellOf.withUnsafeBufferPointer { cells in
                    cellScratch.withUnsafeMutableBufferPointer { cs in
                        for i in 0..<cur.count { cs[cells[i]] += Double(abs(Int(cur[i]) - Int(ref[i]))) }
                    }
                }
            }
        }
        var retained = 0
        for c in 0..<cellCount where cellPixels[c] > 0 && suspectTexture[c] >= Self.retainedCellTexture
            && cellScratch[c] / cellPixels[c] <= Self.retainedCellDiff {
            retained += 1
        }
        return Double(retained) / Double(cellCount)
    }

    /// 整体对比度模型 cur ≈ gain·prev + bias（gain = 两帧亮度标准差之比）。偏离 1 不到 contrastEngage、
    /// 超出 contrastRange、任一帧太平（标准差 < contrastMinDeviation）时 nil（不补偿）
    static func contrastModel(sumCur: Int, sumPrev: Int, sumCurSq: Int, sumPrevSq: Int,
                              count: Int) -> (gain: Double, bias: Double)? {
        guard count > 0 else { return nil }
        let inv = 1 / Double(count)
        let meanCur = Double(sumCur) * inv
        let meanPrev = Double(sumPrev) * inv
        let devCur = max(0, Double(sumCurSq) * inv - meanCur * meanCur).squareRoot()
        let devPrev = max(0, Double(sumPrevSq) * inv - meanPrev * meanPrev).squareRoot()
        guard devCur >= contrastMinDeviation, devPrev >= contrastMinDeviation else { return nil }
        let gain = devCur / devPrev
        guard gain.isFinite, abs(gain - 1) >= contrastEngage, contrastRange.contains(gain) else { return nil }
        return (gain: gain, bias: meanCur - gain * meanPrev)
    }

    /// 按 cur − gain·prev − bias 重算残差（同样减中位数、过噪声门），每格能量写进 cellSumsAlt，返回总能量
    private mutating func contrastResidual(_ pixels: [UInt8], gain: Double, bias: Double, dx: Int, dy: Int,
                                           width w: Int, x0: Int, x1: Int, y0: Int, y1: Int, valid: Int) -> Double {
        for b in 0..<Self.diffBins { diffHistogram[b] = 0 }
        for c in 0..<cellSumsAlt.count { cellSumsAlt[c] = 0 }
        let gate = Self.noiseGate
        var total = 0.0
        previous.withUnsafeBufferPointer { prev in
            pixels.withUnsafeBufferPointer { cur in
                diffHistogram.withUnsafeMutableBufferPointer { dh in
                    for y in y0..<max(y0, y1) {
                        let row = y * w
                        let prow = (y - dy) * w - dx
                        for x in x0..<max(x0, x1) {
                            let q = (Double(cur[row + x]) - gain * Double(prev[prow + x]) - bias).rounded()
                            dh[Int(min(255, max(-255, q))) + 255] += 1
                        }
                    }
                }
                let offset = Self.histogramMedian(diffHistogram, count: valid) - 255
                cellOf.withUnsafeBufferPointer { cells in
                    cellSumsAlt.withUnsafeMutableBufferPointer { cs in
                        for y in y0..<max(y0, y1) {
                            let row = y * w
                            let prow = (y - dy) * w - dx
                            for x in x0..<max(x0, x1) {
                                let d = Double(cur[row + x]) - gain * Double(prev[prow + x]) - bias - offset
                                let e = abs(d) - gate
                                if e > 0 {
                                    total += e
                                    cs[cells[row + x]] += e
                                }
                            }
                        }
                    }
                }
            }
        }
        return total
    }

    /// 直方图中位数（偶数个取中间两个的平均）；count == 0 时返回 255（差值 0）
    static func histogramMedian(_ hist: [Int], count: Int) -> Double {
        guard count > 0 else { return 255 }
        let lowRank = (count - 1) / 2
        let highRank = count / 2
        var seen = 0
        var low = -1
        for b in 0..<hist.count {
            seen += hist[b]
            if low < 0 && seen > lowRank { low = b }
            if seen > highRank { return Double(low + b) / 2 }
        }
        return low >= 0 ? Double(low) : 255
    }

    /// 没有新帧但播放头在走（VFR 静止段）：当作一帧完全没动的画面，刷新参考时间，记零能量
    mutating func still(at time: Double) -> MotionSample? {
        guard let last = previousTime, time.isFinite, Self.gapRange.contains(time - last) else { return nil }
        previousTime = time
        let held = holdRemaining > 0
        if held {
            holdRemaining -= 1
        } else {
            record(0, at: time)
        }
        let out = held ? median(within: Self.substituteWindow, now: time) : 0
        // 画面没变：相机不动、主体速度 0（保持期内读数不变）
        lastCamera = .identity
        let subject = held ? subjectTracker.reading : subjectTracker.update(time: time, speed: 0, vx: 0, vy: 0)
        return MotionSample(time: time, energy: out, coverage: 0, isCut: false, isHeld: held, subject: subject)
    }

    /// 整体位移（内容从上一帧移动了 (dx, dy)：cur[x, y] ≈ prev[x − dx, y − dy]）。
    /// 只在大半格子有变化时才搜；对齐后差异要明显更小才采用，否则 (0, 0)（和不补偿逐位相同）。
    /// scratch：调用方复用的临时缓冲（前一半每格差异和、后一半每格采样数；algo-opt-2 起不再每帧分配，不够长才补一次）
    static func globalShift(_ cur: [UInt8], mean: Double, previous prev: [UInt8], previousMean: Double,
                            width w: Int, height h: Int, cells: [Int], scratch: inout [Double]) -> MotionShift {
        let r = maxShift
        guard w > 2 * r + 4, h > 2 * r + 4, cur.count == w * h, prev.count == w * h, cells.count == w * h else {
            return MotionShift()
        }
        let cellCount = gridColumns * gridRows
        if scratch.count < 2 * cellCount { scratch = [Double](repeating: 0, count: 2 * cellCount) }
        for c in 0..<(2 * cellCount) { scratch[c] = 0 }
        var zero = 0.0
        var samples = 0
        var y = r
        while y < h - r {
            var x = r
            while x < w - r {
                let i = y * w + x
                let d = abs((Double(cur[i]) - mean) - (Double(prev[i]) - previousMean))
                zero += d
                scratch[cells[i]] += d
                scratch[cellCount + cells[i]] += 1
                samples += 1
                x += 2
            }
            y += 2
        }
        guard samples > 0, zero / Double(samples) > noiseGate else { return MotionShift() }
        var changed = 0
        var counted = 0
        for c in 0..<cellCount where scratch[cellCount + c] > 0 {
            counted += 1
            if scratch[c] / scratch[cellCount + c] > noiseGate { changed += 1 }
        }
        guard counted > 0, Double(changed) / Double(counted) > shiftChangedCells else { return MotionShift() }
        var best = zero
        var bestShift = (0, 0)
        for sy in -r...r {
            for sx in -r...r where sx != 0 || sy != 0 {
                var sad = 0.0
                var yy = r
                while yy < h - r && sad < best {
                    var xx = r
                    let row = yy * w
                    let prow = (yy - sy) * w
                    while xx < w - r {
                        sad += abs((Double(cur[row + xx]) - mean) - (Double(prev[prow + xx - sx]) - previousMean))
                        xx += 2
                    }
                    yy += 2
                }
                if sad < best {
                    best = sad
                    bestShift = (sx, sy)
                }
            }
        }
        let ratio = zero > 0 ? best / zero : 1
        guard best < zero * shiftAcceptRatio else { return MotionShift(searched: true, ratio: ratio) }
        return MotionShift(dx: bestShift.0, dy: bestShift.1, searched: true, ratio: ratio)
    }

    /// 记下参考帧：尺寸没变就拷进已有存储（不和调用方的帧缓冲共享、不每帧分配）
    private mutating func remember(_ pixels: [UInt8], width: Int, height: Int, mean: Double, sharpness: Double,
                                   time: Double) {
        if previous.count == pixels.count {
            previous.withUnsafeMutableBufferPointer { dst in
                pixels.withUnsafeBufferPointer { src in
                    if let d = dst.baseAddress, let s = src.baseAddress { d.update(from: s, count: src.count) }
                }
            }
        } else {
            previous = pixels
            previous.reserveCapacity(pixels.count)
        }
        previousWidth = width
        previousHeight = height
        previousMean = mean
        previousSharpness = sharpness
        if previousHistogram.count != Self.histogramBins {
            previousHistogram = [Double](repeating: 0, count: Self.histogramBins)
        }
        for b in 0..<Self.histogramBins { previousHistogram[b] = histogram[b] }
        previousTime = time
    }

    private mutating func record(_ energy: Double, at time: Double) {
        historyTimes.append(time)
        historyEnergies.append(energy)
        while let first = historyTimes.first,
              time - first > Self.baselineWindow || historyTimes.count > Self.historyCapacity {
            historyTimes.removeFirst()
            historyEnergies.removeFirst()
        }
    }

    /// 最近 window 秒内正常样本（不含切换 / 保持期）的能量中位数；没有样本时为 0
    private mutating func median(within window: Double, now: Double) -> Double {
        medianScratch.removeAll(keepingCapacity: true)
        for i in 0..<historyTimes.count where now - historyTimes[i] <= window {
            medianScratch.append(historyEnergies[i])
        }
        guard !medianScratch.isEmpty else { return 0 }
        medianScratch.sort()
        let m = medianScratch.count / 2
        return medianScratch.count % 2 == 1 ? medianScratch[m] : (medianScratch[m - 1] + medianScratch[m]) / 2
    }

    private mutating func buildCells(width w: Int, height h: Int) {
        let cols = Self.gridColumns
        let rows = Self.gridRows
        var map = [Int](repeating: 0, count: w * h)
        var counts = [Double](repeating: 0, count: cols * rows)
        for y in 0..<h {
            let r = min(rows - 1, y * rows / h)
            for x in 0..<w {
                let c = r * cols + min(cols - 1, x * cols / w)
                map[y * w + x] = c
                counts[c] += 1
            }
        }
        cellOf = map
        cellPixels = counts
        cellWidth = w
        cellHeight = h
    }
}

// MARK: - algo-opt-3：主体运动（块运动 + 相机运动扣除 + 往复节奏 + 人体姿态辅助）

/// 小数组统计（algo-opt-3）：只排调用方缓冲的前 n 个（插入排序，n ≤ 48），不分配
enum MotionStats {
    static func sortPrefix(_ a: inout [Double], _ n: Int) {
        let n = min(n, a.count)
        guard n > 1 else { return }
        for i in 1..<n {
            let v = a[i]
            var j = i - 1
            while j >= 0 && a[j] > v {
                a[j + 1] = a[j]
                j -= 1
            }
            a[j + 1] = v
        }
    }

    /// 前 n 个的 q 分位（线性插值）；n == 0 时 0。会打乱前 n 个的顺序
    static func quantile(_ a: inout [Double], _ n: Int, _ q: Double) -> Double {
        let n = min(n, a.count)
        guard n > 0 else { return 0 }
        sortPrefix(&a, n)
        let pos = min(1, max(0, q)) * Double(n - 1)
        let i = Int(pos)
        let f = pos - Double(i)
        return i + 1 < n ? a[i] * (1 - f) + a[i + 1] * f : a[i]
    }

    static func clamp01(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
}

/// 相机运动（algo-opt-3）：分析帧像素坐标（左上角原点，像素 i 的中心在 i + 0.5）上的复数相似变换 z' = m·z + t，
/// 即平移 + 轻微缩放 / 旋转。apply 给出上一帧里的一点在这一帧应该在的位置
struct CameraTransform: Equatable {
    var m0: Double = 1
    var m1: Double = 0
    var t0: Double = 0
    var t1: Double = 0

    static let identity = CameraTransform()

    func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (m0 * x - m1 * y + t0, m1 * x + m0 * y + t1)
    }

    /// 先做 self、再做 next（连续几帧的相机运动合成一段）
    func then(_ next: CameraTransform) -> CameraTransform {
        CameraTransform(m0: next.m0 * m0 - next.m1 * m1,
                        m1: next.m0 * m1 + next.m1 * m0,
                        t0: next.m0 * t0 - next.m1 * t1 + next.t0,
                        t1: next.m1 * t0 + next.m0 * t1 + next.t1)
    }

    var isUsable: Bool { m0.isFinite && m1.isFinite && t0.isFinite && t1.isFinite }
}

/// 一帧的块运动结果（algo-opt-3）
struct BlockMotionResult: Equatable {
    /// 主体残差速度：在动的块的 P80（分析帧像素 / 名义帧间隔 1/15 s），已乘面积门、相机降权、按真实间隔校正
    var speed: Double = 0
    /// 在动的块的平均残差速度（分析帧像素 / 秒，带方向，节奏用）
    var vx: Double = 0
    var vy: Double = 0
    var movingBlocks = 0
    /// 判为相机在动（平移 / 缩放 / 旋转被扣掉）
    var cameraActive = false
    /// 符合相机模型的块的比例（分母：可靠块 + 2 × 一个位移解释不了的块）
    var cameraShare: Double = 0
    /// 这一帧间隔的相机运动（没判为相机在动时 identity）
    var camera = CameraTransform.identity
}

/// 块运动（algo-opt-3）：8×6 块，每块（加 2 像素边）在上一帧里搜 ±8 像素（先隔一个点粗搜，再 ±1 细搜 + 抛物线亚像素），
/// 去均值 SSD（局部变亮变暗不算动）。没纹理 / 只有一条边 / 对不上的块按「法向流」估速度（只给大小）。
/// 相机：可靠块的中位数平移 → 内点 → 最小二乘相似变换（缩放 / 旋转 ≤ 8%）→ 再取内点重拟合；
/// 多数块一致地动（且不是多数块不动）才判为相机在动并扣掉。主体速度 = 扣掉相机后在动的块的 P80：
/// 和「多少面积在动」无关（至少 3 块才满额，1~2 块的噪声不算），大半画面一致地动时再降一点权
struct BlockMotionEstimator {
    static let columns = MotionAnalyzer.gridColumns
    static let rows = MotionAnalyzer.gridRows
    static let blockCount = MotionAnalyzer.gridColumns * MotionAnalyzer.gridRows
    static let searchRadius = 8
    static let margin = 2
    /// 零位移去均值 SSD 的 rms ≤ 3：这一块没动（压缩噪声）；纹理 rms ≥ 6 的静止块（藏不住 0.5 像素以上的位移）
    /// 当作可靠的零向量参加相机拟合
    static let staticRms: Double = 3
    static let staticTextureRms: Double = 6
    /// 可靠向量：最小曲率（每像素 SSD）≥ 4、两个方向曲率比 ≥ 0.1（不是一条边）、最好的匹配能解释大半变化、没顶到搜索边界
    static let minCurvature: Double = 4
    static let minCurvatureRatio: Double = 0.1
    static let explainRatio: Double = 0.5
    static let explainFloor: Double = 9
    static let maxNormalFlow: Double = 6
    /// 混合块（静止背景 + 一小块在动的东西，整块对不上）：只拿「变了的像素」（|帧差| > 12）再搜一次，
    /// 截断平方差（≤ 40²）+ 位移的小惩罚；能把变化解释掉一半以上就用这个位移（只算主体速度，不参加相机拟合）
    static let maskGate = 12
    static let minMaskPixels = 6
    static let maskTruncation = 40 * 40
    static let maskAcceptRatio: Double = 0.5
    static let maskShiftPenalty: Double = 0.005
    static let maskCapacity = 512
    static let minCameraBlocks = 8
    static let inlierTolerance: Double = 1
    static let inlierSlope: Double = 0.1
    static let maxZoomRotation: Double = 0.08
    static let minCameraMotion: Double = 0.6
    static let minCameraShare: Double = 0.6
    static let cameraMargin: Double = 0.2
    /// 残差 > 0.75 + 0.2 × 相机位移 才算在动
    static let movingThreshold: Double = 0.75
    static let movingSlope: Double = 0.2
    static let speedPercentile: Double = 0.8
    static let cameraDownWeight: Double = 0.35
    static let secondaryShare: Double = 1.25
    /// 可靠块里完全不动的超过 15%：镜头是固定的（大面积主体在动），不当相机运动扣
    static let maxStaticShare: Double = 0.15
    /// 相机内点比例的分母里，「一个位移解释不了」的块按 2 个可靠块算
    static let contestedWeight = 2

    private static let tableSide = 2 * BlockMotionEstimator.searchRadius + 1

    private struct Window {
        var x0: Int
        var x1: Int
        var y0: Int
        var y1: Int
        var minCount: Int
    }

    private var centerX = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var centerY = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var vx = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var vy = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var normalFlow = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    /// 0 静止（没纹理）、1 可靠向量、2 只有法向流、3 静止且有纹理（零向量，参加相机拟合）、4 混合块（只用变了的像素对上的位移）
    private var kind = [Int](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var residual = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var residualX = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var residualY = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var maskX = [Int](repeating: 0, count: BlockMotionEstimator.maskCapacity)
    private var maskY = [Int](repeating: 0, count: BlockMotionEstimator.maskCapacity)
    private var inlier = [Bool](repeating: false, count: BlockMotionEstimator.blockCount)
    /// 整块找不到一个位移能解释大半变化（静止背景 + 独立在动的东西）：说明画面里有不跟着相机走的部分
    private var unexplained = [Bool](repeating: false, count: BlockMotionEstimator.blockCount)
    private var table = [Double](repeating: .nan, count: BlockMotionEstimator.tableSide * BlockMotionEstimator.tableSide)
    private var sortA = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)
    private var sortB = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)

    /// rhythm-context P3：false = 不拟合相机运动，整块统一扣掉 presetShift（像素 / 帧间隔）。
    /// 区域内高分辨率运动（RoiFlowTracker）用：区域里大半是主体，拟合会把主体当成相机。默认 true = 原算法逐位不变
    var cameraFit = true
    var presetShift: (x: Double, y: Double) = (0, 0)

    /// rhythm-action tune（动作识别开着时打开；默认关 = 原算法逐位不变）：近景大面积皮肤、暗场噪声、压缩闪烁时，
    /// 没纹理的块按法向流、混合块按「变了的像素」搜位移，都会把噪声当成运动（静止的特写也判成在动）。
    /// 打开后：纹理 rms < guardMinTexture 的块不给法向流（测不出来就当没动）；混合块的最好位移要比粗搜网格上
    /// 所有位移的平均代价低一半以上才算（真的一小块在动时只有一个位移对得上，噪声对哪个位移都差不多）
    var noiseGuard = false
    static let guardMinTexture: Double = 4
    static let guardMaskDistinct: Double = 0.5
    /// 没纹理的块的法向流先记在 weakFlow；旁边（8 邻域）有一块有纹理、确实在动的块时才采用（真的一大片皮肤在动，
    /// 边上总有对得上的块；画面到处一样的闪烁 / 噪声，邻块也全是没纹理的）
    private var weak = [Bool](repeating: false, count: BlockMotionEstimator.blockCount)
    private var weakFlow = [Double](repeating: 0, count: BlockMotionEstimator.blockCount)

    /// rhythm-context P3：上一次 estimate 每块扣掉相机后的位移（像素 / 帧间隔）。只有可靠块 / 混合块有向量，其它块 (0, 0)
    func blockResidual(_ b: Int) -> (x: Double, y: Double) {
        guard b >= 0, b < Self.blockCount, kind[b] == 1 || kind[b] == 4,
              residualX[b].isFinite, residualY[b].isFinite else { return (0, 0) }
        return (residualX[b], residualY[b])
    }

    var scratchAddresses: [Int] {
        func address<T>(_ a: [T]) -> Int { a.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        return [address(centerX), address(centerY), address(vx), address(vy), address(normalFlow), address(kind),
                address(inlier), address(table), address(sortA), address(sortB), address(maskX), address(maskY), address(residual), address(residualX),
                address(residualY), address(unexplained)]
    }

    /// cur[x, y] ≈ prev[x − u, y − v]：内容从上一帧移动了 (u, v)。gap：两帧间隔（秒）
    mutating func estimate(cur: UnsafeBufferPointer<UInt8>, prev: UnsafeBufferPointer<UInt8>, width w: Int, height h: Int,
                           gap: Double) -> BlockMotionResult {
        let cols = Self.columns
        let rows = Self.rows
        guard w >= 2 * cols, h >= 2 * rows, cur.count >= w * h, prev.count >= w * h, gap.isFinite, gap > 0 else {
            return BlockMotionResult()
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let b = r * cols + c
                let bx0 = c * w / cols
                let bx1 = (c + 1) * w / cols
                let by0 = r * h / rows
                let by1 = (r + 1) * h / rows
                centerX[b] = Double(bx0 + bx1) / 2
                centerY[b] = Double(by0 + by1) / 2
                let x0 = max(0, bx0 - Self.margin)
                let x1 = min(w, bx1 + Self.margin)
                let y0 = max(0, by0 - Self.margin)
                let y1 = min(h, by1 + Self.margin)
                let full = max(0, x1 - x0) * max(0, y1 - y0)
                measure(block: b, cur: cur, prev: prev, width: w, height: h,
                        window: Window(x0: x0, x1: x1, y0: y0, y1: y1, minCount: (full + 1) / 2))
            }
        }
        if noiseGuard { coherentWeakFlow() }

        // 相机：中位数平移 → 内点 → 相似变换 → 再取内点重拟合
        let cx0 = Double(w) / 2
        let cy0 = Double(h) / 2
        var k = 0
        for b in 0..<Self.blockCount where kind[b] == 1 || kind[b] == 3 {
            sortA[k] = vx[b]
            sortB[k] = vy[b]
            k += 1
        }
        var model = (tx: 0.0, ty: 0.0, a: 0.0, b: 0.0)
        var active = false
        var share = 0.0
        if cameraFit, k >= Self.minCameraBlocks {
            model.tx = MotionStats.quantile(&sortA, k, 0.5)
            model.ty = MotionStats.quantile(&sortB, k, 0.5)
            for _ in 0..<2 {
                _ = markInliers(model, cx0: cx0, cy0: cy0)
                if let fit = fitSimilarity(cx0: cx0, cy0: cy0) { model = fit }
            }
            let count = markInliers(model, cx0: cx0, cy0: cy0)
            // 分母还算上「一个位移解释不了」的块：大面积主体在固定镜头前动时，主体边上全是这种块，
            // 不能只因为可靠块都朝一个方向走就当成相机在动
            var contested = 0
            for b in 0..<Self.blockCount where unexplained[b] { contested += 1 }
            share = Double(count) / Double(k + Self.contestedWeight * contested)
            var zero = 0
            for b in 0..<Self.blockCount where (kind[b] == 1 || kind[b] == 3)
                && (vx[b] * vx[b] + vy[b] * vy[b]).squareRoot() <= Self.inlierTolerance {
                zero += 1
            }
            let zeroShare = Double(zero) / Double(k)
            var maxDisp = 0.0
            for b in 0..<Self.blockCount {
                let d = Self.displacement(model, x: centerX[b] - cx0, y: centerY[b] - cy0)
                maxDisp = max(maxDisp, (d.x * d.x + d.y * d.y).squareRoot())
            }
            active = maxDisp >= Self.minCameraMotion && share >= Self.minCameraShare
                && share >= zeroShare + Self.cameraMargin && zeroShare <= Self.maxStaticShare
        }
        if !active || !model.tx.isFinite || !model.ty.isFinite || !model.a.isFinite || !model.b.isFinite {
            model = (0, 0, 0, 0)
            active = false
        }
        if !cameraFit, presetShift.x.isFinite, presetShift.y.isFinite {
            // 区域内：相机运动由整幅画面那次估计给（只扣平移，不算相机在动、不降权）
            model = (presetShift.x, presetShift.y, 0, 0)
        }

        // 扣掉相机后的残差：在动的块的 P80 + 带方向的平均（节奏用）。
        // 有 ≥ 2 个可靠块在动时，混合块 / 法向流块的速度不超过可靠块最大值的 1.25 倍（边缘块的整数位移 / 偶然对上不放大）
        var reliableMoving = 0
        var reliableMax = 0.0
        for b in 0..<Self.blockCount {
            let d = Self.displacement(model, x: centerX[b] - cx0, y: centerY[b] - cy0)
            let dm = (d.x * d.x + d.y * d.y).squareRoot()
            var r = 0.0
            residualX[b] = 0
            residualY[b] = 0
            switch kind[b] {
            case 1, 4:
                residualX[b] = vx[b] - d.x
                residualY[b] = vy[b] - d.y
                r = (residualX[b] * residualX[b] + residualY[b] * residualY[b]).squareRoot()
            case 2:
                r = max(0, normalFlow[b] - dm)
            default:
                // 画面里不动的块（含镜头跟着主体走时的主体、台标）不算在动
                r = 0
            }
            let isMoving = r.isFinite && r > Self.movingThreshold + Self.movingSlope * dm
            residual[b] = isMoving ? r : 0
            if isMoving && kind[b] == 1 {
                reliableMoving += 1
                reliableMax = max(reliableMax, r)
            }
        }
        let secondaryLimit = reliableMoving >= 2 ? Self.secondaryShare * reliableMax : Double.infinity
        var moving = 0
        var vectors = 0
        var sumX = 0.0
        var sumY = 0.0
        for b in 0..<Self.blockCount where residual[b] > 0 {
            var r = residual[b]
            var scale = 1.0
            if kind[b] != 1, r > secondaryLimit {
                scale = secondaryLimit / r
                r = secondaryLimit
            }
            sortA[moving] = r
            moving += 1
            if kind[b] == 1 || kind[b] == 4 {
                sumX += residualX[b] * scale
                sumY += residualY[b] * scale
                vectors += 1
            }
        }
        let p80 = MotionStats.quantile(&sortA, moving, Self.speedPercentile)
        let area = min(1, max(0, Double(moving - 1) / 2))
        let camWeight = active ? 1 - Self.cameraDownWeight * MotionStats.clamp01((share - 0.6) / 0.4) : 1
        let correction = min(MotionAnalyzer.rateCorrection.upperBound,
                             max(MotionAnalyzer.rateCorrection.lowerBound, MotionAnalyzer.nominalInterval / gap))
        var out = BlockMotionResult()
        let speed = p80 * area * camWeight * correction
        out.speed = speed.isFinite ? max(0, speed) : 0
        if vectors > 0 {
            let vxs = sumX / Double(vectors) / gap * area
            let vys = sumY / Double(vectors) / gap * area
            out.vx = vxs.isFinite ? vxs : 0
            out.vy = vys.isFinite ? vys : 0
        }
        out.movingBlocks = moving
        out.cameraActive = active
        out.cameraShare = share.isFinite ? share : 0
        if active {
            out.camera = CameraTransform(m0: 1 + model.a, m1: model.b,
                                         t0: model.tx - (model.a * cx0 - model.b * cy0),
                                         t1: model.ty - (model.b * cx0 + model.a * cy0))
        }
        return out
    }

    /// rhythm-action tune（noiseGuard）：没纹理的块，8 邻域里有一块有纹理、在动的块（可靠 / 混合块位移或法向流 > movingThreshold）
    /// 才采用它自己的法向流。只看有纹理的邻块，和块的顺序无关
    private mutating func coherentWeakFlow() {
        let cols = Self.columns
        let rows = Self.rows
        for b in 0..<Self.blockCount where weak[b] && weakFlow[b] > 0 {
            let r = b / cols
            let c = b % cols
            var coherent = false
            for dr in -1...1 {
                for dc in -1...1 where (dr != 0 || dc != 0) && !coherent {
                    let rr = r + dr
                    let cc = c + dc
                    guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                    let nb = rr * cols + cc
                    guard !weak[nb] else { continue }
                    switch kind[nb] {
                    case 1, 4:
                        coherent = (vx[nb] * vx[nb] + vy[nb] * vy[nb]).squareRoot() > Self.movingThreshold
                    case 2:
                        coherent = normalFlow[nb] > Self.movingThreshold
                    default:
                        break
                    }
                }
            }
            if coherent { normalFlow[b] = weakFlow[b] }
        }
    }

    private static func displacement(_ m: (tx: Double, ty: Double, a: Double, b: Double),
                                      x: Double, y: Double) -> (x: Double, y: Double) {
        (m.tx + m.a * x - m.b * y, m.ty + m.b * x + m.a * y)
    }

    private mutating func markInliers(_ m: (tx: Double, ty: Double, a: Double, b: Double), cx0: Double, cy0: Double) -> Int {
        var count = 0
        for b in 0..<Self.blockCount {
            inlier[b] = false
            guard kind[b] == 1 || kind[b] == 3 else { continue }
            let d = Self.displacement(m, x: centerX[b] - cx0, y: centerY[b] - cy0)
            let ex = vx[b] - d.x
            let ey = vy[b] - d.y
            let dm = (d.x * d.x + d.y * d.y).squareRoot()
            if (ex * ex + ey * ey).squareRoot() <= Self.inlierTolerance + Self.inlierSlope * dm {
                inlier[b] = true
                count += 1
            }
        }
        return count
    }

    /// 内点上的最小二乘相似变换（以画面中心为原点）：d(p) = t + [a −b; b a]·p。内点 < 4 个只拟合平移
    private func fitSimilarity(cx0: Double, cy0: Double) -> (tx: Double, ty: Double, a: Double, b: Double)? {
        var n = 0.0
        var spx = 0.0
        var spy = 0.0
        var svx = 0.0
        var svy = 0.0
        for b in 0..<Self.blockCount where inlier[b] {
            n += 1
            spx += centerX[b] - cx0
            spy += centerY[b] - cy0
            svx += vx[b]
            svy += vy[b]
        }
        guard n >= 1 else { return nil }
        let px = spx / n
        let py = spy / n
        let mvx = svx / n
        let mvy = svy / n
        var a = 0.0
        var rot = 0.0
        if n >= 4 {
            var den = 0.0
            var numA = 0.0
            var numB = 0.0
            for b in 0..<Self.blockCount where inlier[b] {
                let qx = centerX[b] - cx0 - px
                let qy = centerY[b] - cy0 - py
                let ux = vx[b] - mvx
                let uy = vy[b] - mvy
                den += qx * qx + qy * qy
                numA += qx * ux + qy * uy
                numB += qx * uy - qy * ux
            }
            if den > 1 {
                a = min(Self.maxZoomRotation, max(-Self.maxZoomRotation, numA / den))
                rot = min(Self.maxZoomRotation, max(-Self.maxZoomRotation, numB / den))
            }
        }
        let tx = mvx - (a * px - rot * py)
        let ty = mvy - (rot * px + a * py)
        guard tx.isFinite, ty.isFinite, a.isFinite, rot.isFinite else { return nil }
        return (tx, ty, a, rot)
    }

    /// 一块：纹理、零位移残差、粗搜 + 细搜 + 亚像素，分类
    private mutating func measure(block b: Int, cur: UnsafeBufferPointer<UInt8>, prev: UnsafeBufferPointer<UInt8>,
                                  width w: Int, height h: Int, window win: Window) {
        vx[b] = 0
        vy[b] = 0
        normalFlow[b] = 0
        kind[b] = 0
        unexplained[b] = false
        weak[b] = false
        weakFlow[b] = 0
        guard win.x1 > win.x0 + 1, win.y1 > win.y0 + 1 else { return }
        // 纹理：窗口内相邻像素差的均方（每个轴）
        var grad = 0
        var gradCount = 0
        for y in win.y0..<win.y1 {
            let row = y * w
            for x in win.x0..<win.x1 {
                let v = Int(cur[row + x])
                if x + 1 < win.x1 {
                    let d = Int(cur[row + x + 1]) - v
                    grad += d * d
                    gradCount += 1
                }
                if y + 1 < win.y1 {
                    let d = Int(cur[row + w + x]) - v
                    grad += d * d
                    gradCount += 1
                }
            }
        }
        let gradRms = gradCount > 0 ? (Double(grad) / Double(gradCount)).squareRoot() : 0
        let s0 = Self.zssd(cur, prev, width: w, height: h, window: win, u: 0, v: 0)
        guard s0.isFinite else { return }
        let gate = Self.staticRms * Self.staticRms
        if s0 <= gate {
            kind[b] = gradRms >= Self.staticTextureRms ? 3 : 0
            return
        }
        let r = Self.searchRadius
        let side = Self.tableSide
        for i in 0..<table.count { table[i] = .nan }
        table[r * side + r] = s0
        var best = s0
        var bu = 0
        var bv = 0
        var v = -r
        while v <= r {
            var u = -r
            while u <= r {
                if u != 0 || v != 0 {
                    let s = Self.zssd(cur, prev, width: w, height: h, window: win, u: u, v: v)
                    table[(v + r) * side + (u + r)] = s
                    if s < best {
                        best = s
                        bu = u
                        bv = v
                    }
                }
                u += 2
            }
            v += 2
        }
        let cu = bu
        let cv = bv
        for dv in -1...1 {
            for du in -1...1 where du != 0 || dv != 0 {
                let s = lookup(cu + du, cv + dv, cur: cur, prev: prev, width: w, height: h, window: win)
                if s < best {
                    best = s
                    bu = cu + du
                    bv = cv + dv
                }
            }
        }
        let sl = lookup(bu - 1, bv, cur: cur, prev: prev, width: w, height: h, window: win)
        let sr = lookup(bu + 1, bv, cur: cur, prev: prev, width: w, height: h, window: win)
        let su = lookup(bu, bv - 1, cur: cur, prev: prev, width: w, height: h, window: win)
        let sd = lookup(bu, bv + 1, cur: cur, prev: prev, width: w, height: h, window: win)
        let curvX = sl + sr - 2 * best
        let curvY = su + sd - 2 * best
        var fx = 0.0
        var fy = 0.0
        if curvX.isFinite, curvX > 1e-9 { fx = min(0.5, max(-0.5, 0.5 * (sl - sr) / curvX)) }
        if curvY.isFinite, curvY > 1e-9 { fy = min(0.5, max(-0.5, 0.5 * (su - sd) / curvY)) }
        let border = abs(bu) >= r || abs(bv) >= r
        let lo = min(curvX, curvY)
        let hi = max(curvX, curvY)
        // 抛物线插值后的最小值（亚像素位移时整数格点上的 best 偏大，不能因此当成「解释不了」）
        var refined = best
        if curvX.isFinite, curvX > 1e-9 { refined -= 0.5 * curvX * fx * fx }
        if curvY.isFinite, curvY > 1e-9 { refined -= 0.5 * curvY * fy * fy }
        let explained = max(0, refined) <= Self.explainRatio * s0 + Self.explainFloor
        let reliable = !border && lo.isFinite && hi.isFinite && lo >= Self.minCurvature
            && lo >= Self.minCurvatureRatio * hi && explained
        unexplained[b] = !reliable && !explained
        if reliable {
            kind[b] = 1
            vx[b] = Double(bu) + fx
            vy[b] = Double(bv) + fy
        } else if let m = maskedMatch(cur: cur, prev: prev, width: w, height: h, window: win) {
            kind[b] = 4
            vx[b] = Double(m.u)
            vy[b] = Double(m.v)
        } else {
            // 法向流：|I_t| ≈ |∇I · d| → |d| ≈ rms(I_t) / rms(∇I)（扣掉噪声，纹理太弱时按 2 算，最多 6）
            kind[b] = 2
            let nf = max(0, s0 - gate).squareRoot() / max(gradRms, 2)
            if noiseGuard && gradRms < Self.guardMinTexture {
                // rhythm-action tune：没纹理的块（大片皮肤 / 暗场）里的帧差多半是噪声：先不给，
                // estimate 里旁边有有纹理且在动的块时再采用（coherentWeakFlow）
                normalFlow[b] = 0
                weak[b] = true
                weakFlow[b] = nf.isFinite ? min(Self.maxNormalFlow, nf) : 0
            } else {
                normalFlow[b] = nf.isFinite ? min(Self.maxNormalFlow, nf) : 0
            }
        }
    }

    /// 混合块：只用变了的像素搜位移（见 maskGate）。解释不了一半变化、顶到搜索边界、变了的像素太少时 nil
    private mutating func maskedMatch(cur: UnsafeBufferPointer<UInt8>, prev: UnsafeBufferPointer<UInt8>,
                                      width w: Int, height h: Int, window win: Window) -> (u: Int, v: Int)? {
        var m = 0
        for y in win.y0..<win.y1 {
            let row = y * w
            for x in win.x0..<win.x1 where m < Self.maskCapacity {
                let d = Int(cur[row + x]) - Int(prev[row + x])
                if abs(d) > Self.maskGate {
                    maskX[m] = x
                    maskY[m] = y
                    m += 1
                }
            }
        }
        guard m >= Self.minMaskPixels else { return nil }
        let cost0 = maskedCost(cur: cur, prev: prev, width: w, height: h, count: m, u: 0, v: 0)
        guard cost0.isFinite, cost0 > 0 else { return nil }
        let r = Self.searchRadius
        let penalty = Self.maskShiftPenalty * cost0
        var best = cost0
        var bu = 0
        var bv = 0
        var coarseSum = 0.0
        var coarseCount = 0
        var v = -r
        while v <= r {
            var u = -r
            while u <= r {
                if u != 0 || v != 0 {
                    let raw = maskedCost(cur: cur, prev: prev, width: w, height: h, count: m, u: u, v: v)
                    if raw.isFinite {
                        coarseSum += raw
                        coarseCount += 1
                    }
                    let c = raw + penalty * Double(u * u + v * v)
                    if c < best {
                        best = c
                        bu = u
                        bv = v
                    }
                }
                u += 2
            }
            v += 2
        }
        let cu = bu
        let cv = bv
        for dv in -1...1 {
            for du in -1...1 where (du != 0 || dv != 0) && abs(cu + du) <= r && abs(cv + dv) <= r {
                let u = cu + du
                let v = cv + dv
                let c = maskedCost(cur: cur, prev: prev, width: w, height: h, count: m, u: u, v: v)
                    + penalty * Double(u * u + v * v)
                if c < best {
                    best = c
                    bu = u
                    bv = v
                }
            }
        }
        guard bu != 0 || bv != 0, abs(bu) < r, abs(bv) < r, best <= Self.maskAcceptRatio * cost0 else { return nil }
        if noiseGuard {
            // rhythm-action tune：最好的位移要明显好过「随便哪个位移」（纯噪声时每个位移都一样差）
            guard coarseCount > 0, best <= Self.guardMaskDistinct * (coarseSum / Double(coarseCount)) else { return nil }
        }
        // 只有一条边时沿边方向的分量是随便对上的：往 0 收，代价只高 10% 以内就收
        let limit = best * 1.1
        for axis in 0..<2 {
            while (axis == 0 ? bu : bv) != 0 {
                let u = axis == 0 ? bu - bu.signum() : bu
                let v = axis == 0 ? bv : bv - bv.signum()
                guard u != 0 || v != 0 else { break }
                let c = maskedCost(cur: cur, prev: prev, width: w, height: h, count: m, u: u, v: v)
                    + penalty * Double(u * u + v * v)
                guard c <= limit else { break }
                bu = u
                bv = v
            }
        }
        return (bu, bv)
    }

    /// 变了的像素和上一帧平移 (u, v) 的截断平方差均值；对得上的像素不到一半时 ∞
    private func maskedCost(cur: UnsafeBufferPointer<UInt8>, prev: UnsafeBufferPointer<UInt8>, width w: Int,
                            height h: Int, count m: Int, u: Int, v: Int) -> Double {
        var s = 0
        var n = 0
        for k in 0..<m {
            let x = maskX[k]
            let y = maskY[k]
            let px = x - u
            let py = y - v
            guard px >= 0, px < w, py >= 0, py < h else { continue }
            let d = Int(cur[y * w + x]) - Int(prev[py * w + px])
            s += min(d * d, Self.maskTruncation)
            n += 1
        }
        guard n > 0, 2 * n >= m else { return .infinity }
        return Double(s) / Double(n)
    }

    private mutating func lookup(_ u: Int, _ v: Int, cur: UnsafeBufferPointer<UInt8>, prev: UnsafeBufferPointer<UInt8>,
                                 width w: Int, height h: Int, window win: Window) -> Double {
        let r = Self.searchRadius
        guard abs(u) <= r, abs(v) <= r else { return .infinity }
        let i = (v + r) * Self.tableSide + (u + r)
        let cached = table[i]
        if !cached.isNaN { return cached }
        let s = Self.zssd(cur, prev, width: w, height: h, window: win, u: u, v: v)
        table[i] = s
        return s
    }

    /// 窗口和「上一帧平移 (u, v)」的重叠部分上的去均值 SSD（每像素）；重叠不到一半时 ∞
    private static func zssd(_ cur: UnsafeBufferPointer<UInt8>, _ prev: UnsafeBufferPointer<UInt8>, width w: Int,
                             height h: Int, window win: Window, u: Int, v: Int) -> Double {
        let xa = max(win.x0, u)
        let xb = min(win.x1, w + u)
        let ya = max(win.y0, v)
        let yb = min(win.y1, h + v)
        guard xb > xa, yb > ya else { return .infinity }
        let n = (xb - xa) * (yb - ya)
        guard n >= win.minCount, n > 0 else { return .infinity }
        var s = 0
        var s2 = 0
        for y in ya..<yb {
            let row = y * w
            let prow = (y - v) * w - u
            for x in xa..<xb {
                let d = Int(cur[row + x]) - Int(prev[prow + x])
                s += d
                s2 += d * d
            }
        }
        let inv = 1 / Double(n)
        let m = Double(s) * inv
        return max(0, Double(s2) * inv - m * m)
    }
}

/// 往复节奏（algo-opt-3）：最近 4 秒带方向的速度 → 主轴投影 → 15 Hz 重采样 → 归一化自相关找周期
/// （滞后 4~30 格 = 3.75~0.5 Hz；取不低于最高峰 85% 的最短周期，避免把两下当一下），抛物线细化。
/// hz：往复频率；confidence：自相关峰值 0~1；amplitude：单程幅度（速度单位 × 秒，正弦近似 √2·rms / 2πf）
struct StrokeRhythm {
    static let window: Double = 4
    static let capacity = 96
    static let gridRate: Double = 15
    static let gridCapacity = 64
    static let minLag = 4
    static let maxLag = 30
    static let minSamples = 12
    static let minSpan: Double = 1.5
    static let octaveShare: Double = 0.85
    /// rhythm-follow（只影响 followEstimate，estimate / 分数与 algo-opt-3 逐位相同）：选中周期正好一半处（插值后 ±0.75 格）
    /// 的峰 ≥ 最高峰的 55%、且自相关本身 ≥ 0.3，就按两倍频率算；最多减半一次
    static let harmonicShare: Double = 0.55
    static let harmonicFloor: Double = 0.3
    /// rhythm-follow：高于实际采样率 0.4 倍的频率不可信（慢设备上姿态约 3 Hz 采样，看不清 1.2 Hz 以上），不给
    static let aliasShare: Double = 0.4

    struct Estimate: Equatable {
        var hz: Double = 0
        var confidence: Double = 0
        var amplitude: Double = 0
    }

    /// rhythm-follow：给 RhythmFollower 的估计（可能是 estimate 的两倍频率）+ 窗口里样本的实际采样率（次 / 秒）
    struct FollowEstimate: Equatable {
        var hz: Double = 0
        var confidence: Double = 0
        var amplitude: Double = 0
        var sampleRate: Double = 0
    }

    /// rhythm-phase P2：最近 1~3 秒（约 2 个周期）带方向的速度在给定频率上做正弦拟合，得到「现在」的位移相位。
    /// 只读环形缓冲（不动 estimate / followEstimate，分数和频率跟随逐位不变），稳态不分配。
    /// phase：样本最后一帧时刻 time 的位移相位（弧度，[-π, π)）；0 = 位移到主轴正方向的最远点（约定的「最深点」），
    /// -π~0 是往正方向走（约定的「往里」）。主轴正方向：初次取向下（竖直分量 ≥ sin 20°），否则向右；之后保持连续，
    /// 主轴一次转过 60° 以上才按约定重取（epoch +1）。方向反了由用户的「方向反转」开关纠正
    struct PhaseFit: Equatable {
        var time: Double = 0
        var phase: Double = 0
        /// 拟合用的频率（在给定频率 ±6% 内细化过）
        var hz: Double = 0
        /// 正弦拟合解释的方差比例 R²（0~1）
        var quality: Double = 0
        /// 主轴上的方差份额 λ1 / (λ1 + λ2)（0.5 = 画圈 / 没有主方向，1 = 一条直线来回）
        var linearity: Double = 0
        /// 主轴上的单程位移幅度（速度单位 × 秒）
        var amplitude: Double = 0
        /// 主轴方向重取的代次（reset / 主轴大转向时变）：不同代次之间相位可能差 180°
        var epoch: Int = 0
        /// rhythm-context P3：拟合用的主轴正方向（单位向量，分析帧坐标；P2 之前的读数 / 手搭的为 0）。
        /// 只给 ActionContext 判断「往里」是不是主轴正方向，不影响 P2 的任何计算
        var axisX: Double = 0
        var axisY: Double = 0

        var isValid: Bool { hz > 0 && quality > 0 && time.isFinite && phase.isFinite }
    }

    static let phaseMinSamples = 8
    static let phaseWindowPeriods: Double = 2
    static let phaseWindowRange: ClosedRange<Double> = 1.0...3.0
    /// 频率细化的搜索步长（±6%）
    static let phaseSearch: Double = 0.06
    /// 新旧主轴夹角的 |cos| ≥ 这个才延续正方向（≤ 60°），否则按约定重取
    static let phaseAxisKeep: Double = 0.5
    /// 约定正方向：竖直分量 ≥ sin 20° 取向下，否则取向右
    static let phaseAxisVertical: Double = 0.342

    private var times = [Double](repeating: 0, count: StrokeRhythm.capacity)
    private var xs = [Double](repeating: 0, count: StrokeRhythm.capacity)
    private var ys = [Double](repeating: 0, count: StrokeRhythm.capacity)
    private var count = 0
    private var head = 0
    private var projected = [Double](repeating: 0, count: StrokeRhythm.capacity)
    private var projectedTimes = [Double](repeating: 0, count: StrokeRhythm.capacity)
    private var grid = [Double](repeating: 0, count: StrokeRhythm.gridCapacity)
    private var corr = [Double](repeating: 0, count: StrokeRhythm.maxLag + 2)
    private(set) var estimate = Estimate()
    /// rhythm-follow：只给频率跟随用（见 follow），不进 StrokeScore
    private(set) var followEstimate = FollowEstimate()
    /// rhythm-phase P2：相位拟合的主轴（单位向量，正方向保持连续）
    private var phaseAxisX: Double = 1
    private var phaseAxisY: Double = 0
    private var phaseAxisSet = false
    private(set) var phaseEpoch = 0

    var scratchAddresses: [Int] {
        func address<T>(_ a: [T]) -> Int { a.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        return [address(times), address(xs), address(ys), address(projected), address(projectedTimes),
                address(grid), address(corr)]
    }

    mutating func reset() {
        count = 0
        head = 0
        estimate = Estimate()
        followEstimate = FollowEstimate()
        phaseAxisSet = false
        phaseEpoch &+= 1
    }

    /// 时间必须递增（不递增的样本丢掉）
    mutating func add(time t: Double, x: Double, y: Double) {
        guard t.isFinite, x.isFinite, y.isFinite else { return }
        let cap = Self.capacity
        if count > 0, t <= times[(head + cap - 1) % cap] { return }
        times[head] = t
        xs[head] = x
        ys[head] = y
        head = (head + 1) % cap
        count = min(cap, count + 1)
        // compute 只在得出基础估计时才填 followEstimate
        followEstimate = FollowEstimate()
        estimate = compute(now: t)
    }

    /// 到 now 还算数的估计：最近 maxAge 秒没有新样本（这组关节被挡住 / 出画）就当没有节奏，旧估计不再加成
    func freshEstimate(at now: Double, maxAge: Double) -> Estimate {
        guard count > 0, now.isFinite else { return Estimate() }
        let last = times[(head + Self.capacity - 1) % Self.capacity]
        return now - last <= maxAge ? estimate : Estimate()
    }

    /// 同 freshEstimate，给频率跟随
    func freshFollowEstimate(at now: Double, maxAge: Double) -> FollowEstimate {
        guard count > 0, now.isFinite else { return FollowEstimate() }
        let last = times[(head + Self.capacity - 1) % Self.capacity]
        return now - last <= maxAge ? followEstimate : FollowEstimate()
    }

    private mutating func compute(now: Double) -> Estimate {
        let cap = Self.capacity
        let start = (head + cap - count) % cap
        var first = count
        for k in 0..<count where now - times[(start + k) % cap] <= Self.window {
            first = k
            break
        }
        let n = count - first
        guard n >= Self.minSamples else { return Estimate() }
        var mx = 0.0
        var my = 0.0
        for k in 0..<n {
            let i = (start + first + k) % cap
            mx += xs[i]
            my += ys[i]
        }
        mx /= Double(n)
        my /= Double(n)
        var cxx = 0.0
        var cyy = 0.0
        var cxy = 0.0
        for k in 0..<n {
            let i = (start + first + k) % cap
            let dx = xs[i] - mx
            let dy = ys[i] - my
            cxx += dx * dx
            cyy += dy * dy
            cxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        let c = cos(theta)
        let s = sin(theta)
        for k in 0..<n {
            let i = (start + first + k) % cap
            projected[k] = (xs[i] - mx) * c + (ys[i] - my) * s
            projectedTimes[k] = times[i]
        }
        let t0 = projectedTimes[0]
        let span = projectedTimes[n - 1] - t0
        guard span.isFinite, span >= Self.minSpan else { return Estimate() }
        let g = min(Self.gridCapacity, Int(span * Self.gridRate) + 1)
        var j = 0
        for q in 0..<g {
            let tq = t0 + Double(q) / Self.gridRate
            while j < n - 2 && projectedTimes[j + 1] < tq { j += 1 }
            let ta = projectedTimes[j]
            let tb = projectedTimes[j + 1]
            let f = tb > ta ? min(1, max(0, (tq - ta) / (tb - ta))) : 0
            grid[q] = projected[j] + (projected[j + 1] - projected[j]) * f
        }
        var gm = 0.0
        for q in 0..<g { gm += grid[q] }
        gm /= Double(g)
        var energy = 0.0
        for q in 0..<g {
            grid[q] -= gm
            energy += grid[q] * grid[q]
        }
        let rms = (energy / Double(g)).squareRoot()
        let kMax = min(Self.maxLag, g / 2)
        guard rms.isFinite, rms > 1e-9, kMax >= Self.minLag + 1, kMax + 1 < g else { return Estimate() }
        for k in (Self.minLag - 1)...(kMax + 1) {
            var sab = 0.0
            var saa = 0.0
            var sbb = 0.0
            for i in 0..<(g - k) {
                let a = grid[i]
                let b = grid[i + k]
                sab += a * b
                saa += a * a
                sbb += b * b
            }
            let den = (saa * sbb).squareRoot()
            corr[k] = den > 1e-18 ? sab / den : 0
        }
        var best = -1.0
        var bestK = Self.minLag
        for k in Self.minLag...kMax where corr[k] > best {
            best = corr[k]
            bestK = k
        }
        guard best > 0.05 else { return Estimate() }
        // 周期不是整数格时（2 Hz = 7.5 格）整数滞后上的峰偏低，两倍周期（15 格）反而接近 1：
        // 用抛物线插值后的峰值和最高峰比，免得把一下一下的往复当成慢一倍
        var pick = bestK
        for k in Self.minLag...kMax where corr[k] >= corr[k - 1] && corr[k] >= corr[k + 1] {
            let den = corr[k - 1] - 2 * corr[k] + corr[k + 1]
            let lift = den < -1e-12 ? min(0.25, -(corr[k - 1] - corr[k + 1]) * (corr[k - 1] - corr[k + 1]) / (8 * den)) : 0
            if corr[k] + lift >= Self.octaveShare * best {
                pick = k
                break
            }
        }
        let a = corr[pick - 1]
        let b = corr[pick]
        let cc = corr[pick + 1]
        // 必须是真的峰：慢于 0.5 Hz / 没有周期的平滑运动，自相关从最短滞后一路往下走，
        // 最高点落在搜索边界上（不是峰），不能当成 3.75 Hz 以上的快节奏
        guard b >= a, b >= cc else { return Estimate() }
        let den = a - 2 * b + cc
        let delta = den < -1e-12 ? min(0.5, max(-0.5, 0.5 * (a - cc) / den)) : 0
        let lag = min(Double(kMax), max(Double(Self.minLag), Double(pick) + delta))
        let hz = Self.gridRate / lag
        let amplitude = 2.0.squareRoot() * rms / (2 * Double.pi * hz)
        guard hz.isFinite, amplitude.isFinite else { return Estimate() }
        let result = Estimate(hz: hz, confidence: MotionStats.clamp01(b), amplitude: amplitude)
        followEstimate = follow(result, pick: pick, best: best, kMax: kMax, rms: rms, samples: n, span: span)
        return result
    }

    /// rhythm-follow：在基础估计的周期上最多减半一次，只给频率跟随用（estimate 不变）。
    /// 真实视频 2 Hz 在 15 fps 上是 7.5 格一个周期，块匹配的速度有量化、相邻两下形状不同，7/8 格只有 ~0.67、15 / 30 格 ~1.0，
    /// 基础规则（85%）会报 1 Hz。门槛按最高峰 best 算（不随减半一路降低）、只减一次、自相关本身 ≥ 0.3。
    /// 推拉不对称的真 1 Hz 在半周期上是负相关，不受影响。采样率太低时（见 aliasShare）不给
    private func follow(_ e: Estimate, pick: Int, best: Double, kMax: Int, rms: Double, samples n: Int,
                        span: Double) -> FollowEstimate {
        let rate = n > 1 && span > 0 ? Double(n - 1) / span : 0
        var out = FollowEstimate(hz: e.hz, confidence: e.confidence, amplitude: e.amplitude, sampleRate: rate)
        if let half = Self.halvedLag(corr, pick: pick, best: best) {
            let lag = min(Double(kMax), max(Double(Self.minLag), half.lag))
            let hz = Self.gridRate / lag
            let amplitude = 2.0.squareRoot() * rms / (2 * Double.pi * hz)
            if hz.isFinite, amplitude.isFinite {
                out.hz = hz
                out.confidence = MotionStats.clamp01(half.peak)
                out.amplitude = amplitude
            }
        }
        guard rate.isFinite, rate > 0, out.hz <= Self.aliasShare * rate else { return FollowEstimate(sampleRate: rate) }
        return out
    }

    /// rhythm-follow：基础周期 pick（格）正好一半处（插值后 ±0.75 格）有没有够格的峰：局部峰、自相关 ≥ harmonicFloor、
    /// 插值后 ≥ harmonicShare × best（best = 整个搜索范围的最高峰，不是 pick 处的值）。有就返回插值后的滞后和那个峰的自相关，
    /// 没有 nil。只看一次（调用方不再拿结果继续减半）。纯函数：corr 下标 = 滞后格数，minLag − 1 … pick 都要有值
    static func halvedLag(_ corr: [Double], pick: Int, best: Double) -> (lag: Double, peak: Double)? {
        guard pick > minLag, pick < corr.count, best.isFinite else { return nil }
        for k in minLag..<pick where corr[k] >= corr[k - 1] && corr[k] >= corr[k + 1] {
            let den = corr[k - 1] - 2 * corr[k] + corr[k + 1]
            let diff = corr[k - 1] - corr[k + 1]
            let lift = den < -1e-12 ? min(0.25, -diff * diff / (8 * den)) : 0
            let offset = den < -1e-12 ? min(0.5, max(-0.5, 0.5 * diff / den)) : 0
            guard abs(2 * (Double(k) + offset) - Double(pick)) <= 1.5, corr[k] >= harmonicFloor,
                  corr[k] + lift >= harmonicShare * best else { continue }
            return (Double(k) + offset, corr[k])
        }
        return nil
    }

    /// rhythm-phase P2：在频率 hz 附近（±6% 细化）对最近约 2 个周期的主轴速度做最小二乘正弦拟合
    /// v ≈ a·cos ω(τ − t) + b·sin ω(τ − t) + c（3 个参数，线性），直接给出最后一帧时刻 t 的位移相位（没有群延迟）。
    /// - 每个速度样本代表上一帧到这一帧之间的位移，时间取两帧的中点（15 Hz 时 2 Hz 少 24° 的系统误差就是这么来的）；
    /// - lag：速度信号本身已知的滞后（秒；姿态关节的指数平滑），按 ω·lag 补回；
    /// - 主轴：窗口内速度的主成分方向，正方向保持连续（见 PhaseFit）。
    /// 样本不够（< 8 个 / 跨度不到约 1 个周期）或 hz 无效时返回空 PhaseFit（isValid = false）。只读缓冲，不分配
    mutating func phaseFit(hz: Double, lag: Double = 0) -> PhaseFit {
        guard count >= Self.phaseMinSamples, hz.isFinite, hz > 0, lag.isFinite else { return PhaseFit() }
        let cap = Self.capacity
        let tN = times[(head + cap - 1) % cap]
        let window = min(Self.phaseWindowRange.upperBound,
                         max(Self.phaseWindowRange.lowerBound, Self.phaseWindowPeriods / hz))
        let start = (head + cap - count) % cap
        var first = count
        for k in 0..<count where tN - times[(start + k) % cap] <= window {
            first = k
            break
        }
        let n = count - first
        guard n >= Self.phaseMinSamples else { return PhaseFit() }
        let t0 = times[(start + first) % cap]
        let span = tN - t0
        guard span.isFinite, span >= min(0.9 / hz, 0.9 * window) else { return PhaseFit() }
        let meanGap = span / Double(n - 1)
        // 主轴（主成分）
        var mx = 0.0
        var my = 0.0
        for k in first..<count {
            let i = (start + k) % cap
            mx += xs[i]
            my += ys[i]
        }
        mx /= Double(n)
        my /= Double(n)
        var cxx = 0.0
        var cyy = 0.0
        var cxy = 0.0
        for k in first..<count {
            let i = (start + k) % cap
            let dx = xs[i] - mx
            let dy = ys[i] - my
            cxx += dx * dx
            cyy += dy * dy
            cxy += dx * dy
        }
        let trace = cxx + cyy
        guard trace.isFinite, trace > 1e-12 else { return PhaseFit() }
        let disc = (max(0, 0.25 * (cxx - cyy) * (cxx - cyy) + cxy * cxy)).squareRoot()
        let linearity = MotionStats.clamp01((0.5 * trace + disc) / trace)
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        var ux = cos(theta)
        var uy = sin(theta)
        if phaseAxisSet {
            let d = ux * phaseAxisX + uy * phaseAxisY
            if abs(d) >= Self.phaseAxisKeep {
                if d < 0 {
                    ux = -ux
                    uy = -uy
                }
            } else {
                phaseEpoch &+= 1
                Self.conventionalAxis(&ux, &uy)
            }
        } else {
            Self.conventionalAxis(&ux, &uy)
        }
        phaseAxisX = ux
        phaseAxisY = uy
        phaseAxisSet = true
        // 三个频率上拟合，抛物线细化 R² 的峰
        let f0 = hz
        let rm = sineFit(hz: f0 * (1 - Self.phaseSearch), first: first, start: start, tN: tN, meanGap: meanGap,
                         ux: ux, uy: uy)
        let r0 = sineFit(hz: f0, first: first, start: start, tN: tN, meanGap: meanGap, ux: ux, uy: uy)
        let rp = sineFit(hz: f0 * (1 + Self.phaseSearch), first: first, start: start, tN: tN, meanGap: meanGap,
                         ux: ux, uy: uy)
        var best = r0
        var bestHz = f0
        let den = rm.r2 - 2 * r0.r2 + rp.r2
        if den < -1e-12 {
            let offset = min(1, max(-1, 0.5 * (rm.r2 - rp.r2) / den))
            let fr = f0 * (1 + offset * Self.phaseSearch)
            let refined = sineFit(hz: fr, first: first, start: start, tN: tN, meanGap: meanGap, ux: ux, uy: uy)
            if refined.r2 >= best.r2 {
                best = refined
                bestHz = fr
            }
        }
        if rm.r2 > best.r2 {
            best = rm
            bestHz = f0 * (1 - Self.phaseSearch)
        }
        if rp.r2 > best.r2 {
            best = rp
            bestHz = f0 * (1 + Self.phaseSearch)
        }
        let omega = 2 * Double.pi * bestHz
        let r = (best.a * best.a + best.b * best.b).squareRoot()
        guard best.r2.isFinite, best.r2 > 0, r.isFinite, r > 0 else { return PhaseFit() }
        let psi = atan2(-best.b, best.a)
        let phase = Self.wrapPhase(psi - 0.5 * Double.pi + omega * lag)
        return PhaseFit(time: tN, phase: phase, hz: bestHz, quality: MotionStats.clamp01(best.r2),
                        linearity: linearity, amplitude: r / omega, epoch: phaseEpoch, axisX: ux, axisY: uy)
    }

    /// 约定正方向：竖直分量够大取向下（分析帧 y 向下），否则取向右
    private static func conventionalAxis(_ ux: inout Double, _ uy: inout Double) {
        if abs(uy) >= phaseAxisVertical {
            if uy < 0 {
                ux = -ux
                uy = -uy
            }
        } else if ux < 0 {
            ux = -ux
            uy = -uy
        }
    }

    /// 一个频率上的最小二乘：返回 a、b 和 R²（相对样本均值）
    private func sineFit(hz: Double, first: Int, start: Int, tN: Double, meanGap: Double,
                         ux: Double, uy: Double) -> (a: Double, b: Double, r2: Double) {
        let cap = Self.capacity
        let omega = 2 * Double.pi * hz
        var scc = 0.0, sss = 0.0, scs = 0.0, sc = 0.0, ss = 0.0, sn = 0.0
        var syc = 0.0, sys = 0.0, sy = 0.0, syy = 0.0
        for k in first..<count {
            let i = (start + k) % cap
            let t = times[i]
            var mid = t - 0.5 * meanGap
            if k > 0 {
                let gap = t - times[(start + k - 1) % cap]
                if gap >= 0.02, gap <= 0.5 { mid = t - 0.5 * gap }
            }
            let y = xs[i] * ux + ys[i] * uy
            let c = cos(omega * (mid - tN))
            let s = sin(omega * (mid - tN))
            scc += c * c
            sss += s * s
            scs += c * s
            sc += c
            ss += s
            sn += 1
            syc += y * c
            sys += y * s
            sy += y
            syy += y * y
        }
        // [scc scs sc; scs sss ss; sc ss sn] · [a b c]ᵀ = [syc sys sy]ᵀ（克莱姆法则）
        let det = scc * (sss * sn - ss * ss) - scs * (scs * sn - ss * sc) + sc * (scs * ss - sss * sc)
        guard det.isFinite, abs(det) > 1e-9 else { return (0, 0, 0) }
        let da = syc * (sss * sn - ss * ss) - scs * (sys * sn - ss * sy) + sc * (sys * ss - sss * sy)
        let db = scc * (sys * sn - ss * sy) - syc * (scs * sn - ss * sc) + sc * (scs * sy - sys * sc)
        let dc = scc * (sss * sy - sys * ss) - scs * (scs * sy - sys * sc) + syc * (scs * ss - sss * sc)
        let a = da / det
        let b = db / det
        let c = dc / det
        let sst = syy - sy * sy / sn
        guard sst.isFinite, sst > 1e-12 else { return (0, 0, 0) }
        let sse = syy - (a * syc + b * sys + c * sy)
        let r2 = 1 - sse / sst
        guard a.isFinite, b.isFinite, r2.isFinite else { return (0, 0, 0) }
        return (a, b, min(1, max(0, r2)))
    }

    /// 弧度折回 [-π, π)
    static func wrapPhase(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        var v = fmod(x + Double.pi, 2 * Double.pi)
        if v < 0 { v += 2 * Double.pi }
        return v - Double.pi
    }
}

/// 主体强度分数 0~1（algo-opt-3）：速度为主（对数刻度），往复节奏（频率够快 + 自相关可信 + 幅度够大）再往上推。
/// 一直快但没节奏 ≈ 0.72 × 速度分；又快又有节奏 → 1
enum StrokeScore {
    /// 画面块运动：分析帧像素 / 名义帧（1/15 s）；幅度：分析帧像素
    static let flowSpeedLow: Double = 0.7
    static let flowSpeedHigh: Double = 4.5
    static let flowAmplitudeLow: Double = 1
    static let flowAmplitudeHigh: Double = 6
    /// 人体姿态：躯干长度 / 秒（关节位置先按 PoseMotionTracker.jitterSeconds 平滑、位移再减掉 jitterDeadZone 死区，
    /// 静止的人 1.5~2% 躯干的检测抖动 → 0；平滑让快动作的速度读数变小，上限相应从 2.2 降到 1.8）；幅度：躯干长度
    static let poseSpeedLow: Double = 0.14
    static let poseSpeedHigh: Double = 1.8
    static let poseAmplitudeLow: Double = 0.03
    static let poseAmplitudeHigh: Double = 0.25
    static let tempoLow: Double = 0.6
    static let tempoHigh: Double = 1.8
    static let confidenceLow: Double = 0.3
    static let confidenceHigh: Double = 0.7
    static let baseShare: Double = 0.72
    static let rhythmBonus: Double = 0.15

    static func logRamp(_ v: Double, low: Double, high: Double) -> Double {
        guard v.isFinite, low > 0, high > low, v > low else { return 0 }
        return min(1, log(v / low) / log(high / low))
    }

    static func ramp(_ v: Double, low: Double, high: Double) -> Double {
        guard high > low else { return 0 }
        return MotionStats.clamp01((v - low) / (high - low))
    }

    /// 节奏分 0~1
    static func rhythm(_ r: StrokeRhythm.Estimate, amplitudeLow: Double, amplitudeHigh: Double) -> Double {
        let tempo = ramp(r.hz, low: tempoLow, high: tempoHigh)
        let conf = ramp(r.confidence, low: confidenceLow, high: confidenceHigh)
        let amp = logRamp(r.amplitude, low: amplitudeLow, high: amplitudeHigh)
        return MotionStats.clamp01(conf * tempo * (0.4 + 0.6 * amp))
    }

    static func combine(speedScore s: Double, rhythm r: Double) -> Double {
        let s = MotionStats.clamp01(s)
        let r = MotionStats.clamp01(r)
        return MotionStats.clamp01(s * (baseShare + (1 - baseShare) * r) + rhythmBonus * r * s)
    }

    static func flow(speed: Double, rhythm r: StrokeRhythm.Estimate) -> Double {
        combine(speedScore: logRamp(speed, low: flowSpeedLow, high: flowSpeedHigh),
                rhythm: rhythm(r, amplitudeLow: flowAmplitudeLow, amplitudeHigh: flowAmplitudeHigh))
    }

    static func pose(speed: Double, rhythm r: StrokeRhythm.Estimate) -> Double {
        combine(speedScore: logRamp(speed, low: poseSpeedLow, high: poseSpeedHigh),
                rhythm: rhythm(r, amplitudeLow: poseAmplitudeLow, amplitudeHigh: poseAmplitudeHigh))
    }
}

/// 一帧的主体运动读数（algo-opt-3，随 MotionSample 带出）
struct SubjectReading: Equatable {
    /// 这一帧有读数（分析器出的样本都有；老调用方手搭的样本没有 = 走原来的能量映射）
    var valid = false
    /// 主体强度分数 0~1
    var score: Double = 0
    /// 最近 1.2 秒残差速度的 P80（分析帧像素 / 名义帧）
    var speed: Double = 0
    var hz: Double = 0
    /// 节奏可信度 0~1
    var rhythm: Double = 0
    /// 单程幅度（分析帧像素）
    var amplitude: Double = 0
    /// rhythm-follow：StrokeRhythm.followEstimate 的频率 / 置信度 / 单程幅度，只给 RhythmFollower，不进 score
    var followHz: Double = 0
    var followRhythm: Double = 0
    var followAmplitude: Double = 0
    /// rhythm-phase P2：按 followHz 拟合的位移相位（StrokeRhythm.phaseFit），只给 RhythmPhaseLock，不进 score
    var phase = StrokeRhythm.PhaseFit()
}

/// 块运动 → 主体读数（algo-opt-3）：最近 1.2 秒每帧主体速度的 P80 + 往复节奏 → StrokeScore.flow
struct SubjectFlowTracker {
    static let speedWindow: Double = 1.2
    static let capacity = 32

    private var times = [Double](repeating: 0, count: SubjectFlowTracker.capacity)
    private var speeds = [Double](repeating: 0, count: SubjectFlowTracker.capacity)
    private var scratch = [Double](repeating: 0, count: SubjectFlowTracker.capacity)
    private var count = 0
    private var head = 0
    private(set) var rhythm = StrokeRhythm()
    private(set) var reading = SubjectReading()

    var scratchAddresses: [Int] {
        func address<T>(_ a: [T]) -> Int { a.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        return [address(times), address(speeds), address(scratch)] + rhythm.scratchAddresses
    }

    /// rhythm-context P3（L1）：相位拟合开关（默认关 = 不算相位，其它字段不变）
    var phaseFitEnabled = false

    mutating func reset() {
        count = 0
        head = 0
        rhythm.reset()
        reading = SubjectReading()
    }

    /// 切镜：新镜头重新攒历史；读数先保持切镜前的（不出尖峰，也不突然掉到 0）
    mutating func noteCut() {
        count = 0
        head = 0
        rhythm.reset()
    }

    mutating func update(time: Double, speed: Double, vx: Double, vy: Double) -> SubjectReading {
        guard time.isFinite else { return reading }
        let cap = Self.capacity
        if count > 0, time <= times[(head + cap - 1) % cap] {
            count = 0
            head = 0
        }
        times[head] = time
        speeds[head] = speed.isFinite ? max(0, speed) : 0
        head = (head + 1) % cap
        count = min(cap, count + 1)
        rhythm.add(time: time, x: vx, y: vy)
        let start = (head + cap - count) % cap
        var n = 0
        for k in 0..<count {
            let i = (start + k) % cap
            if time - times[i] <= Self.speedWindow {
                scratch[n] = speeds[i]
                n += 1
            }
        }
        let p = MotionStats.quantile(&scratch, n, 0.8)
        let est = rhythm.estimate
        let follow = rhythm.followEstimate
        // rhythm-phase P2：有跟随频率时顺带拟合相位（只读节奏缓冲，不影响上面的估计）
        // rhythm-context P3（修 P2 评审 L1）：只有开着相位脉动（phaseFitEnabled，VideoMotionTap 按开关设）才算
        let phase = phaseFitEnabled && follow.hz > 0 ? rhythm.phaseFit(hz: follow.hz) : StrokeRhythm.PhaseFit()
        reading = SubjectReading(valid: true, score: StrokeScore.flow(speed: p, rhythm: est), speed: p,
                                 hz: est.hz, rhythm: est.confidence, amplitude: est.amplitude,
                                 followHz: follow.hz, followRhythm: follow.confidence,
                                 followAmplitude: follow.amplitude, phase: phase)
        return reading
    }
}

/// 人体关键点（algo-opt-3，Vision VNDetectHumanBodyPoseRequest 的一部分）
enum PoseJoint: Int, CaseIterable {
    case nose, neck, leftShoulder, rightShoulder, root, leftHip, rightHip, leftKnee, rightKnee, leftWrist, rightWrist

    static let count = 11
}

/// 一个人的关键点：分析帧像素坐标（左上角原点，和 CameraTransform 同一套），c 是每个点的置信度 0~1（0 = 没检测到）
struct PoseCandidate: Equatable {
    var confidence: Double = 0
    var x = [Double](repeating: 0, count: PoseJoint.count)
    var y = [Double](repeating: 0, count: PoseJoint.count)
    var c = [Double](repeating: 0, count: PoseJoint.count)

    mutating func set(_ j: PoseJoint, x px: Double, y py: Double, confidence conf: Double) {
        guard px.isFinite, py.isFinite, conf.isFinite, x.count == PoseJoint.count, y.count == PoseJoint.count,
              c.count == PoseJoint.count else { return }
        x[j.rawValue] = px
        y[j.rawValue] = py
        c[j.rawValue] = min(1, max(0, conf))
    }

    var isWellFormed: Bool {
        x.count == PoseJoint.count && y.count == PoseJoint.count && c.count == PoseJoint.count && confidence.isFinite
    }
}

/// 视频轨方向（AVAssetTrack.preferredTransform）：交给 Vision 摆正后检测，结果再换回缓冲（分析帧）坐标
enum PoseOrientation: Int, Equatable {
    case up, down, left, right

    static func from(a: Double, b: Double, c: Double, d: Double) -> PoseOrientation {
        func near(_ v: Double, _ t: Double) -> Bool { abs(v - t) < 0.01 }
        if near(a, 0) && near(b, 1) && near(c, -1) && near(d, 0) { return .right }
        if near(a, 0) && near(b, -1) && near(c, 1) && near(d, 0) { return .left }
        if near(a, -1) && near(b, 0) && near(c, 0) && near(d, -1) { return .down }
        return .up
    }

    /// Vision 归一化坐标（摆正后的画面、左下角原点）→ 缓冲归一化坐标（左上角原点）
    func bufferPoint(visionX vx: Double, visionY vy: Double) -> (x: Double, y: Double) {
        let ux = vx
        let uy = 1 - vy
        switch self {
        case .up: return (ux, uy)
        case .down: return (1 - ux, 1 - uy)
        case .right: return (uy, 1 - ux)
        case .left: return (1 - uy, ux)
        }
    }
}

/// 一次姿态估计的读数（algo-opt-3）
struct PoseReading: Equatable {
    var time: Double = 0
    /// 这一帧有人、且最近 1.2 秒攒够了速度样本
    var present = false
    /// 姿态强度分数 0~1（没人时保持上一次的）
    var score: Double = 0
    /// 这个人的检测置信度 0~1（没人时 0）
    var confidence: Double = 0
    var hz: Double = 0
    /// 这次读数用到的关节可信度 0~1（algo-opt-3 复审 M1）：最近一次算速度时髋这组有可用关节 = 1，
    /// 只有头这组 = 0.5，都没有 = 0。手搭的读数不填 = 1（行为不变）
    var trust: Double = 1
    /// 往复频率跟随（rhythm-follow P1）：髋 / 头 / 腕三组里节奏最可信、幅度够大的那组的频率和自相关置信度
    /// （插入看髋、口交看头、撸动看腕；用 StrokeRhythm.followEstimate）。只给 RhythmFollower 用，不影响 score / hz；
    /// 没人或都不可信时为 0
    var rhythmHz: Double = 0
    var rhythmConfidence: Double = 0
    /// 0 = 没有，1 = 髋，2 = 头，3 = 腕
    var rhythmPart: Int = 0
    /// 挑出的那组最近 4 秒的实际采样率（次 / 秒；慢设备上 Vision 节流时会低到 3 左右，见 RhythmFollower.candidate）
    var rhythmRate: Double = 0
    /// rhythm-phase P2：挑出的那组按 rhythmHz 拟合的位移相位（已补上关节平滑的滞后），只给 RhythmPhaseLock
    var rhythmPhase = StrokeRhythm.PhaseFit()
}

/// 姿态 → 主体强度（algo-opt-3）：关节速度按躯干长度（或肩宽、关节包围框对角线）归一（远近 / 缩放无关），
/// 先扣掉相机运动（块运动给的相似变换），再扣掉全身一致的平移（中位数，只留 40%），
/// 髋和头权重最高；最近 1.2 秒的 P80 + 髋 / 头的往复节奏 → StrokeScore.pose。
/// 没人时读数 present = false、分数保持（由 MotionNormalizer 的 PoseBlend 做滞回和保持）
struct PoseMotionTracker {
    static let minJointConfidence: Double = 0.3
    static let minPersonConfidence: Double = 0.3
    static let minJoints = 4
    static let minMovingJoints = 4
    static let scaleSeconds: Double = 0.8
    static let minScaleShare: Double = 0.06
    static let minGap: Double = 0.02
    static let maxGap: Double = 0.4
    static let maxJointSpeed: Double = 8
    static let speedWindow: Double = 1.2
    static let minSpeedSamples = 3
    /// 全身一致的平移只算 40%（镜头跟拍 / 没扣干净的相机运动）
    static let rigidShare: Double = 0.4
    /// 换人判定：和上一帧（按相机运动预测）的中心距离超过 1.5 个身体尺度就按置信度 × 尺度重选
    static let continuityLimit: Double = 1.5
    static let rhythmGapLimit: Double = 1
    /// 髋 / 头这组关节超过 0.5 秒没有新样本（被挡住 / 出画）：它的旧节奏估计不再加成
    static let rhythmMaxAge: Double = 0.5
    /// 检测抖动（algo-opt-3 复审 M1）：Vision 每帧独立检测、不做平滑，静止的人关键点也会抖 1~2% 躯干。
    /// 每个关节先做时间常数 0.08 秒的指数平滑（按帧间隔算系数，平滑状态随相机运动一起搬），
    /// 再从平滑后的位移里减掉 0.015 躯干的死区；关节置信度低于 0.6 时死区按 0.6 / 置信度放大（0.3 → 2 倍）
    static let jitterSeconds: Double = 0.08
    static let jitterDeadZone: Double = 0.015
    static let jitterConfidenceRef: Double = 0.6
    static let capacity = 24
    static let groups: [[PoseJoint]] = [[.nose, .neck], [.leftShoulder, .rightShoulder], [.root, .leftHip, .rightHip],
                                        [.leftKnee, .rightKnee], [.leftWrist, .rightWrist]]
    static let groupWeights: [Double] = [1.0, 0.7, 1.0, 0.6, 0.35]
    static let headGroup = 0
    static let hipGroup = 2
    /// 只有头这组关节可用（髋 / 膝被挡住或置信度 < 0.3）时的读数可信度
    static let headOnlyTrust: Double = 0.5
    static let wristGroup = 4

    private var previous = PoseCandidate()
    private var hasPrevious = false
    private var previousTime: Double = 0
    private var scale: Double = 0
    private var ux = [Double](repeating: 0, count: PoseJoint.count)
    private var uy = [Double](repeating: 0, count: PoseJoint.count)
    private var usable = [Bool](repeating: false, count: PoseJoint.count)
    /// 平滑后的关节位置（上一次 update 那帧的坐标；下一次先按相机运动搬过来）
    private var smoothX = [Double](repeating: 0, count: PoseJoint.count)
    private var smoothY = [Double](repeating: 0, count: PoseJoint.count)
    private var sortX = [Double](repeating: 0, count: PoseJoint.count)
    private var sortY = [Double](repeating: 0, count: PoseJoint.count)
    private var speedTimes = [Double](repeating: 0, count: PoseMotionTracker.capacity)
    private var speeds = [Double](repeating: 0, count: PoseMotionTracker.capacity)
    private var scratch = [Double](repeating: 0, count: PoseMotionTracker.capacity)
    private var speedCount = 0
    private var speedHead = 0
    private var hips = StrokeRhythm()
    private var head = StrokeRhythm()
    /// 最近一次算速度时的关节可信度（见 PoseReading.trust）
    private var trust: Double = 0
    /// 腕（rhythm-follow P1）：只用来给 rhythmHz（撸动时手腕在往复），不进 score
    private var wrists = StrokeRhythm()
    private(set) var reading = PoseReading()
    /// rhythm-context P3（L1）：相位拟合开关（VideoMotionTap 按「相位脉动」设；默认关 = 不算相位）
    var phaseFitEnabled = false
    /// rhythm-context P3：动作识别开着时才填 bodyContext（默认关 = 不算）
    var contextEnabled = false
    /// rhythm-context P3：这一次 update 的身体位置 / 三组节奏 / 另一个人的髋（给 ActionContext；没开 / 没人时 present = false）
    private(set) var bodyContext = PoseBodyContext()
    private var otherPrevious: (x: Double, y: Double, scale: Double)?
    /// rhythm-action tune（动作识别开着时 PoseWorker 打开；默认关 = 逐位不变）：
    /// 近景只认到身体一部分时按解剖比例估尺度（tunedBodyScale）、死区加倍；另一个人的髋也攒节奏（otherHips）
    var actionTuned = false
    static let partialScaleShare: Double = 0.25
    static let hipWidthTorso: Double = 2
    static let thighTorso: Double = 1
    static let partialDeadZoneScale: Double = 2
    /// 髋已经在往复（节奏置信度 0.3 → 0.6）时，死区加倍 / 尺度下限 0.25 × 画面高按比例撤掉：
    /// 关键点抖动出不来像样的节奏，静止的特写照样压；真的慢慢往复的部分骨架不被死区吃掉
    static let partialRelaxLow: Double = 0.3
    static let partialRelaxHigh: Double = 0.6
    private var otherHips = StrokeRhythm()
    private var otherTime: Double = 0
    private var otherSmoothX: Double = 0
    private var otherSmoothY: Double = 0
    /// rhythm-action tune：左右手腕各自的节奏（轻抚要看摸着身体的那只手自己在不在慢慢动；只在 actionTuned 时攒）
    private var leftWristRhythm = StrokeRhythm()
    private var rightWristRhythm = StrokeRhythm()
    /// 同上，但不扣全身中位速度（只扣了相机）：手跟着上身一起动（骑乘手放胸口、乳交）时扣过的只剩 40%，
    /// 「安静 / 在往复」要两个都看（只在 actionTuned 时攒）
    private var leftWristRaw = StrokeRhythm()
    private var rightWristRaw = StrokeRhythm()

    mutating func reset() {
        bodyContext = PoseBodyContext()
        otherPrevious = nil
        otherHips.reset()
        leftWristRhythm.reset()
        rightWristRhythm.reset()
        leftWristRaw.reset()
        rightWristRaw.reset()
        hasPrevious = false
        scale = 0
        speedCount = 0
        speedHead = 0
        hips.reset()
        head.reset()
        trust = 0
        wrists.reset()
        reading = PoseReading()
    }

    /// 身体尺度（分析帧像素）：max(躯干长度, 1.3 × 肩宽, 0.3 × 关节包围框对角线, 0.06 × 画面高)
    static func bodyScale(_ p: PoseCandidate, frameHeight: Double) -> Double {
        var s = minScaleShare * max(0, frameHeight)
        guard p.isWellFormed else { return s }
        func ok(_ j: PoseJoint) -> Bool { p.c[j.rawValue] >= minJointConfidence }
        func dist(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            ((ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
        }
        let n = PoseJoint.neck.rawValue
        let r = PoseJoint.root.rawValue
        let ls = PoseJoint.leftShoulder.rawValue
        let rs = PoseJoint.rightShoulder.rawValue
        let lh = PoseJoint.leftHip.rawValue
        let rh = PoseJoint.rightHip.rawValue
        if ok(.neck) && ok(.root) {
            s = max(s, dist(p.x[n], p.y[n], p.x[r], p.y[r]))
        } else if ok(.leftShoulder) && ok(.rightShoulder) && ok(.leftHip) && ok(.rightHip) {
            s = max(s, dist((p.x[ls] + p.x[rs]) / 2, (p.y[ls] + p.y[rs]) / 2,
                            (p.x[lh] + p.x[rh]) / 2, (p.y[lh] + p.y[rh]) / 2))
        }
        if ok(.leftShoulder) && ok(.rightShoulder) { s = max(s, 1.3 * dist(p.x[ls], p.y[ls], p.x[rs], p.y[rs])) }
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for j in 0..<PoseJoint.count where p.c[j] >= minJointConfidence {
            minX = min(minX, p.x[j])
            maxX = max(maxX, p.x[j])
            minY = min(minY, p.y[j])
            maxY = max(maxY, p.y[j])
        }
        if maxX >= minX, maxY >= minY { s = max(s, 0.3 * dist(minX, minY, maxX, maxY)) }
        return s.isFinite ? s : minScaleShare * max(0, frameHeight)
    }

    /// rhythm-action tune：近景（臀部 / 胸口特写）Vision 常常只认到几个关节，bodyScale 只能按包围框 × 0.3 或画面高 × 0.06 算，
    /// 比真实的躯干小好几倍，检测抖动除以它就成了「很快的动作」。这里再按解剖比例估：髋宽 × 2、大腿（髋→膝）× 1；
    /// 没有躯干长 / 肩宽可量（partial，只是身体的一部分）时至少 0.25 × 画面高（这么近的身体不会更小）。
    /// 完整的人（躯干 / 肩宽都在）结果和 bodyScale 相同（髋宽 × 2、大腿都比躯干短）；只会变大（速度变小，安全方向）
    static func tunedBodyScale(_ p: PoseCandidate, frameHeight: Double,
                               floorShare: Double = partialScaleShare) -> (scale: Double, partial: Bool) {
        let base = bodyScale(p, frameHeight: frameHeight)
        guard p.isWellFormed else { return (base, true) }
        func ok(_ j: PoseJoint) -> Bool { p.c[j.rawValue] >= minJointConfidence }
        func dist(_ a: PoseJoint, _ b: PoseJoint) -> Double {
            let dx = p.x[a.rawValue] - p.x[b.rawValue]
            let dy = p.y[a.rawValue] - p.y[b.rawValue]
            return (dx * dx + dy * dy).squareRoot()
        }
        let torso = (ok(.neck) && ok(.root)) || (ok(.leftShoulder) && ok(.rightShoulder) && ok(.leftHip) && ok(.rightHip))
        let shoulders = ok(.leftShoulder) && ok(.rightShoulder)
        let partial = !torso && !shoulders
        // 躯干 / 肩宽量得到：就是 bodyScale（髋宽 × 2 在髋抖时可能略超躯干长，完整的人不改尺度）
        guard partial else { return (base, false) }
        var s = base
        if ok(.leftHip) && ok(.rightHip) { s = max(s, hipWidthTorso * dist(.leftHip, .rightHip)) }
        if ok(.leftHip) && ok(.leftKnee) { s = max(s, thighTorso * dist(.leftHip, .leftKnee)) }
        if ok(.rightHip) && ok(.rightKnee) { s = max(s, thighTorso * dist(.rightHip, .rightKnee)) }
        s = max(s, floorShare * max(0, frameHeight))
        return (s.isFinite ? s : base, true)
    }

    /// 尺度：actionTuned 时按 tunedBodyScale，否则原来的 bodyScale。relax：见 partialRelaxLow（0 = 不撤）
    private func scaleOf(_ p: PoseCandidate, frameHeight: Double, relax: Double = 0) -> (scale: Double, partial: Bool) {
        guard actionTuned else { return (Self.bodyScale(p, frameHeight: frameHeight), false) }
        let floor = Self.partialScaleShare - (Self.partialScaleShare - Self.minScaleShare) * relax
        return Self.tunedBodyScale(p, frameHeight: frameHeight, floorShare: floor)
    }

    private static func jointCount(_ p: PoseCandidate) -> Int {
        var n = 0
        for j in 0..<PoseJoint.count where p.c[j] >= minJointConfidence { n += 1 }
        return n
    }

    private static func center(_ p: PoseCandidate) -> (x: Double, y: Double) {
        var sx = 0.0
        var sy = 0.0
        var n = 0.0
        for j in 0..<PoseJoint.count where p.c[j] >= minJointConfidence {
            sx += p.x[j]
            sy += p.y[j]
            n += 1
        }
        return n > 0 ? (sx / n, sy / n) : (0, 0)
    }

    /// switched：有上一帧可以对、但没有候选人在它附近（换了人 / 原来的人不见了），这一帧不能和上一帧算速度
    private func select(_ candidates: [PoseCandidate], camera: CameraTransform, continuous: Bool,
                        frameHeight: Double) -> (index: Int, switched: Bool)? {
        var bestIndex: Int?
        var bestValue = -Double.infinity
        var nearIndex: Int?
        var nearDistance = Double.infinity
        var predicted: (x: Double, y: Double)?
        if hasPrevious && continuous {
            let c = Self.center(previous)
            predicted = camera.apply(x: c.x, y: c.y)
        }
        for (i, p) in candidates.enumerated() {
            guard p.isWellFormed, p.confidence >= Self.minPersonConfidence, Self.jointCount(p) >= Self.minJoints else {
                continue
            }
            let size = Self.bodyScale(p, frameHeight: frameHeight)
            let value = p.confidence * size
            if value > bestValue {
                bestValue = value
                bestIndex = i
            }
            if let q = predicted, size > 0 {
                let c = Self.center(p)
                let d = ((c.x - q.x) * (c.x - q.x) + (c.y - q.y) * (c.y - q.y)).squareRoot() / size
                if d < nearDistance {
                    nearDistance = d
                    nearIndex = i
                }
            }
        }
        if let i = nearIndex, nearDistance <= Self.continuityLimit { return (index: i, switched: false) }
        guard let i = bestIndex else { return nil }
        return (index: i, switched: predicted != nil)
    }

    private mutating func absent(_ time: Double) -> PoseReading {
        reading = PoseReading(time: time, present: false, score: reading.score, confidence: 0, hz: reading.hz)
        return reading
    }

    /// candidates：这一帧检测到的人（分析帧像素）；camera：上一次 update 那帧到这一帧的相机运动；
    /// continuous == false：中间断过（seek / 切镜 / 参考帧），不和上一帧算速度
    mutating func update(time: Double, candidates: [PoseCandidate], camera: CameraTransform, continuous: Bool,
                         frameHeight: Double) -> PoseReading {
        guard time.isFinite, frameHeight.isFinite, frameHeight > 0 else {
            hasPrevious = false
            return absent(time.isFinite ? time : reading.time)
        }
        let cam = camera.isUsable ? camera : .identity
        if contextEnabled { bodyContext = PoseBodyContext() }
        guard let pick = select(candidates, camera: cam, continuous: continuous, frameHeight: frameHeight) else {
            hasPrevious = false
            if contextEnabled {
                otherPrevious = nil
                otherHips.reset()
            }
            return absent(time)
        }
        if contextEnabled {
            noteOther(candidates, picked: pick.index, camera: cam, continuous: continuous, frameHeight: frameHeight,
                      time: time)
        }
        let person = candidates[pick.index]
        // rhythm-action tune：髋已经在往复时撤掉部分骨架的死区加倍 / 尺度下限（只在调优开着时算）
        var relax = 0.0
        if actionTuned {
            let h = hips.freshEstimate(at: time, maxAge: Self.rhythmMaxAge)
            if h.confidence.isFinite {
                relax = StrokeScore.ramp(h.confidence, low: Self.partialRelaxLow, high: Self.partialRelaxHigh)
            }
        }
        let measured = scaleOf(person, frameHeight: frameHeight, relax: relax)
        let size = measured.scale
        // rhythm-action tune：只认到身体一部分时检测抖动大得多，死区加倍（髋在往复时按 relax 撤回；关着时 × 1，逐位不变）
        let zoneScale = actionTuned && measured.partial ? 1 + (Self.partialDeadZoneScale - 1) * (1 - relax) : 1
        let dt = time - previousTime
        let linked = !pick.switched && hasPrevious && continuous && dt > Self.minGap && dt <= Self.maxGap && scale > 0
        if linked {
            scale += (size - scale) * (1 - exp(-dt / Self.scaleSeconds))
            let alpha = 1 - exp(-dt / Self.jitterSeconds)
            var n = 0
            for j in 0..<PoseJoint.count {
                usable[j] = false
                guard person.c[j] >= Self.minJointConfidence, previous.c[j] >= Self.minJointConfidence else {
                    smoothX[j] = person.x[j]
                    smoothY[j] = person.y[j]
                    continue
                }
                // 跳变判定照旧按原始检测位置（误检的关节不进平滑）
                let p = cam.apply(x: previous.x[j], y: previous.y[j])
                let rx = (person.x[j] - p.x) / scale / dt
                let ry = (person.y[j] - p.y) / scale / dt
                guard rx.isFinite, ry.isFinite, (rx * rx + ry * ry).squareRoot() <= Self.maxJointSpeed else {
                    smoothX[j] = person.x[j]
                    smoothY[j] = person.y[j]
                    continue
                }
                let s = cam.apply(x: smoothX[j], y: smoothY[j])
                let mx = alpha * (person.x[j] - s.x)
                let my = alpha * (person.y[j] - s.y)
                smoothX[j] = s.x + mx
                smoothY[j] = s.y + my
                // 平滑后的位移（躯干长度）减掉死区
                let dx = mx / scale
                let dy = my / scale
                let conf = min(person.c[j], previous.c[j])
                let zone = Self.jitterDeadZone * max(1, Self.jitterConfidenceRef / max(conf, Self.minJointConfidence))
                    * zoneScale
                let m = (dx * dx + dy * dy).squareRoot()
                let keep = m > zone ? (m - zone) / m : 0
                let vx = dx * keep / dt
                let vy = dy * keep / dt
                guard vx.isFinite, vy.isFinite else { continue }
                ux[j] = vx
                uy[j] = vy
                usable[j] = true
                sortX[n] = vx
                sortY[n] = vy
                n += 1
            }
            if n >= Self.minMovingJoints {
                let cx = MotionStats.quantile(&sortX, n, 0.5)
                let cy = MotionStats.quantile(&sortY, n, 0.5)
                var speed = 0.0
                for g in 0..<Self.groups.count {
                    var sx = 0.0
                    var sy = 0.0
                    var m = 0
                    for joint in Self.groups[g] where usable[joint.rawValue] {
                        sx += ux[joint.rawValue]
                        sy += uy[joint.rawValue]
                        m += 1
                    }
                    guard m > 0 else { continue }
                    let ex = sx / Double(m) - (1 - Self.rigidShare) * cx
                    let ey = sy / Double(m) - (1 - Self.rigidShare) * cy
                    speed = max(speed, Self.groupWeights[g] * (ex * ex + ey * ey).squareRoot())
                    if g == Self.hipGroup { hips.add(time: time, x: ex, y: ey) }
                    if g == Self.headGroup { head.add(time: time, x: ex, y: ey) }
                    if g == Self.wristGroup { wrists.add(time: time, x: ex, y: ey) }
                }
                if actionTuned {
                    // rhythm-action tune：每只手腕单独攒（同组的扣法：减掉 (1 − rigidShare) × 全身中位速度）
                    let lw = PoseJoint.leftWrist.rawValue
                    let rw = PoseJoint.rightWrist.rawValue
                    if usable[lw] {
                        leftWristRhythm.add(time: time, x: ux[lw] - (1 - Self.rigidShare) * cx,
                                            y: uy[lw] - (1 - Self.rigidShare) * cy)
                        leftWristRaw.add(time: time, x: ux[lw], y: uy[lw])
                    }
                    if usable[rw] {
                        rightWristRhythm.add(time: time, x: ux[rw] - (1 - Self.rigidShare) * cx,
                                             y: uy[rw] - (1 - Self.rigidShare) * cy)
                        rightWristRaw.add(time: time, x: ux[rw], y: uy[rw])
                    }
                }
                let hipUsable = Self.groups[Self.hipGroup].contains { usable[$0.rawValue] }
                let headUsable = Self.groups[Self.headGroup].contains { usable[$0.rawValue] }
                trust = hipUsable ? 1 : (headUsable ? Self.headOnlyTrust : 0)
                pushSpeed(time: time, speed: speed)
            }
        } else {
            scale = size
            for j in 0..<PoseJoint.count {
                smoothX[j] = person.x[j]
                smoothY[j] = person.y[j]
            }
            // 断过（seek / 切镜）、换了人或者人丢了超过 1 秒：节奏重新攒；短暂丢失（检测一闪）不清
            if !continuous || pick.switched || !(time - previousTime <= Self.rhythmGapLimit) {
                hips.reset()
                head.reset()
                wrists.reset()
                leftWristRhythm.reset()
                rightWristRhythm.reset()
                leftWristRaw.reset()
                rightWristRaw.reset()
            }
            // 断过 / 换了人：上一个人的速度历史也不算（新的人重新攒够样本才有读数）
            if !continuous || pick.switched {
                speedCount = 0
                speedHead = 0
                trust = 0
            }
        }
        previous = person
        previousTime = time
        hasPrevious = true
        let cap = Self.capacity
        let start = (speedHead + cap - speedCount) % cap
        var n = 0
        for k in 0..<speedCount {
            let i = (start + k) % cap
            if time - speedTimes[i] <= Self.speedWindow, time >= speedTimes[i] {
                scratch[n] = speeds[i]
                n += 1
            }
        }
        guard n >= Self.minSpeedSamples else { return absent(time) }
        let p80 = MotionStats.quantile(&scratch, n, 0.8)
        // 这组关节最近 0.5 秒没有新样本（被挡住 / 出画）：旧节奏不再加成
        let hipsRhythm = hips.freshEstimate(at: time, maxAge: Self.rhythmMaxAge)
        let headRhythm = head.freshEstimate(at: time, maxAge: Self.rhythmMaxAge)
        let byHips = StrokeScore.pose(speed: p80, rhythm: hipsRhythm)
        let byHead = StrokeScore.pose(speed: p80, rhythm: headRhythm)
        let score = max(byHips, byHead)
        reading = PoseReading(time: time, present: true, score: MotionStats.clamp01(score),
                              confidence: MotionStats.clamp01(person.confidence),
                              hz: byHips >= byHead ? hipsRhythm.hz : headRhythm.hz,
                              trust: MotionStats.clamp01(trust))
        // 频率跟随用 followEstimate（可能减半过、采样率太低时没有），score / hz 仍是上面的基础估计
        let hipsFollow = hips.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
        let headFollow = head.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
        let wristFollow = wrists.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
        let part = Self.rhythmPick(hips: hipsFollow, head: headFollow, wrists: wristFollow)
        if contextEnabled {
            fillBodyContext(time: time, hips: hipsFollow, head: headFollow, wrists: wristFollow)
        }
        if part > 0 {
            let r = part == 1 ? hipsFollow : (part == 2 ? headFollow : wristFollow)
            reading.rhythmHz = r.hz
            reading.rhythmConfidence = MotionStats.clamp01(r.confidence)
            reading.rhythmPart = part
            reading.rhythmRate = r.sampleRate.isFinite ? max(0, r.sampleRate) : 0
            // rhythm-phase P2：那组的相位（只读节奏缓冲；补上 jitterSeconds 指数平滑造成的滞后）
            // rhythm-context P3（L1）：只有开着相位脉动（phaseFitEnabled）才算
            let lag = Self.smoothingLag(hz: r.hz, rate: reading.rhythmRate)
            switch phaseFitEnabled ? part : 0 {
            case 0: break
            case 1: reading.rhythmPhase = hips.phaseFit(hz: r.hz, lag: lag)
            case 2: reading.rhythmPhase = head.phaseFit(hz: r.hz, lag: lag)
            default: reading.rhythmPhase = wrists.phaseFit(hz: r.hz, lag: lag)
            }
        }
        return reading
    }

    /// rhythm-context P3：另一个人（不是跟踪的这个）的髋 / 头：先找上一帧那个人附近 1.5 个身体尺度内的，
    /// 没有就按 置信度 × 尺度 挑最大的（同 select 的换人规则）
    private mutating func noteOther(_ candidates: [PoseCandidate], picked: Int, camera: CameraTransform, continuous: Bool,
                                    frameHeight: Double, time: Double) {
        var best: (x: Double, y: Double, scale: Double, headX: Double, headY: Double, hasHead: Bool)?
        var bestValue = -Double.infinity
        var near: (x: Double, y: Double, scale: Double, headX: Double, headY: Double, hasHead: Bool)?
        var nearDistance = Double.infinity
        let predicted = continuous ? otherPrevious.map { camera.apply(x: $0.x, y: $0.y) } : nil
        for (i, p) in candidates.enumerated() where i != picked {
            guard p.isWellFormed, p.confidence >= Self.minPersonConfidence, Self.jointCount(p) >= Self.minJoints,
                  let hip = Self.hipCenter(p) else { continue }
            let size = scaleOf(p, frameHeight: frameHeight).scale
            let head = Self.headPoint(p)
            let entry = (x: hip.x, y: hip.y, scale: size, headX: head?.x ?? 0, headY: head?.y ?? 0, hasHead: head != nil)
            let value = p.confidence * size
            if value > bestValue {
                bestValue = value
                best = entry
            }
            if let q = predicted, size > 0 {
                let d = ((hip.x - q.x) * (hip.x - q.x) + (hip.y - q.y) * (hip.y - q.y)).squareRoot() / size
                if d < nearDistance {
                    nearDistance = d
                    near = entry
                }
            }
        }
        let linkedOther = nearDistance <= Self.continuityLimit
        let chosen = linkedOther ? near : best
        guard let o = chosen else {
            otherPrevious = nil
            otherHips.reset()
            return
        }
        if actionTuned { trackOtherHips(o.x, o.y, scale: o.scale, linked: linkedOther, camera: camera, time: time) }
        otherPrevious = (o.x, o.y, o.scale)
        bodyContext.hasOtherHip = true
        bodyContext.otherHipX = o.x
        bodyContext.otherHipY = o.y
        bodyContext.otherScale = o.scale
        bodyContext.hasOtherHead = o.hasHead
        bodyContext.otherHeadX = o.headX
        bodyContext.otherHeadY = o.headY
        if actionTuned {
            let f = otherHips.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
            var phase = StrokeRhythm.PhaseFit()
            if phaseFitEnabled, f.hz > 0 {
                let rate = f.sampleRate.isFinite ? max(0, f.sampleRate) : 0
                phase = otherHips.phaseFit(hz: f.hz, lag: Self.smoothingLag(hz: f.hz, rate: rate))
            }
            bodyContext.otherHips = PartRhythm(follow: f, phase: phase)
        }
    }

    /// rhythm-action tune：另一个人的髋心（扣掉相机运动、按他自己的尺度归一、同样的指数平滑 + 死区）→ otherHips 节奏。
    /// linked：和上一帧是同一个人（连续性 ≤ 1.5 尺度）；换了人 / 断过就重攒
    private mutating func trackOtherHips(_ x: Double, _ y: Double, scale: Double, linked: Bool, camera: CameraTransform,
                                         time: Double) {
        let dt = time - otherTime
        otherTime = time
        guard linked, let prev = otherPrevious, scale > 0, scale.isFinite else {
            otherHips.reset()
            otherSmoothX = x
            otherSmoothY = y
            return
        }
        guard dt > Self.minGap, dt <= Self.maxGap else {
            otherSmoothX = x
            otherSmoothY = y
            return
        }
        let p = camera.apply(x: prev.x, y: prev.y)
        let rx = (x - p.x) / scale / dt
        let ry = (y - p.y) / scale / dt
        guard rx.isFinite, ry.isFinite, (rx * rx + ry * ry).squareRoot() <= Self.maxJointSpeed else {
            otherSmoothX = x
            otherSmoothY = y
            return
        }
        let s = camera.apply(x: otherSmoothX, y: otherSmoothY)
        let alpha = 1 - exp(-dt / Self.jitterSeconds)
        let mx = alpha * (x - s.x)
        let my = alpha * (y - s.y)
        otherSmoothX = s.x + mx
        otherSmoothY = s.y + my
        let dx = mx / scale
        let dy = my / scale
        let m = (dx * dx + dy * dy).squareRoot()
        let keep = m > Self.jitterDeadZone ? (m - Self.jitterDeadZone) / m : 0
        otherHips.add(time: time, x: dx * keep / dt, y: dy * keep / dt)
    }

    /// 髋中心：root，或左右髋的中点（置信度 ≥ 0.3）
    static func hipCenter(_ p: PoseCandidate) -> (x: Double, y: Double)? {
        guard p.isWellFormed else { return nil }
        let r = PoseJoint.root.rawValue
        let lh = PoseJoint.leftHip.rawValue
        let rh = PoseJoint.rightHip.rawValue
        if p.c[lh] >= minJointConfidence && p.c[rh] >= minJointConfidence {
            return ((p.x[lh] + p.x[rh]) / 2, (p.y[lh] + p.y[rh]) / 2)
        }
        if p.c[r] >= minJointConfidence { return (p.x[r], p.y[r]) }
        if p.c[lh] >= minJointConfidence { return (p.x[lh], p.y[lh]) }
        if p.c[rh] >= minJointConfidence { return (p.x[rh], p.y[rh]) }
        return nil
    }

    /// 头：鼻子，没有就脖子
    static func headPoint(_ p: PoseCandidate) -> (x: Double, y: Double)? {
        guard p.isWellFormed else { return nil }
        for j in [PoseJoint.nose, PoseJoint.neck] where p.c[j.rawValue] >= minJointConfidence {
            return (p.x[j.rawValue], p.y[j.rawValue])
        }
        return nil
    }

    /// rhythm-action tune：胸口锚点：两肩中点，没有就用脖子
    static func chestPoint(_ p: PoseCandidate) -> (x: Double, y: Double)? {
        guard p.isWellFormed else { return nil }
        let ls = PoseJoint.leftShoulder.rawValue
        let rs = PoseJoint.rightShoulder.rawValue
        if p.c[ls] >= minJointConfidence && p.c[rs] >= minJointConfidence {
            return ((p.x[ls] + p.x[rs]) / 2, (p.y[ls] + p.y[rs]) / 2)
        }
        let n = PoseJoint.neck.rawValue
        if p.c[n] >= minJointConfidence { return (p.x[n], p.y[n]) }
        return nil
    }

    /// 两腕的平均位置
    static func wristPoint(_ p: PoseCandidate) -> (x: Double, y: Double)? {
        guard p.isWellFormed else { return nil }
        var sx = 0.0
        var sy = 0.0
        var n = 0.0
        for j in [PoseJoint.leftWrist, PoseJoint.rightWrist] where p.c[j.rawValue] >= minJointConfidence {
            sx += p.x[j.rawValue]
            sy += p.y[j.rawValue]
            n += 1
        }
        return n > 0 ? (sx / n, sy / n) : nil
    }

    /// rhythm-context P3：跟踪的这个人这一帧的位置 + 三组节奏（相位只在 phaseFitEnabled 时算，补平滑滞后同 P2）
    private mutating func fillBodyContext(time: Double, hips hf: StrokeRhythm.FollowEstimate,
                                          head hd: StrokeRhythm.FollowEstimate, wrists wf: StrokeRhythm.FollowEstimate) {
        var c = bodyContext
        c.present = true
        c.time = time
        c.scale = scale
        if let p = Self.hipCenter(previous) {
            c.hasHip = true
            c.hipX = p.x
            c.hipY = p.y
        }
        if let p = Self.headPoint(previous) {
            c.hasHead = true
            c.headX = p.x
            c.headY = p.y
        }
        if let p = Self.wristPoint(previous) {
            c.hasWrist = true
            c.wristX = p.x
            c.wristY = p.y
        }
        if actionTuned {
            if let p = Self.chestPoint(previous) {
                c.hasChest = true
                c.chestX = p.x
                c.chestY = p.y
            }
            let lw = PoseJoint.leftWrist.rawValue
            let rw = PoseJoint.rightWrist.rawValue
            if previous.c[lw] >= Self.minJointConfidence {
                c.hasLeftWrist = true
                c.leftWristX = previous.x[lw]
                c.leftWristY = previous.y[lw]
            }
            if previous.c[rw] >= Self.minJointConfidence {
                c.hasRightWrist = true
                c.rightWristX = previous.x[rw]
                c.rightWristY = previous.y[rw]
            }
            c.leftWristRhythm = leftWristRhythm.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
            c.rightWristRhythm = rightWristRhythm.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
            c.leftWristRaw = leftWristRaw.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
            c.rightWristRaw = rightWristRaw.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
        }
        func fit(_ r: inout StrokeRhythm, _ f: StrokeRhythm.FollowEstimate) -> StrokeRhythm.PhaseFit {
            guard phaseFitEnabled, f.hz > 0 else { return StrokeRhythm.PhaseFit() }
            let rate = f.sampleRate.isFinite ? max(0, f.sampleRate) : 0
            return r.phaseFit(hz: f.hz, lag: Self.smoothingLag(hz: f.hz, rate: rate))
        }
        c.hips = PartRhythm(follow: hf, phase: fit(&hips, hf))
        c.head = PartRhythm(follow: hd, phase: fit(&head, hd))
        c.wrists = PartRhythm(follow: wf, phase: fit(&wrists, wf))
        bodyContext = c
    }

    /// rhythm-phase P2：关节位置按 jitterSeconds 做的离散指数平滑在 hz 上的时间滞后（秒）。
    /// rate：采样率（次 / 秒）；H(z) = α / (1 − (1 − α)z⁻¹)，α = 1 − e^(−Δ/τ)，滞后 = −arg H / ω
    static func smoothingLag(hz: Double, rate: Double) -> Double {
        guard hz.isFinite, hz > 0, rate.isFinite, rate > 0 else { return 0 }
        let step = 1 / rate
        let alpha = 1 - exp(-step / jitterSeconds)
        let omega = 2 * Double.pi * hz
        let lagPhase = atan2((1 - alpha) * sin(omega * step), 1 - (1 - alpha) * cos(omega * step))
        let lag = lagPhase / omega
        return lag.isFinite ? max(0, lag) : 0
    }

    /// rhythm-follow P1：三组里挑「自相关置信度 × 幅度够不够」最高的一组（1 髋 / 2 头 / 3 腕，0 = 都不行）。
    /// 幅度低于 StrokeScore.poseAmplitudeLow（0.03 躯干长度）的是抖动 / 点头，不算往复
    static func rhythmPick(hips: StrokeRhythm.FollowEstimate, head: StrokeRhythm.FollowEstimate,
                           wrists: StrokeRhythm.FollowEstimate) -> Int {
        var best = 0
        var bestValue = 0.0
        for (i, r) in [hips, head, wrists].enumerated() {
            guard r.hz.isFinite, r.hz > 0, r.confidence.isFinite, r.amplitude.isFinite,
                  r.amplitude >= StrokeScore.poseAmplitudeLow else { continue }
            let v = r.confidence * (0.6 + 0.4 * StrokeScore.ramp(r.amplitude, low: StrokeScore.poseAmplitudeLow,
                                                                  high: StrokeScore.poseAmplitudeHigh))
            if v > bestValue {
                bestValue = v
                best = i + 1
            }
        }
        return best
    }

    private mutating func pushSpeed(time: Double, speed: Double) {
        let cap = Self.capacity
        speedTimes[speedHead] = time
        speeds[speedHead] = speed.isFinite ? max(0, speed) : 0
        speedHead = (speedHead + 1) % cap
        speedCount = min(cap, speedCount + 1)
    }
}

/// 姿态和块运动的融合（algo-opt-3，MotionNormalizer 里每拍一次）：累计有人 ≥ 0.55 秒（至少 2 拍）才开始用姿态，
/// 没人 0.9 秒内保持上一次的姿态分数，权重 1 秒升到最多 0.8、1.5 秒降回 0（检测一闪一闪不出尖峰）。
/// 复审 M1：姿态只能细化、不能否决强的块运动——认到的人可能不是在动的那个（多人画面里静止的更清楚），
/// 或者髋 / 膝置信度不够、只剩静止的上半身。输出不低于 flow × (1 − 0.4 × 权重)（满权重时 0.68 × flow），
/// 读数可信度低（没有可用的髋关节）时权重再按 0.5 + 0.5 × 可信度收
struct PoseBlend {
    static let confirmSeconds: TimeInterval = 0.55
    static let holdSeconds: TimeInterval = 0.9
    static let rampUpSeconds: TimeInterval = 1.0
    static let rampDownSeconds: TimeInterval = 1.5
    static let maxWeight: Double = 0.8
    /// 姿态最多把块运动分数往下拉 0.4 × 权重
    static let flowFloorShare: Double = 0.4
    static let minTrustFactor: Double = 0.5
    /// rhythm-action tune（tuned = true 时）：姿态分数不能比画面本身的运动高太多——最多 0.1 + 2 × 块运动分数。
    /// 静止的近景（臀部 / 胸口特写）里 Vision 关键点自己在抖，姿态会报出「很快」，画面却几乎没动；
    /// 真的大幅往复时块运动分数本身就不低（主体 P80 和面积无关），这个上界几乎不起作用
    static let tunedSupportBase: Double = 0.1
    static let tunedSupportSlope: Double = 2
    /// 这个上界只在姿态没有像样的节奏时用：髋 / 头这组节奏置信度 ≥ 0.4（关键点抖动出不来）= 真的往复，
    /// 低纹理近景里块运动偏小时姿态照常起作用
    static let tunedRhythmConfidence: Double = 0.4

    private(set) var weight: Double = 0
    private(set) var heldScore: Double = 0
    private var heldConfidence: Double = 0
    private var heldTrust: Double = 1
    private var presentRun: TimeInterval = 0
    private var absentRun: TimeInterval = .infinity

    mutating func reset() {
        self = PoseBlend()
    }

    mutating func step(_ w: MotionWindow, flow: Double, dt: TimeInterval, tuned: Bool = false) -> Double {
        let flow = MotionStats.clamp01(flow)
        if w.posePresentFrames > 0, w.poseScore.isFinite {
            presentRun += dt
            absentRun = 0
            heldScore = MotionStats.clamp01(w.poseScore)
            heldConfidence = MotionStats.clamp01(w.poseConfidence)
            heldTrust = w.poseTrust.isFinite ? MotionStats.clamp01(w.poseTrust) : 0
        } else {
            // 切了镜头、新画面里没人：不保持切镜前的姿态分数，直接开始降权重
            if w.cutCount > 0 { absentRun = max(absentRun, Self.holdSeconds) }
            absentRun += dt
            if absentRun > Self.holdSeconds { presentRun = 0 }
        }
        let trustFactor = Self.minTrustFactor + (1 - Self.minTrustFactor) * heldTrust
        let confFactor = (0.5 + 0.5 * MotionStats.clamp01((heldConfidence - 0.3) / 0.3)) * trustFactor
        let target = presentRun >= Self.confirmSeconds && absentRun <= Self.holdSeconds ? Self.maxWeight * confFactor : 0
        let rate = Self.maxWeight / (target > weight ? Self.rampUpSeconds : Self.rampDownSeconds)
        if target > weight {
            weight = min(target, weight + rate * dt)
        } else {
            weight = max(target, weight - rate * dt)
        }
        if !weight.isFinite { weight = 0 }
        var poseScore = heldScore
        if tuned && !Self.rhythmicPose(w) {
            poseScore = min(poseScore, Self.tunedSupportBase + Self.tunedSupportSlope * flow)
        }
        let blended = weight * poseScore + (1 - weight) * flow
        return MotionStats.clamp01(max(blended, flow * (1 - Self.flowFloorShare * weight)))
    }

    /// 这一拍姿态的节奏来自髋 / 头（姿态分数就是按这两组算的），且置信度够
    static func rhythmicPose(_ w: MotionWindow) -> Bool {
        w.posePresentFrames > 0 && (w.poseRhythmPart == 1 || w.poseRhythmPart == 2)
            && w.poseRhythmConfidence.isFinite && w.poseRhythmConfidence >= tunedRhythmConfidence
    }
}

/// 一拍（约 0.3 秒）的画面窗口。frames == 0 表示这段没有画面样本（暂停 / 缓冲 / 无视频轨 / 分析暂停）
struct MotionWindow: Equatable {
    var meanEnergy: Double = 0
    var peakEnergy: Double = 0
    var frames: Int = 0
    var cutCount: Int = 0
    var heldCount: Int = 0
    /// 窗口内样本的平均覆盖率 / 平均近场分数（algo-opt-1；老调用方不填 = 0，行为不变）
    var coverage: Double = 0
    var nearField: Double = 0
    /// 主体运动（algo-opt-3）：有效主体读数的样本数、平均主体分数 0~1、最后一个的往复频率。
    /// subjectFrames > 0 时 MotionNormalizer 按主体分数映射（不再看画面变化的面积 / 整幅均值）
    var subjectFrames: Int = 0
    var subjectScore: Double = 0
    var subjectHz: Double = 0
    /// 人体姿态（algo-opt-3，Vision 辅助）：这一拍跑了几次、几次有人；最后一次有人时的分数 / 置信度
    var poseFrames: Int = 0
    var posePresentFrames: Int = 0
    var poseScore: Double = 0
    var poseConfidence: Double = 0
    /// 最后一次有人时的关节可信度（PoseReading.trust；手搭的窗口不填 = 1）
    var poseTrust: Double = 1
    /// 往复频率跟随（rhythm-follow P1）：块运动主体最后一个读数的跟随频率 / 置信度 / 单程幅度（分析帧像素；
    /// SubjectReading.follow*，切镜 / 保持期样本带的是切镜前的读数，记 0），
    /// 姿态最后一次有人时挑出的那组节奏（PoseReading.rhythmHz / rhythmConfidence / rhythmPart / rhythmRate）。
    /// subjectHz 仍是 algo-opt-3 的基础估计，不给跟随用
    var subjectFollowHz: Double = 0
    var subjectFollowRhythm: Double = 0
    var subjectFollowAmplitude: Double = 0
    var poseRhythmHz: Double = 0
    var poseRhythmConfidence: Double = 0
    var poseRhythmPart: Int = 0
    var poseRhythmRate: Double = 0
    /// rhythm-phase P2：这一拍里块运动主体 / 姿态最后一个有效的相位拟合（切镜 / 保持期样本不带；切镜清掉姿态的）。
    /// 只给 RhythmPhaseLock；不影响上面任何字段
    var subjectPhase = StrokeRhythm.PhaseFit()
    var posePhase = StrokeRhythm.PhaseFit()
    /// rhythm-context P3：这一拍最后一个有效的周期区域读数（切镜 / 保持期样本不带）和有效读数的样本数；
    /// 最后一次的手 / 脸 / 身体上下文（切镜清掉、切镜前的帧算出来的不认）。动作识别关着时都是空的。
    /// 只给 ActionContext 改写交给频率跟随 / 相位锁的那份窗口副本；MotionNormalizer 不看
    var roi = RoiReading()
    var roiFrames: Int = 0
    var context = PoseContext()

    static let empty = MotionWindow()

    /// 代表值：均值为主、峰值保留瞬态（思路同 AudioReactiveShaper.rmsWeight）
    var representative: Double { frames > 0 ? 0.6 * meanEnergy + 0.4 * peakEnergy : 0 }
    /// 没有切换 / 保持期样本：可以用来更新参考值
    var settled: Bool { cutCount == 0 && heldCount == 0 }
}

/// 窗口累加（照 AudioWindowAccumulator）：取走即清零，坏样本不进窗口
struct MotionWindowAccumulator {
    private var sum: Double = 0
    private(set) var peak: Double = 0
    private(set) var frames = 0
    private(set) var cutCount = 0
    private(set) var heldCount = 0
    private var coverageSum: Double = 0
    private var nearSum: Double = 0
    private var subjectSum: Double = 0
    private(set) var subjectFrames = 0
    private var subjectHz: Double = 0
    private var poseFrames = 0
    private var posePresentFrames = 0
    private var poseScore: Double = 0
    private var poseConfidence: Double = 0
    private var poseTrust: Double = 1
    /// 最近一个切镜样本的时间（复审 L1）：跨拍保留（drain 不清；seek 时 VideoMotionMeter.reset 整个换新）。
    /// 比它早的帧算出来的姿态读数（Vision 异步，切镜后才回来）不算有人
    private var lastCutTime: Double = -.infinity
    private var subjectFollowHz: Double = 0
    private var subjectFollowRhythm: Double = 0
    private var subjectFollowAmplitude: Double = 0
    private var poseRhythmHz: Double = 0
    private var poseRhythmConfidence: Double = 0
    private var poseRhythmPart = 0
    private var poseRhythmRate: Double = 0
    private var subjectPhase = StrokeRhythm.PhaseFit()
    private var posePhase = StrokeRhythm.PhaseFit()
    private var roi = RoiReading()
    private var roiFrames = 0
    private var context = PoseContext()

    mutating func add(_ s: MotionSample) {
        guard s.energy.isFinite, s.energy >= 0 else { return }
        if s.isCut {
            // 同一拍里切镜前的姿态读数作废：这一拍按「切镜、新画面还没人」处理，PoseBlend 不保持旧人的分数
            if s.time.isFinite { lastCutTime = max(lastCutTime, s.time) }
            posePresentFrames = 0
            poseScore = 0
            poseConfidence = 0
            poseTrust = 1
            poseRhythmHz = 0
            poseRhythmConfidence = 0
            poseRhythmPart = 0
            poseRhythmRate = 0
            posePhase = StrokeRhythm.PhaseFit()
            subjectPhase = StrokeRhythm.PhaseFit()
            roi = RoiReading()
            roiFrames = 0
            context = PoseContext()
        }
        if !s.isCut, !s.isHeld, s.roi.valid || s.roi.region.valid {
            roi = s.roi
            if s.roi.valid { roiFrames += 1 }
        }
        sum += s.energy
        if s.coverage.isFinite { coverageSum += min(1, max(0, s.coverage)) }
        if s.nearField.isFinite { nearSum += min(1, max(0, s.nearField)) }
        peak = max(peak, s.energy)
        frames += 1
        if s.isCut { cutCount += 1 }
        if s.isHeld { heldCount += 1 }
        if s.subject.valid, s.subject.score.isFinite {
            subjectSum += min(1, max(0, s.subject.score))
            subjectFrames += 1
            subjectHz = s.subject.hz.isFinite ? s.subject.hz : 0
            // 切镜 / 保持期的样本带的是切镜前的读数：频率跟随不认（不然切到别的画面还按旧节奏重新锁定）
            let fresh = !s.isCut && !s.isHeld
            subjectFollowHz = fresh && s.subject.followHz.isFinite ? max(0, s.subject.followHz) : 0
            subjectFollowRhythm = fresh && s.subject.followRhythm.isFinite ? min(1, max(0, s.subject.followRhythm)) : 0
            subjectFollowAmplitude = fresh && s.subject.followAmplitude.isFinite ? max(0, s.subject.followAmplitude) : 0
            // rhythm-phase P2：同样只认新鲜样本；这一拍里留最后一个有效的（带时间戳，主线程按时间外推）
            if fresh, s.subject.phase.isValid { subjectPhase = s.subject.phase }
        }
    }

    /// 一次姿态估计（algo-opt-3）：只记次数和最后一次有人时的分数（姿态本身已经按 1.2 秒平滑）
    mutating func addPose(_ r: PoseReading) {
        poseFrames += 1
        guard r.present, r.score.isFinite, r.confidence.isFinite else { return }
        // 切镜前那些帧的读数（切镜样本之后才回来的）不算
        guard !(r.time < lastCutTime) else { return }
        posePresentFrames += 1
        poseScore = min(1, max(0, r.score))
        poseConfidence = min(1, max(0, r.confidence))
        poseTrust = r.trust.isFinite ? min(1, max(0, r.trust)) : 0
        let ok = r.rhythmHz.isFinite && r.rhythmHz > 0 && r.rhythmConfidence.isFinite
        poseRhythmHz = ok ? r.rhythmHz : 0
        poseRhythmConfidence = ok ? min(1, max(0, r.rhythmConfidence)) : 0
        poseRhythmPart = ok ? r.rhythmPart : 0
        poseRhythmRate = ok && r.rhythmRate.isFinite ? max(0, r.rhythmRate) : 0
        // rhythm-phase P2：最后一次有人时那组的相位（没有有效拟合就清掉，不留旧组的）
        posePhase = ok && r.rhythmPhase.isValid ? r.rhythmPhase : StrokeRhythm.PhaseFit()
    }

    /// rhythm-context P3：一次手 / 脸 / 身体上下文（姿态队列；切镜前那些帧算出来的不认）
    mutating func addContext(_ c: PoseContext) {
        guard c.time.isFinite, !(c.time < lastCutTime) else { return }
        context = c
    }

    mutating func drain() -> MotionWindow {
        var window = MotionWindow.empty
        if frames > 0 {
            window = MotionWindow(meanEnergy: sum / Double(frames), peakEnergy: peak, frames: frames,
                                  cutCount: cutCount, heldCount: heldCount,
                                  coverage: coverageSum / Double(frames), nearField: nearSum / Double(frames))
            if subjectFrames > 0 {
                window.subjectFrames = subjectFrames
                window.subjectScore = subjectSum / Double(subjectFrames)
                window.subjectHz = subjectHz
                window.subjectFollowHz = subjectFollowHz
                window.subjectFollowRhythm = subjectFollowRhythm
                window.subjectFollowAmplitude = subjectFollowAmplitude
                window.subjectPhase = subjectPhase
            }
        }
        window.poseFrames = poseFrames
        window.posePresentFrames = posePresentFrames
        window.poseScore = poseScore
        window.poseConfidence = poseConfidence
        window.poseTrust = poseTrust
        let cut = lastCutTime
        window.poseRhythmHz = poseRhythmHz
        window.poseRhythmConfidence = poseRhythmConfidence
        window.poseRhythmPart = poseRhythmPart
        window.poseRhythmRate = poseRhythmRate
        window.posePhase = posePhase
        window.roi = roi
        window.roiFrames = roiFrames
        window.context = context
        self = MotionWindowAccumulator()
        lastCutTime = cut
        return window
    }
}

/// 画面能量 → 0~100（§4.8）：对数压缩 + 快升慢降的参考值跟踪这个视频自己的运动范围，「动得多」映射到 75%，
/// 自动适应和固定尺度各占一半（同声音侧只补一半差距）。
/// 实施时按测试调整（文档允许调常量）：
/// - 下参考取 min(refLow, refHigh − 最小跨度)：一直在动的视频 refLow 会追上 refHigh，按原式会把动作段压到很低；
/// - refHigh 不低于 ln(1 + 2.5)：讲话、轻微晃动的画面（e ≲ 1）不会被当成「动得多」放大；
/// - refHigh 初值 ln(1 + 3)（原稿 ln 7）：40 秒内小动作视频也能用满范围。
struct MotionNormalizer {
    /// e_win 低于这个当静止：输出 0，也不学习
    static let absoluteGate: Double = 0.5
    static let minSpan: Double = 0.8
    /// 「动得多」映射到 75%（原 85%）
    static let targetPercent: Double = 75
    /// 自动适应只占一半，另一半按固定尺度：安静的片子保持偏轻，一个手势不会被当成最激烈（真机反馈 2026-10-16）
    static let adaptiveWeight: Double = 0.5
    static let fixedRatioCap: Double = 1.15
    static let warmUpSeconds: TimeInterval = 3
    static let initialHigh: Double = log(4.0)
    static let initialLow: Double = log(1.8)
    static let minHigh: Double = log(3.5)
    /// 关掉「自动适应画面」时的固定参考
    static let fixedHigh: Double = log(13.0)
    static let fixedLow: Double = log(1.8)
    static let highRiseSeconds: TimeInterval = 2
    static let highFallSeconds: TimeInterval = 25
    static let lowRiseSeconds: TimeInterval = 20
    static let lowFallSeconds: TimeInterval = 1.5
    /// 近场 / 遮挡（algo-opt-1）：ratio 向「固定尺度的 60%」收拢 N 倍（同一拍只降不升）；N ≥ 0.5 的窗口不学参考值
    static let nearFieldFixedShare: Double = 0.6
    static let nearFieldLearnLimit: Double = 0.5

    /// 主体分数映射（algo-opt-3）：近场时往 0.3 收；自动适应只做两件事——减掉这个视频安静时的底（最多 0.08），
    /// 动作一直偏小的视频最多放大 1.25 倍（「动得多」0.7 以上不放大）。从不压低：持续的快速抽插不会被压到中档
    static let subjectNearFloor: Double = 0.3
    static let subjectBaseLimit: Double = 0.08
    static let subjectTargetHigh: Double = 0.7
    static let subjectMaxStretch: Double = 1.25
    static let subjectInitialHigh: Double = 0.7
    static let subjectInitialLow: Double = 0.08
    /// rhythm-action tune（actionTuned，动作识别开着时 VideoSyncPlayer 每拍设；默认关 = 逐位不变）：
    /// 慢 / 轻的动作（轻抚、摸胸口、呼吸起伏）按绝对刻度压低，不再被相对的自动适应放大：
    /// - gentle：分数 s 乘 0.35 + 0.65 × ramp(s, 0.2 → 0.55)（0.2 → 0.07、0.3 → 0.16、0.4 → 0.29、≥ 0.55 不变）；
    /// - 自动适应的放大（最多 × 1.25）只给分数 ≥ 0.45 的动作，0.45 → 0.6 线性放开；减底照旧
    static let gentleLow: Double = 0.2
    static let gentleHigh: Double = 0.55
    static let gentleFloorShare: Double = 0.35
    static let stretchFromScore: Double = 0.45
    static let stretchFullScore: Double = 0.6

    private(set) var refHigh: Double = MotionNormalizer.initialHigh
    private(set) var refLow: Double = MotionNormalizer.initialLow
    private(set) var warmElapsed: TimeInterval = 0
    /// 主体分数的参考值（algo-opt-3；同 refHigh / refLow 的快升慢降 / 快降慢升）
    private(set) var scoreHigh: Double = MotionNormalizer.subjectInitialHigh
    private(set) var scoreLow: Double = MotionNormalizer.subjectInitialLow
    private(set) var pose = PoseBlend()
    /// 连续没有画面样本的时长（发热暂停 / 缓冲）：超过姿态保持时间，恢复后姿态融合从头确认
    private var idleRun: TimeInterval = 0
    /// rhythm-action tune：见 gentleLow（默认关）
    var actionTuned = false
    /// rhythm-action tune：这一拍能不能用 gentle / 放大门槛（VideoSyncPlayer 每拍按上一拍的动作识别设：
    /// 轻抚 / 节奏只来自摸着自己的手 = true；其余 false）。画面完全没有节奏时（unrhythmic）不看这个也压。只在 actionTuned 时看
    var gentleAllowed = true

    /// rhythm-action tune：画面里没有任何节奏（块运动 / 姿态的跟随置信度都 < quietRhythm）= 静止画面的噪声 / 近景抖动的正面依据，
    /// 不管动作识别怎么判都可以 gentle；有一点节奏（慢的、不规则的真往复）不算
    static let quietRhythm: Double = 0.25
    static func unrhythmic(_ w: MotionWindow) -> Bool {
        let flow = w.subjectFollowRhythm.isFinite ? w.subjectFollowRhythm : 0
        let pose = w.posePresentFrames > 0 && w.poseRhythmConfidence.isFinite ? w.poseRhythmConfidence : 0
        return flow < quietRhythm && pose < quietRhythm
    }

    /// rhythm-action tune：慢 / 轻动作的绝对压低（纯函数，0~1 → 0~1，单调、不升）
    static func gentle(_ s: Double) -> Double {
        let v = MotionStats.clamp01(s)
        return v * (gentleFloorShare + (1 - gentleFloorShare) * StrokeScore.ramp(v, low: gentleLow, high: gentleHigh))
    }

    /// 热身置信度：换视频后 3 秒内从 0 线性升到 1（只会让输出偏低，安全方向）
    var confidence: Double { min(1, max(0, warmElapsed / Self.warmUpSeconds)) }
    /// 姿态在融合里的权重 0~0.8（界面提示「已识别人体」用）
    var poseWeight: Double { pose.weight }

    /// 暂停 / seek：平滑状态在 MotionShaper；参考值和热身保留（照 AudioReactiveShaper.reset 不清 refDb）。
    /// 姿态融合从头确认（algo-opt-3：seek 后可能已经不是同一个人）
    mutating func reset() {
        pose.reset()
        idleRun = 0
    }

    /// 换视频：重新学习运动范围、重新热身
    mutating func resetAdaptation() {
        refHigh = Self.initialHigh
        refLow = Self.initialLow
        warmElapsed = 0
        scoreHigh = Self.subjectInitialHigh
        scoreLow = Self.subjectInitialLow
        pose.reset()
        idleRun = 0
    }

    /// rhythm-lookahead P4（预扫描，默认关）：换视频后还一拍都没学过（warmElapsed == 0）时，用全片分位数当参考值的起点，
    /// 之后照常实时学（同样的快升慢降）。只改起点、不跳过热身（开头 3 秒照旧按 confidence 从 0 升）；
    /// 夹在实时学习本来能到的范围里（refHigh ≥ minHigh、主体参考 0~1）。已经学过 / 摘要不可信时不动，返回 false。
    /// 注意起点不保证比不初始化时低：scoreHigh 起点低时主体放大一开始就到 subjectMaxStretch（1.25 倍）、refHigh 起点可低到 minHigh，
    /// 热身过后开头一段可能比不初始化时同一时刻更强（不超过实时学习本来会学到的范围；上限 / 升幅由出口照旧管）
    @discardableResult
    mutating func seed(_ s: MotionPrescan.Summary) -> Bool {
        guard warmElapsed == 0, s.isValid else { return false }
        var used = false
        if s.energyWindows >= MotionPrescan.minWindows, s.refHigh.isFinite, s.refLow.isFinite {
            refHigh = max(Self.minHigh, s.refHigh)
            refLow = min(max(0, s.refLow), refHigh)
            used = true
        }
        if s.scoreWindows >= MotionPrescan.minWindows, s.scoreHigh.isFinite, s.scoreLow.isFinite {
            scoreHigh = MotionStats.clamp01(s.scoreHigh)
            scoreLow = min(MotionStats.clamp01(s.scoreLow), scoreHigh)
            used = true
        }
        return used
    }

    mutating func step(_ w: MotionWindow, gainDb: Double, auto: Bool, dt: TimeInterval) -> Double {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        guard w.frames > 0 else {
            // 分析停着（.critical 发热暂停 / 缓冲）时 PoseBlend 不走：停够保持时间就清掉，恢复后不沿用暂停前的姿态分数
            idleRun += step
            if idleRun > PoseBlend.holdSeconds { pose.reset() }
            return 0
        }
        idleRun = 0
        warmElapsed = min(Self.warmUpSeconds, warmElapsed + step)
        let e = w.representative
        // 开关关着也一直学：中途打开自动适应时参考值已经是这个视频的（同声音侧）
        let near = w.nearField.isFinite ? min(1, max(0, w.nearField)) : 0
        let gated = e.isFinite && e >= Self.absoluteGate
        let l = gated ? log(1 + e) : 0
        // 手贴镜头 / 大面积遮挡不训练「这个视频平时动多大」，否则之后真正的动作会被压低
        if gated, w.settled, near < Self.nearFieldLearnLimit, l.isFinite {
            let highTau = l > refHigh ? Self.highRiseSeconds : Self.highFallSeconds
            refHigh += (l - refHigh) * (1 - exp(-step / highTau))
            refHigh = max(Self.minHigh, refHigh)
            let lowTau = l < refLow ? Self.lowFallSeconds : Self.lowRiseSeconds
            refLow += (l - refLow) * (1 - exp(-step / lowTau))
            if !refHigh.isFinite || !refLow.isFinite { resetAdaptation() }
        }
        // algo-opt-3：分析器给了主体读数就按主体分数映射（画面变化的面积 / 整幅均值不再决定强度）
        if w.subjectFrames > 0 {
            return subjectStep(w, near: near, gainDb: gainDb, auto: auto, dt: step)
        }
        guard gated else { return 0 }
        // 固定尺度也封顶（0 dB 时自动模式最高约 81%）：手贴镜头这类极端画面变化不顶满，要更强靠灵敏度 / 上限
        let fixedRatio = min(Self.fixedRatioCap, (l - Self.fixedLow) / (Self.fixedHigh - Self.fixedLow))
        var ratio = fixedRatio
        if auto {
            let hi = refHigh
            let lo = min(refLow, hi - Self.minSpan)
            let span = max(Self.minSpan, hi - lo)
            // 自动部分最多到满刻度：超出这个视频平时范围的瞬间（手贴镜头）只能靠固定尺度往上走
            let adaptive = min(1, (l - lo) / span)
            ratio = Self.adaptiveWeight * adaptive + (1 - Self.adaptiveWeight) * fixedRatio
        }
        if near > 0 {
            // 近场画面变化很大但不是「内容在动」：往固定尺度的 60% 收，最多收到那里，不会比原来高
            let floorRatio = Self.nearFieldFixedShare * max(0, fixedRatio)
            ratio -= near * max(0, ratio - floorRatio)
        }
        let clampedGain = gainDb.isFinite
            ? min(VisualSyncSettings.motionGainRange.upperBound, max(VisualSyncSettings.motionGainRange.lowerBound, gainDb))
            : 0
        let g = pow(10, clampedGain / 20)
        let out = ratio * g * Self.targetPercent
        return out.isFinite ? min(100, max(0, out)) : 0
    }

    /// 主体分数 → 0~100（algo-opt-3）：块运动分数和姿态分数融合（PoseBlend）→ 近场收拢 → 自动适应（只减底 / 小幅放大）→ 灵敏度
    private mutating func subjectStep(_ w: MotionWindow, near: Double, gainDb: Double, auto: Bool,
                                      dt: TimeInterval) -> Double {
        let flow = MotionStats.clamp01(w.subjectScore)
        var s = pose.step(w, flow: flow, dt: dt, tuned: actionTuned)
        // 近场收拢之前的分数（rhythm-action tune 的 gentle / 放大门槛按它算，不和近场收拢叠加）
        let unpulled = MotionStats.clamp01(s)
        if near > 0 { s -= near * max(0, s - Self.subjectNearFloor) }
        s = MotionStats.clamp01(s)
        if w.settled, near < Self.nearFieldLearnLimit {
            let highTau = s > scoreHigh ? Self.highRiseSeconds : Self.highFallSeconds
            scoreHigh += (s - scoreHigh) * (1 - exp(-dt / highTau))
            let lowTau = s < scoreLow ? Self.lowFallSeconds : Self.lowRiseSeconds
            scoreLow += (s - scoreLow) * (1 - exp(-dt / lowTau))
            if !scoreHigh.isFinite || !scoreLow.isFinite {
                scoreHigh = Self.subjectInitialHigh
                scoreLow = Self.subjectInitialLow
            }
        }
        // rhythm-action tune：慢 / 轻的动作先按绝对刻度压低（关着时 shaped = s，逐位不变）。
        // 只在轻抚 / 还没认出动作且没锁节奏时（gentleAllowed）；按近场收拢之前的分数压、再照样收拢，
        // 不和近场收拢叠加（结果仍 ≤ s：gentle 不升、收拢单调）
        let gentleOn = actionTuned && (gentleAllowed || Self.unrhythmic(w))
        var shaped = s
        if gentleOn {
            var g = Self.gentle(unpulled)
            if near > 0 { g -= near * max(0, g - Self.subjectNearFloor) }
            shaped = MotionStats.clamp01(g)
        }
        var ratio = shaped
        if auto {
            let base = min(max(0, scoreLow), Self.subjectBaseLimit)
            ratio = max(0, (shaped - base) / (1 - base))
            var stretch = min(Self.subjectMaxStretch, max(1, Self.subjectTargetHigh / max(scoreHigh, 0.05)))
            if gentleOn {
                // 安静的视频里不把轻动作放大成中档：放大只给本身就不轻的动作（看近场收拢之前的分数）
                stretch = 1 + (stretch - 1)
                    * StrokeScore.ramp(unpulled, low: Self.stretchFromScore, high: Self.stretchFullScore)
            }
            ratio *= stretch
        }
        let clampedGain = gainDb.isFinite
            ? min(VisualSyncSettings.motionGainRange.upperBound, max(VisualSyncSettings.motionGainRange.lowerBound, gainDb))
            : 0
        let out = ratio * pow(10, clampedGain / 20) * 100
        return out.isFinite ? min(100, max(0, out)) : 0
    }
}

/// 内容时间戳（algo-opt-1）：VideoMotionTap 15 Hz 拉帧，但 24 / 25 / 30 fps 的片子两次拉到的帧之间隔的内容时间
/// 一会儿 1 帧一会儿 2 帧，按拉帧时刻算间隔能量会一大一小地抖。改用「这一帧真正该显示的时刻」：
/// t = host − (播放头时间 − 这帧的显示时间) / 播放速率（滞后在 0~0.5 秒内才用，否则退回 host）。
/// 输出单调递增、相邻至少 minGap（不会让 MotionAnalyzer 因间隔太短而重置），且不晚于 host
struct MotionDisplayClock {
    static let rateRange: ClosedRange<Double> = 0.1...8
    static let rateSmoothing: Double = 0.3
    static let maxLag: Double = 0.5
    static let minGap: Double = 0.031

    private(set) var rate: Double = 1
    /// 上一个真实帧实际用的滞后（host − 输出时间，0~maxLag）：静止补样按它换到同一条时间轴
    private(set) var lastLag: Double = 0
    private var lastHost: Double?
    private var lastItem: Double?
    private var lastOut: Double?

    mutating func reset() {
        rate = 1
        lastLag = 0
        lastHost = nil
        lastItem = nil
        lastOut = nil
    }

    /// 静止补样的时间：和真实帧同一条「显示时刻」时间轴（host − 上一帧的滞后）。
    /// 补样用 host、真实帧用显示时刻会让补样之后第一帧的间隔被压到 minGap，能量按间隔归一时最多 ×2
    func stillTime(host: Double) -> Double {
        guard host.isFinite else { return host }
        return host - lastLag
    }

    /// host：拉帧时刻；item：这个时刻的播放头；shown：拿到的帧的显示时间（itemTimeForDisplay）
    mutating func time(host: Double, item: Double, shown: Double) -> Double {
        guard host.isFinite else { return host }
        defer {
            lastHost = host
            if item.isFinite { lastItem = item }
        }
        if let h0 = lastHost, let i0 = lastItem, item.isFinite {
            let dh = host - h0
            let di = item - i0
            if dh > 0.001, di > 0 {
                let r = min(Self.rateRange.upperBound, max(Self.rateRange.lowerBound, di / dh))
                rate += (r - rate) * Self.rateSmoothing
                if !rate.isFinite { rate = 1 }
            }
        }
        var t = host
        if item.isFinite, shown.isFinite {
            let lag = (item - shown) / rate
            if lag >= 0, lag <= Self.maxLag { t = host - lag }
        }
        if let last = lastOut { t = max(t, min(host, last + Self.minGap)) }
        lastOut = max(lastOut ?? t, t)
        let used = host - t
        lastLag = used.isFinite ? min(Self.maxLag, max(0, used)) : 0
        return t
    }

    /// 发出了静止补样：time 用 stillTime(host:) 的值（同一条时间轴）。之后的帧时间要晚于它
    mutating func noteStill(at time: Double) {
        guard time.isFinite else { return }
        lastOut = max(lastOut ?? time, time)
    }
}

/// 画面的噪声门（回差，沿用声音侧 8 / 4）+ 攻击 / 释放平滑（0.15 s / 0.7 s）（§4.9）
struct MotionShaper {
    static let gateOpenPercent = AudioReactiveShaper.gateOpenPercent
    static let gateClosePercent = AudioReactiveShaper.gateClosePercent
    static let attackSeconds: TimeInterval = 0.15
    static let releaseSeconds: TimeInterval = 0.7

    struct Output: Equatable {
        /// 门前的目标值（0~100），界面「画面」条用
        var level: Double
        /// 门后、平滑后的 0~100
        var smoothed: Double
    }

    private(set) var smoothed: Double = 0
    private(set) var gateOpen = false

    mutating func reset() {
        smoothed = 0
        gateOpen = false
    }

    mutating func step(target: Double, dt: TimeInterval) -> Output {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        let level = target.isFinite ? min(100, max(0, target)) : 0
        if gateOpen {
            if level < Self.gateClosePercent { gateOpen = false }
        } else if level >= Self.gateOpenPercent {
            gateOpen = true
        }
        let goal = gateOpen ? level : 0
        let tau = goal > smoothed ? Self.attackSeconds : Self.releaseSeconds
        smoothed += (goal - smoothed) * (1 - exp(-step / tau))
        smoothed = smoothed.isFinite ? min(100, max(0, smoothed)) : 0
        return Output(level: level, smoothed: smoothed)
    }
}

/// 画面模式的最低强度只在「画面真的在流过分析器」时生效（照 AudioFlowWatch）：
/// 分析在跑 + 播放器确实在播 + 最近 1 秒内有画面样本；开播首拍、缓冲、发热暂停、无视频轨都不加
struct MotionFlowWatch {
    static let freshSeconds: TimeInterval = 1.0
    private(set) var lastFramesAt: TimeInterval?

    mutating func reset() { lastFramesAt = nil }

    mutating func note(_ w: MotionWindow, now: TimeInterval) {
        if w.frames > 0, now.isFinite { lastFramesAt = now }
    }

    func isFlowing(now: TimeInterval) -> Bool {
        guard let t = lastFramesAt, now.isFinite else { return false }
        let age = now - t
        return age >= 0 && age < Self.freshSeconds
    }

    func allowsFloor(analyzerRunning: Bool, playerPlaying: Bool, now: TimeInterval) -> Bool {
        analyzerRunning && playerPlaying && isFlowing(now: now)
    }
}

/// 发热降级（§6）：.serious 降到 8 Hz，.critical 停止画面分析（画面模式输出 0、不加最低强度）
enum MotionThermalPolicy {
    static let normalRate: Double = 15
    static let warmRate: Double = 8

    /// 每秒拉帧次数；0 = 暂停画面分析
    static func frameRate(for state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal, .fair: return normalRate
        case .serious: return warmRate
        case .critical: return 0
        @unknown default: return warmRate
        }
    }

    /// 界面提示；正常时 nil
    static func note(for state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .nominal, .fair: return nil
        case .serious: return "手机发热，画面分析已降频"
        case .critical: return "手机发热，画面分析已暂停"
        @unknown default: return "手机发热，画面分析已降频"
        }
    }
}

/// 跟随来源。P1 只有声音 / 画面二选一（界面就这两个）；2 留给 P2 的「声音+画面」，现在读到 2 或其他值都按声音处理
enum VisualSyncSource: Int, CaseIterable, Identifiable {
    case audio = 0
    case motion = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .audio: return "声音"
        case .motion: return "画面"
        }
    }
}

/// 画面联动设置（视频页 @AppStorage 持久化）。照 AudioSyncSettings：键名不带点、取值夹回范围、坏值回默认
struct VisualSyncSettings: Equatable {
    enum Keys {
        static let source = "bcVisualSyncSource"
        static let motionGainDb = "bcVisualSyncMotionGainDb"
        static let autoMotion = "bcVisualSyncAutoMotion"
        /// rhythm-follow P1：伸缩跟随动作频率（默认关）/ 设备档位→每秒往复次数标定表（文本，见 DeviceRateMap.parse）
        static let rhythmFollow = "bcVisualSyncRhythmFollow"
        static let rateTable = "bcVisualSyncRateTable"
        /// rhythm-phase P2：相位脉动（默认关）/ 脉动深度（档）/ 延迟补偿（毫秒）/ 方向反转
        static let rhythmPulse = "bcVisualSyncRhythmPulse"
        static let pulseDepth = "bcVisualSyncPulseDepth"
        static let pulseLatencyMs = "bcVisualSyncPulseLatencyMs"
        static let pulseInvert = "bcVisualSyncPulseInvert"
        /// rhythm-context P3：动作识别（手 / 头 / 髋 + 周期区域，默认关）/ 撞击声相位校正（默认关）
        static let rhythmContext = "bcVisualSyncRhythmContext"
        static let rhythmAudioAnchor = "bcVisualSyncRhythmAudioAnchor"
        /// rhythm-lookahead P4：前瞻（另开一路解码提前读后面的画面，默认关）
        static let rhythmLookahead = "bcVisualSyncRhythmLookahead"
        /// rhythm-lookahead P4：预扫描整段视频（全片分位初始化画面的自动适应参考值，默认关）
        static let prescan = "bcVisualSyncPrescan"
        /// av-fusion F1：声画融合（实验，默认关；F1 只显示耦合度，不改输出）
        static let avFusion = "bcVisualSyncAVFusion"
        /// av-fusion F2：节奏由声音确认（实验，默认关；融合 + 伸缩跟随动作频率都开着才显示 / 生效）
        static let avRhythmConfirm = "bcVisualSyncAVRhythmConfirm"
    }

    /// 默认跟随声音：老用户行为逐位不变
    static let defaultSource = VisualSyncSource.audio
    /// 画面灵敏度（dB）：-6（×0.5）~ +12（约 ×4）
    static let motionGainRange: ClosedRange<Double> = -6...12
    static let defaultMotionGainDb: Double = 0
    static let defaultAutoMotion = true
    /// 默认关。关着时画面路径的分数 / 强度 / 出口和 algo-opt-3 逐位相同：StrokeRhythm.estimate 的算法没变
    /// （减半只进 followEstimate），VideoSyncPlayer 走原来的 SyncOutputStage.step(value) 和 preview（VisualSyncChecks 钉住）
    static let defaultRhythmFollow = false
    /// 空 = 没标定，用 DeviceRateMap.uncalibrated
    static let defaultRateTable = ""
    /// 标定表文本最长（坏值 / 超长一律当没标定）
    static let maxRateTableLength = 400
    /// rhythm-phase P2：默认关。关着时 Timer 仍是 0.3 秒、出口仍走 step(levels:) / step(value)，和 rhythm-follow P1 逐位相同
    static let defaultRhythmPulse = false
    /// 脉动深度（峰谷差，档）：0~40，默认 20；实际深度还受升幅限速、频率、上限 / 最低强度约束（RhythmPulse.depth）
    static let pulseDepthRange: ClosedRange<Double> = 0...40
    static let defaultPulseDepth: Double = 20
    /// 延迟补偿（毫秒）：蓝牙写入 + 电机响应，0~600，默认 200
    static let pulseLatencyRange: ClosedRange<Double> = 0...600
    static let defaultPulseLatencyMs: Double = 200
    static let defaultPulseInvert = false
    /// rhythm-context P3：默认关。关着时不跑手 / 脸检测、不算周期区域 / 区域内运动 / 动作识别，
    /// 频率跟随和相位锁拿到的窗口和 P2 逐位相同（VisualSyncChecks 钉住）
    static let defaultRhythmContext = false
    /// rhythm-context P3：默认关。关着时音频实时线程不算频带能量、不做撞击检测，指令相位偏移恒 0
    static let defaultRhythmAudioAnchor = false
    /// rhythm-lookahead P4：默认关。关着时不建 LookaheadReader（不另外解码）、窗口和相位偏移都不改，和 P3 逐位相同
    static let defaultRhythmLookahead = false
    /// rhythm-lookahead P4：默认关。关着时不另外解码、MotionNormalizer 不被初始化，和 P3 逐位相同
    static let defaultPrescan = false
    /// av-fusion F1：默认关。关着时实时线程不算 6 段频带 / 包络 / PCM，频带块开关仍是 usesAudioAnchor，和 f706431 逐位相同
    /// （FusionOffCompare 钉住）；开着时 F1 也只显示「声画：」状态行和调试列，交给出口的值和关着时逐位相同
    static let defaultAVFusion = false
    /// av-fusion F2：默认关。关着时交给跟随器 / 相位锁的窗口、跟随器的跳变确认、撞击声校正的条件都和 F1 逐位相同
    /// （融合开着也一样 = f706431，FusionOffCompare 的 AV_F2_ON 变体钉住）
    static let defaultAVRhythmConfirm = false

    var source: VisualSyncSource
    var motionGainDb: Double
    var autoMotion: Bool
    var rhythmFollow: Bool
    var rateTable: String
    var rhythmPulse: Bool
    var pulseDepth: Double
    var pulseLatencyMs: Double
    var pulseInvert: Bool
    var rhythmContext: Bool
    var rhythmAudioAnchor: Bool
    var rhythmLookahead: Bool
    var prescan: Bool
    var avFusion: Bool
    var avRhythmConfirm: Bool

    init(source: VisualSyncSource = defaultSource, motionGainDb: Double = defaultMotionGainDb,
         autoMotion: Bool = defaultAutoMotion, rhythmFollow: Bool = defaultRhythmFollow,
         rateTable: String = defaultRateTable, rhythmPulse: Bool = defaultRhythmPulse,
         pulseDepth: Double = defaultPulseDepth, pulseLatencyMs: Double = defaultPulseLatencyMs,
         pulseInvert: Bool = defaultPulseInvert, rhythmContext: Bool = defaultRhythmContext,
         rhythmAudioAnchor: Bool = defaultRhythmAudioAnchor, rhythmLookahead: Bool = defaultRhythmLookahead,
         prescan: Bool = defaultPrescan, avFusion: Bool = defaultAVFusion,
         avRhythmConfirm: Bool = defaultAVRhythmConfirm) {
        self.source = source
        self.motionGainDb = motionGainDb.isFinite
            ? min(Self.motionGainRange.upperBound, max(Self.motionGainRange.lowerBound, motionGainDb))
            : Self.defaultMotionGainDb
        self.autoMotion = autoMotion
        self.rhythmFollow = rhythmFollow
        self.rateTable = rateTable.count <= Self.maxRateTableLength ? rateTable : Self.defaultRateTable
        self.rhythmPulse = rhythmPulse
        self.pulseDepth = pulseDepth.isFinite
            ? min(Self.pulseDepthRange.upperBound, max(Self.pulseDepthRange.lowerBound, pulseDepth))
            : Self.defaultPulseDepth
        self.pulseLatencyMs = pulseLatencyMs.isFinite
            ? min(Self.pulseLatencyRange.upperBound, max(Self.pulseLatencyRange.lowerBound, pulseLatencyMs))
            : Self.defaultPulseLatencyMs
        self.pulseInvert = pulseInvert
        self.rhythmContext = rhythmContext
        self.rhythmAudioAnchor = rhythmAudioAnchor
        self.rhythmLookahead = rhythmLookahead
        self.prescan = prescan
        self.avFusion = avFusion
        self.avRhythmConfirm = avRhythmConfirm
    }

    /// 存储里的来源值：认不出（含 P2 才有的 2）一律按声音
    static func resolveSource(rawValue: Int) -> VisualSyncSource {
        VisualSyncSource(rawValue: rawValue) ?? defaultSource
    }

    static func load(from defaults: UserDefaults) -> VisualSyncSettings {
        let raw = defaults.object(forKey: Keys.source) as? Int
        return VisualSyncSettings(
            source: raw.map { resolveSource(rawValue: $0) } ?? defaultSource,
            motionGainDb: defaults.object(forKey: Keys.motionGainDb) as? Double ?? defaultMotionGainDb,
            autoMotion: defaults.object(forKey: Keys.autoMotion) as? Bool ?? defaultAutoMotion,
            rhythmFollow: defaults.object(forKey: Keys.rhythmFollow) as? Bool ?? defaultRhythmFollow,
            rateTable: defaults.object(forKey: Keys.rateTable) as? String ?? defaultRateTable,
            rhythmPulse: defaults.object(forKey: Keys.rhythmPulse) as? Bool ?? defaultRhythmPulse,
            pulseDepth: defaults.object(forKey: Keys.pulseDepth) as? Double ?? defaultPulseDepth,
            pulseLatencyMs: defaults.object(forKey: Keys.pulseLatencyMs) as? Double ?? defaultPulseLatencyMs,
            pulseInvert: defaults.object(forKey: Keys.pulseInvert) as? Bool ?? defaultPulseInvert,
            rhythmContext: defaults.object(forKey: Keys.rhythmContext) as? Bool ?? defaultRhythmContext,
            rhythmAudioAnchor: defaults.object(forKey: Keys.rhythmAudioAnchor) as? Bool ?? defaultRhythmAudioAnchor,
            rhythmLookahead: defaults.object(forKey: Keys.rhythmLookahead) as? Bool ?? defaultRhythmLookahead,
            prescan: defaults.object(forKey: Keys.prescan) as? Bool ?? defaultPrescan,
            avFusion: defaults.object(forKey: Keys.avFusion) as? Bool ?? defaultAVFusion,
            avRhythmConfirm: defaults.object(forKey: Keys.avRhythmConfirm) as? Bool ?? defaultAVRhythmConfirm)
    }

    var gainMultiplier: Double { pow(10, motionGainDb / 20) }

    /// 用户填的标定表；空 / 填错时 nil（按 DeviceRateMap.uncalibrated 算，界面提示没标定）
    var calibratedRateMap: DeviceRateMap? { DeviceRateMap.parse(rateTable) }
    var rateMap: DeviceRateMap { calibratedRateMap ?? .uncalibrated }

    /// rhythm-phase P2：相位脉动要用 0.1 秒的子拍（跟随画面 + 伸缩跟随频率 + 相位脉动三个都开）。
    /// 子拍只决定 Timer 间隔；脉动真正起作用还要已标定、相位锁定（RhythmPulseDriver），否则输出和 P1 相同
    var usesPulseTiming: Bool { source == .motion && rhythmFollow && rhythmPulse }
    /// VideoSyncPlayer 的 Timer 间隔：不用子拍时就是 AudioReactiveShaper.interval（0.3 秒，和以前逐位相同）
    var tickInterval: TimeInterval { usesPulseTiming ? RhythmPulseDriver.subTickInterval : AudioReactiveShaper.interval }
    /// rhythm-context P3：动作识别真正生效（跟随画面 + 伸缩跟随频率 + 动作识别都开）。关着时 VideoMotionTap 不跑手 / 脸 / 周期区域
    var usesRhythmContext: Bool { source == .motion && rhythmFollow && rhythmContext }
    /// rhythm-context P3：撞击声相位校正真正生效（要相位脉动在跑；只改指令相位，不改档位）
    var usesAudioAnchor: Bool { usesPulseTiming && rhythmAudioAnchor }
    /// rhythm-lookahead P4：前瞻真正生效（跟随画面 + 伸缩跟随频率 + 前瞻 + 已标定）。频率只要 P1 开着就能用；
    /// 相位读数 / 提前量只在相位脉动也开着时才有地方用。没标定（档位 → 快慢只是估计值）时不用，退回 P4 关着的行为。
    /// 不影响 tickInterval
    var usesLookahead: Bool { source == .motion && rhythmFollow && rhythmLookahead && calibratedRateMap != nil }
    /// rhythm-lookahead P4：预扫描真正生效（跟随画面 + 自动适应画面 + 预扫描）。参考值只在自动适应时才用得上
    var usesPrescan: Bool { source == .motion && autoMotion && prescan }
    /// 要不要另开一路解码（前瞻或预扫描任一生效）
    var usesExtraDecode: Bool { usesLookahead || usesPrescan }
    /// av-fusion F1：声画融合真正生效（跟随画面 + 开关）。不是第三种来源；不影响 tickInterval
    var usesAVFusion: Bool { source == .motion && avFusion }
    /// av-fusion F2：节奏由声音确认真正生效（融合 + 伸缩跟随动作频率 + 开关）。声音只给画面节奏投票、不开锁；不影响 tickInterval
    var usesAVRhythmConfirm: Bool { usesAVFusion && rhythmFollow && avRhythmConfirm }
}

/// 播放中切换来源的交接（algo-opt-1）。纯计算，结果仍只经 VideoSyncPlayer.tick() → sendTick 发出：
/// - 声音 → 画面：画面归一化还在热身（confidence < 1）或画面还没有新鲜样本的那部分用声音的平滑值补上，并在 4 秒内线性淡出。
///   画面占比 k = 爬坡 r × 置信度 c，r 从画面有新鲜样本起 1.5 秒内由 0 升到 1（algo-opt-2）：
///   value = k·M + (1 − k)·淡出·A ≤ max(M, A)，不会比任一来源单独更强。同一个视频第二次切到画面时 c 早已是 1，
///   以前画面一有样本就整段换成 M（刚 reset 的平滑值，接近 0）→ 声音补的那部分一拍掉光；现在每次都按 r 平滑交接。
///   淡出结束且 r 满（或画面没在流）才结束交接，之后和原来逐位相同；
/// - 画面 → 声音：声音直出先经 SyncOutputStage（升幅 ≤ +20 / 拍、归零保持）从设备现在的输出追上，
///   追上或满 10 拍后回到原来的直出路径
struct SourceHandover {
    static let fadeSeconds: TimeInterval = 4
    static let maxCatchUpTicks = 10
    /// 画面有新鲜样本之后，画面占比从 0 爬满的时间
    static let motionRampSeconds: TimeInterval = 1.5

    private(set) var fadeElapsed: TimeInterval?
    private(set) var catchUpTicks: Int?
    /// 这次交接里画面有新鲜样本的累计时长（每次 begin 清零）
    private(set) var motionElapsed: TimeInterval = 0

    var isFading: Bool { fadeElapsed != nil }
    var isCatchingUp: Bool { catchUpTicks != nil }

    mutating func begin(_ to: VisualSyncSource) {
        motionElapsed = 0
        switch to {
        case .motion:
            fadeElapsed = 0
            catchUpTicks = nil
        case .audio:
            fadeElapsed = nil
            catchUpTicks = 0
        }
    }

    mutating func cancel() {
        fadeElapsed = nil
        catchUpTicks = nil
        motionElapsed = 0
    }

    /// 画面一拍的输入值。没有交接时 = motionSignal ? confidence × motion : 0
    mutating func blend(motion m: Double, confidence c: Double, motionSignal: Bool, audio a: Double,
                        audioSignal: Bool, dt: TimeInterval) -> (value: Double, hasSignal: Bool) {
        let mv = motionSignal ? c * m : 0
        guard let e = fadeElapsed else { return (mv, motionSignal) }
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        let fade = max(0, 1 - e / Self.fadeSeconds)
        // 画面还没有新鲜样本（刚装上取帧 / 发热暂停）就当占比 0、全用声音补；有了样本也从 0 起爬
        let ramp = min(1, max(0, motionElapsed / Self.motionRampSeconds))
        if motionSignal { motionElapsed += step }
        let conf = motionSignal && c.isFinite ? min(1, max(0, c)) : 0
        let weight = ramp * conf
        let motionPart = motionSignal && m.isFinite ? min(100, max(0, m)) : 0
        let audioPart = audioSignal && a.isFinite ? min(100, max(0, a)) : 0
        let v = weight * motionPart + (1 - weight) * fade * audioPart
        let next = e + step
        let rampDone = motionElapsed >= Self.motionRampSeconds
        // 淡出满了还要等爬坡满（画面没在流时这一项本来就是 0，直接结束）：结束那一拍和原路径连续
        fadeElapsed = next >= Self.fadeSeconds && (rampDone || !motionSignal) ? nil : min(next, Self.fadeSeconds)
        return (v.isFinite ? min(100, max(0, v)) : 0, motionSignal || (audioSignal && fade > 0))
    }

    /// 画面 → 声音的一拍：限速结果追上直出，或满 maxCatchUpTicks 拍，交接结束
    mutating func noteCatchUp(limited: [Int], direct: [Int]) {
        guard let t = catchUpTicks else { return }
        let next = t + 1
        catchUpTicks = (limited == direct || next >= Self.maxCatchUpTicks) ? nil : next
    }
}

/// 画面模式的出口（§4.12）：最低强度 / 上限映射（与 AudioReactiveShaper.step 尾部逐位一致）
/// → 按输出通道分配 → 每拍每通道升幅 ≤ +20 → 归零后至少保持 0 两拍 → 夹到 [0, min(上限, 99)]，通道 2 / 3 恒 0。
/// 只在画面模式用；声音模式完全走现有代码。结果仍然只经 VideoSyncPlayer.tick() → BLEManager.sendTick 发出
struct SyncOutputStage {
    static let maxRisePerTick = 20
    static let zeroHoldTicks = 2

    /// 上一拍实际算出的四通道（升幅基准）
    private(set) var last: [Int] = [0, 0, 0, 0]
    /// 每通道归零后已经保持了几拍；满 zeroHoldTicks 才允许再升
    private var zeroAge: [Int] = [Int](repeating: SyncOutputStage.zeroHoldTicks, count: 4)
    /// rhythm-phase P2 的按时间限速（step(levels:settings:elapsed:)）：
    /// 名义拍长 0.3 秒；升幅按 +20 / 0.3 秒折算到实际间隔（每次最多按 0.3 秒算），小数部分累加到下一次；
    /// 归零后要保持到「名义 3 拍」（0.9 秒，留 0.05 秒抖动余量）才允许再升——和按拍计数的规则在 0.3 秒一拍时逐位相同
    static let nominalTick: TimeInterval = AudioReactiveShaper.interval
    static let zeroHoldSeconds: TimeInterval = Double(zeroHoldTicks + 1) * nominalTick - 0.05
    private var riseCarry: [Double] = [0, 0, 0, 0]
    /// 每通道归零以来的时间（秒）；.infinity = 没在保持
    private var zeroElapsed: [Double] = [Double](repeating: .infinity, count: 4)
    /// rhythm-context P3（修 P2 评审 L2）：统一按时间限速的计时账本。
    /// lastAt = 上一次带 now 的出口时刻；pendingTimed = 上一次是按时间限速的，下一次即使调用方要「按拍」，
    /// 也按距上一次的实际时间折算，直到某一次实际间隔 ≥ 名义拍长（之后又和按拍逐位相同）。
    /// reset / seed 都不清（暂停、换来源时也不会在 0.1 秒后再给一整拍 +20）
    private(set) var lastAt: Double?
    private(set) var pendingTimed = false
    static let timedReleaseSlack: TimeInterval = 0.005

    /// 暂停 / seek / 开播 / 换视频：基准回 0，第一次升高不推迟（设备这时已经停了）
    mutating func reset() {
        last = [0, 0, 0, 0]
        zeroAge = [Int](repeating: Self.zeroHoldTicks, count: 4)
        riseCarry = [0, 0, 0, 0]
        zeroElapsed = [Double](repeating: .infinity, count: 4)
    }

    /// 播放中切换来源：升幅从设备现在的实际输出算起（不一下跳高）；现在是 0 的通道照样保持两拍
    mutating func seed(_ levels: [Int]) {
        for ch in 0..<4 {
            let v = ch < 2 && ch < levels.count ? max(0, min(BCProtocol.maxManualLevel, levels[ch])) : 0
            last[ch] = v
            zeroAge[ch] = v > 0 ? Self.zeroHoldTicks : 0
            riseCarry[ch] = 0
            zeroElapsed[ch] = v > 0 ? .infinity : 0
        }
    }

    /// 同 AudioReactiveShaper.step 的 floor：有信号才加最低强度
    static func floorPercent(settings s: AudioSyncSettings, hasSignal: Bool) -> Double {
        hasSignal ? min(s.maxPercent, s.minPercent) : 0
    }

    /// 最终夹紧上界：min(上限向下取整, 99)
    static func hardCap(_ s: AudioSyncSettings) -> Int {
        guard s.maxPercent.isFinite else { return 0 }
        return max(0, min(Int(s.maxPercent.rounded(.down)), BCProtocol.maxManualLevel))
    }

    /// 与 AudioReactiveShaper.step 尾部逐位一致（VisualSyncChecks 用 2000 组随机输入钉住）。
    /// value 先按 step 里 smoothed 的规则夹到 0~100；cap / floor 非有限时 0（step 里不会出现）
    static func map(_ value: Double, cap: Double, floor: Double) -> Int {
        guard cap.isFinite, floor.isFinite else { return 0 }
        let smoothed = value.isFinite ? min(100, max(0, value)) : 0
        let percent: Int
        if floor >= 1 {
            let scaled = floor + smoothed * (cap - floor) / 100
            percent = min(Int(cap.rounded(.down)), max(Int(floor.rounded()), Int(scaled.rounded())))
        } else {
            let scaled = smoothed * cap / 100
            percent = scaled < 1 ? 0 : min(Int(cap.rounded(.down)), Int(scaled.rounded()))
        }
        return max(0, min(100, percent))
    }

    /// 联动关着时界面强度条的预览值（不发、不动基准）
    static func preview(_ value: Double, settings s: AudioSyncSettings, hasSignal: Bool) -> Int {
        min(hardCap(s), map(value, cap: s.maxPercent, floor: floorPercent(settings: s, hasSignal: hasSignal)))
    }

    /// value：画面 0~100（已乘热身置信度；没有新鲜画面时调用方传 0、hasSignal = false）
    mutating func step(_ value: Double, settings s: AudioSyncSettings, hasSignal: Bool) -> [Int] {
        let mapped = Self.map(value, cap: s.maxPercent, floor: Self.floorPercent(settings: s, hasSignal: hasSignal))
        return limit(s.channels.levels(percent: mapped), cap: Self.hardCap(s))
    }

    /// rhythm-follow P1：调用方直接给每通道 0~99 的目标档位（RhythmOutput.target 算好最低强度 / 通道分配），
    /// 这里照样做同一套上限夹紧 + 升幅 ≤ +20 / 拍 + 归零保持（和 step(_:settings:hasSignal:) 共用 limit）
    mutating func step(levels target: [Int], settings s: AudioSyncSettings) -> [Int] {
        limit(target, cap: Self.hardCap(s))
    }

    /// rhythm-phase P2：同一个 limit，升幅 / 归零保持按距上一次出口的实际时间 elapsed 算（0.1 秒子拍用）。
    /// 任意连续 0.3 秒内伸缩累计升幅 ≤ 20（+20 / 0.3 秒折算、每次最多 20、小数部分累加），归零后 ≥ 0.85 秒才再升；
    /// 每次 elapsed = 0.3 时和 step(levels:settings:) 逐位相同（VisualSyncChecks 钉住）。上限夹紧、通道 2 / 3 为 0 不变
    mutating func step(levels target: [Int], settings s: AudioSyncSettings, elapsed: TimeInterval) -> [Int] {
        limit(target, cap: Self.hardCap(s), elapsed: elapsed)
    }

    /// rhythm-context P3（L2）：VideoSyncPlayer 所有出口都走这两个带 now 的入口（主机时钟 CACurrentMediaTime）。
    /// 从来没有按时间限速过（P2 脉动 / P3 都关着）时，和 step(_:settings:hasSignal:) / step(levels:settings:) 逐位相同
    /// （VisualSyncChecks 用 dfbfc8e 的基准副本钉住）；timed = true 或上一次是按时间的，就按距上一次出口的实际时间折算
    mutating func step(_ value: Double, settings s: AudioSyncSettings, hasSignal: Bool, now: Double) -> [Int] {
        let mapped = Self.map(value, cap: s.maxPercent, floor: Self.floorPercent(settings: s, hasSignal: hasSignal))
        return step(levels: s.channels.levels(percent: mapped), settings: s, now: now, timed: false)
    }

    mutating func step(levels target: [Int], settings s: AudioSyncSettings, now: Double, timed: Bool) -> [Int] {
        let elapsed = timedElapsed(now: now, timed: timed)
        return limit(target, cap: Self.hardCap(s), elapsed: elapsed)
    }

    /// nil = 按拍（原规则）；非 nil = 按这段实际时间折算
    private mutating func timedElapsed(now: Double, timed: Bool) -> TimeInterval? {
        let gap: TimeInterval? = {
            guard let last = lastAt, now.isFinite else { return nil }
            return max(0, now - last)
        }()
        if now.isFinite { lastAt = now }
        if timed {
            pendingTimed = true
            return gap ?? Self.nominalTick
        }
        guard pendingTimed else { return nil }
        // 上一次按时间：这一次也按实际间隔；间隔已经满一个名义拍（按拍和按时间结果相同）就交回按拍
        let dt = gap ?? Self.nominalTick
        if dt >= Self.nominalTick - Self.timedReleaseSlack { pendingTimed = false }
        return dt
    }

    /// elapsed == nil：原来按拍的规则（每拍 +20、归零后保持 2 拍），输出逐位不变（另外顺带记一份按时间的归零计时，
    /// 两种调用交替时保持一致）；非 nil：rhythm-phase P2 按时间折算
    private mutating func limit(_ target: [Int], cap: Int, elapsed: TimeInterval? = nil) -> [Int] {
        var out = [0, 0, 0, 0]
        // 按时间折算的这一次间隔：非有限 / 负数按 0（不给升幅），最多按一个名义拍算
        let span = elapsed.map { $0.isFinite ? min(Self.nominalTick, max(0, $0)) : 0 }
        for ch in 0..<2 {
            let prev = last[ch]
            var p = ch < target.count ? target[ch] : 0
            if let dt = span {
                let budget = riseCarry[ch] + Double(Self.maxRisePerTick) * (dt / Self.nominalTick)
                let allowed = min(Self.maxRisePerTick, max(0, Int(budget.rounded(.down))))
                riseCarry[ch] = min(0.999_999, max(0, budget - Double(allowed)))
                p = min(p, prev + allowed)
                if p > 0, prev == 0, zeroElapsed[ch] + dt < Self.zeroHoldSeconds { p = 0 }
            } else {
                // 升幅限速：视频 tick 在 BLE 层没有升幅限制（OutputWriteCoalescer 只限 AI 帧）
                p = min(p, prev + Self.maxRisePerTick)
                // 归零保持：运行中的全零会换成完整停止帧对，频繁 0 ↔ 非 0 会让链路忙于停止
                if p > 0, prev == 0, zeroAge[ch] < Self.zeroHoldTicks { p = 0 }
            }
            p = max(0, min(cap, p))
            if p == 0 {
                if let dt = span, prev == 0 {
                    // 按时间：保持了几个名义拍（0.3 秒一次时和下面按拍计数逐位相同）
                    zeroElapsed[ch] += dt
                    let ticks = zeroElapsed[ch].isFinite ? (zeroElapsed[ch] / Self.nominalTick + 1e-6).rounded(.down) : .infinity
                    zeroAge[ch] = ticks >= Double(Self.zeroHoldTicks) ? Self.zeroHoldTicks : max(0, Int(ticks))
                } else {
                    zeroAge[ch] = prev > 0 ? 0 : min(Self.zeroHoldTicks, zeroAge[ch] + 1)
                    zeroElapsed[ch] = prev > 0 ? 0 : zeroElapsed[ch] + Self.nominalTick
                }
            } else {
                zeroAge[ch] = Self.zeroHoldTicks
                zeroElapsed[ch] = .infinity
            }
            out[ch] = p
        }
        last = out
        return out
    }
}

// MARK: - rhythm-follow P1：伸缩跟随动作频率（只跟频率，不对相位）
//
// 0x08 帧只能发档位（Protocol.swift 不改，视频路径尾字节固定 0）。设备的「伸缩」档位按速度档理解：
// 档位越高、每秒往复越多。P1 把画面里估出来的往复频率（块运动主体 + 髋 / 头 / 腕姿态）换算成「让设备也每秒这么多下」的档位，
// 再走同一个 SyncOutputStage（上限、最低强度、升幅 ≤ +20 / 拍、归零保持）。相位（往里对往里）不在 P1 范围。
// 档位→频率的对应关系要真机标定（docs/rhythm-calibration.md），没标定时用 DeviceRateMap.uncalibrated 的保守猜测。

/// 设备伸缩档位 ↔ 每秒往复次数（Hz）的单调分段线性表（rhythm-follow P1）
struct DeviceRateMap: Equatable {
    struct Point: Equatable {
        var level: Int
        var hz: Double
    }

    static let minPoints = 2
    static let maxPoints = 12
    static let hzRange: ClosedRange<Double> = 0.1...8
    /// 没标定时的猜测：10 档约 0.5 Hz、99 档约 3 Hz（只用于还没做 P0 标定的设备，界面会提示）
    static let uncalibrated = DeviceRateMap(points: [Point(level: 10, hz: 0.5), Point(level: 99, hz: 3.0)])!

    let points: [Point]

    /// 至少 2 点、最多 12 点；档位 1~99、频率 0.1~8 Hz，按档位排序后档位和频率都必须严格递增
    init?(points raw: [Point]) {
        guard raw.count >= Self.minPoints, raw.count <= Self.maxPoints else { return nil }
        let sorted = raw.sorted { $0.level < $1.level }
        for (i, p) in sorted.enumerated() {
            guard p.level >= 1, p.level <= BCProtocol.maxManualLevel, p.hz.isFinite, Self.hzRange.contains(p.hz)
            else { return nil }
            if i > 0 {
                guard p.level > sorted[i - 1].level, p.hz > sorted[i - 1].hz else { return nil }
            }
        }
        points = sorted
    }

    /// 文本格式：「档位:每秒次数」，逗号 / 分号 / 顿号 / 空白（含换行、全角空格）分隔，全角冒号 / 逗号 / 分号也认，
    /// 冒号两边可以有空格。例：「20:0.6, 40:1.1, 60:1.7, 99:2.8」「20:0.6 40:1.1」「20：0.6、40：1.1」
    /// 空串、格式错、不单调都返回 nil（按没标定）
    static func parse(_ text: String) -> DeviceRateMap? {
        guard text.count <= VisualSyncSettings.maxRateTableLength else { return nil }
        let unified = text.replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "、", with: ",")
        // 冒号两边的空白去掉，剩下的空白都当分隔
        let normalized = unified.replacingOccurrences(of: "\\s*:\\s*", with: ":", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: ",", options: .regularExpression)
        var pts: [Point] = []
        for chunk in normalized.split(separator: ",") {
            let item = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.isEmpty { continue }
            let parts = item.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, let level = Int(parts[0]), let hz = Double(parts[1]) else { return nil }
            pts.append(Point(level: level, hz: hz))
        }
        return DeviceRateMap(points: pts)
    }

    var text: String {
        points.map { p in "\(p.level):\(String(format: "%g", p.hz))" }.joined(separator: ", ")
    }

    var minHz: Double { points[0].hz }
    var maxHz: Double { points[points.count - 1].hz }
    var minLevel: Int { points[0].level }
    var maxLevel: Int { points[points.count - 1].level }

    /// 让设备每秒往复 hz 次需要的档位（四舍五入）：慢于表里最慢的一点用最低一点的档位，快于最快一点用最高一点的档位
    func level(forHz hz: Double) -> Int {
        guard hz.isFinite else { return minLevel }
        if hz <= minHz { return minLevel }
        if hz >= maxHz { return maxLevel }
        for i in 1..<points.count where hz <= points[i].hz {
            let a = points[i - 1]
            let b = points[i]
            let f = (hz - a.hz) / (b.hz - a.hz)
            let v = Double(a.level) + f * Double(b.level - a.level)
            return min(b.level, max(a.level, Int(v.rounded())))
        }
        return maxLevel
    }

    /// 档位 → 每秒往复次数；低于表里最低档 nil（死区或没测过），高于最高档按最高一点
    func hz(forLevel level: Int) -> Double? {
        guard level >= minLevel else { return nil }
        if level >= maxLevel { return maxHz }
        for i in 1..<points.count where level <= points[i].level {
            let a = points[i - 1]
            let b = points[i]
            let f = Double(level - a.level) / Double(b.level - a.level)
            return a.hz + f * (b.hz - a.hz)
        }
        return maxHz
    }
}

/// 一个节奏候选（这一拍的块运动或姿态）
struct RhythmCandidate: Equatable {
    enum Source: Int {
        case none = 0
        case flow = 1
        case pose = 2
        case both = 3
    }

    var hz: Double
    var confidence: Double
    var source: Source
}

/// 每拍把块运动主体 / 姿态的往复频率合成一个「现在的动作频率」（rhythm-follow P1，r1 复审修正）：
/// - 候选：块运动主体（主体分数 ≥ 0.05、单程幅度 ≥ 1 像素，用 StrokeRhythm.followEstimate）、
///   姿态（髋 / 头 / 腕里最可信的一组；姿态分数 ≥ 0.1，挑中腕时 ≥ 0.2——腕不进姿态分数，光比划手势不算在动）；频率在 0.4~4 Hz；
/// - 两路频率相差 ≤ 15% 时按置信度加权合并、置信度 +0.1；不一致、且姿态的实际采样率看不清块运动那个频率
///   （块运动频率 > 姿态采样率 × 0.4，或不知道采样率；慢设备上 Vision 节流到约 3 Hz 时 2 Hz 会混叠成 1 Hz）时取块运动（r2：不再要求差 1.6 倍）；
///   其余不一致时取置信度高的（姿态 +0.05 优先）；只有姿态时，姿态采样率要 ≥ max(2.5 × 读数, 6 次/秒) 才给（r2，排除混叠）；
/// - 置信度 ≥ 0.40 才锁定，锁定后 < 0.30 才算丢（回差）；画面还在动时丢了保持 1.5 秒再解锁（检测一闪不掉）；
/// - 画面不动（调用方给 active = false）或切镜：马上解锁，weight 0.3 秒内归零，不保持旧节奏；
/// - 频率在 log 域平滑（τ = 1.5 秒，只跟 ±30% 以内的读数）；同方向偏离 15% 以上的读数记进待确认：≥ 2 拍、累计 ≥ 0.6 秒 − 半拍
///   （每拍最多按 0.3 秒算，一拍来晚了也不会单拍就确认；tick 0.29 秒照样 2 拍），读数彼此一致（最大 / 最小 ≤ 1.45），
///   且对数平均偏离当前频率 30% 以上，就直接跳到对数平均——单拍误检不跟，忽高忽低（2.0 / 2.4 交替）的读数也跟得上，
///   ±20% 的逐拍抖动只平滑不硬跳；锁定中一拍没候选不清待确认（隔拍掉线也能确认），连续缺 0.6 秒才清（r2 复审 L1 / L2）；
/// - weight：锁定时 1 秒升到 1、解锁后 1.5 秒降到 0（不动 / 切镜时 0.3 秒），调用方用它在「按动作强度」和「按动作频率」之间交接
struct RhythmFollower {
    static let hzRange: ClosedRange<Double> = 0.4...4
    static let flowMinAmplitude: Double = StrokeScore.flowAmplitudeLow
    /// 块运动主体分数几乎为 0（扣掉相机运动后没剩下主体动作，比如只有手持抖动）时块运动的频率不算
    static let flowMinScore: Double = 0.05
    /// 姿态分数（StrokeScore.pose，0~1）低于这个时姿态的频率不算（人在但没怎么动）；挑中腕时用 wristMinScore
    static let poseMinScore: Double = 0.1
    static let wristMinScore: Double = 0.2
    static let lockConfidence: Double = 0.40
    static let releaseConfidence: Double = 0.30
    static let agreeRatio: Double = 0.15
    static let agreeBonus: Double = 0.1
    static let poseBias: Double = 0.05
    /// 只有姿态、没有块运动候选时：姿态采样率要 ≥ max(2.5 × 读数, 6 次/秒) 才信（排除混叠；正常 Vision 15 / 8 Hz 都够，节流到约 3 Hz 时不给）
    static let poseOnlyRateShare: Double = 2.5
    static let poseOnlyMinRate: Double = 6
    static let smoothSeconds: TimeInterval = 1.5
    static let jumpRatio: Double = 0.3
    static let jumpConfirmSeconds: TimeInterval = 0.6
    static let jumpConfirmBeats = 2
    /// av-fusion F2：声音耦合着、而且同方向跳了时（AVRhythmVote.fastJumpHz）跳变确认缩成 1 拍（累计 ≥ 1 拍 − 半拍）
    static let fastJumpConfirmBeats = 1
    /// 待确认读数彼此要一致（最大 / 最小 ≤ 这个倍数）才跳；不一致时从最新这一拍重新数（r2 复审 L2）
    static let jumpAgreeSpread: Double = 1.45
    /// 锁定中一拍没有合格候选：待确认的跳变先留着（隔拍掉线也能凑够），连续缺这么久才清掉（r2 复审 L1）
    static let pendingGapSeconds: TimeInterval = 0.6
    /// 跳变确认里一拍最多算这么久（名义拍长），dt 偏大的一拍不能单独凑够确认时间
    static let beatSeconds: TimeInterval = AudioReactiveShaper.interval
    static let holdSeconds: TimeInterval = 1.5
    static let rampInSeconds: TimeInterval = 1.0
    static let rampOutSeconds: TimeInterval = 1.5
    static let fastReleaseSeconds: TimeInterval = 0.3
    /// 锁定中「画面不动」要连续这么多拍（有分析过的帧）才解锁（r3 复审 L1：一拍闪断 / 门一拍没开不丢锁；
    /// 输出那边 activity 照旧按即时强度，当拍就不加伸缩，所以动作停下的释放不变慢）
    static let inactiveUnlockTicks = 2

    private(set) var hz: Double = 0
    private(set) var confidence: Double = 0
    private(set) var locked = false
    private(set) var weight: Double = 0
    private(set) var source = RhythmCandidate.Source.none
    private var lostRun: TimeInterval = 0
    /// 待确认的跳变：方向（+1 变快 / −1 变慢）、拍数、读数的对数和、累计时间（每拍最多 beatSeconds）
    private var pendingDirection = 0
    private var pendingBeats = 0
    private var pendingLogSum: Double = 0
    private var pendingLogMin: Double = 0
    private var pendingLogMax: Double = 0
    private var pendingRun: TimeInterval = 0
    /// 因画面不动 / 切镜解锁：weight 按 fastReleaseSeconds 归零
    private var fastRelease = false
    /// 锁定中连续「画面不动」（有帧）的拍数
    private var inactiveTicks = 0

    mutating func reset() {
        self = RhythmFollower()
    }

    /// 这一拍的候选（不看锁定状态；置信度门在 step 里）
    static func candidate(_ w: MotionWindow) -> RhythmCandidate? {
        var flow: RhythmCandidate?
        if w.subjectFrames > 0, w.subjectScore.isFinite, w.subjectScore >= flowMinScore,
           w.subjectFollowHz.isFinite, hzRange.contains(w.subjectFollowHz), w.subjectFollowRhythm.isFinite,
           w.subjectFollowAmplitude.isFinite, w.subjectFollowAmplitude >= flowMinAmplitude {
            flow = RhythmCandidate(hz: w.subjectFollowHz, confidence: MotionStats.clamp01(w.subjectFollowRhythm),
                                   source: .flow)
        }
        var pose: RhythmCandidate?
        let poseFloor = w.poseRhythmPart == 3 ? wristMinScore : poseMinScore
        if w.posePresentFrames > 0, w.poseScore.isFinite, w.poseScore >= poseFloor,
           w.poseRhythmHz.isFinite, hzRange.contains(w.poseRhythmHz), w.poseRhythmConfidence.isFinite {
            pose = RhythmCandidate(hz: w.poseRhythmHz, confidence: MotionStats.clamp01(w.poseRhythmConfidence),
                                   source: .pose)
        }
        guard let f = flow else {
            // 只有姿态（r2 复审 L3）：混叠总落在奈奎斯特以下，只看 hz ≤ 0.4 × 采样率挡不住
            // （约 3 Hz 采样时真 2 Hz 会读成 1 Hz）。采样率不到 max(2.5 × hz, poseOnlyMinRate)（或不知道）就不给
            guard let p = pose else { return nil }
            let rate = w.poseRhythmRate
            guard rate.isFinite, rate >= max(poseOnlyRateShare * p.hz, poseOnlyMinRate) else { return nil }
            return p
        }
        guard let p = pose else { return f }
        let apart = abs(log(f.hz / p.hz))
        if apart <= log(1 + agreeRatio) {
            let wf = max(1e-6, f.confidence)
            let wp = max(1e-6, p.confidence)
            let hz = exp((wf * log(f.hz) + wp * log(p.hz)) / (wf + wp))
            return RhythmCandidate(hz: hz, confidence: min(1, max(f.confidence, p.confidence) + agreeBonus),
                                   source: .both)
        }
        // 差一个八度以上：姿态的采样率看不清块运动那个频率（或不知道采样率）时，姿态那个频率可能是混叠，信块运动（15 Hz 采样）
        let rate = w.poseRhythmRate
        let poseBlind = !(rate.isFinite && rate > 0) || f.hz > StrokeRhythm.aliasShare * rate
        // r2 复审 L3：采样率看不清时，任何超出 agreeRatio 的不一致都信块运动（不只差 1.6 倍以上；3.5 Hz 采样时 2 Hz 会读成 1.5 Hz）
        if poseBlind { return f }
        return p.confidence + poseBias >= f.confidence ? p : f
    }

    /// 每拍一次。没有画面信号时调用方应 reset（不保持）。
    /// active：画面自己的强度确实在动（RhythmOutput.activity > 0）；false 时不锁定，锁定中连续 2 拍（有帧）false 才解锁、weight 快速归零；
    /// frames == 0 的窗口不算 false（没有信息，按一拍没候选保持）。
    /// fastJumpHz（av-fusion F2，默认 0 = 原样）：声音确认过的跳变目标（AVRhythmVote.fastJumpHz）；这一拍真正用的候选读数
    /// 和它同方向、差 ≤ jumpRatio 时，跳变确认只要 1 拍（F2 复审 M2：姿态 / 区域读数没被声音核对过，不跟着缩短）
    @discardableResult
    mutating func step(_ w: MotionWindow, dt: TimeInterval, active: Bool = true, fastJumpHz: Double = 0) -> RhythmFollower {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        let gate = locked ? Self.releaseConfidence : Self.lockConfidence
        // r3 复审 L1：这一拍一帧都没分析到（上一帧还在算被丢、解码卡顿）= 没有信息，不当成「画面不动」，按一拍没候选保持
        let frameless = w.frames <= 0
        if w.cutCount > 0 {
            // 切镜：不保持旧节奏（新镜头重新确认），伸缩马上交回动作强度
            unlock()
        } else if !active && !frameless {
            // 画面不动：没锁定时不锁（也不保持交接）；锁定中要连续 inactiveUnlockTicks 拍才解锁，之前按一拍没候选保持
            inactiveTicks += 1
            if !locked || inactiveTicks >= Self.inactiveUnlockTicks {
                unlock()
            } else {
                holdMissing(step)
            }
        } else if frameless {
            if locked { holdMissing(step) } else { clearPending() }
        } else if let c = Self.candidate(w), c.confidence >= gate {
            inactiveTicks = 0
            lostRun = 0
            confidence = c.confidence
            source = c.source
            if !locked || !(hz > 0) {
                locked = true
                fastRelease = false
                hz = c.hz
                clearPending()
            } else {
                track(c.hz, step: step, fastHz: fastJumpHz)
            }
        } else if locked {
            inactiveTicks = 0
            holdMissing(step)
        } else {
            inactiveTicks = 0
            clearPending()
        }
        if !hz.isFinite { reset() }
        let target: Double = locked ? 1 : 0
        if target > weight {
            weight = min(1, weight + step / Self.rampInSeconds)
        } else if target < weight {
            weight = max(0, weight - step / (fastRelease ? Self.fastReleaseSeconds : Self.rampOutSeconds))
        }
        if weight == 0 && !locked {
            hz = 0
        }
        return self
    }

    /// 锁定后的一个读数（r2 复审 L1 / L2）：
    /// - ±30% 以内平滑跟（τ 1.5 s）；
    /// - 偏离 15% 以上的读数按方向记进「待确认」（回到 15% 以内或方向一反就重新数）；
    /// - 满 jumpConfirmBeats 拍、累计时间 ≥ jumpConfirmSeconds − 半拍（每拍最多按 beatSeconds 算），
    ///   待确认读数彼此一致（最大 / 最小 ≤ jumpAgreeSpread），且它们的对数平均偏离当前频率 30% 以上，才直接跳到对数平均；
    ///   平均只偏 15~30%（比如 ±20% 的逐拍抖动）不跳，照常平滑；读数彼此不一致时从最新这一拍重新数（不跳到谁也没读到的中间值）
    private mutating func track(_ reading: Double, step: TimeInterval, fastHz: Double) {
        let d = log(reading / hz)
        if abs(d) <= log(1 + Self.jumpRatio) {
            let a = 1 - exp(-step / Self.smoothSeconds)
            hz = exp(log(hz) + d * a)
        }
        guard abs(d) > log(1 + Self.agreeRatio) else {
            clearPending()
            return
        }
        let direction = d > 0 ? 1 : -1
        let lr = log(reading)
        if pendingBeats == 0 || direction != pendingDirection
            || max(pendingLogMax, lr) - min(pendingLogMin, lr) > log(Self.jumpAgreeSpread) {
            clearPending()
            pendingDirection = direction
            pendingLogMin = lr
            pendingLogMax = lr
        }
        pendingBeats += 1
        pendingLogSum += lr
        pendingLogMin = min(pendingLogMin, lr)
        pendingLogMax = max(pendingLogMax, lr)
        let beat = min(step, Self.beatSeconds)
        pendingRun += beat
        // av-fusion F2（复审 M2）：只有这一拍真正用的读数和声音确认过的目标同方向、差 ≤ jumpRatio 才缩成 1 拍
        let fast = fastHz.isFinite && fastHz > 0 && (fastHz > hz) == (reading > hz)
            && abs(log(reading / fastHz)) <= log(1 + Self.jumpRatio)
        let beatsNeeded = fast ? Self.fastJumpConfirmBeats : Self.jumpConfirmBeats
        let secondsNeeded = fast ? Self.beatSeconds : Self.jumpConfirmSeconds
        guard pendingBeats >= beatsNeeded,
              pendingRun >= secondsNeeded - 0.5 * beat - 1e-9 else { return }
        let mean = pendingLogSum / Double(pendingBeats)
        if abs(mean - log(hz)) > log(1 + Self.jumpRatio) {
            hz = exp(mean)
            clearPending()
        }
    }

    /// 画面不动 / 切镜：马上解锁，weight 按 fastReleaseSeconds 归零
    private mutating func unlock() {
        locked = false
        confidence = 0
        source = .none
        lostRun = 0
        inactiveTicks = 0
        fastRelease = true
        clearPending()
    }

    /// 锁定中一拍没有可用候选（r2 复审 L1）：不清待确认的跳变，只是这拍不算；连续缺满 pendingGapSeconds 才清，
    /// 满 holdSeconds 解锁（普通 1.5 秒降）
    private mutating func holdMissing(_ step: TimeInterval) {
        lostRun += step
        if lostRun > Self.pendingGapSeconds { clearPending() }
        if lostRun > Self.holdSeconds {
            locked = false
            confidence = 0
            source = .none
            inactiveTicks = 0
            clearPending()
        }
    }

    private mutating func clearPending() {
        pendingDirection = 0
        pendingBeats = 0
        pendingLogSum = 0
        pendingLogMin = 0
        pendingLogMax = 0
        pendingRun = 0
    }
}

/// 伸缩跟随频率时每通道的目标档位（rhythm-follow P1，r1 复审修正；纯函数，结果再经 SyncOutputStage.step(levels:)）：
/// - 先按原来的规则（最低强度 / 上限映射、通道分配）把画面强度 value 换成档位；
/// - 节奏只在画面确实在动时起作用：有效 weight = weight × activity（画面自己的强度 ≤ 2 → 0，≥ 25 → 1；
///   播放器用 motionActivity，下降跟门前即时强度走，动作一停当拍就不加伸缩）；
///   弱动作的节奏上界 rhythmCeiling 按「上限之前」的强度（value 按上限 100、不加最低强度换算的档位）算，再和上限取小
///   （r3 复审 M1：以前按乘过上限的档位算，上限 40 / 60 时频率完全不起作用）；强度 ≥ 30 的真动作没有这个上界，任何上限下都跟频率。
///   画面强度为 0（门关了 / 不动了）时伸缩就是原来的档位，节奏不加任何伸缩；
/// - 伸缩通道在用（「伸缩 + 震动」或「仅伸缩」）、有画面信号、有节奏档位时：
///   伸缩 = 按有效 weight 在「原来的档位」和「节奏档位」之间插值；节奏档位先抬到最低强度、再压到上限；
/// - 震动通道照旧跟画面强度；「仅震动」时节奏不起作用
enum RhythmOutput {
    /// 画面自己的强度（0~100，已乘热身置信度）≤ 这个算没在动
    static let activityFloor: Double = 2
    /// 到这个按节奏档位全权（r2 复审 L4：15 → 25，点头 / 比划手势这类弱动作只交接一部分）
    static let activityFull: Double = 25
    /// 弱动作的节奏上界（r2 复审 L4，r3 复审 M1 改成按上限之前的强度 m 算，和用户上限无关）：
    /// m ≤ rhythmHeadroomKnee 时 ≤ max(m + rhythmHeadroomMin, m × rhythmHeadroomScale)（点头 / 手势：强度 10 → 22、15 → 30）；
    /// m 在 knee ~ rhythmFreeIntensity 之间线性放开到 99；m ≥ rhythmFreeIntensity（30）的真动作没有上界，只受用户上限 / 设备上限
    static let rhythmHeadroomMin = 12
    static let rhythmHeadroomScale = 2
    static let rhythmHeadroomKnee = 20
    static let rhythmFreeIntensity = 30

    /// 画面自己的强度 → 节奏档位能用几成（0~1）
    static func activity(_ value: Double) -> Double {
        guard value.isFinite, value > activityFloor else { return 0 }
        return min(1, (value - activityFloor) / (activityFull - activityFloor))
    }

    /// 播放器每拍用的 activity（r2 复审 M1）：用门前的即时强度 level 和门后平滑值 smoothed 里较小的那个，再乘热身置信度。
    /// 上升不比平滑值快（不额外放大），下降跟即时强度走：动作一停 level 落到门下，节奏马上不再加伸缩，
    /// 不用等 0.7 秒的释放平滑把 smoothed 拖到 25 以下。motionSignal = false（没有新鲜画面）时 0
    static func motionActivity(level: Double, smoothed: Double, confidence: Double, motionSignal: Bool) -> Double {
        guard motionSignal, level.isFinite, smoothed.isFinite, confidence.isFinite else { return 0 }
        return activity(MotionStats.clamp01(confidence) * min(level, smoothed))
    }

    /// 节奏档位的上界（r2 复审 L4 / r3 复审 M1）。intensity：上限之前的强度档位 0~100（intensityLevel(value)），不是乘过上限的档位
    static func rhythmCeiling(intensity: Int) -> Int {
        let m = max(0, min(100, intensity))
        let full = BCProtocol.maxManualLevel
        if m >= rhythmFreeIntensity { return full }
        let weak = max(m + rhythmHeadroomMin, m * rhythmHeadroomScale)
        guard m > rhythmHeadroomKnee else { return weak }
        let kneeCeiling = max(rhythmHeadroomKnee + rhythmHeadroomMin, rhythmHeadroomKnee * rhythmHeadroomScale)
        let f = Double(m - rhythmHeadroomKnee) / Double(rhythmFreeIntensity - rhythmHeadroomKnee)
        return min(full, max(weak, Int((Double(kneeCeiling) + Double(full - kneeCeiling) * f).rounded())))
    }

    /// 上限之前的强度档位（按上限 100、不加最低强度换算 value；节奏上界只看动作本身有多强）
    static func intensityLevel(_ value: Double) -> Int {
        SyncOutputStage.map(value, cap: 100, floor: 0)
    }

    /// 节奏档位（抬到最低强度、压到上限）；ceiling：false = 不加弱动作上界（只给状态行比较用）
    private static func rhythmTarget(value: Double, rateLevel r: Int, settings s: AudioSyncSettings, floor: Double,
                                     ceiling: Bool) -> Int {
        let cap = SyncOutputStage.hardCap(s)
        let floorLevel = floor.isFinite ? max(0, Int(floor.rounded())) : 0
        let lifted = ceiling ? min(r, Self.rhythmCeiling(intensity: Self.intensityLevel(value))) : r
        return min(cap, max(floorLevel, lifted))
    }

    /// 弱动作上界这一拍有没有把节奏档位压低（状态行提示用；和 target 用同一套换算）
    static func ceilingLimits(value: Double, settings s: AudioSyncSettings, hasSignal: Bool, rateLevel: Int?) -> Bool {
        guard hasSignal, let r = rateLevel, s.channels != .vibration else { return false }
        let floor = SyncOutputStage.floorPercent(settings: s, hasSignal: hasSignal)
        return rhythmTarget(value: value, rateLevel: r, settings: s, floor: floor, ceiling: true)
            < rhythmTarget(value: value, rateLevel: r, settings: s, floor: floor, ceiling: false)
    }

    /// activity：nil = 按 value 算（调用方在声音→画面交接期间传画面自己那部分的 activity）
    static func target(value: Double, settings s: AudioSyncSettings, hasSignal: Bool,
                       rateLevel: Int?, weight: Double, activity: Double? = nil) -> [Int] {
        let floor = SyncOutputStage.floorPercent(settings: s, hasSignal: hasSignal)
        let mapped = SyncOutputStage.map(value, cap: s.maxPercent, floor: floor)
        var t = s.channels.levels(percent: mapped)
        let a = activity.map { MotionStats.clamp01($0) } ?? Self.activity(value)
        let w = MotionStats.clamp01(weight) * a
        guard hasSignal, let r = rateLevel, w > 0, s.channels != .vibration else { return t }
        let cap = SyncOutputStage.hardCap(s)
        let rl = Self.rhythmTarget(value: value, rateLevel: r, settings: s, floor: floor, ceiling: true)
        let blended = (Double(t[0]) + (Double(rl) - Double(t[0])) * w).rounded()
        t[0] = blended.isFinite ? min(cap, max(0, Int(blended))) : 0
        return t
    }

    /// 界面上的一行节奏状态（纯展示，VideoSyncPlayer 每拍刷新）。thrust：这一拍伸缩实际发出的档位（联动关着时是预览值）；
    /// 节奏还在不在起作用看 weight > 0（不是 locked：解锁后的交接期里伸缩还有一部分按节奏）。
    /// 「比设备最快 / 最慢」和「已到上限」各自独立提示。value / hasSignal：和 target 同一拍的输入，
    /// 弱动作上界压低了节奏档位时提示「动作偏弱」（r3 复审 M1）
    static func statusText(hz: Double, weight: Double, locked: Bool, rateLevel: Int?, activity: Double, thrust: Int,
                           value: Double, hasSignal: Bool,
                           map: DeviceRateMap, calibrated: Bool, settings s: AudioSyncSettings) -> String {
        let note = calibrated ? "" : "；设备还没标定，档位是估计值"
        guard weight > 0, hz.isFinite, hz > 0, let level = rateLevel else {
            return "还没找到稳定的动作节奏，伸缩先按动作强度" + note
        }
        if s.channels == .vibration {
            return String(format: "动作节奏 %.1f 次/秒（「仅震动」时不跟频率）", hz) + note
        }
        var text = String(format: "动作节奏 %.1f 次/秒", hz) + " → 伸缩 \(thrust) 档"
        if !(activity > 0) {
            text += "（画面没在动，伸缩不跟节奏）"
        } else if !locked {
            text += "（节奏丢了，正在交回动作强度）"
        }
        if activity > 0, ceilingLimits(value: value, settings: s, hasSignal: hasSignal, rateLevel: level) {
            text += "（动作偏弱，伸缩只按节奏加快一点）"
        }
        if hz > map.maxHz * 1.05 {
            text += String(format: "（比设备最快的 %.1f 次/秒还快）", map.maxHz)
        } else if hz < map.minHz * 0.95 {
            text += String(format: "（比设备最慢的 %.1f 次/秒还慢）", map.minHz)
        }
        let cap = SyncOutputStage.hardCap(s)
        let floorPercent = SyncOutputStage.floorPercent(settings: s, hasSignal: true)
        let floorLevel = floorPercent.isFinite ? max(0, Int(floorPercent.rounded())) : 0
        // 弱动作上界已经压到上限以下时不算「到上限」（r3 复审 M1，提示的是「动作偏弱」）
        let lifted = hasSignal && value.isFinite ? min(level, rhythmCeiling(intensity: intensityLevel(value))) : level
        if max(floorLevel, lifted) > cap {
            text += "（已到上限 \(cap)）"
        }
        return text + note
    }
}

// MARK: - rhythm-phase P2：相位对齐（画面往里时设备加强）
//
// 设备只收档位（0x08 帧尾字节固定 0，Protocol.swift 不改），没有位置 / 相位命令，FFA2 通知含义未知，
// 所以「设备活塞往里的那一刻」App 既控制不了也看不到。P2 能做的是开环近似：
// 1. 画面侧估相位：块运动主体 / 姿态那组的主轴速度，在跟随频率上做 2 个周期的正弦拟合（StrokeRhythm.phaseFit），
//    每个读数带画面帧的显示时刻；主线程 RhythmPhaseLock（锁相环）把读数合成一个连续的相位 θ(t)，可以外推到任意时刻；
// 2. 输出侧：在 P1 的伸缩档位（频率跟随）上叠一个「慢升快降」的脉动，峰值落在画面「往里那半拍」的后段，
//    按 θ(现在 + 延迟补偿) 取值——设备的往复本身照旧自由运行，体感是「每次往里时推一下」，不是真正的活塞同步；
// 3. 0.1 秒子拍（只在打开相位脉动时）：Timer 改 0.1 秒，每满 0.3 秒走一次原来完整的拍，中间两次只重算伸缩脉动；
//    出口仍是 tick() → SyncOutputStage.limit（按时间折算：任意 0.3 秒升幅 ≤ 20、归零保持 ≥ 0.85 秒、上限夹紧、通道 2 / 3 为 0）。
// 默认关；没标定、相位没锁定、动作太快 / 太弱、「仅震动」时脉动深度为 0，伸缩就是 P1 的档位（走 P1 原来的出口）。
// FFA2：只做被动观察（NotifyPeriodProbe，手动页设备详情里显示），不参与控制；确认它真的报位置之前不做闭环。

/// 画面往复的相位锁（rhythm-phase P2，主线程每个完整拍一次）：
/// - 读数：MotionWindow.subjectPhase（块运动）/ posePhase（姿态），按 RhythmFollower 当前用的来源挑
///   （both 时取拟合更好的，当前来源 +0.05 优先）。要求：拟合 R² ≥ 0.5（锁定后 ≥ 0.3）、主方向份额 ≥ 0.65（画圈不算）、
///   幅度够大（块运动 ≥ 1 像素、姿态 ≥ 0.03 躯干）、拟合频率和跟随频率差 ≤ 15%、读数不旧于 0.6 秒；
///   姿态还要采样率 ≥ max(4 × 频率, 6 次/秒)（慢设备 Vision 节流时相位会混叠，不用）；
/// - 锁定：连续 2 个读数彼此按跟随频率外推后差 ≤ 60° 才锁；锁定后按 PI 环跟：θ += 0.35·e，频率微调 ≤ ±10%；
///   单个偏差 > 90° 的读数不跟（可能是主轴翻转 / 换了来源 / 误检），连续 2 个一致才重新对齐；
/// - 跟随频率变了 15% 以上：重新锁；频率小变化时保持相位连续；
/// - 切镜、跟随器解锁 / 没频率：马上解锁、weight 归 0；画面不动（有帧）连续 2 拍才解锁（一拍空窗口 / 门一拍没开不解锁），
///   解锁那拍 weight 直接归 0；读数断了 1 秒解锁、weight 0.5 秒降到 0（期间按原频率外推）
struct RhythmPhaseLock {
    static let lockQuality: Double = 0.5
    static let releaseQuality: Double = 0.3
    static let minLinearity: Double = 0.65
    static let flowMinAmplitude: Double = StrokeScore.flowAmplitudeLow
    static let poseMinAmplitude: Double = StrokeScore.poseAmplitudeLow
    static let poseRateShare: Double = 4
    static let poseMinRate: Double = 6
    static let agreeRatio: Double = 0.15
    static let maxAge: Double = 0.6
    static let acquireReadings = 2
    static let acquireTolerance: Double = Double.pi / 3
    static let jumpLimit: Double = Double.pi / 2
    static let jumpConfirmReadings = 2
    static let gain: Double = 0.35
    static let trimGain: Double = 0.08
    static let maxTrimShare: Double = 0.1
    static let lostSeconds: TimeInterval = 1.0
    static let rampInSeconds: TimeInterval = 1.0
    static let rampOutSeconds: TimeInterval = 0.5
    static let inactiveUnlockTicks = 2
    static let sourceBias: Double = 0.05

    struct Reading: Equatable {
        var fit: StrokeRhythm.PhaseFit
        var source: RhythmCandidate.Source
    }

    private(set) var locked = false
    /// 脉动能用几成（0~1）：锁定 1 秒升满，丢了 0.5 秒降，切镜 / 不动直接 0
    private(set) var weight: Double = 0
    /// 跟随频率（Hz，来自 RhythmFollower）
    private(set) var hz: Double = 0
    /// 锁相环的频率微调（弧度 / 秒）
    private(set) var trim: Double = 0
    private(set) var refTime: Double = 0
    private(set) var refPhase: Double = 0
    /// 最近一个用上的读数的拟合 R²
    private(set) var quality: Double = 0
    private(set) var source = RhythmCandidate.Source.none
    private var lastReadingTime = -Double.infinity
    private var lastAcceptedTime = -Double.infinity
    private var lostRun: TimeInterval = 0
    private var inactiveTicks = 0
    private var candCount = 0
    private var candTime: Double = 0
    private var candPhase: Double = 0
    private var candSource = RhythmCandidate.Source.none

    var omega: Double { 2 * Double.pi * hz + trim }

    mutating func reset() {
        self = RhythmPhaseLock()
    }

    /// 时刻 t（host 时间，秒）的画面位移相位；weight 为 0 时 nil
    func phase(at t: Double) -> Double? {
        guard weight > 0, hz > 0, t.isFinite else { return nil }
        let v = refPhase + omega * (t - refTime)
        return v.isFinite ? StrokeRhythm.wrapPhase(v) : nil
    }

    /// 读数合不合格（不看锁定状态以外的历史）
    static func accepts(_ f: StrokeRhythm.PhaseFit, minAmplitude: Double, followerHz: Double, now: Double,
                        gate: Double, after: Double) -> Bool {
        guard f.isValid, f.time > after, f.time.isFinite, now.isFinite, now - f.time <= maxAge, f.time - now <= 0.1,
              f.quality.isFinite, f.quality >= gate, f.linearity.isFinite, f.linearity >= minLinearity,
              f.amplitude.isFinite, f.amplitude >= minAmplitude, followerHz.isFinite, followerHz > 0 else { return false }
        return abs(log(f.hz / followerHz)) <= log(1 + agreeRatio)
    }

    /// 这一拍用哪个读数（nil = 没有合格的）
    static func reading(_ w: MotionWindow, followerHz: Double, followerSource: RhythmCandidate.Source,
                        current: RhythmCandidate.Source, now: Double, gate: Double, after: Double) -> Reading? {
        var flow: Reading?
        if w.subjectFrames > 0,
           accepts(w.subjectPhase, minAmplitude: flowMinAmplitude, followerHz: followerHz, now: now, gate: gate, after: after) {
            flow = Reading(fit: w.subjectPhase, source: .flow)
        }
        var pose: Reading?
        let rate = w.poseRhythmRate
        if w.posePresentFrames > 0, rate.isFinite, rate >= max(poseRateShare * followerHz, poseMinRate),
           accepts(w.posePhase, minAmplitude: poseMinAmplitude, followerHz: followerHz, now: now, gate: gate, after: after) {
            pose = Reading(fit: w.posePhase, source: .pose)
        }
        switch followerSource {
        case .flow: return flow
        case .pose: return pose
        case .both:
            guard let f = flow else { return pose }
            guard let p = pose else { return f }
            let fq = f.fit.quality + (current == .flow ? sourceBias : 0)
            let pq = p.fit.quality + (current == .pose ? sourceBias : 0)
            return pq > fq ? p : f
        case .none: return nil
        }
    }

    /// 每个完整拍一次。followerHz / followerLocked / followerSource：RhythmFollower 这一拍的结果；
    /// now：host 时间（和画面帧时间戳同一时间轴，CACurrentMediaTime）；active：画面自己的强度在动（RhythmOutput.motionActivity > 0）
    mutating func step(_ w: MotionWindow, followerHz: Double, followerLocked: Bool, followerSource: RhythmCandidate.Source,
                       now: Double, dt: TimeInterval, active: Bool) {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        let frameless = w.frames <= 0
        if w.cutCount > 0 || !followerLocked || !(followerHz.isFinite && followerHz > 0) || !now.isFinite {
            unlock(drop: w.cutCount > 0 || !followerLocked)
        } else if !active && !frameless {
            inactiveTicks += 1
            if !locked || inactiveTicks >= Self.inactiveUnlockTicks {
                unlock(drop: true)
            } else {
                hold(step)
            }
        } else {
            if active { inactiveTicks = 0 }
            if locked {
                if abs(log(followerHz / hz)) > log(1 + Self.agreeRatio) {
                    // 跟随频率跳了：旧相位外推不再可信，重新锁
                    unlock(drop: false)
                } else {
                    // 频率小变化：在现在这一刻接上，相位连续
                    refPhase = StrokeRhythm.wrapPhase(refPhase + omega * (now - refTime))
                    refTime = now
                    hz = followerHz
                    trim = min(Self.maxTrimShare * 2 * Double.pi * hz, max(-Self.maxTrimShare * 2 * Double.pi * hz, trim))
                }
            }
            let gate = locked ? Self.releaseQuality : Self.lockQuality
            if !frameless, let r = Self.reading(w, followerHz: followerHz, followerSource: followerSource,
                                                current: source, now: now, gate: gate, after: lastReadingTime) {
                lastReadingTime = r.fit.time
                if locked {
                    track(r, step: step)
                } else {
                    acquire(r, followerHz: followerHz)
                }
            } else if locked {
                hold(step)
            } else if candCount > 0, now - candTime > 1.0 {
                candCount = 0
            }
        }
        if !(refPhase.isFinite && trim.isFinite && hz.isFinite) { reset() }
        let target: Double = locked ? 1 : 0
        if target > weight {
            weight = min(1, weight + step / Self.rampInSeconds)
        } else if target < weight {
            weight = max(0, weight - step / Self.rampOutSeconds)
        }
        if weight == 0 && !locked {
            hz = 0
            trim = 0
        }
    }

    private mutating func acquire(_ r: Reading, followerHz: Double) {
        if candCount > 0, candSource == r.source, r.fit.time - candTime <= 1.0 {
            let predicted = candPhase + 2 * Double.pi * followerHz * (r.fit.time - candTime)
            if abs(StrokeRhythm.wrapPhase(r.fit.phase - predicted)) <= Self.acquireTolerance {
                candCount += 1
            } else {
                candCount = 1
            }
        } else {
            candCount = 1
        }
        candTime = r.fit.time
        candPhase = r.fit.phase
        candSource = r.source
        guard candCount >= Self.acquireReadings else { return }
        locked = true
        hz = followerHz
        trim = 0
        refTime = r.fit.time
        refPhase = r.fit.phase
        quality = r.fit.quality
        source = r.source
        lostRun = 0
        lastAcceptedTime = r.fit.time
        candCount = 0
    }

    private mutating func track(_ r: Reading, step: TimeInterval) {
        let predicted = refPhase + omega * (r.fit.time - refTime)
        let e = StrokeRhythm.wrapPhase(r.fit.phase - predicted)
        if abs(e) > Self.jumpLimit {
            // 偏太多：先不跟；连续 jumpConfirmReadings 个彼此一致的才重新对齐（主轴翻转 / 换来源 / 真的错拍了）
            if candCount > 0, candSource == r.source, r.fit.time - candTime <= 1.0,
               abs(StrokeRhythm.wrapPhase(r.fit.phase - (candPhase + omega * (r.fit.time - candTime))))
                <= Self.acquireTolerance {
                candCount += 1
            } else {
                candCount = 1
            }
            candTime = r.fit.time
            candPhase = r.fit.phase
            candSource = r.source
            if candCount >= Self.jumpConfirmReadings {
                refTime = r.fit.time
                refPhase = r.fit.phase
                trim = 0
                quality = r.fit.quality
                source = r.source
                lostRun = 0
                lastAcceptedTime = r.fit.time
                candCount = 0
            } else {
                hold(step)
            }
            return
        }
        candCount = 0
        let span = lastAcceptedTime.isFinite ? min(1, max(0.1, r.fit.time - lastAcceptedTime)) : AudioReactiveShaper.interval
        refPhase = StrokeRhythm.wrapPhase(predicted + Self.gain * e)
        refTime = r.fit.time
        let maxTrim = Self.maxTrimShare * 2 * Double.pi * hz
        trim = min(maxTrim, max(-maxTrim, trim + Self.trimGain * e / span))
        quality = r.fit.quality
        source = r.source
        lostRun = 0
        lastAcceptedTime = r.fit.time
    }

    private mutating func hold(_ step: TimeInterval) {
        lostRun += step
        if lostRun > Self.lostSeconds { unlock(drop: false) }
    }

    /// drop：weight 直接归 0（切镜 / 画面不动 / 跟随器解锁）；否则按 rampOutSeconds 降
    private mutating func unlock(drop: Bool) {
        locked = false
        lostRun = 0
        inactiveTicks = 0
        candCount = 0
        quality = 0
        source = .none
        if drop {
            weight = 0
            hz = 0
            trim = 0
        }
    }
}

/// 伸缩脉动的波形与深度（rhythm-phase P2，纯函数）：
/// - 波形：每个周期 70% 的时间线性升到峰、30% 的时间降回谷（「慢升快降」：降不限速，升要守 +20 / 0.3 秒）；
///   峰值落在位移相位 −45°（往里那半拍的后段、离最深点 1/8 周期），再按延迟补偿提前发；
/// - 深度（峰谷差）：用户设置（默认 20）、升幅限速允许的 66.7 × 0.7 / 频率（1 Hz 46、2 Hz 23）取小，
///   × 锁相 weight × 频率跟随 weight × activity × 动作强度斜坡（上限前强度 20 → 30，弱动作 / 点头 / 手势不脉动）；
///   频率 2~2.5 Hz 线性减到 0（0.1 秒子拍一个周期少于 4 个点就不像一下一下了），> 2.5 Hz 不脉动；
/// - 档位：以 P1 档位为中心上下各 d/2，谷 ≥ max(最低强度, 8)（运行中发全零会变成停止帧对），峰 ≤ 上限；
///   顶到上限时整体往下挪（只往下脉动，频率差异不被上限压没），中心不往上抬；P1 档位低于谷值就不脉动
enum RhythmPulse {
    static let riseShare: Double = 0.7
    static let peakPhase: Double = -Double.pi / 4
    static let troughFloor = 8
    static let fadeHz: Double = 2.0
    static let maxHz: Double = 2.5
    /// 升幅限速折成每秒：+20 / 0.3 秒
    static let slopePerSecond: Double = Double(SyncOutputStage.maxRisePerTick) / SyncOutputStage.nominalTick
    /// 深度不到这个就不脉动（整档取整后看不出来）
    static let minDepth: Double = 2

    /// 一个周期内的形状 0~1；rel：离峰值的周期比例 [0, 1)（0 = 峰）
    static func wave(_ rel: Double) -> Double {
        guard rel.isFinite else { return 0 }
        var r = rel - rel.rounded(.down)
        if r < 0 { r += 1 }
        let fall = 1 - riseShare
        if r < fall { return 1 - r / fall }
        return (r - fall) / riseShare
    }

    /// 弱动作斜坡：上限之前的强度 ≤ 20 → 0，≥ 30 → 1（和 RhythmOutput 弱动作上界同一组拐点）
    static func strength(intensity: Int) -> Double {
        let lo = RhythmOutput.rhythmHeadroomKnee
        let hi = RhythmOutput.rhythmFreeIntensity
        guard hi > lo else { return intensity >= hi ? 1 : 0 }
        return MotionStats.clamp01(Double(intensity - lo) / Double(hi - lo))
    }

    /// 这一拍的有效深度（峰谷差，档）
    static func depth(setting: Double, hz: Double, weight: Double, activity: Double, intensity: Int) -> Double {
        guard setting.isFinite, setting > 0, hz.isFinite, hz > 0, hz < maxHz, weight.isFinite, activity.isFinite
        else { return 0 }
        let slope = slopePerSecond * riseShare / hz
        let fade = hz <= fadeHz ? 1 : max(0, (maxHz - hz) / (maxHz - fadeHz))
        let d = min(setting, slope) * fade * MotionStats.clamp01(weight) * MotionStats.clamp01(activity)
            * strength(intensity: intensity)
        return d.isFinite && d >= minDepth ? d : 0
    }

    /// 给伸缩的指令相位：现在 + 延迟补偿那一刻的画面相位，方向反转时 +180°
    static func commandPhase(_ lock: RhythmPhaseLock, at now: Double, latency: TimeInterval, invert: Bool) -> Double? {
        guard latency.isFinite, let p = lock.phase(at: now + max(0, latency)) else { return nil }
        return StrokeRhythm.wrapPhase(p + (invert ? Double.pi : 0))
    }

    /// 脉动后的伸缩档位。base：P1 的伸缩档位（RhythmOutput.target）；cap：hardCap；floor：最低强度档位（有信号时）
    static func thrust(base: Int, depth: Double, phase: Double, cap: Int, floor: Int) -> Int {
        guard base > 0, depth.isFinite, depth >= minDepth, phase.isFinite else { return base }
        let lo = max(floor, troughFloor)
        let hi = min(cap, BCProtocol.maxManualLevel)
        guard hi - lo >= 2, base >= lo else { return base }
        var d = min(depth, Double(hi - lo))
        var center = Double(min(base, hi))
        if center + d / 2 > Double(hi) { center = Double(hi) - d / 2 }
        if center - d / 2 < Double(lo) { d = min(d, 2 * (center - Double(lo))) }
        guard d >= minDepth else { return base }
        let rel = StrokeRhythm.wrapPhase(phase - peakPhase) / (2 * Double.pi)
        let v = center - d / 2 + d * wave(rel < 0 ? rel + 1 : rel)
        guard v.isFinite else { return base }
        return min(hi, max(lo, Int(v.rounded())))
    }
}

/// 播放器里相位脉动的调度（rhythm-phase P2，纯状态，VisualSyncChecks 按 0.1 秒子拍整段模拟）：
/// - Timer 0.1 秒一次；takesFullBeat：距上一个完整拍 ≥ 0.265 秒才走完整拍（原来 0.3 秒的全部逻辑），其余是子拍；
/// - 完整拍 beat：拿 P1 的目标档位（RhythmOutput.target），判断这一拍能不能脉动（engaged），能就叠脉动走按时间的出口；
///   不能、且上一拍也没在脉动时，原样走 SyncOutputStage.step(levels:)（和 P1 同一条路径、逐位相同）；
/// - 子拍 subBeat：只有上一个完整拍 engaged 才出值（同一个 P1 档位，只重算伸缩脉动），否则 nil（不发、不动出口状态）。
/// 震动通道、上限、最低强度、归零保持、STOP / 看门狗都不变；发送仍只在 VideoSyncPlayer.tick() 里
struct RhythmPulseDriver {
    static let subTickInterval: TimeInterval = 0.1
    static let fullBeatSlack: TimeInterval = 0.035

    enum State: Equatable {
        case off
        case uncalibrated
        case vibrationOnly
        case unlocked
        case tooFast
        case weak
        case active
    }

    private(set) var base: [Int]?
    private(set) var depth: Double = 0
    private(set) var engaged = false
    private(set) var state = State.off
    /// 顶到上限、只往下脉动
    private(set) var capped = false
    /// 出口上一次是按时间限速的（脉动中 / 刚停脉动）：下一个完整拍也按时间算，不在 0.1 秒后再给一整拍的 +20
    private(set) var timedLast = false
    private var lastOutputAt: Double?
    /// 上一个完整拍的时刻：Timer 计时用，reset 不清（开关脉动 / 重建 Timer 时完整拍间隔不会被缩短）
    private var lastFullBeatAt: Double?
    /// rhythm-context P3（修 P2 评审 L3）：上一个完整拍「该在」的时刻（按 0.3 秒网格往前推），reset 不清
    private var lastFullBeatDue: Double?
    /// 一个 0.1 秒 Timer 回调最早可以提前网格多少就算完整拍；两个完整拍实际间隔至少 minFullBeatGap
    static let fullBeatEarly: TimeInterval = 0.05
    static let minFullBeatGap: TimeInterval = 0.2
    /// 晚于网格这么多就不追（重新以这一刻为网格起点）
    static let fullBeatRegrid: TimeInterval = 0.1
    /// rhythm-context P3：撞击声相位校正（弧度，加到指令相位上；AudioPhaseAnchor 算，默认 0）
    var phaseOffset: Double = 0
    private var latency: TimeInterval = 0
    private var invert = false
    private var floorLevel = 0

    /// 脉动状态清掉（完整拍计时保留）
    mutating func reset() {
        let beatAt = lastFullBeatAt
        let due = lastFullBeatDue
        self = RhythmPulseDriver()
        lastFullBeatAt = beatAt
        lastFullBeatDue = due
    }

    /// 完整拍开头先停子拍：这一拍提前返回（暂停 / 缓冲 / seek 等待…）就不会再按旧档位脉动，直到 beat() 重新判断
    mutating func disarm() {
        engaged = false
    }

    /// 0.3 秒 Timer 的完整拍也记一下时刻（之后切到 0.1 秒时完整拍间隔照样 ≥ 0.3 秒）
    mutating func noteFullBeat(at now: Double) {
        if now.isFinite {
            lastFullBeatAt = now
            lastFullBeatDue = now
        }
    }

    /// 0.1 秒 Timer 每响一次问一次：true = 走完整拍。
    /// rhythm-context P3（L3）：按 0.3 秒网格算——到「上一个完整拍该在的时刻 + 0.3 秒 − 0.05 秒」就算，
    /// 且离上一个实际完整拍 ≥ 0.2 秒；算完后网格往前推 0.3 秒（晚了 > 0.1 秒才以现在为新起点）。
    /// 原来按「距上一个实际完整拍 ≥ 0.265 秒」，Timer 晚一点就会拖到下一个 0.1 秒（≈ 0.4 秒一拍）并一直错开
    mutating func takesFullBeat(at now: Double) -> Bool {
        let interval = AudioReactiveShaper.interval
        if let last = lastFullBeatAt, now.isFinite, now >= last {
            let due = (lastFullBeatDue ?? last) + interval
            if now - last < Self.minFullBeatGap || now < due - Self.fullBeatEarly { return false }
            lastFullBeatAt = now
            lastFullBeatDue = now - due > Self.fullBeatRegrid ? now : due
        } else {
            noteFullBeat(at: now)
        }
        disarm()
        return true
    }

    /// 这一拍能不能脉动、深度多少（不动出口）
    static func plan(levels: [Int], lock: RhythmPhaseLock, visual v: VisualSyncSettings, settings s: AudioSyncSettings,
                     value: Double, activity: Double, followerWeight: Double, now: Double) -> (State, Double) {
        guard v.rhythmPulse else { return (.off, 0) }
        guard v.calibratedRateMap != nil else { return (.uncalibrated, 0) }
        guard s.channels != .vibration else { return (.vibrationOnly, 0) }
        guard lock.locked || lock.weight > 0, lock.phase(at: now) != nil else { return (.unlocked, 0) }
        guard lock.hz < RhythmPulse.maxHz else { return (.tooFast, 0) }
        let d = RhythmPulse.depth(setting: v.pulseDepth, hz: lock.hz, weight: lock.weight * followerWeight,
                                  activity: activity, intensity: RhythmOutput.intensityLevel(value))
        guard d > 0, let b = levels.first, b > 0 else { return (.weak, 0) }
        return (.active, d)
    }

    /// 完整拍。levels：P1 的目标档位（4 通道）；返回这一拍的出口结果（还要经 VideoSyncPlayer 变化才发）
    mutating func beat(levels: [Int], lock: RhythmPhaseLock, visual v: VisualSyncSettings, settings s: AudioSyncSettings,
                       hasSignal: Bool, value: Double, activity: Double, followerWeight: Double, now: Double,
                       stage: inout SyncOutputStage) -> [Int] {
        let (st, d) = Self.plan(levels: levels, lock: lock, visual: v, settings: s, value: value, activity: activity,
                                followerWeight: followerWeight, now: now)
        state = st
        engaged = st == .active
        depth = engaged ? d : 0
        base = levels
        latency = v.pulseLatencyMs / 1000
        invert = v.pulseInvert
        let floorPercent = SyncOutputStage.floorPercent(settings: s, hasSignal: hasSignal)
        floorLevel = floorPercent.isFinite ? max(0, Int(floorPercent.rounded())) : 0
        let cap = SyncOutputStage.hardCap(s)
        capped = engaged && Double(levels[0]) + depth / 2 > Double(cap)
        // rhythm-context P3（L2）：按不按时间由出口自己记（上一次按时间的，这一次也按实际间隔，不管中间经过哪条路径）
        // 自审 L1：完整拍网格允许两拍最近 0.2 秒；离上一次出口不满一个名义拍时也按时间折算（不按拍给满 +20）
        let short = lastOutputAt.map { now.isFinite && now - $0 < SyncOutputStage.nominalTick - SyncOutputStage.timedReleaseSlack } ?? false
        let out = stage.step(levels: modulated(levels, lock: lock, now: now, cap: cap), settings: s, now: now,
                             timed: engaged || short)
        timedLast = engaged || stage.pendingTimed
        lastOutputAt = now
        return out
    }

    /// 子拍：上一个完整拍没在脉动时 nil
    mutating func subBeat(lock: RhythmPhaseLock, settings s: AudioSyncSettings, now: Double,
                          stage: inout SyncOutputStage) -> [Int]? {
        guard engaged, let b = base else { return nil }
        let out = stage.step(levels: modulated(b, lock: lock, now: now, cap: SyncOutputStage.hardCap(s)), settings: s,
                             now: now, timed: true)
        timedLast = true
        lastOutputAt = now
        return out
    }

    private func modulated(_ levels: [Int], lock: RhythmPhaseLock, now: Double, cap: Int) -> [Int] {
        var t = levels
        guard engaged, !t.isEmpty,
              var ph = RhythmPulse.commandPhase(lock, at: now, latency: latency, invert: invert) else { return t }
        if phaseOffset.isFinite, phaseOffset != 0 { ph = StrokeRhythm.wrapPhase(ph + phaseOffset) }
        t[0] = RhythmPulse.thrust(base: t[0], depth: depth, phase: ph, cap: cap, floor: floorLevel)
        return t
    }

    /// 界面上的一行（关着时 nil）
    func statusText(lock: RhythmPhaseLock, visual v: VisualSyncSettings) -> String? {
        switch state {
        case .off:
            return nil
        case .uncalibrated:
            return "相位脉动：设备还没标定（先按标定文档填好标定表），现在只跟频率"
        case .vibrationOnly:
            return "相位脉动：「仅震动」时不用"
        case .unlocked:
            return "相位脉动：还没对上画面的往复时机，现在只跟频率"
        case .tooFast:
            return String(format: "相位脉动：动作 %.1f 次/秒，超过 %.1f 次/秒不脉动，只跟频率", lock.hz, RhythmPulse.maxHz)
        case .weak:
            return "相位脉动：动作偏弱或没在动，不加脉动"
        case .active:
            var text = String(format: "相位脉动：已对上（拟合 %.2f），往里时加强，峰谷差 %d 档；延迟补偿 %d ms",
                              lock.quality, Int(depth.rounded()), Int(v.pulseLatencyMs.rounded()))
            if v.pulseInvert { text += "，方向已反转" }
            if capped { text += "（已到上限，只往下脉动）" }
            return text
        }
    }
}

/// FFA2 通知的被动观察（rhythm-phase P2；只记录、只分析，不参与控制）：最近 20 秒的通知
/// → 条数 / 速率、哪些字节会变、有没有按 0.3~5 次/秒周期变化的字节（正弦拟合 R² ≥ 0.5）、有没有像计数器一样递增的字节。
/// 真机上在手动页固定一个伸缩档位跑 10 秒看这一行：周期 ≈ 设备往复次数 / 计数器速率 ≈ 往复次数，说明 FFA2 可能带位置 / 行程信息，
/// 反馈回来再考虑相位闭环；都没有就说明 P2 只能开环
struct NotifyPeriodProbe {
    static let capacity = 400
    static let window: TimeInterval = 20
    static let maxBytes = 20
    static let minSamples = 12
    static let hzRange: ClosedRange<Double> = 0.3...5
    static let hzStep: Double = 0.05
    static let periodicQuality: Double = 0.5
    static let counterShare: Double = 0.8
    static let counterMinSteps = 6

    struct Report: Equatable {
        var samples = 0
        var rate: Double = 0
        var distinct = 0
        /// 会变的字节（从 0 数）
        var changingBytes: [Int] = []
        var periodicByte: Int?
        var periodicHz: Double = 0
        var periodicQuality: Double = 0
        var counterByte: Int?
        /// 计数器每秒递增多少
        var counterRate: Double = 0
    }

    private(set) var times: [Double] = []
    private(set) var payloads: [[UInt8]] = []

    mutating func reset() {
        times.removeAll()
        payloads.removeAll()
    }

    /// 「AA08…」这样的十六进制；不是十六进制（「—」「（空）」「订阅失败…」）返回 nil
    static func parseHex(_ text: String) -> [UInt8]? {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isWhitespace })
        guard !chars.isEmpty, chars.count % 2 == 0, chars.count <= 2 * 64 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let v = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(v)
            i += 2
        }
        return out
    }

    mutating func add(time: Double, hex: String) {
        guard time.isFinite, let bytes = Self.parseHex(hex) else { return }
        if let last = times.last, time < last { reset() }
        times.append(time)
        payloads.append(bytes)
        prune(now: time)
    }

    private mutating func prune(now: Double) {
        var drop = 0
        while drop < times.count, now - times[drop] > Self.window || times.count - drop > Self.capacity { drop += 1 }
        if drop > 0 {
            times.removeFirst(drop)
            payloads.removeFirst(drop)
        }
    }

    func report(now: Double) -> Report {
        var r = Report()
        let idx = times.indices.filter { now.isFinite && now - times[$0] <= Self.window && times[$0] <= now + 1 }
        r.samples = idx.count
        guard let firstIndex = idx.first, let lastIndex = idx.last else { return r }
        let span = times[lastIndex] - times[firstIndex]
        r.rate = span > 0 ? Double(idx.count - 1) / span : 0
        r.distinct = Set(idx.map { payloads[$0] }).count
        let width = min(Self.maxBytes, idx.map { payloads[$0].count }.max() ?? 0)
        var bestQ = 0.0
        for b in 0..<width {
            let rows = idx.filter { payloads[$0].count > b }
            guard rows.count >= 2 else { continue }
            let ys = rows.map { Double(payloads[$0][b]) }
            guard let lo = ys.min(), let hi = ys.max(), hi > lo else { continue }
            r.changingBytes.append(b)
            let ts = rows.map { times[$0] }
            // 计数器：变化里 ≥ 80% 是 +1~+8（按 256 回绕）
            var steps = 0
            var incs = 0
            var incSum = 0
            for k in 1..<rows.count {
                let d = (Int(payloads[rows[k]][b]) - Int(payloads[rows[k - 1]][b]) + 256) % 256
                if d != 0 { steps += 1 }
                if d >= 1, d <= 8 {
                    incs += 1
                    incSum += d
                }
            }
            let tspan = ts[ts.count - 1] - ts[0]
            if r.counterByte == nil, steps >= Self.counterMinSteps, Double(incs) >= Self.counterShare * Double(steps),
               tspan > 0 {
                r.counterByte = b
                r.counterRate = Double(incSum) / tspan
            }
            guard rows.count >= Self.minSamples, tspan > 0 else { continue }
            var f = Self.hzRange.lowerBound
            while f <= Self.hzRange.upperBound + 1e-9 {
                let q = Self.sineR2(times: ts, values: ys, hz: f)
                if q > bestQ {
                    bestQ = q
                    r.periodicByte = b
                    r.periodicHz = f
                }
                f += Self.hzStep
            }
        }
        r.periodicQuality = bestQ
        if bestQ < Self.periodicQuality {
            r.periodicByte = nil
            r.periodicHz = 0
        }
        return r
    }

    /// 任意采样上的正弦拟合 R²（a·cos + b·sin + c）
    static func sineR2(times ts: [Double], values ys: [Double], hz: Double) -> Double {
        guard ts.count == ys.count, ts.count >= 4, hz.isFinite, hz > 0, let t0 = ts.first else { return 0 }
        let omega = 2 * Double.pi * hz
        var scc = 0.0, sss = 0.0, scs = 0.0, sc = 0.0, ss = 0.0, sn = 0.0
        var syc = 0.0, sys = 0.0, sy = 0.0, syy = 0.0
        for k in 0..<ts.count {
            let c = cos(omega * (ts[k] - t0))
            let s = sin(omega * (ts[k] - t0))
            let y = ys[k]
            scc += c * c
            sss += s * s
            scs += c * s
            sc += c
            ss += s
            sn += 1
            syc += y * c
            sys += y * s
            sy += y
            syy += y * y
        }
        let det = scc * (sss * sn - ss * ss) - scs * (scs * sn - ss * sc) + sc * (scs * ss - sss * sc)
        guard det.isFinite, abs(det) > 1e-9 else { return 0 }
        let da = syc * (sss * sn - ss * ss) - scs * (sys * sn - ss * sy) + sc * (sys * ss - sss * sy)
        let db = scc * (sys * sn - ss * sy) - syc * (scs * sn - ss * sc) + sc * (scs * sy - sys * sc)
        let dc = scc * (sss * sy - sys * ss) - scs * (scs * sy - sys * sc) + syc * (scs * ss - sss * sc)
        let sst = syy - sy * sy / sn
        guard sst > 1e-12 else { return 0 }
        let sse = syy - (da * syc + db * sys + dc * sy) / det
        let r2 = 1 - sse / sst
        return r2.isFinite ? min(1, max(0, r2)) : 0
    }

    /// 手动页设备详情里的一行
    static func summary(_ r: Report) -> String {
        guard r.samples > 0 else { return "FFA2 观察：最近 20 秒没有收到通知" }
        var text = String(format: "FFA2 观察：最近 20 秒 %d 条（约 %.1f 条/秒），%d 种内容", r.samples, r.rate, r.distinct)
        if r.samples < minSamples { return text + "；条数太少，看不出规律" }
        if r.changingBytes.isEmpty { return text + "；内容一直不变（不随往复变化）" }
        text += "；会变的字节：" + r.changingBytes.prefix(6).map { "第 \($0 + 1) 个" }.joined(separator: "、")
        if let b = r.periodicByte {
            text += String(format: "；第 %d 个按约 %.2f 次/秒周期变化（拟合 %.2f），和设备往复次数对一下", b + 1, r.periodicHz,
                           r.periodicQuality)
        } else {
            text += "；没有 0.3~5 次/秒的周期变化"
        }
        if let c = r.counterByte {
            text += String(format: "；第 %d 个像计数器（约每秒 +%.1f）", c + 1, r.counterRate)
        }
        return text
    }
}

// MARK: - rhythm-context P3：动作识别（手 / 头 / 髋 + 周期区域 + 撞击声相位校正，默认关）
//
// P3 不改 P1 / P2 的算法，只在两个开关都打开时多一层「上下文」：
// - 周期区域（PeriodicityMap）：每块扣掉相机后的速度在跟随频率上做 DFT，功率最大且周期性够的块为种子，
//   向 8 邻域扩展功率 ≥ 25%、周期性 ≥ 0.3、相位同向或反向（|Re 相关| ≥ 0.5）的块 → 区域；
//   区域内再裁原图做一次高分辨率块运动（RoiFlowTracker，不拟合相机、整块扣掉整幅估计的相机平移）；
// - 手（VNDetectHumanHandPoseRequest）/ 脸（VNDetectFaceRectanglesRequest）/ 身体各组的位置与节奏（PartMotionTracker、
//   PoseMotionTracker.bodyContext）；
// - ActionContext：手在区域旁且频率一致 → 撸动、头在区域旁 → 口交、髋往复为主 → 插入（滞回 0.9 秒、1.5 秒没依据回「未知」、
//   切镜立刻「未知」），据此改写交给 RhythmFollower / RhythmPhaseLock 的那份窗口副本（选哪个部位的频率 / 相位、
//   区域内的运动代替整幅），并按「朝另一个人的髋」判断往里方向（判断不了就不改，等撞击声或用户的方向反转）；
// - 撞击声（AudioBandSplitter 在实时线程只算 10 ms 三频带能量；AudioOnsetDetector / AudioPhaseAnchor 在主线程）：
//   声音节奏和画面频率差 ≤ 15%、最近 4 秒 ≥ 4 次撞击且在画面相位上集中（R ≥ 0.6）时，把撞击对齐到「最深点」，
//   只改脉动的指令相位（RhythmPulseDriver.phaseOffset），不改档位。
// 输出仍只经 tick() → SyncOutputStage（上限 / 升幅 ≤ +20 / 0.3 秒 / 归零保持 / 通道 3、4 恒 0）。
// 两个开关关着、没标定、没有可信信号时，行为和 P2 相同（VisualSyncChecks 钉住）。

/// 一组身体部位的节奏：频率跟随估计 + 相位拟合（相位只在相位脉动开着时算）
struct PartRhythm: Equatable {
    var follow = StrokeRhythm.FollowEstimate()
    var phase = StrokeRhythm.PhaseFit()
}

/// 跟踪的那个人这一帧的位置和三组节奏，另一个人的髋 / 头（分析帧像素）
struct PoseBodyContext: Equatable {
    var present = false
    var time: Double = 0
    var scale: Double = 0
    var hasHip = false
    var hipX: Double = 0
    var hipY: Double = 0
    var hasHead = false
    var headX: Double = 0
    var headY: Double = 0
    var hasWrist = false
    var wristX: Double = 0
    var wristY: Double = 0
    var hips = PartRhythm()
    var head = PartRhythm()
    var wrists = PartRhythm()
    var hasOtherHip = false
    var otherHipX: Double = 0
    var otherHipY: Double = 0
    var otherScale: Double = 0
    var hasOtherHead = false
    var otherHeadX: Double = 0
    var otherHeadY: Double = 0
    /// rhythm-action tune（PoseMotionTracker.actionTuned 时才填）：胸口锚点（两肩中点，没有就用脖子）、
    /// 左右手腕各自的位置（判断「自己的手在自己身上」），另一个人髋的节奏（谁在往复不一定是认到的这个人）
    var hasChest = false
    var chestX: Double = 0
    var chestY: Double = 0
    var hasLeftWrist = false
    var leftWristX: Double = 0
    var leftWristY: Double = 0
    var hasRightWrist = false
    var rightWristX: Double = 0
    var rightWristY: Double = 0
    var otherHips = PartRhythm()
    /// 左右手腕各自的节奏（轻抚看摸着身体的那只、撸动看另一只）。只存 follow（没有相位）：
    /// 这份上下文随 MotionWindow 到处拷贝，不放用不上的 PhaseFit
    var leftWristRhythm = StrokeRhythm.FollowEstimate()
    var rightWristRhythm = StrokeRhythm.FollowEstimate()
    /// 左右手腕不扣全身中位速度的节奏（判断那只手安静 / 在往复时和上面的一起看）
    var leftWristRaw = StrokeRhythm.FollowEstimate()
    var rightWristRaw = StrokeRhythm.FollowEstimate()
}

/// 一只手 / 一张脸的检测（分析帧像素）。size：换算成「约一个躯干长」的尺度（手 = 3 × 腕到中指根，脸 = 2.5 × 脸框高）
struct PartCandidate: Equatable {
    var x: Double
    var y: Double
    var size: Double
    var confidence: Double
}

/// 跟踪的那只手 / 那张脸
struct PartReading: Equatable {
    var present = false
    var time: Double = 0
    var x: Double = 0
    var y: Double = 0
    var size: Double = 0
    var confidence: Double = 0
    var rhythm = PartRhythm()
}

/// 姿态队列一次的上下文（动作识别关着时不产生）
struct PoseContext: Equatable {
    var valid = false
    var time: Double = 0
    var frameWidth: Double = 0
    var frameHeight: Double = 0
    var body = PoseBodyContext()
    var hand = PartReading()
    var face = PartReading()
}

/// 手 / 脸的运动跟踪（同 PoseMotionTracker 的做法：连续性 1.5 尺度换目标、0.08 秒指数平滑 + 死区、扣相机运动、
/// 速度按尺度归一 → StrokeRhythm）。没开相位脉动时不算相位
struct PartMotionTracker {
    static let minConfidence: Double = 0.3
    static let continuityLimit: Double = 1.5
    static let minGap: Double = 0.02
    static let maxGap: Double = 0.4
    static let maxSpeed: Double = 8
    static let scaleSeconds: Double = 0.8
    static let rhythmGapLimit: Double = 1
    static let rhythmMaxAge: Double = 0.5

    var phaseFitEnabled = false
    private var rhythm = StrokeRhythm()
    private var hasPrevious = false
    private var prevX: Double = 0
    private var prevY: Double = 0
    private var prevTime: Double = 0
    private var smoothX: Double = 0
    private var smoothY: Double = 0
    private var scale: Double = 0
    private(set) var reading = PartReading()

    mutating func reset() {
        rhythm.reset()
        hasPrevious = false
        scale = 0
        reading = PartReading()
    }

    /// candidates：这一帧的手 / 脸；camera：上一次 update 那帧到这一帧的相机运动；continuous == false：中间断过
    mutating func update(time: Double, candidates: [PartCandidate], camera: CameraTransform,
                         continuous: Bool) -> PartReading {
        guard time.isFinite else { return reading }
        let cam = camera.isUsable ? camera : .identity
        var best: Int?
        var bestValue = -Double.infinity
        var near: Int?
        var nearDistance = Double.infinity
        let predicted: (x: Double, y: Double)? = hasPrevious && continuous ? cam.apply(x: prevX, y: prevY) : nil
        for (i, c) in candidates.enumerated() {
            guard c.x.isFinite, c.y.isFinite, c.size.isFinite, c.size > 0, c.confidence.isFinite,
                  c.confidence >= Self.minConfidence else { continue }
            let value = c.confidence * c.size
            if value > bestValue {
                bestValue = value
                best = i
            }
            if let q = predicted {
                let d = ((c.x - q.x) * (c.x - q.x) + (c.y - q.y) * (c.y - q.y)).squareRoot() / max(c.size, scale)
                if d < nearDistance {
                    nearDistance = d
                    near = i
                }
            }
        }
        let index: Int
        let switched: Bool
        if let n = near, nearDistance <= Self.continuityLimit {
            index = n
            switched = false
        } else if let b = best {
            index = b
            switched = predicted != nil
        } else {
            hasPrevious = false
            reading = PartReading(present: false, time: time)
            return reading
        }
        let c = candidates[index]
        let dt = time - prevTime
        let linked = !switched && hasPrevious && continuous && dt > Self.minGap && dt <= Self.maxGap && scale > 0
        if linked {
            scale += (c.size - scale) * (1 - exp(-dt / Self.scaleSeconds))
            let p = cam.apply(x: prevX, y: prevY)
            let rx = (c.x - p.x) / scale / dt
            let ry = (c.y - p.y) / scale / dt
            if rx.isFinite, ry.isFinite, (rx * rx + ry * ry).squareRoot() <= Self.maxSpeed {
                let s = cam.apply(x: smoothX, y: smoothY)
                let alpha = 1 - exp(-dt / PoseMotionTracker.jitterSeconds)
                let mx = alpha * (c.x - s.x)
                let my = alpha * (c.y - s.y)
                smoothX = s.x + mx
                smoothY = s.y + my
                let dx = mx / scale
                let dy = my / scale
                let zone = PoseMotionTracker.jitterDeadZone
                    * max(1, PoseMotionTracker.jitterConfidenceRef / max(c.confidence, Self.minConfidence))
                let m = (dx * dx + dy * dy).squareRoot()
                let keep = m > zone ? (m - zone) / m : 0
                rhythm.add(time: time, x: dx * keep / dt, y: dy * keep / dt)
            } else {
                smoothX = c.x
                smoothY = c.y
            }
        } else {
            scale = c.size
            smoothX = c.x
            smoothY = c.y
            if !continuous || switched || !(time - prevTime <= Self.rhythmGapLimit) { rhythm.reset() }
        }
        prevX = c.x
        prevY = c.y
        prevTime = time
        hasPrevious = true
        let f = rhythm.freshFollowEstimate(at: time, maxAge: Self.rhythmMaxAge)
        var phase = StrokeRhythm.PhaseFit()
        if phaseFitEnabled, f.hz > 0 {
            let rate = f.sampleRate.isFinite ? max(0, f.sampleRate) : 0
            phase = rhythm.phaseFit(hz: f.hz, lag: PoseMotionTracker.smoothingLag(hz: f.hz, rate: rate))
        }
        reading = PartReading(present: true, time: time, x: c.x, y: c.y, size: scale, confidence: c.confidence,
                              rhythm: PartRhythm(follow: f, phase: phase))
        return reading
    }
}

/// 周期区域（归一化 0~1，分析帧左上角原点）
struct PeriodicityROI: Equatable {
    var valid = false
    var time: Double = 0
    var hz: Double = 0
    var x0: Double = 0
    var y0: Double = 0
    var x1: Double = 0
    var y1: Double = 0
    var blocks = 0
    /// 区域内块的周期性（hz 上的功率 × 2 / 总方差，按功率加权，0~1）
    var coherence: Double = 0
    /// 区域占全画面在 hz 上功率的份额
    var share: Double = 0

    var centerX: Double { (x0 + x1) / 2 }
    var centerY: Double { (y0 + y1) / 2 }
}

/// 每块扣掉相机后的速度（像素 / 秒）最近约 4 秒的环形缓冲 + 在给定频率上找周期区域。稳态不分配
struct PeriodicityMap {
    static let capacity = 64
    static let blockCount = BlockMotionEstimator.blockCount
    static let minSamples = 12
    static let windowPeriods: Double = 2
    static let windowRange: ClosedRange<Double> = 1.5...4.0
    /// 种子块速度幅度至少这么多（像素 / 秒，分析帧）
    static let minAmplitude: Double = 4
    static let seedRatio: Double = 0.4
    static let memberRatio: Double = 0.3
    static let memberPower: Double = 0.25
    static let memberSimilarity: Double = 0.5
    /// 区域超过全画面 60% 的块：整幅就是区域，不用再放大
    static let maxBlockShare: Double = 0.6
    static let updateInterval: Double = 0.3
    static let maxGap: Double = 0.5

    private var times = [Double](repeating: 0, count: PeriodicityMap.capacity)
    private var vx = [Double](repeating: 0, count: PeriodicityMap.capacity * PeriodicityMap.blockCount)
    private var vy = [Double](repeating: 0, count: PeriodicityMap.capacity * PeriodicityMap.blockCount)
    private var cosT = [Double](repeating: 0, count: PeriodicityMap.capacity)
    private var sinT = [Double](repeating: 0, count: PeriodicityMap.capacity)
    private var xr = [Double](repeating: 0, count: PeriodicityMap.blockCount)
    private var xi = [Double](repeating: 0, count: PeriodicityMap.blockCount)
    private var yr = [Double](repeating: 0, count: PeriodicityMap.blockCount)
    private var yi = [Double](repeating: 0, count: PeriodicityMap.blockCount)
    private var power = [Double](repeating: 0, count: PeriodicityMap.blockCount)
    private var ratio = [Double](repeating: 0, count: PeriodicityMap.blockCount)
    private var member = [Bool](repeating: false, count: PeriodicityMap.blockCount)
    private var queue = [Int](repeating: 0, count: PeriodicityMap.blockCount)
    private var count = 0
    private var head = 0
    private var lastUpdate = -Double.infinity
    private(set) var roi = PeriodicityROI()

    /// rhythm-action tune（动作识别开着时打开；默认关 = 逐位不变）：区域要在全画面这个频率的功率里占 ≥ 35%
    /// （画面到处都有一点同频的抖动 / 闪烁时，最大的那一块只是噪声，不是主要动作），
    /// 且和上一次算出来的区域重叠（IoU ≥ 0.3）才算——种子在几块之间来回跳时不给区域，放大框不会被拽来拽去
    var stabilityGuard = false
    static let guardMinShare: Double = 0.35
    static let guardMinOverlap: Double = 0.3
    /// 上一次 compute 的原始结果（稳定性判断用）
    private var lastRaw = PeriodicityROI()

    var scratchAddresses: [Int] {
        func address<T>(_ a: [T]) -> Int { a.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        return [address(times), address(vx), address(vy), address(cosT), address(sinT), address(power), address(queue)]
    }

    mutating func reset() {
        count = 0
        head = 0
        lastUpdate = -.infinity
        roi = PeriodicityROI()
        lastRaw = PeriodicityROI()
    }

    /// 两个区域框的 IoU（归一化坐标）
    static func overlap(_ a: PeriodicityROI, _ b: PeriodicityROI) -> Double {
        guard a.valid, b.valid else { return 0 }
        return CropRect(x0: a.x0, y0: a.y0, x1: a.x1, y1: a.y1).iou(CropRect(x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1))
    }

    /// VisualSyncChecks 用：直接给每块扣掉相机后的位移（像素 / 帧间隔，按块序号），其余同 add(time:blocks:gap:)
    mutating func add(time: Double, residualX: [Double], residualY: [Double], gap: Double) {
        guard time.isFinite, gap.isFinite, gap > 0 else { return }
        let cap = Self.capacity
        let n = Self.blockCount
        if count > 0 {
            let last = times[(head + cap - 1) % cap]
            if time <= last || time - last > Self.maxGap {
                count = 0
                head = 0
            }
        }
        times[head] = time
        for b in 0..<n {
            let x = b < residualX.count && residualX[b].isFinite ? residualX[b] : 0
            let y = b < residualY.count && residualY[b].isFinite ? residualY[b] : 0
            vx[head * n + b] = x / gap
            vy[head * n + b] = y / gap
        }
        head = (head + 1) % cap
        count = min(cap, count + 1)
    }

    /// 一帧的每块残差（BlockMotionEstimator.blockResidual，像素 / 帧间隔 → 像素 / 秒）。时间倒退 / 断档 > 0.5 秒就重来
    mutating func add(time: Double, blocks: BlockMotionEstimator, gap: Double) {
        guard time.isFinite, gap.isFinite, gap > 0 else { return }
        let cap = Self.capacity
        let n = Self.blockCount
        if count > 0 {
            let last = times[(head + cap - 1) % cap]
            if time <= last || time - last > Self.maxGap {
                count = 0
                head = 0
            }
        }
        times[head] = time
        for b in 0..<n {
            let r = blocks.blockResidual(b)
            vx[head * n + b] = r.x / gap
            vy[head * n + b] = r.y / gap
        }
        head = (head + 1) % cap
        count = min(cap, count + 1)
    }

    /// 每 0.3 秒最多算一次；hz 无效 / 样本不够 / 没有够强的周期块时区域无效
    @discardableResult
    mutating func update(hz: Double, now: Double) -> PeriodicityROI {
        guard now.isFinite else { return roi }
        if now >= lastUpdate, now - lastUpdate < Self.updateInterval { return roi }
        lastUpdate = now
        if stabilityGuard {
            let raw = compute(hz: hz)
            let steady = raw.valid && raw.share >= Self.guardMinShare && Self.overlap(raw, lastRaw) >= Self.guardMinOverlap
            lastRaw = raw
            roi = steady ? raw : PeriodicityROI()
        } else {
            roi = compute(hz: hz)
        }
        if roi.valid { roi.time = now }
        return roi
    }

    private mutating func compute(hz: Double) -> PeriodicityROI {
        guard hz.isFinite, RhythmFollower.hzRange.contains(hz), count >= Self.minSamples else { return PeriodicityROI() }
        let cap = Self.capacity
        let n = Self.blockCount
        let tN = times[(head + cap - 1) % cap]
        let window = min(Self.windowRange.upperBound, max(Self.windowRange.lowerBound, Self.windowPeriods / hz))
        let start = (head + cap - count) % cap
        var first = count
        for k in 0..<count where tN - times[(start + k) % cap] <= window {
            first = k
            break
        }
        let m = count - first
        guard m >= Self.minSamples, tN - times[(start + first) % cap] >= 0.9 / hz else { return PeriodicityROI() }
        let omega = 2 * Double.pi * hz
        for k in first..<count {
            let i = (start + k) % cap
            cosT[i] = cos(omega * (times[i] - tN))
            sinT[i] = sin(omega * (times[i] - tN))
        }
        let inv = 1 / Double(m)
        var total = 0.0
        var seed = -1
        var seedPower = (Self.minAmplitude / 2) * (Self.minAmplitude / 2)
        for b in 0..<n {
            var mx = 0.0
            var my = 0.0
            for k in first..<count {
                let i = (start + k) % cap
                mx += vx[i * n + b]
                my += vy[i * n + b]
            }
            mx *= inv
            my *= inv
            var ar = 0.0, ai = 0.0, br = 0.0, bi = 0.0, v = 0.0
            for k in first..<count {
                let i = (start + k) % cap
                let dx = vx[i * n + b] - mx
                let dy = vy[i * n + b] - my
                ar += dx * cosT[i]
                ai -= dx * sinT[i]
                br += dy * cosT[i]
                bi -= dy * sinT[i]
                v += dx * dx + dy * dy
            }
            ar *= inv
            ai *= inv
            br *= inv
            bi *= inv
            v *= inv
            let p = ar * ar + ai * ai + br * br + bi * bi
            xr[b] = ar
            xi[b] = ai
            yr[b] = br
            yi[b] = bi
            power[b] = p.isFinite ? p : 0
            ratio[b] = v > 1e-9 && p.isFinite ? min(1, 2 * p / v) : 0
            total += power[b]
            if ratio[b] >= Self.seedRatio, power[b] >= seedPower {
                seed = b
                seedPower = power[b]
            }
        }
        guard seed >= 0, total > 0 else { return PeriodicityROI() }
        let cols = BlockMotionEstimator.columns
        let rows = BlockMotionEstimator.rows
        for b in 0..<n { member[b] = false }
        member[seed] = true
        queue[0] = seed
        var qh = 0
        var qt = 1
        let seedNorm = seedPower.squareRoot()
        while qh < qt {
            let b = queue[qh]
            qh += 1
            let r = b / cols
            let c = b % cols
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let rr = r + dr
                    let cc = c + dc
                    guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                    let nb = rr * cols + cc
                    guard !member[nb], power[nb] >= Self.memberPower * seedPower, ratio[nb] >= Self.memberRatio else {
                        continue
                    }
                    let dot = xr[seed] * xr[nb] + xi[seed] * xi[nb] + yr[seed] * yr[nb] + yi[seed] * yi[nb]
                    let sim = abs(dot) / (seedNorm * power[nb].squareRoot())
                    guard sim.isFinite, sim >= Self.memberSimilarity else { continue }
                    member[nb] = true
                    queue[qt] = nb
                    qt += 1
                }
            }
        }
        guard Double(qt) <= Self.maxBlockShare * Double(n) else { return PeriodicityROI() }
        var c0 = cols, c1 = -1, r0 = rows, r1 = -1
        var inPower = 0.0
        var weighted = 0.0
        for k in 0..<qt {
            let b = queue[k]
            c0 = min(c0, b % cols)
            c1 = max(c1, b % cols)
            r0 = min(r0, b / cols)
            r1 = max(r1, b / cols)
            inPower += power[b]
            weighted += power[b] * ratio[b]
        }
        var out = PeriodicityROI()
        out.valid = true
        out.hz = hz
        out.x0 = Double(c0) / Double(cols)
        out.x1 = Double(c1 + 1) / Double(cols)
        out.y0 = Double(r0) / Double(rows)
        out.y1 = Double(r1 + 1) / Double(rows)
        out.blocks = qt
        out.coherence = inPower > 0 ? MotionStats.clamp01(weighted / inPower) : 0
        out.share = MotionStats.clamp01(inPower / total)
        return out
    }
}

/// 归一化裁剪框（0~1，左上角原点）
struct CropRect: Equatable {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double

    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }

    func iou(_ o: CropRect) -> Double {
        let ix = max(0, min(x1, o.x1) - max(x0, o.x0))
        let iy = max(0, min(y1, o.y1) - max(y0, o.y0))
        let inter = ix * iy
        let union = width * height + o.width * o.height - inter
        return union > 0 ? inter / union : 0
    }
}

/// Y 平面里一个裁剪框 → 小图（同 LumaDownscaler：每个输出像素读框里均匀分布的 4×4 点求平均；采样表按框缓存）
struct LumaCropDownscaler {
    private var key: [Int] = []
    private var columnTaps: [Int] = []
    private var rowOffsets: [Int] = []

    /// 框（归一化）→ 源像素的起点和长度（至少 1 像素，不越界）
    static func span(_ a: Double, _ b: Double, size: Int) -> (start: Int, length: Int) {
        guard size > 0, a.isFinite, b.isFinite else { return (0, max(0, size)) }
        let lo = min(max(0, min(a, b)), 1)
        let hi = min(max(0, max(a, b)), 1)
        let s = min(size - 1, max(0, Int((lo * Double(size)).rounded(.down))))
        let e = min(size, max(s + 1, Int((hi * Double(size)).rounded(.up))))
        return (s, e - s)
    }

    mutating func downscale(_ src: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, crop: CropRect,
                            outWidth: Int, outHeight: Int, into frame: inout LumaFrame) -> Bool {
        guard width > 0, height > 0, outWidth > 0, outHeight > 0, bytesPerRow >= width, src.baseAddress != nil else {
            return false
        }
        let (lastRow, overflow) = (height - 1).multipliedReportingOverflow(by: bytesPerRow)
        guard !overflow, lastRow <= Int.max - width, lastRow + width <= src.count else { return false }
        let sx = Self.span(crop.x0, crop.x1, size: width)
        let sy = Self.span(crop.y0, crop.y1, size: height)
        let k = LumaDownscaler.tapsPerAxis
        let newKey = [width, height, bytesPerRow, sx.start, sx.length, sy.start, sy.length, outWidth, outHeight]
        if newKey != key {
            columnTaps = LumaDownscaler.tapPositions(output: outWidth, source: sx.length).map { $0 + sx.start }
            rowOffsets = LumaDownscaler.tapPositions(output: outHeight, source: sy.length).map { ($0 + sy.start) * bytesPerRow }
            key = newKey
        }
        if frame.width != outWidth || frame.height != outHeight || frame.pixels.count != outWidth * outHeight {
            frame = LumaFrame(width: outWidth, height: outHeight)
        }
        let area = k * k
        columnTaps.withUnsafeBufferPointer { cols in
            rowOffsets.withUnsafeBufferPointer { rows in
                frame.pixels.withUnsafeMutableBufferPointer { out in
                    for oy in 0..<outHeight {
                        for ox in 0..<outWidth {
                            var sum = 0
                            for j in 0..<k {
                                let row = rows[oy * k + j]
                                for i in 0..<k { sum += Int(src[row + cols[ox * k + i]]) }
                            }
                            out[oy * outWidth + ox] = UInt8((sum + area / 2) / area)
                        }
                    }
                }
            }
        }
        return true
    }
}

/// 周期区域里的高分辨率读数（subject：同 SubjectReading，速度 / 幅度已换回分析帧像素）
struct RoiReading: Equatable {
    /// subject 有效（区域内高分辨率块运动在跟）
    var valid = false
    var time: Double = 0
    /// 这一帧的周期区域（动作识别开着就带；不放大时也有，给 ActionContext 判断手 / 头在不在区域旁）
    var region = PeriodicityROI()
    var crop = CropRect(x0: 0, y0: 0, x1: 1, y1: 1)
    var zoom: Double = 1
    var subject = SubjectReading()
}

/// 周期区域内的高分辨率块运动：按区域裁原图 → 同尺寸小图 → BlockMotionEstimator（不拟合相机，扣掉整幅估计的相机平移）
/// → SubjectFlowTracker。框 1 秒最多挪一次（和现在的框重合 IoU < 0.5 才挪；挪得很远 IoU < 0.2 时节奏重攒）
struct RoiFlowTracker {
    static let minZoom: Double = 1.5
    static let maxZoom: Double = 4
    /// 区域外再留 30%
    static let margin: Double = 1.3
    static let moveIoU: Double = 0.5
    static let keepHistoryIoU: Double = 0.2
    static let minMoveInterval: Double = 1
    /// 周期区域这么久没有有效的就不跟了
    static let maxRoiAge: Double = 1
    static let minGap: Double = 0.03
    static let maxGap: Double = 0.5

    private var estimator = BlockMotionEstimator()
    private var tracker = SubjectFlowTracker()
    private var previous = LumaFrame()
    private var previousTime: Double = 0
    private var hasPrevious = false
    private(set) var crop: CropRect?
    private var lastMove = -Double.infinity
    private var lastValidRoi = -Double.infinity
    private(set) var reading = RoiReading()

    var phaseFitEnabled: Bool {
        get { tracker.phaseFitEnabled }
        set { tracker.phaseFitEnabled = newValue }
    }

    /// rhythm-action tune：区域内块运动也用噪声防护（同 MotionAnalyzer.actionTuned；默认关）
    var noiseGuard: Bool {
        get { estimator.noiseGuard }
        set { estimator.noiseGuard = newValue }
    }

    init() {
        estimator.cameraFit = false
    }

    mutating func reset() {
        tracker.reset()
        hasPrevious = false
        crop = nil
        lastMove = -.infinity
        lastValidRoi = -.infinity
        reading = RoiReading()
    }

    /// 切镜 / 保持期：新镜头重新攒，框也重新定
    mutating func noteCut() {
        tracker.noteCut()
        hasPrevious = false
        crop = nil
        lastMove = -.infinity
        reading = RoiReading()
    }

    /// 区域 → 想要的裁剪框（和画面同宽高比，放大 1.5~4 倍）；区域太大不值得放大时 nil
    static func desiredCrop(_ roi: PeriodicityROI) -> (CropRect, Double)? {
        guard roi.valid else { return nil }
        let extent = max(roi.x1 - roi.x0, roi.y1 - roi.y0) * Self.margin
        guard extent.isFinite, extent > 0 else { return nil }
        let zoom = min(Self.maxZoom, 1 / extent)
        guard zoom >= Self.minZoom else { return nil }
        let half = 0.5 / zoom
        let cx = min(1 - half, max(half, roi.centerX))
        let cy = min(1 - half, max(half, roi.centerY))
        return (CropRect(x0: cx - half, y0: cy - half, x1: cx + half, y1: cy + half), zoom)
    }

    /// 这一帧要裁的框（nil = 不跟）
    mutating func plan(_ roi: PeriodicityROI, now: Double) -> CropRect? {
        guard now.isFinite else { return crop }
        let desired = Self.desiredCrop(roi)
        if roi.valid { lastValidRoi = now }
        guard let current = crop else {
            if let d = desired {
                crop = d.0
                lastMove = now
                hasPrevious = false
            }
            return crop
        }
        if desired == nil {
            if now - lastValidRoi > Self.maxRoiAge || (roi.valid && now - lastMove >= Self.minMoveInterval) {
                // 区域没了 / 变得太大：不跟
                tracker.noteCut()
                crop = nil
                hasPrevious = false
                reading = RoiReading()
            }
            return crop
        }
        if let d = desired, current.iou(d.0) < Self.moveIoU, now - lastMove >= Self.minMoveInterval {
            if current.iou(d.0) < Self.keepHistoryIoU { tracker.noteCut() }
            crop = d.0
            lastMove = now
            hasPrevious = false
        }
        return crop
    }

    /// frame：按 crop 裁出来的小图（和分析帧同尺寸）；camera / cameraContinuous：整幅那次估计的相机运动；
    /// analysisWidth / Height：分析帧尺寸
    mutating func update(time: Double, frame: LumaFrame, camera: CameraTransform, cameraContinuous: Bool,
                         analysisWidth: Int, analysisHeight: Int) -> RoiReading {
        guard let c = crop, time.isFinite, frame.width > 0, frame.height > 0,
              frame.pixels.count == frame.width * frame.height, analysisWidth > 0, analysisHeight > 0 else {
            hasPrevious = false
            return RoiReading()
        }
        let gap = time - previousTime
        var out = RoiReading()
        if hasPrevious, cameraContinuous, gap >= Self.minGap, gap <= Self.maxGap,
           previous.width == frame.width, previous.height == frame.height {
            let w = Double(analysisWidth)
            let h = Double(analysisHeight)
            let cx = (c.x0 + c.x1) / 2 * w
            let cy = (c.y0 + c.y1) / 2 * h
            let cam = camera.isUsable ? camera : .identity
            let moved = cam.apply(x: cx, y: cy)
            // 裁剪小图里一个像素 = 分析帧里 1 / scale 个像素
            let scale = Double(frame.width) / max(1e-9, c.width * w)
            estimator.presetShift = ((moved.x - cx) * scale, (moved.y - cy) * scale)
            let flow = frame.pixels.withUnsafeBufferPointer { cur in
                previous.pixels.withUnsafeBufferPointer { prev in
                    estimator.estimate(cur: cur, prev: prev, width: frame.width, height: frame.height, gap: gap)
                }
            }
            let subject = tracker.update(time: time, speed: flow.speed / scale, vx: flow.vx / scale, vy: flow.vy / scale)
            out = RoiReading(valid: subject.valid, time: time, crop: c, zoom: 1 / max(1e-9, c.width),
                             subject: subject)
        }
        if previous.width == frame.width, previous.height == frame.height, previous.pixels.count == frame.pixels.count {
            previous.pixels.withUnsafeMutableBufferPointer { dst in
                frame.pixels.withUnsafeBufferPointer { src in
                    for i in 0..<src.count { dst[i] = src[i] }
                }
            }
        } else {
            previous = LumaFrame(width: frame.width, height: frame.height, pixels: frame.pixels)
        }
        previousTime = time
        hasPrevious = true
        reading = out
        return out
    }
}

/// 动作识别（主线程，每个完整拍一次）：看窗口里的周期区域 / 手 / 脸 / 身体，判断现在是哪种动作，
/// 改写交给 RhythmFollower / RhythmPhaseLock 的那份窗口副本。只改 subjectFollow* / subjectPhase / poseRhythm* / posePhase
/// （以及没检测到身体时让手 / 脸的节奏能被采用的 posePresentFrames / poseScore 下限），强度那条路（MotionNormalizer）不看这份副本。
/// 「未知」时只用区域内的运动（区域可信时），部位 / 方向都不改 = P2 行为。
/// rhythm-action tune：撸动 / 口交要有对象（手离某个髋 ≤ 1 个身体尺度、脸离不是它自己身体的髋 ≤ 1.2 个尺度），
/// 只有一只手 / 一张脸在动不算；自己的手在自己胸口 / 肚子上、髋没在往复 → 轻抚（不跟节奏，强度最多 20）；
/// 插入时另一个人的髋也算（谁在往复就跟谁）；改判确认中漏一两拍不重新计时
struct ActionContext {
    enum Kind: Int, Equatable {
        case unknown = 0
        case insertion
        case oral
        case stroke
        /// rhythm-action tune：轻抚 / 摸自己（自己的手在自己的胸口 / 肚子上，髋没在往复）：不跟节奏、强度压低
        case caress
    }

    struct Evidence: Equatable {
        var insertion: Double = 0
        var oral: Double = 0
        var stroke: Double = 0
        var caress: Double = 0

        func value(_ k: Kind) -> Double {
            switch k {
            case .unknown: return 0
            case .insertion: return insertion
            case .oral: return oral
            case .stroke: return stroke
            case .caress: return caress
            }
        }
    }

    static let minPartConfidence: Double = 0.3
    static let agreeRatio: Double = 0.15
    static let refMinConfidence: Double = 0.3
    static let minEvidence: Double = 0.3
    static let evidenceMargin: Double = 0.1
    /// 当前动作的依据还 ≥ 这个就算「还在」
    static let keepEvidence: Double = 0.15
    static let switchSeconds: TimeInterval = 0.9
    static let dropSeconds: TimeInterval = 1.5
    static let contextMaxAge: Double = 0.8
    static let roiMaxAge: Double = 0.6
    /// 部位离区域中心 ≤ max(区域半对角线, 1.5 × 部位尺度) 算在区域旁（2 倍内算一半）
    static let nearShare: Double = 1.5
    /// 没有周期区域 / 没有参考频率时的折扣
    static let noRoiProximity: Double = 0.7
    static let noRefAgreement: Double = 0.6
    /// 手 / 头的幅度要 ≥ 1.5 × 髋才算「手 / 头在动」（髋也在同频往复时）
    static let dominanceSpan: Double = 0.5
    static let insertionShare: Double = 0.67
    /// 主轴和「往里」夹角 ≤ 70° 才判断方向；方向改判要持续 1 秒
    static let directionDot: Double = 0.34
    static let directionHoldSeconds: TimeInterval = 1
    /// 部位到目标髋的距离 ≥ 0.3 个尺度才判断方向（重叠时分不清）
    static let minInwardShare: Double = 0.3
    /// 区域内运动的跟随置信度不低于整幅 − 0.05 才用
    static let roiSlack: Double = 0.05
    /// 没检测到身体时：整幅主体分数 ≥ 0.2（画面确实在动）才让手 / 脸的节奏能被跟随器采用
    static let liftSubjectScore: Double = 0.2
    /// rhythm-action tune：自己的手腕在自己的躯干上（胸口锚点往髋的方向 −0.15 ~ 0.7 段、离中线 ≤ 0.6 个身体尺度）、
    /// 髋没在和画面同频地大幅往复、主要的周期区域就在这只手旁（要有新鲜的区域）、这只手的动作小 / 不规则（quietTouch）
    /// → 轻抚（依据最多 0.6）。没有区域时只算 selfPaced（软压低 + 不跟节奏，不封顶）
    static let caressEvidence: Double = 0.6
    static let torsoAbove: Double = 0.15
    static let torsoBelow: Double = 0.7
    static let torsoAcross: Double = 0.6
    /// 手检测离自己摸着身体的那只手腕 ≤ 0.5 个身体尺度：就是那只手，不算撸动的依据
    static let selfHandReach: Double = 0.5
    /// 髋「在往复」：节奏置信度 ≥ 0.4、单程幅度 ≥ 0.06 躯干（有参考频率时还要一致）
    static let hipsActiveConfidence: Double = 0.4
    static let hipsActiveAmplitude: Double = 0.06
    /// 撸动要有对象：手 / 手腕离某个髋（自己的 / 另一个人的）≤ 1 个身体尺度
    static let strokeHipReach: Double = 1.0
    /// 口交要有对象：脸 / 头离一个不是它自己身体的髋 ≤ 1.2 个身体尺度（说话 / 点头的人自己不算）
    static let oralHipReach: Double = 1.2
    /// 轻抚时强度（上限之前的 0~100）最多到这么多
    static let caressCeiling: Double = 20
    /// 改判确认中漏掉的拍（这一拍没有够格的候选）不重新计时，连续缺超过这么久才放弃
    static let pendingGapSeconds: TimeInterval = 0.6
    /// 轻抚要那只手自己在慢慢动：节奏 ≤ 2 次/秒（再快不是轻抚）
    static let caressMaxHz: Double = 2
    /// 整幅主体分数 ≥ 这个（画面在大幅动）不算轻抚（同 MotionNormalizer.gentleHigh：不轻的动作）
    static let caressMaxSubject: Double = 0.55
    /// 跟随器锁着、锁的权重 ≥ 这个时，频率和摸着身体的那只手对不上就不算轻抚（锁的是别的往复）
    static let caressLockWeight: Double = 0.5
    /// 「锁在别的频率上」的一致范围放宽到 ±35%（两个估计各自有误差，±15% 太严，会把真轻抚判成锁在别处）
    static let lockAgreeRatio: Double = 0.35
    /// 摸着自己的那只手：节奏置信度 ≥ 0.5 且单程幅度 ≥ 0.12 躯干（规则、幅度大）= 往复，不是轻抚；
    /// 和区域 / 整幅的参考频率一致时它算撸动等的依据（不从对手依据里扣掉）
    static let caressMaxConfidence: Double = 0.5
    static let caressMaxAmplitude: Double = 0.12

    /// rhythm-action tune：摸着自己躯干的那只手腕（位置 + 它自己的节奏），另一只手腕（有的话）
    struct SelfTouch: Equatable {
        var x: Double
        var y: Double
        var rhythm = PartRhythm()
        /// 那只手腕不扣全身中位速度的节奏（手跟着上身一起往复时只有它看得出来）
        var rawRhythm = PartRhythm()
        var hasOther = false
        var otherX: Double = 0
        var otherY: Double = 0
        var otherRhythm = PartRhythm()
    }

    private(set) var kind = Kind.unknown
    private(set) var evidence = Evidence()
    /// 这一拍用的部位：0 没改、1 髋、2 头 / 脸、3 手 / 腕
    private(set) var part = 0
    private(set) var usesHand = false
    private(set) var usesFace = false
    private(set) var usesRoi = false
    /// rhythm-action tune：插入时用的是另一个人的髋（他在往复）
    private(set) var usesOtherHips = false
    /// rhythm-action tune：这一拍画面里的节奏只来自摸着自己躯干的那只手（它自己在慢慢动、没有往复的对手、
    /// 跟随器没锁在别的频率上）——还没有区域、算不上轻抚时，慢 / 轻动作照样压低
    private(set) var selfPaced = false
    /// 往里方向：+1 主轴正方向就是往里、−1 反了（相位翻 180°）、0 判断不了（不改）
    private(set) var flowDirection = 0
    private(set) var poseDirection = 0
    private(set) var inwardKnown = false
    private var pendingKind: Kind?
    private var pendingSince: Double = 0
    /// 最近一次看到和 pendingKind 相同的候选的时刻（漏拍容忍）
    private var pendingSeen: Double = 0
    private var lastSupported = -Double.infinity
    private var context = PoseContext()
    /// 最近一个有区域的读数（调试叠加层也读）
    private(set) var roi = RoiReading()
    private var flowPending = 0
    private var flowPendingSince: Double = 0
    private var posePending = 0
    private var posePendingSince: Double = 0

    mutating func reset() {
        self = ActionContext()
    }

    /// 方向已判断（给撞击声校正：已知时只做 ±60° 的细调）
    var directionKnown: Bool { inwardKnown && (flowDirection != 0 || poseDirection != 0) }

    /// rhythm-action tune：节奏只来自摸着自己的、动作小 / 不规则的那只手（没有区域、算不上轻抚时）
    private(set) var quietSelf = false

    /// rhythm-action tune：轻抚，或还没认出动作且节奏只来自摸着自己的安静的手时节奏不起作用
    /// （VideoSyncPlayer 把这一拍当成「画面不在往复」）
    var suppressesRhythm: Bool { kind == .caress || (kind == .unknown && quietSelf) }

    /// rhythm-action tune：这一拍画面强度（上限之前的 0~100）最多多少；nil = 不限
    var intensityCeiling: Double? { kind == .caress ? Self.caressCeiling : nil }

    /// rhythm-action tune：MotionNormalizer.gentleAllowed——只有正面依据才压慢 / 轻动作：轻抚，或还没认出动作且
    /// 节奏只来自摸着自己的那只手（selfPaced）。只是「没认出 / 没锁」不算（慢的、不规则的真往复不压）；
    /// 画面完全没节奏时 MotionNormalizer.unrhythmic 自己会压。followerLocked 不再参与（保留参数给调用方）
    func allowsGentle(followerLocked: Bool) -> Bool {
        kind == .caress || (kind == .unknown && selfPaced)
    }

    /// rhythm-action tune：摸着自己的手动作小 / 不规则（才可能是轻抚）
    static func quietTouch(_ r: PartRhythm) -> Bool {
        let f = r.follow
        let conf = f.confidence.isFinite ? f.confidence : 0
        let amp = f.amplitude.isFinite ? f.amplitude : 0
        return conf < caressMaxConfidence || amp < caressMaxAmplitude
    }

    /// rhythm-action tune：摸着自己的手规则、大幅地往复，且和参考频率一致（有的话）：是往复动作（撸动 / 乳交 / 骑乘时的手）
    static func reciprocatingTouch(_ r: PartRhythm, refHz: Double) -> Bool {
        let f = r.follow
        guard !quietTouch(r), f.hz.isFinite, RhythmFollower.hzRange.contains(f.hz) else { return false }
        return refHz > 0 ? agreesLoosely(f.hz, refHz) : true
    }

    /// 轻抚这条路的频率一致（锁定判断 / 轻抚依据 / 摸着自己的手在往复）：同频 ±35%，或差一个八度（一个估计减半 / 加倍）±15%。
    /// 八度那支用严的 ±15%：两支都放宽的话 0.37~2.7 倍几乎全算一致，就分不出「锁在别的频率上」了
    private static func agreesLoosely(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0, a.isFinite, b.isFinite else { return false }
        let r = abs(log(a / b))
        return r <= log(1 + lockAgreeRatio) || abs(r - log(2.0)) <= log(1 + agreeRatio)
    }

    /// rhythm-action tune：传给 refine 的 followerHz（锁定且权重够才算牢牢锁着；否则 0）
    static func lockedHz(locked: Bool, weight: Double, hz: Double) -> Double {
        locked && weight.isFinite && weight >= caressLockWeight && hz.isFinite && hz > 0 ? hz : 0
    }

    private static func agrees(_ a: Double, _ b: Double) -> Bool {
        a > 0 && b > 0 && a.isFinite && b.isFinite && abs(log(a / b)) <= log(1 + agreeRatio)
    }

    private static func distance(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        ((ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
    }

    /// 部位离周期区域多近：1 在区域旁、0.5 在两倍范围内、0 远；没有区域时 noRoiProximity
    static func proximity(_ x: Double, _ y: Double, size: Double, region: PeriodicityROI?,
                          frameWidth w: Double, frameHeight h: Double) -> Double {
        guard let g = region, g.valid, w > 0, h > 0 else { return noRoiProximity }
        let cx = g.centerX * w
        let cy = g.centerY * h
        let gw = (g.x1 - g.x0) * w
        let gh = (g.y1 - g.y0) * h
        let half = 0.5 * (gw * gw + gh * gh).squareRoot()
        let reach = max(half, nearShare * max(0, size.isFinite ? size : 0))
        let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
        return d <= reach ? 1 : (d <= 2 * reach ? 0.5 : 0)
    }

    /// 一个部位的依据：节奏置信度 × 频率一致 × 在区域旁
    static func support(_ r: PartRhythm, x: Double, y: Double, size: Double, refHz: Double, region: PeriodicityROI?,
                        frameWidth w: Double, frameHeight h: Double) -> Double {
        let f = r.follow
        guard f.hz.isFinite, RhythmFollower.hzRange.contains(f.hz), f.confidence.isFinite,
              f.confidence >= minPartConfidence, x.isFinite, y.isFinite else { return 0 }
        let agree = refHz > 0 ? (agrees(f.hz, refHz) ? 1 : 0) : noRefAgreement
        let near = proximity(x, y, size: size, region: region, frameWidth: w, frameHeight: h)
        return MotionStats.clamp01(f.confidence) * agree * near
    }

    private static func dominance(_ a: Double, hip: Double) -> Double {
        guard hip > 0, hip.isFinite else { return 1 }
        guard a.isFinite, a > 0 else { return 0 }
        return MotionStats.clamp01((a / hip - 1) / dominanceSpan)
    }

    /// rhythm-action tune：这组关节在明显地往复（置信度 / 幅度够；有参考频率时还要一致）
    static func reciprocating(_ f: StrokeRhythm.FollowEstimate, refHz: Double) -> Bool {
        guard f.hz.isFinite, RhythmFollower.hzRange.contains(f.hz), f.confidence.isFinite,
              f.confidence >= hipsActiveConfidence, f.amplitude.isFinite, f.amplitude >= hipsActiveAmplitude else {
            return false
        }
        return refHz > 0 ? agrees(f.hz, refHz) : true
    }

    /// rhythm-action tune：自己的哪只手腕在自己的躯干上（胸口 / 肚子，不到胯；没有就 nil）。
    /// 躯干方向：胸口锚点 → 髋心（没有髋 / 太近时按画面向下、长度按身体尺度）
    static func selfTouchWrist(_ b: PoseBodyContext) -> (x: Double, y: Double)? {
        selfTouch(b).map { ($0.x, $0.y) }
    }

    /// rhythm-action tune：同 selfTouchWrist，再带上那只手腕自己的节奏和另一只手腕
    static func selfTouch(_ b: PoseBodyContext) -> SelfTouch? {
        guard b.present, b.hasChest, b.scale.isFinite, b.scale > 0 else { return nil }
        var ax = 0.0
        var ay = 1.0
        var length = b.scale
        if b.hasHip {
            let dx = b.hipX - b.chestX
            let dy = b.hipY - b.chestY
            let d = (dx * dx + dy * dy).squareRoot()
            if d.isFinite, d >= 0.3 * b.scale {
                ax = dx / d
                ay = dy / d
                length = d
            }
        }
        var wrists: [(x: Double, y: Double, rhythm: StrokeRhythm.FollowEstimate, raw: StrokeRhythm.FollowEstimate)] = []
        if b.hasLeftWrist { wrists.append((b.leftWristX, b.leftWristY, b.leftWristRhythm, b.leftWristRaw)) }
        if b.hasRightWrist { wrists.append((b.rightWristX, b.rightWristY, b.rightWristRhythm, b.rightWristRaw)) }
        for (i, w) in wrists.enumerated() {
            let rx = w.x - b.chestX
            let ry = w.y - b.chestY
            let along = rx * ax + ry * ay
            let across = abs(rx * ay - ry * ax)
            if along >= -torsoAbove * length, along <= torsoBelow * length, across <= torsoAcross * b.scale {
                var t = SelfTouch(x: w.x, y: w.y, rhythm: PartRhythm(follow: w.rhythm), rawRhythm: PartRhythm(follow: w.raw))
                if wrists.count == 2 {
                    let o = wrists[1 - i]
                    t.hasOther = true
                    t.otherX = o.x
                    t.otherY = o.y
                    t.otherRhythm = PartRhythm(follow: o.rhythm)
                }
                return t
            }
        }
        return nil
    }

    /// rhythm-action tune：一只手自己慢慢动的依据（节奏 ≤ caressMaxHz 才算；其余同 support，但频率一致按 agreesLoosely：
    /// 姿态手腕和块运动 / 区域是两个估计，慢而不规则的轻抚差 15% 以上、或者一个减半了很常见）
    static func slowSupport(_ r: PartRhythm, x: Double, y: Double, size: Double, refHz: Double, region: PeriodicityROI?,
                            frameWidth w: Double, frameHeight h: Double) -> Double {
        let f = r.follow
        guard f.hz.isFinite, f.hz <= caressMaxHz, RhythmFollower.hzRange.contains(f.hz), f.confidence.isFinite,
              f.confidence >= minPartConfidence, x.isFinite, y.isFinite else { return 0 }
        let agree = refHz > 0 ? (agreesLoosely(f.hz, refHz) ? 1 : 0) : noRefAgreement
        let near = proximity(x, y, size: size, region: region, frameWidth: w, frameHeight: h)
        return MotionStats.clamp01(f.confidence) * agree * near
    }

    /// rhythm-action tune：到最近的「对象髋」的距离（以那个身体的尺度计；没有就 ∞）。
    /// excludeOwn / excludeOther：这个部位就是那个身体自己的（脸 = 自己的头），它自己的髋不算对象
    static func hipReach(_ x: Double, _ y: Double, body b: PoseBodyContext, excludeOwn: Bool,
                         excludeOther: Bool) -> Double {
        var best = Double.infinity
        guard x.isFinite, y.isFinite else { return best }
        if b.hasHip, !excludeOwn, b.scale > 0 {
            best = min(best, distance(x, y, b.hipX, b.hipY) / b.scale)
        }
        if b.hasOtherHip, !excludeOther {
            let s = b.otherScale > 0 ? b.otherScale : b.scale
            if s > 0 { best = min(best, distance(x, y, b.otherHipX, b.otherHipY) / s) }
        }
        return best.isFinite ? best : .infinity
    }

    /// 每个完整拍一次；now：host 时间（CACurrentMediaTime，和画面帧时间同一时间轴）。
    /// followerHz：频率跟随器上一拍牢牢锁着（锁定且权重 ≥ caressLockWeight）时的频率，否则 0（轻抚判断用）
    mutating func refine(_ w: MotionWindow, now: Double, followerHz: Double = 0) -> MotionWindow {
        part = 0
        usesHand = false
        usesFace = false
        usesRoi = false
        usesOtherHips = false
        selfPaced = false
        quietSelf = false
        guard now.isFinite else { return w }
        if w.cutCount > 0 {
            // 切镜：立刻回「未知」，新镜头重新判断
            reset()
            return w
        }
        if w.context.valid { context = w.context }
        if w.roi.valid || w.roi.region.valid { roi = w.roi }
        let ctxFresh = context.valid && context.time.isFinite && now - context.time <= Self.contextMaxAge
        let regionFresh = roi.region.valid && now - roi.region.time <= Self.roiMaxAge
        let region: PeriodicityROI? = regionFresh ? roi.region : nil
        let fw = context.frameWidth
        let fh = context.frameHeight

        // 参考频率：区域内运动（可信时）或整幅主体
        var refHz = 0.0
        let rs = roi.subject
        let roiUsable = w.roiFrames > 0 && roi.valid && now - roi.time <= Self.roiMaxAge && rs.followHz.isFinite
            && RhythmFollower.hzRange.contains(rs.followHz) && rs.followAmplitude.isFinite
            && rs.followAmplitude >= RhythmFollower.flowMinAmplitude && rs.followRhythm.isFinite
            && rs.followRhythm >= w.subjectFollowRhythm - Self.roiSlack && rs.score.isFinite
            && rs.score >= RhythmFollower.flowMinScore
        if roiUsable, rs.followRhythm >= Self.refMinConfidence {
            refHz = rs.followHz
        } else if w.subjectFrames > 0, w.subjectFollowHz.isFinite, RhythmFollower.hzRange.contains(w.subjectFollowHz),
                  w.subjectFollowRhythm.isFinite, w.subjectFollowRhythm >= Self.refMinConfidence {
            refHz = w.subjectFollowHz
        }

        // 各部位的依据
        var ev = Evidence()
        var sHand = 0.0, sWrist = 0.0, sFace = 0.0, sHead = 0.0, sHips = 0.0, sOther = 0.0
        let body = context.body
        let hand = context.hand
        let face = context.face
        // rhythm-action tune：自己的手在自己躯干上（姿态没给胸口 / 各自的手腕时 nil）。
        // 那只手规则、大幅地和参考频率同步往复（手在胸口 / 肚子前撸、乳交、骑乘时手放胸口）：不当成摸自己，
        // 它照常算撸动等的依据，也不算轻抚（reciprocatingSelf）
        let touched: SelfTouch? = ctxFresh ? Self.selfTouch(body) : nil
        // 扣过全身中位速度的、没扣的都看：手跟着上身一起往复（骑乘手放胸口、乳交）时扣过的只剩 40%，看起来像安静的手
        let reciprocatingSelf = touched.map {
            Self.reciprocatingTouch($0.rhythm, refHz: refHz) || Self.reciprocatingTouch($0.rawRhythm, refHz: refHz)
        } ?? false
        let selfTouch: SelfTouch? = reciprocatingSelf ? nil : touched
        // 撸动看的手腕：平时是两腕的平均；一只手摸着自己时只看另一只（它可能在撸动）
        var wristPart = body.wrists
        var wristX = body.wristX
        var wristY = body.wristY
        var caressBlocked = false
        if ctxFresh {
            // 手检测就是摸着自己的那只手：不算撸动的依据（离那只手腕近、且比离另一只手腕近，而且它自己也安静）。
            // 离那只手腕近、却规则大幅地往复的手（别人在撸，被撸的人手放在小腹上）不归给自己：照常算撸动依据，也挡住轻抚
            var handIsSelf = false
            var handReciprocating = false
            if let st = selfTouch, hand.present {
                let dSelf = Self.distance(hand.x, hand.y, st.x, st.y)
                let dOther = st.hasOther ? Self.distance(hand.x, hand.y, st.otherX, st.otherY) : Double.infinity
                let nearSelf = dSelf <= Self.selfHandReach * max(body.scale, 1e-6) && dSelf < dOther
                handIsSelf = nearSelf && Self.quietTouch(hand.rhythm)
                handReciprocating = nearSelf && Self.reciprocatingTouch(hand.rhythm, refHz: refHz)
            }
            if hand.present && !handIsSelf {
                sHand = Self.support(hand.rhythm, x: hand.x, y: hand.y, size: hand.size, refHz: refHz, region: region,
                                     frameWidth: fw, frameHeight: fh)
            }
            if face.present {
                sFace = Self.support(face.rhythm, x: face.x, y: face.y, size: face.size, refHz: refHz, region: region,
                                     frameWidth: fw, frameHeight: fh)
            }
            if body.present {
                // 两腕的平均位置：有一只手摸着自己时不代表在撸动；这时只看另一只手腕自己的节奏
                if let st = selfTouch {
                    if st.hasOther {
                        wristPart = st.otherRhythm
                        wristX = st.otherX
                        wristY = st.otherY
                        sWrist = Self.support(wristPart, x: wristX, y: wristY, size: 0.5 * body.scale,
                                              refHz: refHz, region: region, frameWidth: fw, frameHeight: fh)
                    }
                } else if body.hasWrist {
                    sWrist = Self.support(body.wrists, x: body.wristX, y: body.wristY, size: 0.5 * body.scale,
                                          refHz: refHz, region: region, frameWidth: fw, frameHeight: fh)
                }
                if body.hasHead {
                    sHead = Self.support(body.head, x: body.headX, y: body.headY, size: 0.5 * body.scale,
                                         refHz: refHz, region: region, frameWidth: fw, frameHeight: fh)
                }
                if body.hasHip {
                    sHips = Self.support(body.hips, x: body.hipX, y: body.hipY, size: body.scale, refHz: refHz,
                                         region: region, frameWidth: fw, frameHeight: fh)
                }
                if body.hasOtherHip {
                    sOther = Self.support(body.otherHips, x: body.otherHipX, y: body.otherHipY, size: body.otherScale,
                                          refHz: refHz, region: region, frameWidth: fw, frameHeight: fh)
                }
            }
            let ownA = sHips > 0 ? body.hips.follow.amplitude : 0
            let otherA = sOther > 0 ? body.otherHips.follow.amplitude : 0
            let hipA = max(ownA.isFinite ? ownA : 0, otherA.isFinite ? otherA : 0)
            // 对象：手 / 手腕要在某个髋旁；脸 / 头要在一个不是它自己身体的髋旁（rhythm-action tune）
            let faceReach = max(0.5 * face.size, 0.25 * body.scale)
            let ownFace = body.hasHead && Self.distance(face.x, face.y, body.headX, body.headY) <= faceReach
            let otherFace = body.hasOtherHead
                && Self.distance(face.x, face.y, body.otherHeadX, body.otherHeadY) <= faceReach
            let handTarget = Self.hipReach(hand.x, hand.y, body: body, excludeOwn: false, excludeOther: false)
            let wristTarget = Self.hipReach(wristX, wristY, body: body, excludeOwn: false, excludeOther: false)
            let faceTarget = Self.hipReach(face.x, face.y, body: body, excludeOwn: ownFace, excludeOther: otherFace)
            let headTarget = Self.hipReach(body.headX, body.headY, body: body, excludeOwn: true, excludeOther: false)
            let handOK: Double = handTarget <= Self.strokeHipReach ? 1 : 0
            let wristOK: Double = wristTarget <= Self.strokeHipReach ? 1 : 0
            let faceOK: Double = faceTarget <= Self.oralHipReach ? 1 : 0
            let headOK: Double = headTarget <= Self.oralHipReach ? 1 : 0
            let handScore = sHand * Self.dominance(hand.rhythm.follow.amplitude, hip: hipA) * handOK
            let wristScore = 0.8 * sWrist * Self.dominance(wristPart.follow.amplitude, hip: hipA) * wristOK
            let faceScore = sFace * Self.dominance(face.rhythm.follow.amplitude, hip: hipA) * faceOK
            let headScore = 0.9 * sHead * Self.dominance(body.head.follow.amplitude, hip: hipA) * headOK
            ev.stroke = max(handScore, wristScore)
            ev.oral = max(faceScore, headScore)
            var other = 0.0
            if sHand > 0 { other = max(other, hand.rhythm.follow.amplitude) }
            if sWrist > 0 { other = max(other, wristPart.follow.amplitude) }
            if sFace > 0 { other = max(other, face.rhythm.follow.amplitude) }
            if sHead > 0 { other = max(other, body.head.follow.amplitude) }
            let hipShare = other > 0 && other.isFinite
                ? MotionStats.clamp01((hipA / other - Self.insertionShare) / (1 - Self.insertionShare)) : 1
            ev.insertion = max(sHips, sOther) * hipShare
            usesHand = handScore >= wristScore && sHand > 0
            usesFace = faceScore >= headScore && sFace > 0
            // 轻抚：自己的手在自己躯干上、这只手自己在慢慢动（依据随它的节奏置信度，最多 caressEvidence），
            // 主要的周期区域就在这只手旁（要有新鲜的区域，且离这只手比离任何髋都近）。
            // 有往复的对手（撸动 / 口交 / 插入依据 ≥ minEvidence、髋在往复）、整幅画面在大幅动、
            // 或者跟随器牢牢锁在别的频率上时不算（而且已经是轻抚的立刻放开，见下面）
            // 轻抚的放开条件（L2：不管现在还有没有手摸着自己都算）
            let hipsActive = Self.reciprocating(body.hips.follow, refHz: refHz)
                || (body.hasOtherHip && Self.reciprocating(body.otherHips.follow, refHz: refHz))
            let competitor = max(ev.stroke, ev.oral, ev.insertion)
            let strong = w.subjectFrames > 0 && w.subjectScore.isFinite && w.subjectScore >= Self.caressMaxSubject
            caressBlocked = hipsActive || competitor >= Self.minEvidence || strong || reciprocatingSelf
                || handReciprocating
            if let st = selfTouch {
                var own = Self.slowSupport(st.rhythm, x: st.x, y: st.y, size: 0.5 * body.scale, refHz: refHz,
                                           region: region, frameWidth: fw, frameHeight: fh)
                var ownHz = st.rhythm.follow.hz
                if handIsSelf {
                    let s = Self.slowSupport(hand.rhythm, x: hand.x, y: hand.y, size: hand.size, refHz: refHz,
                                             region: region, frameWidth: fw, frameHeight: fh)
                    if s > own {
                        own = s
                        ownHz = hand.rhythm.follow.hz
                    }
                }
                var regionOK = false
                if let g = region, fw > 0, fh > 0,
                   Self.proximity(st.x, st.y, size: 0.5 * body.scale, region: g, frameWidth: fw, frameHeight: fh) >= 1 {
                    let cx = g.centerX * fw
                    let cy = g.centerY * fh
                    var hipD = Double.infinity
                    if body.hasHip { hipD = min(hipD, Self.distance(body.hipX, body.hipY, cx, cy)) }
                    if body.hasOtherHip { hipD = min(hipD, Self.distance(body.otherHipX, body.otherHipY, cx, cy)) }
                    regionOK = Self.distance(st.x, st.y, cx, cy) < hipD
                }
                let lockedElsewhere = followerHz > 0 && followerHz.isFinite && !Self.agreesLoosely(ownHz, followerHz)
                caressBlocked = caressBlocked || lockedElsewhere
                // 硬上限 + 不跟节奏只给动作小 / 不规则的手（规则大幅的往复不封顶，最多 selfPaced 的软压低）
                let quiet = Self.quietTouch(st.rhythm) && Self.quietTouch(st.rawRhythm)
                if !caressBlocked && regionOK && quiet { ev.caress = min(Self.caressEvidence, own) }
                selfPaced = !caressBlocked && own >= Self.minEvidence
                quietSelf = selfPaced && quiet
            }
        }
        evidence = ev
        // 已经是轻抚、但出现了往复的对手：立刻放开（强度上限 / 不跟节奏马上撤掉），对手照常确认
        // （姿态上下文过期时也看整幅画面是不是在大幅动）
        let strongNow = w.subjectFrames > 0 && w.subjectScore.isFinite && w.subjectScore >= Self.caressMaxSubject
        if kind == .caress, caressBlocked || strongNow {
            kind = .unknown
            pendingKind = nil
        }

        // 选动作 + 滞回（漏一两拍不重新计时）
        let ranked: [(Kind, Double)] = [(.insertion, ev.insertion), (.oral, ev.oral), (.stroke, ev.stroke),
                                        (.caress, ev.caress)].sorted { $0.1 > $1.1 }
        let candidate: Kind? = ranked[0].1 >= Self.minEvidence && ranked[0].1 - ranked[1].1 >= Self.evidenceMargin
            ? ranked[0].0 : nil
        if kind != .unknown, ev.value(kind) >= Self.keepEvidence { lastSupported = now }
        if let c = candidate, c != kind {
            if pendingKind == c, now - pendingSeen <= Self.pendingGapSeconds + 1e-9 {
                pendingSeen = now
                if now - pendingSince >= Self.switchSeconds {
                    kind = c
                    lastSupported = now
                    pendingKind = nil
                }
            } else {
                pendingKind = c
                pendingSince = now
                pendingSeen = now
            }
        } else if candidate != nil || pendingKind == nil || now - pendingSeen > Self.pendingGapSeconds + 1e-9 {
            // 候选就是现在的动作 / 没有在确认的 / 缺得太久：放弃确认；只漏一两拍（≤ 0.6 秒）时保留进度
            pendingKind = nil
        }
        if kind != .unknown, now - lastSupported >= Self.dropSeconds { kind = .unknown }

        var r = w
        if roiUsable {
            r.subjectFollowHz = rs.followHz
            r.subjectFollowRhythm = MotionStats.clamp01(rs.followRhythm)
            r.subjectFollowAmplitude = rs.followAmplitude
            if rs.phase.isValid { r.subjectPhase = rs.phase }
            usesRoi = true
        }

        // 动作 → 部位的节奏
        var chosen: PartRhythm?
        var moving: (x: Double, y: Double, size: Double)?
        switch kind {
        case .unknown, .caress:
            break
        case .stroke:
            if usesHand {
                chosen = hand.rhythm
                moving = (hand.x, hand.y, hand.size)
            } else if sWrist > 0 {
                chosen = wristPart
                moving = (wristX, wristY, body.scale)
            }
            part = 3
        case .oral:
            if usesFace {
                chosen = face.rhythm
                moving = (face.x, face.y, face.size)
            } else if sHead > 0 {
                chosen = body.head
                moving = (body.headX, body.headY, body.scale)
            }
            part = 2
        case .insertion:
            if sOther > sHips {
                // rhythm-action tune：另一个人的髋往复得更明显（认到的这个人可能是不动的那个）：跟他
                chosen = body.otherHips
                moving = (body.otherHipX, body.otherHipY, body.otherScale > 0 ? body.otherScale : body.scale)
                usesOtherHips = true
            } else if sHips > 0 {
                chosen = body.hips
                moving = (body.hipX, body.hipY, body.scale)
            }
            part = 1
        }
        // 自审 M1：整幅画面 / 周期区域没有可信往复节奏（refHz == 0）时不改写、不抬高姿态节奏——
        // 只有手 / 脸在动（点头、手势）不该把跟随器锁上、推高伸缩档位
        if let pr = chosen, ctxFresh, pr.follow.hz > 0, refHz > 0 {
            r.poseRhythmHz = pr.follow.hz
            r.poseRhythmConfidence = MotionStats.clamp01(pr.follow.confidence)
            r.poseRhythmPart = part
            r.poseRhythmRate = pr.follow.sampleRate.isFinite ? max(0, pr.follow.sampleRate) : 0
            r.posePhase = pr.phase.isValid ? pr.phase : StrokeRhythm.PhaseFit()
            let floor = part == 3 ? RhythmFollower.wristMinScore : RhythmFollower.poseMinScore
            if r.posePresentFrames == 0 || !(r.poseScore >= floor) {
                if w.subjectFrames > 0, w.subjectScore.isFinite, w.subjectScore >= Self.liftSubjectScore {
                    r.posePresentFrames = max(1, r.posePresentFrames)
                    r.poseScore = max(r.poseScore.isFinite ? r.poseScore : 0, floor)
                    if !(r.poseConfidence > 0) { r.poseConfidence = MotionStats.clamp01(pr.follow.confidence) }
                }
            }
        } else {
            part = 0
            usesOtherHips = false
            // 复审：没采用这个部位的节奏（refHz == 0）时也不拿它判断往里方向——
            // 否则会按手 / 脸的位置去翻原来那份（可能是髋的）姿态相位
            if refHz <= 0 { moving = nil }
        }
        if suppressesRhythm {
            // rhythm-action tune：轻抚 / 只有摸着自己的安静的手（quietSelf）不是往复动作，频率跟随 / 相位锁这一拍都没有候选
            // （VideoSyncPlayer 还按 suppressesRhythm 把这一拍当成「画面不在往复」，伸缩当拍不跟节奏）
            r.subjectFollowHz = 0
            r.subjectFollowRhythm = 0
            r.subjectFollowAmplitude = 0
            r.subjectPhase = StrokeRhythm.PhaseFit()
            r.poseRhythmHz = 0
            r.poseRhythmConfidence = 0
            r.poseRhythmPart = 0
            r.poseRhythmRate = 0
            r.posePhase = StrokeRhythm.PhaseFit()
            usesRoi = false
            moving = nil
        }

        // 往里方向：朝目标髋
        var inward: (x: Double, y: Double)?
        if ctxFresh, let p = moving {
            var targets: [(x: Double, y: Double)] = []
            switch kind {
            case .stroke:
                if body.hasHip { targets.append((body.hipX, body.hipY)) }
                if body.hasOtherHip { targets.append((body.otherHipX, body.otherHipY)) }
            case .oral:
                let reach = max(0.5 * p.size, 0.25 * body.scale)
                let ownBody = body.hasHead && hypot(body.headX - p.x, body.headY - p.y) <= reach
                let ownOther = body.hasOtherHead && hypot(body.otherHeadX - p.x, body.otherHeadY - p.y) <= reach
                if body.hasHip, !ownBody, !(part == 2 && !usesFace) { targets.append((body.hipX, body.hipY)) }
                if body.hasOtherHip, !ownOther { targets.append((body.otherHipX, body.otherHipY)) }
            case .insertion:
                if usesOtherHips {
                    // 另一个人在往复：往里 = 朝认到的这个人的髋
                    if body.hasHip { targets.append((body.hipX, body.hipY)) }
                } else if body.hasOtherHip {
                    targets.append((body.otherHipX, body.otherHipY))
                }
            case .unknown, .caress:
                break
            }
            var best: (x: Double, y: Double)?
            var bestD = Double.infinity
            for t in targets {
                let d = hypot(t.x - p.x, t.y - p.y)
                if d < bestD {
                    bestD = d
                    best = (t.x - p.x, t.y - p.y)
                }
            }
            let ref = max(p.size, 1e-6)
            if let b = best, bestD.isFinite, bestD >= Self.minInwardShare * ref {
                inward = (b.x / bestD, b.y / bestD)
            }
        }
        inwardKnown = inward != nil
        if let u = inward {
            flowDirection = Self.decide(fit: r.subjectPhase, inward: u, state: flowDirection, pending: &flowPending,
                                        since: &flowPendingSince, now: now)
            poseDirection = Self.decide(fit: r.posePhase, inward: u, state: poseDirection, pending: &posePending,
                                        since: &posePendingSince, now: now)
            if flowDirection < 0 { r.subjectPhase = Self.flipped(r.subjectPhase) }
            if poseDirection < 0 { r.posePhase = Self.flipped(r.posePhase) }
        } else {
            flowDirection = 0
            poseDirection = 0
            flowPending = 0
            posePending = 0
        }
        return r
    }

    /// 主轴和往里的点积 → +1 / −1 / 0（夹角接近 90° 时保持原判断）；改判要持续 directionHoldSeconds
    private static func decide(fit: StrokeRhythm.PhaseFit, inward u: (x: Double, y: Double), state: Int,
                               pending: inout Int, since: inout Double, now: Double) -> Int {
        guard fit.isValid else { return state }
        let n = (fit.axisX * fit.axisX + fit.axisY * fit.axisY).squareRoot()
        guard n > 1e-6, n.isFinite else { return state }
        let d = (fit.axisX * u.x + fit.axisY * u.y) / n
        let raw = d >= directionDot ? 1 : (d <= -directionDot ? -1 : 0)
        if raw == 0 || raw == state {
            pending = 0
            return state
        }
        if state == 0 {
            pending = 0
            return raw
        }
        if pending == raw {
            if now - since >= directionHoldSeconds {
                pending = 0
                return raw
            }
        } else {
            pending = raw
            since = now
        }
        return state
    }

    /// 相位翻 180°、主轴反向（往里 = 新的正方向）
    static func flipped(_ f: StrokeRhythm.PhaseFit) -> StrokeRhythm.PhaseFit {
        guard f.isValid else { return f }
        var g = f
        g.phase = StrokeRhythm.wrapPhase(f.phase + Double.pi)
        g.axisX = -f.axisX
        g.axisY = -f.axisY
        return g
    }

    /// 界面上的一行（关着时调用方不显示）
    func statusText() -> String {
        var text: String
        switch kind {
        case .unknown: text = "动作识别：还没认出动作（按整幅画面跟）"
        case .insertion: text = usesOtherHips ? "动作识别：插入（看另一个人的髋）" : "动作识别：插入（看髋）"
        case .oral: text = usesFace ? "动作识别：口交（看脸）" : "动作识别：口交（看头）"
        case .stroke: text = usesHand ? "动作识别：撸动（看手）" : "动作识别：撸动（看手腕）"
        case .caress: text = "动作识别：轻抚 / 摸自己（不跟节奏，强度压低）"
        }
        if usesRoi { text += "，用周期区域内的运动" }
        if kind != .unknown && kind != .caress {
            text += directionKnown ? "，往里方向已判断" : "，往里方向判断不了（按原约定 / 方向反转开关）"
        }
        return text
    }
}

/// 10 毫秒一块的三频带能量（均方，满幅 = 1）：低 < 200 Hz、中 200 Hz ~ 2 kHz、高 > 2 kHz；time：块中点的视频时间（秒）
struct AudioBandFrame: Equatable {
    var time: Double = 0
    var low: Float = 0
    var mid: Float = 0
    var high: Float = 0
}

/// 音频实时线程上用：两个一阶低通分三段、每 10 毫秒出一块。只有几个数的状态，不分配、不加锁
struct AudioBandSplitter {
    static let blockSeconds: Double = 0.01
    static let lowCutHz: Double = 200
    static let midCutHz: Double = 2000
    /// 回调之间时间对不上（seek / 丢样本）超过这么多就丢掉没满的块
    static let maxSkew: Double = 0.05

    private(set) var sampleRate: Double = 0
    private var aLow: Double = 0
    private var aMid: Double = 0
    private var sLow: Double = 0
    private var sMid: Double = 0
    private var accLow: Double = 0
    private var accMid: Double = 0
    private var accHigh: Double = 0
    private var n = 0
    private var blockLength = 0
    private var blockStart: Double = 0
    private var expectedNext = Double.nan

    /// 采样率认不出（≤ 1 kHz / 非有限）时不出块
    mutating func configure(sampleRate sr: Double) {
        self = AudioBandSplitter()
        guard sr.isFinite, sr > 1000, sr < 1_000_000 else { return }
        sampleRate = sr
        aLow = 1 - exp(-2 * Double.pi * Self.lowCutHz / sr)
        aMid = 1 - exp(-2 * Double.pi * Self.midCutHz / sr)
        blockLength = max(1, Int((sr * Self.blockSeconds).rounded()))
    }

    mutating func clear() {
        let sr = sampleRate
        configure(sampleRate: sr)
    }

    /// 一次回调开始：start = 第一个样本的视频时间。和上一次接不上就丢掉没满的块（滤波状态也重来）
    mutating func begin(start: Double, frames: Int) {
        guard sampleRate > 0 else { return }
        if !start.isFinite || (expectedNext.isFinite && abs(start - expectedNext) > Self.maxSkew) {
            n = 0
            accLow = 0
            accMid = 0
            accHigh = 0
            sLow = 0
            sMid = 0
        }
        expectedNext = start.isFinite ? start + Double(max(0, frames)) / sampleRate : .nan
    }

    /// 一个样本（t = 它的视频时间）；满 10 毫秒返回一块
    mutating func add(_ x: Double, at t: Double) -> AudioBandFrame? {
        guard blockLength > 0 else { return nil }
        let v = x.isFinite ? max(-4, min(4, x)) : 0
        sLow += aLow * (v - sLow)
        sMid += aMid * (v - sMid)
        let low = sLow
        let mid = sMid - sLow
        let high = v - sMid
        if n == 0 { blockStart = t }
        accLow += low * low
        accMid += mid * mid
        accHigh += high * high
        n += 1
        guard n >= blockLength else { return nil }
        let inv = 1 / Double(n)
        let f = AudioBandFrame(time: blockStart + 0.5 * Double(blockLength) / sampleRate, low: Float(accLow * inv),
                               mid: Float(accMid * inv), high: Float(accHigh * inv))
        n = 0
        accLow = 0
        accMid = 0
        accHigh = 0
        return f.time.isFinite ? f : nil
    }
}

/// 撞击检测（主线程）：三频带对数能量的正向增量（加权和）= 撞击强度；高于最近 1 秒均值 + 1.5σ、且 ≥ 1.5、
/// 是局部峰、离上一次 ≥ 0.12 秒、声音不是静音 → 一次撞击。最近 4 秒撞击时刻的自相关给声音节奏（0.4~4 Hz）
struct AudioOnsetDetector {
    static let frameSeconds: Double = AudioBandSplitter.blockSeconds
    static let historyFrames = 400
    static let thresholdFrames = 100
    static let thresholdSigma: Double = 1.5
    static let minFlux: Double = 1.5
    static let refractory: Double = 0.12
    static let silence: Double = 1e-7
    static let onsetCapacity = 64
    static let weights: (low: Double, mid: Double, high: Double) = (1, 1, 0.5)
    static let maxFrameGap: Double = 0.1
    /// 声音节奏：比最高峰短的 lag 上有不低于它 85% 的局部峰就取短的（避免认成一半频率）
    static let harmonicShare: Double = 0.85

    private var flux = [Double](repeating: 0, count: AudioOnsetDetector.historyFrames)
    private var fluxTimes = [Double](repeating: 0, count: AudioOnsetDetector.historyFrames)
    private var count = 0
    private var head = 0
    private var prevLog: (Double, Double, Double)?
    private var lastTime = Double.nan
    /// 峰值判断要等下一块：上一块 / 上上块
    private var p1: (time: Double, flux: Double, threshold: Double, loud: Bool)?
    private var p2Flux: Double = 0
    private var onsetTimes = [Double](repeating: 0, count: AudioOnsetDetector.onsetCapacity)
    private var onsetCount = 0
    private var onsetHead = 0
    private var lastOnset = -Double.infinity

    mutating func reset() {
        self = AudioOnsetDetector()
    }

    mutating func add(_ f: AudioBandFrame) {
        guard f.time.isFinite else { return }
        if lastTime.isFinite, f.time <= lastTime || f.time - lastTime > Self.maxFrameGap { reset() }
        lastTime = f.time
        let l = (log(Double(max(0, f.low)) + 1e-10), log(Double(max(0, f.mid)) + 1e-10), log(Double(max(0, f.high)) + 1e-10))
        var v = 0.0
        if let p = prevLog {
            v = Self.weights.low * max(0, l.0 - p.0) + Self.weights.mid * max(0, l.1 - p.1)
                + Self.weights.high * max(0, l.2 - p.2)
        }
        prevLog = l
        if !v.isFinite { v = 0 }
        // 阈值：之前 1 秒（不含这一块）
        let cap = Self.historyFrames
        let m = min(count, Self.thresholdFrames)
        var sum = 0.0
        var sq = 0.0
        for k in 0..<m {
            let x = flux[(head + cap - 1 - k) % cap]
            sum += x
            sq += x * x
        }
        let mean = m > 0 ? sum / Double(m) : 0
        let sd = m > 1 ? max(0, sq / Double(m) - mean * mean).squareRoot() : 0
        let threshold = max(Self.minFlux, mean + Self.thresholdSigma * sd)
        let loud = Double(f.low) + Double(f.mid) + Double(f.high) >= Self.silence
        // 上一块是不是峰
        if let p = p1, p.loud, p.flux >= p.threshold, p.flux >= p2Flux, p.flux > v, p.time - lastOnset >= Self.refractory {
            onsetTimes[onsetHead] = p.time
            onsetHead = (onsetHead + 1) % Self.onsetCapacity
            onsetCount = min(Self.onsetCapacity, onsetCount + 1)
            lastOnset = p.time
        }
        p2Flux = p1?.flux ?? 0
        p1 = (f.time, v, threshold, loud)
        flux[head] = v
        fluxTimes[head] = f.time
        head = (head + 1) % cap
        count = min(cap, count + 1)
    }

    /// 最近的撞击时刻（视频时间，旧 → 新）
    func onsets(since t: Double) -> [Double] {
        var out: [Double] = []
        let cap = Self.onsetCapacity
        let start = (onsetHead + cap - onsetCount) % cap
        for k in 0..<onsetCount {
            let x = onsetTimes[(start + k) % cap]
            if x >= t { out.append(x) }
        }
        return out
    }

    /// 声音节奏：最近 4 秒的撞击时刻做成脉冲串（每次撞击一个 σ = 1.5 块的高斯，容得下 ±10 ms 的抖动），
    /// 归一化自相关在 0.4~4 Hz（25~250 块）里找局部峰，取最短的、不低于最高峰 85% 的那个（倍周期的相关一样高），抛物线细化。
    /// 用撞击时刻而不是原始强度：稳定的噪声 / 哼声（强度有周期性起伏但没有撞击）不会给出节奏
    func rhythm() -> (hz: Double, confidence: Double) {
        let cap = Self.historyFrames
        let n = count
        guard n >= 200, lastTime.isFinite else { return (0, 0) }
        let t0 = fluxTimes[(head + cap - n) % cap]
        let hits = onsets(since: t0)
        guard hits.count >= 3 else { return (0, 0) }
        var sig = [Double](repeating: 0, count: n)
        let sigma = 1.5
        for h in hits {
            let c = (h - t0) / Self.frameSeconds
            let lo = max(0, Int((c - 4 * sigma).rounded(.down)))
            let hi = min(n - 1, Int((c + 4 * sigma).rounded(.up)))
            guard lo <= hi else { continue }
            for k in lo...hi {
                let d = (Double(k) - c) / sigma
                sig[k] += exp(-0.5 * d * d)
            }
        }
        var mean = 0.0
        for v in sig { mean += v }
        mean /= Double(n)
        for k in 0..<n { sig[k] -= mean }
        var r0 = 0.0
        for v in sig { r0 += v * v }
        guard r0 > 1e-9 else { return (0, 0) }
        let minLag = Int((1 / RhythmFollower.hzRange.upperBound / Self.frameSeconds).rounded(.down))
        let maxLag = min(n / 2, Int((1 / RhythmFollower.hzRange.lowerBound / Self.frameSeconds).rounded(.up)))
        guard maxLag > minLag + 2 else { return (0, 0) }
        var corr = [Double](repeating: 0, count: maxLag + 2)
        for lag in max(1, minLag - 1)...(maxLag + 1) where lag < n {
            var s = 0.0
            for k in 0..<(n - lag) { s += sig[k] * sig[k + lag] }
            corr[lag] = s / r0 * Double(n) / Double(n - lag)
        }
        var bestLag = 0
        var best = 0.0
        for lag in minLag...maxLag where corr[lag] > best && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            best = corr[lag]
            bestLag = lag
        }
        guard bestLag > 0 else { return (0, 0) }
        for lag in minLag..<bestLag where corr[lag] >= Self.harmonicShare * best
            && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            bestLag = lag
            break
        }
        let a = corr[bestLag - 1]
        let b = corr[bestLag]
        let c = corr[bestLag + 1]
        let den = a - 2 * b + c
        let offset = den < -1e-12 ? min(0.5, max(-0.5, 0.5 * (a - c) / den)) : 0
        let lag = Double(bestLag) + offset
        return (1 / (lag * Self.frameSeconds), MotionStats.clamp01(b))
    }
}

/// 撞击声相位校正（主线程，每个完整拍一次）：声音节奏和画面频率差 ≤ 15%、最近 4 秒 ≥ 4 次撞击、
/// 撞击时刻的画面相位集中（R ≥ 0.6）→ 把撞击对齐到「最深点」（相位 0）：offset 每拍向 −(平均撞击相位) 收 30%；
/// 方向已判断时只做 ±60° 的细调，判断不了时可以整个翻过来（声音能分清往里往外）。
/// 条件不满足：保持 2 秒后按 2 秒时间常数回 0；相位锁放开 / 切镜 / seek 时立刻 0。只改指令相位，不改档位
struct AudioPhaseAnchor {
    static let agreeRatio: Double = 0.15
    static let minOnsets = 4
    static let windowSeconds: Double = 4
    static let minConcentration: Double = 0.6
    static let minRhythmConfidence: Double = 0.3
    static let gain: Double = 0.3
    static let knownLimit: Double = Double.pi / 3
    /// 自审 L2：方向没判断出来时也最多 ±90°（背景音乐碰巧同频时不会把脉动整个翻过来）
    static let unknownLimit: Double = Double.pi / 2
    static let holdSeconds: Double = 2
    static let decaySeconds: Double = 2
    /// 撞击对应的画面相位（最深点）
    static let impactPhase: Double = 0

    private(set) var offset: Double = 0
    private(set) var active = false
    private(set) var concentration: Double = 0
    private(set) var audioHz: Double = 0
    /// av-fusion F2：这一拍因为声画不耦合（像配乐 / 人声 / 还没证明同步）没有对齐
    private(set) var uncoupled = false
    private var lastGood = -Double.infinity

    mutating func reset() {
        self = AudioPhaseAnchor()
    }

    /// onsets：撞击时刻（host 时间）；返回这一拍的相位偏移（弧度）。
    /// coupled（av-fusion F2）：nil = 不看耦合（F2 关着，和以前逐位相同）；false = 声画还没证明耦合，这一拍不对齐（按条件不满足保持 / 回 0）
    @discardableResult
    mutating func step(onsets: [Double], audioHz hz: Double, audioConfidence: Double, lock: RhythmPhaseLock,
                       directionKnown: Bool, now: Double, dt: TimeInterval, coupled: Bool? = nil) -> Double {
        guard now.isFinite, lock.locked, lock.hz > 0, lock.phase(at: now) != nil else {
            reset()
            return 0
        }
        audioHz = hz.isFinite ? max(0, hz) : 0
        uncoupled = coupled == false
        let agree = audioHz > 0 && audioConfidence.isFinite && audioConfidence >= Self.minRhythmConfidence
            && abs(log(audioHz / lock.hz)) <= log(1 + Self.agreeRatio) && !uncoupled
        var good = false
        concentration = 0
        if agree {
            var sx = 0.0
            var sy = 0.0
            var n = 0
            for t in onsets where t.isFinite && t >= now - Self.windowSeconds && t <= now + 0.2 {
                guard let ph = lock.phase(at: t) else { continue }
                sx += cos(ph)
                sy += sin(ph)
                n += 1
            }
            if n >= Self.minOnsets {
                let r = (sx * sx + sy * sy).squareRoot() / Double(n)
                concentration = r.isFinite ? r : 0
                if concentration >= Self.minConcentration {
                    let mu = atan2(sy, sx)
                    var target = StrokeRhythm.wrapPhase(Self.impactPhase - mu)
                    let limit = directionKnown ? Self.knownLimit : Self.unknownLimit
                    target = min(limit, max(-limit, target))
                    offset = StrokeRhythm.wrapPhase(offset + Self.gain * StrokeRhythm.wrapPhase(target - offset))
                    offset = min(limit, max(-limit, offset))
                    lastGood = now
                    good = true
                }
            }
        }
        active = good
        if !good, now - lastGood > Self.holdSeconds {
            let step = dt.isFinite ? min(1, max(0, dt)) : AudioReactiveShaper.interval
            offset *= exp(-step / Self.decaySeconds)
            if abs(offset) < 1e-3 { offset = 0 }
        }
        if !offset.isFinite { offset = 0 }
        return offset
    }

    func statusText(lockHz: Double) -> String {
        if active {
            return String(format: "撞击声校正：声音 %.2f 次/秒和画面一致，已对齐（集中度 %.2f，偏移 %+d°）", audioHz,
                          concentration, Int((offset * 180 / Double.pi).rounded()))
        }
        if uncoupled {
            return offset != 0
                ? String(format: "撞击声校正：声画不耦合（像配乐 / 人声），保持偏移 %+d° 后慢慢回 0", Int((offset * 180 / Double.pi).rounded()))
                : "撞击声校正：声画不耦合（像配乐 / 人声），只按画面相位"
        }
        if offset != 0 {
            return String(format: "撞击声校正：暂时对不上，保持偏移 %+d° 后慢慢回 0", Int((offset * 180 / Double.pi).rounded()))
        }
        return "撞击声校正：没听到和画面一致的撞击声，只按画面相位"
    }
}

// MARK: - rhythm-lookahead P4：前瞻（另开一路解码提前读后面的画面，默认关）
//
// 视频是本地文件：VideoMotionTap.swift 的 LookaheadReader 用 AVAssetReader 从播放头附近往后读（最多领先 3 秒），
// 跑同一套 LumaDownscaler + MotionAnalyzer（块运动主体 / 节奏 / 相位拟合，不跑 Vision），按视频时间存成 LookaheadTimeline。
// 主线程每个完整拍：
// 1. 核对（RhythmLookahead.refine）：同一个视频时刻，前瞻的因果读数和实时窗口的读数比——频率差 ≤ 15% 算一致，
//    实时没有节奏而前瞻有把握有节奏、实时有把握有节奏而前瞻（攒满一个窗口的同一段里）没有节奏，都算不一致；
//    只看最近 8 次：一致 ≥ 3、不一致 ≤ 2、最近一次不是不一致、最近一次核对在 3 秒内才「核对通过」，
//    读帧那边重读（时间轴 origin 变了）时核对历史清掉；相位按 0° / 180° 折叠（两路主轴正方向可能取得不一样），
//    折叠后差 ≤ 45° 才认方向，连续 2 次一致才定 / 改方向；差在 45°~135° 的不认（时间轴对不上 / 不是同一个运动）；
// 2. 代入：核对通过后，交给 RhythmFollower / RhythmPhaseLock 的窗口副本里块运动主体的
//    - 跟随频率 = 「现在 + 延迟补偿 × 倍速」那一刻的居中读数（followEstimate 是因果的最近 4 秒，居中 = 往后看 2 秒那一帧的读数），
//    - 相位读数 = 现在这一刻的居中相位（相位拟合窗口中点落在现在附近的那些读数按拟合质量加权求圆平均，非因果平滑），
//      按核对出来的方向折到实时的约定上，时间戳记成现在；
//    P1 / P2 / P3 的锁定、门、滞回、上限都不变（锁不锁、用几成照旧由它们决定），只是读数没有检测延迟；
// 3. 提前量（RhythmLookahead.stepLead）：P2 的指令相位 = 相位锁(现在 + 延迟)，按「现在的频率」外推；
//    前瞻直接看到这段时间里画面实际走了多少相位，差值（有界 ±60°、每秒最多变 90°）加到脉动的指令相位偏移上。
// 默认关；没读到够远 / 核对没通过 / 对不上 / 切镜 / 保持期 / 倍速读不出 / 发热 / 解码跟不上 / 读不了这个文件时
// 窗口原样交回、提前量 0（= P4 关着时的行为，也就是 main 的 P1 / P2 / P3）。不改强度那条路，不改出口，不新增发送路径。

/// 前瞻分析的一帧（视频时间轴）
struct LookaheadRecord: Equatable {
    /// 视频时间（秒；和 AVPlayer.currentTime() 同一条轴）
    var time: Double
    /// 连续段：切镜 / 重新开读 / 断档 +1。不同段的读数不混用
    var segment: Int
    /// 块运动主体的 followEstimate（视频时间上的 Hz）；切镜 / 保持期 / 没有主体读数时 0
    var followHz: Double = 0
    var followRhythm: Double = 0
    var followAmplitude: Double = 0
    /// 这一帧的相位拟合（time = 视频时间，hz = 视频时间上的频率）；没有时无效
    var phase = StrokeRhythm.PhaseFit()
}

/// 居中（非因果）的相位读数
struct LookaheadPhase: Equatable {
    /// 视频时刻 time 的位移相位（前瞻分析器自己的主轴约定）
    var time: Double = 0
    var phase: Double = 0
    /// 视频时间上的频率
    var hz: Double = 0
    /// 加权平均拟合 R² × 一致性
    var quality: Double = 0
    var linearity: Double = 0
    var amplitude: Double = 0
    /// 各读数外推到 time 后的一致性（圆平均的合成长度 0~1）
    var coherence: Double = 0
    /// 用上的读数里离窗口中点最近的那个有多居中（0~1，1 = 拟合窗口正好以 time 为中点）
    var centering: Double = 0
    var count = 0
    var epoch = 0
    var segment = 0
    var axisX: Double = 0
    var axisY: Double = 0
}

/// 前瞻时间轴（读帧队列追加，主线程按视频时间查询；纯数据，VisualSyncChecks 直接喂）
struct LookaheadTimeline: Equatable {
    static let capacity = 200
    /// 播放头之前留这么久（核对用实时窗口里最旧的读数也够得着）
    static let keepBehind: Double = 5
    /// 相邻两帧隔这么久就算断档（新段）
    static let maxGap: Double = 0.5
    /// 查询时刻离最近一帧最多这么远
    static let nearest: Double = 0.2
    /// 居中相位：至少几个读数、一致性、居中程度
    static let phaseMinCount = 3
    static let phaseMinCoherence: Double = 0.7
    static let phaseMinCentering: Double = 0.5
    /// 居中频率：followEstimate 的窗口是因果的 StrokeRhythm.window 秒，居中要往后看一半
    static let followLead: Double = StrokeRhythm.window / 2
    /// 居中频率最少要往后看这么多才算（不然和实时一样是因果的，不用代入）
    static let followMinLead: Double = 0.5

    private(set) var records: [LookaheadRecord] = []
    private(set) var segment = 0
    /// 这一路从哪个视频时间开始读（restart 设；读帧那边判断要不要重读）
    private(set) var origin: Double = .nan

    init() {
        records.reserveCapacity(Self.capacity)
    }

    var head: Double { records.last?.time ?? -.infinity }
    var first: Double { records.first?.time ?? .infinity }
    var isEmpty: Bool { records.isEmpty }

    /// 重新开读（seek / 跳读 / 发热后恢复）：清空、新段
    mutating func restart(at v: Double) {
        records.removeAll(keepingCapacity: true)
        segment += 1
        origin = v
    }

    /// 读帧队列：一帧分析结果（s.time 是视频时间）。时间不前进的丢掉
    mutating func append(_ s: MotionSample) {
        guard s.time.isFinite else { return }
        if let last = records.last {
            guard s.time > last.time else { return }
            if s.time - last.time > Self.maxGap { segment += 1 }
        }
        if s.isCut { segment += 1 }
        var r = LookaheadRecord(time: s.time, segment: segment)
        if s.subject.valid, !s.isCut, !s.isHeld {
            let f = s.subject
            if f.followHz.isFinite, f.followHz > 0 {
                r.followHz = f.followHz
                r.followRhythm = f.followRhythm.isFinite ? min(1, max(0, f.followRhythm)) : 0
                r.followAmplitude = f.followAmplitude.isFinite ? max(0, f.followAmplitude) : 0
            }
            if f.phase.isValid { r.phase = f.phase }
        }
        if records.count >= Self.capacity { records.removeFirst(records.count - Self.capacity + 1) }
        records.append(r)
    }

    /// 播放头之前 keepBehind 秒以前的丢掉
    mutating func prune(playhead v: Double) {
        guard v.isFinite else { return }
        let limit = v - Self.keepBehind
        var k = 0
        while k < records.count, records[k].time < limit { k += 1 }
        if k > 0 { records.removeFirst(k) }
    }

    /// time ≤ v 的最后一帧
    func index(atOrBefore v: Double) -> Int? {
        guard v.isFinite, let f = records.first, f.time <= v else { return nil }
        var lo = 0
        var hi = records.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if records[mid].time <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// v 落在哪一段：v 之前 nearest 秒内有一帧（就是那一帧的段）；之后紧跟着的那帧必须同段或 v 贴着它
    func segment(at v: Double) -> Int? {
        guard let i = index(atOrBefore: v), v - records[i].time <= Self.nearest else { return nil }
        return records[i].segment
    }

    /// 从 v 起同一段一直读到了哪个视频时间（没有 = nil）
    func reach(from v: Double) -> Double? {
        guard let i = index(atOrBefore: v), v - records[i].time <= Self.nearest else { return nil }
        let seg = records[i].segment
        var j = i
        while j + 1 < records.count, records[j + 1].segment == seg { j += 1 }
        return records[j].time
    }

    /// 因果读数：v 时刻（之前 nearest 秒内）的最后一帧（核对用：和实时窗口同一个视频时刻的同一种读数比）
    func causal(at v: Double) -> LookaheadRecord? {
        guard let i = index(atOrBefore: v), v - records[i].time <= Self.nearest else { return nil }
        return records[i]
    }

    /// v 时刻（之前 nearest 秒内）那一帧所在的段已经连续读了多久（秒，视频时间；没有 = nil）
    func segmentAge(at v: Double) -> Double? {
        guard let i = index(atOrBefore: v), v - records[i].time <= Self.nearest else { return nil }
        var s = i
        while s > 0, records[s - 1].segment == records[i].segment { s -= 1 }
        return records[i].time - records[s].time
    }

    /// 居中的跟随频率：v 那一刻 = 同段里 v + followLead 那一帧的读数（读到的不够远时用同段最远的一帧，但至少往后看 followMinLead）。
    /// 那一帧没有频率时：段开头攒满一个窗口才算「没有节奏」（返回 hz 0），没攒满 nil。
    /// 返回 (hz（视频时间）, 置信度, 幅度, 往后看了多少秒)
    func centeredFollow(at v: Double) -> (hz: Double, rhythm: Double, amplitude: Double, lead: Double)? {
        guard let i = index(atOrBefore: v), v - records[i].time <= Self.nearest else { return nil }
        let seg = records[i].segment
        let target = v + Self.followLead
        var j = i
        while j + 1 < records.count, records[j + 1].segment == seg, records[j + 1].time <= target { j += 1 }
        let r = records[j]
        let lead = r.time - v
        guard lead >= Self.followMinLead else { return nil }
        // 这一帧还没有频率：段开头不满一个 StrokeRhythm 窗口时是「还没攒够」（不代入，实时照用），满了才是「真没有节奏」
        if !(r.followHz > 0) {
            var s = i
            while s > 0, records[s - 1].segment == seg { s -= 1 }
            guard r.time - records[s].time >= StrokeRhythm.window else { return nil }
        }
        return (r.followHz, r.followRhythm, r.followAmplitude, lead)
    }

    /// 居中的相位：同段、拟合窗口（因果的 2 个周期，夹在 1~3 秒）盖住 v 的那些读数，按「窗口中点离 v 多近 × 拟合 R²」加权，
    /// 各自外推回 v 再求圆平均。只用权重最大那个读数的主轴代次（代次不同可能差 180°，混在一起会互相抵消）。
    /// 读数不够 / 不一致 / 读到的还不够远（最居中的那个窗口中点离 v 超过四分之一个窗口）时 nil
    func centeredPhase(at v: Double) -> LookaheadPhase? {
        guard let i = index(atOrBefore: v), v - records[i].time <= Self.nearest else { return nil }
        let seg = records[i].segment
        let maxSpan = StrokeRhythm.phaseWindowRange.upperBound
        func weight(_ r: LookaheadRecord) -> (w: Double, c: Double)? {
            let p = r.phase
            guard p.isValid, r.time >= v, p.quality.isFinite, p.quality > 0 else { return nil }
            let span = min(StrokeRhythm.phaseWindowRange.upperBound,
                           max(StrokeRhythm.phaseWindowRange.lowerBound, StrokeRhythm.phaseWindowPeriods / p.hz))
            guard r.time - v <= span else { return nil }
            let c = 1 - abs((r.time - v) - span / 2) / (span / 2)
            guard c > 0 else { return nil }
            return (c * min(1, p.quality), c)
        }
        var best: (w: Double, k: Int)?
        var k = i
        while k < records.count, records[k].segment == seg, records[k].time - v <= maxSpan {
            if let wc = weight(records[k]), wc.w > (best?.w ?? 0) { best = (wc.w, k) }
            k += 1
        }
        guard let b = best else { return nil }
        let epoch = records[b.k].phase.epoch
        var sw = 0.0, sc = 0.0, ss = 0.0, shz = 0.0, sq = 0.0, sl = 0.0, sa = 0.0
        var count = 0
        var centering = 0.0
        k = i
        while k < records.count, records[k].segment == seg, records[k].time - v <= maxSpan {
            let r = records[k]
            k += 1
            guard r.phase.epoch == epoch, let wc = weight(r) else { continue }
            let p = r.phase
            let predicted = p.phase - 2 * Double.pi * p.hz * (r.time - v)
            guard predicted.isFinite else { continue }
            sw += wc.w
            sc += wc.w * cos(predicted)
            ss += wc.w * sin(predicted)
            shz += wc.w * p.hz
            sq += wc.w * min(1, p.quality)
            sl += wc.w * (p.linearity.isFinite ? p.linearity : 0)
            sa += wc.w * (p.amplitude.isFinite ? p.amplitude : 0)
            count += 1
            centering = max(centering, wc.c)
        }
        guard count >= Self.phaseMinCount, sw > 0 else { return nil }
        let coherence = sqrt(sc * sc + ss * ss) / sw
        guard coherence.isFinite, coherence >= Self.phaseMinCoherence, centering >= Self.phaseMinCentering else { return nil }
        let a = records[b.k].phase
        return LookaheadPhase(time: v, phase: StrokeRhythm.wrapPhase(atan2(ss, sc)), hz: shz / sw,
                              quality: sq / sw * coherence, linearity: sl / sw, amplitude: sa / sw,
                              coherence: coherence, centering: centering, count: count, epoch: epoch, segment: seg,
                              axisX: a.axisX, axisY: a.axisY)
    }

    /// 视频时间 v0 → v1 之间画面实际走了多少相位（弧度；同段、同代次的两个居中相位，按平均频率解开整圈）
    func phaseAdvance(from v0: Double, to v1: Double) -> Double? {
        guard v1 >= v0, let a = centeredPhase(at: v0), let b = centeredPhase(at: v1),
              a.segment == b.segment, a.epoch == b.epoch else { return nil }
        let hz = (a.hz + b.hz) / 2
        let expected = 2 * Double.pi * hz * (v1 - v0)
        let dev = StrokeRhythm.wrapPhase(b.phase - a.phase - expected)
        let adv = expected + dev
        return adv.isFinite ? adv : nil
    }
}

/// 前瞻的主线程状态（rhythm-lookahead P4，每个完整拍一次；纯状态，VisualSyncChecks 覆盖）：
/// 核对两条时间轴是不是同一个画面 → 把交给频率跟随器 / 相位锁的窗口副本换成没有检测延迟的读数 → 算脉动的提前量
struct RhythmLookahead {
    static let agreeRatio: Double = 0.15
    /// 频率核对只看最近 historyLength 次（复审 M2：不按开播以来的累计次数，前面对上过不代表现在还对得上）
    static let historyLength = 8
    /// 「核对通过」：最近 8 次里一致 ≥ 3 次、不一致 ≤ 2 次，且最近一次不是不一致
    static let verifyAgreements = 3
    static let verifyMaxDisagreements = 2
    static let mismatchDisagreements = 5
    /// 实时没有跟随频率、前瞻同一时刻却有置信度 ≥ 这个的频率：算一次不一致（= RhythmFollower 锁定的门）
    static let confidentRhythm: Double = RhythmFollower.lockConfidence
    /// 相位折叠后差 ≤ 45° 算同向 / 反向
    static let flipTolerance: Double = Double.pi / 4
    static let flipConfirm = 2
    /// 最近 6 次相位核对里 ≥ 4 次对不上（45°~135°）：方向作废，不代入相位
    static let phaseHistoryLength = 6
    static let phaseMisses = 4
    /// 方向核对多久没更新就作废（换了镜头 / 实时那边一直没有相位读数）
    static let flipStaleSeconds: Double = 3
    /// 频率核对多久没记过就作废（复审 R3-M1：最近一次核对太旧 = 现在没人在核对，不能再凭老结果代入）。
    /// 和方向作废同一个时长：约 10 个完整拍，够跨过切镜 / 保持期那几拍
    static let verifyStaleSeconds: Double = flipStaleSeconds
    /// 提前量上限 / 每秒最多变多少
    static let maxLead: Double = Double.pi / 3
    static let leadRatePerSecond: Double = Double.pi / 2
    /// 实时窗口里没有相位读数时，按「现在 − 这么久」当实时频率读数的时刻（窗口最后一帧大约这么旧）
    static let windowAge: Double = 0.1

    enum State: Equatable {
        /// 关着（播放器不调用）
        case off
        /// 前瞻还没读到够远 / 这一拍不能用（切镜、保持期、倍速读不出）
        case waiting
        /// 读到了，正在和实时画面核对
        case checking
        /// 和实时画面对不上：只用实时
        case mismatch
        /// 只代入了频率（相位方向还没核对上 / 读数不够）
        case frequencyOnly
        /// 频率和相位都按前瞻
        case engaged
    }

    /// 播放器这一拍的时钟：host 时间 hostNow 时播放头在 itemNow（视频秒），倍速 rate
    struct Clock: Equatable {
        var hostNow: Double
        var itemNow: Double
        var rate: Double

        var isValid: Bool { hostNow.isFinite && itemNow.isFinite && rate.isFinite && rate > 0.01 }
        /// host 时刻 → 视频时刻
        func video(_ host: Double) -> Double { itemNow + (host - hostNow) * rate }
    }

    private(set) var state = State.off
    /// 最近 historyLength 次频率核对（true = 一致），新的在低位
    private var history: UInt32 = 0
    private var historyCount = 0
    /// 最近一次记下频率核对的 host 时间 / 最近一次 refine 的 host 时间（复审 R3-M1：核对太旧就不算通过）
    private var lastCheckAt = -Double.infinity
    private var hostNow = -Double.infinity
    /// 上一次核对用的时间轴是从哪开读的（LookaheadTimeline.origin 的位模式）：变了 = 读帧那边重读过（seek / 发热或后台恢复 /
    /// 跟不上后重来），核对历史作废（复审 M2）
    private var timelineOrigin: UInt64?
    /// 相位核对：最近几次（true = 对不上）
    private var phaseHistory: UInt32 = 0
    private var phaseHistoryCount = 0
    /// 前瞻主轴相对实时主轴：false = 同向、true = 反向、nil = 还不知道
    private(set) var flip: Bool?
    private var flipEpoch = 0
    private var flipSegment = 0
    private var flipAt = -Double.infinity
    private var flipCand: Bool?
    private var flipCandCount = 0
    private var flipCandEpoch = 0
    private var flipCandSegment = 0
    /// 脉动指令相位的提前量（弧度，加到 RhythmPulseDriver.phaseOffset 上）
    private(set) var lead: Double = 0
    private(set) var leadTarget: Double = 0
    private(set) var frequencyEngaged = false
    private(set) var phaseEngaged = false
    /// 读到了播放头之后多远（秒，视频时间；状态行用）
    private(set) var ahead: Double = 0

    /// 核对通过（只看最近 historyLength 次）：一致 ≥ 3、不一致 ≤ 2，且最近一次不是不一致；
    /// 最近一次核对离最近一次 refine 不超过 verifyStaleSeconds（复审 R3-M1：老结果不续命）
    var verified: Bool {
        historyCount > 0 && history & 1 == 1
            && agreements >= Self.verifyAgreements && disagreements <= Self.verifyMaxDisagreements
            && hostNow - lastCheckAt <= Self.verifyStaleSeconds
    }

    var mismatched: Bool {
        historyCount >= Self.mismatchDisagreements && disagreements >= Self.mismatchDisagreements
    }

    /// 最近 historyLength 次核对里一致 / 不一致的次数
    var agreements: Int { historyCount - disagreements }

    var disagreements: Int {
        var n = 0
        for b in 0..<min(historyCount, Self.historyLength) where history & (1 << UInt32(b)) == 0 { n += 1 }
        return n
    }

    private var phaseMissCount: Int {
        var n = 0
        for b in 0..<min(phaseHistoryCount, Self.phaseHistoryLength) where phaseHistory & (1 << UInt32(b)) != 0 { n += 1 }
        return n
    }

    /// seek / 切镜 / 关开关 / 缓冲：方向、提前量从头来；核对历史保留（同一路连续读的时间轴，两条时间轴的对应关系不变）。
    /// 读帧那边重新开读时（时间轴 origin 变了）refine 会把核对历史清掉
    mutating func reset() {
        flip = nil
        flipCand = nil
        flipCandCount = 0
        flipAt = -.infinity
        phaseHistory = 0
        phaseHistoryCount = 0
        lead = 0
        leadTarget = 0
        frequencyEngaged = false
        phaseEngaged = false
        ahead = 0
        state = .off
    }

    /// 换视频 / 拆取帧：全清
    mutating func resetVideo() {
        self = RhythmLookahead()
    }

    private mutating func noteAgreement(_ agree: Bool, at now: Double) {
        history = ((history << 1) | (agree ? 1 : 0)) & ((1 << UInt32(Self.historyLength)) - 1)
        historyCount = min(Self.historyLength, historyCount + 1)
        lastCheckAt = now
    }

    /// 读帧那边重读了：频率核对历史清掉，要重新对上才用（方向另由 epoch / segment 管）
    private mutating func clearHistory() {
        history = 0
        historyCount = 0
        lastCheckAt = -.infinity
    }

    private mutating func notePhaseMiss(_ miss: Bool) {
        phaseHistory = ((phaseHistory << 1) | (miss ? 1 : 0)) & ((1 << UInt32(Self.phaseHistoryLength)) - 1)
        phaseHistoryCount = min(Self.phaseHistoryLength, phaseHistoryCount + 1)
    }

    /// 前瞻这一帧有把握有节奏（频率 > 0、置信度 ≥ confidentRhythm）
    static func confident(_ r: LookaheadRecord) -> Bool {
        r.followHz.isFinite && r.followHz > 0 && r.followRhythm.isFinite && r.followRhythm >= confidentRhythm
    }

    static func agree(_ a: Double, _ b: Double) -> Bool {
        guard a.isFinite, b.isFinite, a > 0, b > 0 else { return false }
        return abs(log(a / b)) <= log(1 + agreeRatio)
    }

    /// 每个完整拍一次：核对 + 代入。w：实时窗口（P3 动作识别之前的原窗口）；latency：延迟补偿（秒，host 时间）。
    /// 返回交给频率跟随器 / 相位锁（以及之后 P3 动作识别）的窗口；不能用时原样返回
    mutating func refine(_ w: MotionWindow, timeline: LookaheadTimeline, clock: Clock, latency: TimeInterval) -> MotionWindow {
        frequencyEngaged = false
        phaseEngaged = false
        // 读帧那边重新开读过（origin 变了）：之前的核对是另一路读出来的，作废（复审 M2）
        let origin = timeline.origin.bitPattern
        if let seen = timelineOrigin, seen != origin { clearHistory() }
        timelineOrigin = origin
        if clock.hostNow.isFinite { hostNow = clock.hostNow }
        guard clock.isValid else {
            state = .waiting
            return w
        }
        let vNow = clock.itemNow
        let reach = timeline.reach(from: vNow)
        ahead = reach.map { max(0, $0 - vNow) } ?? 0
        if w.cutCount > 0 {
            // 切镜：两路的主轴都重取，方向从头核对；这一拍原样（跟随器 / 相位锁自己会放开）
            flip = nil
            flipCand = nil
            flipCandCount = 0
            state = .waiting
            return w
        }
        check(w, timeline: timeline, clock: clock)
        guard reach != nil else {
            state = .waiting
            return w
        }
        if mismatched {
            state = .mismatch
            return w
        }
        guard verified else {
            state = .checking
            return w
        }
        // 保持期（切镜后头两帧）/ 没有主体读数：原样
        guard w.subjectFrames > 0, w.heldCount == 0, w.frames > 0 else {
            state = .waiting
            return w
        }
        var out = w
        let lat = latency.isFinite ? max(0, latency) : 0
        let vf = vNow + lat * clock.rate
        if let seg = timeline.segment(at: vNow), timeline.segment(at: vf) == seg,
           let f = timeline.centeredFollow(at: vf), f.hz.isFinite {
            out.subjectFollowHz = f.hz > 0 ? f.hz * clock.rate : 0
            out.subjectFollowRhythm = f.hz > 0 ? f.rhythm : 0
            out.subjectFollowAmplitude = f.hz > 0 ? f.amplitude : 0
            frequencyEngaged = true
        }
        if let fl = flip, clock.hostNow - flipAt <= Self.flipStaleSeconds, phaseMissCount < Self.phaseMisses,
           let c = timeline.centeredPhase(at: vNow), c.epoch == flipEpoch, c.segment == flipSegment {
            var fit = StrokeRhythm.PhaseFit()
            fit.time = clock.hostNow
            fit.phase = StrokeRhythm.wrapPhase(c.phase + (fl ? Double.pi : 0))
            fit.hz = c.hz * clock.rate
            fit.quality = c.quality
            fit.linearity = c.linearity
            fit.amplitude = c.amplitude
            if w.subjectPhase.isValid {
                fit.epoch = w.subjectPhase.epoch
                fit.axisX = w.subjectPhase.axisX
                fit.axisY = w.subjectPhase.axisY
            } else {
                fit.epoch = c.epoch
                fit.axisX = fl ? -c.axisX : c.axisX
                fit.axisY = fl ? -c.axisY : c.axisY
            }
            if fit.isValid {
                out.subjectPhase = fit
                phaseEngaged = true
            }
        }
        state = phaseEngaged ? .engaged : (frequencyEngaged ? .frequencyOnly : .waiting)
        return out
    }

    /// 核对：实时窗口最后的读数 ↔ 同一个视频时刻前瞻的因果读数
    private mutating func check(_ w: MotionWindow, timeline: LookaheadTimeline, clock: Clock) {
        guard w.subjectFrames > 0, w.heldCount == 0, w.subjectFollowHz.isFinite else { return }
        let tRt = w.subjectPhase.isValid ? w.subjectPhase.time : clock.hostNow - Self.windowAge
        let vRt = clock.video(tRt)
        guard let rec = timeline.causal(at: vRt) else { return }
        guard rec.followHz > 0 else {
            // 复审 R3-M1：反过来——实时有把握有节奏，前瞻在那一刻和「现在」都没有节奏、同一段、而且这段已经攒满一个
            // StrokeRhythm 窗口（不是段开头还没攒够）= 不一致。不记的话核对一直停在以前的「通过」，前瞻会拿「没节奏」顶掉实时的节奏。
            // 节奏在这一拍才开始时前瞻「现在」那帧已经有频率，不误记
            if w.subjectFollowHz > 0, w.subjectFollowRhythm.isFinite, w.subjectFollowRhythm >= Self.confidentRhythm,
               let age = timeline.segmentAge(at: vRt), age >= StrokeRhythm.window,
               let cur = timeline.causal(at: clock.itemNow), cur.segment == rec.segment, !(cur.followHz > 0) {
                noteAgreement(false, at: clock.hostNow)
            }
            return
        }
        guard w.subjectFollowHz > 0 else {
            // 复审 M2：实时这一刻没有节奏，前瞻（同样是因果读数）却有把握有节奏 = 不一致。
            // 窗口的跟随频率是最后一帧的、相位时间可能是更早一帧的：前瞻在那一刻和「现在」（不早于实时最后一帧）都有把握、
            // 同一段才算，节奏真的在这一拍停了时两边一起停，不误记。前瞻自己也没把握时不算（两边都在攒 / 都快没了）。
            // 小幅 seek 没重读时实时刚清空、前瞻还连着，这几拍也会记成不一致，只会让前瞻晚一点用上（安全方向）
            if Self.confident(rec), let cur = timeline.causal(at: clock.itemNow), cur.segment == rec.segment,
               Self.confident(cur) {
                noteAgreement(false, at: clock.hostNow)
            }
            return
        }
        noteAgreement(Self.agree(rec.followHz * clock.rate, w.subjectFollowHz), at: clock.hostNow)
        // 相位：两边都有拟合、频率对得上才比；按 0° / 180° 折叠
        let rp = w.subjectPhase
        guard rp.isValid, rec.phase.isValid, Self.agree(rec.phase.hz * clock.rate, rp.hz) else { return }
        let predicted = rec.phase.phase + 2 * Double.pi * rec.phase.hz * (vRt - rec.time)
        let d = abs(StrokeRhythm.wrapPhase(rp.phase - predicted))
        let obs: Bool?
        if d <= Self.flipTolerance {
            obs = false
        } else if d >= Double.pi - Self.flipTolerance {
            obs = true
        } else {
            obs = nil
        }
        notePhaseMiss(obs == nil)
        guard let o = obs else {
            flipCandCount = 0
            flipCand = nil
            return
        }
        let epoch = rec.phase.epoch
        let seg = rec.segment
        if flipCand == o, flipCandEpoch == epoch, flipCandSegment == seg {
            flipCandCount += 1
        } else {
            flipCand = o
            flipCandCount = 1
            flipCandEpoch = epoch
            flipCandSegment = seg
        }
        if flip == o, flipEpoch == epoch, flipSegment == seg {
            flipAt = clock.hostNow
        } else if flipCandCount >= Self.flipConfirm {
            flip = o
            flipEpoch = epoch
            flipSegment = seg
            flipAt = clock.hostNow
        }
    }

    /// 每个完整拍一次（refine 之后、相位锁 step 之后）：前瞻里「现在 → 现在 + 延迟」画面实际走的相位，减去相位锁按现在的频率外推的，
    /// 有界 ±60°，每秒最多变 90°；没代入相位 / 相位锁没在用 / 延迟 0 时回 0（相位锁不用时立刻 0）
    mutating func stepLead(timeline: LookaheadTimeline, clock: Clock, latency: TimeInterval, lockOmega: Double,
                           lockWeight: Double, dt: TimeInterval) -> Double {
        guard lockWeight > 0, lockWeight.isFinite else {
            lead = 0
            leadTarget = 0
            return 0
        }
        var target = 0.0
        let lat = latency.isFinite ? max(0, latency) : 0
        if phaseEngaged, clock.isValid, lat > 0, lockOmega.isFinite, lockOmega > 0,
           let adv = timeline.phaseAdvance(from: clock.itemNow, to: clock.itemNow + lat * clock.rate) {
            let dev = StrokeRhythm.wrapPhase(adv - lockOmega * lat)
            target = min(Self.maxLead, max(-Self.maxLead, dev))
        }
        leadTarget = target
        let step = (dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval) * Self.leadRatePerSecond
        if lead < target {
            lead = min(target, lead + step)
        } else if lead > target {
            lead = max(target, lead - step)
        }
        if !lead.isFinite { lead = 0 }
        return lead
    }

    /// 两者相加后的总偏移上限：撞击声校正自己最宽就是 ±90°（AudioPhaseAnchor.unknownLimit），前瞻不把总偏移推到更宽
    static let maxTotalOffset: Double = AudioPhaseAnchor.unknownLimit

    /// 脉动相位偏移 = 撞击声校正 + 前瞻提前量（总和夹在 ±90°）；提前量 0 时就是撞击声校正本身（逐位相同，不夹）
    static func phaseOffset(anchor: Double, lead: Double) -> Double {
        guard lead != 0 else { return anchor }
        let sum = anchor + lead
        guard sum.isFinite else { return anchor.isFinite ? anchor : 0 }
        return min(maxTotalOffset, max(-maxTotalOffset, sum))
    }

    /// 界面上的一行。reader：读帧那边的情况（nil = 正常在读）
    func statusText(reader: String?) -> String {
        if let r = reader { return "前瞻：\(r)，只用实时画面" }
        let a = String(format: "%.1f", ahead)
        switch state {
        case .off, .waiting:
            return ahead > 0.05 ? "前瞻：已读到后面 \(a) 秒，等够长的画面再用" : "前瞻：正在提前读后面的画面…"
        case .checking:
            return "前瞻：已读到后面 \(a) 秒，正在和实时画面核对"
        case .mismatch:
            return "前瞻：和实时画面对不上，只用实时画面"
        case .frequencyOnly:
            return "前瞻：已读到后面 \(a) 秒，频率按将来的画面；相位还在核对方向，按实时"
        case .engaged:
            let deg = Int((lead * 180 / Double.pi).rounded())
            return "前瞻：已读到后面 \(a) 秒，频率和相位都按将来的画面" + (deg != 0 ? String(format: "（提前修正 %+d°）", deg) : "")
        }
    }
}

extension LookaheadTimeline {
    /// 读帧那边（rhythm-lookahead P4）：前瞻最多领先播放头这么久（视频秒）。
    /// 至少要盖住 居中频率往后看的 2 秒 + 延迟补偿（≤ 0.6 秒）
    static let horizon: Double = 3
    /// 播放头比还留着的最早一帧（没有帧时是开读处）早这么多（往回 seek / 播完重播）就从播放头重新开读
    static let restartBehind: Double = 0.25
    /// 播放头比读到的最远处还靠后这么多（往前 seek / 解码跟不上）就从播放头重新开读
    static let restartAhead: Double = 1

    /// 播放头 v 不在这一路能接着读的范围里：要从 v 重新开读（还没开读过也算）。
    /// 往回比的是还留着的最早一帧（复审 M1）：prune 只留播放头前 5 秒，往回 seek 到开读处之后、最早一帧之前
    /// （含播完后从 0 重播：读帧那边已读到文件尾）也要重读，不然这段一直没有前瞻
    func needsRestart(playhead v: Double) -> Bool {
        guard v.isFinite else { return false }
        guard origin.isFinite else { return true }
        let low = records.first.map { max(origin, $0.time) } ?? origin
        if v < low - Self.restartBehind { return true }
        let reached = records.isEmpty ? origin : max(origin, head)
        return v > reached + Self.restartAhead
    }

    /// 还要不要往后读（读到的还没到 v + horizon）
    func wantsMore(playhead v: Double) -> Bool {
        guard v.isFinite else { return false }
        let reached = records.isEmpty ? (origin.isFinite ? origin : -.infinity) : head
        return reached < v + Self.horizon
    }
}

/// rhythm-lookahead P4：另开一路解码（前瞻 / 预扫描）的发热规则。
/// 只在 .nominal / .fair 跑；.serious 起整个停掉（画面分析本身那时也降频，P3 的手 / 脸 Vision 只在 .nominal）。
/// 这一路不跑任何 Vision 请求
enum LookaheadThermalPolicy {
    static func allowsExtraDecode(_ state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .nominal, .fair: return true
        case .serious, .critical: return false
        @unknown default: return false
        }
    }

    /// 停掉时的说明（状态行用）；能跑时 nil
    static func note(_ state: ProcessInfo.ThermalState) -> String? {
        allowsExtraDecode(state) ? nil : "手机发热，已暂停提前读视频"
    }
}

/// rhythm-lookahead P4：预扫描（选视频后在后台把整段视频按 15 Hz 分析一遍，默认关）。
/// 按 0.3 秒视频时间攒成和实时同样的窗口，记下 MotionNormalizer 会拿来学参考值的那些量（同样的门：
/// 过了噪声门、没有切镜 / 保持期、近场 < 0.5），最后给 10 / 90 分位。纯数据，VisualSyncChecks 直接喂。
/// 只用来给 MotionNormalizer.seed 当起点；播放时以实时分析为准
struct MotionPrescan {
    /// 和实时一样每 0.3 秒一个窗口
    static let windowSeconds: Double = AudioReactiveShaper.interval
    /// 至少这么多个可学的窗口（约 9 秒）才给分位数
    static let minWindows = 30
    /// 最多记这么多个窗口（约 2 小时；更长的视频只看前 2 小时）
    static let maxWindows = 24_000
    static let lowQuantile: Double = 0.1
    static let highQuantile: Double = 0.9

    struct Summary: Equatable {
        var refLow: Double = .nan
        var refHigh: Double = .nan
        var scoreLow: Double = .nan
        var scoreHigh: Double = .nan
        var energyWindows = 0
        var scoreWindows = 0
        /// 扫到了哪个视频时间（秒）
        var scanned: Double = 0

        var isValid: Bool { energyWindows >= MotionPrescan.minWindows || scoreWindows >= MotionPrescan.minWindows }
    }

    private var accumulator = MotionWindowAccumulator()
    private var windowStart: Double = .nan
    private(set) var windows = 0
    private(set) var energy: [Float] = []
    private(set) var score: [Float] = []
    private(set) var scanned: Double = 0

    /// 一帧分析结果（s.time 是视频时间）。时间倒退的（重读 / 坏时间戳）丢掉
    mutating func add(_ s: MotionSample) {
        guard s.time.isFinite, s.time >= scanned || windowStart.isNaN else { return }
        if windowStart.isNaN { windowStart = s.time }
        while s.time >= windowStart + Self.windowSeconds {
            closeWindow()
            windowStart += Self.windowSeconds
            if s.time >= windowStart + 10 * Self.windowSeconds { windowStart = s.time }
        }
        accumulator.add(s)
        scanned = max(scanned, s.time)
    }

    /// 扫完：最后半截窗口也算
    mutating func finish() {
        closeWindow()
    }

    private mutating func closeWindow() {
        let w = accumulator.drain()
        guard w.frames > 0, windows < Self.maxWindows else { return }
        windows += 1
        let near = w.nearField.isFinite ? min(1, max(0, w.nearField)) : 0
        guard w.settled, near < MotionNormalizer.nearFieldLearnLimit else { return }
        let e = w.representative
        if e.isFinite, e >= MotionNormalizer.absoluteGate {
            let l = log(1 + e)
            if l.isFinite { energy.append(Float(l)) }
        }
        if w.subjectFrames > 0 {
            var sc = MotionStats.clamp01(w.subjectScore)
            if near > 0 { sc -= near * max(0, sc - MotionNormalizer.subjectNearFloor) }
            score.append(Float(MotionStats.clamp01(sc)))
        }
    }

    static func quantile(_ sorted: [Float], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let k = min(sorted.count - 1, max(0, Int((q * Double(sorted.count - 1)).rounded())))
        return Double(sorted[k])
    }

    var summary: Summary {
        var s = Summary()
        s.scanned = scanned
        s.energyWindows = energy.count
        s.scoreWindows = score.count
        if energy.count >= Self.minWindows {
            let e = energy.sorted()
            s.refLow = Self.quantile(e, Self.lowQuantile)
            s.refHigh = Self.quantile(e, Self.highQuantile)
        }
        if score.count >= Self.minWindows {
            let c = score.sorted()
            s.scoreLow = Self.quantile(c, Self.lowQuantile)
            s.scoreHigh = Self.quantile(c, Self.highQuantile)
        }
        return s
    }
}

/// rhythm-lookahead P4 的播放器接线（纯状态；VideoSyncPlayer 和 VisualSyncChecks 用同一份）：
/// enabled == false 时每个函数都把输入原样交回（窗口 ==、相位偏移逐位相同），状态清掉，
/// 所以开关关着 / 没标定 / 读帧那边停了时整条链就是 P4 之前的行为
struct LookaheadCoordinator {
    private(set) var lookahead = RhythmLookahead()
    /// 上一拍加过提前量：当时的撞击声部分和加完的总值（下一拍先撤掉再算撞击声校正）
    private var appliedAnchor: Double = 0
    private var appliedTotal: Double = 0
    private var hasApplied = false

    var lead: Double { lookahead.lead }

    mutating func reset() {
        lookahead.reset()
        hasApplied = false
    }

    mutating func resetVideo() {
        lookahead.resetVideo()
        hasApplied = false
    }

    /// 每个完整拍、交给频率跟随器 / 相位锁（以及 P3 动作识别）之前
    mutating func refine(_ w: MotionWindow, enabled: Bool, timeline: LookaheadTimeline,
                         clock: RhythmLookahead.Clock, latency: TimeInterval) -> MotionWindow {
        guard enabled else {
            if lookahead.state != .off || hasApplied { reset() }
            return w
        }
        return lookahead.refine(w, timeline: timeline, clock: clock, latency: latency)
    }

    /// 撞击声校正算之前：把上一拍加上去的提前量撤掉（没加过 / 偏移已经被别处改过时原样返回）。
    /// 防御性的：现在播放器里 updateAudioAnchor 每个完整拍都会整个改写 phaseOffset（关着 / 读不出倍速时写 0，开着写校正值），
    /// 撤不撤结果一样；留着是为了以后撞击声校正改成在原偏移上累加时，提前量也不会一拍拍叠上去
    mutating func removeLead(from offset: Double) -> Double {
        guard hasApplied else { return offset }
        hasApplied = false
        return offset.bitPattern == appliedTotal.bitPattern ? appliedAnchor : offset
    }

    /// 撞击声校正算完、相位锁 step 之后：加上这一拍的提前量（总和有界）；没开时原样返回
    mutating func applyLead(to anchor: Double, enabled: Bool, timeline: LookaheadTimeline,
                            clock: RhythmLookahead.Clock, latency: TimeInterval, lock: RhythmPhaseLock,
                            dt: TimeInterval) -> Double {
        guard enabled else {
            hasApplied = false
            return anchor
        }
        let lead = lookahead.stepLead(timeline: timeline, clock: clock, latency: latency, lockOmega: lock.omega,
                                      lockWeight: lock.weight, dt: dt)
        let total = RhythmLookahead.phaseOffset(anchor: anchor, lead: lead)
        if lead != 0 {
            appliedAnchor = anchor
            appliedTotal = total
            hasApplied = true
        } else {
            hasApplied = false
        }
        return total
    }

    func statusText(reader: String?) -> String { lookahead.statusText(reader: reader) }
}

// MARK: - av-fusion
// 声画融合（F0 观测与标定）：只观测、不参与控制。所有类型都是纯状态，VideoSyncPlayer 和 VisualSyncChecks 用同一份。
// F0 不加开关：跟着已有的「调试记录」（bcMotionDebugLog）走——关着时实时线程只多看一个布尔，不多读一个样本

/// av-fusion F0：音频 tap 一次回调的时间记录（实时线程写）。
/// host：回调时的 host 时间（CACurrentMediaTime，秒）；itemStart：这段第一个样本的视频时间（拿不到 NaN）
struct AudioTapTiming: Equatable {
    var host: Double = .nan
    var itemStart: Double = .nan
    var frames: Int = 0

    var valid: Bool { host.isFinite && itemStart.isFinite && frames > 0 }
}

/// av-fusion F0：tap 回调时间的环形缓冲（固定容量，init 时一次分配，record 不分配）。
/// 自己不加锁：调用方（AudioLevelMeter）在已有的 os_unfair_lock 里读写。enabled == false 时 record 什么都不写
final class AudioTapTimingRing {
    static let capacity = 64
    private let buffer: UnsafeMutablePointer<AudioTapTiming>
    private var head = 0
    private(set) var count = 0
    private(set) var enabled = false
    /// 上次 drain 以来时间范围有效 / 无效的回调数（满了丢最旧的记录，计数照记）
    private(set) var validCount = 0
    private(set) var invalidCount = 0

    init() {
        buffer = UnsafeMutablePointer<AudioTapTiming>.allocate(capacity: Self.capacity)
        buffer.initialize(repeating: AudioTapTiming(), count: Self.capacity)
    }

    deinit {
        buffer.deinitialize(count: Self.capacity)
        buffer.deallocate()
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        clear()
    }

    func clear() {
        head = 0
        count = 0
        validCount = 0
        invalidCount = 0
    }

    /// 实时线程：写一条（满了覆盖最旧的）
    func record(_ t: AudioTapTiming) {
        guard enabled else { return }
        buffer[head] = t
        head = (head + 1) % Self.capacity
        count = min(Self.capacity, count + 1)
        if t.valid { validCount += 1 } else { invalidCount += 1 }
    }

    /// 主线程：取走全部记录（旧 → 新）和计数，清零
    func drain() -> (timings: [AudioTapTiming], valid: Int, invalid: Int) {
        var out: [AudioTapTiming] = []
        out.reserveCapacity(count)
        let start = (head + Self.capacity - count) % Self.capacity
        for k in 0..<count { out.append(buffer[(start + k) % Self.capacity]) }
        let r = (out, validCount, invalidCount)
        clear()
        return r
    }
}

/// av-fusion F0：同一时刻读到的播放器时钟（host 时间、视频时间、倍速）。视频时间 ↔ host 时间互换（倍速不变的那一小段内）
struct MediaClockSnapshot: Equatable {
    var host: Double = .nan
    var item: Double = .nan
    var rate: Double = .nan

    var isValid: Bool { host.isFinite && item.isFinite && rate.isFinite && rate > 0.01 }

    /// 视频时间 → 这一刻应该被看到 / 听到的 host 时间（无效 NaN）
    func host(forItem t: Double) -> Double {
        guard isValid, t.isFinite else { return .nan }
        return host + (t - item) / rate
    }

    /// host 时间 → 视频时间（无效 NaN）
    func item(forHost h: Double) -> Double {
        guard isValid, h.isFinite else { return .nan }
        return item + (h - host) * rate
    }
}

/// av-fusion F0：tap 提前量 = 这段声音按播放器时钟该放出来的 host 时刻 − tap 处理它的 host 时刻（正 = tap 先于出声）。
/// 最近 sampleCapacity 个的中位数；离谱的（> maxAbsLead，seek / 时钟跳）丢掉。只用于调试记录和 F1 的时间可用判断
struct AudioTapLeadEstimator {
    static let sampleCapacity = 32
    static let maxAbsLead: Double = 2
    private(set) var samples: [Double] = []
    private var next = 0

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        next = 0
    }

    mutating func add(_ timings: [AudioTapTiming], clock: MediaClockSnapshot) {
        guard clock.isValid else { return }
        for t in timings where t.valid {
            let lead = clock.host(forItem: t.itemStart) - t.host
            guard lead.isFinite, abs(lead) <= Self.maxAbsLead else { continue }
            if samples.count < Self.sampleCapacity {
                samples.append(lead)
            } else {
                samples[next] = lead
                next = (next + 1) % Self.sampleCapacity
            }
        }
    }

    /// 中位数（秒；没有样本 NaN）
    var lead: Double {
        guard !samples.isEmpty else { return .nan }
        let s = samples.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : 0.5 * (s[m - 1] + s[m])
    }
}

/// av-fusion F0：一拍内取走的三频带块的汇总（调试记录用；均值能量换成 dB，没有块时 NaN）
struct AudioBandSummary: Equatable {
    private(set) var frames = 0
    private var low: Double = 0
    private var mid: Double = 0
    private var high: Double = 0

    mutating func add(_ bands: [AudioBandFrame]) {
        for b in bands {
            low += Double(max(0, b.low))
            mid += Double(max(0, b.mid))
            high += Double(max(0, b.high))
            frames += 1
        }
    }

    private func db(_ sum: Double) -> Double {
        frames > 0 ? 10 * log10(sum / Double(frames) + 1e-12) : .nan
    }

    var lowDb: Double { db(low) }
    var midDb: Double { db(mid) }
    var highDb: Double { db(high) }
}

/// av-fusion F0：调试表格（MotionDebugLog）后面加的声画列。纯格式化：非有限数写空，列数和表头一致
enum AVDebugColumns {
    static let f0Header = "av_onsets,av_band_frames,av_band_low_db,av_band_mid_db,av_band_high_db,"
        + "av_tap_lead_ms,av_tap_valid,av_tap_invalid,av_play_host,av_play_item,av_play_rate"

    static func field(_ x: Double, digits: Int = 4) -> String {
        x.isFinite ? String(format: "%.\(digits)f", x) : ""
    }

    /// 撞击时刻（视频时间，秒）用分号连起来（CSV 里不能有逗号）；非有限的跳过
    static func list(_ xs: [Double]) -> String {
        xs.filter { $0.isFinite }.map { String(format: "%.3f", $0) }.joined(separator: ";")
    }

    static func f0Fields(onsets: [Double], bands: AudioBandSummary, tapLead: Double, tapValid: Int, tapInvalid: Int,
                         clock: MediaClockSnapshot) -> [String] {
        [list(onsets), String(bands.frames), field(bands.lowDb, digits: 2), field(bands.midDb, digits: 2),
         field(bands.highDb, digits: 2), field(tapLead * 1000, digits: 1), String(tapValid), String(tapInvalid),
         field(clock.host), field(clock.item), field(clock.rate, digits: 3)]
    }

    /// 没在记录 / 这一拍没数据时的空列（列数不变）
    static var f0Empty: [String] {
        [String](repeating: "", count: f0Header.split(separator: ",", omittingEmptySubsequences: false).count)
    }
}

// MARK: - av-fusion F1：声音特征 + 耦合度（只显示，默认关）
// 开关 bcVisualSyncAVFusion（VisualSyncSettings.avFusion；只在跟随画面时显示 / 生效：usesAVFusion）。不是第三种来源。
// - 实时线程（AudioLevelMeter，开着才算；关着时只多看一个布尔）：AudioFeatureSplitter——6 段二阶带通的 10 毫秒能量 +
//   1 毫秒子块峰值、降采样到约 8 kHz 的 PCM，写固定容量的环形缓冲（init 时一次分配，回调里不分配、不加新锁）；
// - 主线程每个完整拍（AVFusionEngine.beat）：AudioFeatureExtractor（多频带同时起音 / 起音陡度 + 衰减 → 撞击；
//   纯 Swift FFT → 谐波度 / 频谱平坦度 / HPSS；长窗节拍网格）→ AudioSceneEvidence（P_music / P_voice）→
//   AVCouplingEstimator（C、回差、切镜考验）→「声画：」状态行和调试列；
// - F1 只显示：不改任何交给出口的值；P3 撞击声校正和融合共用频带块时经 AudioBandBacklog 原样接上（输入逐位不变）

/// av-fusion F1：P3 的三频带块两边共用。融合每拍先从电平计取走（drainBands），撞击声校正还要用时把取走的块存在这里；
/// 校正下次取的时候 take(adding:) 把新取的接在后面、只留最新的 capacity 个——和电平计环形缓冲（满了丢最旧的）
/// 单独攒到那一刻的内容逐位相同。融合关着时这里一直是空的，take 原样返回新取的
struct AudioBandBacklog {
    /// = AudioLevelMeter.bandCapacity
    static let capacity = 1024
    private(set) var frames: [AudioBandFrame] = []

    mutating func clear() {
        frames.removeAll(keepingCapacity: true)
    }

    /// 融合取走的块先存着（只留最新的 capacity 个）
    mutating func keep(_ fresh: [AudioBandFrame]) {
        guard !fresh.isEmpty else { return }
        frames.append(contentsOf: fresh)
        if frames.count > Self.capacity { frames.removeFirst(frames.count - Self.capacity) }
    }

    /// 撞击声校正取块：存着的 + 新取的，只留最新的 capacity 个，取完清空
    mutating func take(adding fresh: [AudioBandFrame]) -> [AudioBandFrame] {
        guard !frames.isEmpty else { return fresh }
        keep(fresh)
        let out = frames
        clear()
        return out
    }
}

/// av-fusion F1：6 段频带的一帧（10 毫秒）。time = 帧中点的视频时间；e* = 这一帧的均方能量；p* = 帧内 1 毫秒子块均方的最大值
struct AudioFeatureFrame: Equatable {
    static let bandCount = 6
    var time: Double = .nan
    var e0: Float = 0
    var e1: Float = 0
    var e2: Float = 0
    var e3: Float = 0
    var e4: Float = 0
    var e5: Float = 0
    var p0: Float = 0
    var p1: Float = 0
    var p2: Float = 0
    var p3: Float = 0
    var p4: Float = 0
    var p5: Float = 0

    func energy(_ b: Int) -> Double {
        switch b {
        case 0: return Double(e0)
        case 1: return Double(e1)
        case 2: return Double(e2)
        case 3: return Double(e3)
        case 4: return Double(e4)
        default: return Double(e5)
        }
    }

    func peak(_ b: Int) -> Double {
        switch b {
        case 0: return Double(p0)
        case 1: return Double(p1)
        case 2: return Double(p2)
        case 3: return Double(p3)
        case 4: return Double(p4)
        default: return Double(p5)
        }
    }

    var totalEnergy: Double { Double(e0) + Double(e1) + Double(e2) + Double(e3) + Double(e4) + Double(e5) }
}

/// av-fusion F1：RBJ 二阶带通（峰值增益 0 dB，转置直接 II 型）。几个数的状态，不分配
struct AudioBiquad {
    private var b0: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0
    private var z1: Double = 0
    private var z2: Double = 0

    init() {}

    /// 中心频率 ≥ 0.45 × 采样率（或参数不对）时不通：输出恒 0
    init(center f: Double, q: Double, sampleRate sr: Double) {
        guard sr.isFinite, sr > 0, f.isFinite, f > 0, f < 0.45 * sr, q.isFinite, q > 0 else { return }
        let w = 2 * Double.pi * f / sr
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b2 = -alpha / a0
        a1 = -2 * cos(w) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = -a1 * y + z2
        z2 = b2 * x - a2 * y
        // 静音后滤波状态衰减到非规格化数时直接归零（只为速度；有声音时一位不差）
        if abs(z1) < 1e-25 { z1 = 0 }
        if abs(z2) < 1e-25 { z2 = 0 }
        return y
    }
}

/// av-fusion F1：一段频带的累加状态（帧能量、1 毫秒子块、帧内子块峰值）
struct AudioFeatureBand {
    private var filter = AudioBiquad()
    private var acc: Double = 0
    private var sub: Double = 0
    private var peak: Double = 0

    init() {}

    init(center: Double, sampleRate: Double) {
        filter = AudioBiquad(center: center, q: AudioFeatureSplitter.q, sampleRate: sampleRate)
    }

    mutating func add(_ x: Double) {
        let y = filter.run(x)
        let s = y * y
        acc += s
        sub += s
    }

    mutating func closeSub(_ inv: Double) {
        peak = max(peak, sub * inv)
        sub = 0
    }

    mutating func closeFrame(_ inv: Double) -> (energy: Float, peak: Float) {
        let e = acc * inv
        let r = (Float(e.isFinite ? e : 0), Float(peak.isFinite ? peak : 0))
        acc = 0
        peak = 0
        return r
    }
}

/// av-fusion F1（实时线程上用，纯值类型、不分配、不加锁）：6 段二阶带通（100 / 300 / 800 / 1800 / 3500 / 6000 Hz，Q = 1）
/// 每 10 毫秒出一帧（均方能量 + 1 毫秒子块峰值）；另把单声道低通（约 3.4 kHz）后按 round(采样率 / 8000) 取平均降采样成 PCM。
/// 时间按样本计数从这一段连续声音的起点推（不按回调切块累加），所以任意切块喂进来结果都和一次喂完逐位相同；
/// 回调之间时间对不上（seek / 丢样本）超过 maxSkew 就丢掉没满的帧、滤波从头来
struct AudioFeatureSplitter {
    static let frameSeconds: Double = 0.01
    static let subSeconds: Double = 0.001
    static let maxSkew: Double = AudioBandSplitter.maxSkew
    static let q: Double = 1
    /// 中心频率（Hz）。用 switch 不用数组：configure 在实时线程上跑，静态数组第一次访问会分配
    static func center(_ b: Int) -> Double {
        switch b {
        case 0: return 100
        case 1: return 300
        case 2: return 800
        case 3: return 1800
        case 4: return 3500
        default: return 6000
        }
    }
    static let pcmTargetRate: Double = 8000
    static let pcmCutHz: Double = 3400
    /// add 的返回值：出了一帧 / 出了一个 PCM 样本
    static let frameReady: UInt8 = 1
    static let pcmReady: UInt8 = 2

    /// 采样率 → 降采样倍数（认不出 0）
    static func decimation(forSampleRate sr: Double) -> Int {
        guard sr.isFinite, sr > 1000, sr < 1_000_000 else { return 0 }
        return max(1, Int((sr / pcmTargetRate).rounded()))
    }

    /// 采样率 → PCM 的采样率（认不出 0）
    static func pcmRate(forSampleRate sr: Double) -> Double {
        let d = decimation(forSampleRate: sr)
        return d > 0 ? sr / Double(d) : 0
    }

    private(set) var sampleRate: Double = 0
    private var band0 = AudioFeatureBand()
    private var band1 = AudioFeatureBand()
    private var band2 = AudioFeatureBand()
    private var band3 = AudioFeatureBand()
    private var band4 = AudioFeatureBand()
    private var band5 = AudioFeatureBand()
    private var frameLength = 0
    private var subLength = 0
    private var decimation = 0
    private var inFrame = 0
    private var inSub = 0
    private var inPCM = 0
    private var frameStart = 0
    private var count = 0
    /// 这一段连续声音第一个样本的视频时间（NaN = 还没开始 / 时间拿不到，此时不出帧）
    private var origin = Double.nan
    private var expectedNext = Double.nan
    private var lowpass: Double = 0
    private var lowpassCoef: Double = 0
    private var pcmAcc: Double = 0

    /// 采样率认不出（≤ 1 kHz / 非有限）时不出帧
    mutating func configure(sampleRate sr: Double) {
        self = AudioFeatureSplitter()
        let d = Self.decimation(forSampleRate: sr)
        guard d > 0 else { return }
        sampleRate = sr
        frameLength = max(1, Int((sr * Self.frameSeconds).rounded()))
        subLength = max(1, Int((sr * Self.subSeconds).rounded()))
        decimation = d
        lowpassCoef = 1 - exp(-2 * Double.pi * min(Self.pcmCutHz, 0.45 * sr / Double(d)) / sr)
        band0 = AudioFeatureBand(center: Self.center(0), sampleRate: sr)
        band1 = AudioFeatureBand(center: Self.center(1), sampleRate: sr)
        band2 = AudioFeatureBand(center: Self.center(2), sampleRate: sr)
        band3 = AudioFeatureBand(center: Self.center(3), sampleRate: sr)
        band4 = AudioFeatureBand(center: Self.center(4), sampleRate: sr)
        band5 = AudioFeatureBand(center: Self.center(5), sampleRate: sr)
    }

    private mutating func restart(origin start: Double) {
        let sr = sampleRate
        configure(sampleRate: sr)
        origin = start
    }

    /// 一次回调开始：start = 第一个样本的视频时间。拿不到时间 → 这一段不出帧（滤波从头来）；
    /// 和上一次接不上 → 丢掉没满的帧、从这里重新起算；差不到半个样本的不动，差得多（≤ maxSkew）只把时间起点挪过去
    mutating func begin(start: Double, frames: Int) {
        guard sampleRate > 0 else { return }
        guard start.isFinite else {
            restart(origin: .nan)
            return
        }
        if !origin.isFinite || !expectedNext.isFinite || abs(start - expectedNext) > Self.maxSkew {
            restart(origin: start)
        } else if abs(start - expectedNext) > 0.5 / sampleRate {
            origin += start - expectedNext
        }
        expectedNext = start + Double(max(0, frames)) / sampleRate
    }

    /// 一个样本。满 10 毫秒把一帧写进 frame、满一个降采样周期把一个 PCM 样本写进 pcm；返回 frameReady / pcmReady 的组合
    mutating func add(_ x: Double, frame: inout AudioFeatureFrame, pcm: inout Float) -> UInt8 {
        guard frameLength > 0, origin.isFinite else { return 0 }
        let v = x.isFinite ? max(-4, min(4, x)) : 0
        if inFrame == 0 { frameStart = count }
        band0.add(v)
        band1.add(v)
        band2.add(v)
        band3.add(v)
        band4.add(v)
        band5.add(v)
        count += 1
        var flags: UInt8 = 0
        inSub += 1
        if inSub >= subLength {
            let inv = 1 / Double(subLength)
            band0.closeSub(inv)
            band1.closeSub(inv)
            band2.closeSub(inv)
            band3.closeSub(inv)
            band4.closeSub(inv)
            band5.closeSub(inv)
            inSub = 0
        }
        inFrame += 1
        if inFrame >= frameLength {
            let inv = 1 / Double(frameLength)
            var f = AudioFeatureFrame()
            f.time = origin + (Double(frameStart) + 0.5 * Double(frameLength)) / sampleRate
            (f.e0, f.p0) = band0.closeFrame(inv)
            (f.e1, f.p1) = band1.closeFrame(inv)
            (f.e2, f.p2) = band2.closeFrame(inv)
            (f.e3, f.p3) = band3.closeFrame(inv)
            (f.e4, f.p4) = band4.closeFrame(inv)
            (f.e5, f.p5) = band5.closeFrame(inv)
            inFrame = 0
            if f.time.isFinite {
                frame = f
                flags |= Self.frameReady
            }
        }
        lowpass += lowpassCoef * (v - lowpass)
        pcmAcc += lowpass
        inPCM += 1
        if inPCM >= decimation {
            let y = pcmAcc / Double(decimation)
            pcm = Float(y.isFinite ? y : 0)
            pcmAcc = 0
            inPCM = 0
            flags |= Self.pcmReady
        }
        return flags
    }
}

/// av-fusion F1：主线程每拍从电平计取走的特征（旧 → 新）。invalidChunks = 融合开着时时间范围拿不到的回调数
struct AudioFeatureDrain: Equatable {
    var frames: [AudioFeatureFrame] = []
    var pcm: [Float] = []
    var pcmRate: Double = 0
    var invalidChunks = 0
}

/// av-fusion F1：纯 Swift 基 2 复数 FFT（原地）。只依赖 Foundation：设备和 VisualSyncChecks 走同一份代码（不用 Accelerate）
struct AudioFFT {
    let n: Int
    private let cosTable: [Double]
    private let sinTable: [Double]
    private let bitReverse: [Int]

    init(size: Int) {
        var m = 2
        while m < size { m <<= 1 }
        n = m
        cosTable = (0..<(m / 2)).map { cos(2 * Double.pi * Double($0) / Double(m)) }
        sinTable = (0..<(m / 2)).map { sin(2 * Double.pi * Double($0) / Double(m)) }
        var bits = 0
        while (1 << bits) < m { bits += 1 }
        var rev = [Int](repeating: 0, count: m)
        for i in 0..<m {
            var r = 0
            var x = i
            for _ in 0..<bits {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            rev[i] = r
        }
        bitReverse = rev
    }

    /// 正变换 X[k] = Σ x[j]·e^(−2πi·jk/n)；inverse 时 e^(+…)（不除 n）
    func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool = false) {
        guard re.count == n, im.count == n else { return }
        for i in 0..<n {
            let j = bitReverse[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        let sign: Double = inverse ? 1 : -1
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosTable[k * step]
                    let wi = sign * sinTable[k * step]
                    let a = start + k
                    let b = a + half
                    let xr = re[b] * wr - im[b] * wi
                    let xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr
                    im[b] = im[a] - xi
                    re[a] += xr
                    im[a] += xi
                }
                start += len
            }
            len <<= 1
        }
    }
}

/// av-fusion F1：降采样 PCM 的短时分析（主线程）。每 20 毫秒一帧：最近 512 个样本加 Hann 窗、补零到 1024 点 FFT——
/// - 谐波度：功率谱反变换得自相关，除以窗自己的自相关（Boersma），70~400 Hz 的 lag 里取最高的局部峰 ρ，
///   谐波度 = clamp((ρ − 0.35) / 0.5)（噪声 / 撞击 ≈ 0，人声 / 呻吟 / 和弦 ≈ 1）；太静（RMS < 1e-3）的帧不算；
/// - 频谱平坦度：功率谱几何平均 / 算术平均；
/// - HPSS 用的 32 段频谱（每段 16 个频点）
struct AudioHarmonicAnalyzer {
    static let window = 512
    static let fftSize = 1024
    static let hopSeconds: Double = 0.02
    static let minHz: Double = 70
    static let maxHz: Double = 400
    static let gateRMS: Double = 1e-3
    static let rhoLow: Double = 0.35
    static let rhoSpan: Double = 0.5
    static let spectrumBands = 32

    struct Frame: Equatable {
        var voiced = false
        var harmonicity: Double = 0
        var flatness: Double = .nan
        var spectrum: [Double] = []
    }

    static let hann: [Double] = (0..<window).map { 0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(window)) }
    /// Hann 窗自己的自相关（归一到 lag 0 = 1）
    static let windowCorrelation: [Double] = {
        var r = [Double](repeating: 0, count: window)
        for lag in 0..<window {
            var s = 0.0
            for i in 0..<(window - lag) { s += hann[i] * hann[i + lag] }
            r[lag] = s
        }
        let r0 = r[0]
        return r.map { $0 / r0 }
    }()

    private(set) var rate: Double = 0
    private var ring = [Float](repeating: 0, count: AudioHarmonicAnalyzer.window)
    private var head = 0
    private var filled = 0
    private var sinceHop = 0
    private var hop = 0
    private let fft = AudioFFT(size: AudioHarmonicAnalyzer.fftSize)

    mutating func reset() {
        ring = [Float](repeating: 0, count: Self.window)
        head = 0
        filled = 0
        sinceHop = 0
        hop = 0
        rate = 0
    }

    /// 喂一段 PCM（采样率变了就从头来）；返回这段里出的分析帧
    mutating func add(_ samples: [Float], rate r: Double) -> [Frame] {
        guard r.isFinite, r > 1000 else { return [] }
        if r != rate {
            reset()
            rate = r
            hop = max(1, Int((r * Self.hopSeconds).rounded()))
        }
        var out: [Frame] = []
        for x in samples {
            ring[head] = x.isFinite ? x : 0
            head = (head + 1) % Self.window
            filled = min(Self.window, filled + 1)
            sinceHop += 1
            if filled == Self.window, sinceHop >= hop {
                sinceHop = 0
                out.append(analyze())
            }
        }
        return out
    }

    private func analyze() -> Frame {
        let n = Self.fftSize
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        var sq = 0.0
        for i in 0..<Self.window {
            let x = Double(ring[(head + i) % Self.window])
            sq += x * x
            re[i] = x * Self.hann[i]
        }
        fft.transform(&re, &im)
        var power = [Double](repeating: 0, count: n)
        for k in 0..<n { power[k] = re[k] * re[k] + im[k] * im[k] }
        var frame = Frame()
        let bins = n / 2
        let per = bins / Self.spectrumBands
        var spectrum = [Double](repeating: 0, count: Self.spectrumBands)
        for b in 0..<Self.spectrumBands {
            var s = 0.0
            for k in (b * per)..<((b + 1) * per) { s += power[k] }
            spectrum[b] = s
        }
        frame.spectrum = spectrum
        let rms = (sq / Double(Self.window)).squareRoot()
        guard rms.isFinite, rms >= Self.gateRMS else { return frame }
        frame.voiced = true
        var logSum = 0.0
        var sum = 0.0
        for k in 1..<bins {
            logSum += log(power[k] + 1e-20)
            sum += power[k]
        }
        let mean = sum / Double(bins - 1)
        let flat = exp(logSum / Double(bins - 1)) / (mean + 1e-20)
        frame.flatness = flat.isFinite ? min(1, max(0, flat)) : .nan
        // 自相关 = 功率谱的反变换（补零到 2 倍窗长 = 线性自相关）
        var ar = power
        var ai = [Double](repeating: 0, count: n)
        fft.transform(&ar, &ai, inverse: true)
        let r0 = ar[0]
        guard r0 > 1e-20 else { return frame }
        let minLag = max(2, Int((rate / Self.maxHz).rounded(.down)))
        let maxLag = min(Self.window / 3, Int((rate / Self.minHz).rounded(.up)))
        guard maxLag > minLag + 1 else { return frame }
        func rho(_ lag: Int) -> Double { (ar[lag] / r0) / max(1e-6, Self.windowCorrelation[lag]) }
        var best = 0.0
        for lag in minLag...maxLag {
            let v = rho(lag)
            if v > best, v >= rho(lag - 1), v >= rho(lag + 1) { best = v }
        }
        let h = (min(1, best) - Self.rhoLow) / Self.rhoSpan
        frame.harmonicity = h.isFinite ? min(1, max(0, h)) : 0
        return frame
    }
}

/// av-fusion F1：一次起音候选的判断结果（视频时间）
struct AudioOnsetEvent: Equatable {
    var time: Double
    /// 各频带上升（dB）之和：节拍网格的权重
    var strength: Double
    /// 上升 ≥ 6 dB 的频带数
    var risingBands: Int
    /// 起音陡（20 毫秒内比之前升 ≥ 9 dB，而且已经到了之后 80 毫秒最高点的 3 dB 以内）的频带数
    var steepBands: Int
    /// 又陡、40~80 毫秒内又降了 ≥ 6 dB 的频带数
    var shortBands: Int

    /// 撞击：≥ 4 段同时又陡又短（宽带、短促）
    var isImpact: Bool { shortBands >= AudioFeatureExtractor.impactBands }
    /// 起音陡（≥ 2 段又陡又短）：P_voice 的「起音陡度」按这个算占比
    var isSteep: Bool { shortBands >= AudioFeatureExtractor.steepBands }
}

/// av-fusion F1：长窗节拍网格（视频时间）：period 秒一格，anchor 是一个格点；share = 起音落在格点 ±30 毫秒内的权重占比
struct AudioBeatGrid: Equatable {
    var period: Double
    var anchor: Double
    var share: Double
    /// clamp((share − 0.5) / 0.3)
    var stable: Double
    /// 有 2× 细分（踩镲）：clamp((corr(L/2) / corr(L) − 0.3) / 0.4)
    var subdivided: Double

    /// P_music 的「长窗网格稳定」= 稳定 × 细分
    var value: Double { stable * subdivided }

    /// t 离最近格点多远（秒，±period / 2）
    func residual(_ t: Double) -> Double {
        guard period > 0, t.isFinite else { return .infinity }
        var x = (t - anchor) / period
        x -= x.rounded()
        return x * period
    }

    static let tolerance: Double = 0.03
    static let windowSeconds: Double = 12
    static let minSpan: Double = 6
    static let minEvents = 8
    static let bin: Double = 0.01
    static let minLagBins = 30
    static let maxLagBins = 150
    static let harmonicShare: Double = 0.85

    /// 最近 windowSeconds 秒（start ~ end）的起音按强度做成脉冲串（σ = 1.5 格的高斯），归一化自相关：
    /// 0.3~1.5 秒里最高的局部峰 L（比它短、不低于它 85% 的局部峰优先），看 L/2 有没有细分；
    /// 格长 = 细分 ≥ 0.5 时 L/2、否则 L，再在 ±12 毫秒里按 0.5 毫秒细调（合成长度最大），求格点和占比
    static func estimate(_ events: [AudioOnsetEvent], start: Double, end: Double) -> AudioBeatGrid? {
        guard start.isFinite, end.isFinite, end - start >= minSpan else { return nil }
        let ev = events.filter { $0.time > start && $0.time <= end && $0.strength > 0 && $0.strength.isFinite }
        guard ev.count >= minEvents else { return nil }
        let n = Int(((end - start) / bin).rounded(.up)) + 1
        guard n > 2 * maxLagBins else { return nil }
        var sig = [Double](repeating: 0, count: n)
        let sigma = 1.5
        for e in ev {
            let c = (e.time - start) / bin
            let lo = max(0, Int((c - 4 * sigma).rounded(.down)))
            let hi = min(n - 1, Int((c + 4 * sigma).rounded(.up)))
            guard lo <= hi else { continue }
            for k in lo...hi {
                let d = (Double(k) - c) / sigma
                sig[k] += e.strength * exp(-0.5 * d * d)
            }
        }
        var mean = 0.0
        for v in sig { mean += v }
        mean /= Double(n)
        var r0 = 0.0
        for k in 0..<n {
            sig[k] -= mean
            r0 += sig[k] * sig[k]
        }
        guard r0 > 1e-12 else { return nil }
        let lo = minLagBins / 2 - 1
        let hi = maxLagBins + 1
        var corr = [Double](repeating: 0, count: hi + 1)
        for lag in lo...hi {
            var s = 0.0
            for k in 0..<(n - lag) { s += sig[k] * sig[k + lag] }
            corr[lag] = s / r0 * Double(n) / Double(n - lag)
        }
        var best = 0.0
        var bestLag = 0
        for lag in minLagBins...maxLagBins where corr[lag] > best && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            best = corr[lag]
            bestLag = lag
        }
        guard bestLag > 0, best > 0.1 else { return nil }
        for lag in minLagBins..<bestLag where corr[lag] >= harmonicShare * best
            && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            bestLag = lag
            break
        }
        let half = bestLag / 2
        let sub = max(corr[half], corr[half + (bestLag % 2)], corr[max(lo, half - 1)], corr[half + 1])
        let ratio = sub / max(1e-9, corr[bestLag])
        let subdivided = min(1, max(0, (ratio - 0.3) / 0.4))
        let coarse = (subdivided >= 0.5 ? Double(bestLag) / 2 : Double(bestLag)) * bin
        var total = 0.0
        for e in ev { total += e.strength }
        var bestR = -1.0
        var period = coarse
        var anchor = 0.0
        var step = -24
        while step <= 24 {
            let g = coarse + Double(step) * 0.0005
            step += 1
            guard g > 0.05 else { continue }
            var sx = 0.0
            var sy = 0.0
            for e in ev {
                let a = 2 * Double.pi * (e.time - start) / g
                sx += e.strength * cos(a)
                sy += e.strength * sin(a)
            }
            let r = (sx * sx + sy * sy).squareRoot() / total
            if r > bestR {
                bestR = r
                period = g
                anchor = start + atan2(sy, sx) / (2 * Double.pi) * g
            }
        }
        var grid = AudioBeatGrid(period: period, anchor: anchor, share: 0, stable: 0, subdivided: subdivided)
        var on = 0.0
        for e in ev where abs(grid.residual(e.time)) <= tolerance { on += e.strength }
        grid.share = on / total
        grid.stable = min(1, max(0, (grid.share - 0.5) / 0.3))
        return grid
    }
}

/// av-fusion F1：主线程的声音特征（只读电平计取走的特征帧和 PCM，不碰任何控制状态）。
/// 起音候选：≥ 2 段的帧能量比前两帧里低的那个升了 ≥ 6 dB（离上一个候选 ≥ 80 毫秒）；8 帧（80 毫秒）后判断——
/// 每段：陡 = 这帧和下一帧的 1 毫秒峰值比之前升 ≥ 9 dB、而且到了之后 80 毫秒最高点的 3 dB 以内（10~20 毫秒内起来）；
/// 短 = 40~80 毫秒那 5 帧的平均比峰值降了 ≥ 6 dB。≥ 4 段又陡又短 = 撞击（宽带、短促）。
/// PCM 那边每 20 毫秒一帧谐波度 / 平坦度 / 32 段频谱（AudioHarmonicAnalyzer），取最近 2 秒的中位数；HPSS 用最近 17 帧
struct AudioFeatureExtractor {
    static let jumpDb: Double = 6
    static let minRisingBands = 2
    static let steepRiseDb: Double = 9
    static let nearPeakDb: Double = 3
    static let decayDb: Double = 6
    static let refractory: Double = 0.08
    static let impactBands = 4
    static let steepBands = 2
    static let lookahead = 8
    static let silenceDb: Double = -70
    static let maxFrameGap: Double = 0.1
    static let historySeconds: Double = 13
    static let historyFrames = 16
    static let harmonicFrames = 100
    static let minVoicedFrames = 10
    static let hpssFrames = 17
    static let loudEnergy: Double = 1e-7

    private var recent: [AudioFeatureFrame] = []
    /// recent[0] 的序号（收到的第几帧）
    private var base = 0
    private var nextIndex = 0
    private var pending: [Int] = []
    private var lastCandidate = -Double.infinity
    private(set) var events: [AudioOnsetEvent] = []
    private(set) var lastFrameTime = Double.nan
    private(set) var lastLoudTime = Double.nan
    /// 这次 reset 以来第一帧的视频时间（长窗网格的起点不早于它）
    private(set) var firstFrameTime = Double.nan
    private var analyzer = AudioHarmonicAnalyzer()
    private(set) var harmonic: [AudioHarmonicAnalyzer.Frame] = []

    mutating func reset() {
        self = AudioFeatureExtractor()
    }

    private static func db(_ x: Double) -> Double { 10 * log10(max(1e-14, x.isFinite ? x : 0)) }

    private func frame(_ i: Int) -> AudioFeatureFrame { recent[i - base] }
    private func energyDb(_ i: Int, _ b: Int) -> Double { Self.db(frame(i).energy(b)) }
    private func peakDb(_ i: Int, _ b: Int) -> Double {
        let f = frame(i)
        return Self.db(max(f.peak(b), f.energy(b)))
    }

    /// 时间倒退 / 断档（seek）：没判断完的候选和最近几帧丢掉（已判断的起音留着，换视频 / seek 时由调用方 reset）
    private mutating func clearFrames() {
        recent.removeAll(keepingCapacity: true)
        base = nextIndex
        pending.removeAll()
    }

    mutating func add(_ f: AudioFeatureFrame) {
        guard f.time.isFinite else { return }
        if lastFrameTime.isFinite, f.time <= lastFrameTime || f.time - lastFrameTime > Self.maxFrameGap { clearFrames() }
        lastFrameTime = f.time
        if !firstFrameTime.isFinite { firstFrameTime = f.time }
        if f.totalEnergy >= Self.loudEnergy { lastLoudTime = f.time }
        recent.append(f)
        if recent.count > Self.historyFrames {
            recent.removeFirst()
            base += 1
        }
        let k = nextIndex
        nextIndex += 1
        if k - 2 >= base, f.time - lastCandidate >= Self.refractory {
            var rising = 0
            for b in 0..<AudioFeatureFrame.bandCount {
                let d = energyDb(k, b)
                let before = max(min(energyDb(k - 1, b), energyDb(k - 2, b)), Self.silenceDb)
                if d > Self.silenceDb, d - before >= Self.jumpDb { rising += 1 }
            }
            if rising >= Self.minRisingBands {
                pending.append(k)
                lastCandidate = f.time
            }
        }
        while let c = pending.first, k >= c + Self.lookahead {
            pending.removeFirst()
            if c - 2 >= base { evaluate(c) }
        }
    }

    private mutating func evaluate(_ c: Int) {
        var strength = 0.0
        var rising = 0
        var steep = 0
        var short = 0
        for b in 0..<AudioFeatureFrame.bandCount {
            let before = max(min(energyDb(c - 1, b), energyDb(c - 2, b)), Self.silenceDb)
            let top = max(energyDb(c, b), energyDb(c + 1, b))
            let rise = top - before
            if rise > 0 { strength += rise }
            if rise >= Self.jumpDb { rising += 1 }
            let near = max(peakDb(c, b), peakDb(c + 1, b))
            var later = near
            for j in (c + 2)...(c + Self.lookahead) { later = max(later, peakDb(j, b)) }
            guard near - before >= Self.steepRiseDb, near >= later - Self.nearPeakDb else { continue }
            steep += 1
            var tail = 0.0
            for j in (c + 4)...(c + 8) { tail += energyDb(j, b) }
            tail /= 5
            if tail <= top - Self.decayDb { short += 1 }
        }
        events.append(AudioOnsetEvent(time: frame(c).time, strength: strength, risingBands: rising, steepBands: steep,
                                      shortBands: short))
        let keepAfter = lastFrameTime - Self.historySeconds
        if let first = events.first, first.time < keepAfter { events.removeAll { $0.time < keepAfter } }
    }

    mutating func addPCM(_ samples: [Float], rate: Double) {
        guard !samples.isEmpty else { return }
        let frames = analyzer.add(samples, rate: rate)
        guard !frames.isEmpty else { return }
        harmonic.append(contentsOf: frames)
        if harmonic.count > Self.harmonicFrames { harmonic.removeFirst(harmonic.count - Self.harmonicFrames) }
    }

    /// 撞击时刻（视频时间，from ≤ t ≤ to，旧 → 新）
    func impacts(from: Double, to: Double) -> [Double] {
        events.filter { $0.isImpact && $0.time >= from && $0.time <= to }.map { $0.time }
    }

    /// 起音陡度：这段时间里起音候选（按强度加权）有多少是陡的；没有候选 0
    func steepness(from: Double, to: Double) -> Double {
        var all = 0.0
        var steep = 0.0
        for e in events where e.time >= from && e.time <= to {
            let w = max(1e-6, e.strength)
            all += w
            if e.isSteep { steep += w }
        }
        return all > 0 ? steep / all : 0
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return .nan }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : 0.5 * (s[m - 1] + s[m])
    }

    /// 谐波度：最近 2 秒不太静的帧的中位数（不够 10 帧 0）
    var harmonicity: Double {
        let v = harmonic.filter { $0.voiced }.map { $0.harmonicity }
        return v.count >= Self.minVoicedFrames ? Self.median(v) : 0
    }

    /// 频谱平坦度：最近 2 秒不太静的帧的中位数（不够 10 帧 NaN）
    var flatness: Double {
        let v = harmonic.filter { $0.voiced && $0.flatness.isFinite }.map { $0.flatness }
        return v.count >= Self.minVoicedFrames ? Self.median(v) : .nan
    }

    /// HPSS 简化版：最近 17 帧 × 32 段，中间那帧每段的时间方向中值 H、频率方向（±8 段）中值 P，
    /// 打击成分占比 = Σ S·P² / (H² + P²) / Σ S（不够 17 帧 / 太静 NaN）
    var percussive: Double {
        guard harmonic.count >= Self.hpssFrames else { return .nan }
        let frames = harmonic.suffix(Self.hpssFrames).map { $0.spectrum }
        let bands = AudioHarmonicAnalyzer.spectrumBands
        guard frames.allSatisfy({ $0.count == bands }) else { return .nan }
        let center = frames[Self.hpssFrames / 2]
        var total = 0.0
        var perc = 0.0
        for b in 0..<bands {
            let h = Self.median(frames.map { $0[b] })
            let p = Self.median(Array(center[max(0, b - 8)...min(bands - 1, b + 8)]))
            let den = h * h + p * p
            total += center[b]
            if den > 0 { perc += center[b] * p * p / den }
        }
        return total > 1e-12 ? min(1, max(0, perc / total)) : .nan
    }
}

/// av-fusion F1：配乐 / 人声的证据（主线程每个完整拍一次，视频时间）。
/// P_music = max(0.4·跨切镜节拍连续 + 0.3·画面不动时仍有节奏 + 0.2·长窗网格（稳定 × 细分）+ 0.1·谐波,
///               0.8·跨切镜连续, 0.6·画面不动仍有节奏)；P_voice = 谐波度 × (1 − 起音陡度)。
/// - 跨切镜：切镜那一拍有稳定网格（stable ≥ 0.5）就记下来，之后 2 秒里 ≥ 2 次起音、按强度 ≥ 75% 落在原网格 ±30 毫秒 → 1，保持 10 秒；
///   考验期间（cutTesting）耦合度挂起不更新；
/// - 画面不动（activity = 0）时声音节奏置信 ≥ 0.4：1 秒爬满，条件没了保持 10 秒再按 1 秒降
struct AudioSceneEvidence {
    static let crossCutWeight: Double = 0.4
    static let stillWeight: Double = 0.3
    static let gridWeight: Double = 0.2
    static let harmonicWeight: Double = 0.1
    /// 两条最有力的证据单独成立时的下限（「强烈上升」）：跨切镜连续 ⇒ ≥ 0.8，画面不动仍有节奏 ⇒ ≥ 0.6
    static let crossCutFloor: Double = 0.8
    static let stillFloor: Double = 0.6
    static let cutTestSeconds: Double = 2
    static let cutMinOnsets = 2
    static let cutShare: Double = 0.75
    static let holdSeconds: Double = 10
    static let stillConfidence: Double = 0.4
    static let rampSeconds: Double = 1
    static let minCutStable: Double = 0.5

    private(set) var crossCut: Double = 0
    private(set) var still: Double = 0
    private(set) var grid: Double = 0
    private(set) var harmonic: Double = 0
    private(set) var steepness: Double = 0
    private(set) var pMusic: Double = 0
    private(set) var pVoice: Double = 0
    /// 切镜考验：记下的网格和切镜时刻（视频时间）
    private(set) var cutTest: (grid: AudioBeatGrid, start: Double)?
    private var crossCutUntil = -Double.infinity
    private var stillSeen = -Double.infinity

    var cutTesting: Bool { cutTest != nil }

    mutating func reset() {
        self = AudioSceneEvidence()
    }

    mutating func step(item: Double, cut: Bool, grid g: AudioBeatGrid?, onsets: [AudioOnsetEvent], activity: Double,
                       rhythmConfidence: Double, harmonicity: Double, steepness s: Double, audioPresent: Bool,
                       dt: Double) {
        let step = dt.isFinite ? min(1, max(0, dt)) : AudioReactiveShaper.interval
        guard item.isFinite else { return }
        if cut, cutTest == nil, let g = g, g.stable >= Self.minCutStable { cutTest = (g, item) }
        if let test = cutTest, item >= test.start + Self.cutTestSeconds {
            var all = 0.0
            var on = 0.0
            var count = 0
            for e in onsets where e.time > test.start && e.time <= test.start + Self.cutTestSeconds {
                let w = max(1e-6, e.strength)
                all += w
                count += 1
                if abs(test.grid.residual(e.time)) <= AudioBeatGrid.tolerance { on += w }
            }
            if count >= Self.cutMinOnsets, all > 0, on / all >= Self.cutShare { crossCutUntil = item + Self.holdSeconds }
            cutTest = nil
        }
        crossCut = item < crossCutUntil ? 1 : 0
        if audioPresent, activity <= 0, rhythmConfidence.isFinite, rhythmConfidence >= Self.stillConfidence {
            still = min(1, still + step / Self.rampSeconds)
            stillSeen = item
        } else if item - stillSeen > Self.holdSeconds || item < stillSeen {
            still = max(0, still - step / Self.rampSeconds)
        }
        grid = g?.value ?? 0
        harmonic = harmonicity.isFinite ? min(1, max(0, harmonicity)) : 0
        steepness = s.isFinite ? min(1, max(0, s)) : 0
        if !audioPresent {
            grid = 0
            harmonic = 0
        }
        let linear = Self.crossCutWeight * crossCut + Self.stillWeight * still + Self.gridWeight * grid
            + Self.harmonicWeight * harmonic
        pMusic = min(1, max(linear, Self.crossCutFloor * crossCut, Self.stillFloor * still))
        pVoice = harmonic * (1 - steepness)
    }
}

/// av-fusion F1：声画耦合度 C（主线程每个完整拍一次）。
/// C_raw = A_f × A_R × A_n × (1 − P_music) × (1 − P_voice)：
/// A_f = clamp(1 − |ln(f_a / f_v)| / ln 1.15)（f_a = 最近 4 秒撞击间隔中位数换成的频率 × 倍速，f_v = 相位锁频率）；
/// A_R = clamp((R − 0.4) / 0.4)（R = 撞击时刻画面相位的集中度，相位锁锁着才有）；A_n = clamp((n − 2) / 3)（n = 最近 4 秒撞击次数）。
/// C 按 τ = 1 秒 EMA；C ≥ 0.6 持续 2 秒进入「耦合」，C < 0.4 持续 1.5 秒退出；切镜考验期间挂起（不更新、不清）；seek / 换视频 / 开关时 reset
struct AVCouplingEstimator {
    static let agreeRatio: Double = 0.15
    static let minR: Double = 0.4
    static let spanR: Double = 0.4
    static let minImpacts: Double = 2
    static let spanImpacts: Double = 3
    static let windowSeconds: Double = 4
    static let tau: Double = 1
    static let enterLevel: Double = 0.6
    static let enterSeconds: Double = 2
    static let exitLevel: Double = 0.4
    static let exitSeconds: Double = 1.5
    static let minPhaseImpacts = 3

    private(set) var c: Double = 0
    private(set) var coupled = false
    private var above: Double?
    private var below: Double?

    mutating func reset() {
        self = AVCouplingEstimator()
    }

    static func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }

    static func frequencyAgreement(audioHz fa: Double, visualHz fv: Double) -> Double {
        guard fa.isFinite, fv.isFinite, fa > 0, fv > 0 else { return 0 }
        return clamp01(1 - abs(log(fa / fv)) / log(1 + agreeRatio))
    }

    static func concentrationScore(_ r: Double) -> Double { clamp01((r - minR) / spanR) }

    static func countScore(_ n: Int) -> Double { clamp01((Double(n) - minImpacts) / spanImpacts) }

    /// 撞击间隔中位数 → 频率（视频时间上的 Hz；不够 3 次 / 间隔离谱 0）
    static func impactHz(_ times: [Double]) -> Double {
        guard times.count >= 3 else { return 0 }
        var gaps: [Double] = []
        for k in 1..<times.count {
            let g = times[k] - times[k - 1]
            if g.isFinite, g > 0.2, g < 3 { gaps.append(g) }
        }
        guard gaps.count >= 2 else { return 0 }
        let s = gaps.sorted()
        let m = s.count / 2
        let med = s.count % 2 == 1 ? s[m] : 0.5 * (s[m - 1] + s[m])
        return med > 0 ? 1 / med : 0
    }

    /// 撞击时刻（host 时间）的画面相位集中度（相位锁没锁 / 不够 3 次 NaN）
    static func concentration(_ hostTimes: [Double], lock: RhythmPhaseLock) -> Double {
        guard lock.locked else { return .nan }
        var sx = 0.0
        var sy = 0.0
        var n = 0
        for t in hostTimes {
            guard let ph = lock.phase(at: t) else { continue }
            sx += cos(ph)
            sy += sin(ph)
            n += 1
        }
        guard n >= minPhaseImpacts else { return .nan }
        let r = (sx * sx + sy * sy).squareRoot() / Double(n)
        return r.isFinite ? r : .nan
    }

    /// 这一拍：raw = C_raw；suspended（切镜考验）时什么都不改
    mutating func step(raw: Double, dt: Double, suspended: Bool) {
        guard !suspended else { return }
        let step = dt.isFinite ? min(1, max(0, dt)) : AudioReactiveShaper.interval
        let x = Self.clamp01(raw)
        c += (1 - exp(-step / Self.tau)) * (x - c)
        if !c.isFinite { c = 0 }
        if coupled {
            above = nil
            if c < Self.exitLevel {
                let held = (below ?? -step) + step
                below = held
                if held >= Self.exitSeconds - 1e-9 {
                    coupled = false
                    below = nil
                }
            } else {
                below = nil
            }
        } else {
            below = nil
            if c >= Self.enterLevel {
                let held = (above ?? -step) + step
                above = held
                if held >= Self.enterSeconds - 1e-9 {
                    coupled = true
                    above = nil
                }
            } else {
                above = nil
            }
        }
    }
}

/// av-fusion F1：一拍的融合结果（状态行 / 调试列用；F1 不进控制）
struct AVFusionBeat: Equatable {
    enum State: String {
        case noAudio = "no_audio"
        case noTime = "no_time"
        case cutTest = "cut_test"
        case coupled
        case music
        case voice
        case noLock = "no_lock"
        case uncoupled
    }

    var state: State = .noAudio
    var c: Double = 0
    var raw: Double = 0
    var coupled = false
    var af: Double = 0
    var ar: Double = 0
    var an: Double = 0
    var r: Double = .nan
    var impacts = 0
    var fa: Double = 0
    var fv: Double = 0
    var pMusic: Double = 0
    var pVoice: Double = 0
    var crossCut: Double = 0
    var still: Double = 0
    var grid: Double = 0
    var harmonicity: Double = 0
    var steepness: Double = 0
    var flatness: Double = .nan
    var percussive: Double = .nan
    var rhythmConfidence: Double = 0

    static let musicLevel: Double = 0.5
    static let voiceLevel: Double = 0.5

    var statusText: String {
        switch state {
        case .noAudio:
            return "声画：没声音（只看画面）"
        case .noTime:
            return "声画：时间不可用（拿不到这段声音的视频时间，只看画面）"
        case .cutTest:
            return "声画：切镜了，看节拍是否连续（耦合度先挂起）"
        case .coupled:
            return String(format: "声画：耦合（C %.2f，撞击 %d 下 / 4 秒，集中度 %.2f）", c, impacts, r.isFinite ? r : 0)
        case .music:
            return String(format: "声画：像配乐（%.2f），不耦合（C %.2f）", pMusic, c)
        case .voice:
            return String(format: "声画：像人声（%.2f），不耦合（C %.2f）", pVoice, c)
        case .noLock:
            return "声画：不耦合（画面相位还没锁上；要开「伸缩跟随频率」和「相位脉动」）"
        case .uncoupled:
            let reason: String
            if an <= 0 {
                reason = "撞击太少"
            } else if af <= ar {
                reason = "频率对不上"
            } else {
                reason = "相位散"
            }
            return String(format: "声画：不耦合（C %.2f，%@）", c, reason)
        }
    }
}

/// av-fusion F1：融合的主线程部分（每个完整拍一次；只读，不改任何交给出口的值）。
/// 声音在场 = 音轨 tap 就绪 + 特征帧在流（最近 1 秒内有）+ 最近 1 秒有不静的帧；时间不可用 = 这一拍没有特征帧、却有时间范围拿不到的回调
struct AVFusionEngine {
    static let presenceSeconds: Double = 1
    static let gridEvery: Double = 1

    private(set) var extractor = AudioFeatureExtractor()
    /// P3 的三频带块 → 撞击检测（只给「画面不动时仍有节奏」用；和撞击声校正那份互不影响）
    private var onsetDetector = AudioOnsetDetector()
    private(set) var scene = AudioSceneEvidence()
    private(set) var coupling = AVCouplingEstimator()
    private(set) var grid: AudioBeatGrid?
    private var gridAt = -Double.infinity
    private var framesThisBeat = 0
    private var invalidThisBeat = 0
    private var timeInvalid = false

    mutating func reset() {
        self = AVFusionEngine()
    }

    mutating func addBands(_ frames: [AudioBandFrame]) {
        for f in frames { onsetDetector.add(f) }
    }

    mutating func addFeatures(_ d: AudioFeatureDrain) {
        for f in d.frames { extractor.add(f) }
        extractor.addPCM(d.pcm, rate: d.pcmRate)
        framesThisBeat += d.frames.count
        invalidThisBeat += d.invalidChunks
    }

    /// clock：这一拍读到的播放器时钟；lock：画面相位锁（P2，只读）；activity：画面在不在往复（RhythmOutput.motionActivity）；
    /// cut：这一拍的画面窗口有切镜；audioReady：音轨 tap 就绪
    mutating func beat(clock: MediaClockSnapshot, lock: RhythmPhaseLock, activity: Double, cut: Bool, audioReady: Bool,
                       dt: Double) -> AVFusionBeat {
        if framesThisBeat > 0 {
            timeInvalid = false
        } else if invalidThisBeat > 0 {
            timeInvalid = true
        }
        framesThisBeat = 0
        invalidThisBeat = 0
        var out = AVFusionBeat()
        let item = clock.item
        guard clock.isValid else {
            out.state = timeInvalid ? .noTime : .noAudio
            out.c = coupling.c
            out.coupled = coupling.coupled
            return out
        }
        let rate = clock.rate
        let ex = extractor
        let present = audioReady && !timeInvalid && ex.lastFrameTime.isFinite
            && ex.lastFrameTime >= item - Self.presenceSeconds * rate - 0.5
            && ex.lastLoudTime.isFinite && ex.lastLoudTime >= ex.lastFrameTime - Self.presenceSeconds
        if item - gridAt >= Self.gridEvery || item < gridAt {
            gridAt = item
            let end = ex.lastFrameTime.isFinite ? ex.lastFrameTime : item
            let start = max(end - AudioBeatGrid.windowSeconds, ex.firstFrameTime.isFinite ? ex.firstFrameTime : end)
            grid = AudioBeatGrid.estimate(ex.events, start: start, end: end)
        }
        let window = AVCouplingEstimator.windowSeconds * rate
        let from = item - window
        let to = item + 0.2 * rate
        let hits = ex.impacts(from: from, to: to)
        let rhythm = onsetDetector.rhythm()
        let steep = ex.steepness(from: from, to: to)
        let harmonicity = ex.harmonicity
        scene.step(item: item, cut: cut, grid: grid, onsets: ex.events, activity: activity,
                   rhythmConfidence: rhythm.confidence, harmonicity: harmonicity, steepness: steep, audioPresent: present, dt: dt)
        let fa = AVCouplingEstimator.impactHz(hits) * rate
        let fv = lock.locked && lock.hz > 0 ? lock.hz : 0
        let r = AVCouplingEstimator.concentration(hits.map { clock.host(forItem: $0) }, lock: lock)
        out.impacts = hits.count
        out.fa = fa
        out.fv = fv
        out.r = r
        out.af = AVCouplingEstimator.frequencyAgreement(audioHz: fa, visualHz: fv)
        out.ar = r.isFinite ? AVCouplingEstimator.concentrationScore(r) : 0
        out.an = AVCouplingEstimator.countScore(hits.count)
        out.pMusic = scene.pMusic
        out.pVoice = scene.pVoice
        var raw = out.af * out.ar * out.an * (1 - scene.pMusic) * (1 - scene.pVoice)
        if !present { raw = 0 }
        out.raw = AVCouplingEstimator.clamp01(raw)
        coupling.step(raw: out.raw, dt: dt, suspended: scene.cutTesting)
        out.c = coupling.c
        out.coupled = coupling.coupled
        out.crossCut = scene.crossCut
        out.still = scene.still
        out.grid = scene.grid
        out.harmonicity = harmonicity
        out.steepness = steep
        out.flatness = ex.flatness
        out.percussive = ex.percussive
        out.rhythmConfidence = rhythm.confidence
        if timeInvalid {
            out.state = .noTime
        } else if !present {
            out.state = .noAudio
        } else if scene.cutTesting {
            out.state = .cutTest
        } else if coupling.coupled {
            out.state = .coupled
        } else if scene.pMusic >= AVFusionBeat.musicLevel {
            out.state = .music
        } else if scene.pVoice >= AVFusionBeat.voiceLevel {
            out.state = .voice
        } else if !lock.locked {
            out.state = .noLock
        } else {
            out.state = .uncoupled
        }
        return out
    }
}

extension AVDebugColumns {
    /// av-fusion F1：融合开着时每拍的耦合度 / 证据（关着时整组空）
    static let f1Header = "av_state,av_c,av_c_raw,av_coupled,av_af,av_ar,av_an,av_r,av_impacts,av_fa,av_fv,"
        + "av_p_music,av_p_voice,av_cross_cut,av_still,av_grid,av_harmonicity,av_steepness,av_flatness,av_percussive,"
        + "av_rhythm_conf"

    static func f1Fields(_ b: AVFusionBeat) -> [String] {
        [b.state.rawValue, field(b.c, digits: 3), field(b.raw, digits: 3), b.coupled ? "1" : "0", field(b.af, digits: 3),
         field(b.ar, digits: 3), field(b.an, digits: 3), field(b.r, digits: 3), String(b.impacts), field(b.fa, digits: 3),
         field(b.fv, digits: 3), field(b.pMusic, digits: 3), field(b.pVoice, digits: 3), field(b.crossCut, digits: 2),
         field(b.still, digits: 2), field(b.grid, digits: 3), field(b.harmonicity, digits: 3), field(b.steepness, digits: 3),
         field(b.flatness, digits: 3), field(b.percussive, digits: 3), field(b.rhythmConfidence, digits: 3)]
    }

    static var f1Empty: [String] {
        [String](repeating: "", count: f1Header.split(separator: ",", omittingEmptySubsequences: false).count)
    }
}

// MARK: - av-fusion F2：节奏由声音确认（默认关）
// 开关 bcVisualSyncAVRhythmConfirm（VisualSyncSettings.avRhythmConfirm；usesAVRhythmConfirm = 融合 + 伸缩跟随动作频率 + 开关）。
// 画面为主、声音作证：频率 / 相位仍由画面（P1~P4）决定，声音只在已经证明和画面说的是同一件事（F1 的「耦合」）之后才说话，
// 而且只纠正、不发起——activity 只看画面（声音永远不能让静止的画面动起来）、声音不能开节奏锁，只能在画面已经有候选时加置信度 /
// 选八度 / 缩短跳变确认。每一拍按状态走（主线程，完整拍）：
//   S0 关（开关关 / 不在跟随画面）= main；S1 只有画面（不耦合 / 没声音 / 时间不可用 / 切镜考验）= 现在的跟随画面；
//   S2 耦合（上一拍融合状态 = coupled）= 画面结果 + 声音确认（AVRhythmVote）+ 撞击声校正的耦合条件。S2 → S1 单调退回。
// 只改交给 RhythmFollower / RhythmPhaseLock 的那份窗口副本（P4 前瞻之后、P3 动作识别之前，和 P3 / P4 同一个做法）
// 和跟随器这一拍的跳变确认拍数；不碰出口、不新增发送路径。

/// av-fusion F2：声音给画面节奏投票（主线程每个完整拍一次）。只在 S2（coupled：上一拍 AVFusionBeat.state == .coupled，
/// 即 C ≥ 0.6 持续 2 秒进入、时间可用、声音在场、没在切镜考验）而且这一拍有块运动节奏候选时才改窗口副本：
/// 1. 一致：声音节奏和画面跟随频率差 ≤ 15%（和 F1 的 A_f 同一个口径）→ subjectFollowRhythm + 0.1（夹 0~1）；
/// 2. 八度消歧：两边正好差 2 倍 / 一半（八度两边各 15%）、声音是干净的单一脉冲串 → 画面频率乘 2 / 除 2
///    （幅度按频率反比换算；按错的八度拟合的相位作废，相位锁等下一个读数；姿态和块运动同一个八度时一起换）。
///    声音节奏按「最短且 ≥ 最高峰 85%」取周期，只用来消歧、不发起。一下两响（往里 / 往外各一声）的风险：
///    两响强弱不同时按幅度加权的自相关落在整周期，和撞击间隔中位数（F1 的 f_a）差一个八度 → 不算干净、不管；
///    两响一样强时声音和画面本来就差一倍、F1 的 A_f = 0 进不了耦合（S2 只能在声音和画面同频时建立）；
/// 3. 跳频确认：跟随器锁着、画面读数偏离跟随频率 15% 以上、声音同方向也偏了 15% 以上、而且和画面读数差 ≤ 30% → fastJump，
///    fastJumpHz = 这个画面读数（声音核对过的目标）。跟随器只在它这一拍真正用的候选读数和目标同方向、差 ≤ 30% 时
///    才把跳变确认从 2 拍缩到 1 拍（RhythmFollower.step(fastJumpHz:)；复审 M2：跟随器挑了姿态读数时声音没核对过，不缩）。
///    声音这边看同一个对齐窗口里最后 4 下撞击的间隔中位数（4 秒自相关要攒够新节奏才换峰，比画面晚；跳了多少仍要 ≥ 30% 才跳，
///    由跟随器自己判断）。
/// 声音的 4 秒窗口和画面 followEstimate 的 4 秒窗口按播放器时钟对齐：画面窗口的终点 = 最后一个相位拟合的时刻（没有时 = 现在），
/// 换成视频时间后往前 4 秒 × 倍速。enabled == false / 不在 S2 / 条件不满足时窗口原样交回（== 而且位模式相同）、fastJump = false
struct AVRhythmVote {
    enum Action: String {
        case none
        case agree
        case octaveUp = "octave_up"
        case octaveDown = "octave_down"
    }

    static let agreeRatio: Double = AVCouplingEstimator.agreeRatio
    static let confidenceBonus: Double = RhythmFollower.agreeBonus
    /// 声音节奏的自相关峰低于这个不投票
    static let minAudioConfidence: Double = 0.3
    /// 跳频确认：声音和画面这一拍的读数差 ≤ 30%（= 跟随器的 jumpRatio）
    static let jumpSpread: Double = RhythmFollower.jumpRatio
    /// 和 StrokeRhythm 的窗口同长
    static let windowSeconds: Double = StrokeRhythm.window
    static let bin: Double = 0.01
    static let harmonicShare: Double = AudioBeatGrid.harmonicShare
    static let minImpacts = 3
    static let recentImpacts = 4

    private(set) var action = Action.none
    private(set) var fastJump = false
    /// fastJump 时声音核对过的跳变目标（画面这一拍的读数，Hz；没有 0）→ RhythmFollower.step(fastJumpHz:)
    private(set) var fastJumpHz: Double = 0
    /// 这一拍声音节奏（host 时间上的 Hz，已乘倍速；没有 0）/ 自相关峰 / 最近几下撞击间隔的频率（跳频方向用）
    private(set) var audioHz: Double = 0
    private(set) var recentHz: Double = 0
    private(set) var audioConfidence: Double = 0
    /// 声音节奏和撞击间隔中位数一致（单一脉冲串）
    private(set) var clean = false
    private(set) var active = false

    mutating func reset() {
        self = AVRhythmVote()
    }

    /// 最近一段（视频时间 start ~ end）的撞击（isImpact）按强度做成脉冲串（σ = 1.5 格的高斯），归一化自相关在 0.4~4 Hz 里
    /// 找局部峰，取最短的、不低于最高峰 85% 的那个，抛物线细化。返回视频时间上的 Hz 和那个峰（不够 3 次撞击 / 窗口不到 2 秒 0）
    static func audioRhythm(_ events: [AudioOnsetEvent], start: Double, end: Double) -> (hz: Double, confidence: Double) {
        guard start.isFinite, end.isFinite, end - start >= 2 else { return (0, 0) }
        let hits = impacts(events, start: start, end: end)
        guard hits.count >= minImpacts else { return (0, 0) }
        let n = Int(((end - start) / bin).rounded(.up)) + 1
        var sig = [Double](repeating: 0, count: n)
        let sigma = 1.5
        for e in hits {
            // 按幅度加权：strength 是各段上升 dB 之和，换成每段平均上升的幅度倍数（一下两响差 12 dB ≈ 4 倍；直接用 dB 只差 1.4 倍）
            let weight = pow(10, e.strength / Double(AudioFeatureFrame.bandCount) / 20)
            let c = (e.time - start) / bin
            let lo = max(0, Int((c - 4 * sigma).rounded(.down)))
            let hi = min(n - 1, Int((c + 4 * sigma).rounded(.up)))
            guard lo <= hi else { continue }
            for k in lo...hi {
                let d = (Double(k) - c) / sigma
                sig[k] += weight * exp(-0.5 * d * d)
            }
        }
        var mean = 0.0
        for v in sig { mean += v }
        mean /= Double(n)
        var r0 = 0.0
        for k in 0..<n {
            sig[k] -= mean
            r0 += sig[k] * sig[k]
        }
        guard r0.isFinite, r0 > 1e-12 else { return (0, 0) }
        let minLag = Int((1 / RhythmFollower.hzRange.upperBound / bin).rounded(.down))
        let maxLag = min(n / 2, Int((1 / RhythmFollower.hzRange.lowerBound / bin).rounded(.up)))
        guard maxLag > minLag + 2, maxLag + 1 < n else { return (0, 0) }
        var corr = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var s = 0.0
            for k in 0..<(n - lag) { s += sig[k] * sig[k + lag] }
            corr[lag] = s / r0 * Double(n) / Double(n - lag)
        }
        var best = 0.0
        var bestLag = 0
        for lag in minLag...maxLag where corr[lag] > best && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            best = corr[lag]
            bestLag = lag
        }
        guard bestLag > 0 else { return (0, 0) }
        for lag in minLag..<bestLag where corr[lag] >= harmonicShare * best
            && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            bestLag = lag
            break
        }
        let a = corr[bestLag - 1]
        let b = corr[bestLag]
        let c = corr[bestLag + 1]
        let den = a - 2 * b + c
        let offset = den < -1e-12 ? min(0.5, max(-0.5, 0.5 * (a - c) / den)) : 0
        let hz = 1 / ((Double(bestLag) + offset) * bin)
        return hz.isFinite ? (hz, MotionStats.clamp01(b)) : (0, 0)
    }

    /// 窗口（视频时间 start ~ end）里的撞击（旧 → 新）
    static func impacts(_ events: [AudioOnsetEvent], start: Double, end: Double) -> [AudioOnsetEvent] {
        events.filter { $0.isImpact && $0.time > start && $0.time <= end && $0.strength.isFinite && $0.strength > 0 }
    }

    /// 跳频确认看的声音读数：同一个对齐窗口里最后 recentImpacts 次撞击的间隔中位数（视频时间上的 Hz；不够 0）。
    /// 4 秒自相关在跳频后要攒够新节奏才换峰（比画面的 followEstimate 晚），方向只看窗口末尾最新的几下
    static func recentHz(_ events: [AudioOnsetEvent], start: Double, end: Double) -> Double {
        AVCouplingEstimator.impactHz(impacts(events, start: start, end: end).suffix(recentImpacts).map { $0.time })
    }

    /// 每个完整拍、P4 前瞻之后、P3 动作识别之前。coupled：上一拍融合状态是不是 .coupled（S2）；events：融合的起音（视频时间）；
    /// impactHz：上一拍 F1 的 f_a（撞击间隔中位数 × 倍速，干净度判断用）；clock：这一拍的播放器时钟；
    /// followerHz / followerLocked：跟随器上一拍的结果（跳频确认用）
    mutating func refine(_ w: MotionWindow, enabled: Bool, coupled: Bool, events: [AudioOnsetEvent], impactHz: Double,
                         clock: MediaClockSnapshot, followerHz: Double, followerLocked: Bool) -> MotionWindow {
        guard enabled else {
            if active || action != .none || fastJump || audioHz != 0 || recentHz != 0 { reset() }
            return w
        }
        active = true
        action = .none
        fastJump = false
        fastJumpHz = 0
        audioHz = 0
        audioConfidence = 0
        recentHz = 0
        clean = false
        let vf = w.subjectFollowHz
        guard coupled, clock.isValid, w.frames > 0, w.cutCount == 0, w.heldCount == 0, w.subjectFrames > 0,
              vf.isFinite, RhythmFollower.hzRange.contains(vf), w.subjectFollowRhythm.isFinite, w.subjectFollowRhythm > 0
        else { return w }
        let endHost = w.subjectPhase.isValid ? w.subjectPhase.time : clock.host
        let end = clock.item(forHost: endHost)
        let start = end - Self.windowSeconds * clock.rate
        let r = Self.audioRhythm(events, start: start, end: end)
        let ha = r.hz * clock.rate
        let hr = Self.recentHz(events, start: start, end: end) * clock.rate
        recentHz = hr.isFinite ? hr : 0
        let tol = log(1 + Self.agreeRatio)
        var out = w
        if ha.isFinite, ha > 0, r.confidence >= Self.minAudioConfidence {
            audioHz = ha
            audioConfidence = r.confidence
            clean = impactHz.isFinite && impactHz > 0 && abs(log(ha / impactHz)) <= tol
        }
        let d = audioHz > 0 ? log(audioHz / vf) : Double.infinity
        if abs(d) <= tol {
            out.subjectFollowRhythm = MotionStats.clamp01(w.subjectFollowRhythm + Self.confidenceBonus)
            action = .agree
        } else if clean, abs(abs(d) - log(2)) <= tol {
            let k: Double = d > 0 ? 2 : 0.5
            out.subjectFollowHz = vf * k
            out.subjectFollowAmplitude = w.subjectFollowAmplitude / k
            out.subjectPhase = StrokeRhythm.PhaseFit()
            if w.posePresentFrames > 0, w.poseRhythmHz.isFinite, w.poseRhythmHz > 0, abs(log(w.poseRhythmHz / vf)) <= tol {
                out.poseRhythmHz = w.poseRhythmHz * k
                out.posePhase = StrokeRhythm.PhaseFit()
            }
            action = d > 0 ? .octaveUp : .octaveDown
        }
        let hv = out.subjectFollowHz
        if followerLocked, followerHz.isFinite, followerHz > 0, recentHz > 0 {
            let dv = log(hv / followerHz)
            let da = log(recentHz / followerHz)
            fastJump = abs(dv) > tol && abs(da) > tol && (dv > 0) == (da > 0)
                && abs(log(recentHz / hv)) <= log(1 + Self.jumpSpread)
            if fastJump { fastJumpHz = hv }
        }
        return out
    }

    var statusText: String {
        switch action {
        case .none:
            return fastJump ? "节奏确认：声音同方向跳了，跳频只确认 1 拍" : "节奏确认：没有投票（只看画面）"
        case .agree:
            return String(format: "节奏确认：声音 %.2f 次/秒和画面一致，置信 +0.1%@", audioHz, fastJump ? "，跳频只确认 1 拍" : "")
        case .octaveUp, .octaveDown:
            return String(format: "节奏确认：画面读成了%@，按声音 %.2f 次/秒改成%@", action == .octaveUp ? "一半" : "两倍", audioHz,
                          action == .octaveUp ? "两倍" : "一半")
        }
    }
}

extension AVDebugColumns {
    /// av-fusion F2：节奏由声音确认（开关关着时整组空）
    static let f2Header = "av_vote,av_vote_hz,av_vote_conf,av_vote_clean,av_fast_jump"

    static func f2Fields(_ v: AVRhythmVote) -> [String] {
        [v.action.rawValue, field(v.audioHz, digits: 3), field(v.audioConfidence, digits: 3), v.clean ? "1" : "0",
         v.fastJump ? "1" : "0"]
    }

    static var f2Empty: [String] {
        [String](repeating: "", count: f2Header.split(separator: ",", omittingEmptySubsequences: false).count)
    }
}
