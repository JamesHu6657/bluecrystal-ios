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
        if k >= Self.minCameraBlocks {
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
            normalFlow[b] = nf.isFinite ? min(Self.maxNormalFlow, nf) : 0
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
        var v = -r
        while v <= r {
            var u = -r
            while u <= r {
                if u != 0 || v != 0 {
                    let c = maskedCost(cur: cur, prev: prev, width: w, height: h, count: m, u: u, v: v)
                        + penalty * Double(u * u + v * v)
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

    struct Estimate: Equatable {
        var hz: Double = 0
        var confidence: Double = 0
        var amplitude: Double = 0
    }

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

    var scratchAddresses: [Int] {
        func address<T>(_ a: [T]) -> Int { a.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) } }
        return [address(times), address(xs), address(ys), address(projected), address(projectedTimes),
                address(grid), address(corr)]
    }

    mutating func reset() {
        count = 0
        head = 0
        estimate = Estimate()
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
        estimate = compute(now: t)
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
        var pick = bestK
        for k in Self.minLag...kMax where corr[k] >= corr[k - 1] && corr[k] >= corr[k + 1]
            && corr[k] >= Self.octaveShare * best {
            pick = k
            break
        }
        let a = corr[pick - 1]
        let b = corr[pick]
        let cc = corr[pick + 1]
        let den = a - 2 * b + cc
        let delta = den < -1e-12 ? min(0.5, max(-0.5, 0.5 * (a - cc) / den)) : 0
        let lag = Double(pick) + delta
        let hz = Self.gridRate / lag
        let amplitude = 2.0.squareRoot() * rms / (2 * Double.pi * hz)
        guard hz.isFinite, amplitude.isFinite else { return Estimate() }
        return Estimate(hz: hz, confidence: MotionStats.clamp01(b), amplitude: amplitude)
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
    /// 人体姿态：躯干长度 / 秒；幅度：躯干长度
    static let poseSpeedLow: Double = 0.12
    static let poseSpeedHigh: Double = 2.2
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
        reading = SubjectReading(valid: true, score: StrokeScore.flow(speed: p, rhythm: est), speed: p,
                                 hz: est.hz, rhythm: est.confidence, amplitude: est.amplitude)
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
    static let capacity = 24
    static let groups: [[PoseJoint]] = [[.nose, .neck], [.leftShoulder, .rightShoulder], [.root, .leftHip, .rightHip],
                                        [.leftKnee, .rightKnee], [.leftWrist, .rightWrist]]
    static let groupWeights: [Double] = [1.0, 0.7, 1.0, 0.6, 0.35]
    static let headGroup = 0
    static let hipGroup = 2

    private var previous = PoseCandidate()
    private var hasPrevious = false
    private var previousTime: Double = 0
    private var scale: Double = 0
    private var ux = [Double](repeating: 0, count: PoseJoint.count)
    private var uy = [Double](repeating: 0, count: PoseJoint.count)
    private var usable = [Bool](repeating: false, count: PoseJoint.count)
    private var sortX = [Double](repeating: 0, count: PoseJoint.count)
    private var sortY = [Double](repeating: 0, count: PoseJoint.count)
    private var speedTimes = [Double](repeating: 0, count: PoseMotionTracker.capacity)
    private var speeds = [Double](repeating: 0, count: PoseMotionTracker.capacity)
    private var scratch = [Double](repeating: 0, count: PoseMotionTracker.capacity)
    private var speedCount = 0
    private var speedHead = 0
    private var hips = StrokeRhythm()
    private var head = StrokeRhythm()
    private(set) var reading = PoseReading()

    mutating func reset() {
        hasPrevious = false
        scale = 0
        speedCount = 0
        speedHead = 0
        hips.reset()
        head.reset()
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

    private func select(_ candidates: [PoseCandidate], camera: CameraTransform, continuous: Bool,
                        frameHeight: Double) -> Int? {
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
        if let i = nearIndex, nearDistance <= Self.continuityLimit { return i }
        return bestIndex
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
        guard let pick = select(candidates, camera: cam, continuous: continuous, frameHeight: frameHeight) else {
            hasPrevious = false
            return absent(time)
        }
        let person = candidates[pick]
        let size = Self.bodyScale(person, frameHeight: frameHeight)
        let dt = time - previousTime
        let linked = hasPrevious && continuous && dt > Self.minGap && dt <= Self.maxGap && scale > 0
        if linked {
            scale += (size - scale) * (1 - exp(-dt / Self.scaleSeconds))
            var n = 0
            for j in 0..<PoseJoint.count {
                usable[j] = false
                guard person.c[j] >= Self.minJointConfidence, previous.c[j] >= Self.minJointConfidence else { continue }
                let p = cam.apply(x: previous.x[j], y: previous.y[j])
                let vx = (person.x[j] - p.x) / scale / dt
                let vy = (person.y[j] - p.y) / scale / dt
                guard vx.isFinite, vy.isFinite, (vx * vx + vy * vy).squareRoot() <= Self.maxJointSpeed else { continue }
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
                }
                pushSpeed(time: time, speed: speed)
            }
        } else {
            scale = size
            // 断过（seek / 切镜）或者人丢了超过 1 秒：节奏重新攒；短暂丢失（检测一闪）不清
            if !continuous || !(time - previousTime <= Self.rhythmGapLimit) {
                hips.reset()
                head.reset()
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
        let byHips = StrokeScore.pose(speed: p80, rhythm: hips.estimate)
        let byHead = StrokeScore.pose(speed: p80, rhythm: head.estimate)
        let score = max(byHips, byHead)
        reading = PoseReading(time: time, present: true, score: MotionStats.clamp01(score),
                              confidence: MotionStats.clamp01(person.confidence),
                              hz: byHips >= byHead ? hips.estimate.hz : head.estimate.hz)
        return reading
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
/// 没人 0.9 秒内保持上一次的姿态分数，权重 1 秒升到最多 0.8、1.5 秒降回 0（检测一闪一闪不出尖峰）
struct PoseBlend {
    static let confirmSeconds: TimeInterval = 0.55
    static let holdSeconds: TimeInterval = 0.9
    static let rampUpSeconds: TimeInterval = 1.0
    static let rampDownSeconds: TimeInterval = 1.5
    static let maxWeight: Double = 0.8

    private(set) var weight: Double = 0
    private(set) var heldScore: Double = 0
    private var heldConfidence: Double = 0
    private var presentRun: TimeInterval = 0
    private var absentRun: TimeInterval = .infinity

    mutating func reset() {
        self = PoseBlend()
    }

    mutating func step(_ w: MotionWindow, flow: Double, dt: TimeInterval) -> Double {
        let flow = MotionStats.clamp01(flow)
        if w.posePresentFrames > 0, w.poseScore.isFinite {
            presentRun += dt
            absentRun = 0
            heldScore = MotionStats.clamp01(w.poseScore)
            heldConfidence = MotionStats.clamp01(w.poseConfidence)
        } else {
            absentRun += dt
            if absentRun > Self.holdSeconds { presentRun = 0 }
        }
        let confFactor = 0.5 + 0.5 * MotionStats.clamp01((heldConfidence - 0.3) / 0.3)
        let target = presentRun >= Self.confirmSeconds && absentRun <= Self.holdSeconds ? Self.maxWeight * confFactor : 0
        let rate = Self.maxWeight / (target > weight ? Self.rampUpSeconds : Self.rampDownSeconds)
        if target > weight {
            weight = min(target, weight + rate * dt)
        } else {
            weight = max(target, weight - rate * dt)
        }
        if !weight.isFinite { weight = 0 }
        return MotionStats.clamp01(weight * heldScore + (1 - weight) * flow)
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

    mutating func add(_ s: MotionSample) {
        guard s.energy.isFinite, s.energy >= 0 else { return }
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
        }
    }

    /// 一次姿态估计（algo-opt-3）：只记次数和最后一次有人时的分数（姿态本身已经按 1.2 秒平滑）
    mutating func addPose(_ r: PoseReading) {
        poseFrames += 1
        guard r.present, r.score.isFinite, r.confidence.isFinite else { return }
        posePresentFrames += 1
        poseScore = min(1, max(0, r.score))
        poseConfidence = min(1, max(0, r.confidence))
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
            }
        }
        window.poseFrames = poseFrames
        window.posePresentFrames = posePresentFrames
        window.poseScore = poseScore
        window.poseConfidence = poseConfidence
        self = MotionWindowAccumulator()
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

    private(set) var refHigh: Double = MotionNormalizer.initialHigh
    private(set) var refLow: Double = MotionNormalizer.initialLow
    private(set) var warmElapsed: TimeInterval = 0
    /// 主体分数的参考值（algo-opt-3；同 refHigh / refLow 的快升慢降 / 快降慢升）
    private(set) var scoreHigh: Double = MotionNormalizer.subjectInitialHigh
    private(set) var scoreLow: Double = MotionNormalizer.subjectInitialLow
    private(set) var pose = PoseBlend()

    /// 热身置信度：换视频后 3 秒内从 0 线性升到 1（只会让输出偏低，安全方向）
    var confidence: Double { min(1, max(0, warmElapsed / Self.warmUpSeconds)) }
    /// 姿态在融合里的权重 0~0.8（界面提示「已识别人体」用）
    var poseWeight: Double { pose.weight }

    /// 暂停 / seek：平滑状态在 MotionShaper；参考值和热身保留（照 AudioReactiveShaper.reset 不清 refDb）。
    /// 姿态融合从头确认（algo-opt-3：seek 后可能已经不是同一个人）
    mutating func reset() {
        pose.reset()
    }

    /// 换视频：重新学习运动范围、重新热身
    mutating func resetAdaptation() {
        refHigh = Self.initialHigh
        refLow = Self.initialLow
        warmElapsed = 0
        scoreHigh = Self.subjectInitialHigh
        scoreLow = Self.subjectInitialLow
        pose.reset()
    }

    mutating func step(_ w: MotionWindow, gainDb: Double, auto: Bool, dt: TimeInterval) -> Double {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        guard w.frames > 0 else { return 0 }
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
        var s = pose.step(w, flow: flow, dt: dt)
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
        var ratio = s
        if auto {
            let base = min(max(0, scoreLow), Self.subjectBaseLimit)
            ratio = max(0, (s - base) / (1 - base))
            let stretch = min(Self.subjectMaxStretch, max(1, Self.subjectTargetHigh / max(scoreHigh, 0.05)))
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
    }

    /// 默认跟随声音：老用户行为逐位不变
    static let defaultSource = VisualSyncSource.audio
    /// 画面灵敏度（dB）：-6（×0.5）~ +12（约 ×4）
    static let motionGainRange: ClosedRange<Double> = -6...12
    static let defaultMotionGainDb: Double = 0
    static let defaultAutoMotion = true

    var source: VisualSyncSource
    var motionGainDb: Double
    var autoMotion: Bool

    init(source: VisualSyncSource = defaultSource, motionGainDb: Double = defaultMotionGainDb,
         autoMotion: Bool = defaultAutoMotion) {
        self.source = source
        self.motionGainDb = motionGainDb.isFinite
            ? min(Self.motionGainRange.upperBound, max(Self.motionGainRange.lowerBound, motionGainDb))
            : Self.defaultMotionGainDb
        self.autoMotion = autoMotion
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
            autoMotion: defaults.object(forKey: Keys.autoMotion) as? Bool ?? defaultAutoMotion)
    }

    var gainMultiplier: Double { pow(10, motionGainDb / 20) }
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

    /// 暂停 / seek / 开播 / 换视频：基准回 0，第一次升高不推迟（设备这时已经停了）
    mutating func reset() {
        last = [0, 0, 0, 0]
        zeroAge = [Int](repeating: Self.zeroHoldTicks, count: 4)
    }

    /// 播放中切换来源：升幅从设备现在的实际输出算起（不一下跳高）；现在是 0 的通道照样保持两拍
    mutating func seed(_ levels: [Int]) {
        for ch in 0..<4 {
            let v = ch < 2 && ch < levels.count ? max(0, min(BCProtocol.maxManualLevel, levels[ch])) : 0
            last[ch] = v
            zeroAge[ch] = v > 0 ? Self.zeroHoldTicks : 0
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
        let target = s.channels.levels(percent: mapped)
        let cap = Self.hardCap(s)
        var out = [0, 0, 0, 0]
        for ch in 0..<2 {
            let prev = last[ch]
            var p = ch < target.count ? target[ch] : 0
            // 升幅限速：视频 tick 在 BLE 层没有升幅限制（OutputWriteCoalescer 只限 AI 帧）
            p = min(p, prev + Self.maxRisePerTick)
            // 归零保持：运行中的全零会换成完整停止帧对，频繁 0 ↔ 非 0 会让链路忙于停止
            if p > 0, prev == 0, zeroAge[ch] < Self.zeroHoldTicks { p = 0 }
            p = max(0, min(cap, p))
            if p == 0 {
                zeroAge[ch] = prev > 0 ? 0 : min(Self.zeroHoldTicks, zeroAge[ch] + 1)
            } else {
                zeroAge[ch] = Self.zeroHoldTicks
            }
            out[ch] = p
        }
        last = out
        return out
    }
}
