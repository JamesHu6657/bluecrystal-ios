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
                address(medianScratch)]
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
                swap(&cellSums, &cellSumsAlt)
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
        if isCut {
            // 不出尖峰，也不突然掉到 0
            out = median(within: Self.substituteWindow, now: time)
            holdRemaining = Self.holdSamples
            noteCutForBackground(sharpness: sharp, gap: gap)
        } else if holdRemaining > 0 {
            out = median(within: Self.substituteWindow, now: time)
            holdRemaining -= 1
            held = true
            noteCutForBackground(sharpness: sharp, gap: gap)
        } else {
            record(energy, at: time)
            var soft = false
            if suspectValid {
                soft = isSoftCut(pixels, mean: mean, sharpness: sharp, jump: jump, distance: distance, energy: energy)
            }
            near = updateNearField(coverage: coverage, sharpness: sharp, shift: shift, gap: gap, softCut: soft)
        }
        remember(pixels, width: w, height: h, mean: mean, sharpness: sharp, time: time)
        return MotionSample(time: time, energy: out, coverage: coverage, isCut: isCut, isHeld: held, nearField: near)
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
        return MotionSample(time: time, energy: out, coverage: 0, isCut: false, isHeld: held)
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

    mutating func add(_ s: MotionSample) {
        guard s.energy.isFinite, s.energy >= 0 else { return }
        sum += s.energy
        if s.coverage.isFinite { coverageSum += min(1, max(0, s.coverage)) }
        if s.nearField.isFinite { nearSum += min(1, max(0, s.nearField)) }
        peak = max(peak, s.energy)
        frames += 1
        if s.isCut { cutCount += 1 }
        if s.isHeld { heldCount += 1 }
    }

    mutating func drain() -> MotionWindow {
        let window = frames > 0
            ? MotionWindow(meanEnergy: sum / Double(frames), peakEnergy: peak, frames: frames,
                           cutCount: cutCount, heldCount: heldCount,
                           coverage: coverageSum / Double(frames), nearField: nearSum / Double(frames))
            : .empty
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

    private(set) var refHigh: Double = MotionNormalizer.initialHigh
    private(set) var refLow: Double = MotionNormalizer.initialLow
    private(set) var warmElapsed: TimeInterval = 0

    /// 热身置信度：换视频后 3 秒内从 0 线性升到 1（只会让输出偏低，安全方向）
    var confidence: Double { min(1, max(0, warmElapsed / Self.warmUpSeconds)) }

    /// 暂停 / seek：平滑状态在 MotionShaper；参考值和热身保留（照 AudioReactiveShaper.reset 不清 refDb）
    mutating func reset() {}

    /// 换视频：重新学习运动范围、重新热身
    mutating func resetAdaptation() {
        refHigh = Self.initialHigh
        refLow = Self.initialLow
        warmElapsed = 0
    }

    mutating func step(_ w: MotionWindow, gainDb: Double, auto: Bool, dt: TimeInterval) -> Double {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : AudioReactiveShaper.interval
        guard w.frames > 0 else { return 0 }
        warmElapsed = min(Self.warmUpSeconds, warmElapsed + step)
        let e = w.representative
        guard e.isFinite, e >= Self.absoluteGate else { return 0 }
        let l = log(1 + e)
        // 开关关着也一直学：中途打开自动适应时参考值已经是这个视频的（同声音侧）
        let near = w.nearField.isFinite ? min(1, max(0, w.nearField)) : 0
        // 手贴镜头 / 大面积遮挡不训练「这个视频平时动多大」，否则之后真正的动作会被压低
        if w.settled, near < Self.nearFieldLearnLimit, l.isFinite {
            let highTau = l > refHigh ? Self.highRiseSeconds : Self.highFallSeconds
            refHigh += (l - refHigh) * (1 - exp(-step / highTau))
            refHigh = max(Self.minHigh, refHigh)
            let lowTau = l < refLow ? Self.lowFallSeconds : Self.lowRiseSeconds
            refLow += (l - refLow) * (1 - exp(-step / lowTau))
            if !refHigh.isFinite || !refLow.isFinite { resetAdaptation() }
        }
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
