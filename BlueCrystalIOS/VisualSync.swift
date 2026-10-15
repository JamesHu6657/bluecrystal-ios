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
        let cols = columnTaps
        let rows = rowOffsets
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

    private var previous: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0
    private var previousMean: Double = 0
    private var previousHistogram: [Double] = []
    private var previousTime: Double?
    private var holdRemaining = 0
    private var historyTimes: [Double] = []
    private var historyEnergies: [Double] = []
    private var cellWidth = 0
    private var cellHeight = 0
    private var cellOf: [Int] = []
    private var cellPixels: [Double] = []

    var hasReference: Bool { previousTime != nil }

    /// 丢掉参考帧和历史（seek / 开播 / 不连续）：下一帧只当参考帧
    mutating func reset() {
        previousTime = nil
        previous = []
        previousHistogram = []
        holdRemaining = 0
        historyTimes.removeAll(keepingCapacity: true)
        historyEnergies.removeAll(keepingCapacity: true)
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
        var histogram = [Double](repeating: 0, count: Self.histogramBins)
        var sum = 0
        for p in pixels {
            sum += Int(p)
            histogram[Int(p) >> 4] += 1
        }
        let inv = 1 / Double(n)
        for b in 0..<Self.histogramBins { histogram[b] *= inv }
        let mean = Double(sum) * inv

        guard let lastTime = previousTime, previousWidth == w, previousHeight == h, previous.count == n,
              previousHistogram.count == Self.histogramBins, Self.gapRange.contains(time - lastTime) else {
            reset()
            remember(pixels, width: w, height: h, mean: mean, histogram: histogram, time: time)
            return nil
        }
        let gap = time - lastTime
        if cellWidth != w || cellHeight != h { buildCells(width: w, height: h) }

        // 去均值帧差 + 噪声门：整体变亮变暗（闪光、渐变、自动曝光）几乎没有贡献
        let prev = previous
        let cells = cellOf
        let prevMean = previousMean
        let gate = Self.noiseGate
        let (dx, dy) = Self.globalShift(pixels, mean: mean, previous: prev, previousMean: prevMean,
                                        width: w, height: h, cells: cells)
        var cellSums = [Double](repeating: 0, count: Self.gridColumns * Self.gridRows)
        var total = 0.0
        var valid = 0
        for y in 0..<h {
            let py = y - dy
            guard py >= 0, py < h else { continue }
            for x in 0..<w {
                let px = x - dx
                guard px >= 0, px < w else { continue }
                let i = y * w + x
                valid += 1
                let d = (Double(pixels[i]) - mean) - (Double(prev[py * w + px]) - prevMean)
                let e = abs(d) - gate
                if e > 0 {
                    total += e
                    cellSums[cells[i]] += e
                }
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
        if isCut {
            // 不出尖峰，也不突然掉到 0
            out = median(within: Self.substituteWindow, now: time)
            holdRemaining = Self.holdSamples
        } else if holdRemaining > 0 {
            out = median(within: Self.substituteWindow, now: time)
            holdRemaining -= 1
            held = true
        } else {
            record(energy, at: time)
        }
        remember(pixels, width: w, height: h, mean: mean, histogram: histogram, time: time)
        return MotionSample(time: time, energy: out, coverage: coverage, isCut: isCut, isHeld: held)
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
    /// 只在大半格子有变化时才搜；对齐后差异要明显更小才采用，否则 (0, 0)（和不补偿逐位相同）
    static func globalShift(_ cur: [UInt8], mean: Double, previous prev: [UInt8], previousMean: Double,
                            width w: Int, height h: Int, cells: [Int]) -> (Int, Int) {
        let r = maxShift
        guard w > 2 * r + 4, h > 2 * r + 4, cur.count == w * h, prev.count == w * h, cells.count == w * h else {
            return (0, 0)
        }
        let cellCount = gridColumns * gridRows
        var cellDiff = [Double](repeating: 0, count: cellCount)
        var cellN = [Double](repeating: 0, count: cellCount)
        var zero = 0.0
        var samples = 0
        var y = r
        while y < h - r {
            var x = r
            while x < w - r {
                let i = y * w + x
                let d = abs((Double(cur[i]) - mean) - (Double(prev[i]) - previousMean))
                zero += d
                cellDiff[cells[i]] += d
                cellN[cells[i]] += 1
                samples += 1
                x += 2
            }
            y += 2
        }
        guard samples > 0, zero / Double(samples) > noiseGate else { return (0, 0) }
        var changed = 0
        var counted = 0
        for c in 0..<cellCount where cellN[c] > 0 {
            counted += 1
            if cellDiff[c] / cellN[c] > noiseGate { changed += 1 }
        }
        guard counted > 0, Double(changed) / Double(counted) > shiftChangedCells else { return (0, 0) }
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
        return best < zero * shiftAcceptRatio ? bestShift : (0, 0)
    }

    private mutating func remember(_ pixels: [UInt8], width: Int, height: Int, mean: Double,
                                   histogram: [Double], time: Double) {
        previous = pixels
        previousWidth = width
        previousHeight = height
        previousMean = mean
        previousHistogram = histogram
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
    private func median(within window: Double, now: Double) -> Double {
        var values: [Double] = []
        for i in 0..<historyTimes.count where now - historyTimes[i] <= window {
            values.append(historyEnergies[i])
        }
        guard !values.isEmpty else { return 0 }
        values.sort()
        let m = values.count / 2
        return values.count % 2 == 1 ? values[m] : (values[m - 1] + values[m]) / 2
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

    mutating func add(_ s: MotionSample) {
        guard s.energy.isFinite, s.energy >= 0 else { return }
        sum += s.energy
        peak = max(peak, s.energy)
        frames += 1
        if s.isCut { cutCount += 1 }
        if s.isHeld { heldCount += 1 }
    }

    mutating func drain() -> MotionWindow {
        let window = frames > 0
            ? MotionWindow(meanEnergy: sum / Double(frames), peakEnergy: peak, frames: frames,
                           cutCount: cutCount, heldCount: heldCount)
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
        if w.settled, l.isFinite {
            let highTau = l > refHigh ? Self.highRiseSeconds : Self.highFallSeconds
            refHigh += (l - refHigh) * (1 - exp(-step / highTau))
            refHigh = max(Self.minHigh, refHigh)
            let lowTau = l < refLow ? Self.lowFallSeconds : Self.lowRiseSeconds
            refLow += (l - refLow) * (1 - exp(-step / lowTau))
            if !refHigh.isFinite || !refLow.isFinite { resetAdaptation() }
        }
        let fixedRatio = (l - Self.fixedLow) / (Self.fixedHigh - Self.fixedLow)
        var ratio = fixedRatio
        if auto {
            let hi = refHigh
            let lo = min(refLow, hi - Self.minSpan)
            let span = max(Self.minSpan, hi - lo)
            // 自动部分最多到满刻度：超出这个视频平时范围的瞬间（手贴镜头）只能靠固定尺度往上走
            let adaptive = min(1, (l - lo) / span)
            ratio = Self.adaptiveWeight * adaptive + (1 - Self.adaptiveWeight) * fixedRatio
        }
        let clampedGain = gainDb.isFinite
            ? min(VisualSyncSettings.motionGainRange.upperBound, max(VisualSyncSettings.motionGainRange.lowerBound, gainDb))
            : 0
        let g = pow(10, clampedGain / 20)
        let out = ratio * g * Self.targetPercent
        return out.isFinite ? min(100, max(0, out)) : 0
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
