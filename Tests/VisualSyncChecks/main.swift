import Foundation

// 画面联动 P1 的纯逻辑检查：只编译纯类型（Protocol / Models / SafetyLedger / AIProgram）+ VisualSync.swift，
// 和 Round4Checks 同一套方式。每条失败打印 FAIL，最后有失败就以非零退出（PR Checks 据此判失败并把 FAIL 行写到 PR 上）

var vsFailures = 0
func vcheck(_ ok: Bool, _ name: String) {
    if ok {
        print("PASS \(name)")
    } else {
        vsFailures += 1
        print("FAIL \(name)")
    }
}

var vsSeed: UInt64 = 0xF00D
func vsRandom() -> Double {
    vsSeed = vsSeed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(vsSeed >> 11) / Double(1 << 53)
}

/// 源图：width × height，每行尾部 padding 个 0xEE（不该被读到）
func vsSource(width: Int, height: Int, padding: Int = 0, _ f: (Int, Int) -> UInt8) -> [UInt8] {
    let row = width + padding
    var bytes = [UInt8](repeating: 0xEE, count: row * height)
    for y in 0..<height {
        for x in 0..<width { bytes[y * row + x] = f(x, y) }
    }
    return bytes
}

func vsDownscale(_ bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> LumaFrame? {
    var scaler = LumaDownscaler()
    var frame = LumaFrame()
    let ok = bytes.withUnsafeBytes { raw in
        scaler.downscale(raw, width: width, height: height, bytesPerRow: bytesPerRow, into: &frame)
    }
    return ok ? frame : nil
}

/// 64×36 分析帧
func vsFrame(_ f: (Int, Int) -> UInt8) -> LumaFrame {
    var px = [UInt8](repeating: 0, count: 64 * 36)
    for y in 0..<36 {
        for x in 0..<64 { px[y * 64 + x] = f(x, y) }
    }
    return LumaFrame(width: 64, height: 36, pixels: px)
}

/// 背景 50、8×8 亮块 200（左上角 x = bx，y = 14）
func vsBlock(_ bx: Int) -> LumaFrame {
    vsFrame { x, y in
        let inside = x >= bx && x < bx + 8 && y >= 14 && y < 22
        return inside ? 200 : 50
    }
}

/// 确定性随机纹理，亮度在 lo...hi
func vsTexture(_ lo: Int, _ hi: Int) -> LumaFrame {
    vsFrame { _, _ in
        let v = lo + Int(vsRandom() * Double(hi - lo + 1))
        return UInt8(min(255, max(0, v)))
    }
}

let vsDt = 1.0 / 15

// MARK: - 降采样

let size169 = LumaDownscaler.outputSize(width: 1920, height: 1080)
vcheck(size169?.width == 64 && size169?.height == 36, "降采样：横屏 16:9 → 64×36")
let size916 = LumaDownscaler.outputSize(width: 1080, height: 1920)
vcheck(size916?.width == 36 && size916?.height == 64, "降采样：竖屏 9:16 → 36×64")
let sizeWide = LumaDownscaler.outputSize(width: 4000, height: 500)
vcheck(sizeWide?.width == 64 && sizeWide?.height == 18, "降采样：超宽画面短边不少于 18")
vcheck(LumaDownscaler.outputSize(width: 0, height: 10) == nil, "降采样：空尺寸不处理")

let flatSource = vsSource(width: 1280, height: 720, padding: 64) { _, _ in 77 }
if let flat = vsDownscale(flatSource, width: 1280, height: 720, bytesPerRow: 1344) {
    vcheck(flat.width == 64 && flat.height == 36 && flat.pixels.allSatisfy { $0 == 77 },
           "降采样：常数图 → 常数，行尾 padding 不读")
} else {
    vcheck(false, "降采样：常数图")
}

let gradientSource = vsSource(width: 640, height: 360, padding: 16) { x, _ in UInt8(x * 255 / 639) }
if let g = vsDownscale(gradientSource, width: 640, height: 360, bytesPerRow: 656) {
    let row0 = Array(g.pixels[0..<g.width])
    let monotonic = zip(row0, row0.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 }
    let ends = (row0.first ?? 255) < 12 && (row0.last ?? 0) > 243
    vcheck(monotonic && ends, "降采样：横向渐变保持单调、两端接近 0 / 255")
} else {
    vcheck(false, "降采样：渐变图")
}

let tinySource = vsSource(width: 10, height: 6) { _, _ in 90 }
if let tiny = vsDownscale(tinySource, width: 10, height: 6, bytesPerRow: 10) {
    vcheck(tiny.width == 64 && tiny.height == 38 && tiny.pixels.allSatisfy { $0 == 90 },
           "降采样：源图比目标小也不越界")
} else {
    vcheck(false, "降采样：小源图")
}

let tallSource = vsSource(width: 360, height: 640) { _, y in y < 320 ? 20 : 220 }
if let tall = vsDownscale(tallSource, width: 360, height: 640, bytesPerRow: 360) {
    vcheck(tall.width == 36 && tall.height == 64 && tall.pixels[0] == 20 && tall.pixels[tall.pixels.count - 1] == 220,
           "降采样：竖屏输出 36×64，上下不颠倒")
} else {
    vcheck(false, "降采样：竖屏")
}

vcheck(vsDownscale([UInt8](repeating: 0, count: 100), width: 64, height: 36, bytesPerRow: 64) == nil,
       "降采样：缓冲区不够大时拒绝")
vcheck(vsDownscale(flatSource, width: 1280, height: 720, bytesPerRow: 100) == nil, "降采样：bytesPerRow 小于宽度时拒绝")

// MARK: - 帧差

// 镜头平移 / 手持晃动：整幅有纹理的画面平移 2 像素 → 补偿后几乎没有能量；不补偿（小物体）照旧
func vsPanTex(_ x: Int, _ y: Int) -> UInt8 {
    let h = (x &* 73_856_093) ^ (y &* 19_349_663)
    return UInt8(40 + (h & 0x7fff_ffff) % 160)
}

do {
    var an = MotionAnalyzer()
    _ = an.analyze(vsFrame { x, y in vsPanTex(x, y) }, time: 0)
    let panned = an.analyze(vsFrame { x, y in vsPanTex(x - 2, y + 1) }, time: vsDt)
    let e = panned?.energy ?? 99
    vcheck(e < 0.5, "平移补偿：整幅画面平移 (2, −1) 像素 → 能量 < 0.5（得到 \(e)）")
    var raw = MotionAnalyzer()
    _ = raw.analyze(vsFrame { x, y in vsPanTex(x, y) }, time: 0)
    let changed = raw.analyze(vsFrame { x, y in vsPanTex(x + 37, y + 11) }, time: vsDt)
    vcheck((changed?.energy ?? 0) > 10, "平移补偿：画面整个换掉（对不齐）→ 能量照样大（\(changed?.energy ?? 0)）")
}

// VFR 静止段：没有新帧但播放头在走 → 零能量样本，参考帧保住
do {
    var an = MotionAnalyzer()
    vcheck(an.still(at: 0) == nil, "静止补样：没有参考帧时不补")
    _ = an.analyze(vsBlock(20), time: 0)
    let s1 = an.still(at: 0.3)
    vcheck(s1?.energy == 0 && s1?.isCut == false, "静止补样：0.3 s 没新帧 → 零能量样本")
    let s2 = an.still(at: 0.6)
    vcheck(s2 != nil && an.hasReference, "静止补样：连续补样不断档（参考时间跟着刷新）")
    vcheck(an.analyze(vsBlock(24), time: 0.7) != nil, "静止补样：之后的新帧直接出样本，不再当参考帧")
    vcheck(an.still(at: 2.0) == nil, "静止补样：断档超过 0.5 s 不补")
}

do {
    var an = MotionAnalyzer()
    vcheck(an.analyze(vsBlock(20), time: 0) == nil, "帧差：第一帧只当参考帧，没有样本")
    let same = an.analyze(vsBlock(20), time: vsDt)
    vcheck(same?.energy == 0 && same?.isCut == false, "帧差：相同两帧 → 能量 0")
    let moved = an.analyze(vsBlock(24), time: 2 * vsDt)
    let energy = moved?.energy ?? 0
    let coverage = moved?.coverage ?? 1
    vcheck(energy > 1 && coverage < 0.2 && coverage > 0, "帧差：8×8 方块移动 4 像素 → 能量 > 1、覆盖率 < 0.2（\(energy) / \(coverage)）")
}

do {
    var an = MotionAnalyzer()
    let base = vsTexture(40, 200)
    _ = an.analyze(base, time: 0)
    var noisy = base
    for i in 0..<noisy.pixels.count {
        noisy.pixels[i] = UInt8(Int(base.pixels[i]) + Int(vsRandom() * 7) - 3)
    }
    vcheck(an.analyze(noisy, time: vsDt)?.energy == 0, "帧差：±3 压缩噪声 → 能量 0（τ = 4）")
}

do {
    var an = MotionAnalyzer()
    let base = vsTexture(40, 200)
    _ = an.analyze(base, time: 0)
    var brighter = base
    for i in 0..<brighter.pixels.count { brighter.pixels[i] = base.pixels[i] + 40 }
    let s = an.analyze(brighter, time: vsDt)
    vcheck((s?.energy ?? 1) < 0.1 && s?.isCut == false, "帧差：整体亮度 +40 → 能量 < 0.1（去均值），不算切换")
}

do {
    var a1 = MotionAnalyzer()
    var a2 = MotionAnalyzer()
    var a3 = MotionAnalyzer()
    _ = a1.analyze(vsBlock(20), time: 0)
    _ = a2.analyze(vsBlock(20), time: 0)
    _ = a3.analyze(vsBlock(20), time: 0)
    let e1 = a1.analyze(vsBlock(24), time: vsDt)?.energy ?? -1
    let e2 = a2.analyze(vsBlock(24), time: 2 * vsDt)?.energy ?? -1
    let e3 = a3.analyze(vsBlock(24), time: 0.5 * vsDt)?.energy ?? -1
    vcheck(e1 > 0 && abs(e2 - e1 * 0.5) < 1e-9 && abs(e3 - e1 * 2) < 1e-9,
           "帧差：按拉帧间隔归一（隔一帧 ×0.5、半间隔 ×2）")
}

do {
    var an = MotionAnalyzer()
    _ = an.analyze(vsBlock(20), time: 0)
    vcheck(an.analyze(vsBlock(24), time: 0.8) == nil, "帧差：Δt = 0.8 s 视为不连续，只当新参考帧")
    vcheck(an.analyze(vsBlock(24), time: 0.8 + vsDt)?.energy == 0, "帧差：不连续之后和新参考帧做差")
    an.reset()
    vcheck(!an.hasReference && an.analyze(vsBlock(30), time: 0.8 + 2 * vsDt) == nil,
           "帧差：reset() 后第一帧不和 reset 前的帧做差")
    vcheck(an.analyze(vsBlock(30), time: 0.7) == nil, "帧差：时间倒退视为不连续")
}

// MARK: - 镜头切换 / 闪白

do {
    var an = MotionAnalyzer()
    _ = an.analyze(vsBlock(10), time: 0)
    var steady = 0.0
    for k in 1...14 {
        steady = an.analyze(vsBlock(10 + k), time: Double(k) * vsDt)?.energy ?? -1
    }
    vcheck(abs(steady - 16.0 * 146 / 2304) < 1e-9, "切换：移动方块每帧能量稳定（\(steady)）")
    let bright = vsTexture(130, 250)
    let cut = an.analyze(bright, time: 15 * vsDt)
    let cutOK = cut?.isCut == true && abs((cut?.energy ?? -1) - steady) < 1e-6
    vcheck(cutOK, "切换：硬切 → isCut，能量用最近 1 秒中位数（不出尖峰）")
    let h1 = an.analyze(bright, time: 16 * vsDt)
    let h2 = an.analyze(bright, time: 17 * vsDt)
    let h1OK = h1?.isHeld == true && abs((h1?.energy ?? -1) - steady) < 1e-6
    let h2OK = h2?.isHeld == true && abs((h2?.energy ?? -1) - steady) < 1e-6
    vcheck(h1OK && h2OK, "切换：之后 2 个样本也用中位数")
    let after = an.analyze(bright, time: 18 * vsDt)
    let afterOK = after?.energy == 0 && after?.isCut == false && after?.isHeld == false
    vcheck(afterOK, "切换：保持期过后和新镜头做差（静止 = 0）")
}

do {
    var an = MotionAnalyzer()
    _ = an.analyze(vsBlock(10), time: 0)
    var steady = 0.0
    for k in 1...10 {
        steady = an.analyze(vsBlock(10 + k), time: Double(k) * vsDt)?.energy ?? -1
    }
    let white = vsFrame { _, _ in 255 }
    let f1 = an.analyze(white, time: 11 * vsDt)
    let f2 = an.analyze(vsBlock(21), time: 12 * vsDt)
    let ok1 = f1?.isCut == true && abs((f1?.energy ?? -1) - steady) < 1e-6
    let ok2 = f2?.isCut == true && abs((f2?.energy ?? -1) - steady) < 1e-6
    vcheck(ok1 && ok2, "切换：闪白一帧再回来，两个样本都按切换处理")
}

// MARK: - 窗口

do {
    var acc = MotionWindowAccumulator()
    acc.add(MotionSample(time: 0, energy: 2, coverage: 0.1, isCut: false, isHeld: false))
    acc.add(MotionSample(time: 0.07, energy: 6, coverage: 0.1, isCut: false, isHeld: false))
    acc.add(MotionSample(time: 0.13, energy: 4, coverage: 0.1, isCut: true, isHeld: false))
    acc.add(MotionSample(time: 0.2, energy: .nan, coverage: 0, isCut: false, isHeld: false))
    acc.add(MotionSample(time: 0.25, energy: -1, coverage: 0, isCut: false, isHeld: false))
    let w = acc.drain()
    vcheck(w.frames == 3 && w.meanEnergy == 4 && w.peakEnergy == 6 && w.cutCount == 1 && !w.settled,
           "窗口：均值 / 峰值 / 切换计数，坏样本不进窗口")
    vcheck(abs(w.representative - (0.6 * 4 + 0.4 * 6)) < 1e-12, "窗口：代表值 0.6·mean + 0.4·peak")
    vcheck(acc.drain() == .empty && MotionWindow.empty.representative == 0, "窗口：取走后清零，空窗口代表值 0")
}

// MARK: - 归一化 / 平滑

func vsWindow(_ mean: Double, _ peak: Double? = nil) -> MotionWindow {
    MotionWindow(meanEnergy: mean, peakEnergy: peak ?? mean, frames: 4, cutCount: 0, heldCount: 0)
}

/// 归一化 + 平滑一拍（0.3 秒），返回乘过热身置信度的 0~100
struct VSChain {
    /// gentleAllowed = false：同 VideoSyncPlayer 在没有正面依据（轻抚 / 节奏只来自摸着自己的手）时的设法。
    /// 只在 actionTuned 时看；要测「有正面依据」的场景自己设 true
    var normalizer: MotionNormalizer = {
        var n = MotionNormalizer()
        n.gentleAllowed = false
        return n
    }()
    var shaper = MotionShaper()

    mutating func step(_ w: MotionWindow, auto: Bool = true, gainDb: Double = 0) -> Double {
        let target = normalizer.step(w, gainDb: gainDb, auto: auto, dt: 0.3)
        return normalizer.confidence * shaper.step(target: target, dt: 0.3).smoothed
    }
}

do {
    var c = VSChain()
    var peak = 0.0
    for _ in 0..<200 { peak = max(peak, c.step(vsWindow(0.2 + vsRandom() * 0.2))) }
    vcheck(peak == 0, "归一化：静止画面（e 0.2~0.4）60 秒输出恒 0")
}

do {
    var autoChain = VSChain()
    var fixedChain = VSChain()
    var a = 0.0
    var f = 0.0
    for _ in 0..<134 {
        a = autoChain.step(vsWindow(2.25))
        f = fixedChain.step(vsWindow(2.25), auto: false)
    }
    vcheck(a >= 35 && a <= 60, "归一化：小动作视频（e ≈ 2.25）适度放大到中档 35~60%（得到 \(Int(a))）")
    vcheck(f < a - 15, "归一化：关掉自动适应时小动作视频更低（\(Int(f)) vs \(Int(a))）")
}

do {
    var c = VSChain()
    var outs: [Double] = []
    for _ in 0..<134 {
        let m = 8 + vsRandom() * 12
        outs.append(c.step(vsWindow(m, m + vsRandom() * 4)))
    }
    let late = Array(outs.suffix(67))
    let lateMean = late.reduce(0, +) / Double(late.count)
    let pinned = outs.filter { $0 >= 99 }.count
    vcheck(lateMean >= 65, "归一化：大动作视频（e 8~20）动作段 ≥ 65%（后 20 秒均值 \(Int(lateMean))）")
    vcheck(pinned * 10 < outs.count, "归一化：大动作视频不长期顶在 100（≥ 99 的拍数 \(pinned)/\(outs.count)）")
}

do {
    var talk = VSChain()
    var walk = VSChain()
    var t = 0.0
    var w = 0.0
    for _ in 0..<134 {
        t = talk.step(vsWindow(0.8))
        w = walk.step(vsWindow(3.5))
    }
    vcheck(t < 15 && w >= 45, "归一化：讲话量级（e ≈ 0.8）远低于走动量级（e ≈ 3.5）（\(Int(t)) vs \(Int(w))）")
}

// 安静的片子里突然一个大动作（手贴镜头比耶）：不再顶到最强
do {
    var c = VSChain()
    for _ in 0..<100 { _ = c.step(vsWindow(0.8)) }
    var peak = 0.0
    for _ in 0..<5 { peak = max(peak, c.step(vsWindow(8))) }
    vcheck(peak >= 40 && peak <= 80, "归一化：安静片子里 1.5 秒的大动作落在 40~80%，不顶满（得到 \(Int(peak))）")
}
for e in [20.0, 40.0, 200.0] {
    var c = VSChain()
    for _ in 0..<100 { _ = c.step(vsWindow(0.8)) }
    var peak = 0.0
    for _ in 0..<5 { peak = max(peak, c.step(vsWindow(e))) }
    vcheck(peak <= 85, "归一化：安静片子里极端画面变化（e = \(Int(e))）0 dB 时不超过 85%（得到 \(Int(peak))）")
}

do {
    var n = MotionNormalizer()
    for _ in 0..<50 { _ = n.step(vsWindow(15), gainDb: 0, auto: true, dt: 0.3) }
    vcheck(n.refHigh > MotionNormalizer.initialHigh && n.confidence == 1, "归一化：参考值学到这个视频、热身已满")
    n.resetAdaptation()
    vcheck(n.refHigh == MotionNormalizer.initialHigh && n.refLow == MotionNormalizer.initialLow && n.confidence == 0,
           "换视频：参考值回初值、重新热身")
    var last = -1.0
    var monotonic = true
    for _ in 0..<10 {
        _ = n.step(vsWindow(3), gainDb: 0, auto: true, dt: 0.3)
        if n.confidence < last { monotonic = false }
        last = n.confidence
    }
    vcheck(monotonic && abs(n.confidence - 1) < 1e-9, "热身：3 秒内置信度单调升到 1")
    vcheck(n.step(.empty, gainDb: 0, auto: true, dt: 0.3) == 0, "归一化：没有画面样本 → 0")
}

do {
    var n = MotionNormalizer()
    let cutWindow = MotionWindow(meanEnergy: 40, peakEnergy: 40, frames: 4, cutCount: 1, heldCount: 0)
    let heldWindow = MotionWindow(meanEnergy: 40, peakEnergy: 40, frames: 4, cutCount: 0, heldCount: 2)
    for _ in 0..<20 {
        _ = n.step(cutWindow, gainDb: 0, auto: true, dt: 0.3)
        _ = n.step(heldWindow, gainDb: 0, auto: true, dt: 0.3)
    }
    vcheck(n.refHigh == MotionNormalizer.initialHigh && n.refLow == MotionNormalizer.initialLow,
           "归一化：切换 / 保持期窗口不更新参考值")
}

do {
    var plain = MotionNormalizer()
    var boosted = MotionNormalizer()
    var quiet = MotionNormalizer()
    var capped = MotionNormalizer()
    var loud = MotionNormalizer()
    let a = plain.step(vsWindow(2.25), gainDb: 0, auto: false, dt: 0.3)
    let b = boosted.step(vsWindow(2.25), gainDb: 6, auto: false, dt: 0.3)
    let q = quiet.step(vsWindow(1), gainDb: 0, auto: false, dt: 0.3)
    let c = capped.step(vsWindow(1), gainDb: 99, auto: false, dt: 0.3)
    vcheck(a > 0 && b > a * 1.9 && b < a * 2.1, "画面灵敏度：+6 dB ≈ ×2")
    vcheck(q > 0 && c < 100 && abs(c - q * pow(10, 12.0 / 20)) < 1e-6, "画面灵敏度：超范围夹到 +12 dB（\(q) → \(c)）")
    vcheck(loud.step(vsWindow(40), gainDb: 12, auto: false, dt: 0.3) == 100, "画面灵敏度：放大后仍夹在 100")
}

do {
    var n = MotionNormalizer()
    var s = MotionShaper()
    let weird = [vsWindow(.nan), vsWindow(.infinity), vsWindow(-5),
                 MotionWindow(meanEnergy: 1e300, peakEnergy: 1e300, frames: 4, cutCount: 0, heldCount: 0)]
    let steps: [Double] = [0.3, Double.nan, 1_000, -1]
    var finite = true
    for w in weird {
        for dt in steps {
            let t = n.step(w, gainDb: .nan, auto: true, dt: dt)
            let o = s.step(target: t, dt: dt)
            if !t.isFinite || t < 0 || t > 100 || !o.smoothed.isFinite || o.smoothed < 0 || o.smoothed > 100 {
                finite = false
            }
        }
    }
    vcheck(finite && n.refHigh.isFinite && n.refLow.isFinite, "归一化 / 平滑：NaN / ∞ / 负值 / 超长步长 → 有限且在 0~100")
}

do {
    var s = MotionShaper()
    let o1 = s.step(target: 6, dt: 0.3)
    vcheck(!s.gateOpen && o1.smoothed == 0 && o1.level == 6, "平滑：门槛以下不开门（画面条仍显示）")
    let o2 = s.step(target: 100, dt: 0.3)
    vcheck(s.gateOpen && o2.smoothed >= 80, "平滑：攻击一步跟上 ≥ 80%（\(Int(o2.smoothed))）")
    _ = s.step(target: 6, dt: 0.3)
    vcheck(s.gateOpen, "平滑：4~8 之间不关门（回差）")
    _ = s.step(target: 3, dt: 0.3)
    vcheck(!s.gateOpen, "平滑：低于 4 才关门")
    var o = o2
    for _ in 0..<20 { o = s.step(target: 0, dt: 0.3) }
    vcheck(o.smoothed < 1, "平滑：持续静止 6 秒内落到 0 附近")
    s.reset()
    vcheck(s.smoothed == 0 && !s.gateOpen, "平滑：reset 清零")
}

// MARK: - 最低强度只在画面真的在流时生效

do {
    var f = MotionFlowWatch()
    vcheck(!f.allowsFloor(analyzerRunning: true, playerPlaying: true, now: 10), "画面最低强度：还没有画面样本时不加")
    f.note(.empty, now: 10)
    vcheck(!f.isFlowing(now: 10), "画面最低强度：空窗口不算有画面")
    f.note(vsWindow(0.1), now: 10.3)
    vcheck(f.allowsFloor(analyzerRunning: true, playerPlaying: true, now: 10.3), "画面最低强度：静止画面也算画面在流（不归零）")
    vcheck(!f.allowsFloor(analyzerRunning: true, playerPlaying: false, now: 10.3), "画面最低强度：缓冲中（播放器没在播）不加")
    vcheck(!f.allowsFloor(analyzerRunning: false, playerPlaying: true, now: 10.3), "画面最低强度：分析没在跑不加")
    vcheck(f.isFlowing(now: 11.2) && !f.isFlowing(now: 11.4), "画面最低强度：最近 1 秒内有样本才算新鲜")
    f.reset()
    vcheck(!f.isFlowing(now: 10.4), "画面最低强度：开播 / 跳转后旧样本不作数")
    f.note(vsWindow(1), now: 12)
    vcheck(!f.isFlowing(now: 11.5) && f.isFlowing(now: 12.5), "画面最低强度：时间倒退不算新鲜")
}

// MARK: - 发热降级

vcheck(MotionThermalPolicy.frameRate(for: .nominal) == 15 && MotionThermalPolicy.frameRate(for: .fair) == 15
       && MotionThermalPolicy.note(for: .nominal) == nil, "发热：正常 / 偏热 15 Hz、不提示")
vcheck(MotionThermalPolicy.frameRate(for: .serious) == 8 && MotionThermalPolicy.note(for: .serious) != nil,
       "发热：.serious 降到 8 Hz 并提示")
vcheck(MotionThermalPolicy.frameRate(for: .critical) == 0 && MotionThermalPolicy.note(for: .critical) != nil,
       "发热：.critical 暂停画面分析并提示")

// MARK: - 出口（安全相关）

do {
    // 映射与 AudioReactiveShaper.step 尾部逐位一致
    var shaper = AudioReactiveShaper()
    var identical = true
    for _ in 0..<2_000 {
        let s = AudioSyncSettings(sensitivityDb: -20 + vsRandom() * 50, maxPercent: vsRandom() * 120,
                                  channels: AudioSyncChannels(rawValue: Int(vsRandom() * 3)) ?? .both,
                                  minPercent: vsRandom() * 60, autoGain: vsRandom() < 0.5)
        let w = AudioWindow(peakToPeak: vsRandom() * 2.5, rms: vsRandom(), frames: Int(vsRandom() * 3) * 1_000)
        let hasAudio = vsRandom() < 0.7
        let out = shaper.step(w, settings: s, dt: vsRandom() * 1.5, hasAudio: hasAudio)
        let floor = SyncOutputStage.floorPercent(settings: s, hasSignal: hasAudio)
        if SyncOutputStage.map(shaper.smoothed, cap: s.maxPercent, floor: floor) != out.percent { identical = false }
    }
    vcheck(identical, "出口：最低强度 / 上限映射与 AudioReactiveShaper.step 尾部逐位一致（2000 组随机）")
}

do {
    let s60 = AudioSyncSettings(maxPercent: 60)
    var st = SyncOutputStage()
    let r1 = st.step(100, settings: s60, hasSignal: true)
    let r2 = st.step(100, settings: s60, hasSignal: true)
    let r3 = st.step(100, settings: s60, hasSignal: true)
    let r4 = st.step(100, settings: s60, hasSignal: true)
    vcheck(r1 == [20, 20, 0, 0] && r2 == [40, 40, 0, 0] && r3 == [60, 60, 0, 0] && r4 == [60, 60, 0, 0],
           "出口：每拍最多 +20，到上限 60 停住")
    let drop = st.step(0, settings: s60, hasSignal: true)
    vcheck(drop == [0, 0, 0, 0], "出口：下降不限（60 一拍到 0）")
    let k1 = st.step(100, settings: s60, hasSignal: true)
    let k2 = st.step(100, settings: s60, hasSignal: true)
    let k3 = st.step(100, settings: s60, hasSignal: true)
    vcheck(k1 == [0, 0, 0, 0] && k2 == [0, 0, 0, 0], "出口：归零后两拍内保持 0")
    vcheck(k3 == [20, 20, 0, 0], "出口：第三拍才开始爬（≤ 20）")
    st.reset()
    vcheck(st.step(100, settings: s60, hasSignal: true) == [20, 20, 0, 0], "出口：reset() 后第一拍从 0 起爬、不推迟")
    st.seed([50, 50, 99, 99])
    vcheck(st.step(100, settings: s60, hasSignal: true) == [60, 60, 0, 0], "出口：切换来源时从当前输出起算升幅")
    st.seed([0, 0, 0, 0])
    let z1 = st.step(100, settings: s60, hasSignal: true)
    let z2 = st.step(100, settings: s60, hasSignal: true)
    let z3 = st.step(100, settings: s60, hasSignal: true)
    vcheck(z1 == [0, 0, 0, 0] && z2 == [0, 0, 0, 0] && z3 == [20, 20, 0, 0], "出口：切换来源时为 0 的通道同样保持两拍")
}

do {
    var thrust = SyncOutputStage()
    var vibration = SyncOutputStage()
    vcheck(thrust.step(100, settings: AudioSyncSettings(maxPercent: 60, channels: .thrust), hasSignal: true) == [20, 0, 0, 0],
           "出口：仅伸缩")
    vcheck(vibration.step(100, settings: AudioSyncSettings(maxPercent: 60, channels: .vibration), hasSignal: true) == [0, 20, 0, 0],
           "出口：仅震动")
    let floorOn = AudioSyncSettings(maxPercent: 60, minPercent: 10)
    var withSignal = SyncOutputStage()
    var noSignal = SyncOutputStage()
    vcheck(withSignal.step(0, settings: floorOn, hasSignal: true) == [10, 10, 0, 0], "出口：有新鲜画面时安静段保持最低强度")
    vcheck(noSignal.step(0, settings: floorOn, hasSignal: false) == [0, 0, 0, 0], "出口：没有画面信号时输出 0（不加最低强度）")
    vcheck(SyncOutputStage.hardCap(AudioSyncSettings(maxPercent: 100)) == 99, "出口：上限 100% 时最高 99 档")
    vcheck(SyncOutputStage.preview(100, settings: AudioSyncSettings(maxPercent: 60), hasSignal: true) == 60,
           "出口：联动关着时的预览不受升幅限制、不超上限")
}

do {
    // 上限模糊测试：任何输入都在 [0, min(上限, 99)]，通道 2 / 3 恒 0，升幅 ≤ 20
    var st = SyncOutputStage()
    var base = [0, 0, 0, 0]
    var withinCap = true
    var riseOK = true
    let specials: [Double] = [.nan, .infinity, -Double.infinity, -50, 1e9]
    for i in 0..<5_000 {
        var s = AudioSyncSettings(maxPercent: -20 + vsRandom() * 170,
                                  channels: AudioSyncChannels(rawValue: Int(vsRandom() * 3)) ?? .both,
                                  minPercent: vsRandom() * 60)
        // init 会把上限夹回 10~100：直接写越界值 / NaN，真正覆盖 hardCap 的防御分支
        if i % 11 == 0 { s.maxPercent = [Double.nan, .infinity, -5, 500][i % 4] }
        let r = vsRandom()
        if r < 0.03 {
            st.reset()
            base = [0, 0, 0, 0]
        } else if r < 0.06 {
            let levels = [Int(vsRandom() * 200) - 50, Int(vsRandom() * 200) - 50, 99, 99]
            st.seed(levels)
            base = [max(0, min(99, levels[0])), max(0, min(99, levels[1])), 0, 0]
        }
        let v = i % 7 == 0 ? specials[i % specials.count] : vsRandom() * 120 - 10
        let out = st.step(v, settings: s, hasSignal: vsRandom() < 0.6)
        // 独立判据，不拿被测的 hardCap 当标准
        let cap = s.maxPercent.isFinite ? max(0, min(Int(s.maxPercent.rounded(.down)), 99)) : 0
        let frame = [UInt8](BCProtocol.videoFrame(levels: out))
        if out.count != 4 || out[2] != 0 || out[3] != 0 || frame[5] != 0 || frame[6] != 0 { withinCap = false }
        for ch in 0..<2 where out[ch] < 0 || out[ch] > cap { withinCap = false }
        for ch in 0..<2 where out[ch] - base[ch] > SyncOutputStage.maxRisePerTick { riseOK = false }
        base = out
    }
    vcheck(withinCap, "出口：5000 组随机（含 NaN / ∞ / 越界上限）都不超过 min(上限, 99)，通道 2 / 3 恒 0")
    vcheck(riseOK, "出口：任意相邻两拍每通道升高 ≤ 20")
    var bad = AudioSyncSettings()
    for (v, want) in [(Double.nan, 0), (.infinity, 0), (-5, 0), (500, 99)] {
        bad.maxPercent = v
        vcheck(SyncOutputStage.hardCap(bad) == want, "出口：hardCap(\(v)) == \(want)")
    }
}

// MARK: - 设置

do {
    let d = VisualSyncSettings()
    vcheck(d.source == .audio && d.motionGainDb == 0 && d.autoMotion, "画面设置：默认跟随声音、0 dB、自动适应开")
    vcheck(VisualSyncSettings(motionGainDb: 99).motionGainDb == 12 && VisualSyncSettings(motionGainDb: -99).motionGainDb == -6,
           "画面设置：灵敏度超范围夹回")
    vcheck(VisualSyncSettings(motionGainDb: .nan).motionGainDb == 0 && VisualSyncSettings(motionGainDb: .infinity).motionGainDb == 0,
           "画面设置：NaN / 无穷按默认")
    vcheck(VisualSyncSettings.resolveSource(rawValue: 2) == .audio && VisualSyncSettings.resolveSource(rawValue: 9) == .audio
           && VisualSyncSettings.resolveSource(rawValue: 1) == .motion, "画面设置：认不出的来源（含 P2 的 2）按声音")
    vcheck(VisualSyncSource.allCases.map { $0.title } == ["声音", "画面"], "画面设置：P1 只有声音 / 画面两个选项")
    vcheck(!VisualSyncSettings.Keys.source.contains(".") && !VisualSyncSettings.Keys.motionGainDb.contains(".")
           && !VisualSyncSettings.Keys.autoMotion.contains("."), "画面设置：@AppStorage 键名不带点")
}

let vsSuite = "bc.visualsync.checks"
if let defaults = UserDefaults(suiteName: vsSuite) {
    defaults.removePersistentDomain(forName: vsSuite)
    vcheck(VisualSyncSettings.load(from: defaults) == VisualSyncSettings(), "画面设置：没存过用默认（跟随声音，老用户行为不变）")
    defaults.set(9, forKey: VisualSyncSettings.Keys.source)
    defaults.set("abc", forKey: VisualSyncSettings.Keys.motionGainDb)
    defaults.set("yes", forKey: VisualSyncSettings.Keys.autoMotion)
    let bad = VisualSyncSettings.load(from: defaults)
    vcheck(bad.source == .audio && bad.motionGainDb == 0 && bad.autoMotion, "画面设置：存储里的坏值回默认")
    defaults.set(2, forKey: VisualSyncSettings.Keys.source)
    vcheck(VisualSyncSettings.load(from: defaults).source == .audio, "画面设置：存的是 2（P2 混合）时按声音")
    defaults.set(1, forKey: VisualSyncSettings.Keys.source)
    defaults.set(99.0, forKey: VisualSyncSettings.Keys.motionGainDb)
    defaults.set(false, forKey: VisualSyncSettings.Keys.autoMotion)
    let stored = VisualSyncSettings.load(from: defaults)
    vcheck(stored.source == .motion && stored.motionGainDb == 12 && !stored.autoMotion, "画面设置：读回存的值并夹紧")
    defaults.removePersistentDomain(forName: vsSuite)
} else {
    vcheck(false, "画面设置：创建测试用 UserDefaults")
}

// MARK: - algo-opt-1：稳健去均值 / 近场分数 / 内容时间戳 / 来源交接 / 轻柔声音降权

func vsNoise(_ x: Int, _ y: Int) -> UInt8 {
    let h = (x &* 73_856_093) ^ (y &* 19_349_663)
    return UInt8(40 + (h & 0x7fff_ffff) % 160)
}

do {
    // 左边 40% 变暗 90：原来按整帧均值去均值，没动的右边也会被算成在动（覆盖率 ≈ 1）；中位数去均值后只剩左边几列
    var an = MotionAnalyzer()
    _ = an.analyze(vsFrame { x, y in vsNoise(x, y) }, time: 0)
    let s = an.analyze(vsFrame { x, y in x < 26 ? UInt8(max(0, Int(vsNoise(x, y)) - 90)) : vsNoise(x, y) }, time: vsDt)
    let c = s?.coverage ?? 1
    vcheck(c > 0.3 && c <= 0.55, "稳健去均值：左 40% 变暗 → 覆盖率约 0.4~0.5、不是整幅（\(c)）")
    vcheck(MotionAnalyzer.histogramMedian([0, 3, 0, 2], count: 5) == 1, "稳健去均值：直方图中位数（奇数个）")
    vcheck(MotionAnalyzer.histogramMedian([0, 2, 0, 2], count: 4) == 2, "稳健去均值：直方图中位数（偶数个取中间两个平均）")
    vcheck(MotionAnalyzer.histogramMedian([0, 0], count: 0) == 255, "稳健去均值：没有像素 → 差值 0")
}

/// 近场测试：前 2 秒小方块来回动；之后一个暗的、软纹理的「手」从左边 1 秒滑进来盖住 3/4 画面，再左右晃 5 像素
func vsHand(_ i: Int) -> LumaFrame {
    if i < 30 {
        let bx = 10 + (i % 2) * 4
        return vsFrame { x, y in (x >= bx && x < bx + 8 && y >= 14 && y < 22) ? 220 : vsNoise(x, y) }
    }
    let edge = i < 45 ? (i - 30) * 3 + 3 : 48 + (i % 2 == 0 ? 0 : 5)
    return vsFrame { x, y in
        guard x < edge else { return vsNoise(x, y) }
        let ex = Double(x - edge + 48)
        return UInt8(max(0, min(255, 35 + 20 * sin(ex / 4) + 10 * cos(Double(y) / 5))))
    }
}

/// 跑一段画面：返回（最后 30 个样本的平均近场分数, 最大近场分数, 最后一拍输出, 同样窗口但近场分数清零的输出）
func vsRunNear(_ frames: Int, _ gen: (Int) -> LumaFrame) -> (near: Double, maxNear: Double, out: Double, plain: Double) {
    var an = MotionAnalyzer()
    var acc = MotionWindowAccumulator()
    var norm = MotionNormalizer()
    var plainNorm = MotionNormalizer()
    var nears: [Double] = []
    var out = 0.0
    var plain = 0.0
    for i in 0..<frames {
        if let s = an.analyze(gen(i), time: Double(i) * vsDt) {
            acc.add(s)
            nears.append(s.nearField)
        }
        if i % 5 == 4 {
            let w = acc.drain()
            var w0 = w
            w0.nearField = 0
            out = norm.step(w, gainDb: 0, auto: true, dt: 1.0 / 3)
            plain = plainNorm.step(w0, gainDb: 0, auto: true, dt: 1.0 / 3)
        }
    }
    let tail = nears.suffix(30)
    return (tail.reduce(0, +) / Double(max(1, tail.count)), nears.max() ?? 0, out, plain)
}

do {
    let hand = vsRunNear(100, vsHand)
    vcheck(hand.near > 0.6, "近场：手滑进来盖住大半画面再晃 → 近场分数高（\(hand.near)）")
    vcheck(hand.plain > 50 && hand.out <= 0.75 * hand.plain,
           "近场：同一段画面输出明显变低（\(Int(hand.out)) vs 不降权 \(Int(hand.plain))）")
    let pan = vsRunNear(90) { i in vsFrame { x, y in vsNoise(x - 2 * i, y) } }
    vcheck(pan.maxNear <= 0.05 && pan.out == pan.plain, "近场：纯平移镜头不算近场（最大 \(pan.maxNear)）")
    let small = vsRunNear(90) { i in
        let bx = 10 + (i % 2) * 4
        return vsFrame { x, y in (x >= bx && x < bx + 8 && y >= 14 && y < 22) ? 220 : vsNoise(x, y) }
    }
    vcheck(small.maxNear == 0 && small.out == small.plain && small.out > 0,
           "近场：小物体来回动不受影响（输出 \(Int(small.out))）")
    let big = vsRunNear(90) { i in
        let o = (i % 2) * 3
        return vsFrame { x, y in (x > 8 && x < 56) ? vsNoise(x + o, y + 50) : vsNoise(x, y) }
    }
    vcheck(big.near < 0.1 && abs(big.out - big.plain) <= 2,
           "近场：大面积但同类纹理的动作基本不受影响（\(big.near)，\(Int(big.out)) vs \(Int(big.plain))）")
}

// 第二轮审查 M1：手在一帧内盖住镜头 → 被判成切镜 / 闪变；背景不能因此换成手本身
func vsSoftBlob(_ x: Int, _ y: Int, edge: Int) -> UInt8 {
    let ex = Double(x - edge + 48)
    return UInt8(max(0, min(255, 35 + 20 * sin(ex / 4) + 10 * cos(Double(y) / 5))))
}

func vsBeforeCut(_ i: Int) -> LumaFrame {
    let bx = 10 + (i % 2) * 4
    return vsFrame { x, y in (x >= bx && x < bx + 8 && y >= 14 && y < 22) ? 220 : vsNoise(x, y) }
}

/// 跑 frames 帧（第 30 帧起换成 after），返回每帧样本（没有样本为 nil）和每帧之后背景是否待定
func vsRunCut(_ frames: Int, after: (Int) -> LumaFrame) -> (samples: [MotionSample?], pending: [Bool]) {
    var an = MotionAnalyzer()
    var samples: [MotionSample?] = []
    var pending: [Bool] = []
    for i in 0..<frames {
        samples.append(an.analyze(i < 30 ? vsBeforeCut(i) : after(i), time: Double(i) * vsDt))
        pending.append(an.isBackgroundPending)
    }
    return (samples, pending)
}

do {
    let sudden = vsRunCut(90) { i in
        let edge = 48 + (i % 2 == 0 ? 0 : 5)
        return vsFrame { x, y in x < edge ? vsSoftBlob(x, y, edge: edge) : vsNoise(x, y) }
    }
    let cutIndex = (30..<40).first { sudden.samples[$0]?.isCut == true }
    vcheck(cutIndex != nil, "近场 / 切镜：手一帧内盖住 75% → 被判为切镜 / 闪变（前提）")
    let start = (cutIndex ?? 30) + MotionAnalyzer.holdSamples + 1
    let afterHold = sudden.samples[start..<min(sudden.samples.count, start + 30)].compactMap { $0 }
    let near = afterHold.map(\.nearField).reduce(0, +) / Double(max(1, afterHold.count))
    vcheck(afterHold.count >= 20 && near > 0.6 && afterHold.allSatisfy { !$0.isCut && !$0.isHeld },
           "近场 / 切镜：保持期之后手在晃 → 近场分数仍高（\(near)），背景没换成手")
    vcheck(sudden.pending[start + 20], "近场 / 切镜：手一直晃时保持切镜前的背景（待定中）")
    // 同一段画面进归一化：近场窗口不降权就会被学成「这个视频平时动这么大」
    var norm = MotionNormalizer()
    var plainNorm = MotionNormalizer()
    var acc = MotionWindowAccumulator()
    var out = 0.0
    var plain = 0.0
    for (i, s) in sudden.samples.enumerated() {
        if let s = s { acc.add(s) }
        if i % 5 == 4 {
            let w = acc.drain()
            var w0 = w
            w0.nearField = 0
            out = norm.step(w, gainDb: 0, auto: true, dt: 1.0 / 3)
            plain = plainNorm.step(w0, gainDb: 0, auto: true, dt: 1.0 / 3)
        }
    }
    vcheck(plain > 50 && out <= 0.75 * plain && norm.refHigh < plainNorm.refHigh,
           "近场 / 切镜：手突然盖住后的晃动降权且不学参考值（\(Int(out)) vs \(Int(plain))）")

    // 真实切镜到清晰、高动态的新场景：很快（远早于 nearFreezeLimit）采用新背景，近场分数回落
    let realCut = vsRunCut(90) { i in
        let o = (i % 2) * 3
        return vsFrame { x, y in
            let v = Int(vsNoise((x > 8 && x < 56) ? x + o : x, y + 50))
            return UInt8(min(255, 90 + v))
        }
    }
    let realCutIndex = (30..<40).first { realCut.samples[$0]?.isCut == true }
    let adoptIndex = (30..<90).first { $0 > (realCutIndex ?? 30) && !realCut.pending[$0] }
    let adoptSeconds = Double((adoptIndex ?? 999) - (realCutIndex ?? 30)) * vsDt
    let realTail = realCut.samples.suffix(30).compactMap { $0 }.map(\.nearField)
    vcheck(realCutIndex != nil && adoptSeconds <= 1.5 && adoptSeconds < MotionAnalyzer.nearFreezeLimit,
           "近场 / 切镜：真实切到清晰的高动态场景 → \(String(format: "%.2f", adoptSeconds)) 秒内采用新背景")
    vcheck((realTail.max() ?? 1) < 0.2, "近场 / 切镜：采用新背景后近场分数回落（最大 \(realTail.max() ?? -1)）")

    // 一直分不清（手盖住后持续晃）：最多冻结 nearFreezeLimit，之后采用新背景，近场分数不再判为近场（≤ 0.5，恢复学习）
    let limitFrames = Int((MotionAnalyzer.nearFreezeLimit / vsDt).rounded(.up))
    let long = vsRunCut(30 + limitFrames + 45) { i in
        let edge = 48 + (i % 2 == 0 ? 0 : 5)
        return vsFrame { x, y in x < edge ? vsSoftBlob(x, y, edge: edge) : vsNoise(x, y) }
    }
    let longCut = (30..<40).first { long.samples[$0]?.isCut == true } ?? 30
    let longAdopt = (longCut + 1..<long.pending.count).first { !long.pending[$0] }
    let longSeconds = Double((longAdopt ?? 9_999) - longCut) * vsDt
    let longTail = long.samples.suffix(20).compactMap { $0 }.map(\.nearField)
    vcheck(longAdopt != nil && longSeconds >= MotionAnalyzer.nearFreezeLimit - 0.5
           && longSeconds <= MotionAnalyzer.nearFreezeLimit + 0.2,
           "近场 / 切镜：一直分不清时最多冻结 nearFreezeLimit（\(String(format: "%.2f", longSeconds)) 秒后采用新背景）")
    vcheck((longTail.max() ?? 1) <= 0.5, "近场 / 切镜：冻结结束后不再判为近场（最大 \(longTail.max() ?? -1)）")

    // 切到本身就糊、整幅在动的新场景：同样在 nearFreezeLimit 内采用新背景并恢复
    let blurry = vsRunCut(30 + limitFrames + 45) { i in
        vsFrame { x, y in vsSoftBlob(x, y, edge: 64 + (i % 2 == 0 ? 0 : 5)) }
    }
    let blurCut = (30..<40).first { blurry.samples[$0]?.isCut == true } ?? 30
    let blurAdopt = (blurCut + 1..<blurry.pending.count).first { !blurry.pending[$0] }
    let blurSeconds = Double((blurAdopt ?? 9_999) - blurCut) * vsDt
    let blurTail = blurry.samples.suffix(20).compactMap { $0 }.map(\.nearField)
    vcheck(blurAdopt != nil && blurSeconds <= MotionAnalyzer.nearFreezeLimit + 0.2,
           "近场 / 切镜：切到偏糊的新场景也在 nearFreezeLimit 内采用新背景（\(String(format: "%.2f", blurSeconds)) 秒）")
    vcheck((blurTail.max() ?? 1) < 0.2, "近场 / 切镜：偏糊的新场景采用后近场分数回落（最大 \(blurTail.max() ?? -1)）")
    var resetAn = MotionAnalyzer()
    _ = resetAn.analyze(vsBeforeCut(0), time: 0)
    _ = resetAn.analyze(vsBeforeCut(1), time: vsDt)
    _ = resetAn.analyze(vsFrame { x, y in vsSoftBlob(x, y, edge: 48) }, time: 2 * vsDt)
    let pendingBefore = resetAn.isBackgroundPending
    resetAn.reset()
    vcheck(pendingBefore && !resetAn.isBackgroundPending, "近场 / 切镜：reset() 清掉待定状态")
}

do {
    // 近场窗口不训练参考值；近场只降不升
    var learn = MotionNormalizer()
    var frozen = MotionNormalizer()
    for _ in 0..<30 {
        _ = learn.step(MotionWindow(meanEnergy: 30, peakEnergy: 30, frames: 4, cutCount: 0, heldCount: 0),
                       gainDb: 0, auto: true, dt: 0.3)
        _ = frozen.step(MotionWindow(meanEnergy: 30, peakEnergy: 30, frames: 4, cutCount: 0, heldCount: 0,
                                     coverage: 0.9, nearField: 0.8), gainDb: 0, auto: true, dt: 0.3)
    }
    vcheck(learn.refHigh > MotionNormalizer.initialHigh + 0.5 && frozen.refHigh == MotionNormalizer.initialHigh
           && frozen.refLow == MotionNormalizer.initialLow, "近场：近场分数 ≥ 0.5 的窗口不学参考值")
    var onlyLower = true
    var inRange = true
    for _ in 0..<2_000 {
        var a = MotionNormalizer()
        var b = MotionNormalizer()
        let e = vsRandom() * 60
        let near = vsRandom() < 0.1 ? Double.nan : vsRandom() * 1.2 - 0.1
        let gain = -10 + vsRandom() * 25
        let auto = vsRandom() < 0.5
        let w = MotionWindow(meanEnergy: e, peakEnergy: e * (1 + vsRandom()), frames: 4, cutCount: 0, heldCount: 0,
                             coverage: vsRandom(), nearField: near)
        var w0 = w
        w0.nearField = 0
        let x = a.step(w, gainDb: gain, auto: auto, dt: 0.3)
        let y = b.step(w0, gainDb: gain, auto: auto, dt: 0.3)
        if x > y + 1e-9 { onlyLower = false }
        if !(x >= 0 && x <= 100) { inRange = false }
    }
    vcheck(onlyLower && inRange, "近场：2000 组随机（含 NaN / 越界分数）只降不升、输出在 0~100")
    var acc = MotionWindowAccumulator()
    acc.add(MotionSample(time: 0, energy: 2, coverage: 0.2, isCut: false, isHeld: false, nearField: 0.4))
    acc.add(MotionSample(time: 0.07, energy: 4, coverage: 0.6, isCut: false, isHeld: false, nearField: .nan))
    let w = acc.drain()
    vcheck(abs(w.coverage - 0.4) < 1e-12 && abs(w.nearField - 0.2) < 1e-12, "窗口：覆盖率 / 近场分数取平均（NaN 当 0）")
}

do {
    // 24 fps 片源、15 Hz 拉帧：方块每个内容帧走 1 像素。按拉帧时刻算能量一大一小，按显示时刻算几乎恒定
    func run(clocked: Bool) -> (spread: Double, monotonic: Bool) {
        var an = MotionAnalyzer()
        var clock = MotionDisplayClock()
        var energies: [Double] = []
        var last = -Double.infinity
        var monotonic = true
        for k in 0..<30 {
            let host = 50 + Double(k) / 15
            let item = Double(k) / 15
            let shownFrame = Int((item * 24).rounded(.down))
            let shown = Double(shownFrame) / 24
            let t = clocked ? clock.time(host: host, item: item, shown: shown) : host
            if t <= last || t > host { monotonic = false }
            last = t
            let bx = 4 + shownFrame
            if let s = an.analyze(vsBlock(bx), time: t), s.energy > 0 { energies.append(s.energy) }
        }
        guard let lo = energies.min(), let hi = energies.max(), lo > 0 else { return (99, monotonic) }
        return (hi / lo, monotonic)
    }
    let host = run(clocked: false)
    let clocked = run(clocked: true)
    vcheck(host.spread > 1.5 && clocked.spread < 1.1,
           "内容时间戳：24 fps 片源能量不再一大一小（\(host.spread) → \(clocked.spread)）")
    vcheck(clocked.monotonic, "内容时间戳：时间单调递增且不晚于拉帧时刻")
    var c = MotionDisplayClock()
    vcheck(c.time(host: 10, item: 5, shown: 4) == 10, "内容时间戳：滞后超过 0.5 秒不信，用拉帧时刻")
    vcheck(c.time(host: 10.1, item: 5.1, shown: .nan) == 10.1, "内容时间戳：拿不到显示时间用拉帧时刻")
    c.noteStill(at: 10.4)
    let after = c.time(host: 10.47, item: 5.47, shown: 5.0)
    vcheck(after > 10.4 && after <= 10.47, "内容时间戳：补过静止样本后不会倒回去（\(after)）")
    var fuzz = MotionDisplayClock()
    var ok = true
    var prev = -Double.infinity
    for k in 0..<500 {
        let host = Double(k) * 0.07
        let r = vsRandom()
        let item = r < 0.05 ? Double.nan : host * (0.5 + vsRandom())
        let shown = r < 0.1 ? Double.infinity : item - vsRandom() * 0.6
        let t = fuzz.time(host: host, item: item, shown: shown)
        if !t.isFinite || t > host || t < prev { ok = false }
        prev = t
    }
    vcheck(ok && fuzz.rate >= 0.1 && fuzz.rate <= 8, "内容时间戳：随机 / NaN 输入下有限、单调、不晚于拉帧时刻")
}

do {
    // 帧 → 静止补样 → 帧：补样和真实帧同一条显示时刻时间轴（host − 上一帧滞后）。
    // 以前补样用 host，补样后第一帧被压到 lastOut + 31 ms，按间隔归一时能量 ×2
    var ref = MotionAnalyzer()
    _ = ref.analyze(vsBlock(20), time: 0)
    let eRef = ref.analyze(vsBlock(24), time: vsDt)?.energy ?? -1
    func hostAt(_ k: Int) -> Double { 10 + Double(k) / 15 }
    func itemAt(_ k: Int) -> Double { 1 + Double(k) / 15 }
    var an = MotionAnalyzer()
    var clock = MotionDisplayClock()
    let t0 = clock.time(host: hostAt(0), item: itemAt(0), shown: itemAt(0) - 0.05)
    _ = an.analyze(vsBlock(20), time: t0)
    let st = clock.stillTime(host: hostAt(4))
    let still = an.still(at: st)
    if still != nil { clock.noteStill(at: st) }
    let t5 = clock.time(host: hostAt(5), item: itemAt(5), shown: itemAt(5) - 0.05)
    let e5 = an.analyze(vsBlock(24), time: t5)?.energy ?? -1
    vcheck(still != nil && st < hostAt(4) && t5 > st && t5 <= hostAt(5),
           "内容时间戳：静止补样换到显示时刻时间轴，之后的帧仍晚于它（\(st) → \(t5)）")
    vcheck(eRef > 0 && abs(e5 / eRef - 1) < 0.01,
           "内容时间戳：帧 → 静止补样 → 帧，补样后第一帧能量不被间隔归一放大（\(e5) vs \(eRef)）")
}

do {
    // 来源交接
    var none = SourceHandover()
    var same = true
    for _ in 0..<2_000 {
        let m = vsRandom() * 100
        let c = vsRandom()
        let sig = vsRandom() < 0.7
        let r = none.blend(motion: m, confidence: c, motionSignal: sig, audio: vsRandom() * 100,
                           audioSignal: vsRandom() < 0.5, dt: 0.3)
        if r.value != (sig ? c * m : 0) || r.hasSignal != sig { same = false }
    }
    vcheck(same, "来源交接：没有交接时和原来逐位相同（2000 组随机）")
    var h = SourceHandover()
    h.begin(.motion)
    let first = h.blend(motion: 40, confidence: 0, motionSignal: false, audio: 70, audioSignal: true, dt: 0.3)
    vcheck(first.value == 70 && first.hasSignal, "来源交接：声音→画面第一拍画面还没热身时接着用声音")
    var bounded = true
    var ticks = 1
    while h.isFading && ticks < 100 {
        let m = vsRandom() * 100
        let a = vsRandom() * 100
        let r = h.blend(motion: m, confidence: vsRandom(), motionSignal: true, audio: a, audioSignal: true, dt: 0.3)
        if r.value > max(m, a) + 1e-9 || r.value < 0 { bounded = false }
        ticks += 1
    }
    vcheck(bounded, "来源交接：交接中不高于两个来源中较大的那个")
    vcheck(!h.isFading && ticks <= 15, "来源交接：4 秒内淡出结束（\(ticks) 拍）")
    var back = SourceHandover()
    back.begin(.audio)
    var n = 0
    while back.isCatchingUp && n < 50 {
        back.noteCatchUp(limited: [20, 20, 0, 0], direct: [60, 60, 0, 0])
        n += 1
    }
    vcheck(n == SourceHandover.maxCatchUpTicks, "来源交接：画面→声音最多限速 10 拍")
    back.begin(.audio)
    back.noteCatchUp(limited: [60, 60, 0, 0], direct: [60, 60, 0, 0])
    vcheck(!back.isCatchingUp, "来源交接：追上声音直出就结束")
    // 限速追赶：每拍升幅 ≤ 20、不超过上限
    var stage = SyncOutputStage()
    stage.seed([10, 10, 0, 0])
    let s60 = AudioSyncSettings(maxPercent: 60)
    let r1 = stage.step(100, settings: s60, hasSignal: true)
    let r2 = stage.step(100, settings: s60, hasSignal: true)
    let r3 = stage.step(100, settings: s60, hasSignal: true)
    vcheck(r1 == [30, 30, 0, 0] && r2 == [50, 50, 0, 0] && r3 == [60, 60, 0, 0], "来源交接：画面→声音追赶时每拍 +20、到上限为止")
}

do {
    // 同一个视频第二次切到画面：归一化早已热身（confidence = 1），新装的分析器还没出样本 → 仍用声音补
    var h = SourceHandover()
    h.begin(.motion)
    let waiting = h.blend(motion: 0, confidence: 1, motionSignal: false, audio: 70, audioSignal: true, dt: 0.3)
    vcheck(waiting.value == 70 && waiting.hasSignal,
           "来源交接：再次切到画面、画面还没有新鲜样本时接着用声音（\(waiting.value)）")
    let flowing = h.blend(motion: 40, confidence: 1, motionSignal: true, audio: 70, audioSignal: true, dt: 0.3)
    vcheck(flowing.value > 60 && flowing.value <= 70,
           "来源交接：画面刚有新鲜样本时不立刻整段换成画面（algo-opt-2，\(flowing.value)）")
}

// algo-opt-2：同一个视频第二次（及以后每次）切到画面，声音补的那部分平滑交给画面，不再一拍掉光
func vsSecondSwitch(_ h: inout SourceHandover) -> [Double] {
    h.begin(.motion)
    // 前 3 拍新装的分析器还没出样本；之后画面平滑值从 0 爬到 40（归一化早已热身，confidence = 1）
    let motion: [Double] = [0, 0, 0, 0, 15, 30, 40]
    var out: [Double] = []
    for k in 0..<20 {
        let flowing = k >= 3
        let m = k < motion.count ? motion[k] : 40
        out.append(h.blend(motion: m, confidence: 1, motionSignal: flowing, audio: 70, audioSignal: true, dt: 0.3).value)
    }
    return out
}

do {
    var h = SourceHandover()
    let first = vsSecondSwitch(&h)
    var maxDrop = 0.0
    for k in 1..<first.count { maxDrop = max(maxDrop, first[k - 1] - first[k]) }
    // 以前：第 4 拍（画面一有样本）直接 = 画面 0，从约 60 一拍掉到 0
    vcheck(first[3] > 50, "来源交接：再次切到画面，画面刚有样本那一拍仍接着声音（\(first[3])）")
    vcheck(maxDrop <= 15, "来源交接：再次切到画面时每拍最多降 15（以前一拍降约 60；最大 \(maxDrop)）")
    var bounded = true
    for k in 0..<first.count {
        let m = k < 7 ? [0.0, 0, 0, 0, 15, 30, 40][k] : 40
        let cap = max(k >= 3 ? m : 0, 70)
        if first[k] < 0 || first[k] > cap + 1e-9 { bounded = false }
    }
    vcheck(bounded, "来源交接：平滑交接中不高于 max(画面, 声音)")
    vcheck(abs(first[9] - 40) < 1e-6 && !h.isFading && first.last == 40,
           "来源交接：画面有样本 1.5 秒后完全交给画面，交接结束后和原路径相同（\(first[9])）")
    let again = vsSecondSwitch(&h)
    vcheck(again == first, "来源交接：每次切到画面都同样平滑（第三次和第二次逐拍相同）")
}

do {
    // 随机交接：任意信号组合下都在 0 ~ max(有信号的画面, 有信号的声音) 之间，交接一定结束
    // 自己的随机序列：不改变后面测试用的 vsRandom 序列
    var seed: UInt64 = 0xBEEF
    func rnd() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }
    var h = SourceHandover()
    var bounded = true
    var ended = true
    for round in 0..<200 {
        h.begin(.motion)
        var ticks = 0
        while h.isFading && ticks < 60 {
            let m = rnd() * 100
            let a = rnd() * 100
            let ms = rnd() < 0.7
            let au = rnd() < 0.7
            let r = h.blend(motion: m, confidence: rnd(), motionSignal: ms, audio: a, audioSignal: au,
                            dt: round % 9 == 0 ? Double.nan : 0.1 + rnd() * 0.4)
            if r.value < 0 || r.value > max(ms ? m : 0, au ? a : 0) + 1e-9 { bounded = false }
            ticks += 1
        }
        if h.isFading { ended = false }
    }
    vcheck(bounded, "来源交接：随机信号下不高于 max(有信号的画面, 有信号的声音)、不低于 0")
    vcheck(ended, "来源交接：随机信号下交接都会结束")
}

// 轻柔声音：每段 4800 点 × 3（0.3 秒）的均匀噪声，振幅可按样本序号变
func vsNoiseWindow(_ amp: (Int) -> Double) -> AudioWindow {
    var acc = AudioWindowAccumulator()
    for chunk in 0..<3 {
        var st = AudioChannelStats()
        for i in 0..<4_800 { st.add((vsRandom() * 2 - 1) * amp(chunk * 4_800 + i)) }
        st.finish()
        acc.add(peakToPeak: st.peakToPeak, meanSquare: st.meanSquare, frames: 4_800, blocks: st.blocks)
    }
    return acc.drain()
}

do {
    var st = AudioChannelStats()
    for i in 0..<1_224 { st.add(i < 512 ? 0.01 : 0.2 * (i % 2 == 0 ? 1 : -1)) }
    st.finish()
    vcheck(st.blocks.count == 3 && st.blocks.onsets == 1, "块电平：512 点一块、末尾 ≥ 128 点也算、跳高 ≥ 6 dB 记一次起音（\(st.blocks.count) / \(st.blocks.onsets)）")
    var tiny = AudioChannelStats()
    for _ in 0..<100 { tiny.add(0.5) }
    tiny.finish()
    vcheck(tiny.blocks.count == 0 && tiny.peakToPeak == 0 && tiny.meanSquare == 0.25, "块电平：不足 128 点不成块，峰峰值 / 均方照旧")
    var silent = AudioChannelStats()
    for _ in 0..<2_048 { silent.add(0) }
    silent.finish()
    vcheck(silent.blocks.count == 0, "块电平：静音块不进统计")
}

do {
    // 跨 tap 回调接着分块（AudioLevelMeter 每个声道存一份 AudioBlockCarry）：1024 / 333 点的小段和一整段结果相同；
    // 不延续（每段单独收尾，以前的做法）时回调边界上的起音漏掉、尾巴成了短块
    func sample(_ i: Int) -> Double {
        let amp = (i / 1_536) % 2 == 0 ? 0.02 : 0.3
        return i % 2 == 0 ? amp : -amp
    }
    let total = 12_288
    var whole = AudioChannelStats()
    for i in 0..<total { whole.add(sample(i)) }
    whole.finish()
    var carry = AudioBlockCarry()
    var carried = AudioBlockStats()
    var fresh = AudioBlockStats()
    var start = 0
    var k = 0
    while start < total {
        let n = min(total - start, k % 2 == 0 ? 1_024 : 333)
        var s = AudioChannelStats(carry: carry)
        var f = AudioChannelStats()
        for i in start..<(start + n) {
            s.add(sample(i))
            f.add(sample(i))
        }
        carry = s.carry
        f.finish()
        carried.merge(s.blocks)
        fresh.merge(f.blocks)
        start += n
        k += 1
    }
    var tail = AudioChannelStats(carry: carry)
    tail.finish()
    carried.merge(tail.blocks)
    let same = carried.count == whole.blocks.count && carried.onsets == whole.blocks.onsets
        && abs(carried.dbSum - whole.blocks.dbSum) < 1e-9 && abs(carried.dbSumSquares - whole.blocks.dbSumSquares) < 1e-6
    vcheck(same && whole.blocks.count == 24 && whole.blocks.onsets == 4,
           "块电平：1024 / 333 点小段跨回调接着分块，和一整段结果相同（\(carried.count) / \(carried.onsets)）")
    vcheck(fresh != whole.blocks,
           "块电平：不延续时（每段单独收尾）结果不同（\(fresh.count) / \(fresh.onsets) vs \(whole.blocks.count) / \(whole.blocks.onsets)）")
}

do {
    let amp = pow(10, -30.0 / 20) * 3.0.squareRoot()  // 均匀噪声 RMS −30 dBFS
    for auto in [false, true] {
        var duck = AudioReactiveShaper()
        var plain = AudioReactiveShaper()
        let on = AudioSyncSettings(maxPercent: 100, autoGain: auto, softDuck: true)
        let off = AudioSyncSettings(maxPercent: 100, autoGain: auto)
        var d = 0
        var p = 0
        for _ in 0..<150 {
            let w = vsNoiseWindow { _ in amp }
            d = duck.step(w, settings: on, dt: 0.3).percent
            p = plain.step(w, settings: off, dt: 0.3).percent
        }
        vcheck(p > 30 && Double(d) <= 0.75 * Double(p),
               "轻柔声音：持续平稳的小声底噪输出明显变轻（\(auto ? "自动" : "手动")：\(p) → \(d)）")
        var pd = AudioReactiveShaper()
        var pp = AudioReactiveShaper()
        for _ in 0..<150 {
            let w = vsNoiseWindow { i in (i / 2_400) % 2 == 0 ? amp * 4 : amp * 0.25 }
            d = pd.step(w, settings: on, dt: 0.3).percent
            p = pp.step(w, settings: off, dt: 0.3).percent
        }
        vcheck(abs(d - p) <= 2, "轻柔声音：一阵一阵有起伏的声音不受影响（\(auto ? "自动" : "手动")：\(p) / \(d)）")
    }
    // 开关关着：块数据有没有都逐位相同；开着只会更轻；随机 / NaN 输入也在 0 ~ 上限
    var a = AudioReactiveShaper()
    var b = AudioReactiveShaper()
    var on = AudioReactiveShaper()
    var identical = true
    var onlyLower = true
    var bounded = true
    for _ in 0..<2_000 {
        let s = AudioSyncSettings(sensitivityDb: -20 + vsRandom() * 50, maxPercent: vsRandom() * 120,
                                  minPercent: vsRandom() * 60, autoGain: vsRandom() < 0.5)
        var sOn = s
        sOn.softDuck = true
        let r = vsRandom()
        let w = AudioWindow(peakToPeak: r < 0.03 ? .nan : vsRandom() * 2.5, rms: r > 0.97 ? .infinity : vsRandom() * 0.5,
                            frames: Int(vsRandom() * 3) * 1_000)
        var wb = w
        wb.blockCount = Int(vsRandom() * 40)
        wb.blockDbMean = -60 + vsRandom() * 60
        wb.blockDbStd = vsRandom() < 0.02 ? .nan : vsRandom() * 12
        wb.onsets = Int(vsRandom() * 6)
        let dt = vsRandom() < 0.02 ? Double.nan : vsRandom() * 1.5
        let hasAudio = vsRandom() < 0.7
        let x = a.step(w, settings: s, dt: dt, hasAudio: hasAudio)
        let y = b.step(wb, settings: s, dt: dt, hasAudio: hasAudio)
        let z = on.step(wb, settings: sOn, dt: dt, hasAudio: hasAudio)
        if x != y { identical = false }
        if z.percent > y.percent { onlyLower = false }
        if z.percent < 0 || z.percent > Int(s.maxPercent.rounded(.down)) || !on.softness.isFinite
            || !on.dynamics.isFinite || on.softness < 0 || on.softness > 1 { bounded = false }
    }
    vcheck(identical, "轻柔声音：开关关着时和以前逐位相同（块数据不影响输出，2000 组随机）")
    vcheck(onlyLower, "轻柔声音：开着只会更轻、不会更强（同一串随机窗口）")
    vcheck(bounded, "轻柔声音：随机 / NaN / 无穷输入下输出在 0 ~ 上限、内部状态有限")
    vcheck(AudioSyncSettings().softDuck == false && AudioSyncSettings.defaultSoftDuck
           && !AudioSyncSettings.Keys.softDuck.contains("."), "轻柔声音：init 默认关（老调用方不变）、App 默认开、键名不带点")
}

// MARK: - algo-opt-2：软切 / 对比度补偿 / 稳态不分配

/// 偏糊的新镜头：大块柔和明暗（相邻像素差约 7，切镜前的噪声纹理约 100），宽 width 的区域里左右两半在奇数帧
/// 往相反方向挪 2 像素（不是整体平移，补偿不掉，覆盖率接近 1、能量约 4）；x ≥ width 是切镜前的噪声背景原样留着
func vsSoftShot(_ x: Int, _ y: Int, _ i: Int, width: Int = 64) -> UInt8 {
    guard x < width else { return vsNoise(x, y) }
    let o = i % 2 == 0 ? 0.0 : (x < width / 2 ? 2.0 : -2.0)
    return UInt8(max(0, min(255, 100 + 30 * sin((Double(x) + o) / 5) + 20 * cos(Double(y) / 4))))
}

do {
    // 切到偏糊、整幅轻微在动的新镜头：以前覆盖率高 + 变糊 → 近场分数一直高，最长 6 秒才恢复
    let soft = vsRunCut(90) { i in vsFrame { x, y in vsSoftShot(x, y, i) } }
    let early = soft.samples[30..<45].compactMap { $0 }.map(\.nearField)
    vcheck((early.max() ?? 0) > 0.5, "软切：刚切到偏糊、轻微在动的新镜头时近场分数高（前提，最大 \(early.max() ?? -1)）")
    let late = soft.samples[45..<90].compactMap { $0 }.map(\.nearField)
    vcheck(late.count >= 40 && (late.max() ?? 1) < 0.2,
           "软切：1 秒内恢复，之后近场分数最大 \(late.max() ?? -1)（以前最长 6 秒）")
    vcheck(!soft.pending[45], "软切：1 秒内已采用新背景")

    // 同样偏糊、同样在动，但只盖住左边 75%，右边切镜前的背景原样留着：是遮挡，不当软切
    let partial = vsRunCut(90) { i in vsFrame { x, y in vsSoftShot(x, y, i, width: 48) } }
    let mid = partial.samples[45..<75].compactMap { $0 }.map(\.nearField)
    let midMean = mid.reduce(0, +) / Double(max(1, mid.count))
    vcheck(mid.count >= 25 && midMean > 0.5,
           "软切：偏糊画面只盖住 75%、原来的背景还在 → 1~3 秒后仍按遮挡降权（\(midMean)）")
}

do {
    // 整体按比例变暗（渐黑，每帧 ×0.8）：减中位数去不掉，以前每帧都像在动
    let base = vsTexture(40, 200)
    func faded(_ k: Int) -> LumaFrame {
        var f = base
        let s = pow(0.8, Double(k))
        for i in 0..<f.pixels.count { f.pixels[i] = UInt8((Double(base.pixels[i]) * s).rounded()) }
        return f
    }
    var on = MotionAnalyzer()
    var off = MotionAnalyzer()
    off.compensatesContrast = false
    var maxOn = 0.0
    var maxOff = 0.0
    var anyCut = false
    for k in 0...8 {
        let t = Double(k) * vsDt
        if let s = on.analyze(faded(k), time: t) {
            maxOn = max(maxOn, s.energy)
            if s.isCut { anyCut = true }
        }
        if let s = off.analyze(faded(k), time: t) { maxOff = max(maxOff, s.energy) }
    }
    vcheck(maxOff > 3, "对比度补偿：不补偿时渐黑像在动（前提，最大能量 \(maxOff)）")
    vcheck(maxOn < 0.2 && !anyCut, "对比度补偿：渐黑（每帧 ×0.8）→ 能量 ≈ 0（最大 \(maxOn)）、不算切镜")

    // 自动曝光 / 闪光式的对比度 +25%（围绕 120）
    var stretched = base
    for i in 0..<base.pixels.count {
        stretched.pixels[i] = UInt8((120 + 1.25 * (Double(base.pixels[i]) - 120)).rounded())
    }
    var on2 = MotionAnalyzer()
    var off2 = MotionAnalyzer()
    off2.compensatesContrast = false
    _ = on2.analyze(base, time: 0)
    _ = off2.analyze(base, time: 0)
    let sOn = on2.analyze(stretched, time: vsDt)
    let sOff = off2.analyze(stretched, time: vsDt)
    let eOn = sOn?.energy ?? 99
    let eOff = sOff?.energy ?? 0
    vcheck(eOff > 3 && eOn < 0.2 && sOn?.isCut == false && sOn?.coverage == 0,
           "对比度补偿：整体对比度 +25% → 能量 \(eOn)（不补偿 \(eOff)）")

    // 对比度变化的同时方块在动：动作照样算出来（补偿解释不掉真实动作）
    func withBlock(_ f: LumaFrame, _ bx: Int) -> LumaFrame {
        var g = f
        for y in 14..<22 {
            for x in bx..<(bx + 8) { g.pixels[y * 64 + x] = 250 }
        }
        return g
    }
    var mv = MotionAnalyzer()
    _ = mv.analyze(withBlock(base, 20), time: 0)
    let moved = mv.analyze(withBlock(stretched, 24), time: vsDt)
    vcheck((moved?.energy ?? 0) > 1, "对比度补偿：对比度变化时方块移动照样有能量（\(moved?.energy ?? -1)）")

    // 模型本身：偏离 < 8%、太平、没有像素都不补偿；σ 40 → 50 得到 g = 1.25
    vcheck(MotionAnalyzer.contrastModel(sumCur: 0, sumPrev: 0, sumCurSq: 0, sumPrevSq: 0, count: 0) == nil
           && MotionAnalyzer.contrastModel(sumCur: 10_000, sumPrev: 10_000, sumCurSq: 1_000_000, sumPrevSq: 1_000_000,
                                           count: 100) == nil
           && MotionAnalyzer.contrastModel(sumCur: 10_000, sumPrev: 10_000, sumCurSq: 1_160_000, sumPrevSq: 1_170_000,
                                           count: 100) == nil,
           "对比度补偿：没有像素 / 两帧都平 / 对比度几乎没变时不补偿")
    let model = MotionAnalyzer.contrastModel(sumCur: 10_000, sumPrev: 10_000, sumCurSq: 1_250_000,
                                             sumPrevSq: 1_160_000, count: 100)
    vcheck(model != nil && abs((model?.gain ?? 0) - 1.25) < 1e-9 && abs((model?.bias ?? 0) + 25) < 1e-9,
           "对比度补偿：σ 40 → 50 得到 g = 1.25、b = −25")
}

do {
    // 稳态不分配：平移、切镜（记参考帧）、软切、渐黑（对比度补偿）各跑一轮之后，每帧复用的缓冲地址不再变
    let tex = vsTexture(40, 200)
    func cycleFrame(_ k: Int) -> LumaFrame {
        let j = k % 60
        switch j {
        case 0..<15:
            return vsBeforeCut(j)
        case 15..<30:
            return vsFrame { x, y in vsPanTex(x - 2 * j, y) }
        case 30..<45:
            return vsFrame { x, y in vsSoftShot(x, y, j) }
        default:
            var f = tex
            let s = pow(0.85, Double(j - 45))
            for i in 0..<f.pixels.count { f.pixels[i] = UInt8((Double(tex.pixels[i]) * s).rounded()) }
            return f
        }
    }
    var an = MotionAnalyzer()
    for k in 0..<60 { _ = an.analyze(cycleFrame(k), time: Double(k) * vsDt) }
    let warm = an.scratchAddresses.sorted()
    var samples = 0
    for k in 60..<240 {
        if an.analyze(cycleFrame(k), time: Double(k) * vsDt) != nil { samples += 1 }
    }
    vcheck(samples > 150 && an.scratchAddresses.sorted() == warm,
           "稳态不分配：热身一轮后再跑 180 帧，复用缓冲的存储地址都没变（\(samples) 个样本）")
}

// MARK: - algo-opt-3：主体运动（块运动 / 相机补偿 / 往复节奏）、人体姿态

func vs3Hash(_ i: Int, _ j: Int, _ salt: Int) -> Double {
    var h = UInt64(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263 &+ salt &* 1_442_695_041)
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h % 1024) / 1023
}

/// 值噪声（格距 3 像素，亮度 40~220）
func vs3Value(_ x: Double, _ y: Double, salt: Int) -> Double {
    let gx = x / 3
    let gy = y / 3
    let i = floor(gx)
    let j = floor(gy)
    let fx = gx - i
    let fy = gy - j
    let ii = Int(i)
    let jj = Int(j)
    let a = vs3Hash(ii, jj, salt)
    let b = vs3Hash(ii + 1, jj, salt)
    let c = vs3Hash(ii, jj + 1, salt)
    let d = vs3Hash(ii + 1, jj + 1, salt)
    let v = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    return 40 + 180 * v
}

/// 合成画面：有纹理的静止背景 + 一块带着自己纹理水平往复的主体（peak：峰值速度，分析帧像素 / 帧），
/// shake：手持抖动（约 ±5 像素的平移 + 2% 缩放）
struct VS3Scene {
    var rect: (x: Double, y: Double, w: Double, h: Double)? = nil
    var hz: Double = 1
    var peak: Double = 1
    var shake = false

    func frame(_ k: Int) -> LumaFrame {
        let t = Double(k) * vsDt
        var ox = 0.0
        if rect != nil {
            ox = peak * 15 / (2 * Double.pi * hz) * sin(2 * Double.pi * hz * t)
        }
        var sx = 0.0
        var sy = 0.0
        var zoom = 1.0
        if shake {
            sx = 3.5 * sin(2 * Double.pi * 1.3 * t) + 1.5 * sin(2 * Double.pi * 2.9 * t + 1)
            sy = 3.0 * sin(2 * Double.pi * 1.1 * t + 0.5) + 2.0 * sin(2 * Double.pi * 2.3 * t + 2)
            zoom = 1 + 0.02 * sin(2 * Double.pi * 0.7 * t)
        }
        var px = [UInt8](repeating: 0, count: 64 * 36)
        for y in 0..<36 {
            for x in 0..<64 {
                let qx = (Double(x) + 0.5 - 32 - sx) / zoom + 32
                let qy = (Double(y) + 0.5 - 18 - sy) / zoom + 18
                var v: Double
                if let r = rect, qx >= r.x + ox, qx < r.x + ox + r.w, qy >= r.y, qy < r.y + r.h {
                    v = vs3Value(qx - ox + 100, qy + 100, salt: 2)
                } else {
                    v = vs3Value(qx + 200, qy + 200, salt: 1)
                }
                px[y * 64 + x] = UInt8(min(255, max(0, v.rounded())))
            }
        }
        return LumaFrame(width: 64, height: 36, pixels: px)
    }
}

struct VS3Analysis {
    var windows: [MotionWindow] = []
    var samples = 0
    var cameraFrames = 0
    /// 后一半样本的平均往复频率
    var hz: Double = 0
}

/// 15 fps 跑分析器，每 5 帧取一个窗口（1/3 秒）
func vs3Analyze(_ scene: VS3Scene, seconds: Double = 14) -> VS3Analysis {
    var an = MotionAnalyzer()
    an.phaseFitEnabled = true  // P3 L1：相位拟合只在相位脉动开着时算；这些窗口按「开着」造
    var acc = MotionWindowAccumulator()
    var r = VS3Analysis()
    var hzSum = 0.0
    var hzCount = 0
    let frames = Int(seconds * 15)
    for k in 0..<frames {
        if let s = an.analyze(scene.frame(k), time: Double(k) * vsDt) {
            acc.add(s)
            r.samples += 1
            if an.lastBlockMotion.cameraActive { r.cameraFrames += 1 }
            if k >= frames / 2 {
                hzSum += s.subject.hz
                hzCount += 1
            }
        }
        if k % 5 == 4 { r.windows.append(acc.drain()) }
    }
    r.hz = hzCount > 0 ? hzSum / Double(hzCount) : 0
    return r
}

/// 窗口 → 归一化 → 平滑 → 出口（上限 cap）：后一半的平均值、全程最大值、单拍最大升幅
func vs3Output(_ windows: [MotionWindow], cap: Double = 100, auto: Bool = true,
               tuned: Bool = false) -> (mean: Double, max: Int, rise: Int) {
    var chain = VSChain()
    // tuned：归一化也按动作调优。gentleAllowed 是 VSChain 的 false（没有轻抚的正面依据，同真机）：
    // 压低只来自 MotionNormalizer.unrhythmic（画面完全没节奏）
    chain.normalizer.actionTuned = tuned
    var stage = SyncOutputStage()
    let settings = AudioSyncSettings(maxPercent: cap)
    var outs: [Int] = []
    for w in windows {
        outs.append(stage.step(chain.step(w, auto: auto), settings: settings, hasSignal: true)[0])
    }
    let tail = outs.suffix(outs.count / 2)
    let mean = tail.isEmpty ? 0 : Double(tail.reduce(0, +)) / Double(tail.count)
    var rise = 0
    for i in 1..<max(1, outs.count) { rise = max(rise, outs[i] - outs[i - 1]) }
    return (mean, outs.max() ?? 0, rise)
}

let vs3Big = (x: 7.0, y: 4.5, w: 50.0, h: 27.0)      // 约 60% 画面
let vs3Small = (x: 30.0, y: 12.0, w: 15.0, h: 15.0)  // 约 10%
let vs3Mid = (x: 20.0, y: 9.0, w: 26.0, h: 18.0)     // 约 20%
let vs3Slow60 = vs3Analyze(VS3Scene(rect: vs3Big, hz: 0.5, peak: 1))
let vs3Fast60 = vs3Analyze(VS3Scene(rect: vs3Big, hz: 2, peak: 4))
let vs3Light10 = vs3Analyze(VS3Scene(rect: vs3Small, hz: 1, peak: 1))
let vs3Strong20 = vs3Analyze(VS3Scene(rect: vs3Mid, hz: 2, peak: 4))
let vs3Shake = vs3Analyze(VS3Scene(shake: true))
let vs3ShakeStrong = vs3Analyze(VS3Scene(rect: vs3Mid, hz: 2, peak: 4, shake: true))
let vs3Static = vs3Analyze(VS3Scene(), seconds: 6)

do {
    let slow = vs3Output(vs3Slow60.windows)
    let fast = vs3Output(vs3Fast60.windows)
    vcheck(slow.mean <= 0.5 * fast.mean && fast.mean - slow.mean >= 25,
           "主体：60% 画面慢动（0.5 Hz、约 1 px/帧）明显低于快动（2 Hz、约 4 px/帧）（\(Int(slow.mean)) vs \(Int(fast.mean))）")
    let light = vs3Output(vs3Light10.windows)
    vcheck(light.mean <= 30, "主体：80% 静止 + 10% 轻动（1 Hz、约 1 px/帧）判为轻（\(Int(light.mean))）")
    let strong = vs3Output(vs3Strong20.windows)
    let strong60 = vs3Output(vs3Strong20.windows, cap: 60)
    vcheck(strong.mean >= 70 && strong60.mean >= 0.7 * 60,
           "主体：静止背景 + 20% 快速往复（2 Hz、4 px/帧）热身后 > 上限的 70%（上限 100：\(Int(strong.mean))，上限 60：\(Int(strong60.mean))）")
    vcheck(strong.mean >= max(slow.mean, light.mean) + 30,
           "主体：20% 快速往复明显高于大面积慢动 / 小面积轻动（\(Int(strong.mean)) vs \(Int(slow.mean)) / \(Int(light.mean))）")
    let strongFixed = vs3Output(vs3Strong20.windows, auto: false)
    vcheck(strong.mean >= 70 && abs(strong.mean - strongFixed.mean) <= 10,
           "主体：自动适应不压持续的快速往复（开 \(Int(strong.mean)) / 关 \(Int(strongFixed.mean))）")
    let shake = vs3Output(vs3Shake.windows)
    let still = vs3Output(vs3Static.windows)
    vcheck(shake.mean <= 10 && shake.max <= 20 && still.max <= 3,
           "相机：有纹理的静止画面 + 手持抖动（±5 px + 轻微缩放）接近最低（均值 \(Int(shake.mean))、最高 \(shake.max)；不抖 \(still.max)）")
    let shakeStrong = vs3Output(vs3ShakeStrong.windows)
    vcheck(shakeStrong.mean >= shake.mean + 30,
           "相机：抖动 + 主体快速往复明显高于只抖动（\(Int(shakeStrong.mean)) vs \(Int(shake.mean))）")
    let rises = [slow, fast, light, strong, strong60, strongFixed, shake, shakeStrong].map { $0.rise }
    vcheck(rises.allSatisfy { $0 <= 20 }, "出口：主体运动各场景单拍升幅 ≤ 20（\(rises)）")
    vcheck(vs3Shake.cameraFrames * 10 >= vs3Shake.samples * 7 && vs3Strong20.cameraFrames * 20 <= vs3Strong20.samples
           && vs3Fast60.cameraFrames * 5 <= vs3Fast60.samples,
           "相机：抖动画面 ≥ 70% 的帧判为相机在动，固定镜头的 20% / 60% 主体几乎不误判（\(vs3Shake.cameraFrames)/\(vs3Shake.samples)、\(vs3Strong20.cameraFrames)、\(vs3Fast60.cameraFrames)）")
    vcheck(abs(vs3Strong20.hz - 2) <= 0.25 && abs(vs3Slow60.hz - 0.5) <= 0.15 && abs(vs3Light10.hz - 1) <= 0.2,
           "节奏：往复频率估得准（2 Hz → \(String(format: "%.2f", vs3Strong20.hz))，0.5 Hz → \(String(format: "%.2f", vs3Slow60.hz))，1 Hz → \(String(format: "%.2f", vs3Light10.hz))）")
}

do {
    let a = CameraTransform(m0: 1.01, m1: 0.02, t0: 1.5, t1: -0.5)
    let b = CameraTransform(m0: 0.99, m1: -0.01, t0: -2, t1: 3)
    let p = a.then(b).apply(x: 12, y: 7)
    let q0 = a.apply(x: 12, y: 7)
    let q = b.apply(x: q0.x, y: q0.y)
    vcheck(abs(p.x - q.x) < 1e-12 && abs(p.y - q.y) < 1e-12 && CameraTransform.identity.then(a) == a,
           "相机：连续几段相机运动合成 = 依次作用")
}

/// 合成骨架（64×36 分析帧，躯干约 10 像素）：hipX 髋（连带膝盖 60%）水平偏移，headY 头上下偏移，
/// shiftX / shiftY 全身平移，k 整体缩放（绕原点）
func vs3Skeleton(k: Double = 1, shiftX: Double = 0, shiftY: Double = 0, hipX: Double = 0, headY: Double = 0,
                 confidence: Double = 0.9) -> PoseCandidate {
    var p = PoseCandidate()
    p.confidence = confidence
    let joints: [(PoseJoint, Double, Double)] = [
        (.nose, 32, 7 + headY), (.neck, 32, 10 + 0.5 * headY), (.leftShoulder, 28, 11), (.rightShoulder, 36, 11),
        (.root, 32 + hipX, 20), (.leftHip, 29.5 + hipX, 20), (.rightHip, 34.5 + hipX, 20),
        (.leftKnee, 29 + 0.6 * hipX, 27), (.rightKnee, 35 + 0.6 * hipX, 27), (.leftWrist, 26, 18), (.rightWrist, 38, 18),
    ]
    for (j, x, y) in joints { p.set(j, x: (x + shiftX) * k, y: (y + shiftY) * k, confidence: confidence) }
    return p
}

struct VS3PoseRun {
    /// 每拍：归一化 × 热身 × 平滑后的 0~100，以及出口值
    var outs: [Double] = []
    var stage: [Int] = []
    var readings: [PoseReading] = []
    var maxWeight = 0.0
}

/// 15 Hz 画面样本（块运动主体分数固定为 flow）+ 每 5 帧 3 次姿态估计（约 9 Hz，间隔不均匀），每 5 帧一拍。
/// pose(i, t) 返回 nil = 第 i 次估计没检测到人；camera(t0, t1)：两次估计之间的相机运动
func vs3PoseRun(seconds: Double = 14, flow: Double, frameHeight: Double = 36,
                pose: (Int, Double) -> PoseCandidate?,
                camera: (Double, Double) -> CameraTransform = { _, _ in .identity }) -> VS3PoseRun {
    var tracker = PoseMotionTracker()
    var acc = MotionWindowAccumulator()
    var chain = VSChain()
    var stage = SyncOutputStage()
    let settings = AudioSyncSettings(maxPercent: 100)
    var r = VS3PoseRun()
    var last = 0.0
    var i = 0
    for k in 0..<Int(seconds * 15) {
        let t = Double(k) * vsDt
        acc.add(MotionSample(time: t, energy: 1, coverage: 0.2, isCut: false, isHeld: false,
                             subject: SubjectReading(valid: true, score: flow)))
        if k % 5 == 0 || k % 5 == 2 || k % 5 == 4 {
            let found = pose(i, t).map { [$0] } ?? []
            let reading = tracker.update(time: t, candidates: found, camera: camera(last, t), continuous: true,
                                         frameHeight: frameHeight)
            r.readings.append(reading)
            acc.addPose(reading)
            last = t
            i += 1
        }
        if k % 5 == 4 {
            let v = chain.step(acc.drain())
            r.outs.append(v)
            r.stage.append(stage.step(v, settings: settings, hasSignal: true)[0])
            r.maxWeight = max(r.maxWeight, chain.normalizer.poseWeight)
        }
    }
    return r
}

func vs3Late(_ a: [Double]) -> Double {
    let tail = a.suffix(a.count / 2)
    return tail.isEmpty ? 0 : tail.reduce(0, +) / Double(tail.count)
}

func vs3HipWave(_ t: Double) -> Double { 2.0 * sin(2 * Double.pi * 2 * t) }        // 2 Hz、约 0.2 躯干
func vs3NodWave(_ t: Double) -> Double { 0.3 * sin(2 * Double.pi * 0.5 * t) }      // 0.5 Hz、约 0.03 躯干
func vs3ShakeX(_ t: Double) -> Double { 4 * sin(2 * Double.pi * 1.3 * t) + 2 * sin(2 * Double.pi * 2.9 * t + 1) }
func vs3ShakeY(_ t: Double) -> Double { 3 * sin(2 * Double.pi * 1.1 * t + 0.5) }

let vs3PoseNone = vs3PoseRun(flow: 0.2) { _, _ in nil }
let vs3PoseHips = vs3PoseRun(flow: 0.2) { _, t in vs3Skeleton(hipX: vs3HipWave(t)) }
let vs3PoseNod = vs3PoseRun(flow: 0.2) { _, t in vs3Skeleton(headY: vs3NodWave(t)) }
let vs3PosePanCam = vs3PoseRun(flow: 0, pose: { _, t in vs3Skeleton(shiftX: vs3ShakeX(t), shiftY: vs3ShakeY(t)) },
                               camera: { a, b in
                                   CameraTransform(t0: vs3ShakeX(b) - vs3ShakeX(a), t1: vs3ShakeY(b) - vs3ShakeY(a))
                               })
let vs3PoseLinear = vs3PoseRun(flow: 0) { _, t in vs3Skeleton(shiftX: -20 + 4 * t) }
let vs3PoseHips2x = vs3PoseRun(flow: 0.2, frameHeight: 72) { _, t in vs3Skeleton(k: 2, hipX: vs3HipWave(t)) }
let vs3PoseFlicker = vs3PoseRun(flow: 0.2) { i, t in i % 6 < 3 ? vs3Skeleton(hipX: vs3HipWave(t)) : nil }
let vs3PoseBlip = vs3PoseRun(flow: 0.2) { i, t in i % 27 < 3 ? vs3Skeleton(hipX: 3 * vs3HipWave(t)) : nil }

do {
    let hips = vs3Late(vs3PoseHips.outs)
    let hz = vs3PoseHips.readings.last(where: { $0.present })?.hz ?? 0
    vcheck(hips >= 70 && abs(hz - 2) <= 0.2,
           "姿态：髋部 2 Hz 大幅往复（约 0.2 躯干）→ 强（\(Int(hips))，\(String(format: "%.2f", hz)) Hz；块运动分数只有 0.2）")
    let nod = vs3Late(vs3PoseNod.outs)
    vcheck(nod <= 20 && nod <= hips - 50, "姿态：头部 0.5 Hz 小幅点头（约 0.03 躯干）→ 轻（\(Int(nod))）")
    let pan = vs3PosePanCam.outs.max() ?? 99
    let linear = vs3PoseLinear.outs.max() ?? 99
    vcheck(pan <= 5 && linear <= 10,
           "姿态：全身一起平移（手持抖动且给了相机运动 / 匀速摇镜头）→ 接近最低（最高 \(Int(pan)) / \(Int(linear))）")
    var scoreDiff = 0.0
    for (a, b) in zip(vs3PoseHips.readings, vs3PoseHips2x.readings) { scoreDiff = max(scoreDiff, abs(a.score - b.score)) }
    var outDiff = 0.0
    for (a, b) in zip(vs3PoseHips.outs, vs3PoseHips2x.outs) { outDiff = max(outDiff, abs(a - b)) }
    vcheck(vs3PoseHips.readings.count == vs3PoseHips2x.readings.count && scoreDiff <= 1e-9 && outDiff <= 1e-9,
           "姿态：同一动作放大 2 倍（坐标和帧高一起）分数完全一样（差 \(scoreDiff) / \(outDiff)）")
    let flicker = vs3PoseFlicker.outs
    var jump = 0.0
    for k in max(1, flicker.count / 2)..<flicker.count { jump = max(jump, abs(flicker[k] - flicker[k - 1])) }
    let hipsMax = vs3PoseHips.outs.max() ?? 0
    var rise = 0
    for k in 1..<vs3PoseFlicker.stage.count { rise = max(rise, vs3PoseFlicker.stage[k] - vs3PoseFlicker.stage[k - 1]) }
    vcheck((flicker.max() ?? 99) <= hipsMax + 2 && jump <= 10 && rise <= 20,
           "姿态：检测一闪一闪（有 3 次、没 3 次）不出尖峰（最高 \(Int(flicker.max() ?? 0)) ≤ 稳定检测 \(Int(hipsMax))，后半段单拍变化 \(String(format: "%.1f", jump))）")
    let blip = vs3PoseBlip.outs.max() ?? 99
    let none = vs3PoseNone.outs.max() ?? 0
    vcheck(blip <= none + 3 && vs3PoseBlip.maxWeight == 0,
           "姿态：偶尔 0.3 秒的误检（剧烈动作）不起作用（最高 \(Int(blip)) vs 没人 \(Int(none))）")
}

/// 15 Hz 直接喂 StrokeRhythm，记下每一步的估计
func vs3Rhythm(seconds: Double, _ v: (Double) -> (x: Double, y: Double)) -> [StrokeRhythm.Estimate] {
    var r = StrokeRhythm()
    var out: [StrokeRhythm.Estimate] = []
    for k in 0..<Int(seconds * 15) {
        let t = Double(k) * vsDt
        let p = v(t)
        r.add(time: t, x: p.x, y: p.y)
        out.append(r.estimate)
    }
    return out
}

do {
    // 慢于 0.5 Hz：自相关从最短滞后一路往下走，最高点在搜索边界上，不是峰 → 没有节奏（以前会报 3.75~4.3 Hz）
    var falseBeats: [String] = []
    for f in [0.3, 0.35, 0.4] {
        let e = vs3Rhythm(seconds: 12) { t in
            let v = cos(2 * Double.pi * f * t)
            return (0.8 * v, 0.6 * v)
        }
        if let bad = e.first(where: { $0.confidence != 0 || $0.hz != 0 }) {
            falseBeats.append("\(f) Hz → \(String(format: "%.2f", bad.hz)) Hz")
        }
    }
    // 平滑的随机漂移（每个轴 3 个 0.05~0.2 Hz、随机相位 / 幅度的分量）：没有往复 → 没有节奏
    let drift = vs3Rhythm(seconds: 20) { t in
        var x = 0.0
        var y = 0.0
        for j in 0..<3 {
            x += (0.5 + vs3Hash(j, 0, 7)) * sin(2 * Double.pi * (0.05 + 0.15 * vs3Hash(j, 1, 7)) * t
                                               + 2 * Double.pi * vs3Hash(j, 2, 7))
            y += (0.5 + vs3Hash(j, 0, 8)) * sin(2 * Double.pi * (0.05 + 0.15 * vs3Hash(j, 1, 8)) * t
                                               + 2 * Double.pi * vs3Hash(j, 2, 8))
        }
        return (x, y)
    }
    if let bad = drift.first(where: { $0.confidence != 0 || $0.hz != 0 }) {
        falseBeats.append("漂移 → \(String(format: "%.2f", bad.hz)) Hz")
    }
    vcheck(falseBeats.isEmpty, "节奏：0.3~0.4 Hz 慢往复 / 平滑随机漂移不判成快节奏（\(falseBeats)）")

    // 0.7 Hz：头 2 秒历史太短、够不到真周期，不能报快节奏；攒够以后照样认出 0.7 Hz
    let slow = vs3Rhythm(seconds: 8) { t in
        let v = sin(2 * Double.pi * 0.7 * t)
        return (v, 0)
    }
    let early = slow.prefix(30).map { $0.hz }.max() ?? 99
    let last = slow.last ?? StrokeRhythm.Estimate()
    vcheck(early < 1 && abs(last.hz - 0.7) <= 0.1 && last.confidence >= 0.5,
           "节奏：0.7 Hz 头 2 秒没有假快节奏（最高 \(String(format: "%.2f", early)) Hz），之后认出 \(String(format: "%.2f", last.hz)) Hz")
}

do {
    // 换人（原来的人不见了，另一个人在 2 个身体尺度外）不算关节速度、不进节奏：
    // Vision 慢（0.3 秒一次）时以前会把 20 像素 / 0.3 秒的跳变当成约 6 躯干 / 秒的动作
    var tracker = PoseMotionTracker()
    var maxScore = 0.0
    var present = 0
    for i in 0..<40 {
        let t = Double(i) * 0.3
        let person = vs3Skeleton(shiftX: i % 2 == 0 ? -10 : 10)
        let r = tracker.update(time: t, candidates: [person], camera: .identity, continuous: true, frameHeight: 36)
        maxScore = max(maxScore, r.score)
        if r.present { present += 1 }
    }
    vcheck(maxScore <= 1e-9 && present == 0,
           "姿态：两个人轮流出现（每次都是换人）不算速度（最高分 \(String(format: "%.3f", maxScore))，有读数 \(present) 次）")
}

do {
    // AVAssetTrack.preferredTransform（缓冲 16×9）→ 显示坐标 → Vision 归一化（左下角原点）→ bufferPoint 应该回到原点
    let w = 16.0
    let h = 9.0
    let cases: [(PoseOrientation, Double, Double, Double, Double, Double, Double, Double, Double)] = [
        (.up, 1, 0, 0, 1, 0, 0, w, h),
        (.right, 0, 1, -1, 0, h, 0, h, w),
        (.left, 0, -1, 1, 0, 0, w, h, w),
        (.down, -1, 0, 0, -1, w, h, w, h),
    ]
    var ok = true
    for (o, a, b, c, d, tx, ty, dw, dh) in cases {
        ok = ok && PoseOrientation.from(a: a, b: b, c: c, d: d) == o
        for (bx, by) in [(2.0, 1.0), (13.0, 7.5), (8.0, 4.5)] {
            let dx = a * bx + c * by + tx
            let dy = b * bx + d * by + ty
            let p = o.bufferPoint(visionX: dx / dw, visionY: 1 - dy / dh)
            ok = ok && abs(p.x - bx / w) < 1e-12 && abs(p.y - by / h) < 1e-12
        }
    }
    ok = ok && PoseOrientation.from(a: 0.5, b: 0.2, c: 0, d: 1) == .up
    vcheck(ok, "姿态：视频轨方向（竖拍 / 倒拍）→ Vision 方向，检测结果换回缓冲坐标正确")
}

do {
    // 稳态不分配（algo-opt-3）：块运动 / 主体跟踪的缓冲也在 scratchAddresses 里，抖动 + 主体往复跑一轮后地址不变
    let scene = VS3Scene(rect: vs3Mid, hz: 2, peak: 4, shake: true)
    var an = MotionAnalyzer()
    for k in 0..<45 { _ = an.analyze(scene.frame(k), time: Double(k) * vsDt) }
    // 新缓冲排在 scratchAddresses 末尾（块运动 + 主体跟踪 / 往复节奏）
    let extra = BlockMotionEstimator().scratchAddresses.count + SubjectFlowTracker().scratchAddresses.count
    let warm = Array(an.scratchAddresses.suffix(extra))
    for k in 45..<120 { _ = an.analyze(scene.frame(k), time: Double(k) * vsDt) }
    vcheck(extra >= 20 && an.scratchAddresses.count >= extra + 5 && Array(an.scratchAddresses.suffix(extra)) == warm,
           "稳态不分配：块运动 / 主体跟踪的 \(extra) 个缓冲在抖动 + 往复画面里地址不变")
}

/// 确定性的近似高斯噪声（Box–Muller，用 vs3Hash）：均值 0、标准差 1
func vs3Gauss(_ i: Int, _ j: Int, _ salt: Int) -> Double {
    let u1 = 1 - 0.999 * vs3Hash(i, j, salt)
    let u2 = vs3Hash(i, j, salt + 1)
    return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
}

/// 每个关键点 x / y 各加 sigma 像素的检测抖动（第 i 次估计、互相独立）
func vs3Jittered(_ base: PoseCandidate, i: Int, sigma: Double, salt: Int = 11) -> PoseCandidate {
    var p = base
    for j in 0..<PoseJoint.count {
        p.x[j] += sigma * vs3Gauss(i, 2 * j, salt)
        p.y[j] += sigma * vs3Gauss(i, 2 * j + 1, salt)
    }
    return p
}

do {
    // 复审 M1：静止的人 + Vision 关键点抖动（σ = 1.5% 躯干 = 0.15 像素，每个点每次独立）→ 接近最低；
    // 同样的抖动叠在髋部 2 Hz 大幅往复上照样是强
    let still = vs3PoseRun(flow: 0) { i, _ in vs3Jittered(vs3Skeleton(), i: i, sigma: 0.15) }
    let stillMax = still.outs.max() ?? 99
    let stillScore = still.readings.map { $0.score }.max() ?? 99
    let moving = vs3PoseRun(flow: 0.2) { i, t in vs3Jittered(vs3Skeleton(hipX: vs3HipWave(t)), i: i, sigma: 0.15) }
    let movingLate = vs3Late(moving.outs)
    vcheck(stillMax <= 10 && stillScore <= 0.1 && movingLate >= 65,
           "姿态：静止的人 + 1.5% 躯干的检测抖动 → 接近最低（最高 \(Int(stillMax))，姿态分 \(String(format: "%.3f", stillScore))）；"
           + "叠加同样抖动的 2 Hz 髋部往复仍强（\(Int(movingLate))）")
}

do {
    // 复审 M2：髋 2 Hz 往复 6 秒后髋 / 膝被挡住（上半身还在、同一个人），0.5 秒后髋的旧节奏不再加成
    var tracker = PoseMotionTracker()
    var before = PoseReading()
    var staleHz = 0.0
    var after = 0
    for i in 0..<80 {
        let t = Double(i) * 0.11
        var p = vs3Skeleton(hipX: vs3HipWave(t))
        if t >= 6 {
            for j in [PoseJoint.root, .leftHip, .rightHip, .leftKnee, .rightKnee] { p.c[j.rawValue] = 0 }
        }
        let r = tracker.update(time: t, candidates: [p], camera: .identity, continuous: true, frameHeight: 36)
        if t < 6 { before = r }
        if t >= 6.6, r.present {
            staleHz = max(staleHz, r.hz)
            after += 1
        }
    }
    vcheck(before.present && abs(before.hz - 2) <= 0.2 && after > 0 && staleHz == 0,
           "姿态：髋部被挡住超过 0.5 秒，旧的 2 Hz 节奏不再加成（挡住前 \(String(format: "%.2f", before.hz)) Hz，"
           + "之后最高 \(String(format: "%.2f", staleHz)) Hz，读数 \(after) 次）")
}

do {
    // 复审 L1：跟了 A（髋部往复）3 秒后换成远处静止的 B：B 不能沿用 A 的速度历史，重新攒够 3 个样本前没有读数
    var tracker = PoseMotionTracker()
    var afterSwitch: [PoseReading] = []
    for i in 0..<40 {
        let t = Double(i) * 0.11
        let p = t < 3 ? vs3Skeleton(hipX: vs3HipWave(t)) : vs3Skeleton(shiftX: 30)
        let r = tracker.update(time: t, candidates: [p], camera: .identity, continuous: true, frameHeight: 36)
        if t >= 3 { afterSwitch.append(r) }
    }
    let early = afterSwitch.prefix(3)
    let later = afterSwitch.dropFirst(3)
    vcheck(early.count == 3 && early.allSatisfy { !$0.present } && later.allSatisfy { $0.present && $0.score <= 1e-9 },
           "姿态：换人后不沿用上一个人的速度历史（换人后前 3 次 \(early.map { $0.present })）")
}

do {
    // 复审 L2：切镜头到没人的画面不保持切镜前的姿态分数；分析停够保持时间（发热暂停）后恢复，姿态融合从头确认
    var on = MotionWindow()
    on.frames = 5
    on.subjectFrames = 5
    on.poseFrames = 3
    on.posePresentFrames = 3
    on.poseScore = 1
    on.poseConfidence = 0.9
    var off = on
    off.poseFrames = 3
    off.posePresentFrames = 0
    var cut = off
    cut.cutCount = 1
    var held = PoseBlend()
    var cutBlend = PoseBlend()
    for _ in 0..<10 {
        _ = held.step(on, flow: 0, dt: 0.3)
        _ = cutBlend.step(on, flow: 0, dt: 0.3)
    }
    let peak = held.step(on, flow: 0, dt: 0.3)
    _ = cutBlend.step(on, flow: 0, dt: 0.3)
    let heldOut = held.step(off, flow: 0, dt: 0.3)
    let cutOut = cutBlend.step(cut, flow: 0, dt: 0.3)
    let cutNext = cutBlend.step(off, flow: 0, dt: 0.3)
    vcheck(peak >= 0.75 && heldOut >= peak - 1e-9 && cutOut <= peak - 0.1 && cutNext < cutOut,
           "姿态：切镜到没人的画面直接降权重（不切 \(String(format: "%.2f", heldOut))，切镜 \(String(format: "%.2f", cutOut)) → \(String(format: "%.2f", cutNext))）")

    var paused = MotionNormalizer()
    var blip = MotionNormalizer()
    for _ in 0..<12 {
        _ = paused.step(on, gainDb: 0, auto: true, dt: 0.3)
        _ = blip.step(on, gainDb: 0, auto: true, dt: 0.3)
    }
    let before = paused.poseWeight
    for _ in 0..<5 { _ = paused.step(.empty, gainDb: 0, auto: true, dt: 0.3) }
    _ = blip.step(.empty, gainDb: 0, auto: true, dt: 0.3)
    _ = paused.step(off, gainDb: 0, auto: true, dt: 0.3)
    _ = blip.step(off, gainDb: 0, auto: true, dt: 0.3)
    vcheck(before >= 0.7 && paused.poseWeight == 0 && blip.poseWeight >= 0.7,
           "姿态：分析停 1.5 秒（发热暂停）后恢复不沿用暂停前的姿态（\(String(format: "%.2f", before)) → "
           + "\(String(format: "%.2f", paused.poseWeight))；只空 1 拍保持 \(String(format: "%.2f", blip.poseWeight))）")
}

do {
    // 第 3 轮复审 M1：块运动很强（0.9）时，Vision 认到的人是静止的（多人画面里清楚的那个不动），
    // 或者髋 / 膝置信度只有 0.2（不可用、只剩静止的上半身）：姿态不能把输出压没，至少保留只看块运动时的 0.6
    let flowOnly = vs3Late(vs3PoseRun(flow: 0.9) { _, _ in nil }.outs)
    let still = vs3PoseRun(flow: 0.9) { _, _ in vs3Skeleton() }
    let stillLate = vs3Late(still.outs)
    let lowHips = vs3Late(vs3PoseRun(flow: 0.9) { _, t in
        var p = vs3Skeleton(hipX: vs3HipWave(t))
        for j in [PoseJoint.root, .leftHip, .rightHip, .leftKnee, .rightKnee] { p.c[j.rawValue] = 0.2 }
        return p
    }.outs)
    let floorOK: Bool = stillLate >= 0.6 * flowOnly && lowHips >= 0.6 * flowOnly
    vcheck(flowOnly >= 80 && still.maxWeight >= 0.7 && floorOK,
           "姿态：块运动 0.9 + 认到静止的人 / 髋部不可用，不否决强运动（只看块运动 \(Int(flowOnly))，"
           + "静止的人 \(Int(stillLate))，髋置信度 0.2 \(Int(lowHips))）")
}

do {
    // 第 3 轮复审 L1：切镜在一拍中间，同一拍里还有切镜前的有人读数、切镜后才回来的旧帧读数（Vision 异步）：
    // 这一拍按「切镜、没人」处理，直接降权重；下一拍迟到的旧帧读数也不算；切镜后的新读数照常算
    var acc = MotionWindowAccumulator()
    var blend = PoseBlend()
    let cutTime = 12 * 0.3 + 2 * 0.06
    func window(_ k: Int, cutAt: Int? = nil, persons: Bool = true, extra: PoseReading? = nil) -> MotionWindow {
        let t0 = Double(k) * 0.3
        for j in 0..<5 {
            let t = t0 + Double(j) * 0.06
            acc.add(MotionSample(time: t, energy: 1, coverage: 0.2, isCut: j == cutAt, isHeld: false,
                                 subject: SubjectReading(valid: true, score: 0)))
            guard j % 2 == 0 else { continue }
            if let c = cutAt {
                if j < c {
                    acc.addPose(PoseReading(time: t, present: true, score: 1, confidence: 0.9))
                } else if j == c {
                    acc.addPose(PoseReading(time: t - 0.11, present: true, score: 1, confidence: 0.9))
                } else {
                    acc.addPose(PoseReading(time: t, present: false))
                }
            } else {
                acc.addPose(PoseReading(time: t, present: persons, score: persons ? 1 : 0, confidence: persons ? 0.9 : 0))
            }
        }
        if let r = extra { acc.addPose(r) }
        return acc.drain()
    }
    for k in 0..<11 { _ = blend.step(window(k), flow: 0, dt: 0.3) }
    let peak = blend.step(window(11), flow: 0, dt: 0.3)
    let cutWindow = window(12, cutAt: 2)
    let cutOut = blend.step(cutWindow, flow: 0, dt: 0.3)
    let lateWindow = window(13, persons: false,
                            extra: PoseReading(time: cutTime - 0.02, present: true, score: 1, confidence: 0.9))
    let lateOut = blend.step(lateWindow, flow: 0, dt: 0.3)
    let postWindow = window(14, persons: false,
                            extra: PoseReading(time: 14 * 0.3 + 0.2, present: true, score: 0.2, confidence: 0.8))
    let windowsOK: Bool = cutWindow.cutCount == 1 && cutWindow.posePresentFrames == 0
        && lateWindow.posePresentFrames == 0 && postWindow.posePresentFrames == 1
    let blendOK: Bool = peak >= 0.75 && cutOut <= peak - 0.1 && lateOut < cutOut
    vcheck(windowsOK && blendOK,
           "姿态：切镜在一拍中间、同拍有切镜前的读数，照样直接降权重（\(String(format: "%.2f", peak)) → "
           + "\(String(format: "%.2f", cutOut)) → \(String(format: "%.2f", lateOut))；切镜后的读数 "
           + "\(postWindow.posePresentFrames) 次照常算）")
}

// MARK: - rhythm-follow P1：设备档位↔频率标定表 / 节奏跟随 / 伸缩按频率出档位

do {
    let m = DeviceRateMap.parse("20:0.6, 40:1.1, 60:1.7, 99:2.8")
    vcheck(m?.points.count == 4 && m?.minLevel == 20 && m?.maxLevel == 99 && m?.minHz == 0.6 && m?.maxHz == 2.8,
           "标定表：标准格式解析")
    let wide = DeviceRateMap.parse("99：2.8；20：0.6，60：1.7\n40: 1.1 ")
    vcheck(wide == m, "标定表：全角冒号 / 逗号 / 分号 / 换行、乱序都认，按档位排序")
    // 复审 L5：空白（空格 / Tab / 换行 / 全角空格）和顿号也是分隔，冒号两边可以有空格
    let spaced = DeviceRateMap.parse("20:0.6 40:1.1 60:1.7 99:2.8")
    let dunhao = DeviceRateMap.parse("20：0.6、40：1.1、60：1.7、99：2.8")
    let messy = DeviceRateMap.parse("  20 : 0.6\t40: 1.1\n60 :1.7\u{3000}99:2.8  ")
    let spaceBad = ["20 0.6, 40:1", "20:0.6 40", "20:0.6 40:1.1 x", "20: :0.6, 40:1"].filter { DeviceRateMap.parse($0) != nil }
    vcheck(spaced == m && dunhao == m && messy == m && spaceBad.isEmpty,
           "标定表（L5）：空格 / Tab / 全角空格 / 顿号分隔、冒号两边空格都认；缺冒号 / 多余字段照样按填错（误收：\(spaceBad)）")
    vcheck(m.flatMap { DeviceRateMap.parse($0.text) } == m, "标定表：text 能原样解析回来（\(m?.text ?? "nil")）")
    let bad = ["", "  ", "abc", "20:0.6", "20:0.6, 40:0.5", "20:0.6, 20:0.8", "0:0.5, 50:1", "20:0.6, 100:3",
               "20:0.05, 40:1", "20:0.6, 40:9", "20:nan, 40:1", "20:0.6, 40", "20:0.6:1, 40:1", "20:0.6, x:1",
               (1...13).map { "\($0 * 7):\(Double($0) * 0.5)" }.joined(separator: ","),
               "20:0.6, 99:2.8" + String(repeating: " ", count: VisualSyncSettings.maxRateTableLength)]
    let accepted = bad.filter { DeviceRateMap.parse($0) != nil }
    vcheck(accepted.isEmpty, "标定表：空 / 格式错 / 不单调 / 越界 / 超 12 点 / 超长都按没标定（误收：\(accepted)）")
    vcheck(DeviceRateMap.parse((1...12).map { "\($0 * 8):\(Double($0) * 0.5)" }.joined(separator: ",")) != nil,
           "标定表：12 点能收")
    if let m {
        var mono = true
        var prev = 0
        var hz = 0.1
        while hz <= 5 {
            let l = m.level(forHz: hz)
            if l < prev || l < 20 || l > 99 { mono = false }
            prev = l
            hz += 0.01
        }
        vcheck(mono && m.level(forHz: 0.2) == 20 && m.level(forHz: 4) == 99 && m.level(forHz: .nan) == 20
               && m.level(forHz: 1.1) == 40 && m.level(forHz: 1.4) == 50,
               "标定表：频率 → 档位单调、夹到表的两端、中间线性插值（1.4 Hz → \(m.level(forHz: 1.4))）")
        var inverse = true
        for l in 20...99 {
            guard let h = m.hz(forLevel: l), abs(m.level(forHz: h) - l) <= 1 else { inverse = false; continue }
        }
        vcheck(inverse && m.hz(forLevel: 19) == nil && m.hz(forLevel: 99) == 2.8,
               "标定表：档位 → 频率和反查一致（±1 档），低于最低档 nil")
    }
    let u = DeviceRateMap.uncalibrated
    vcheck(u.minLevel == 10 && u.maxLevel == 99 && u.level(forHz: 1) == 28 && u.level(forHz: 2) == 63,
           "标定表：没标定时的保守猜测 10 档 0.5 Hz ~ 99 档 3 Hz（1 Hz → \(u.level(forHz: 1))，2 Hz → \(u.level(forHz: 2))）")
}

/// algo-opt-3（07ac4d4）的 StrokeRhythm 原样拷贝（只把类型名换掉、去掉用不到的成员）：rhythm-follow 关着时
/// 分数路径必须和它逐位相同（复审 M1：减半只能进 followEstimate）
struct BaseStrokeRhythm07 {
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

    private var times = [Double](repeating: 0, count: BaseStrokeRhythm07.capacity)
    private var xs = [Double](repeating: 0, count: BaseStrokeRhythm07.capacity)
    private var ys = [Double](repeating: 0, count: BaseStrokeRhythm07.capacity)
    private var count = 0
    private var head = 0
    private var projected = [Double](repeating: 0, count: BaseStrokeRhythm07.capacity)
    private var projectedTimes = [Double](repeating: 0, count: BaseStrokeRhythm07.capacity)
    private var grid = [Double](repeating: 0, count: BaseStrokeRhythm07.gridCapacity)
    private var corr = [Double](repeating: 0, count: BaseStrokeRhythm07.maxLag + 2)
    private(set) var estimate = Estimate()

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
        guard b >= a, b >= cc else { return Estimate() }
        let den = a - 2 * b + cc
        let delta = den < -1e-12 ? min(0.5, max(-0.5, 0.5 * (a - cc) / den)) : 0
        let lag = min(Double(kMax), max(Double(Self.minLag), Double(pick) + delta))
        let hz = Self.gridRate / lag
        let amplitude = 2.0.squareRoot() * rms / (2 * Double.pi * hz)
        guard hz.isFinite, amplitude.isFinite else { return Estimate() }
        return Estimate(hz: hz, confidence: MotionStats.clamp01(b), amplitude: amplitude)
    }
}

/// algo-opt-3（07ac4d4）的 SyncOutputStage.step(value) 原样拷贝：rhythm-follow 关着时出口必须和它逐位相同
struct BaseSyncOutputStage07 {
    static let maxRisePerTick = 20
    static let zeroHoldTicks = 2

    private(set) var last: [Int] = [0, 0, 0, 0]
    private var zeroAge: [Int] = [Int](repeating: BaseSyncOutputStage07.zeroHoldTicks, count: 4)

    mutating func reset() {
        last = [0, 0, 0, 0]
        zeroAge = [Int](repeating: Self.zeroHoldTicks, count: 4)
    }

    static func floorPercent(settings s: AudioSyncSettings, hasSignal: Bool) -> Double {
        hasSignal ? min(s.maxPercent, s.minPercent) : 0
    }

    static func hardCap(_ s: AudioSyncSettings) -> Int {
        guard s.maxPercent.isFinite else { return 0 }
        return max(0, min(Int(s.maxPercent.rounded(.down)), BCProtocol.maxManualLevel))
    }

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

    static func preview(_ value: Double, settings s: AudioSyncSettings, hasSignal: Bool) -> Int {
        min(hardCap(s), map(value, cap: s.maxPercent, floor: floorPercent(settings: s, hasSignal: hasSignal)))
    }

    mutating func step(_ value: Double, settings s: AudioSyncSettings, hasSignal: Bool) -> [Int] {
        let mapped = Self.map(value, cap: s.maxPercent, floor: Self.floorPercent(settings: s, hasSignal: hasSignal))
        let target = s.channels.levels(percent: mapped)
        let cap = Self.hardCap(s)
        var out = [0, 0, 0, 0]
        for ch in 0..<2 {
            let prev = last[ch]
            var p = ch < target.count ? target[ch] : 0
            p = min(p, prev + Self.maxRisePerTick)
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

/// 同一串样本（rate 次 / 秒）同时喂当前的 StrokeRhythm 和 07ac4d4 原版：每一步的 estimate / followEstimate / 原版估计
func rfRhythm(seconds: Double, rate: Double = 15, _ v: (Double) -> (x: Double, y: Double))
    -> (now: [StrokeRhythm.Estimate], follow: [StrokeRhythm.FollowEstimate], base: [StrokeRhythm.Estimate]) {
    var r = StrokeRhythm()
    var b = BaseStrokeRhythm07()
    var now: [StrokeRhythm.Estimate] = []
    var follow: [StrokeRhythm.FollowEstimate] = []
    var base: [StrokeRhythm.Estimate] = []
    for k in 0..<Int(seconds * rate) {
        let t = Double(k) * (1 / rate)
        let p = v(t)
        r.add(time: t, x: p.x, y: p.y)
        b.add(time: t, x: p.x, y: p.y)
        now.append(r.estimate)
        follow.append(r.followEstimate)
        base.append(StrokeRhythm.Estimate(hz: b.estimate.hz, confidence: b.estimate.confidence,
                                          amplitude: b.estimate.amplitude))
    }
    return (now, follow, base)
}

/// 测试用的确定性噪声（同上面随机测试的 LCG），-1~1
struct RFNoise {
    var seed: UInt64
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31) * 2 - 1
    }
}

do {
    // 复审 M1：分数路径（estimate → StrokeScore）和 07ac4d4 逐位相同，减半只进 followEstimate
    // 真实视频 2 Hz（15 fps 上 7.5 格一个周期）+ 1 Hz 的身体晃动、速度量化成整数像素：自相关 15 格 ≈ 1.0、7/8 格偏低
    let mixed = rfRhythm(seconds: 10) { t in
        ((5 * cos(2 * Double.pi * 2 * t) + 1.5 * cos(2 * Double.pi * t)).rounded(), 0)
    }
    // 真的 1 Hz、推拉不对称（30% / 60% 二次谐波）：一半滞后上是负相关，不能减半成 2 Hz
    let pushPull = [0.3, 0.6].map { h in
        rfRhythm(seconds: 10) { t in (cos(2 * Double.pi * t) + h * cos(4 * Double.pi * t + 0.5), 0) }
    }
    var noise = RFNoise(seed: 2024)
    let noisy = rfRhythm(seconds: 12) { t in
        (2 * sin(2 * Double.pi * 1.7 * t) + 0.8 * noise.next(), 1.2 * cos(2 * Double.pi * 0.6 * t) + 0.5 * noise.next())
    }
    var irregular = StrokeRhythm()
    var irregularBase = BaseStrokeRhythm07()
    var irregularSame = true
    for k in 0..<(14 * 15) where k % 5 == 0 || k % 5 == 2 || k % 5 == 4 {
        let t = Double(k) * vsDt
        let x = 3 * sin(2 * Double.pi * 1.3 * t)
        irregular.add(time: t, x: x, y: 0.5 * x)
        irregularBase.add(time: t, x: x, y: 0.5 * x)
        let e = irregular.estimate
        let b = irregularBase.estimate
        if e.hz != b.hz || e.confidence != b.confidence || e.amplitude != b.amplitude { irregularSame = false }
    }
    let runs = [mixed] + pushPull + [noisy]
    let same = runs.allSatisfy { $0.now == $0.base }
    vcheck(same && irregularSame && mixed.now.count == 150,
           "节奏（M1）：分数用的 estimate 和 algo-opt-3 原版逐位相同（半整数周期的 2 Hz 在分数路径上仍是 "
           + "\(String(format: "%.2f", mixed.now.last?.hz ?? 0)) Hz，和原版一样）")
    let late = mixed.follow.suffix(90)
    vcheck(late.allSatisfy { abs($0.hz - 2) <= 0.1 && $0.confidence >= 0.4 }
           && pushPull.allSatisfy { $0.follow.suffix(90).allSatisfy { abs($0.hz - 1) <= 0.05 } },
           "节奏（跟随）：半整数周期的 2 Hz 不被当成 1 Hz（\(String(format: "%.2f", late.last?.hz ?? 0)) Hz），推拉不对称的 1 Hz 不减半")

    // 同一个 SubjectFlowTracker：分数 / hz / 置信度 / 幅度都按原版估计算，跟随值另走
    var tracker = SubjectFlowTracker()
    var trackerBase = BaseStrokeRhythm07()
    var trackerSame = true
    var trackerFollow = 0.0
    for k in 0..<(10 * 15) {
        let t = Double(k) * vsDt
        let vx = (5 * cos(2 * Double.pi * 2 * t) + 1.5 * cos(2 * Double.pi * t)).rounded()
        let reading = tracker.update(time: t, speed: abs(vx), vx: vx, vy: 0)
        trackerBase.add(time: t, x: vx, y: 0)
        let b = StrokeRhythm.Estimate(hz: trackerBase.estimate.hz, confidence: trackerBase.estimate.confidence,
                                      amplitude: trackerBase.estimate.amplitude)
        if reading.score != StrokeScore.flow(speed: reading.speed, rhythm: b) || reading.hz != b.hz
            || reading.rhythm != b.confidence || reading.amplitude != b.amplitude { trackerSame = false }
        trackerFollow = reading.followHz
    }
    vcheck(trackerSame && abs(trackerFollow - 2) <= 0.1,
           "节奏（M1）：块运动主体的分数 / hz / 置信度 / 幅度和原版逐位相同，跟随频率另给 \(String(format: "%.2f", trackerFollow)) Hz")
}

do {
    // 复审 L7：减半只看一次、门槛按最高峰 best 算、自相关本身 ≥ 0.3（直接喂自相关，结果是确定的）
    func corr(_ points: [Int: Double]) -> [Double] {
        var c = [Double](repeating: 0, count: StrokeRhythm.maxLag + 2)
        for (k, v) in points { c[k] = v }
        return c
    }
    // 真 2 Hz 的典型形状：15 格 1.0、7 / 8 格平顶 0.67 → 减半到 7.5 格
    let real = StrokeRhythm.halvedLag(corr([6: 0.5, 7: 0.67, 8: 0.67, 9: 0.5, 14: 0.8, 15: 1, 16: 0.8]), pick: 15, best: 1)
    // 0.5 Hz 带一点 1 Hz：30 格 1.0、15 格 0.56、7 / 8 格 0.2 → 只减一次到 15 格（原来会接着按 0.55 × 0.56 再减到 7.5 格）
    let once = StrokeRhythm.halvedLag(corr([6: 0.1, 7: 0.2, 8: 0.2, 9: 0.1, 14: 0.4, 15: 0.56, 16: 0.4, 29: 0.9, 30: 1, 31: 0.9]),
                                      pick: 30, best: 1)
    // 弱 1 Hz：最高峰只有 0.5，半周期处 0.27（加上插值 ≈ 0.30 ≥ 0.55 × 0.5，原来会减半）：低于 0.3 的绝对门槛，不减半
    let weak = StrokeRhythm.halvedLag(corr([6: 0.05, 7: 0.27, 8: 0.27, 9: 0.05, 14: 0.4, 15: 0.5, 16: 0.4]), pick: 15, best: 0.5)
    // 选中的 15 格只有最高峰（30 格 1.0）的 86%：半周期 0.5 够 0.55 × 0.86、不够 0.55 × 1 → 不减半
    let vsBest = StrokeRhythm.halvedLag(corr([6: 0.3, 7: 0.5, 8: 0.5, 9: 0.3, 14: 0.7, 15: 0.86, 16: 0.7, 29: 0.9, 30: 1, 31: 0.9]),
                                        pick: 15, best: 1)
    vcheck(abs((real?.lag ?? 0) - 7.5) < 1e-9 && abs((once?.lag ?? 0) - 15) < 1e-9 && weak == nil && vsBest == nil,
           "节奏（L7）：真 2 Hz 减半到 7.5 格；0.5 Hz 最多减一次（\(once.map { String(format: "%.1f", $0.lag) } ?? "nil") 格）；"
           + "弱峰 < 0.3、不到最高峰 55% 都不减")

    // 信号层面：带噪声 / 量化的 0.5 Hz、1 Hz（半周期反对称 → 半周期处负相关）一次都不减半；
    // 随机噪声里也最多减一次（跟随频率不超过基础估计的 2.5 倍、减过的那个峰 ≥ 0.3）
    var noise = RFNoise(seed: 77)
    var notHalved = true
    for f in [0.5, 1.0] {
        for amp in [1.2, 4.0] {
            let r = rfRhythm(seconds: 14) { t in
                ((amp * sin(2 * Double.pi * f * t)).rounded() + 0.3 * noise.next(), 0.2 * noise.next())
            }
            for (e, fo) in zip(r.now, r.follow) where e.hz > 0 && fo.hz != e.hz { notHalved = false }
        }
    }
    var atMostOnce = true
    for seed in 1...6 {
        var n = RFNoise(seed: UInt64(seed) * 7919)
        let r = rfRhythm(seconds: 10) { _ in (n.next(), n.next()) }
        for (e, fo) in zip(r.now, r.follow) where fo.hz > 0 && fo.hz != e.hz {
            if !(e.hz > 0 && fo.hz <= 2.5 * e.hz + 1e-9 && fo.confidence >= StrokeRhythm.harmonicFloor - 1e-12) {
                atMostOnce = false
            }
        }
    }
    vcheck(notHalved && atMostOnce, "节奏（L7）：带噪声的 0.5 / 1 Hz 不减半；随机噪声里跟随频率最多是基础估计的两倍左右")
}

do {
    // 复审 L3：跟随频率超过实际采样率 × 0.4 就不给（慢设备上姿态约 3 Hz 采样）
    let fast = rfRhythm(seconds: 10) { t in (sin(2 * Double.pi * 1.4 * t), 0) }
    let slow = rfRhythm(seconds: 14, rate: 3) { t in (sin(2 * Double.pi * 1.4 * t), 0) }
    let fastLate = fast.follow.suffix(45)
    let slowRates = slow.follow.filter { $0.sampleRate > 0 }
    vcheck(fastLate.allSatisfy { abs($0.hz - 1.4) <= 0.1 && abs($0.sampleRate - 15) <= 0.5 }
           && slow.follow.allSatisfy { $0.hz <= StrokeRhythm.aliasShare * 3 + 1e-6 }
           && slowRates.allSatisfy { abs($0.sampleRate - 3) <= 0.2 },
           "节奏（L3）：15 Hz 采样的 1.4 Hz 照常给（\(String(format: "%.2f", fastLate.last?.hz ?? 0)) Hz）；"
           + "3 Hz 采样时高于 1.2 Hz 的跟随频率一律不给")
}

func rfWindow(flowHz: Double = 0, flowConf: Double = 0, amp: Double = 3,
              poseHz: Double = 0, poseConf: Double = 0, poseScore: Double = 0.5, posePart: Int = 1,
              poseRate: Double = 9, cut: Bool = false) -> MotionWindow {
    var w = MotionWindow()
    w.frames = 5
    if cut { w.cutCount = 1 }
    if flowHz > 0 {
        w.subjectFrames = 5
        w.subjectScore = 0.5
        w.subjectHz = flowHz
        w.subjectFollowHz = flowHz
        w.subjectFollowRhythm = flowConf
        w.subjectFollowAmplitude = amp
    }
    if poseHz > 0 {
        w.poseFrames = 3
        w.posePresentFrames = 3
        w.poseScore = poseScore
        w.poseRhythmHz = poseHz
        w.poseRhythmConfidence = poseConf
        w.poseRhythmPart = posePart
        w.poseRhythmRate = poseRate
    }
    return w
}

do {
    let both = RhythmFollower.candidate(rfWindow(flowHz: 1.5, flowConf: 0.6, poseHz: 1.6, poseConf: 0.5))
    vcheck(both?.source == .both && (both?.hz ?? 0) > 1.5 && (both?.hz ?? 9) < 1.6
           && abs((both?.confidence ?? 0) - 0.7) < 1e-9,
           "节奏候选：块运动和姿态频率一致（差 ≤ 15%）时加权合并、置信度 +0.1")
    let near = RhythmFollower.candidate(rfWindow(flowHz: 1.0, flowConf: 0.6, poseHz: 2.0, poseConf: 0.58))
    let far = RhythmFollower.candidate(rfWindow(flowHz: 1.0, flowConf: 0.7, poseHz: 2.0, poseConf: 0.6))
    vcheck(near?.source == .pose && near?.hz == 2 && far?.source == .flow && far?.hz == 1,
           "节奏候选：两路不一致时取置信度高的（姿态略优先）")
    let tiny = RhythmFollower.candidate(rfWindow(flowHz: 1.5, flowConf: 0.9, amp: 0.5))
    var camOnly = rfWindow(flowHz: 1.5, flowConf: 0.9)
    camOnly.subjectScore = 0.01
    let fast = RhythmFollower.candidate(rfWindow(flowHz: 5, flowConf: 0.9))
    let slow = RhythmFollower.candidate(rfWindow(poseHz: 0.3, poseConf: 0.9))
    var nanW = rfWindow(flowHz: 1.5, flowConf: 0.9, poseHz: 1.5, poseConf: 0.9)
    nanW.subjectFollowHz = .nan
    nanW.poseRhythmConfidence = .infinity
    vcheck(tiny == nil && camOnly.subjectFrames > 0 && RhythmFollower.candidate(camOnly) == nil && fast == nil && slow == nil && RhythmFollower.candidate(nanW) == nil
           && RhythmFollower.candidate(.empty) == nil,
           "节奏候选：主体分数几乎为 0（只有相机在动）、幅度不到 1 像素、频率不在 0.4~4 Hz、NaN / 无穷都不算")

    // 复审 M2：姿态分数太低（人在但没怎么动）不算；腕不进姿态分数，挑中腕时要更高的姿态分数
    let still = RhythmFollower.candidate(rfWindow(poseHz: 1.5, poseConf: 0.9, poseScore: 0.05))
    let moving = RhythmFollower.candidate(rfWindow(poseHz: 1.5, poseConf: 0.9, poseScore: 0.15))
    let wristWave = RhythmFollower.candidate(rfWindow(poseHz: 1.5, poseConf: 0.9, poseScore: 0.15, posePart: 3))
    let wristReal = RhythmFollower.candidate(rfWindow(poseHz: 1.5, poseConf: 0.9, poseScore: 0.25, posePart: 3))
    vcheck(still == nil && moving?.source == .pose && wristWave == nil && wristReal?.source == .pose,
           "节奏候选（M2）：姿态分数 < 0.1 不算；挑中腕时姿态分数 < 0.2 不算（光比划手势）")

    // 复审 L3：慢设备上姿态约 3 Hz 采样，2 Hz 混叠成 1 Hz、置信度还很高：差一个八度且姿态采样率看不清块运动的频率 → 信块运动；
    // 姿态采样率够（约 9 Hz）时照旧比置信度
    let alias = RhythmFollower.candidate(rfWindow(flowHz: 2, flowConf: 0.67, poseHz: 1, poseConf: 0.9, poseRate: 3))
    let clear = RhythmFollower.candidate(rfWindow(flowHz: 2, flowConf: 0.67, poseHz: 1, poseConf: 0.9, poseRate: 9))
    let unknownRate = RhythmFollower.candidate(rfWindow(flowHz: 2, flowConf: 0.67, poseHz: 1, poseConf: 0.9, poseRate: 0))
    let mild = RhythmFollower.candidate(rfWindow(flowHz: 2, flowConf: 0.67, poseHz: 1.5, poseConf: 0.9, poseRate: 3))
    // r2 复审 L3：采样率看不清时，差得不到 1.6 倍也信块运动（以前 mild 取姿态 1.5 Hz）；9 Hz 采样时照旧比置信度
    let mid = RhythmFollower.candidate(rfWindow(flowHz: 2, flowConf: 0.6, poseHz: 1.5, poseConf: 0.7, poseRate: 3.5))
    let midClear = RhythmFollower.candidate(rfWindow(flowHz: 2, flowConf: 0.6, poseHz: 1.5, poseConf: 0.7, poseRate: 9))
    vcheck(alias?.source == .flow && alias?.hz == 2 && clear?.source == .pose && unknownRate?.source == .flow
           && mild?.source == .flow && mid?.source == .flow && mid?.hz == 2 && midClear?.source == .pose,
           "节奏候选（L3）：姿态采样率看不清块运动的频率时，任何不一致都取块运动（3 Hz 采样差八度 \(alias?.hz ?? 0) Hz、"
           + "3.5 Hz 采样 1.5 vs 2.0 → \(mid?.hz ?? 0) Hz）；9 Hz 采样时照旧比置信度")
    // r2 复审 L3：只有姿态时混叠挡不住（3 Hz 采样时真 2 Hz 读成 1 Hz），采样率 < max(2.5 × hz, 6) 或不知道就不给
    let poseOnlyAlias = RhythmFollower.candidate(rfWindow(poseHz: 1, poseConf: 0.9, poseRate: 3))
    let poseOnlyUnknown = RhythmFollower.candidate(rfWindow(poseHz: 1, poseConf: 0.9, poseRate: 0))
    let poseOnlyFast = RhythmFollower.candidate(rfWindow(poseHz: 3, poseConf: 0.9, poseRate: 7))
    let poseOnlyOk = RhythmFollower.candidate(rfWindow(poseHz: 1.5, poseConf: 0.9, poseRate: 8))
    let poseOnly15 = RhythmFollower.candidate(rfWindow(poseHz: 3, poseConf: 0.9, poseRate: 15))
    vcheck(poseOnlyAlias == nil && poseOnlyUnknown == nil && poseOnlyFast == nil && poseOnlyOk?.source == .pose
           && poseOnly15?.hz == 3,
           "节奏候选（L3）：只有姿态时采样 3 Hz 的 1 Hz、不知道采样率、7 Hz 采样的 3 Hz 都不给；8 Hz 采样的 1.5 Hz、15 Hz 采样的 3 Hz 照常给")
}

do {
    var f = RhythmFollower()
    var weights: [Double] = []
    for _ in 0..<12 { weights.append(f.step(rfWindow(flowHz: 1.5, flowConf: 0.7), dt: 0.3).weight) }
    vcheck(f.locked && abs(f.hz - 1.5) < 1e-9 && f.source == .flow && weights[3] == 1 && weights[0] <= 0.3 + 1e-9,
           "节奏跟随：稳定 1.5 Hz 第一拍就锁定，weight 约 1 秒升满（\(weights.prefix(4).map { String(format: "%.2f", $0) })）")

    var j = RhythmFollower()
    var seed: UInt64 = 12345
    var inMax = 0.0
    var outMax = 0.0
    var lastIn = 1.5
    var lastOut = 0.0
    for k in 0..<60 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let r = Double(seed >> 33) / Double(1 << 31) * 2 - 1
        let h = 1.5 * (1 + 0.1 * r)
        j.step(rfWindow(flowHz: h, flowConf: 0.6), dt: 0.3)
        if k >= 20 {
            inMax = max(inMax, abs(h - lastIn))
            outMax = max(outMax, abs(j.hz - lastOut))
        }
        lastIn = h
        lastOut = j.hz
    }
    vcheck(abs(j.hz - 1.5) <= 0.075 && outMax <= 0.4 * inMax,
           "节奏跟随：±10% 抖动被平滑（输出 \(String(format: "%.2f", j.hz)) Hz，拍间变化 \(String(format: "%.3f", outMax)) vs 输入 \(String(format: "%.3f", inMax))）")

    var s = RhythmFollower()
    for _ in 0..<20 { s.step(rfWindow(flowHz: 1, flowConf: 0.7), dt: 0.3) }
    var reached: Double?
    var firstAfter = 0.0
    for k in 0..<20 {
        s.step(rfWindow(flowHz: 2, flowConf: 0.7), dt: 0.3)
        if k == 0 { firstAfter = s.hz }
        if reached == nil, abs(s.hz - 2) <= 0.2 { reached = Double(k + 1) * 0.3 }
    }
    vcheck(abs(firstAfter - 1) < 1e-9 && (reached ?? 99) <= 3 && (reached ?? 0) >= 0.6 - 1e-9,
           "节奏跟随：1 → 2 Hz 阶跃先确认 0.6 秒再跟，≤ 3 秒到位（\(reached.map { String(format: "%.1f 秒", $0) } ?? "没到")）")

    var o = RhythmFollower()
    var worst = 0.0
    for k in 0..<30 {
        let h = k == 15 ? 3.0 : 1.5
        o.step(rfWindow(flowHz: h, flowConf: 0.7), dt: 0.3)
        worst = max(worst, abs(o.hz - 1.5))
    }
    var o2 = RhythmFollower()
    for k in 0..<30 { o2.step(rfWindow(flowHz: k == 15 || k == 17 ? 3.0 : 1.5, flowConf: 0.7), dt: 0.3); worst = max(worst, abs(o2.hz - 1.5)) }
    vcheck(worst < 1e-9, "节奏跟随：单拍 / 隔拍的倍频误检不跟")

    var g = RhythmFollower()
    for _ in 0..<20 { g.step(rfWindow(flowHz: 1.5, flowConf: 0.7), dt: 0.3) }
    g.step(rfWindow(flowHz: 1.8, flowConf: 0.7), dt: 0.3)
    let one = g.hz
    for _ in 0..<19 { g.step(rfWindow(flowHz: 1.8, flowConf: 0.7), dt: 0.3) }
    vcheck(one > 1.5 && one < 1.6 && abs(g.hz - 1.8) <= 0.05,
           "节奏跟随：20% 以内的变化平滑跟上（1 拍后 \(String(format: "%.2f", one))，6 秒后 \(String(format: "%.2f", g.hz))）")

    var h = RhythmFollower()
    for _ in 0..<20 { h.step(rfWindow(flowHz: 1.5, flowConf: 0.35), dt: 0.3) }
    let neverLocked = !h.locked && h.weight == 0 && h.hz == 0
    for _ in 0..<5 { h.step(rfWindow(flowHz: 1.5, flowConf: 0.7), dt: 0.3) }
    for _ in 0..<10 { h.step(rfWindow(flowHz: 1.6, flowConf: 0.33), dt: 0.3) }
    let stillLocked = h.locked && h.weight == 1 && h.hz > 1.5
    var drops: [Double] = []
    var lockedAt4 = false
    var hzAt4 = 0.0
    var prevW = h.weight
    var unlockedBy = -1
    for k in 0..<14 {
        h.step(rfWindow(flowHz: 1.5, flowConf: 0.2), dt: 0.3)
        drops.append(prevW - h.weight)
        prevW = h.weight
        if k == 3 { lockedAt4 = h.locked; hzAt4 = h.hz }
        if unlockedBy < 0, !h.locked { unlockedBy = k + 1 }
    }
    vcheck(neverLocked && stillLocked, "节奏跟随：置信度 0.35 不锁定；锁定后 0.33 不丢（回差 0.40 / 0.30）")
    vcheck(lockedAt4 && hzAt4 > 1.5 && unlockedBy == 6 && drops.allSatisfy { $0 <= 0.2 + 1e-9 }
           && h.weight == 0 && h.hz == 0 && !h.locked,
           "节奏跟随：丢了保持 1.5 秒再解锁（第 \(unlockedBy) 拍），weight 1.5 秒降到 0 后频率清零")

    var r = RhythmFollower()
    for _ in 0..<5 { r.step(rfWindow(flowHz: 1.5, flowConf: 0.7), dt: .nan) }
    r.step(rfWindow(flowHz: 1.5, flowConf: 0.7), dt: -1)
    let finite = r.hz.isFinite && r.weight.isFinite && r.locked
    r.reset()
    vcheck(finite && !r.locked && r.hz == 0 && r.weight == 0 && r.source == .none,
           "节奏跟随：dt 是 NaN / 负数不出错；reset 回初始")
}

do {
    // 复审 M3：锁在 1.4 Hz，画面变快到约 2.2 Hz，但每拍的读数 2.0 / 2.4 交替（彼此差 20%）：以前每拍都重新数、永远停在 1.4
    func lockAt(_ hz: Double) -> RhythmFollower {
        var f = RhythmFollower()
        for _ in 0..<8 { f.step(rfWindow(flowHz: hz, flowConf: 0.7), dt: 0.3) }
        return f
    }
    var wobble = lockAt(1.4)
    var wobbleReached: Double?
    for k in 0..<20 {
        wobble.step(rfWindow(flowHz: k % 2 == 0 ? 2.0 : 2.4, flowConf: 0.7), dt: 0.3)
        if wobbleReached == nil, abs(wobble.hz - 2.19) <= 0.1 { wobbleReached = Double(k + 1) * 0.3 }
    }
    // 一边落在 ±30% 平滑带里的忽高忽低（1.7 / 2.4）也一样跟上
    var mixedWobble = lockAt(1.4)
    for k in 0..<20 { mixedWobble.step(rfWindow(flowHz: k % 2 == 0 ? 1.7 : 2.4, flowConf: 0.7), dt: 0.3) }
    // 单拍离群（2.4）照样不跟
    var outlier = lockAt(1.4)
    outlier.step(rfWindow(flowHz: 2.4, flowConf: 0.7), dt: 0.3)
    let afterOutlier = outlier.hz
    for _ in 0..<5 { outlier.step(rfWindow(flowHz: 1.4, flowConf: 0.7), dt: 0.3) }
    vcheck((wobbleReached ?? 99) <= 1.5 && abs(wobble.hz - 2.19) <= 0.1 && abs(mixedWobble.hz - 2.02) <= 0.12
           && abs(afterOutlier - 1.4) < 1e-9 && abs(outlier.hz - 1.4) < 1e-6,
           "节奏跟随（M3）：读数 2.0 / 2.4 交替时 \(wobbleReached.map { String(format: "%.1f", $0) } ?? "—") 秒跟到 "
           + "\(String(format: "%.2f", wobble.hz)) Hz，1.7 / 2.4 交替到 \(String(format: "%.2f", mixedWobble.hz)) Hz；单拍离群不跟")

    // 复审 L2：一拍来晚了（dt 0.65 秒）也只算一拍：单个离群读数不能凭一拍凑够 0.6 秒
    var late = lockAt(1.5)
    late.step(rfWindow(flowHz: 3, flowConf: 0.7), dt: 0.65)
    let lateOne = late.hz
    late.step(rfWindow(flowHz: 1.5, flowConf: 0.7), dt: 0.3)
    // 拍很密（0.1 秒）：要 2 拍以上、还要累计满 0.6 秒（6 拍）才确认
    var dense = lockAt(1.5)
    var denseHz: [Double] = []
    for _ in 0..<6 {
        dense.step(rfWindow(flowHz: 3, flowConf: 0.7), dt: 0.1)
        denseHz.append(dense.hz)
    }
    // 两拍都来晚：2 拍 + 0.6 秒，确认
    var lateTwo = lockAt(1.5)
    lateTwo.step(rfWindow(flowHz: 3, flowConf: 0.7), dt: 0.65)
    lateTwo.step(rfWindow(flowHz: 3, flowConf: 0.7), dt: 0.65)
    vcheck(abs(lateOne - 1.5) < 1e-9 && abs(late.hz - 1.5) < 1e-6
           && denseHz.prefix(5).allSatisfy { abs($0 - 1.5) < 1e-9 } && abs((denseHz.last ?? 0) - 3) < 1e-9
           && abs(lateTwo.hz - 3) < 1e-9,
           "节奏跟随（L2）：dt 0.65 秒的单拍离群不跟；0.1 秒一拍时第 6 拍（0.6 秒）才确认；两拍都晚照常确认")
}

do {
    func lockAt(_ hz: Double, conf: Double = 0.8) -> RhythmFollower {
        var f = RhythmFollower()
        for _ in 0..<10 { f.step(rfWindow(flowHz: hz, flowConf: conf), dt: 0.3) }
        return f
    }
    // r2 复审 L1：锁在 1.0 Hz，真频率变成 2.0 Hz，但置信度 0.45 / 0.25 隔拍交替（0.25 低于丢失门）：以前每拍清零、30 秒还停在 1.0
    var gap = lockAt(1.0)
    var gapReached: Double?
    for k in 0..<100 {
        gap.step(rfWindow(flowHz: 2.0, flowConf: k % 2 == 0 ? 0.45 : 0.25), dt: 0.3)
        if gapReached == nil, abs(gap.hz - 2.0) <= 0.1 { gapReached = Double(k + 1) * 0.3 }
    }
    // 真的断了（连续 3 拍没候选 = 0.9 秒）：之前那一拍不留着，回来后重新数
    var broken = lockAt(1.0)
    broken.step(rfWindow(flowHz: 2.0, flowConf: 0.8), dt: 0.3)
    for _ in 0..<3 { broken.step(rfWindow(), dt: 0.3) }
    broken.step(rfWindow(flowHz: 2.0, flowConf: 0.8), dt: 0.3)
    let brokenHz = broken.hz
    vcheck((gapReached ?? 99) <= 3 && gap.locked && gap.weight == 1 && abs(brokenHz - 1.0) < 1e-9,
           "节奏跟随（r2 L1）：候选隔拍掉线（置信度 0.45 / 0.25 交替）\(gapReached.map { String(format: "%.1f", $0) } ?? "没") 秒跟到 2 Hz；"
           + "连续缺 0.9 秒后待确认清掉（\(String(format: "%.2f", brokenHz)) Hz）")

    // r2 复审 L2 A：2.0 Hz 附近 ±20% 的逐拍抖动：平滑、不硬跳（以前 60 秒里有 15 次 > 10% 的跳）
    var jit = lockAt(2.0)
    var seed: UInt64 = 42
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31)
    }
    var jitMin = 9.0
    var jitMax = 0.0
    var bigSteps = 0
    var prevHz = jit.hz
    for _ in 0..<200 {
        jit.step(rfWindow(flowHz: 2.0 * (1 + (rnd() * 0.4 - 0.2)), flowConf: 0.8), dt: 0.3)
        if abs(log(jit.hz / prevHz)) > log(1.1) { bigSteps += 1 }
        prevHz = jit.hz
        jitMin = min(jitMin, jit.hz)
        jitMax = max(jitMax, jit.hz)
    }
    vcheck(bigSteps == 0 && jitMin >= 1.7 && jitMax <= 2.3,
           "节奏跟随（r2 L2）：2 Hz ±20% 抖动 60 秒：频率 \(String(format: "%.2f~%.2f", jitMin, jitMax)) Hz，拍间 > 10% 的跳 \(bigSteps) 次")

    // r2 复审 L2 B：待确认读数彼此不一致（一拍倍频 2.0 + 一拍 1.35）不跳到谁也没读到的对数平均 1.64
    var mixed = lockAt(1.0)
    mixed.step(rfWindow(flowHz: 2.0, flowConf: 0.8), dt: 0.3)
    mixed.step(rfWindow(flowHz: 1.35, flowConf: 0.8), dt: 0.3)
    let mixedHz = mixed.hz
    // 彼此一致的两拍（2.0 / 2.2）照常跳到对数平均
    var agree = lockAt(1.0)
    agree.step(rfWindow(flowHz: 2.0, flowConf: 0.8), dt: 0.3)
    agree.step(rfWindow(flowHz: 2.2, flowConf: 0.8), dt: 0.3)
    // r2 复审 L2 C：tick 稍快（0.29 秒）也是 2 拍确认（以前 3 拍）；0.1 秒一拍仍要 6 拍
    var quick = lockAt(1.0)
    var quickBeats = 0
    while quick.hz < 1.5, quickBeats < 10 {
        quick.step(rfWindow(flowHz: 2.0, flowConf: 0.8), dt: 0.29)
        quickBeats += 1
    }
    vcheck(mixedHz < 1.1 && abs(agree.hz - exp((log(2.0) + log(2.2)) / 2)) < 1e-9 && quickBeats == 2,
           "节奏跟随（r2 L2）：2.0 + 1.35 不一致不跳（\(String(format: "%.2f", mixedHz)) Hz）、2.0 + 2.2 跳到 "
           + "\(String(format: "%.2f", agree.hz)) Hz；dt 0.29 秒 \(quickBeats) 拍确认")
}

// r2 复审 M1：真实链路（MotionShaper 门 + 0.7 秒释放平滑 → RhythmFollower → RhythmOutput → SyncOutputStage），
// 动作停下（目标强度落到 0）那一拍起，节奏开着的伸缩 ≤ 节奏关着（同一条 MotionShaper → step(value)）的伸缩；
// 以前 activity 读平滑后的值，平滑值掉到 15 以下之前一直是满节奏档位（停下后 0.9 秒还在 63 档）
func rhythmStopRun(_ fall: [Double]) -> (stopIndex: Int, rhythm: [Int], base: [Int]) {
    let u = DeviceRateMap.uncalibrated
    let st = AudioSyncSettings(maxPercent: 99, channels: .both)
    var sh = MotionShaper()
    var bsh = MotionShaper()
    var rf = RhythmFollower()
    var stage = SyncOutputStage()
    var baseStage = SyncOutputStage()
    let targets = [Double](repeating: 60, count: 20) + fall + [Double](repeating: 0, count: 12)
    var rhythm: [Int] = []
    var base: [Int] = []
    for target in targets {
        let o = sh.step(target: target, dt: 0.3)
        let a = RhythmOutput.motionActivity(level: o.level, smoothed: o.smoothed, confidence: 1, motionSignal: true)
        rf.step(rfWindow(flowHz: 2, flowConf: 0.8), dt: 0.3, active: a > 0)
        let lv = rf.weight > 0 && rf.hz > 0 ? u.level(forHz: rf.hz) : nil
        rhythm.append(stage.step(levels: RhythmOutput.target(value: o.smoothed, settings: st, hasSignal: true,
                                                             rateLevel: lv, weight: rf.weight, activity: a), settings: st)[0])
        base.append(baseStage.step(bsh.step(target: target, dt: 0.3).smoothed, settings: st, hasSignal: true)[0])
    }
    return (20 + (fall.firstIndex(of: 0) ?? fall.count), rhythm, base)
}
do {
    let u = DeviceRateMap.uncalibrated
    let step = rhythmStopRun([0])
    let gradual = rhythmStopRun([50, 40, 30, 20, 10, 0])
    func okAfterStop(_ r: (stopIndex: Int, rhythm: [Int], base: [Int])) -> Bool {
        (r.stopIndex..<r.rhythm.count).allSatisfy { r.rhythm[$0] <= r.base[$0] }
    }
    let before = step.rhythm[step.stopIndex - 1]
    vcheck(before == u.level(forHz: 2) && okAfterStop(step) && okAfterStop(gradual) && step.rhythm.last == 0,
           "节奏出档（r2 M1）：真实 MotionShaper 链路里动作停下那一拍起伸缩 ≤ 节奏关着的伸缩（阶跃 60→0："
           + "\(step.rhythm[step.stopIndex...].prefix(4)) vs \(step.base[step.stopIndex...].prefix(4))；"
           + "逐渐落 60→0 1.8 秒：\(gradual.rhythm[gradual.stopIndex...].prefix(4)) vs \(gradual.base[gradual.stopIndex...].prefix(4))）")
    // 同一条链路照旧在动作持续时给满节奏档位（不是靠关掉节奏通过的）
    vcheck(gradual.rhythm[19] == u.level(forHz: 2) && gradual.rhythm[19] > gradual.base[19],
           "节奏出档（r2 M1）：动作持续时伸缩是节奏档位 \(gradual.rhythm[19])（节奏关着 \(gradual.base[19])）")
    // activity：上升不比平滑值快，下降跟门前即时强度走；没有新鲜画面时 0
    vcheck(RhythmOutput.motionActivity(level: 60, smoothed: 10, confidence: 1, motionSignal: true) == RhythmOutput.activity(10)
           && RhythmOutput.motionActivity(level: 0, smoothed: 40, confidence: 1, motionSignal: true) == 0
           && RhythmOutput.motionActivity(level: 60, smoothed: 60, confidence: 0.5, motionSignal: true) == RhythmOutput.activity(30)
           && RhythmOutput.motionActivity(level: 60, smoothed: 60, confidence: 1, motionSignal: false) == 0
           && RhythmOutput.motionActivity(level: .nan, smoothed: 60, confidence: 1, motionSignal: true) == 0,
           "节奏出档（r2 M1）：activity = activity(置信度 × min(即时强度, 平滑值))，没信号 / NaN 为 0")
}

do {
    // r2 复审 L4：光点头 / 比划手势（节奏 1.5 Hz 也锁住了），画面强度只有 10 / 15：伸缩只比原来高一点
    let u = DeviceRateMap.uncalibrated
    let st = AudioSyncSettings(maxPercent: 100, channels: .both)
    let rate = u.level(forHz: 1.5)
    func pair(_ v: Double) -> (rhythm: Int, base: Int) {
        (RhythmOutput.target(value: v, settings: st, hasSignal: true, rateLevel: rate, weight: 1)[0],
         st.channels.levels(percent: SyncOutputStage.map(v, cap: 100, floor: 0))[0])
    }
    let p10 = pair(10)
    let p15 = pair(15)
    let p40 = pair(40)
    vcheck(p10.rhythm - p10.base <= 6 && p15.rhythm - p15.base <= 10 && p40.rhythm == rate && rate > 40,
           "节奏出档（r2 L4）：节奏 1.5 Hz（\(rate) 档）时强度 10 → \(p10.rhythm)（原 \(p10.base)）、15 → \(p15.rhythm)（原 \(p15.base)）；"
           + "强度 40 的真动作照样到节奏档位 \(p40.rhythm)")
    // r3 复审 M1：上界按上限之前的强度算；≤ 20 时 max(+12, ×2)，20~30 线性放开，≥ 30 没有上界（99）
    let ceilings = (0...100).map { RhythmOutput.rhythmCeiling(intensity: $0) }
    vcheck(ceilings[0] == 12 && ceilings[10] == 22 && ceilings[15] == 30 && ceilings[20] == 40
           && ceilings[30] == 99 && ceilings[100] == 99 && zip(ceilings, ceilings.dropFirst()).allSatisfy { $0 <= $1 },
           "节奏出档（r2 L4 / r3 M1）：弱动作上界 0 → 12、10 → 22、15 → 30、20 → 40，单调，强度 ≥ 30 不设上界（\(ceilings[25])@25）")
}

do {
    // r3 复审 M1：弱动作上界按上限之前的强度算，再和上限取小；上限 40 / 60 下真动作（强度 30 / 40）照样跟频率。
    // 设备快一点的标定表（10:1.0, 30:2.0, 50:3.0），2 Hz → 30 档、3 Hz → 50 档，都在上限附近
    let fast = DeviceRateMap(points: [DeviceRateMap.Point(level: 10, hz: 1.0), DeviceRateMap.Point(level: 30, hz: 2.0),
                                      DeviceRateMap.Point(level: 50, hz: 3.0)])!
    let u = DeviceRateMap.uncalibrated
    func thrust(_ v: Double, cap: Double, _ map: DeviceRateMap, _ hz: Double) -> Int {
        let st = AudioSyncSettings(maxPercent: cap, channels: .both)
        return RhythmOutput.target(value: v, settings: st, hasSignal: true, rateLevel: map.level(forHz: hz), weight: 1)[0]
    }
    var rows: [String] = []
    var differ = true
    for cap in [40.0, 60.0] {
        for v in [30.0, 40.0] {
            let t2 = thrust(v, cap: cap, fast, 2)
            let t3 = thrust(v, cap: cap, fast, 3)
            // 到上限为止跟节奏档位：2 Hz 30 档；3 Hz min(上限, 50)
            if t2 == t3 || t2 != 30 || t3 != min(Int(cap), 50) { differ = false }
            rows.append("上限 \(Int(cap)) 强度 \(Int(v))：2 Hz \(t2) / 3 Hz \(t3)")
        }
    }
    // 估计值表：上限 60 时 1.5 Hz（46 档）和 2 Hz（63 → 上限 60）也要分开；上限 99、强度 30 时 2 Hz 63 / 3 Hz 99（以前都是 60）
    let u60a = thrust(40, cap: 60, u, 1.5)
    let u60b = thrust(40, cap: 60, u, 2)
    let u99a = thrust(30, cap: 99, u, 2)
    let u99b = thrust(30, cap: 99, u, 3)
    vcheck(differ && u60a == u.level(forHz: 1.5) && u60b == 60 && u99a == u.level(forHz: 2) && u99b == 99,
           "节奏出档（r3 M1）：上限 40 / 60 下真动作的伸缩随频率变（\(rows.joined(separator: "；"))；"
           + "估计值上限 60 强度 40：1.5 Hz \(u60a) / 2 Hz \(u60b)；上限 99 强度 30：2 Hz \(u99a) / 3 Hz \(u99b)）")
    // 手势保护照旧（和上限无关）：强度 10 / 15 节奏最多到 22 / 30 档，上限 40 / 60 / 100 都一样
    var guardOK = true
    var guardRows: [String] = []
    for cap in [40.0, 60.0, 100.0] {
        let g10 = thrust(10, cap: cap, u, 2)
        let g15 = thrust(15, cap: cap, u, 2)
        if g10 > 22 || g15 > 30 { guardOK = false }
        guardRows.append("上限 \(Int(cap))：\(g10) / \(g15)")
    }
    vcheck(guardOK, "节奏出档（r3 M1）：弱动作上界不随上限放大或缩小（2 Hz 时强度 10 / 15：\(guardRows.joined(separator: "，"))）")
    // 状态行：上界压低了节奏档位时提示「动作偏弱」，真动作 / 到上限时不提示
    let st60 = AudioSyncSettings(maxPercent: 60, channels: .both)
    let weak = RhythmOutput.statusText(hz: 2, weight: 1, locked: true, rateLevel: u.level(forHz: 2), activity: 0.4,
                                       thrust: thrust(10, cap: 60, u, 2), value: 10, hasSignal: true, map: u,
                                       calibrated: true, settings: st60)
    let strong = RhythmOutput.statusText(hz: 2, weight: 1, locked: true, rateLevel: u.level(forHz: 2), activity: 1,
                                         thrust: 60, value: 40, hasSignal: true, map: u, calibrated: true, settings: st60)
    vcheck(weak.contains("动作偏弱") && !weak.contains("已到上限") && !strong.contains("动作偏弱") && strong.contains("已到上限 60")
           && RhythmOutput.ceilingLimits(value: 10, settings: st60, hasSignal: true, rateLevel: 63)
           && !RhythmOutput.ceilingLimits(value: 10, settings: st60, hasSignal: true, rateLevel: 15)
           && !RhythmOutput.ceilingLimits(value: 10, settings: AudioSyncSettings(maxPercent: 60, channels: .vibration),
                                          hasSignal: true, rateLevel: 63),
           "节奏状态（r3 M1）：弱动作上界压低时提示（\(weak)），真动作不提示（\(strong)）")
}

// r3 复审 L1：真实 MotionShaper 链路，锁定后置信度落到 0.35（在释放 0.30 和锁定 0.40 之间，靠滞回锁着），
// 第 20 拍一帧都没分析到（窗口 frames = 0，MotionNormalizer 给 0）/ 或门一拍没开（有帧、强度 0）：都不能丢锁
func rhythmBlipRun(target: Double, conf: Double, blank: Set<Int>, frameless: Bool) -> (thrust: [Int], locked: [Bool]) {
    let u = DeviceRateMap.uncalibrated
    let st = AudioSyncSettings(maxPercent: 99, channels: .both)
    var sh = MotionShaper()
    var rf = RhythmFollower()
    var stage = SyncOutputStage()
    var thrust: [Int] = []
    var locked: [Bool] = []
    for i in 0..<40 {
        let b = blank.contains(i)
        let o = sh.step(target: b ? 0 : target, dt: 0.3)
        let a = RhythmOutput.motionActivity(level: o.level, smoothed: o.smoothed, confidence: 1, motionSignal: true)
        let w = b && frameless ? MotionWindow.empty : rfWindow(flowHz: 2, flowConf: i < 10 ? 0.8 : conf)
        rf.step(b && !frameless ? rfWindow() : w, dt: 0.3, active: a > 0)
        let lv = rf.weight > 0 && rf.hz > 0 ? u.level(forHz: rf.hz) : nil
        thrust.append(stage.step(levels: RhythmOutput.target(value: o.smoothed, settings: st, hasSignal: true,
                                                             rateLevel: lv, weight: rf.weight, activity: a), settings: st)[0])
        locked.append(rf.locked)
    }
    return (thrust, locked)
}
do {
    let u = DeviceRateMap.uncalibrated
    let rate = u.level(forHz: 2)
    let empty = rhythmBlipRun(target: 35, conf: 0.35, blank: [20], frameless: true)
    let gate = rhythmBlipRun(target: 35, conf: 0.35, blank: [20], frameless: false)
    let gate2 = rhythmBlipRun(target: 35, conf: 0.35, blank: [20, 21], frameless: false)
    let heldEmpty = empty.locked[10...].allSatisfy { $0 } && empty.thrust[23...].allSatisfy { $0 == rate }
    let heldGate = gate.locked[10...].allSatisfy { $0 } && gate.thrust[23...].allSatisfy { $0 == rate }
    vcheck(heldEmpty && heldGate,
           "节奏跟随（r3 L1）：置信度 0.35 靠滞回锁着，一拍没帧 / 门一拍没开都不丢锁，伸缩回到节奏档位"
           + "（没帧：\(empty.thrust[18...26].map { $0 })；门：\(gate.thrust[18...26].map { $0 })）")
    // 有帧的「画面不动」连续 2 拍照样解锁（置信度 0.35 < 0.40，之后不再锁上）；那一拍伸缩照样当拍交回强度
    vcheck(!gate2.locked[21] && !gate2.locked[39] && empty.thrust[20] < rate
           && gate.thrust[20] < rate,
           "节奏跟随（r3 L1）：连续 2 拍有帧不动才解锁（\(gate2.thrust[18...26].map { $0 })），闪断那拍伸缩当拍按强度（\(gate.thrust[20])）")
}

do {
    // 复审 M2：节奏只在画面确实在动时出伸缩；画面强度为 0 时伸缩就是原来的档位（节奏不加任何伸缩）
    let u = DeviceRateMap.uncalibrated
    let st = AudioSyncSettings(maxPercent: 100, channels: .both)
    func lockedFollower() -> RhythmFollower {
        var f = RhythmFollower()
        for _ in 0..<10 { f.step(rfWindow(flowHz: 2, flowConf: 0.7), dt: 0.3) }
        return f
    }

    // 动作停了：4 秒的节奏窗口里还留着旧的往复（候选还在），但画面强度已经落到 0
    var stopF = lockedFollower()
    var stopStage = SyncOutputStage()
    var thrustBefore = 0
    for _ in 0..<5 {
        let lv = stopF.weight > 0 ? u.level(forHz: stopF.hz) : nil
        thrustBefore = stopStage.step(levels: RhythmOutput.target(value: 60, settings: st, hasSignal: true, rateLevel: lv,
                                                                  weight: stopF.weight), settings: st)[0]
    }
    var stopTicks: Int?
    var stopLockedAgain = false
    var stopUnlockedAt: Int?
    for k in 0..<10 {
        let value = 0.0
        stopF.step(rfWindow(flowHz: 2, flowConf: 0.7), dt: 0.3, active: RhythmOutput.activity(value) > 0)
        // r3 复审 L1：锁定中要连续 2 拍不动才解锁（第 1 拍按保持），解锁后旧节奏还在窗口里也不能再锁上
        if !stopF.locked, stopUnlockedAt == nil { stopUnlockedAt = k + 1 }
        if stopF.locked, stopUnlockedAt != nil { stopLockedAgain = true }
        let lv = stopF.weight > 0 ? u.level(forHz: stopF.hz) : nil
        let thrust = stopStage.step(levels: RhythmOutput.target(value: value, settings: st, hasSignal: true, rateLevel: lv,
                                                                weight: stopF.weight), settings: st)[0]
        if stopTicks == nil, thrust == 0 { stopTicks = k + 1 }
    }
    let stopRelease = Double(stopTicks ?? 99) * 0.3
    vcheck(thrustBefore == u.level(forHz: 2) && stopRelease <= 0.5 && stopF.weight == 0 && !stopLockedAgain
           && stopUnlockedAt == RhythmFollower.inactiveUnlockTicks,
           "节奏出档（M2）：动作停了（强度 0）伸缩 \(String(format: "%.1f", stopRelease)) 秒内归零（之前 \(thrustBefore) 档），"
           + "旧节奏还在窗口里也不重新锁定")

    // 切镜：画面强度还在（切镜保持），节奏 0.5 秒内交回动作强度，新镜头重新确认
    var cutF = lockedFollower()
    var cutStage = SyncOutputStage()
    for _ in 0..<5 {
        let lv = cutF.weight > 0 ? u.level(forHz: cutF.hz) : nil
        _ = cutStage.step(levels: RhythmOutput.target(value: 30, settings: st, hasSignal: true, rateLevel: lv,
                                                      weight: cutF.weight), settings: st)
    }
    let plain = st.channels.levels(percent: SyncOutputStage.map(30, cap: 100, floor: 0))[0]
    var cutTicks: Int?
    for k in 0..<6 {
        cutF.step(k == 0 ? rfWindow(cut: true) : rfWindow(), dt: 0.3)
        let lv = cutF.weight > 0 ? u.level(forHz: cutF.hz) : nil
        let thrust = cutStage.step(levels: RhythmOutput.target(value: 30, settings: st, hasSignal: true, rateLevel: lv,
                                                               weight: cutF.weight), settings: st)[0]
        if cutTicks == nil, thrust == plain { cutTicks = k + 1 }
    }
    let cutRelease = Double(cutTicks ?? 99) * 0.3
    vcheck(cutRelease <= 0.5 && !cutF.locked && cutF.weight == 0 && cutF.hz == 0,
           "节奏出档（M2）：切镜后伸缩 \(String(format: "%.1f", cutRelease)) 秒内回到按强度（\(plain) 档），不保持旧节奏")

    // 画面不动时就算候选一直在也不锁定
    var idle = RhythmFollower()
    for _ in 0..<10 { idle.step(rfWindow(flowHz: 2, flowConf: 0.9), dt: 0.3, active: false) }
    vcheck(!idle.locked && idle.weight == 0 && idle.hz == 0, "节奏跟随（M2）：画面没在动时不锁定")

    // 切镜 / 保持期样本带的是切镜前的读数：窗口里不记跟随频率（分数路径的 subjectHz 照旧）
    var acc = MotionWindowAccumulator()
    let held = SubjectReading(valid: true, score: 0.5, speed: 3, hz: 2, rhythm: 0.9, amplitude: 4,
                              followHz: 2, followRhythm: 0.9, followAmplitude: 4)
    acc.add(MotionSample(time: 1, energy: 1, coverage: 0.2, isCut: false, isHeld: false, subject: held))
    acc.add(MotionSample(time: 1.07, energy: 1, coverage: 0.2, isCut: false, isHeld: true, subject: held))
    let heldWindow = acc.drain()
    acc.add(MotionSample(time: 1.13, energy: 1, coverage: 0.2, isCut: true, isHeld: false, subject: held))
    let cutWindow = acc.drain()
    acc.add(MotionSample(time: 1.2, energy: 1, coverage: 0.2, isCut: false, isHeld: false, subject: held))
    let freshWindow = acc.drain()
    vcheck(heldWindow.subjectFollowHz == 0 && heldWindow.subjectHz == 2 && cutWindow.subjectFollowHz == 0
           && freshWindow.subjectFollowHz == 2 && freshWindow.subjectFollowRhythm == 0.9
           && freshWindow.subjectFollowAmplitude == 4,
           "节奏窗口（M2）：切镜 / 保持期样本不带跟随频率，正常样本照常带")
}

do {
    let s = AudioSyncSettings(maxPercent: 70, channels: .both, minPercent: 15)
    let base = RhythmOutput.target(value: 50, settings: s, hasSignal: true, rateLevel: nil, weight: 1)
    let plain = s.channels.levels(percent: SyncOutputStage.map(50, cap: 70, floor: 15))
    let full = RhythmOutput.target(value: 50, settings: s, hasSignal: true, rateLevel: 90, weight: 1)
    let low = RhythmOutput.target(value: 50, settings: s, hasSignal: true, rateLevel: 5, weight: 1)
    let noSig = RhythmOutput.target(value: 0, settings: s, hasSignal: false, rateLevel: 55, weight: 1)
    let vibSettings = AudioSyncSettings(maxPercent: 70, channels: .vibration)
    let vib = RhythmOutput.target(value: 50, settings: vibSettings, hasSignal: true, rateLevel: 60, weight: 1)
    vcheck(base == plain && full[0] == 70 && full[1] == plain[1] && low[0] == 15 && noSig[0] == 0
           && vib == RhythmOutput.target(value: 50, settings: vibSettings, hasSignal: true, rateLevel: nil, weight: 1),
           "节奏出档：伸缩 = 节奏档位（抬到最低强度、压到上限），震动照旧；没信号 / 仅震动不起作用（\(full) \(low)）")
    // 复审 M2：画面强度 0 → 节奏不加任何伸缩（没有最低强度时就是 0，有最低强度时就是原来的最低强度）；
    // 强度在 2~15 之间按比例交接（8.5 → 一半）
    let s0 = AudioSyncSettings(maxPercent: 70, channels: .both)
    let zero = RhythmOutput.target(value: 0, settings: s0, hasSignal: true, rateLevel: 55, weight: 1)
    let zeroFloor = RhythmOutput.target(value: 0, settings: s, hasSignal: true, rateLevel: 55, weight: 0.5)
    let plainZeroFloor = s.channels.levels(percent: SyncOutputStage.map(0, cap: 70, floor: 15))
    // r2 复审 L4：activityFull 15 → 25，一半在 13.5；r3 复审 M1：弱动作上界按上限之前的强度（13.5 → 14 → 上界 28，
    // 不再按上限 70 换算后的 9 档 → 21），9 档和 28 档之间插一半 → 19
    let halfActive = RhythmOutput.target(value: 13.5, settings: s0, hasSignal: true, rateLevel: 55, weight: 1)
    let idle = RhythmOutput.target(value: 50, settings: s, hasSignal: true, rateLevel: 90, weight: 1, activity: 0)
    vcheck(zero == [0, 0, 0, 0] && zeroFloor == plainZeroFloor && halfActive[0] == 19
           && abs(RhythmOutput.activity(13.5) - 0.5) < 1e-12 && RhythmOutput.activity(.nan) == 0 && idle == plain,
           "节奏出档（M2）：画面强度 0 时伸缩 \(zero[0])（有最低强度 15 时 \(zeroFloor[0])），强度 13.5 时交接一半（\(halfActive[0])），"
           + "画面自己没在动（activity 0）时和原路径一样")

    var seed: UInt64 = 987654321
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 33) / Double(1 << 31)
    }
    var stage = SyncOutputStage()
    var a = SyncOutputStage()
    var b = SyncOutputStage()
    var c = SyncOutputStage()
    var original = BaseSyncOutputStage07()
    var prev = [0, 0, 0, 0]
    // 连续 0 的拍数（含刚归零那一拍）；reset 后视为已保持够。生产里刚归零那拍 zeroAge = 0，满 zeroHoldTicks 才能再升，
    // 也就是非 0 → 0 之后至少要连续 zeroHoldTicks + 1 拍 0（r2 复审 L5：以前少数一拍，保持缩短一拍也测不出）
    let heldRun = SyncOutputStage.zeroHoldTicks + 1
    var zeroRun = [heldRun, heldRun]
    var ok = true
    var same = true
    var asBase = true
    var bad = ""
    let channels = AudioSyncChannels.allCases
    for i in 0..<3000 {
        if i % 200 == 0 { stage.reset(); a.reset(); b.reset(); c.reset(); original.reset(); prev = [0, 0, 0, 0]
            zeroRun = [heldRun, heldRun] }
        let st = AudioSyncSettings(maxPercent: 5 + rnd() * 100, channels: channels[Int(rnd() * 3) % 3],
                                   minPercent: rnd() * 60)
        let value = rnd() < 0.05 ? Double.nan : rnd() * 120 - 10
        let sig = rnd() < 0.85
        let rate: Int? = rnd() < 0.2 ? nil : Int(rnd() * 130) - 10
        let w = rnd() * 2 - 0.5
        let out = stage.step(levels: RhythmOutput.target(value: value, settings: st, hasSignal: sig, rateLevel: rate,
                                                         weight: w), settings: st)
        let cap = SyncOutputStage.hardCap(st)
        if out.count != 4 || out[2] != 0 || out[3] != 0 { ok = false; bad = "通道 \(out)" }
        for ch in 0..<2 {
            if out[ch] < 0 || out[ch] > cap { ok = false; bad = "上限 \(out) cap \(cap)" }
            if out[ch] - prev[ch] > SyncOutputStage.maxRisePerTick { ok = false; bad = "升幅 \(prev) → \(out)" }
            if out[ch] > 0, prev[ch] == 0, zeroRun[ch] < heldRun { ok = false; bad = "归零保持 \(zeroRun[ch]) 拍" }
            zeroRun[ch] = out[ch] == 0 ? min(heldRun, zeroRun[ch] + 1) : 0
        }
        prev = out
        let ta = RhythmOutput.target(value: value, settings: st, hasSignal: sig, rateLevel: nil, weight: w)
        let idleTarget = RhythmOutput.target(value: value, settings: st, hasSignal: sig, rateLevel: rate, weight: w,
                                             activity: 0)
        // 开关关着：VideoSyncPlayer 走 step(value) / preview，必须和 07ac4d4 原版逐位相同
        let off = b.step(value, settings: st, hasSignal: sig)
        if off != original.step(value, settings: st, hasSignal: sig)
            || SyncOutputStage.preview(value, settings: st, hasSignal: sig)
            != BaseSyncOutputStage07.preview(value, settings: st, hasSignal: sig) { asBase = false }
        if a.step(levels: ta, settings: st) != off || c.step(levels: idleTarget, settings: st) != off { same = false }
    }
    vcheck(ok, "节奏出档：3000 组随机输入经 step(levels:) 后 ≤ 上限、单拍升幅 ≤ 20、归零保持 2 拍、只用两个通道 \(bad)")
    vcheck(asBase, "节奏出档（M1）：开关关着时的出口 step(value) / 预览和 algo-opt-3 原版逐位一致（3000 组随机输入）")
    vcheck(same, "节奏出档：没有节奏档位、或画面没在动（activity 0）时 step(levels:) 和 step(value) 逐位一致")

    // 复审 L4：状态行显示实际发出的档位；「比设备最快」和「已到上限」各自提示；按 weight 判断节奏还在不在起作用
    let u = DeviceRateMap.uncalibrated
    let cap60 = AudioSyncSettings(maxPercent: 60, channels: .both)
    let both = RhythmOutput.statusText(hz: 3.5, weight: 1, locked: true, rateLevel: 99, activity: 1, thrust: 60, value: 60, hasSignal: true,
                                       map: u, calibrated: false, settings: cap60)
    let fading = RhythmOutput.statusText(hz: 1, weight: 0.4, locked: false, rateLevel: 28, activity: 1, thrust: 24, value: 60, hasSignal: true,
                                         map: u, calibrated: true, settings: cap60)
    let still = RhythmOutput.statusText(hz: 1, weight: 0.4, locked: false, rateLevel: 28, activity: 0, thrust: 0, value: 60, hasSignal: true,
                                        map: u, calibrated: true, settings: cap60)
    let noRhythm = RhythmOutput.statusText(hz: 1, weight: 0, locked: false, rateLevel: nil, activity: 1, thrust: 30, value: 60, hasSignal: true,
                                           map: u, calibrated: true, settings: cap60)
    let vibOnly = RhythmOutput.statusText(hz: 1, weight: 1, locked: true, rateLevel: 28, activity: 1, thrust: 0, value: 60, hasSignal: true, map: u,
                                          calibrated: true, settings: AudioSyncSettings(maxPercent: 60, channels: .vibration))
    vcheck(both.contains("伸缩 60 档") && both.contains("比设备最快的 3.0 次/秒还快") && both.contains("已到上限 60")
           && both.contains("设备还没标定") && fading.contains("动作节奏 1.0 次/秒 → 伸缩 24 档")
           && fading.contains("正在交回动作强度") && !fading.contains("设备还没标定") && still.contains("画面没在动")
           && noRhythm.hasPrefix("还没找到稳定的动作节奏") && vibOnly.contains("仅震动"),
           "节奏状态（L4）：显示实际档位、超速和上限同时提示、交接期仍显示节奏（\(both) / \(fading)）")
}

func rfFollow(_ windows: [MotionWindow], dt: Double = 5.0 / 15) -> (f: RhythmFollower, lockedTicks: Int) {
    var f = RhythmFollower()
    var n = 0
    for w in windows {
        f.step(w, dt: dt)
        if f.locked { n += 1 }
    }
    return (f, n)
}

let rf1Hz = vs3Analyze(VS3Scene(rect: vs3Mid, hz: 1, peak: 4))
do {
    let one = rfFollow(rf1Hz.windows)
    let two = rfFollow(vs3Strong20.windows)
    let u = DeviceRateMap.uncalibrated
    vcheck(one.f.locked && two.f.locked && abs(one.f.hz - 1) <= 0.1 && abs(two.f.hz - 2) <= 0.2
           && u.level(forHz: two.f.hz) > u.level(forHz: one.f.hz) + 20,
           "节奏端到端：合成画面 1 Hz / 2 Hz 往复锁定到 \(String(format: "%.2f", one.f.hz)) / \(String(format: "%.2f", two.f.hz)) Hz，"
           + "档位 \(u.level(forHz: one.f.hz)) / \(u.level(forHz: two.f.hz))")
    let still = rfFollow(vs3Static.windows)
    let shake = rfFollow(vs3Shake.windows)
    vcheck(still.lockedTicks == 0 && shake.lockedTicks == 0,
           "节奏端到端：静止画面不锁定、只有手持抖动不锁定（\(still.lockedTicks) / \(shake.lockedTicks) 拍）")
    let shakeStrong = rfFollow(vs3ShakeStrong.windows)
    vcheck(shakeStrong.f.locked && abs(shakeStrong.f.hz - 2) <= 0.25,
           "节奏端到端：手持抖动 + 主体 2 Hz 往复照样锁到主体频率（\(String(format: "%.2f", shakeStrong.f.hz)) Hz）")

    func run(_ windows: [MotionWindow]) -> (late: Double, rise: Int) {
        var chain = VSChain()
        var stage = SyncOutputStage()
        var f = RhythmFollower()
        let st = AudioSyncSettings(maxPercent: 100, channels: .both)
        var outs: [Int] = []
        for w in windows {
            let v = chain.step(w)
            f.step(w, dt: 5.0 / 15)
            let rate = f.weight > 0 ? u.level(forHz: f.hz) : nil
            outs.append(stage.step(levels: RhythmOutput.target(value: v, settings: st, hasSignal: true,
                                                               rateLevel: rate, weight: f.weight), settings: st)[0])
        }
        var rise = 0
        for i in 1..<max(1, outs.count) { rise = max(rise, outs[i] - outs[i - 1]) }
        let tail = outs.suffix(outs.count / 3)
        return (tail.isEmpty ? 0 : Double(tail.reduce(0, +)) / Double(tail.count), rise)
    }
    let r1 = run(rf1Hz.windows)
    let r2 = run(vs3Strong20.windows)
    vcheck(abs(r1.late - Double(u.level(forHz: 1))) <= 4 && abs(r2.late - Double(u.level(forHz: 2))) <= 6
           && r1.rise <= 20 && r2.rise <= 20,
           "节奏端到端：伸缩档位稳定在频率对应档（1 Hz \(Int(r1.late))、2 Hz \(Int(r2.late))），升幅 ≤ 20")
}

do {
    // 腕 1.5 Hz 上下撸动（约 0.3 躯干），髋 / 头不动：节奏取腕
    var tracker = PoseMotionTracker()
    var acc = MotionWindowAccumulator()
    var follower = RhythmFollower()
    var last = PoseReading()
    var lastWindow = MotionWindow()
    for k in 0..<(14 * 15) {
        let t = Double(k) * vsDt
        acc.add(MotionSample(time: t, energy: 1, coverage: 0.2, isCut: false, isHeld: false,
                             subject: SubjectReading(valid: true, score: 0.2)))
        if k % 5 == 0 || k % 5 == 2 || k % 5 == 4 {
            var p = vs3Skeleton()
            let dy = 3 * sin(2 * Double.pi * 1.5 * t)
            p.set(.leftWrist, x: 26, y: 18 + dy, confidence: 0.9)
            p.set(.rightWrist, x: 38, y: 18 + dy, confidence: 0.9)
            last = tracker.update(time: t, candidates: [p], camera: .identity, continuous: true, frameHeight: 36)
            acc.addPose(last)
        }
        if k % 5 == 4 {
            lastWindow = acc.drain()
            follower.step(lastWindow, dt: 5.0 / 15)
        }
    }
    vcheck(last.rhythmPart == 3 && abs(last.rhythmHz - 1.5) <= 0.15 && last.rhythmConfidence >= 0.4
           && last.rhythmRate >= 8 && last.rhythmRate <= 10 && lastWindow.poseRhythmPart == 3
           && lastWindow.poseScore >= RhythmFollower.wristMinScore,
           "节奏姿态：只有手腕在往复时取腕（第 \(last.rhythmPart) 组 \(String(format: "%.2f", last.rhythmHz)) Hz，"
           + "采样 \(String(format: "%.1f", last.rhythmRate)) 次/秒，姿态分数 \(String(format: "%.2f", lastWindow.poseScore))）")
    vcheck(abs(lastWindow.poseRhythmHz - 1.5) <= 0.15 && follower.locked && follower.source == .pose
           && abs(follower.hz - 1.5) <= 0.15,
           "节奏姿态：窗口带出姿态节奏，跟随器按姿态锁定到 \(String(format: "%.2f", follower.hz)) Hz")
    let hip = vs3PoseHips.readings.last ?? PoseReading()
    let none = vs3PoseNone.readings.last ?? PoseReading()
    vcheck(hip.rhythmPart == 1 && abs(hip.rhythmHz - 2) <= 0.2 && none.rhythmPart == 0 && none.rhythmHz == 0,
           "节奏姿态：髋 2 Hz 往复取髋（\(String(format: "%.2f", hip.rhythmHz)) Hz），没人时没有节奏")
}

do {
    vcheck(!VisualSyncSettings.Keys.rhythmFollow.contains(".") && !VisualSyncSettings.Keys.rateTable.contains("."),
           "节奏设置：@AppStorage 键名不带点")
    let long = String(repeating: "1", count: VisualSyncSettings.maxRateTableLength + 1)
    vcheck(VisualSyncSettings(rateTable: long).rateTable == "" && VisualSyncSettings().rateMap == .uncalibrated
           && VisualSyncSettings().calibratedRateMap == nil
           && VisualSyncSettings(rateTable: "20:0.6, 99:2.8").calibratedRateMap?.maxHz == 2.8
           && VisualSyncSettings(rateTable: "20:0.6, 10:2.8").rateMap == .uncalibrated,
           "节奏设置：超长表回默认，填错按没标定")
    let suite = "bc.visualsync.rhythm.checks"
    if let d = UserDefaults(suiteName: suite) {
        d.removePersistentDomain(forName: suite)
        let def = VisualSyncSettings.load(from: d)
        vcheck(!def.rhythmFollow && def.rateTable == "", "节奏设置：默认关、没标定（老用户行为不变）")
        d.set("yes", forKey: VisualSyncSettings.Keys.rhythmFollow)
        d.set(42, forKey: VisualSyncSettings.Keys.rateTable)
        let bad = VisualSyncSettings.load(from: d)
        d.set(long, forKey: VisualSyncSettings.Keys.rateTable)
        let tooLong = VisualSyncSettings.load(from: d)
        d.set(true, forKey: VisualSyncSettings.Keys.rhythmFollow)
        d.set("20:0.6, 60:1.8, 99:2.8", forKey: VisualSyncSettings.Keys.rateTable)
        let stored = VisualSyncSettings.load(from: d)
        vcheck(!bad.rhythmFollow && bad.rateTable == "" && tooLong.rateTable == "" && stored.rhythmFollow
               && stored.calibratedRateMap?.points.count == 3, "节奏设置：坏值回默认、读回存的值")
        d.removePersistentDomain(forName: suite)
    } else {
        vcheck(false, "节奏设置：创建测试用 UserDefaults")
    }
}

// MARK: - rhythm-phase P2：相位对齐（相位锁 + 0.1 秒子拍脉动，默认关）

/// main（dfbfc8e）的 SyncOutputStage 原样拷贝（只改名）：钉住「关掉 P2 时出口逐位不变」
struct BaseSyncOutputStageP1 {
    static let maxRisePerTick = 20
    static let zeroHoldTicks = 2
    private(set) var last: [Int] = [0, 0, 0, 0]
    private var zeroAge: [Int] = [Int](repeating: BaseSyncOutputStageP1.zeroHoldTicks, count: 4)

    mutating func reset() {
        last = [0, 0, 0, 0]
        zeroAge = [Int](repeating: Self.zeroHoldTicks, count: 4)
    }

    mutating func seed(_ levels: [Int]) {
        for ch in 0..<4 {
            let v = ch < 2 && ch < levels.count ? max(0, min(BCProtocol.maxManualLevel, levels[ch])) : 0
            last[ch] = v
            zeroAge[ch] = v > 0 ? Self.zeroHoldTicks : 0
        }
    }

    static func floorPercent(settings s: AudioSyncSettings, hasSignal: Bool) -> Double {
        hasSignal ? min(s.maxPercent, s.minPercent) : 0
    }

    static func hardCap(_ s: AudioSyncSettings) -> Int {
        guard s.maxPercent.isFinite else { return 0 }
        return max(0, min(Int(s.maxPercent.rounded(.down)), BCProtocol.maxManualLevel))
    }

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

    mutating func step(_ value: Double, settings s: AudioSyncSettings, hasSignal: Bool) -> [Int] {
        let mapped = Self.map(value, cap: s.maxPercent, floor: Self.floorPercent(settings: s, hasSignal: hasSignal))
        return limit(s.channels.levels(percent: mapped), cap: Self.hardCap(s))
    }

    mutating func step(levels target: [Int], settings s: AudioSyncSettings) -> [Int] {
        limit(target, cap: Self.hardCap(s))
    }

    private mutating func limit(_ target: [Int], cap: Int) -> [Int] {
        var out = [0, 0, 0, 0]
        for ch in 0..<2 {
            let prev = last[ch]
            var p = ch < target.count ? target[ch] : 0
            p = min(p, prev + Self.maxRisePerTick)
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

func p2Settings() -> AudioSyncSettings {
    let ch: AudioSyncChannels = [.both, .thrust, .vibration][Int(vsRandom() * 3) % 3]
    let cap = vsRandom() < 0.1 ? 100 : (vsRandom() * 100).rounded()
    let minP = vsRandom() < 0.5 ? 0 : (vsRandom() * 40).rounded()
    return AudioSyncSettings(enabled: true, maxPercent: cap, channels: ch, minPercent: minP)
}

func p2Levels() -> [Int] {
    if vsRandom() < 0.15 { return [0, 0, 0, 0] }
    let a = Int(vsRandom() * 110) - 5
    let b = Int(vsRandom() * 110) - 5
    return [a, b, Int(vsRandom() * 99), Int(vsRandom() * 99)]
}

do {
    // 关掉 P2：出口逐位等于 main 的 SyncOutputStage（3000 组随机序列：step(value) / step(levels:) / seed / reset 混用）
    var same = true
    var steps = 0
    for _ in 0..<3000 {
        var a = SyncOutputStage()
        var b = BaseSyncOutputStageP1()
        for _ in 0..<(4 + Int(vsRandom() * 12)) {
            let s = p2Settings()
            let r = vsRandom()
            if r < 0.4 {
                let v = vsRandom() < 0.05 ? Double.nan : vsRandom() * 120 - 10
                let sig = vsRandom() < 0.7
                same = same && a.step(v, settings: s, hasSignal: sig) == b.step(v, settings: s, hasSignal: sig)
            } else if r < 0.88 {
                let l = p2Levels()
                same = same && a.step(levels: l, settings: s) == b.step(levels: l, settings: s)
            } else if r < 0.95 {
                let l = p2Levels()
                a.seed(l)
                b.seed(l)
            } else {
                a.reset()
                b.reset()
            }
            same = same && a.last == b.last
            steps += 1
        }
    }
    vcheck(same, "P2 关闭：出口和 main 的 SyncOutputStage 逐位相同（3000 组随机序列 \(steps) 步）")

    // 按时间的出口在 elapsed = 0.3 秒时和按拍的逐位相同（含归零保持 / seed / reset）
    var timedSame = true
    for _ in 0..<1500 {
        var a = SyncOutputStage()
        var b = SyncOutputStage()
        for _ in 0..<(4 + Int(vsRandom() * 14)) {
            let s = p2Settings()
            let r = vsRandom()
            if r < 0.9 {
                let l = p2Levels()
                timedSame = timedSame && a.step(levels: l, settings: s, elapsed: 0.3) == b.step(levels: l, settings: s)
            } else if r < 0.96 {
                let l = p2Levels()
                a.seed(l)
                b.seed(l)
            } else {
                a.reset()
                b.reset()
            }
        }
    }
    vcheck(timedSame, "P2 出口：按时间限速在间隔 0.3 秒时和原来按拍的逐位相同")

    // 按时间的出口随机安全性：任意两刻之间升幅 ≤ 20 × 间隔 / 0.3 + 1，单步 ≤ 20，≤ 上限，通道 3 / 4 恒 0，归零后 ≥ 0.85 秒才再升
    var safe = true
    var worst = 0.0
    for _ in 0..<600 {
        var stage = SyncOutputStage()
        let s = AudioSyncSettings(enabled: true, maxPercent: (40 + vsRandom() * 60).rounded(), channels: .both)
        var t = 0.0
        var times: [Double] = []
        var outs: [[Int]] = []
        var zeroAt: [Double?] = [nil, nil]
        var prev = [0, 0, 0, 0]
        for _ in 0..<80 {
            let r = vsRandom()
            let dt = r < 0.7 ? 0.1 + (vsRandom() - 0.5) * 0.03 : (r < 0.85 ? 0.3 : (r < 0.95 ? vsRandom() * 0.05 : 0.2))
            t += dt
            let l = vsRandom() < 0.1 ? [0, 0, 0, 0] : [Int(vsRandom() * 99), Int(vsRandom() * 99), 50, 50]
            let o = stage.step(levels: l, settings: s, elapsed: dt)
            safe = safe && o[2] == 0 && o[3] == 0 && o[0] <= SyncOutputStage.hardCap(s) && o[1] <= SyncOutputStage.hardCap(s)
            for ch in 0..<2 {
                safe = safe && o[ch] - prev[ch] <= 20
                if o[ch] == 0, prev[ch] > 0 { zeroAt[ch] = t }
                if o[ch] > 0, prev[ch] == 0, let z = zeroAt[ch] { safe = safe && t - z >= 0.85 - 1e-9 }
            }
            prev = o
            times.append(t)
            outs.append(o)
        }
        for i in 0..<outs.count {
            for j in (i + 1)..<outs.count {
                for ch in 0..<2 {
                    let allowed = 20 * (times[j] - times[i]) / 0.3 + 1
                    let rise = Double(outs[j][ch] - outs[i][ch])
                    worst = max(worst, rise - allowed)
                    if rise > allowed + 1e-9 { safe = false }
                }
            }
        }
    }
    vcheck(safe, "P2 出口：0.1 秒子拍随机间隔下升幅按时间 ≤ +20 / 0.3 秒、单步 ≤ 20、≤ 上限、通道 3/4 恒 0、归零保持 ≥ 0.85 秒"
           + "（最紧处余量 \(String(format: "%.2f", -worst + 0))）")
}

/// 位移 x(t) = A·cos(2πf·t + φ0) 沿方向 (ux, uy)，按 rate 采样（±jitter 秒抖动）后差分成速度喂给 StrokeRhythm
func p2Rhythm(hz: Double, phase0: Double = 0.4, amp: Double = 4, rate: Double = 15, seconds: Double = 4,
              ux: Double = 1, uy: Double = 0, jitter: Double = 0, noise: Double = 0,
              wobble: Double = 0, start: Double = 10) -> (r: StrokeRhythm, tN: Double) {
    var r = StrokeRhythm()
    var prevT = start
    func pos(_ t: Double) -> Double { amp * cos(2 * Double.pi * hz * t + phase0) }
    var prevX = pos(prevT)
    var t = start
    while t < start + seconds {
        t += 1 / rate + (vsRandom() - 0.5) * 2 * jitter
        let x = pos(t)
        let v = (x - prevX) / (t - prevT) + (vsRandom() - 0.5) * 2 * noise
        let a = wobble * sin(2 * Double.pi * 0.2 * t)
        let cx = ux * cos(a) - uy * sin(a)
        let cy = ux * sin(a) + uy * cos(a)
        r.add(time: t, x: v * cx, y: v * cy)
        prevT = t
        prevX = x
    }
    return (r, prevT)
}

func p2Err(_ a: Double, _ b: Double) -> Double { abs(StrokeRhythm.wrapPhase(a - b)) }

do {
    // 相位拟合：0.5 / 1 / 2 / 3 Hz、采样抖动、横 / 竖 / 斜方向，相位误差小、拟合好
    var worst = 0.0
    var minQ = 1.0
    var minLin = 1.0
    for hz in [0.5, 1.0, 2.0, 3.0] {
        for (ux, uy) in [(1.0, 0.0), (0.0, 1.0), (cos(0.5), sin(0.5))] {
            var (r, tN) = p2Rhythm(hz: hz, rate: 15, ux: ux, uy: uy, jitter: 0.006)
            let f = r.phaseFit(hz: hz)
            let truth = 2 * Double.pi * hz * tN + 0.4
            worst = max(worst, p2Err(f.phase, truth))
            minQ = min(minQ, f.quality)
            minLin = min(minLin, f.linearity)
            if !(f.isValid && abs(f.time - tN) < 1e-9) { worst = .infinity }
        }
    }
    vcheck(worst <= 0.15 && minQ >= 0.9 && minLin >= 0.95,
           "P2 相位拟合：0.5~3 Hz、15 Hz 抖动采样、横竖斜方向，误差 ≤ \(String(format: "%.0f", worst * 180 / .pi))°"
           + "（拟合 ≥ \(String(format: "%.2f", minQ))，线性 ≥ \(String(format: "%.2f", minLin))）")

    // 约定方向：竖直分量大取向下、否则向右；反方向运动 → 相位差 180°
    var (up, tU) = p2Rhythm(hz: 1, ux: 0, uy: -1)
    var (left, tL) = p2Rhythm(hz: 1, ux: -1, uy: 0)
    let fu = up.phaseFit(hz: 1)
    let fl = left.phaseFit(hz: 1)
    vcheck(p2Err(fu.phase, 2 * Double.pi * tU + 0.4 + Double.pi) <= 0.15
           && p2Err(fl.phase, 2 * Double.pi * tL + 0.4 + Double.pi) <= 0.15,
           "P2 相位拟合：往上 / 往左的运动按约定方向（向下 / 向右）算，相位差半个周期")

    // 给的频率差 5%：细化后仍对得上
    var (mis, tM) = p2Rhythm(hz: 1.05)
    let fm = mis.phaseFit(hz: 1.0)
    vcheck(p2Err(fm.phase, 2 * Double.pi * 1.05 * tM + 0.4) <= 0.25 && abs(fm.hz - 1.05) <= 0.03,
           "P2 相位拟合：跟随频率差 5% 时细化到 \(String(format: "%.3f", fm.hz)) Hz，相位误差 "
           + "\(String(format: "%.0f", p2Err(fm.phase, 2 * Double.pi * 1.05 * tM + 0.4) * 180 / .pi))°")

    // 主轴 ±20° 慢慢晃：方向不翻、代次不变、相位照样对
    var wob = StrokeRhythm()
    var epochs = Set<Int>()
    var wobWorst = 0.0
    do {
        var prevT = 10.0
        var prevX = 4 * cos(2 * Double.pi * 1.2 * prevT)
        var t = prevT
        var k = 0
        while t < 18 {
            t += 1.0 / 15
            let x = 4 * cos(2 * Double.pi * 1.2 * t)
            let v = (x - prevX) / (t - prevT)
            let a = 0.35 * sin(2 * Double.pi * 0.15 * t)
            wob.add(time: t, x: v * cos(a), y: v * sin(a))
            prevT = t
            prevX = x
            k += 1
            if k >= 30 {
                let f = wob.phaseFit(hz: 1.2)
                epochs.insert(f.epoch)
                wobWorst = max(wobWorst, p2Err(f.phase, 2 * Double.pi * 1.2 * t))
            }
        }
    }
    vcheck(epochs.count == 1 && wobWorst <= 0.3,
           "P2 相位拟合：主轴 ±20° 晃动不翻方向（代次 \(epochs.count) 个），误差 ≤ \(String(format: "%.0f", wobWorst * 180 / .pi))°")

    // 纯噪声拟合差；画圈（没有主方向）线性低；样本不够 / NaN 频率不给
    var noiseR = StrokeRhythm()
    for k in 0..<60 { noiseR.add(time: Double(k) / 15, x: vsRandom() - 0.5, y: 0.1 * (vsRandom() - 0.5)) }
    let fn = noiseR.phaseFit(hz: 1)
    var circle = StrokeRhythm()
    for k in 0..<60 {
        let t = Double(k) / 15
        circle.add(time: t, x: cos(2 * Double.pi * t), y: sin(2 * Double.pi * t))
    }
    let fc = circle.phaseFit(hz: 1)
    var few = StrokeRhythm()
    for k in 0..<5 { few.add(time: Double(k) / 15, x: 1, y: 0) }
    vcheck(fn.quality < RhythmPhaseLock.releaseQuality && fc.linearity < RhythmPhaseLock.minLinearity
           && !few.phaseFit(hz: 1).isValid && !circle.phaseFit(hz: .nan).isValid,
           "P2 相位拟合：纯噪声拟合 \(String(format: "%.2f", fn.quality))、画圈线性 \(String(format: "%.2f", fc.linearity))，"
           + "样本不够 / 频率无效不给")

    // 只读：拟合不改 estimate / followEstimate（频率跟随和分数逐位不变）
    var plain = StrokeRhythm()
    var probed = StrokeRhythm()
    var untouched = true
    var prevX = 0.0
    for k in 1..<200 {
        let t = Double(k) / 15 + (vsRandom() - 0.5) * 0.01
        let x = 3 * sin(2 * Double.pi * 1.3 * t) + 0.5 * (vsRandom() - 0.5)
        let v = (x - prevX) * 15
        prevX = x
        plain.add(time: t, x: v, y: 0.2 * v)
        probed.add(time: t, x: v, y: 0.2 * v)
        _ = probed.phaseFit(hz: 1.3)
        untouched = untouched && plain.estimate == probed.estimate && plain.followEstimate == probed.followEstimate
    }
    vcheck(untouched, "P2 相位拟合：只读节奏缓冲，estimate / followEstimate 逐位不变")

    // 姿态平滑滞后：jitterSeconds 指数平滑的滞后补偿后，平滑过的位移也对得上
    var ema = StrokeRhythm()
    var sm = 4 * cos(2 * Double.pi * 1.5 * 10.0)
    var prevS = sm
    var tt = 10.0
    let alpha = 1 - exp(-(1.0 / 9) / PoseMotionTracker.jitterSeconds)
    while tt < 14 {
        tt += 1.0 / 9
        sm += alpha * (4 * cos(2 * Double.pi * 1.5 * tt) - sm)
        ema.add(time: tt, x: 0, y: (sm - prevS) * 9)
        prevS = sm
    }
    let lag = PoseMotionTracker.smoothingLag(hz: 1.5, rate: 9)
    let raw = ema.phaseFit(hz: 1.5)
    let comp = ema.phaseFit(hz: 1.5, lag: lag)
    let truthE = 2 * Double.pi * 1.5 * tt
    vcheck(p2Err(comp.phase, truthE) <= 0.12 && p2Err(raw.phase, truthE) > p2Err(comp.phase, truthE) && lag > 0,
           "P2 相位拟合：姿态平滑滞后 \(Int((lag * 1000).rounded())) ms 补上后误差 "
           + "\(String(format: "%.0f", p2Err(comp.phase, truthE) * 180 / .pi))°（不补 \(String(format: "%.0f", p2Err(raw.phase, truthE) * 180 / .pi))°）")
}

do {
    // 端到端：合成画面里的块左右往复 ox = A·sin(2πft)（向右为正）→ 窗口里的主体相位对得上 θ = 2πft − 90°
    func flowPhaseError(_ windows: [MotionWindow], hz: Double) -> (worst: Double, n: Int) {
        var worst = 0.0
        var n = 0
        for w in windows.suffix(windows.count / 2) where w.subjectPhase.isValid {
            let truth = 2 * Double.pi * hz * w.subjectPhase.time - Double.pi / 2
            worst = max(worst, p2Err(w.subjectPhase.phase, truth))
            n += 1
        }
        return (worst, n)
    }
    let one = flowPhaseError(rf1Hz.windows, hz: 1)
    let two = flowPhaseError(vs3Strong20.windows, hz: 2)
    vcheck(one.n >= 15 && two.n >= 15 && one.worst <= 0.45 && two.worst <= 0.6,
           "P2 端到端：块运动 1 Hz / 2 Hz 往复的相位误差 ≤ \(String(format: "%.0f", one.worst * 180 / .pi))° / "
           + "\(String(format: "%.0f", two.worst * 180 / .pi))°（\(one.n) / \(two.n) 拍有读数）")
    let stillPhase = vs3Static.windows.filter { $0.subjectPhase.isValid && $0.subjectPhase.quality >= RhythmPhaseLock.lockQuality }
    vcheck(stillPhase.isEmpty, "P2 端到端：静止画面没有合格的相位读数")

    // 锁相环吃端到端窗口：锁上、预测相位对得上
    var follower = RhythmFollower()
    var lock = RhythmPhaseLock()
    var lockErr = 0.0
    var lockedLate = 0
    for (i, w) in rf1Hz.windows.enumerated() {
        follower.step(w, dt: 5.0 / 15)
        let now = Double(i * 5 + 4) * vsDt + 0.01
        lock.step(w, followerHz: follower.hz, followerLocked: follower.locked, followerSource: follower.source,
                  now: now, dt: 5.0 / 15, active: true)
        if i >= rf1Hz.windows.count / 2, lock.locked, let p = lock.phase(at: now) {
            lockedLate += 1
            lockErr = max(lockErr, p2Err(p, 2 * Double.pi * now - Double.pi / 2))
        }
    }
    vcheck(lockedLate >= rf1Hz.windows.count / 2 - 1 && lockErr <= 0.45,
           "P2 端到端：相位锁跟着合成 1 Hz 往复锁上（后一半 \(lockedLate) 拍），预测误差 ≤ \(String(format: "%.0f", lockErr * 180 / .pi))°")
}

/// 相位锁测试用窗口：块运动主体的相位读数（真值 2πf·t + φ0，加噪声）
func plWindow(time: Double, hz: Double, phase0: Double = 0.3, noise: Double = 0, quality: Double = 0.9,
              linearity: Double = 0.95, amp: Double = 3, frames: Int = 5, valid: Bool = true, cut: Bool = false,
              offset: Double = 0) -> MotionWindow {
    var w = MotionWindow()
    w.frames = frames
    if cut { w.cutCount = 1 }
    guard frames > 0 else { return w }
    w.subjectFrames = frames
    w.subjectScore = 0.5
    if valid {
        let ph = 2 * Double.pi * hz * time + phase0 + offset + (vsRandom() - 0.5) * 2 * noise
        w.subjectPhase = StrokeRhythm.PhaseFit(time: time, phase: StrokeRhythm.wrapPhase(ph), hz: hz, quality: quality,
                                               linearity: linearity, amplitude: amp, epoch: 0)
    }
    return w
}

func plTruth(_ t: Double, hz: Double, phase0: Double = 0.3) -> Double { 2 * Double.pi * hz * t + phase0 }

do {
    // 锁定：2 个一致的读数锁上，weight 1 秒升满；稳态误差小
    var lock = RhythmPhaseLock()
    var lockedAt: Int?
    var fullAt: Int?
    var steadyErr = 0.0
    for k in 0..<40 {
        let now = 10 + Double(k) * 0.3
        lock.step(plWindow(time: now - 0.03, hz: 1.2), followerHz: 1.2, followerLocked: true, followerSource: .flow,
                  now: now, dt: 0.3, active: true)
        if lock.locked, lockedAt == nil { lockedAt = k }
        if lock.weight >= 1, fullAt == nil { fullAt = k }
        if k >= 10, let p = lock.phase(at: now + 0.2) { steadyErr = max(steadyErr, p2Err(p, plTruth(now + 0.2, hz: 1.2))) }
    }
    vcheck(lockedAt == 1 && fullAt == 4 && steadyErr <= 0.02 && lock.source == .flow,
           "P2 相位锁：第 2 个一致读数锁上（第 \(lockedAt ?? -1) 拍）、weight 约 1 秒升满（第 \(fullAt ?? -1) 拍），"
           + "外推 0.2 秒误差 ≤ \(String(format: "%.1f", steadyErr * 180 / .pi))°")

    // 噪声 ±25°：滤波后误差均方根明显小于读数
    var noisy = RhythmPhaseLock()
    var se = 0.0
    var n = 0
    for k in 0..<120 {
        let now = 10 + Double(k) * 0.3
        noisy.step(plWindow(time: now - 0.03, hz: 1, noise: 25 * Double.pi / 180), followerHz: 1, followerLocked: true,
                   followerSource: .flow, now: now, dt: 0.3, active: true)
        if k >= 20, let p = noisy.phase(at: now) {
            let e = p2Err(p, plTruth(now, hz: 1))
            se += e * e
            n += 1
        }
    }
    let rms = n > 0 ? (se / Double(n)).squareRoot() : .infinity
    vcheck(noisy.locked && rms <= 10 * Double.pi / 180,
           "P2 相位锁：读数 ±25° 噪声时预测误差均方根 \(String(format: "%.1f", rms * 180 / .pi))°")

    // 跟随频率比实际低 5%：频率微调追上，误差收敛
    var mis = RhythmPhaseLock()
    var misErr = 0.0
    for k in 0..<100 {
        let now = 10 + Double(k) * 0.3
        mis.step(plWindow(time: now - 0.03, hz: 1.05), followerHz: 1.0, followerLocked: true, followerSource: .flow,
                 now: now, dt: 0.3, active: true)
        if k >= 60, let p = mis.phase(at: now) { misErr = max(misErr, p2Err(p, plTruth(now, hz: 1.05))) }
    }
    vcheck(mis.locked && misErr <= 0.1 && abs(mis.omega - 2 * Double.pi * 1.05) <= 0.05,
           "P2 相位锁：跟随频率差 5% 时微调到 \(String(format: "%.3f", mis.omega / (2 * Double.pi))) Hz，"
           + "误差 ≤ \(String(format: "%.1f", misErr * 180 / .pi))°")

    // 单个 180° 离群读数不跟；连续 2 个一致的翻转读数才重新对齐
    var flip = RhythmPhaseLock()
    for k in 0..<10 {
        let now = 10 + Double(k) * 0.3
        flip.step(plWindow(time: now - 0.03, hz: 1), followerHz: 1, followerLocked: true, followerSource: .flow,
                  now: now, dt: 0.3, active: true)
    }
    var now = 10 + 10 * 0.3
    flip.step(plWindow(time: now - 0.03, hz: 1, offset: .pi), followerHz: 1, followerLocked: true, followerSource: .flow,
              now: now, dt: 0.3, active: true)
    let afterOne = flip.phase(at: now).map { p2Err($0, plTruth(now, hz: 1)) } ?? 9
    now += 0.3
    flip.step(plWindow(time: now - 0.03, hz: 1), followerHz: 1, followerLocked: true, followerSource: .flow,
              now: now, dt: 0.3, active: true)
    let backOk = flip.phase(at: now).map { p2Err($0, plTruth(now, hz: 1)) } ?? 9
    for _ in 0..<2 {
        now += 0.3
        flip.step(plWindow(time: now - 0.03, hz: 1, offset: .pi), followerHz: 1, followerLocked: true,
                  followerSource: .flow, now: now, dt: 0.3, active: true)
    }
    let flipped = flip.phase(at: now).map { p2Err($0, plTruth(now, hz: 1) + .pi) } ?? 9
    vcheck(afterOne <= 0.01 && backOk <= 0.01 && flipped <= 0.01 && flip.locked && flip.weight == 1,
           "P2 相位锁：单个 180° 离群读数不跟、漏掉之后照常；连续 2 个一致的翻转读数才重新对齐（不掉锁）")

    // 漏拍 / 抖动：每隔一拍没读数、读数时间抖 ±50 ms，照样锁住、误差小
    var gappy = RhythmPhaseLock()
    var gapErr = 0.0
    for k in 0..<60 {
        let now = 10 + Double(k) * 0.3 + (vsRandom() - 0.5) * 0.04
        let t = now - 0.03 - vsRandom() * 0.1
        gappy.step(plWindow(time: t, hz: 1.5, valid: k % 2 == 0 || k < 4), followerHz: 1.5, followerLocked: true,
                   followerSource: .flow, now: now, dt: 0.3, active: true)
        if k >= 10, let p = gappy.phase(at: now) { gapErr = max(gapErr, p2Err(p, plTruth(now, hz: 1.5))) }
    }
    vcheck(gappy.locked && gappy.weight == 1 && gapErr <= 0.05,
           "P2 相位锁：隔拍漏读数 + 时间抖动照样锁住，误差 ≤ \(String(format: "%.1f", gapErr * 180 / .pi))°")
}

/// 先锁好的相位锁（1 Hz 默认）
func plLocked(hz: Double = 1, until: Double = 13) -> RhythmPhaseLock {
    var lock = RhythmPhaseLock()
    var now = 10.0
    while now < until {
        lock.step(plWindow(time: now - 0.03, hz: hz), followerHz: hz, followerLocked: true, followerSource: .flow,
                  now: now, dt: 0.3, active: true)
        now += 0.3
    }
    return lock
}

do {
    let base = plLocked()
    // 一拍一帧都没分析到：不解锁
    var frameless = base
    frameless.step(plWindow(time: 13, hz: 1, frames: 0), followerHz: 1, followerLocked: true, followerSource: .flow,
                   now: 13.1, dt: 0.3, active: false)
    // 镜头切换：立刻放开、weight 0
    var cut = base
    cut.step(plWindow(time: 13, hz: 1, cut: true), followerHz: 1, followerLocked: true, followerSource: .flow,
             now: 13.1, dt: 0.3, active: true)
    // 画面不动：1 拍保持，连续 2 拍（有帧）放开、weight 0
    var idle = base
    idle.step(plWindow(time: 13, hz: 1), followerHz: 1, followerLocked: true, followerSource: .flow,
              now: 13.1, dt: 0.3, active: false)
    let idleOne = idle.locked && idle.weight == 1
    idle.step(plWindow(time: 13.3, hz: 1), followerHz: 1, followerLocked: true, followerSource: .flow,
              now: 13.4, dt: 0.3, active: false)
    // 跟随器解锁：立刻 0
    var lostFollower = base
    lostFollower.step(plWindow(time: 13, hz: 1), followerHz: 1, followerLocked: false, followerSource: .flow,
                      now: 13.1, dt: 0.3, active: true)
    vcheck(frameless.locked && frameless.weight == 1 && cut.weight == 0 && !cut.locked && cut.phase(at: 13.1) == nil
           && idleOne && !idle.locked && idle.weight == 0 && lostFollower.weight == 0,
           "P2 相位锁：没帧的一拍不解锁；切镜 / 画面连续 2 拍不动 / 频率跟随解锁 → 立刻放开（weight 0）")

    // 读数没了：保持 1 秒后放开，weight 0.5 秒降到 0
    var lost = base
    var unlockAt: Double?
    var zeroAt: Double?
    var now = 13.0
    while now < 16 {
        lost.step(plWindow(time: now - 0.03, hz: 1, valid: false), followerHz: 1, followerLocked: true,
                  followerSource: .flow, now: now, dt: 0.3, active: true)
        if !lost.locked, unlockAt == nil { unlockAt = now }
        if lost.weight == 0, zeroAt == nil { zeroAt = now }
        now += 0.3
    }
    let u = (unlockAt ?? 99) - 13
    let z = (zeroAt ?? 99) - (unlockAt ?? 0)
    vcheck(u > 0.85 && u <= 1.25 && z <= 0.65 && z >= 0.25,
           "P2 相位锁：读数没了约 1 秒（这里第 \(String(format: "%.1f", u)) 秒）才放开、weight \(String(format: "%.1f", z)) 秒内降到 0")

    // 跟随频率跳变 > 15%：重新锁（旧相位外推不再可信）；小变化在当前时刻接上、相位连续
    var jump = base
    jump.step(plWindow(time: 13, hz: 1.3, valid: false), followerHz: 1.3, followerLocked: true, followerSource: .flow,
              now: 13.1, dt: 0.3, active: true)
    var small = base
    let before = small.phase(at: 13.1) ?? 9
    small.step(plWindow(time: 13, hz: 1.05, valid: false), followerHz: 1.05, followerLocked: true, followerSource: .flow,
               now: 13.1, dt: 0.3, active: true)
    let after = small.phase(at: 13.1) ?? 0
    vcheck(!jump.locked && small.locked && p2Err(before, after) <= 1e-9 && abs(small.hz - 1.05) < 1e-9,
           "P2 相位锁：跟随频率跳 30% 重新锁；变 5% 在这一刻接上（相位连续）")

    // 读数门：拟合差 / 线性低（画圈）/ 幅度太小 / 频率对不上 / 太旧 都不锁
    func locks(_ make: (Double) -> MotionWindow, follower: Double = 1, source: RhythmCandidate.Source = .flow) -> Bool {
        var l = RhythmPhaseLock()
        var now = 10.0
        for _ in 0..<12 {
            l.step(make(now), followerHz: follower, followerLocked: true, followerSource: source, now: now, dt: 0.3,
                   active: true)
            now += 0.3
        }
        return l.locked
    }
    let good = locks { plWindow(time: $0 - 0.03, hz: 1) }
    let lowQ = locks { plWindow(time: $0 - 0.03, hz: 1, quality: 0.4) }
    let circ = locks { plWindow(time: $0 - 0.03, hz: 1, linearity: 0.55) }
    let tiny = locks { plWindow(time: $0 - 0.03, hz: 1, amp: 0.5) }
    let offHz = locks({ plWindow(time: $0 - 0.03, hz: 1.3) }, follower: 1)
    let stale = locks { plWindow(time: $0 - 0.8, hz: 1) }
    let wrongSource = locks({ plWindow(time: $0 - 0.03, hz: 1) }, source: .pose)
    vcheck(good && !lowQ && !circ && !tiny && !offHz && !stale && !wrongSource,
           "P2 相位锁：拟合 < 0.5 / 线性 < 0.65（画圈）/ 幅度太小 / 频率差 > 15% / 读数旧于 0.6 秒 / 来源不对 都不锁")

    // 姿态读数：采样率 < max(4 × 频率, 6) 不用（慢设备上的混叠），够才用
    func poseWindow(_ t: Double, rate: Double) -> MotionWindow {
        var w = MotionWindow()
        w.frames = 5
        w.poseFrames = 3
        w.posePresentFrames = 3
        w.poseRhythmRate = rate
        w.posePhase = StrokeRhythm.PhaseFit(time: t, phase: StrokeRhythm.wrapPhase(plTruth(t, hz: 1)), hz: 1, quality: 0.9,
                                            linearity: 0.95, amplitude: 0.1, epoch: 0)
        return w
    }
    let poseSlow = locks({ poseWindow($0 - 0.03, rate: 3) }, source: .pose)
    let poseOk = locks({ poseWindow($0 - 0.03, rate: 9) }, source: .pose)
    vcheck(!poseSlow && poseOk, "P2 相位锁：姿态采样 3 次/秒的读数不用（混叠），9 次/秒照常锁")
}

do {
    // 波形：峰 1、30% 周期降到谷、70% 周期升回峰（慢升快降）
    vcheck(abs(RhythmPulse.wave(0) - 1) < 1e-12 && abs(RhythmPulse.wave(0.3)) < 1e-12
           && abs(RhythmPulse.wave(0.65) - 0.5) < 1e-12 && abs(RhythmPulse.wave(1.15) - 0.5) < 1e-12
           && abs(RhythmPulse.wave(-0.35) - 0.5) < 1e-12 && RhythmPulse.wave(.nan) == 0,
           "P2 脉动波形：峰 → 30% 周期降到谷 → 70% 周期升回峰，周期延拓")

    // 深度：设置 / 升幅允许（66.7 × 0.7 / 频率）取小，2~2.5 Hz 淡出，× weight × activity × 强度斜坡（20 → 30）
    let d1 = RhythmPulse.depth(setting: 20, hz: 1, weight: 1, activity: 1, intensity: 60)
    let d40 = RhythmPulse.depth(setting: 40, hz: 1.5, weight: 1, activity: 1, intensity: 60)
    let dFade = RhythmPulse.depth(setting: 20, hz: 2.25, weight: 1, activity: 1, intensity: 60)
    let dFast = RhythmPulse.depth(setting: 20, hz: 2.5, weight: 1, activity: 1, intensity: 60)
    let dHalf = RhythmPulse.depth(setting: 20, hz: 1, weight: 0.5, activity: 1, intensity: 60)
    let dAct = RhythmPulse.depth(setting: 20, hz: 1, weight: 1, activity: 0.25, intensity: 60)
    let dWeak = RhythmPulse.depth(setting: 20, hz: 1, weight: 1, activity: 1, intensity: 20)
    let dMid = RhythmPulse.depth(setting: 20, hz: 1, weight: 1, activity: 1, intensity: 25)
    let dTiny = RhythmPulse.depth(setting: 20, hz: 1, weight: 0.05, activity: 1, intensity: 60)
    let dNan = RhythmPulse.depth(setting: .nan, hz: 1, weight: 1, activity: 1, intensity: 60)
    vcheck(abs(d1 - 20) < 1e-9 && abs(d40 - 200.0 / 3 * 0.7 / 1.5) < 1e-6 && abs(dFade - 10) < 1e-9 && dFast == 0
           && abs(dHalf - 10) < 1e-9 && abs(dAct - 5) < 1e-9 && dWeak == 0 && abs(dMid - 10) < 1e-9 && dTiny == 0
           && dNan == 0,
           "P2 脉动深度：1 Hz 20 档、1.5 Hz 设 40 只给 \(String(format: "%.1f", d40))（升幅限速）、2.25 Hz 减半、≥ 2.5 Hz 0、"
           + "随 weight / activity / 强度斜坡缩小、< 2 档不脉动")

    // 档位：以 P1 档位为中心 ±d/2；谷 ≥ max(最低强度, 8)；顶到上限整体往下挪；P1 档位低于谷值不脉动
    let peak = RhythmPulse.thrust(base: 50, depth: 20, phase: RhythmPulse.peakPhase, cap: 99, floor: 0)
    let trough = RhythmPulse.thrust(base: 50, depth: 20, phase: RhythmPulse.peakPhase + 0.3 * 2 * .pi, cap: 99, floor: 0)
    let lowPeak = RhythmPulse.thrust(base: 15, depth: 20, phase: RhythmPulse.peakPhase, cap: 99, floor: 0)
    let lowTrough = RhythmPulse.thrust(base: 15, depth: 20, phase: RhythmPulse.peakPhase + 0.6, cap: 99, floor: 0)
    let floorTrough = RhythmPulse.thrust(base: 30, depth: 20, phase: RhythmPulse.peakPhase + 0.3 * 2 * .pi, cap: 99, floor: 25)
    let capPeak = RhythmPulse.thrust(base: 50, depth: 20, phase: RhythmPulse.peakPhase, cap: 55, floor: 0)
    let capTrough = RhythmPulse.thrust(base: 70, depth: 20, phase: RhythmPulse.peakPhase + 0.3 * 2 * .pi, cap: 55, floor: 0)
    let under = RhythmPulse.thrust(base: 5, depth: 20, phase: RhythmPulse.peakPhase, cap: 99, floor: 0)
    var allIn = true
    for _ in 0..<5000 {
        let b = Int(vsRandom() * 100)
        let cap = 10 + Int(vsRandom() * 90)
        let fl = Int(vsRandom() * 30)
        let v = RhythmPulse.thrust(base: b, depth: vsRandom() * 45, phase: (vsRandom() - 0.5) * 2 * .pi, cap: cap, floor: fl)
        let lo = max(fl, RhythmPulse.troughFloor)
        allIn = allIn && (v == b || (v >= lo && v <= min(cap, 99)))
    }
    vcheck(peak == 60 && trough == 40 && lowPeak == 22 && lowTrough >= 8 && floorTrough == 25 && capPeak == 55
           && capTrough == 35 && under == 5 && allIn,
           "P2 脉动档位：50 ± 10；低档谷 ≥ 8（15 → 8~22）；谷 ≥ 最低强度；上限 55 时 35~55（只往下脉动）；"
           + "低于谷值不脉动；随机 5000 组都在 [max(最低, 8), 上限]")

    // 指令相位：现在 + 延迟补偿那一刻的画面相位，反转 +180°
    let lock = plLocked()
    let c0 = RhythmPulse.commandPhase(lock, at: 13, latency: 0.25, invert: false) ?? 9
    let c1 = RhythmPulse.commandPhase(lock, at: 13, latency: 0.25, invert: true) ?? 9
    vcheck(p2Err(c0, plTruth(13.25, hz: 1)) <= 0.01 && p2Err(c1, plTruth(13.25, hz: 1) + .pi) <= 0.01
           && RhythmPulse.commandPhase(RhythmPhaseLock(), at: 13, latency: 0.2, invert: false) == nil,
           "P2 指令相位：按延迟补偿提前、方向反转差 180°；没锁时没有")
}

/// 0.1 秒 Timer 整段模拟：timer 抖动 ±jitter；完整拍更新相位锁 + beat，子拍 subBeat。
/// activeUntil 之后画面不动（activity 0），cutAt 那一拍切镜
struct P2Sim {
    var times: [Double] = []
    var outs: [[Int]] = []
    var states: [RhythmPulseDriver.State] = []
    var subOuts = 0
    var fullOuts: [[Int]] = []
    var fullTimes: [Double] = []
    var p1Outs: [[Int]] = []
    var stopFirstFull: Double?
    var subAfterStop = 0
}

func p2Simulate(hz: Double = 1, seconds: Double = 14, visual: VisualSyncSettings, settings: AudioSyncSettings,
                levels: [Int] = [50, 40, 0, 0], value: Double = 60, activeUntil: Double = .infinity,
                cutAt: Double? = nil, jitter: Double = 0.01) -> P2Sim {
    var sim = P2Sim()
    var lock = RhythmPhaseLock()
    var driver = RhythmPulseDriver()
    var stage = SyncOutputStage()
    var p1 = SyncOutputStage()
    var t = 10.0
    let end = 10 + seconds
    var lastFull: Double?
    while t < end {
        t += 0.1 + (vsRandom() - 0.5) * 2 * jitter
        if driver.takesFullBeat(at: t) {
            let active = t < activeUntil
            let cut = cutAt.map { abs($0 - t) < 0.15 } ?? false
            let dt = lastFull.map { t - $0 } ?? 0.3
            lastFull = t
            let w = plWindow(time: t - 0.04, hz: hz, cut: cut)
            lock.step(w, followerHz: hz, followerLocked: true, followerSource: .flow, now: t, dt: dt, active: active)
            let lv = active ? levels : [0, 0, 0, 0]
            let o = driver.beat(levels: lv, lock: lock, visual: visual, settings: settings, hasSignal: true, value: value,
                                activity: active ? 1 : 0, followerWeight: 1, now: t, stage: &stage)
            sim.fullOuts.append(o)
            sim.fullTimes.append(t)
            sim.p1Outs.append(p1.step(levels: lv, settings: settings))
            sim.states.append(driver.state)
            sim.times.append(t)
            sim.outs.append(o)
            if !active, sim.stopFirstFull == nil { sim.stopFirstFull = t }
        } else if let o = driver.subBeat(lock: lock, settings: settings, now: t, stage: &stage) {
            sim.subOuts += 1
            sim.times.append(t)
            sim.outs.append(o)
            if let s = sim.stopFirstFull, t > s { sim.subAfterStop += 1 }
        }
    }
    return sim
}

/// 任意两刻之间伸缩 / 震动的升幅 ≤ 20 × 间隔 / 0.3 + 1、单步 ≤ 20、通道 3 / 4 恒 0、≤ 上限
func p2Envelope(_ sim: P2Sim, cap: Int) -> (ok: Bool, margin: Double) {
    var ok = true
    var margin = Double.infinity
    var prev = [0, 0, 0, 0]
    for (i, o) in sim.outs.enumerated() {
        ok = ok && o[2] == 0 && o[3] == 0 && o[0] <= cap && o[1] <= cap && o[0] - prev[0] <= 20 && o[1] - prev[1] <= 20
        prev = o
        for j in (i + 1)..<sim.outs.count where sim.times[j] - sim.times[i] <= 2 {
            for ch in 0..<2 {
                let allowed = 20 * (sim.times[j] - sim.times[i]) / 0.3 + 1
                let rise = Double(sim.outs[j][ch] - o[ch])
                margin = min(margin, allowed - rise)
                if rise > allowed + 1e-9 { ok = false }
            }
        }
    }
    return (ok, margin)
}

do {
    let st = AudioSyncSettings(enabled: true, maxPercent: 100, channels: .both)
    let cal = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: "20:0.6, 60:1.8, 99:2.8", rhythmPulse: true)
    let sim = p2Simulate(visual: cal, settings: st)
    // 稳态：伸缩在 40~60 之间脉动（震动不变），峰在指令相位 −45° 附近（延迟补偿 200 ms 提前发）
    let lateIdx = sim.times.indices.filter { sim.times[$0] >= 15 }
    let thrust = lateIdx.map { sim.outs[$0][0] }
    let vib = Set(lateIdx.map { sim.outs[$0][1] })
    var peakErr = 0.0
    var peaks = 0
    for k in lateIdx.dropFirst().dropLast() where sim.outs[k][0] > sim.outs[k - 1][0] && sim.outs[k][0] >= sim.outs[k + 1][0] {
        let cmd = plTruth(sim.times[k] + 0.2, hz: 1)
        peakErr = max(peakErr, p2Err(cmd, RhythmPulse.peakPhase))
        peaks += 1
    }
    let env = p2Envelope(sim, cap: 99)
    vcheck(sim.states.suffix(20).allSatisfy { $0 == .active } && (thrust.max() ?? 0) >= 58 && (thrust.min() ?? 99) <= 42
           && vib == [40] && peaks >= 7 && peakErr <= 2 * Double.pi * 0.12 && sim.subOuts > 50 && env.ok,
           "P2 子拍模拟：1 Hz 锁上后伸缩 \(thrust.min() ?? 0)~\(thrust.max() ?? 0) 脉动、震动不变；"
           + "\(peaks) 个峰都在指令相位 −45° ± \(String(format: "%.0f", peakErr * 180 / .pi))°；升幅包络余量 \(String(format: "%.2f", env.margin))")

    // 动作一停：下一个完整拍（≤ 0.3 秒）起不再脉动、伸缩降到 0（降不限速）
    let stop = p2Simulate(visual: cal, settings: st, activeUntil: 18)
    let stopIdx = stop.times.indices.filter { stop.times[$0] >= (stop.stopFirstFull ?? 99) }
    let fallTime = stopIdx.first.map { stop.times[$0] - 18 } ?? 9
    vcheck(stop.subAfterStop == 0 && stopIdx.allSatisfy { stop.outs[$0] == [0, 0, 0, 0] } && fallTime <= 0.5
           && p2Envelope(stop, cap: 99).ok,
           "P2 子拍模拟：动作停了 \(String(format: "%.2f", fallTime)) 秒内归零、之后没有子拍")

    // 切镜：那一拍起不脉动，重新锁上后再脉动；全程升幅包络不破
    let cut = p2Simulate(visual: cal, settings: st, cutAt: 17)
    let resumed = cut.states.suffix(10).allSatisfy { $0 == .active }
    let cutStates = cut.fullTimes.indices.filter { abs(cut.fullTimes[$0] - 17) < 0.15 }.map { cut.states[$0] }
    let cutSubs = cut.times.filter { $0 > 17.1 && $0 < 17.5 }.count - cut.fullTimes.filter { $0 > 17.1 && $0 < 17.5 }.count
    vcheck(cutStates == [.unlocked] && cutSubs == 0 && resumed && p2Envelope(cut, cap: 99).ok,
           "P2 子拍模拟：切镜那一拍起不脉动（之后的子拍不出）、重新锁上后继续，切换前后升幅包络不破")

    // 上限 55：只往下脉动（峰 ≤ 55），频率差异不被压没
    let capped = p2Simulate(visual: cal, settings: AudioSyncSettings(enabled: true, maxPercent: 55, channels: .both),
                            levels: [70, 40, 0, 0])
    let cThrust = capped.times.indices.filter { capped.times[$0] >= 15 }.map { capped.outs[$0][0] }
    vcheck((cThrust.max() ?? 99) <= 55 && (cThrust.max() ?? 0) >= 53 && (cThrust.min() ?? 99) <= 37
           && p2Envelope(capped, cap: 55).ok,
           "P2 子拍模拟：上限 55 时伸缩 \(cThrust.min() ?? 0)~\(cThrust.max() ?? 0)（只往下脉动）")

    // 没标定 / 开关关着 / 仅震动 / 太快：完整拍和 P1 的 step(levels:) 逐位相同、没有子拍输出
    let uncal = p2Simulate(visual: VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true), settings: st)
    let off = p2Simulate(visual: VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: "20:0.6, 99:2.8"),
                         settings: st)
    let vibOnly = p2Simulate(visual: cal, settings: AudioSyncSettings(enabled: true, maxPercent: 100, channels: .vibration),
                             levels: [0, 40, 0, 0])
    let fast = p2Simulate(hz: 2.6, visual: cal, settings: st)
    let fade = p2Simulate(hz: 2.3, visual: cal, settings: st)
    vcheck(uncal.fullOuts == uncal.p1Outs && uncal.subOuts == 0 && uncal.states.allSatisfy { $0 == .uncalibrated }
           && off.fullOuts == off.p1Outs && off.subOuts == 0 && off.states.allSatisfy { $0 == .off }
           && vibOnly.fullOuts == vibOnly.p1Outs && vibOnly.subOuts == 0 && vibOnly.states.allSatisfy { $0 == .vibrationOnly }
           && fast.fullOuts == fast.p1Outs && fast.subOuts == 0 && fast.states.suffix(10).allSatisfy { $0 == .tooFast },
           "P2 子拍模拟：没标定 / 开关关着 / 仅震动 / ≥ 2.5 Hz 时完整拍和 P1 逐位相同、没有子拍输出")
    let fThrust = fade.times.indices.filter { fade.times[$0] >= 15 }.map { fade.outs[$0][0] }
    vcheck((fThrust.max() ?? 0) - (fThrust.min() ?? 0) <= 10 && (fThrust.max() ?? 0) - (fThrust.min() ?? 0) >= 3
           && p2Envelope(fade, cap: 99).ok,
           "P2 子拍模拟：2.3 Hz 时脉动减弱（峰谷差 \((fThrust.max() ?? 0) - (fThrust.min() ?? 0))）")

    // 弱动作（强度 20、手势 / 点头）：不脉动、和 P1 相同
    let weak = p2Simulate(visual: cal, settings: st, levels: [30, 20, 0, 0], value: 20)
    vcheck(weak.fullOuts == weak.p1Outs && weak.subOuts == 0 && weak.states.suffix(10).allSatisfy { $0 == .weak },
           "P2 子拍模拟：动作强度 20（手势 / 点头）不脉动，和 P1 相同")

    // 延迟补偿 / 方向反转：峰提前 / 晚半个周期
    let early = p2Simulate(visual: VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: "20:0.6, 99:2.8",
                                                      rhythmPulse: true, pulseLatencyMs: 0, pulseInvert: true), settings: st)
    var invErr = 0.0
    var invPeaks = 0
    let eIdx = early.times.indices.filter { early.times[$0] >= 15 }
    for k in eIdx.dropFirst().dropLast() where early.outs[k][0] > early.outs[k - 1][0] && early.outs[k][0] >= early.outs[k + 1][0] {
        invErr = max(invErr, p2Err(plTruth(early.times[k], hz: 1) + .pi, RhythmPulse.peakPhase))
        invPeaks += 1
    }
    vcheck(invPeaks >= 7 && invErr <= 2 * Double.pi * 0.12,
           "P2 子拍模拟：延迟补偿 0 + 方向反转时峰在画面相位 135°（± \(String(format: "%.0f", invErr * 180 / .pi))°）")
}

do {
    // 完整拍 / 子拍调度：0.1 秒 Timer 每 3 次 1 个完整拍；抖动 ±15 ms 不丢拍；reset 不清计时；disarm 后子拍不出
    var d = RhythmPulseDriver()
    var pattern: [Bool] = []
    var t = 100.0
    for _ in 0..<30 {
        t += 0.1 + (vsRandom() - 0.5) * 0.03
        pattern.append(d.takesFullBeat(at: t))
    }
    let fulls = pattern.filter { $0 }.count
    var gaps: [Double] = []
    var e = RhythmPulseDriver()
    var last: Double?
    t = 0
    for _ in 0..<300 {
        t += 0.1 + (vsRandom() - 0.5) * 0.03
        if e.takesFullBeat(at: t) {
            if let l = last { gaps.append(t - l) }
            last = t
        }
    }
    var r = RhythmPulseDriver()
    _ = r.takesFullBeat(at: 5)
    r.reset()
    let afterReset = r.takesFullBeat(at: 5.1)
    var n = RhythmPulseDriver()
    n.noteFullBeat(at: 7)
    let afterNote = n.takesFullBeat(at: 7.1)
    let thenFull = n.takesFullBeat(at: 7.3)
    // P3 L3：完整拍按 0.3 秒网格对齐（允许提前 50 ms、两拍至少隔 0.2 秒），抖动不再把平均间隔拖长
    let meanGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
    vcheck((9...11).contains(fulls) && (gaps.min() ?? 0) >= RhythmPulseDriver.minFullBeatGap - 1e-9 && (gaps.max() ?? 1) <= 0.4 + 1e-9
           && abs(meanGap - 0.3) <= 0.01 && !afterReset && !afterNote && thenFull,
           "P2 调度：0.1 秒 Timer 每 3 次一个完整拍（间隔 \(String(format: "%.2f", gaps.min() ?? 0))~\(String(format: "%.2f", gaps.max() ?? 0)) 秒，"
           + "平均 \(String(format: "%.3f", meanGap)) 秒）；reset / 0.3 秒 Timer 记下的完整拍之后 0.1 秒不再算完整拍")

    let st = AudioSyncSettings(enabled: true, maxPercent: 100, channels: .both)
    let cal = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: "20:0.6, 99:2.8", rhythmPulse: true)
    let lock = plLocked()
    var drv = RhythmPulseDriver()
    var stage = SyncOutputStage()
    _ = drv.takesFullBeat(at: 13)
    _ = drv.beat(levels: [50, 40, 0, 0], lock: lock, visual: cal, settings: st, hasSignal: true, value: 60, activity: 1,
                 followerWeight: 1, now: 13, stage: &stage)
    let engaged = drv.engaged && drv.subBeat(lock: lock, settings: st, now: 13.1, stage: &stage) != nil
    _ = drv.takesFullBeat(at: 13.3)
    let disarmed = !drv.engaged && drv.subBeat(lock: lock, settings: st, now: 13.4, stage: &stage) == nil
    vcheck(engaged && disarmed && drv.timedLast,
           "P2 调度：完整拍一开始先停子拍（这一拍提前返回时不再按旧档位脉动），但下一拍仍按时间限速")

    // 状态行：关着 nil；各状态有说明
    var texts = Set<String>()
    for (v, s, lv, val) in [(cal, st, [50, 40, 0, 0], 60.0),
                            (VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true), st, [50, 40, 0, 0], 60.0),
                            (cal, AudioSyncSettings(enabled: true, channels: .vibration), [0, 40, 0, 0], 60.0),
                            (cal, st, [30, 20, 0, 0], 20.0)] {
        var dd = RhythmPulseDriver()
        var ss = SyncOutputStage()
        _ = dd.beat(levels: lv, lock: lock, visual: v, settings: s, hasSignal: true, value: val, activity: 1,
                    followerWeight: 1, now: 13, stage: &ss)
        if let t = dd.statusText(lock: lock, visual: v) { texts.insert(t) }
    }
    var unl = RhythmPulseDriver()
    var us = SyncOutputStage()
    _ = unl.beat(levels: [50, 40, 0, 0], lock: RhythmPhaseLock(), visual: cal, settings: st, hasSignal: true, value: 60,
                 activity: 1, followerWeight: 1, now: 13, stage: &us)
    if let t = unl.statusText(lock: RhythmPhaseLock(), visual: cal) { texts.insert(t) }
    vcheck(texts.count == 5 && RhythmPulseDriver().statusText(lock: lock, visual: cal) == nil,
           "P2 状态行：已对上 / 没标定 / 仅震动 / 动作偏弱 / 没对上各有说明，关着时没有")
}

do {
    // 设置：默认关、深度 20、延迟 200 ms、不反转；键名不带点；越界夹紧、NaN 回默认；只有三个开关都开才用 0.1 秒 Timer
    let def = VisualSyncSettings()
    let keys = [VisualSyncSettings.Keys.rhythmPulse, VisualSyncSettings.Keys.pulseDepth,
                VisualSyncSettings.Keys.pulseLatencyMs, VisualSyncSettings.Keys.pulseInvert]
    let clampHi = VisualSyncSettings(pulseDepth: 100, pulseLatencyMs: 5000)
    let clampLo = VisualSyncSettings(pulseDepth: -5, pulseLatencyMs: -10)
    let nanS = VisualSyncSettings(pulseDepth: .nan, pulseLatencyMs: .infinity)
    vcheck(!def.rhythmPulse && def.pulseDepth == 20 && def.pulseLatencyMs == 200 && !def.pulseInvert
           && keys.allSatisfy { !$0.contains(".") } && Set(keys).count == 4
           && clampHi.pulseDepth == 40 && clampHi.pulseLatencyMs == 600 && clampLo.pulseDepth == 0
           && clampLo.pulseLatencyMs == 0 && nanS.pulseDepth == 20 && nanS.pulseLatencyMs == 200,
           "P2 设置：默认关 / 20 档 / 200 ms / 不反转，键名不带点，越界夹紧、NaN 回默认")
    let all = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true)
    let audio = VisualSyncSettings(source: .audio, rhythmFollow: true, rhythmPulse: true)
    let noFollow = VisualSyncSettings(source: .motion, rhythmFollow: false, rhythmPulse: true)
    let p1 = VisualSyncSettings(source: .motion, rhythmFollow: true)
    vcheck(all.tickInterval == 0.1 && audio.tickInterval == AudioReactiveShaper.interval
           && noFollow.tickInterval == AudioReactiveShaper.interval && p1.tickInterval == AudioReactiveShaper.interval
           && def.tickInterval == AudioReactiveShaper.interval && AudioReactiveShaper.interval == 0.3,
           "P2 设置：只有跟随画面 + 频率跟随 + 相位脉动都开才用 0.1 秒 Timer，其余仍 0.3 秒")
    let suite = "bc.visualsync.pulse.checks"
    if let d = UserDefaults(suiteName: suite) {
        d.removePersistentDomain(forName: suite)
        let fresh = VisualSyncSettings.load(from: d)
        d.set("yes", forKey: VisualSyncSettings.Keys.rhythmPulse)
        d.set("deep", forKey: VisualSyncSettings.Keys.pulseDepth)
        // 注意 Darwin 上存的 Bool 会被 `as? Double` 桥接成 1.0，坏值只用字符串
        d.set("slow", forKey: VisualSyncSettings.Keys.pulseLatencyMs)
        let bad = VisualSyncSettings.load(from: d)
        d.set(true, forKey: VisualSyncSettings.Keys.rhythmPulse)
        d.set(35.0, forKey: VisualSyncSettings.Keys.pulseDepth)
        d.set(320.0, forKey: VisualSyncSettings.Keys.pulseLatencyMs)
        d.set(true, forKey: VisualSyncSettings.Keys.pulseInvert)
        let stored = VisualSyncSettings.load(from: d)
        vcheck(fresh == def && !bad.rhythmPulse && bad.pulseDepth == 20 && bad.pulseLatencyMs == 200 && stored.rhythmPulse
               && stored.pulseDepth == 35 && stored.pulseLatencyMs == 320 && stored.pulseInvert,
               "P2 设置：没存过 = 默认；坏值回默认；读回存的值")
        d.removePersistentDomain(forName: suite)
    } else {
        vcheck(false, "P2 设置：创建测试用 UserDefaults")
    }
}

do {
    // FFA2 被动观察：解析、周期字节、计数器字节、不变的内容、条数太少
    vcheck(NotifyPeriodProbe.parseHex("AA08") == [0xAA, 0x08] && NotifyPeriodProbe.parseHex(" aa 08 ff ") == [0xAA, 0x08, 0xFF]
           && NotifyPeriodProbe.parseHex("—") == nil && NotifyPeriodProbe.parseHex("（空）") == nil
           && NotifyPeriodProbe.parseHex("ABC") == nil && NotifyPeriodProbe.parseHex("") == nil
           && NotifyPeriodProbe.parseHex("订阅失败：x") == nil,
           "P2 FFA2 观察：十六进制解析，「—」「（空）」「订阅失败」不算")
    var periodic = NotifyPeriodProbe()
    var counter = NotifyPeriodProbe()
    var constant = NotifyPeriodProbe()
    var few = NotifyPeriodProbe()
    for k in 0..<150 {
        let t = 50 + Double(k) * 0.1
        let pos = UInt8(128 + 90 * sin(2 * Double.pi * 1.2 * t))
        periodic.add(time: t, hex: String(format: "AA%02X%02X00", 7, pos))
        counter.add(time: t, hex: String(format: "AA%02X", UInt8(k % 256)))
        constant.add(time: t, hex: "AA0100")
        if k < 5 { few.add(time: t, hex: String(format: "AA%02X", k)) }
    }
    let pr = periodic.report(now: 65)
    let cr = counter.report(now: 65)
    let kr = constant.report(now: 65)
    let fr = few.report(now: 50.5)
    vcheck(pr.periodicByte == 2 && abs(pr.periodicHz - 1.2) <= 0.06 && pr.periodicQuality >= 0.9 && pr.changingBytes == [2]
           && abs(pr.rate - 10) < 0.1 && cr.counterByte == 1 && abs(cr.counterRate - 10) <= 0.5
           && kr.changingBytes.isEmpty && kr.distinct == 1 && kr.periodicByte == nil && kr.counterByte == nil
           && NotifyPeriodProbe.summary(kr).contains("一直不变") && NotifyPeriodProbe.summary(fr).contains("太少")
           && NotifyPeriodProbe.summary(pr).contains("1.2") && NotifyPeriodProbe.summary(NotifyPeriodProbe.Report()).contains("没有收到"),
           "P2 FFA2 观察：1.2 Hz 周期变化的字节认出来（\(String(format: "%.2f", pr.periodicHz)) Hz）、计数器认出来、"
           + "不变 / 太少各有说明")
    var back = NotifyPeriodProbe()
    back.add(time: 10, hex: "AA01")
    back.add(time: 11, hex: "AA02")
    back.add(time: 5, hex: "AA03")
    var old = NotifyPeriodProbe()
    for k in 0..<500 { old.add(time: Double(k) * 0.02, hex: "AA01") }
    vcheck(back.times == [5] && old.times.count <= NotifyPeriodProbe.capacity && old.report(now: 100).samples == 0,
           "P2 FFA2 观察：时间倒退重来、最多存 400 条、超过 20 秒的不算")
}

// MARK: - rhythm-context P3：动作识别（手 / 头 / 髋 + 周期区域 + 撞击声相位校正，默认关）+ P2 L1–L3

do {
    // L2：带 now 的出口入口，从来没按时间限速过时和 dfbfc8e 的基准副本逐位相同（随机设置 / 目标 / 间隔 / reset / seed）
    var same = true
    var steps = 0
    for _ in 0..<200 {
        var stage = SyncOutputStage()
        var base = BaseSyncOutputStageP1()
        var now = 100 + vsRandom() * 50
        for _ in 0..<60 {
            let s = p2Settings()
            now += vsRandom() < 0.1 ? vsRandom() * 3 : 0.05 + vsRandom() * 0.5
            let r = vsRandom()
            if r < 0.04 {
                stage.reset()
                base.reset()
            } else if r < 0.07 {
                let lv = p2Levels()
                stage.seed(lv)
                base.seed(lv)
            } else if r < 0.5 {
                let v = vsRandom() < 0.05 ? Double.nan : vsRandom() * 120 - 10
                let sig = vsRandom() < 0.7
                same = same && stage.step(v, settings: s, hasSignal: sig, now: now) == base.step(v, settings: s, hasSignal: sig)
            } else {
                let lv = p2Levels()
                same = same && stage.step(levels: lv, settings: s, now: now, timed: false) == base.step(levels: lv, settings: s)
            }
            steps += 1
        }
        same = same && !stage.pendingTimed
    }
    vcheck(same, "P3 L2：带 now 的出口在没按时间限速过时和 P1 出口逐位相同（\(steps) 步随机）")

    // L2：按时间限速（子拍）→ 按拍的路径交替：任意两刻升幅 ≤ 20 × 间隔 / 0.3 + 1；间隔满 0.3 秒后交回按拍
    var sim = P2Sim()
    var stage = SyncOutputStage()
    var t = 50.0
    var released = false
    for k in 0..<400 {
        let st = AudioSyncSettings(enabled: true, maxPercent: 100, channels: .both)
        let target = [k % 7 == 0 ? 0 : 30 + Int(vsRandom() * 70), 20 + Int(vsRandom() * 80), 0, 0]
        let o: [Int]
        let mode = Int(vsRandom() * 4)
        // 按拍的路径（没在按时间限速时）本来就是 0.3 秒一次（P1 的节拍）；按时间限速中才会 0.1 秒后来一次按拍
        let legacy = (mode == 1 || mode == 2) && !stage.pendingTimed
        t += mode == 3 || legacy ? 0.3 : 0.1 + (vsRandom() - 0.5) * 0.02
        switch mode {
        case 0: o = stage.step(levels: target, settings: st, now: t, timed: true)
        case 1: o = stage.step(levels: target, settings: st, now: t, timed: false)
        case 2: o = stage.step(vsRandom() * 100, settings: st, hasSignal: true, now: t)
        default:
            let wasPending = stage.pendingTimed
            o = stage.step(levels: target, settings: st, now: t, timed: false)
            if wasPending && !stage.pendingTimed { released = true }
        }
        sim.times.append(t)
        sim.outs.append(o)
    }
    let env = p2Envelope(sim, cap: 100)
    // P2 时的问题：子拍后 0.1 秒的按拍出口还按「一拍」给 +20
    var old = SyncOutputStage()
    _ = old.step(levels: [0, 0, 0, 0], settings: AudioSyncSettings(maxPercent: 100), now: 10, timed: false)
    _ = old.step(levels: [0, 0, 0, 0], settings: AudioSyncSettings(maxPercent: 100), now: 10.3, timed: false)
    _ = old.step(levels: [0, 0, 0, 0], settings: AudioSyncSettings(maxPercent: 100), now: 10.6, timed: false)
    let a = old.step(levels: [60, 60, 0, 0], settings: AudioSyncSettings(maxPercent: 100), now: 10.7, timed: true)
    let b = old.step(levels: [60, 60, 0, 0], settings: AudioSyncSettings(maxPercent: 100), now: 10.8, timed: false)
    let c = old.step(levels: [60, 60, 0, 0], settings: AudioSyncSettings(maxPercent: 100), now: 11.1, timed: false)
    vcheck(env.ok && released && a[0] <= 7 && b[0] - a[0] <= 7 && c[0] - b[0] <= 20 && !old.pendingTimed,
           "P3 L2：子拍 / 完整拍 / 交接追赶混着走，任意两刻升幅包络不破（余量 \(String(format: "%.2f", env.margin))）；"
           + "子拍后 0.1 秒的完整拍只给 +\(b[0] - a[0])，满 0.3 秒交回按拍")
}

do {
    // L3：Timer 系统性偏慢 / 偏快时完整拍仍按 0.3 秒网格，平均间隔不被拖长
    func meanGap(_ step: Double, jitter: Double = 0) -> (mean: Double, min: Double, max: Double) {
        var d = RhythmPulseDriver()
        var t = 0.0
        var last: Double?
        var gaps: [Double] = []
        for _ in 0..<600 {
            t += step + (vsRandom() - 0.5) * 2 * jitter
            if d.takesFullBeat(at: t) {
                if let l = last { gaps.append(t - l) }
                last = t
            }
        }
        return (gaps.reduce(0, +) / Double(max(1, gaps.count)), gaps.min() ?? 0, gaps.max() ?? 0)
    }
    let slow = meanGap(0.112)
    let fast = meanGap(0.095)
    let noisy = meanGap(0.1, jitter: 0.03)
    vcheck(abs(slow.mean - 0.3) <= 0.01 && abs(fast.mean - 0.3) <= 0.01 && abs(noisy.mean - 0.3) <= 0.012
           && slow.min >= RhythmPulseDriver.minFullBeatGap - 1e-9 && noisy.min >= RhythmPulseDriver.minFullBeatGap - 1e-9
           && slow.max <= 0.45 && noisy.max <= 0.45,
           "P3 L3：Timer 每次 112 / 95 ms / 抖 ±30 ms 时完整拍平均间隔 \(String(format: "%.3f / %.3f / %.3f", slow.mean, fast.mean, noisy.mean)) 秒"
           + "（P2 会被拖到约 0.336 秒），最短 \(String(format: "%.2f", min(slow.min, noisy.min))) 秒")
}

do {
    // L1：相位拟合只在开着时算；关着时相位无效，其余读数逐位相同
    var on = MotionAnalyzer()
    on.phaseFitEnabled = true
    var off = MotionAnalyzer()
    let scene = VS3Scene(rect: vs3Mid, hz: 1, peak: 4)
    var same = true
    var phases = 0
    var offPhases = 0
    for k in 0..<150 {
        let f = scene.frame(k)
        let a = on.analyze(f, time: Double(k) * vsDt)
        let b = off.analyze(f, time: Double(k) * vsDt)
        if let x = a, x.subject.phase.isValid { phases += 1 }
        if let y = b, y.subject.phase.isValid { offPhases += 1 }
        var x = a
        x?.subject.phase = StrokeRhythm.PhaseFit()
        same = same && x == b
    }
    var pOn = PoseMotionTracker()
    pOn.phaseFitEnabled = true
    var pOff = PoseMotionTracker()
    var poseSame = true
    var posePhases = 0
    for i in 0..<120 {
        let t = Double(i) / 9
        let c = [vs3Skeleton(hipX: vs3HipWave(t))]
        var a = pOn.update(time: t, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
        let b = pOff.update(time: t, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
        if a.rhythmPhase.isValid { posePhases += 1 }
        poseSame = poseSame && !b.rhythmPhase.isValid
        a.rhythmPhase = StrokeRhythm.PhaseFit()
        poseSame = poseSame && a == b
    }
    vcheck(same && poseSame && phases > 50 && posePhases > 40 && offPhases == 0 && !MotionAnalyzer().phaseFitEnabled
           && !PoseMotionTracker().phaseFitEnabled,
           "P3 L1：相位拟合默认关；关着时块运动 / 姿态都不算相位（开着时 \(phases) / \(posePhases) 次有相位），其余读数逐位相同")
}

do {
    // 设置：默认关、键名、读回、只有对应的上级开关都开才生效
    let d = VisualSyncSettings()
    let keys = [VisualSyncSettings.Keys.rhythmContext, VisualSyncSettings.Keys.rhythmAudioAnchor]
    let suite = "bc.visualsync.p3checks"
    let ud = UserDefaults(suiteName: suite)!
    ud.removePersistentDomain(forName: suite)
    let fresh = VisualSyncSettings.load(from: ud)
    ud.set(true, forKey: VisualSyncSettings.Keys.rhythmContext)
    ud.set(true, forKey: VisualSyncSettings.Keys.rhythmAudioAnchor)
    let stored = VisualSyncSettings.load(from: ud)
    ud.set("x", forKey: VisualSyncSettings.Keys.rhythmContext)
    let bad = VisualSyncSettings.load(from: ud)
    ud.removePersistentDomain(forName: suite)
    let all = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true, rhythmContext: true,
                                 rhythmAudioAnchor: true)
    var noFollow = all
    noFollow.rhythmFollow = false
    var noPulse = all
    noPulse.rhythmPulse = false
    var audio = all
    audio.source = .audio
    vcheck(!d.rhythmContext && !d.rhythmAudioAnchor && !d.usesRhythmContext && !d.usesAudioAnchor
           && keys.allSatisfy { !$0.contains(".") && $0.hasPrefix("bcVisualSync") } && Set(keys).count == 2
           && !fresh.rhythmContext && !fresh.rhythmAudioAnchor && stored.rhythmContext && stored.rhythmAudioAnchor
           && !bad.rhythmContext && all.usesRhythmContext && all.usesAudioAnchor
           && !noFollow.usesRhythmContext && !noFollow.usesAudioAnchor && noPulse.usesRhythmContext && !noPulse.usesAudioAnchor
           && !audio.usesRhythmContext && !audio.usesAudioAnchor,
           "P3 设置：动作识别 / 撞击声校正默认关，键名不带点；动作识别要跟随画面 + 频率跟随，撞击声校正还要相位脉动")
}

do {
    // 动作识别关着：分析器不攒周期区域、窗口里没有区域 / 上下文；开着时分析器其余输出逐位相同；
    // 窗口里没有上下文时 ActionContext 不改窗口（= P2）
    var plain = MotionAnalyzer()
    var ctx = MotionAnalyzer()
    ctx.contextEnabled = true
    let scene = VS3Scene(rect: vs3Small, hz: 1.2, peak: 3)
    var same = true
    var roiSeen = false
    var accOff = MotionWindowAccumulator()
    var windowsEmpty = true
    for k in 0..<150 {
        let f = scene.frame(k)
        let a = plain.analyze(f, time: Double(k) * vsDt)
        let b = ctx.analyze(f, time: Double(k) * vsDt)
        same = same && a == b
        if ctx.periodicity.roi.valid { roiSeen = true }
        if let s = a { accOff.add(s) }
        if k % 5 == 4 {
            let w = accOff.drain()
            windowsEmpty = windowsEmpty && w.roi == RoiReading() && w.roiFrames == 0 && w.context == PoseContext()
        }
    }
    var identity = true
    var ac = ActionContext()
    for (i, w) in rf1Hz.windows.enumerated() {
        identity = identity && ac.refine(w, now: Double(i * 5 + 4) * vsDt + 0.01) == w
    }
    for (i, w) in vs3Strong20.windows.enumerated() {
        identity = identity && ac.refine(w, now: Double(i * 5 + 4) * vsDt + 0.01) == w
    }
    var flipOff = ctx
    flipOff.contextEnabled = false
    vcheck(same && roiSeen && !plain.periodicity.roi.valid && windowsEmpty && identity && ac.kind == .unknown
           && !ac.directionKnown && !flipOff.periodicity.roi.valid && !MotionAnalyzer().contextEnabled,
           "P3 关着 = P2：分析器默认不算周期区域、开着时其余读数逐位相同；没有上下文的窗口 ActionContext 原样返回")
}

/// 两块区域：左边一块按 hz 水平往复（周期），右边一块随机游走（不周期）；背景静止
func p3TwoBlobs(_ k: Int, hz: Double, periodicLeft: Bool = true) -> LumaFrame {
    let t = Double(k) * vsDt
    let ox = 3 * sin(2 * Double.pi * hz * t)
    var walk = 0.0
    for j in 0...k { walk += (vs3Hash(j, 7, 9) - 0.5) * 2.4 }
    walk = max(-5, min(5, walk.truncatingRemainder(dividingBy: 10)))
    let pr = periodicLeft ? (x: 6.0, y: 10.0) : (x: 42.0, y: 10.0)
    let dr = periodicLeft ? (x: 42.0, y: 12.0) : (x: 6.0, y: 12.0)
    var px = [UInt8](repeating: 0, count: 64 * 36)
    for y in 0..<36 {
        for x in 0..<64 {
            let qx = Double(x) + 0.5
            let qy = Double(y) + 0.5
            var v: Double
            if qx >= pr.x + ox, qx < pr.x + ox + 12, qy >= pr.y, qy < pr.y + 12 {
                v = vs3Value(qx - ox + 100, qy + 100, salt: 2)
            } else if qx >= dr.x + walk, qx < dr.x + walk + 12, qy >= dr.y, qy < dr.y + 12 {
                v = vs3Value(qx - walk + 300, qy + 300, salt: 3)
            } else {
                v = vs3Value(qx + 200, qy + 200, salt: 1)
            }
            px[y * 64 + x] = UInt8(min(255, max(0, v.rounded())))
        }
    }
    return LumaFrame(width: 64, height: 36, pixels: px)
}

do {
    // 周期区域：往复的那块被框出来（不框随机游走的干扰块）、只占一小块画面；整幅都在动 / 静止时没有区域
    func run(_ gen: (Int) -> LumaFrame, seconds: Double = 8) -> (roi: PeriodicityROI, validLate: Int, n: Int) {
        var an = MotionAnalyzer()
        an.contextEnabled = true
        var valid = 0
        var n = 0
        let frames = Int(seconds * 15)
        for k in 0..<frames {
            _ = an.analyze(gen(k), time: Double(k) * vsDt)
            if k >= frames / 2 {
                n += 1
                if an.periodicity.roi.valid { valid += 1 }
            }
        }
        return (an.periodicity.roi, valid, n)
    }
    let left = run { p3TwoBlobs($0, hz: 1.2) }
    let right = run { p3TwoBlobs($0, hz: 1.2, periodicLeft: false) }
    let still = run { _ in VS3Scene().frame(0) }
    let big = run { VS3Scene(rect: (x: 1, y: 1, w: 62, h: 34), hz: 1, peak: 3).frame($0) }
    let l = left.roi
    let r = right.roi
    vcheck(l.valid && l.centerX < 0.45 && l.x0 <= 12.0 / 64 && l.x1 >= 12.0 / 64 && l.share > 0.3 && l.blocks <= 16
           && r.valid && r.centerX > 0.55 && left.validLate >= left.n * 3 / 4 && !still.roi.valid && still.validLate == 0
           && !big.roi.valid,
           "P3 周期区域：往复块被框出（左 \(String(format: "%.2f~%.2f", l.x0, l.x1))、右 \(String(format: "%.2f~%.2f", r.x0, r.x1))，"
           + "\(l.blocks) 块），随机游走的干扰块不算；静止 / 整幅都在动时没有区域")
}

do {
    // 裁剪降采样：框内按面积平均、框外不读；同尺寸复用缓冲；缓冲不够 / 尺寸不对返回 false
    let src = vsSource(width: 640, height: 360, padding: 8) { x, y in UInt8((x * 255 / 639 + (y < 180 ? 0 : 0)) & 0xFF) }
    var cropper = LumaCropDownscaler()
    var out = LumaFrame()
    let half = CropRect(x0: 0.5, y0: 0.25, x1: 1, y1: 0.75)
    let ok = src.withUnsafeBytes { cropper.downscale($0, width: 640, height: 360, bytesPerRow: 648, crop: half,
                                                     outWidth: 64, outHeight: 36, into: &out) }
    let firstCol = out.pixels.isEmpty ? 0 : Int(out.pixels[0])
    let lastCol = out.pixels.isEmpty ? 0 : Int(out.pixels[63])
    var monotonic = out.pixels.count == 64 * 36
    if monotonic { for x in 1..<64 { monotonic = monotonic && out.pixels[x] >= out.pixels[x - 1] } }
    var rowsSame = monotonic
    if rowsSame { for y in 1..<36 { rowsSame = rowsSame && Array(out.pixels[(y * 64)..<(y * 64 + 64)]) == Array(out.pixels[0..<64]) } }
    let addr = out.pixels.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
    let ok2 = src.withUnsafeBytes { cropper.downscale($0, width: 640, height: 360, bytesPerRow: 648, crop: half,
                                                      outWidth: 64, outHeight: 36, into: &out) }
    let addr2 = out.pixels.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
    let short = [UInt8](repeating: 0, count: 1000)
    let bad = short.withUnsafeBytes { cropper.downscale($0, width: 640, height: 360, bytesPerRow: 648, crop: half,
                                                        outWidth: 64, outHeight: 36, into: &out) }
    let span = LumaCropDownscaler.span(0.2, 0.1, size: 100)
    let empty = LumaCropDownscaler.span(0.5, 0.5, size: 100)
    let nanSpan = LumaCropDownscaler.span(.nan, 1, size: 100)
    vcheck(ok && ok2 && !bad && abs(firstCol - 128) <= 3 && lastCol >= 250 && monotonic && rowsSame && addr == addr2
           && span == (10, 10) && empty.length == 1 && nanSpan == (0, 100),
           "P3 裁剪降采样：右半幅放大到 64×36（\(firstCol)~\(lastCol)，单调、各行相同），稳态不重新分配，缓冲不够返回 false")
}

do {
    // 放大框：区域 → 同宽高比、放大 1.5~4 倍、不出画面；小变化不挪框，大变化 1 秒后才挪；区域没了 1 秒后不跟
    func roi(_ cx: Double, _ cy: Double, _ size: Double, time: Double = 0) -> PeriodicityROI {
        var r = PeriodicityROI()
        r.valid = true
        r.time = time
        r.hz = 1.2
        r.x0 = cx - size / 2
        r.x1 = cx + size / 2
        r.y0 = cy - size / 2
        r.y1 = cy + size / 2
        r.blocks = 4
        return r
    }
    let small = RoiFlowTracker.desiredCrop(roi(0.5, 0.5, 0.1))
    let edge = RoiFlowTracker.desiredCrop(roi(0.95, 0.05, 0.2))
    let tooBig = RoiFlowTracker.desiredCrop(roi(0.5, 0.5, 0.6))
    var tr = RoiFlowTracker()
    let c0 = tr.plan(roi(0.3, 0.4, 0.15), now: 10)
    let c1 = tr.plan(roi(0.32, 0.41, 0.15), now: 10.5)
    let c2 = tr.plan(roi(0.7, 0.6, 0.15), now: 10.6)
    let c3 = tr.plan(roi(0.7, 0.6, 0.15), now: 11.1)
    let c4 = tr.plan(PeriodicityROI(), now: 11.5)
    let c5 = tr.plan(PeriodicityROI(), now: 12.2)
    let e = edge?.0
    vcheck(small?.1 == RoiFlowTracker.maxZoom && abs((small?.0.width ?? 0) - 0.25) < 1e-9
           && e.map { $0.x1 <= 1 + 1e-9 && $0.y0 >= -1e-9 && abs($0.width - $0.height) < 1e-9 } == true
           && tooBig == nil && c0 != nil && c1 == c0 && c2 == c0 && c3 != c0 && (c3?.x0 ?? 0) > 0.5
           && c4 == c3 && c5 == nil,
           "P3 放大框：放大 \(String(format: "%.1f", small?.1 ?? 0)) 倍、贴边不出画面、区域太大不放大；"
           + "小变化不挪、大变化 1 秒后才挪、区域没了 1 秒后不跟")

    // 放大后的块运动：裁剪小图里的往复 → 频率对得上，速度 / 幅度换回分析帧像素（÷ 放大倍数）
    var rt = RoiFlowTracker()
    _ = rt.plan(roi(0.5, 0.5, 0.12), now: 0)
    let zoom = 1 / (rt.plan(roi(0.5, 0.5, 0.12), now: 0)?.width ?? 1)
    let scene = VS3Scene(rect: (x: 12, y: 6, w: 40, h: 24), hz: 1.5, peak: 3)
    var reading = RoiReading()
    var hzLate: [Double] = []
    var bigAmp = 0.0
    for k in 0..<150 {
        let t = Double(k) * vsDt
        reading = rt.update(time: t, frame: scene.frame(k), camera: .identity, cameraContinuous: true,
                            analysisWidth: 64, analysisHeight: 36)
        if k >= 90, reading.valid, reading.subject.followHz > 0 { hzLate.append(reading.subject.followHz) }
        bigAmp = max(bigAmp, reading.subject.followAmplitude)
    }
    var full = MotionAnalyzer()
    var fullAmp = 0.0
    for k in 0..<150 {
        if let s = full.analyze(scene.frame(k), time: Double(k) * vsDt) { fullAmp = max(fullAmp, s.subject.followAmplitude) }
    }
    let meanHz = hzLate.isEmpty ? 0 : hzLate.reduce(0, +) / Double(hzLate.count)
    var cutTr = rt
    cutTr.noteCut()
    let afterCut = cutTr.update(time: 10.1, frame: scene.frame(151), camera: .identity, cameraContinuous: true,
                                analysisWidth: 64, analysisHeight: 36)
    vcheck(zoom > 3.9 && hzLate.count >= 40 && abs(meanHz - 1.5) <= 0.08 && reading.valid && reading.zoom > 3.9
           && fullAmp > 0 && abs(bigAmp * zoom / fullAmp - 1) < 0.35 && !afterCut.valid,
           "P3 放大跟踪：裁剪小图里 1.5 Hz 往复读出 \(String(format: "%.2f", meanHz)) Hz、"
           + "幅度换回分析帧后是整幅的 \(String(format: "%.2f", fullAmp > 0 ? bigAmp * zoom / fullAmp : 0)) 倍（÷ 放大 \(String(format: "%.1f", zoom))）；切镜后重新攒")
}

do {
    // 手 / 脸跟踪：9 Hz 检测、1.5 Hz 往复 → 频率对得上；镜头同时平移（给了相机运动）照样对；
    // 另一个更大的手不抢（连续性优先）；相位只在开着时算；低置信度 / 空帧不出读数
    func run(pan: Bool, phase: Bool, distractor: Bool = false) -> (hz: Double, conf: Double, phaseOK: Bool, x: Double) {
        var tr = PartMotionTracker()
        tr.phaseFitEnabled = phase
        var r = PartReading()
        var hzs: [Double] = []
        var phaseOK = true
        var lastPan = 0.0
        for i in 0..<120 {
            let t = Double(i) / 9 + (i % 3 == 1 ? 0.01 : 0)
            let p = pan ? 12 * sin(2 * Double.pi * 0.7 * t) + 3 * t : 0
            var c = [PartCandidate(x: 20 + 4 * sin(2 * Double.pi * 1.5 * t) + p, y: 18, size: 8, confidence: 0.8)]
            if distractor, i >= 30 { c.append(PartCandidate(x: 50, y: 10 + 3 * sin(2 * Double.pi * 0.6 * t), size: 14, confidence: 0.9)) }
            let cam = CameraTransform(t0: p - lastPan)
            lastPan = p
            r = tr.update(time: t, candidates: c, camera: cam, continuous: true)
            if i >= 60, r.present, r.rhythm.follow.hz > 0 { hzs.append(r.rhythm.follow.hz) }
            if i >= 60 { phaseOK = phaseOK && (phase ? r.rhythm.phase.isValid : !r.rhythm.phase.isValid) }
        }
        return (hzs.isEmpty ? 0 : hzs.reduce(0, +) / Double(hzs.count), r.rhythm.follow.confidence, phaseOK && hzs.count >= 50, r.x)
    }
    let still = run(pan: false, phase: true)
    let panned = run(pan: true, phase: false)
    let busy = run(pan: false, phase: false, distractor: true)
    var low = PartMotionTracker()
    let lowR = low.update(time: 1, candidates: [PartCandidate(x: 1, y: 1, size: 5, confidence: 0.2)], camera: .identity,
                          continuous: true)
    let none = low.update(time: 1.1, candidates: [], camera: .identity, continuous: true)
    vcheck(abs(still.hz - 1.5) <= 0.08 && abs(panned.hz - 1.5) <= 0.08 && abs(busy.hz - 1.5) <= 0.08 && busy.x < 30
           && still.conf >= 0.5 && still.phaseOK && panned.phaseOK && !lowR.present && !none.present,
           "P3 手 / 脸跟踪：1.5 Hz 往复读出 \(String(format: "%.2f", still.hz)) Hz，镜头平移时 \(String(format: "%.2f", panned.hz)) Hz，"
           + "旁边更大的手不抢；相位只在开着时算")
}

do {
    // 窗口：区域读数 / 上下文跟着样本走；切镜清掉、切镜前的上下文不认；取走后清零
    var acc = MotionWindowAccumulator()
    var s = MotionSample(time: 1, energy: 2, coverage: 0.1, isCut: false, isHeld: false)
    s.roi = RoiReading(valid: true, time: 1, zoom: 2)
    acc.add(s)
    var ctx = PoseContext()
    ctx.valid = true
    ctx.time = 1.02
    acc.addContext(ctx)
    let w1 = acc.drain()
    let w2 = acc.drain()
    acc.add(s)
    acc.addContext(ctx)
    acc.add(MotionSample(time: 1.1, energy: 2, coverage: 0.1, isCut: true, isHeld: false))
    var late = ctx
    late.time = 1.05
    acc.addContext(late)
    var held = s
    held.isHeld = true
    held.time = 1.15
    acc.add(held)
    let w3 = acc.drain()
    vcheck(w1.roiFrames == 1 && w1.roi.zoom == 2 && w1.context.valid && w2.roiFrames == 0 && !w2.context.valid
           && w3.roiFrames == 0 && !w3.roi.valid && !w3.context.valid,
           "P3 窗口：区域读数 / 手脸身体上下文跟着样本走；切镜清掉、切镜前算出来的不认、保持期不带；取走后清零")
}

/// 一拍的窗口 + 上下文：手 / 脸 / 髋的节奏（hz、置信度、幅度），位置（分析帧像素，64×36）
func p3Window(time: Double, hand: (hz: Double, conf: Double, amp: Double)? = nil,
              face: (hz: Double, conf: Double, amp: Double)? = nil, hips: (hz: Double, conf: Double, amp: Double)? = nil,
              subjectHz: Double = 1.5, handAt: (Double, Double) = (30, 22), faceAt: (Double, Double) = (30, 10),
              axis: (Double, Double) = (0, 1), otherHip: (Double, Double)? = nil, cut: Bool = false,
              roi: PeriodicityROI? = nil) -> MotionWindow {
    var w = plWindow(time: time - 0.03, hz: subjectHz, cut: cut)
    w.subjectFollowHz = subjectHz
    w.subjectFollowRhythm = 0.7
    w.subjectFollowAmplitude = 3
    w.subjectPhase.axisX = axis.0
    w.subjectPhase.axisY = axis.1
    var c = PoseContext()
    c.valid = true
    c.time = time - 0.05
    c.frameWidth = 64
    c.frameHeight = 36
    func rhythm(_ r: (hz: Double, conf: Double, amp: Double)) -> PartRhythm {
        var p = PartRhythm()
        p.follow = StrokeRhythm.FollowEstimate(hz: r.hz, confidence: r.conf, amplitude: r.amp, sampleRate: 9)
        p.phase = StrokeRhythm.PhaseFit(time: time - 0.05, phase: 0.5, hz: r.hz, quality: 0.9, linearity: 0.95,
                                        amplitude: r.amp, epoch: 0)
        p.phase.axisX = axis.0
        p.phase.axisY = axis.1
        return p
    }
    if let h = hand {
        c.hand = PartReading(present: true, time: c.time, x: handAt.0, y: handAt.1, size: 6, confidence: 0.8, rhythm: rhythm(h))
    }
    if let f = face {
        c.face = PartReading(present: true, time: c.time, x: faceAt.0, y: faceAt.1, size: 6, confidence: 0.8, rhythm: rhythm(f))
    }
    c.body.present = true
    c.body.time = c.time
    c.body.scale = 16
    c.body.hasHip = true
    c.body.hipX = 32
    c.body.hipY = 20
    c.body.hasHead = true
    c.body.headX = 32
    c.body.headY = 7
    if let hp = hips { c.body.hips = rhythm(hp) }
    if let o = otherHip {
        c.body.hasOtherHip = true
        c.body.otherHipX = o.0
        c.body.otherHipY = o.1
        c.body.otherScale = 16
    }
    w.context = c
    if let r = roi {
        w.roi.region = r
    }
    return w
}

do {
    // 动作识别：手在和画面同频地往复、髋几乎不动 → 撸动（看手）；髋同频往复、手 / 脸不动 → 插入（看髋）；
    // 脸同频往复 → 口交（看脸）。改判要连续 0.9 秒；一拍不一样不改；切镜立刻回未知；依据没了 1.5 秒回未知
    func settle(_ make: (Double) -> MotionWindow, from: Double = 10, seconds: Double = 2.4) -> (ActionContext, MotionWindow) {
        var ac = ActionContext()
        var t = from
        var out = MotionWindow()
        while t < from + seconds {
            out = ac.refine(make(t), now: t)
            t += 0.3
        }
        return (ac, out)
    }
    let stroke = settle { p3Window(time: $0, hand: (1.5, 0.8, 0.3), hips: (1.5, 0.5, 0.05)) }
    let insert = settle { p3Window(time: $0, hips: (1.5, 0.8, 0.3)) }
    let oral = settle { p3Window(time: $0, face: (1.5, 0.8, 0.3), faceAt: (32, 26)) }
    let offFreq = settle { p3Window(time: $0, hand: (0.7, 0.8, 0.3)) }
    // 刚满足 0.6 秒还不改；一拍插入不改判
    var ac = ActionContext()
    var kinds: [ActionContext.Kind] = []
    for i in 0..<12 {
        let t = 10 + Double(i) * 0.3
        let w = i == 7 ? p3Window(time: t, hips: (1.5, 0.8, 0.3)) : p3Window(time: t, hand: (1.5, 0.8, 0.3))
        _ = ac.refine(w, now: t)
        kinds.append(ac.kind)
    }
    var cutAc = stroke.0
    _ = cutAc.refine(p3Window(time: 12.5, hand: (1.5, 0.8, 0.3), cut: true), now: 12.5)
    var gone = stroke.0
    var goneKinds: [ActionContext.Kind] = []
    for i in 1...7 {
        let t = 12.4 + Double(i) * 0.3
        _ = gone.refine(p3Window(time: t), now: t)
        goneKinds.append(gone.kind)
    }
    vcheck(stroke.0.kind == .stroke && stroke.1.poseRhythmPart == 3 && abs(stroke.1.poseRhythmHz - 1.5) < 1e-9
           && insert.0.kind == .insertion && insert.1.poseRhythmPart == 1
           && oral.0.kind == .oral && oral.1.poseRhythmPart == 2 && oral.0.statusText().contains("脸")
           && offFreq.0.kind == .unknown && offFreq.1.poseRhythmHz == p3Window(time: 12.1, hand: (0.7, 0.8, 0.3)).poseRhythmHz
           && kinds[1] == .unknown && kinds[2] == .unknown && kinds[3] == .stroke && kinds[8...].allSatisfy { $0 == .stroke }
           && cutAc.kind == .unknown && goneKinds.first == .stroke && goneKinds.last == .unknown,
           "P3 动作识别：手 / 髋 / 脸同频往复分别认成撸动 / 插入 / 口交，用那个部位的节奏；频率对不上不认；"
           + "0.9 秒才改判、一拍不一样不改；切镜立刻回未知、依据没了 1.5 秒回未知")

    // 方向：手往复的主轴朝着髋 = 往里，相位不翻；主轴背着髋 → 翻 180°（主轴也反过来）；判断不了时不改
    let toward = settle { p3Window(time: $0, hand: (1.5, 0.8, 0.3), handAt: (32, 8), axis: (0, 1)) }
    let away = settle { p3Window(time: $0, hand: (1.5, 0.8, 0.3), handAt: (32, 8), axis: (0, -1)) }
    let side = settle { p3Window(time: $0, hand: (1.5, 0.8, 0.3), handAt: (32, 8), axis: (1, 0)) }
    let src = p3Window(time: 12.1, hand: (1.5, 0.8, 0.3), handAt: (32, 8), axis: (0, -1))
    vcheck(toward.0.directionKnown && abs(toward.1.posePhase.phase - 0.5) < 1e-9 && abs(toward.1.subjectPhase.phase - src.subjectPhase.phase) < 1e-9
           && away.0.directionKnown && abs(StrokeRhythm.wrapPhase(away.1.posePhase.phase - 0.5 - Double.pi)) < 1e-9
           && away.1.posePhase.axisY > 0
           && abs(StrokeRhythm.wrapPhase(away.1.subjectPhase.phase - src.subjectPhase.phase - Double.pi)) < 1e-9
           && !side.0.directionKnown && abs(side.1.posePhase.phase - 0.5) < 1e-9,
           "P3 动作方向：主轴朝着髋 = 往里（不翻），背着髋 → 相位翻 180°，和往里垂直时判断不了（不改）")
}

/// 48 kHz 合成声音：clicks 时刻（秒）各一个 15 ms 衰减的宽带撞击 + 背景（noise 幅度的白噪声 + hum 幅度的 120 Hz）
func p3Audio(seconds: Double, clicks: [Double], noise: Double = 0.01, hum: Double = 0, rate: Double = 48_000,
             start: Double = 0) -> [AudioBandFrame] {
    var sp = AudioBandSplitter()
    sp.configure(sampleRate: rate)
    var out: [AudioBandFrame] = []
    let n = Int(seconds * rate)
    var ci = 0
    var seed: UInt64 = 0xC0FFEE
    func rnd() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53) - 0.5
    }
    let chunk = 1024
    var i = 0
    while i < n {
        let m = min(chunk, n - i)
        sp.begin(start: start + Double(i) / rate, frames: m)
        for j in 0..<m {
            let t = Double(i + j) / rate
            while ci + 1 < clicks.count, clicks[ci + 1] <= t { ci += 1 }
            var x = noise * rnd() * 2 + hum * sin(2 * Double.pi * 120 * t)
            if ci < clicks.count, t >= clicks[ci], t - clicks[ci] < 0.06 {
                x += 0.8 * exp(-(t - clicks[ci]) / 0.015) * rnd() * 2
            }
            if let f = sp.add(x, at: start + t) { out.append(f) }
        }
        i += m
    }
    return out
}

do {
    // 频带分离：10 毫秒一块、时间是块中点；低频哼声进低频带、白噪声主要在高频带；采样率认不出不出块；接不上的回调丢掉半块
    let hum = p3Audio(seconds: 1, clicks: [], noise: 0, hum: 0.5)
    let hiss = p3Audio(seconds: 1, clicks: [], noise: 0.3)
    var bad = AudioBandSplitter()
    bad.configure(sampleRate: 500)
    bad.begin(start: 0, frames: 100)
    var none = 0
    for k in 0..<1000 { if bad.add(0.5, at: Double(k) / 500) != nil { none += 1 } }
    var sk = AudioBandSplitter()
    sk.configure(sampleRate: 48_000)
    sk.begin(start: 0, frames: 240)
    for k in 0..<240 { _ = sk.add(0.1, at: Double(k) / 48_000) }
    sk.begin(start: 5, frames: 480)
    var firstAfterSkip: AudioBandFrame?
    for k in 0..<480 where firstAfterSkip == nil { firstAfterSkip = sk.add(0.1, at: 5 + Double(k) / 48_000) }
    let humLate = hum.suffix(50)
    let hissLate = hiss.suffix(50)
    let humLow = humLate.map { Double($0.low) }.reduce(0, +)
    let humHigh = humLate.map { Double($0.high) + Double($0.mid) }.reduce(0, +)
    let hissHigh = hissLate.map { Double($0.high) }.reduce(0, +)
    let hissLow = hissLate.map { Double($0.low) }.reduce(0, +)
    vcheck(hum.count == 100 && abs(hum[0].time - 0.005) < 1e-6 && humLow > 2 * humHigh && hissHigh > 5 * hissLow
           && none == 0 && firstAfterSkip.map { abs($0.time - 5.005) < 1e-6 } == true,
           "P3 撞击声频带：10 毫秒一块（时间是块中点）、哼声进低频带、白噪声主要在高频带；采样率不对不出块；seek 后丢掉半块")
}

do {
    // 撞击检测：1.6 Hz 的撞击（有背景噪声）→ 时刻误差 ≤ 20 ms、声音节奏 1.6 Hz；
    // 稳定的白噪声 / 哼声没有撞击；时间倒退重来
    let clicks = (0..<14).map { 0.3 + Double($0) / 1.6 + (vsRandom() - 0.5) * 0.02 }
    let frames = p3Audio(seconds: 9, clicks: clicks, noise: 0.02)
    var det = AudioOnsetDetector()
    for f in frames { det.add(f) }
    let found = det.onsets(since: 0)
    var worst = 0.0
    var matched = 0
    for c in clicks where c > 0.5 {
        if let best = found.min(by: { abs($0 - c) < abs($1 - c) }), abs(best - c) <= 0.03 {
            matched += 1
            worst = max(worst, abs(best - c))
        }
    }
    let rhythm = det.rhythm()
    var quiet = AudioOnsetDetector()
    for f in p3Audio(seconds: 6, clicks: [], noise: 0.05, hum: 0.2) { quiet.add(f) }
    var back = det
    back.add(AudioBandFrame(time: 1, low: 0.1, mid: 0.1, high: 0.1))
    vcheck(matched >= 12 && found.count <= 15 && worst <= 0.02 && abs(rhythm.hz - 1.6) <= 0.08 && rhythm.confidence >= 0.3
           && quiet.onsets(since: 0).count <= 1 && quiet.rhythm().confidence < 0.3 && back.onsets(since: 0).isEmpty,
           "P3 撞击检测：1.6 Hz 撞击认出 \(matched) / 13 次（共 \(found.count) 次，误差 ≤ \(Int((worst * 1000).rounded())) ms）、"
           + "声音节奏 \(String(format: "%.2f", rhythm.hz)) Hz（置信度 \(String(format: "%.2f", rhythm.confidence))）；稳定噪声没有撞击")
}

do {
    // 撞击声相位校正：撞击总在画面相位 μ → 偏移收敛到 −μ（撞击对到最深点）；方向已判断时只到 ±60°；
    // 声音频率和画面差 > 15% / 撞击时刻散乱 / 没锁 → 0（保持 2 秒后慢慢回 0、没锁立刻 0）
    let lock = plLocked(hz: 1, until: 13)
    func onsets(mu: Double, until now: Double, scatter: Bool = false) -> [Double] {
        var out: [Double] = []
        var k = 0
        while true {
            let base = (mu - 0.3) / (2 * Double.pi) + Double(k)
            let t = scatter ? base + vs3Hash(k, 3, 5) : base
            k += 1
            if t > now { break }
            if t >= now - 4.5 { out.append(t) }
            if k > 100 { break }
        }
        return out.sorted()
    }
    func run(mu: Double, audioHz: Double = 1, known: Bool = false, scatter: Bool = false, beats: Int = 30,
             start anchor: AudioPhaseAnchor = AudioPhaseAnchor(), from: Double = 13) -> (AudioPhaseAnchor, Double) {
        var a = anchor
        var off = 0.0
        for i in 0..<beats {
            let now = from + Double(i) * 0.3
            off = a.step(onsets: onsets(mu: mu, until: now, scatter: scatter), audioHz: audioHz, audioConfidence: 0.7,
                         lock: lock, directionKnown: known, now: now, dt: 0.3)
        }
        return (a, off)
    }
    let free = run(mu: 2.0)
    let known = run(mu: 2.0, known: true)
    let small = run(mu: -0.4, known: true)
    let wrongHz = run(mu: 2.0, audioHz: 1.4)
    let scattered = run(mu: 2.0, scatter: true)
    // 对上之后声音没了：2 秒内保持，之后按 2 秒时间常数回 0
    let (held1, _) = run(mu: 2.0, audioHz: 1.4, beats: 5, start: free.0, from: 22)
    let (held2, _) = run(mu: 2.0, audioHz: 1.4, beats: 25, start: free.0, from: 22)
    var unlocked = free.0
    let zero = unlocked.step(onsets: [], audioHz: 1, audioConfidence: 0.7, lock: RhythmPhaseLock(), directionKnown: false,
                             now: 30, dt: 0.3)
    vcheck(abs(free.1 + AudioPhaseAnchor.unknownLimit) < 1e-3 && free.0.active && abs(known.1 + Double.pi / 3) < 1e-3 && abs(small.1 - 0.4) < 0.05
           && wrongHz.1 == 0 && !wrongHz.0.active && scattered.1 == 0 && abs(held1.offset - free.1) < 1e-9
           && abs(held2.offset) < abs(free.1) * 0.35 && zero == 0 && unlocked.offset == 0
           && free.0.statusText(lockHz: 1).contains("已对齐") && wrongHz.0.statusText(lockHz: 1).contains("没听到"),
           "P3 撞击声校正：偏移收敛到 \(String(format: "%.2f", free.1))（撞击在 2.0 rad，方向未判断时限 ±90°）、方向已判断时限 ±60°（\(String(format: "%.2f", known.1))）；"
           + "频率对不上 / 撞击散乱不校正；声音没了 2 秒后慢慢回 0（\(String(format: "%.2f", held2.offset))）、没锁立刻 0")
}

do {
    // 脉动相位偏移：offset = Δ 时和「相位锁本身提前 Δ」逐位相同（只挪时机，出口规则不变）；offset 0 = P2
    func lockAt(_ phase0: Double) -> RhythmPhaseLock {
        var lock = RhythmPhaseLock()
        var now = 10.0
        while now < 13 {
            lock.step(plWindow(time: now - 0.03, hz: 1, phase0: phase0), followerHz: 1, followerLocked: true,
                      followerSource: .flow, now: now, dt: 0.3, active: true)
            now += 0.3
        }
        return lock
    }
    let st = AudioSyncSettings(enabled: true, maxPercent: 100, channels: .both)
    let cal = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: "20:0.6, 60:1.8, 99:2.8", rhythmPulse: true)
    func run(lock: RhythmPhaseLock, offset: Double) -> [[Int]] {
        var d = RhythmPulseDriver()
        d.phaseOffset = offset
        var stage = SyncOutputStage()
        var out: [[Int]] = []
        var t = 13.0
        _ = d.takesFullBeat(at: t)
        for _ in 0..<30 {
            t += 0.1
            if d.takesFullBeat(at: t) {
                out.append(d.beat(levels: [50, 40, 0, 0], lock: lock, visual: cal, settings: st, hasSignal: true, value: 60,
                                  activity: 1, followerWeight: 1, now: t, stage: &stage))
            } else if let o = d.subBeat(lock: lock, settings: st, now: t, stage: &stage) {
                out.append(o)
            }
        }
        return out
    }
    let shifted = run(lock: lockAt(0.3), offset: 1.1)
    let early = run(lock: lockAt(1.4), offset: 0)
    let plain = run(lock: lockAt(0.3), offset: 0)
    let distinct = Set(shifted.map { $0[0] }).count
    vcheck(shifted.count >= 25 && shifted == early && shifted != plain && distinct >= 5
           && shifted.allSatisfy { $0[2] == 0 && $0[3] == 0 } && shifted.suffix(20).allSatisfy { $0[1] == 40 } && RhythmPulseDriver().phaseOffset == 0,
           "P3 脉动相位偏移：偏移 1.1 rad 和相位锁本身提前 1.1 rad 逐位相同（震动不变、通道 3 / 4 恒 0），默认 0 = P2")
}

do {
    // 姿态上下文：开着时给出髋 / 头 / 腕位置和三组节奏，另一个人的髋 / 头也带上；关着时一直是空的
    var on = PoseMotionTracker()
    on.contextEnabled = true
    var off = PoseMotionTracker()
    var sameReading = true
    for i in 0..<90 {
        let t = Double(i) / 9
        let c = [vs3Skeleton(hipX: vs3HipWave(t)), vs3Skeleton(shiftX: 20, confidence: 0.6)]
        let a = on.update(time: t, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
        let b = off.update(time: t, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
        sameReading = sameReading && a == b
    }
    let bc = on.bodyContext
    vcheck(sameReading && bc.present && bc.hasHip && bc.hasHead && bc.hasWrist && abs(bc.headY - 7) < 1e-9
           && abs(bc.hips.follow.hz - 2) <= 0.15 && bc.hasOtherHip && abs(bc.otherHipX - 52) < 1e-9 && bc.hasOtherHead
           && !bc.hips.phase.isValid && off.bodyContext == PoseBodyContext(),
           "P3 姿态上下文：髋 / 头 / 腕位置 + 节奏（髋 \(String(format: "%.2f", bc.hips.follow.hz)) Hz）、另一个人的髋 / 头；"
           + "关着时是空的，姿态读数和关着逐位相同")
}

// MARK: - rhythm-action tune：动作识别调优（真机反馈：慢慢摸胸口 → 强；臀部对着镜头不动 → 强）

/// 92681ea 的 PoseBlend 原样拷贝（常量写死）：调优关着时 PoseBlend / MotionNormalizer 必须和它逐位相同
struct BasePoseBlend92 {
    private(set) var weight: Double = 0
    private(set) var heldScore: Double = 0
    private var heldConfidence: Double = 0
    private var heldTrust: Double = 1
    private var presentRun: TimeInterval = 0
    private var absentRun: TimeInterval = .infinity

    mutating func reset() { self = BasePoseBlend92() }

    mutating func step(_ w: MotionWindow, flow: Double, dt: TimeInterval) -> Double {
        let flow = MotionStats.clamp01(flow)
        if w.posePresentFrames > 0, w.poseScore.isFinite {
            presentRun += dt
            absentRun = 0
            heldScore = MotionStats.clamp01(w.poseScore)
            heldConfidence = MotionStats.clamp01(w.poseConfidence)
            heldTrust = w.poseTrust.isFinite ? MotionStats.clamp01(w.poseTrust) : 0
        } else {
            if w.cutCount > 0 { absentRun = max(absentRun, 0.9) }
            absentRun += dt
            if absentRun > 0.9 { presentRun = 0 }
        }
        let trustFactor = 0.5 + (1 - 0.5) * heldTrust
        let confFactor = (0.5 + 0.5 * MotionStats.clamp01((heldConfidence - 0.3) / 0.3)) * trustFactor
        let target = presentRun >= 0.55 && absentRun <= 0.9 ? 0.8 * confFactor : 0
        let rate = 0.8 / (target > weight ? 1.0 : 1.5)
        if target > weight {
            weight = min(target, weight + rate * dt)
        } else {
            weight = max(target, weight - rate * dt)
        }
        if !weight.isFinite { weight = 0 }
        let blended = weight * heldScore + (1 - weight) * flow
        return MotionStats.clamp01(max(blended, flow * (1 - 0.4 * weight)))
    }
}

/// 92681ea 的 MotionNormalizer 原样拷贝（常量写死）
struct BaseMotionNormalizer92 {
    private(set) var refHigh: Double = log(4.0)
    private(set) var refLow: Double = log(1.8)
    private(set) var warmElapsed: TimeInterval = 0
    private(set) var scoreHigh: Double = 0.7
    private(set) var scoreLow: Double = 0.08
    private(set) var pose = BasePoseBlend92()
    private var idleRun: TimeInterval = 0

    var confidence: Double { min(1, max(0, warmElapsed / 3)) }

    mutating func resetAdaptation() { self = BaseMotionNormalizer92() }

    mutating func step(_ w: MotionWindow, gainDb: Double, auto: Bool, dt: TimeInterval) -> Double {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : 0.3
        guard w.frames > 0 else {
            idleRun += step
            if idleRun > 0.9 { pose.reset() }
            return 0
        }
        idleRun = 0
        warmElapsed = min(3, warmElapsed + step)
        let e = w.representative
        let near = w.nearField.isFinite ? min(1, max(0, w.nearField)) : 0
        let gated = e.isFinite && e >= 0.5
        let l = gated ? log(1 + e) : 0
        if gated, w.settled, near < 0.5, l.isFinite {
            let highTau = l > refHigh ? 2.0 : 25.0
            refHigh += (l - refHigh) * (1 - exp(-step / highTau))
            refHigh = max(log(3.5), refHigh)
            let lowTau = l < refLow ? 1.5 : 20.0
            refLow += (l - refLow) * (1 - exp(-step / lowTau))
            if !refHigh.isFinite || !refLow.isFinite { resetAdaptation() }
        }
        if w.subjectFrames > 0 {
            let flow = MotionStats.clamp01(w.subjectScore)
            var s = pose.step(w, flow: flow, dt: step)
            if near > 0 { s -= near * max(0, s - 0.3) }
            s = MotionStats.clamp01(s)
            if w.settled, near < 0.5 {
                let highTau = s > scoreHigh ? 2.0 : 25.0
                scoreHigh += (s - scoreHigh) * (1 - exp(-step / highTau))
                let lowTau = s < scoreLow ? 1.5 : 20.0
                scoreLow += (s - scoreLow) * (1 - exp(-step / lowTau))
                if !scoreHigh.isFinite || !scoreLow.isFinite {
                    scoreHigh = 0.7
                    scoreLow = 0.08
                }
            }
            var ratio = s
            if auto {
                let base = min(max(0, scoreLow), 0.08)
                ratio = max(0, (s - base) / (1 - base))
                let stretch = min(1.25, max(1, 0.7 / max(scoreHigh, 0.05)))
                ratio *= stretch
            }
            let clampedGain = gainDb.isFinite ? min(12, max(-6, gainDb)) : 0
            let out = ratio * pow(10, clampedGain / 20) * 100
            return out.isFinite ? min(100, max(0, out)) : 0
        }
        guard gated else { return 0 }
        let fixedRatio = min(1.15, (l - log(1.8)) / (log(13.0) - log(1.8)))
        var ratio = fixedRatio
        if auto {
            let hi = refHigh
            let lo = min(refLow, hi - 0.8)
            let span = max(0.8, hi - lo)
            let adaptive = min(1, (l - lo) / span)
            ratio = 0.5 * adaptive + 0.5 * fixedRatio
        }
        if near > 0 {
            let floorRatio = 0.6 * max(0, fixedRatio)
            ratio -= near * max(0, ratio - floorRatio)
        }
        let clampedGain = gainDb.isFinite ? min(12, max(-6, gainDb)) : 0
        let out = ratio * pow(10, clampedGain / 20) * 75
        return out.isFinite ? min(100, max(0, out)) : 0
    }
}

/// 随机窗口（含姿态 / 近场 / 切镜 / 坏值），给逐位比对用
func atRandomWindow() -> MotionWindow {
    var w = MotionWindow()
    let r = vsRandom()
    w.frames = r < 0.05 ? 0 : 1 + Int(vsRandom() * 5)
    w.meanEnergy = vsRandom() < 0.03 ? Double.nan : vsRandom() * 12
    w.peakEnergy = w.meanEnergy + vsRandom() * 4
    w.cutCount = vsRandom() < 0.05 ? 1 : 0
    w.heldCount = vsRandom() < 0.05 ? 1 : 0
    w.nearField = vsRandom() < 0.2 ? vsRandom() : 0
    if vsRandom() < 0.85 {
        w.subjectFrames = max(1, w.frames)
        w.subjectScore = vsRandom() < 0.02 ? Double.nan : vsRandom()
    }
    if vsRandom() < 0.6 {
        w.poseFrames = 3
        w.posePresentFrames = vsRandom() < 0.8 ? 3 : 0
        w.poseScore = vsRandom()
        w.poseConfidence = vsRandom()
        w.poseTrust = vsRandom() < 0.5 ? 1 : vsRandom()
    }
    return w
}

do {
    // 开关关着 = 92681ea：调优关着的 MotionNormalizer（含 PoseBlend）和原样拷贝逐位相同（随机窗口 / 设置 / 换视频）
    var same = true
    var steps = 0
    for _ in 0..<60 {
        var a = MotionNormalizer()
        var b = BaseMotionNormalizer92()
        for _ in 0..<120 {
            if vsRandom() < 0.01 {
                a.resetAdaptation()
                b.resetAdaptation()
            }
            let w = atRandomWindow()
            let gain = vsRandom() < 0.05 ? Double.infinity : vsRandom() * 18 - 6
            let auto = vsRandom() < 0.8
            let dt = vsRandom() < 0.03 ? Double.nan : 0.05 + vsRandom() * 0.6
            let x = a.step(w, gainDb: gain, auto: auto, dt: dt)
            let y = b.step(w, gainDb: gain, auto: auto, dt: dt)
            same = same && (x == y || (x.isNaN && y.isNaN)) && a.confidence == b.confidence
            steps += 1
        }
    }
    let d = MotionNormalizer()
    var p = PoseMotionTracker()
    let an = MotionAnalyzer()
    var est = BlockMotionEstimator()
    est.cameraFit = true
    p.contextEnabled = true
    vcheck(same && !d.actionTuned && !p.actionTuned && !an.actionTuned && !an.periodicity.stabilityGuard
           && !est.noiseGuard && !RoiFlowTracker().noiseGuard && ActionContext().intensityCeiling == nil
           && !ActionContext().suppressesRhythm,
           "动作调优关着 = 92681ea：MotionNormalizer / PoseBlend 和原样拷贝逐位相同（\(steps) 步随机），所有调优开关默认关")
}

do {
    // gentle：单调、不升、≥ 0.55 不变；固定点
    var mono = true
    var prev = -1.0
    for i in 0...100 {
        let s = Double(i) / 100
        let g = MotionNormalizer.gentle(s)
        mono = mono && g >= prev - 1e-12 && g <= s + 1e-12
        prev = g
    }
    vcheck(mono && abs(MotionNormalizer.gentle(0.2) - 0.07) < 1e-9 && abs(MotionNormalizer.gentle(0.6) - 0.6) < 1e-9
           && MotionNormalizer.gentle(.nan) == 0 && abs(MotionNormalizer.gentle(0.4) - 0.4 * (0.35 + 0.65 * 0.2 / 0.35)) < 1e-9,
           "动作调优：慢 / 轻动作的绝对压低单调、只降不升（0.2 → 0.07、0.4 → 0.29、≥ 0.55 不变）")

    // 轻动作（主体分数一直 0.3）：以前自动适应会放大到 ≥ 24；调优后 ≈ 9（≤ 12）。强动作（0.85）开 / 关完全一样
    func run(_ score: Double, tuned: Bool) -> [Double] {
        var c = VSChain()
        c.normalizer.actionTuned = tuned
        var out: [Double] = []
        for _ in 0..<60 {
            var w = MotionWindow(meanEnergy: 2, peakEnergy: 2, frames: 5, cutCount: 0, heldCount: 0)
            w.subjectFrames = 5
            w.subjectScore = score
            out.append(c.step(w))
        }
        return out
    }
    let lightOld = vs3Late(run(0.3, tuned: false))
    let lightNew = vs3Late(run(0.3, tuned: true))
    let strongOld = run(0.85, tuned: false)
    let strongNew = run(0.85, tuned: true)
    vcheck(lightOld >= 20 && lightNew <= 12 && strongOld == strongNew && vs3Late(strongNew) >= 80,
           "动作调优：轻动作不再被自动适应放大（关 \(Int(lightOld)) → 开 \(Int(lightNew))），强动作开 / 关逐位相同（\(Int(vs3Late(strongNew)))）")
}

/// 臀部特写：Vision 只认到髋 / 膝 4 个点（没有躯干 / 肩宽可量），置信度 0.5
func atPartialHips(confidence: Double = 0.5) -> PoseCandidate {
    var p = PoseCandidate()
    p.confidence = confidence
    p.set(.leftHip, x: 24, y: 18, confidence: confidence)
    p.set(.rightHip, x: 40, y: 18, confidence: confidence)
    p.set(.leftKnee, x: 22, y: 30, confidence: confidence)
    p.set(.rightKnee, x: 42, y: 30, confidence: confidence)
    return p
}

/// 同 vs3PoseRun，但 tracker / 归一化按 tuned 打开动作调优
func atPoseRun(tuned: Bool, flow: Double, seconds: Double = 14, pose: (Int, Double) -> PoseCandidate?) -> VS3PoseRun {
    var tracker = PoseMotionTracker()
    tracker.actionTuned = tuned
    tracker.contextEnabled = tuned
    var acc = MotionWindowAccumulator()
    var chain = VSChain()
    chain.normalizer.actionTuned = tuned
    var r = VS3PoseRun()
    var i = 0
    for k in 0..<Int(seconds * 15) {
        let t = Double(k) * vsDt
        acc.add(MotionSample(time: t, energy: 1, coverage: 0.2, isCut: false, isHeld: false,
                             subject: SubjectReading(valid: true, score: flow)))
        if k % 5 == 0 || k % 5 == 2 || k % 5 == 4 {
            let found = pose(i, t).map { [$0] } ?? []
            let reading = tracker.update(time: t, candidates: found, camera: .identity, continuous: true, frameHeight: 36)
            r.readings.append(reading)
            acc.addPose(reading)
            i += 1
        }
        if k % 5 == 4 {
            let v = chain.step(acc.drain())
            r.outs.append(v)
            r.maxWeight = max(r.maxWeight, chain.normalizer.poseWeight)
        }
    }
    return r
}

do {
    // 尺度：部分骨架（只有髋 / 膝）以前按包围框 × 0.3 ≈ 7 像素，调优按髋宽 × 2 = 32 像素；完整的人不变
    let partial = atPartialHips()
    let old = PoseMotionTracker.bodyScale(partial, frameHeight: 36)
    let tuned = PoseMotionTracker.tunedBodyScale(partial, frameHeight: 36)
    let full = vs3Skeleton(hipX: 1.5)
    let fullOld = PoseMotionTracker.bodyScale(full, frameHeight: 36)
    let fullNew = PoseMotionTracker.tunedBodyScale(full, frameHeight: 36)
    var chestOnly = PoseCandidate()
    chestOnly.confidence = 0.6
    chestOnly.set(.nose, x: 30, y: 4, confidence: 0.6)
    chestOnly.set(.leftWrist, x: 28, y: 20, confidence: 0.6)
    chestOnly.set(.rightWrist, x: 36, y: 22, confidence: 0.6)
    chestOnly.set(.neck, x: 31, y: 9, confidence: 0.6)
    let chest = PoseMotionTracker.tunedBodyScale(chestOnly, frameHeight: 36)
    vcheck(abs(old - 0.3 * (400.0 + 144).squareRoot()) < 1e-9 && tuned.partial && abs(tuned.scale - 32) < 1e-9
           && !fullNew.partial && fullNew.scale == fullOld && chest.partial && chest.scale >= 9 - 1e-9,
           "动作调优：只认到髋 / 膝时尺度 \(String(format: "%.1f", old)) → \(String(format: "%.1f", tuned.scale)) 像素（髋宽 × 2），"
           + "胸口特写至少 0.25 × 画面高；完整的人不变（\(String(format: "%.1f", fullNew.scale))）")

    // 臀部对着镜头不动（真机 b）：Vision 关键点每次独立抖 σ = 0.6 像素，块运动分数 0。
    // 以前：尺度太小 → 抖动读成很快 → 姿态分数高、输出 ≥ 10；调优：姿态分数 ≤ 0.12、输出 ≤ 3
    let oldRun = atPoseRun(tuned: false, flow: 0) { i, _ in vs3Jittered(atPartialHips(), i: i, sigma: 0.6) }
    let newRun = atPoseRun(tuned: true, flow: 0) { i, _ in vs3Jittered(atPartialHips(), i: i, sigma: 0.6) }
    let oldScores = oldRun.readings.suffix(oldRun.readings.count / 2).filter { $0.present }.map { $0.score }
    let oldScore = oldScores.isEmpty ? 0 : oldScores.reduce(0, +) / Double(oldScores.count)
    let newScore = newRun.readings.map { $0.score }.max() ?? 99
    let oldOut = vs3Late(oldRun.outs)
    let newOut = newRun.outs.max() ?? 99
    vcheck(oldScore >= 0.25 && oldOut >= 10 && newScore <= 0.12 && newOut <= 3,
           "动作调优（真机 b）：臀部特写不动 + 关键点抖动：姿态分 \(String(format: "%.2f", oldScore)) → ≤ \(String(format: "%.2f", newScore))，"
           + "输出 \(Int(oldOut)) → 最高 \(String(format: "%.1f", newOut))")

    // 姿态分数再高也不能比画面本身高太多：块运动 0 + 姿态说 1.0（检测在抖）→ 调优输出 0；块运动 0.6 时姿态照常起作用
    var on = MotionWindow(meanEnergy: 1, peakEnergy: 1, frames: 5, cutCount: 0, heldCount: 0)
    on.subjectFrames = 5
    on.subjectScore = 0
    on.poseFrames = 3
    on.posePresentFrames = 3
    on.poseScore = 1
    on.poseConfidence = 0.9
    var blendOld = PoseBlend()
    var blendNew = PoseBlend()
    var blendBusy = PoseBlend()
    var busy = on
    busy.subjectScore = 0.6
    var o = 0.0, n = 0.0, b = 0.0
    for _ in 0..<12 {
        o = blendOld.step(on, flow: 0, dt: 0.3)
        n = blendNew.step(on, flow: 0, dt: 0.3, tuned: true)
        b = blendBusy.step(busy, flow: 0.6, dt: 0.3, tuned: true)
    }
    vcheck(o >= 0.75 && n <= 0.1 + 1e-9 && b >= 0.9,
           "动作调优：姿态不能比画面本身的运动高太多（块运动 0：\(String(format: "%.2f", o)) → \(String(format: "%.2f", n))；块运动 0.6 时 \(String(format: "%.2f", b))）")

    // 完整的人：调优开着时姿态读数和关着逐位相同（尺度不变、死区不变）
    var a = PoseMotionTracker()
    var t = PoseMotionTracker()
    t.actionTuned = true
    var poseSame = true
    for i in 0..<90 {
        let time = Double(i) / 9
        let c = [vs3Jittered(vs3Skeleton(hipX: vs3HipWave(time)), i: i, sigma: 0.15)]
        poseSame = poseSame && a.update(time: time, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
            == t.update(time: time, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
    }
    vcheck(poseSame, "动作调优：完整的人（躯干 / 肩宽都在）姿态读数和关着逐位相同")
}

do {
    // 块运动噪声防护（真机 b：大片皮肤 + 光线闪烁）：上一帧平的 100，这一帧叠一个低对比的周期纹理（±6，周期 8 像素）：
    // 每块零位移帧差方差 12.5~14.5 > 9、纹理 rms ≈ 2.1 → 以前按法向流 ≈ 0.88 像素 / 帧，48 块全「在动」；
    // 调优：纹理 rms < 4 的块不给法向流 → 速度 0
    let pattern: [Int] = [-6, -3, 0, 3, 6, 3, 0, -3]
    let flat = [UInt8](repeating: 100, count: 64 * 36)
    var flicker = flat
    for y in 0..<36 {
        for x in 0..<64 { flicker[y * 64 + x] = UInt8(100 + pattern[x % 8]) }
    }
    func run(_ guardOn: Bool) -> BlockMotionResult {
        var e = BlockMotionEstimator()
        e.noiseGuard = guardOn
        return flicker.withUnsafeBufferPointer { cur in
            flat.withUnsafeBufferPointer { prev in e.estimate(cur: cur, prev: prev, width: 64, height: 36, gap: vsDt) }
        }
    }
    let old = run(false)
    let new = run(true)
    vcheck(old.movingBlocks >= 30 && old.speed >= 0.75 && new.movingBlocks == 0 && new.speed == 0 && !new.cameraActive,
           "动作调优（真机 b）：大片没纹理的皮肤上的闪烁不算运动（以前 \(old.movingBlocks) 块、\(String(format: "%.2f", old.speed)) 像素 / 帧 → "
           + "\(new.movingBlocks) 块、\(String(format: "%.2f", new.speed))）")

    // 有纹理的真实运动不受影响：20% 快速往复画面（algo-opt-3 的场景）调优开 / 关的输出差 ≤ 10 且仍 ≥ 70
    var plain = MotionAnalyzer()
    var tuned = MotionAnalyzer()
    tuned.actionTuned = true
    var accA = MotionWindowAccumulator()
    var accB = MotionWindowAccumulator()
    var wa: [MotionWindow] = []
    var wb: [MotionWindow] = []
    let scene = VS3Scene(rect: vs3Mid, hz: 2, peak: 4)
    for k in 0..<Int(14 * 15) {
        let f = scene.frame(k)
        if let s = plain.analyze(f, time: Double(k) * vsDt) { accA.add(s) }
        if let s = tuned.analyze(f, time: Double(k) * vsDt) { accB.add(s) }
        if k % 5 == 4 {
            wa.append(accA.drain())
            wb.append(accB.drain())
        }
    }
    let outA = vs3Output(wa)
    // 开 = 分析器噪声防护 + 归一化调优（gentle / 姿态上界 / 放大门槛）整条链都开
    let outB = vs3Output(wb, tuned: true)
    vcheck(tuned.actionTuned && tuned.periodicity.stabilityGuard && abs(outA.mean - outB.mean) <= 10 && outB.mean >= 70,
           "动作调优：有纹理的 20% 快速往复照样强（关 \(Int(outA.mean)) / 整条链开 \(Int(outB.mean))）")
}

/// 一拍的窗口：主体在 1.2 Hz 往复（块运动 0.45、姿态 0.4、腕的节奏 1.2 Hz）；上下文里一只手在胸口（32, 12）。
/// chest = true：姿态给了胸口锚点和右手腕（调优后的 PoseMotionTracker 才给）；false：92681ea 的上下文（没有这几项）
func atChestWindow(time: Double, chest: Bool, region: Bool = false, amplitude: Double = 0.08) -> MotionWindow {
    var w = MotionWindow(meanEnergy: 2, peakEnergy: 3, frames: 5, cutCount: 0, heldCount: 0)
    w.subjectFrames = 5
    w.subjectScore = 0.45
    w.subjectHz = 1.2
    w.subjectFollowHz = 1.2
    w.subjectFollowRhythm = 0.7
    w.subjectFollowAmplitude = 3
    w.poseFrames = 3
    w.posePresentFrames = 3
    w.poseScore = 0.4
    w.poseConfidence = 0.8
    w.poseRhythmHz = 1.2
    w.poseRhythmConfidence = 0.8
    w.poseRhythmPart = 3
    w.poseRhythmRate = 9
    var c = PoseContext()
    c.valid = true
    c.time = time - 0.05
    c.frameWidth = 64
    c.frameHeight = 36
    var rh = PartRhythm()
    // 轻抚：手小幅地摸（默认 0.08 躯干）；amplitude ≥ 0.12 的同一个窗口就是在胸口前规则地撸（H1 反例）
    rh.follow = StrokeRhythm.FollowEstimate(hz: 1.2, confidence: 0.8, amplitude: amplitude, sampleRate: 9)
    c.hand = PartReading(present: true, time: c.time, x: 32, y: 12, size: 6, confidence: 0.8, rhythm: rh)
    c.body.present = true
    c.body.time = c.time
    c.body.scale = 16
    c.body.hasHip = true
    c.body.hipX = 32
    c.body.hipY = 20
    c.body.hasHead = true
    c.body.headX = 32
    c.body.headY = 4
    c.body.hasWrist = true
    c.body.wristX = 33
    c.body.wristY = 12
    c.body.wrists = rh
    if chest {
        c.body.hasChest = true
        c.body.chestX = 32
        c.body.chestY = 9
        c.body.hasRightWrist = true
        c.body.rightWristX = 33
        c.body.rightWristY = 12
        c.body.rightWristRhythm = rh.follow
    }
    w.context = c
    if region {
        // 周期区域就在摸胸口的那只手上（真机里慢慢摸的那只手就是主要的周期区域）
        w.roi.region = atRegion(x: 33, y: 12, time: time - 0.05)
    }
    return w
}

/// 分析帧（64 × 36）里以 (x, y) 为中心、半宽 halfW / 半高 halfH 像素的周期区域
func atRegion(x: Double, y: Double, halfW: Double = 4, halfH: Double = 3, time: Double, hz: Double = 1.2) -> PeriodicityROI {
    var g = PeriodicityROI()
    g.valid = true
    g.time = time
    g.hz = hz
    g.x0 = (x - halfW) / 64
    g.x1 = (x + halfW) / 64
    g.y0 = (y - halfH) / 36
    g.y1 = (y + halfH) / 36
    g.blocks = 1
    g.share = 0.6
    return g
}

struct ATRun {
    var values: [Double] = []
    var out: [[Int]] = []
    var kinds: [ActionContext.Kind] = []
    var locked: [Bool] = []
}

/// VideoSyncPlayer.motionTick 的画面 → 出口那一段（0.3 秒一拍、频率跟随开、未标定的档位表、联动开）：
/// tuned = 动作调优；context = 跑 ActionContext.refine（动作识别开着）
func atRun(beats: Int = 40, tuned: Bool, context: Bool, settings: AudioSyncSettings = AudioSyncSettings(maxPercent: 100),
           window: (Double) -> MotionWindow) -> ATRun {
    var normalizer = MotionNormalizer()
    normalizer.actionTuned = tuned
    var shaper = MotionShaper()
    var ac = ActionContext()
    var follower = RhythmFollower()
    var stage = SyncOutputStage()
    var r = ATRun()
    for i in 0..<beats {
        let now = 100 + Double(i) * 0.3
        let w = window(now)
        // 同 VideoSyncPlayer：gentle 只在轻抚 / 还没认出动作且没锁节奏时用（上一拍的判断）
        normalizer.gentleAllowed = ac.allowsGentle(followerLocked: follower.locked)
        var target = normalizer.step(w, gainDb: 0, auto: true, dt: 0.3)
        if tuned, let ceiling = ac.intensityCeiling { target = min(target, ceiling) }
        let shaped = shaper.step(target: target, dt: 0.3)
        let value = normalizer.confidence * shaped.smoothed
        let activity = RhythmOutput.motionActivity(level: shaped.level, smoothed: shaped.smoothed,
                                                   confidence: normalizer.confidence, motionSignal: true)
        let lockHz = ActionContext.lockedHz(locked: follower.locked, weight: follower.weight, hz: follower.hz)
        let input = context ? ac.refine(w, now: now, followerHz: lockHz) : w
        let suppress = tuned && ac.suppressesRhythm
        follower.step(input, dt: 0.3, active: activity > 0 && !suppress)
        let rate: Int? = follower.weight > 0 && follower.hz > 0 ? DeviceRateMap.uncalibrated.level(forHz: follower.hz) : nil
        let levels = RhythmOutput.target(value: value, settings: settings, hasSignal: true, rateLevel: rate,
                                         weight: follower.weight, activity: suppress ? 0 : activity)
        r.out.append(stage.step(levels: levels, settings: settings, now: now, timed: false))
        r.values.append(value)
        r.kinds.append(ac.kind)
        r.locked.append(follower.locked)
    }
    return r
}

do {
    // 真机 a：一只手慢慢在自己胸口摸（1.2 Hz 小幅，髋不动）。
    // 92681ea + 动作识别：手在髋附近 → 认成撸动、跟手的 1.2 Hz，强度被自动适应放大 → 输出 ≥ 30；
    // 调优：自己的手在自己躯干上 → 轻抚：不跟节奏（跟随器放开）、强度最多 20
    let old = atRun(tuned: false, context: true) { atChestWindow(time: $0, chest: false) }
    let new = atRun(tuned: true, context: true) { atChestWindow(time: $0, chest: true, region: true) }
    let lateOld = old.out.suffix(15)
    let lateNew = new.out.suffix(15)
    let oldPeak = Double(lateOld.map { $0.max() ?? 0 }.reduce(0, +)) / 15
    let oldThrust = Double(lateOld.map { $0[0] }.reduce(0, +)) / 15
    let newMax = lateNew.map { $0.max() ?? 0 }.max() ?? 99
    vcheck(old.kinds.last == .stroke && old.locked.last == true && oldPeak >= 30 && oldThrust >= 25,
           "动作调优（真机 a 复现）：92681ea 把摸胸口认成撸动、锁 1.2 Hz（输出 \(Int(oldPeak))、伸缩 \(Int(oldThrust))）")
    vcheck(new.kinds.last == .caress && new.locked.suffix(10).allSatisfy { !$0 } && newMax <= 20
           && (new.values.suffix(15).max() ?? 99) <= 20 + 0.01,  // 平滑从前三拍的高值指数回落，尾巴上 ~0.0006 的残差；出口值已 ≤ 20
           "动作调优（真机 a）：摸自己胸口认成轻抚，不跟节奏、输出 ≤ 20（最高 \(newMax)；kind \(String(describing: new.kinds.last))；locked \(new.locked.suffix(10))；value \(new.values.suffix(15).max() ?? -1)；kinds \(new.kinds.map { $0.rawValue })）")
    var ac = ActionContext()
    var t = 10.0
    while t < 12.5 {
        _ = ac.refine(atChestWindow(time: t, chest: true, region: true), now: t)
        t += 0.3
    }
    let refined = ac.refine(atChestWindow(time: t, chest: true, region: true), now: t)
    vcheck(ac.kind == .caress && ac.suppressesRhythm && ac.intensityCeiling == ActionContext.caressCeiling
           && refined.subjectFollowHz == 0 && refined.poseRhythmHz == 0 && !refined.subjectPhase.isValid
           && !ac.directionKnown && ac.statusText().contains("轻抚"),
           "动作调优：轻抚时交给跟随器 / 相位锁的副本没有节奏候选，状态行「\(ac.statusText())」")

    // 自己的手放在胯（不是胸口 / 肚子）上：不算轻抚（照常按撸动的规则走）
    var low = ActionContext()
    t = 10
    while t < 12.5 {
        var w = atChestWindow(time: t, chest: true)
        w.context.body.rightWristX = 32
        w.context.body.rightWristY = 21
        w.context.hand.x = 32
        w.context.hand.y = 21
        w.context.body.wristX = 32
        w.context.body.wristY = 21
        _ = low.refine(w, now: t)
        t += 0.3
    }
    // 髋在同频往复（被插入时摸自己）：不算轻抚
    var busy = ActionContext()
    t = 10
    while t < 12.5 {
        var w = atChestWindow(time: t, chest: true, region: true)
        w.context.body.hips.follow = StrokeRhythm.FollowEstimate(hz: 1.2, confidence: 0.8, amplitude: 0.2, sampleRate: 9)
        _ = busy.refine(w, now: t)
        t += 0.3
    }
    vcheck(low.kind == .stroke && busy.kind != .caress && busy.evidence.caress == 0 && busy.intensityCeiling == nil,
           "动作调优：手在胯上 → 撸动（\(low.kind)）；髋在同频往复时摸自己不算轻抚（\(busy.kind)）")
}

do {
    // 只有一只手在动（没认到身体）不算撸动：以前直接认成撸动、把手的节奏塞给跟随器
    var ac = ActionContext()
    var out = MotionWindow()
    var t = 10.0
    while t < 13 {
        var w = p3Window(time: t, hand: (1.5, 0.8, 0.3))
        w.context.body = PoseBodyContext()
        out = ac.refine(w, now: t)
        t += 0.3
    }
    // 说话 / 点头的人：脸在自己头上和画面同频地动，没有别人的髋 → 不是口交
    var talk = ActionContext()
    var talkOut = MotionWindow()
    t = 10
    while t < 13 {
        talkOut = talk.refine(p3Window(time: t, face: (1.5, 0.8, 0.3), faceAt: (32, 7)), now: t)
        t += 0.3
    }
    // 同一张脸在另一个人的髋旁 → 口交照认
    var oral = ActionContext()
    t = 10
    while t < 13 {
        _ = oral.refine(p3Window(time: t, face: (1.5, 0.8, 0.3), faceAt: (32, 7), otherHip: (34, 12)), now: t)
        t += 0.3
    }
    vcheck(ac.kind == .unknown && out.poseRhythmHz == 0 && talk.kind == .unknown && talkOut.poseRhythmPart == 0
           && oral.kind == .oral,
           "动作调优：没有对象的手（没认到身体）不算撸动、说话 / 点头不算口交（\(ac.kind) / \(talk.kind)）；脸在另一个人髋旁照认（\(oral.kind)）")
}

do {
    // 另一个人的髋在往复（认到的这个人不动）：插入，跟另一个人的髋，往里 = 朝认到的这个人
    var ac = ActionContext()
    var out = MotionWindow()
    var t = 10.0
    while t < 13 {
        var w = p3Window(time: t, otherHip: (32, 28))
        var rh = PartRhythm()
        rh.follow = StrokeRhythm.FollowEstimate(hz: 1.5, confidence: 0.8, amplitude: 0.3, sampleRate: 9)
        w.context.body.otherHips = rh
        out = ac.refine(w, now: t)
        t += 0.3
    }
    vcheck(ac.kind == .insertion && ac.usesOtherHips && out.poseRhythmPart == 1 && abs(out.poseRhythmHz - 1.5) < 1e-9
           && ac.statusText().contains("另一个人"),
           "动作调优：另一个人的髋在往复时认成插入并跟他（\(ac.statusText())）")

    // PoseMotionTracker：认到的人不动、另一个人髋 2 Hz 往复 → bodyContext.otherHips ≈ 2 Hz；胸口 / 两腕位置给出
    var tracker = PoseMotionTracker()
    tracker.contextEnabled = true
    tracker.actionTuned = true
    for i in 0..<90 {
        let time = Double(i) / 9
        let c = [vs3Skeleton(), vs3Skeleton(shiftX: 20, hipX: vs3HipWave(time), confidence: 0.6)]
        _ = tracker.update(time: time, candidates: c, camera: .identity, continuous: true, frameHeight: 36)
    }
    let bc = tracker.bodyContext
    vcheck(abs(bc.otherHips.follow.hz - 2) <= 0.2 && bc.hasChest && abs(bc.chestY - 11) < 1e-9 && bc.hasLeftWrist
           && bc.hasRightWrist && abs(bc.rightWristX - 38) < 1e-9,
           "动作调优：另一个人的髋也攒节奏（\(String(format: "%.2f", bc.otherHips.follow.hz)) Hz），给出胸口和两只手腕的位置")
}

do {
    // 改判确认漏一拍不重新计时：撸动、撸动、（这拍没依据）、撸动 → 第 4 拍（0.9 秒）就改判；
    // 连续缺 3 拍（> 0.6 秒）才重新计时
    func kinds(_ missing: Set<Int>) -> [ActionContext.Kind] {
        var ac = ActionContext()
        var out: [ActionContext.Kind] = []
        for i in 0..<12 {
            let t = 10 + Double(i) * 0.3
            let w = missing.contains(i) ? p3Window(time: t) : p3Window(time: t, hand: (1.5, 0.8, 0.3))
            _ = ac.refine(w, now: t)
            out.append(ac.kind)
        }
        return out
    }
    let one = kinds([2])
    let three = kinds([2, 3, 4])
    vcheck(one[2] == .unknown && one[3] == .stroke && three[7] == .unknown && three[8] == .stroke,
           "动作调优：改判确认中漏一拍不重新计时（第 \(one.firstIndex(of: .stroke) ?? -1) 拍改判），连续缺 0.9 秒才重新计时（第 \(three.firstIndex(of: .stroke) ?? -1) 拍）")
}

do {
    // 周期区域稳定性：一块 1.2 Hz 往复 → 调优要连续两次（≥ 0.3 秒）一致才给区域；
    // 画面到处都有同频的抖动（6 块各 0.9 倍、和种子不相邻）→ 种子只占 ≈ 17% 的功率 → 调优不给区域（以前给）
    func run(_ guardOn: Bool, extra: Bool) -> (roi: PeriodicityROI, first: Double, everValid: Bool) {
        var map = PeriodicityMap()
        map.stabilityGuard = guardOn
        var first = -1.0
        var ever = false
        for k in 0..<90 {
            let t = Double(k) * vsDt
            var rx = [Double](repeating: 0, count: PeriodicityMap.blockCount)
            let ry = [Double](repeating: 0, count: PeriodicityMap.blockCount)
            rx[5] = sin(2 * Double.pi * 1.2 * t)
            if extra {
                for (j, b) in [0, 2, 16, 18, 32, 34].enumerated() {
                    rx[b] = 0.9 * sin(2 * Double.pi * 1.2 * t + Double(j))
                }
            }
            map.add(time: t, residualX: rx, residualY: ry, gap: vsDt)
            let r = map.update(hz: 1.2, now: t)
            if r.valid {
                ever = true
                if first < 0 { first = t }
            }
        }
        return (map.roi, first, ever)
    }
    let a = run(false, extra: false)
    let b = run(true, extra: false)
    let c = run(false, extra: true)
    let d = run(true, extra: true)
    vcheck(a.roi.valid && b.roi.valid && b.roi.blocks == 1 && abs(b.roi.x0 - 5.0 / 8) < 1e-9 && b.first >= a.first + 0.29
           && c.roi.valid && c.roi.share < 0.35 && !d.everValid,
           "动作调优：周期区域连续两次一致才给（晚 \(String(format: "%.2f", b.first - a.first)) 秒）；"
           + "到处都有同频抖动、种子只占 \(String(format: "%.0f", c.roi.share * 100))% 时不给区域")
}

// MARK: - rhythm-action tune 复审修正：轻抚不压掉真往复、gentle 只压轻抚 / 没认出的动作

/// 两只手：右手平放在自己肚子上（不动），左手在胯上撸（1.5 Hz）。handOnRest = 手检测落在不动的那只手上
func atTwoHandWindow(time: Double, handOnRest: Bool, region: Bool) -> MotionWindow {
    var w = atChestWindow(time: time, chest: true)
    w.subjectHz = 1.5
    w.subjectFollowHz = 1.5
    w.poseRhythmHz = 1.5
    var stroke = PartRhythm()
    stroke.follow = StrokeRhythm.FollowEstimate(hz: 1.5, confidence: 0.8, amplitude: 0.2, sampleRate: 9)
    w.context.body.rightWristX = 33
    w.context.body.rightWristY = 15
    w.context.body.rightWristRhythm = StrokeRhythm.FollowEstimate()
    w.context.body.hasLeftWrist = true
    w.context.body.leftWristX = 31
    w.context.body.leftWristY = 21
    w.context.body.leftWristRhythm = stroke.follow
    w.context.body.wristX = 32
    w.context.body.wristY = 18
    w.context.body.wrists = stroke
    if handOnRest {
        w.context.hand.x = 33
        w.context.hand.y = 15
        w.context.hand.rhythm = PartRhythm()
    } else {
        w.context.hand.x = 31
        w.context.hand.y = 21
        w.context.hand.rhythm = stroke
    }
    if region { w.roi.region = atRegion(x: 31, y: 21, time: time - 0.05, hz: 1.5) }
    return w
}

/// 被口交的一方（认到的这个人）一只手放在自己肚子上；另一个人的脸在他胯上 1.5 Hz 往复
func atPassiveOralWindow(time: Double, region: Bool) -> MotionWindow {
    var w = atChestWindow(time: time, chest: true)
    w.subjectHz = 1.5
    w.subjectFollowHz = 1.5
    w.poseRhythmHz = 1.5
    w.context.hand = PartReading()
    w.context.body.wrists = PartRhythm()
    w.context.body.rightWristX = 33
    w.context.body.rightWristY = 15
    w.context.body.rightWristRhythm = StrokeRhythm.FollowEstimate()
    w.context.body.wristX = 33
    w.context.body.wristY = 15
    var bob = PartRhythm()
    bob.follow = StrokeRhythm.FollowEstimate(hz: 1.5, confidence: 0.8, amplitude: 0.3, sampleRate: 9)
    w.context.face = PartReading(present: true, time: w.context.time, x: 32, y: 22, size: 6, confidence: 0.8, rhythm: bob)
    w.context.body.hasOtherHip = true
    w.context.body.otherHipX = 32
    w.context.body.otherHipY = 34
    w.context.body.otherScale = 16
    w.context.body.hasOtherHead = true
    w.context.body.otherHeadX = 32
    w.context.body.otherHeadY = 22
    if region { w.roi.region = atRegion(x: 32, y: 22, time: time - 0.05, hz: 1.5) }
    return w
}

func atSettle(_ make: (Double) -> MotionWindow, seconds: Double = 3) -> ActionContext {
    var ac = ActionContext()
    var t = 10.0
    while t < 10 + seconds {
        _ = ac.refine(make(t), now: t)
        t += 0.3
    }
    return ac
}

do {
    // 自己撸、另一只手放在肚子上：不能认成轻抚（以前固定 0.6 的轻抚依据压过撸动 → 强度最多 20、不跟节奏）
    var ok = true
    var notes: [String] = []
    for handOnRest in [false, true] {
        for region in [true, false] {
            let ac = atSettle { atTwoHandWindow(time: $0, handOnRest: handOnRest, region: region) }
            ok = ok && ac.kind == .stroke && ac.evidence.caress == 0 && ac.intensityCeiling == nil && !ac.suppressesRhythm
            notes.append("\(ac.kind)")
        }
    }
    vcheck(ok, "动作调优：自己撸、另一只手放在肚子上 → 撸动，不是轻抚（手检测在撸的手 / 放着的手 × 有 / 没区域：\(notes)）")

    // 被口交的一方一只手放在自己肚子上：口交，不是轻抚（区域在脸那里，离髋比离那只手近）
    var oralOK = true
    var oralNotes: [String] = []
    for region in [true, false] {
        let ac = atSettle { atPassiveOralWindow(time: $0, region: region) }
        oralOK = oralOK && ac.kind == .oral && ac.evidence.caress == 0 && ac.intensityCeiling == nil
        oralNotes.append("\(ac.kind)")
    }
    vcheck(oralOK, "动作调优：被口交的一方手放在肚子上 → 口交，不是轻抚（有 / 没区域：\(oralNotes)）")

    // 轻抚中出现往复的对手（另一只手开始撸）：这一拍就放开轻抚（上限 / 不跟节奏马上撤掉），0.9 秒后认成撸动
    var ac = atSettle { atChestWindow(time: $0, chest: true, region: true) }
    let wasCaress = ac.kind == .caress
    var t = 13.0
    _ = ac.refine(atTwoHandWindow(time: t, handOnRest: false, region: true), now: t)
    let leftAtOnce = ac.kind != .caress && ac.intensityCeiling == nil && !ac.suppressesRhythm
    while t < 14.2 {
        t += 0.3
        _ = ac.refine(atTwoHandWindow(time: t, handOnRest: false, region: true), now: t)
    }
    vcheck(wasCaress && leftAtOnce && ac.kind == .stroke,
           "动作调优：轻抚中另一只手开始撸 → 当拍放开轻抚、随后认成撸动（\(ac.kind)）")

    // 没有周期区域：摸胸口不算轻抚（区域必须在那只手旁）；整幅画面在大幅动 / 跟随器锁在别的频率上也不算
    let noRegion = atSettle { atChestWindow(time: $0, chest: true, region: false) }
    let vigorous = atSettle { t in
        var w = atChestWindow(time: t, chest: true, region: true)
        w.subjectScore = 0.8
        return w
    }
    var lockedElse = ActionContext()
    t = 10
    while t < 13 {
        _ = lockedElse.refine(atChestWindow(time: t, chest: true, region: true), now: t, followerHz: 2.0)
        t += 0.3
    }
    vcheck(noRegion.kind != .caress && noRegion.allowsGentle(followerLocked: true)
           && vigorous.kind != .caress && lockedElse.kind != .caress && !lockedElse.allowsGentle(followerLocked: true),
           "动作调优：没有区域 / 画面大幅动 / 跟随器锁在别的频率时不认轻抚（\(noRegion.kind) / \(vigorous.kind) / \(lockedElse.kind)）；"
           + "没区域时节奏只来自那只手，慢动作照样压低")

    // 没区域时（认不成轻抚）慢慢摸胸口也不会被放大：跟随器锁上那只手的 1.2 Hz，gentle 照样压（比 92681ea 低）
    let oldNoRegion = atRun(tuned: false, context: true) { atChestWindow(time: $0, chest: false) }
    let newNoRegion = atRun(tuned: true, context: true) { atChestWindow(time: $0, chest: true, region: false) }
    let oldMean = vs3Late(oldNoRegion.values)
    let newMean = vs3Late(newNoRegion.values)
    // M1：伸缩通道（out[0]）也不能被手的 1.2 Hz 节奏推上去：selfPaced 时跟随器不锁、伸缩跟强度走
    let oldNRThrust = Double(oldNoRegion.out.suffix(15).map { $0[0] }.reduce(0, +)) / 15
    let newNRThrust = Double(newNoRegion.out.suffix(15).map { $0[0] }.reduce(0, +)) / 15
    let newNRPeak = newNoRegion.out.suffix(15).map { $0.max() ?? 0 }.max() ?? 99
    vcheck(newMean <= oldMean - 3 && newNRThrust <= oldNRThrust - 5 && newNoRegion.locked.suffix(10).allSatisfy { !$0 }
           && Double(newNRPeak) <= newMean + 3,
           "动作调优：没区域时摸胸口也按轻动作压低（92681ea \(Int(oldMean)) → \(Int(newMean))），伸缩不跟手的节奏"
           + "（\(Int(oldNRThrust)) → \(Int(newNRThrust))，最高 \(newNRPeak)）")
}

/// 慢的真插入：髋 0.8 Hz 往复（置信度 0.8、幅度 0.15 躯干），主体分数 0.32（0.8 Hz、1.5 像素 / 帧、4 像素幅度的实际分数）
func atSlowThrustWindow(time: Double) -> MotionWindow {
    var w = MotionWindow(meanEnergy: 2, peakEnergy: 3, frames: 5, cutCount: 0, heldCount: 0)
    w.subjectFrames = 5
    w.subjectScore = 0.32
    w.subjectHz = 0.8
    w.subjectFollowHz = 0.8
    w.subjectFollowRhythm = 0.8
    w.subjectFollowAmplitude = 4
    var c = PoseContext()
    c.valid = true
    c.time = time - 0.05
    c.frameWidth = 64
    c.frameHeight = 36
    c.body.present = true
    c.body.time = c.time
    c.body.scale = 16
    c.body.hasHip = true
    c.body.hipX = 32
    c.body.hipY = 20
    c.body.hips.follow = StrokeRhythm.FollowEstimate(hz: 0.8, confidence: 0.8, amplitude: 0.15, sampleRate: 9)
    w.context = c
    w.roi.region = atRegion(x: 32, y: 20, time: time - 0.05, hz: 0.8)
    return w
}

do {
    // 慢的真插入不被 gentle 压：认出插入 / 节奏锁上后，强度和 92681ea 一样（以前一直按轻动作压到约 1/3）
    let old = atRun(tuned: false, context: true) { atSlowThrustWindow(time: $0) }
    let new = atRun(tuned: true, context: true) { atSlowThrustWindow(time: $0) }
    var crushed = MotionNormalizer()
    crushed.actionTuned = true
    crushed.gentleAllowed = true  // 对照：一直按轻动作压会是多少
    var crushedChain = VSChain()
    crushedChain.normalizer = crushed
    var crushedOut: [Double] = []
    for i in 0..<40 { crushedOut.append(crushedChain.step(atSlowThrustWindow(time: 100 + Double(i) * 0.3))) }
    let oldMean = vs3Late(old.values)
    let newMean = vs3Late(new.values)
    let oldThrust = Double(old.out.suffix(15).map { $0[0] }.reduce(0, +)) / 15
    let newThrust = Double(new.out.suffix(15).map { $0[0] }.reduce(0, +)) / 15
    vcheck(new.kinds.last == .insertion && new.locked.last == true && newMean >= 0.95 * oldMean
           && newThrust >= 0.9 * oldThrust && vs3Late(crushedOut) <= 0.6 * oldMean,
           "动作调优：慢的真插入（主体 0.32）认出 / 锁上后不再按轻动作压（强度 92681ea \(Int(oldMean)) / 调优 \(Int(newMean))，"
           + "伸缩 \(Int(oldThrust)) / \(Int(newThrust))；一直压的话只有 \(Int(vs3Late(crushedOut)))）")

    // gentle 不和近场收拢叠加：近场 1 的大幅动作（主体 0.9）调优开 / 关一样；近场里本来就轻的（0.3）照样压
    func nearRun(_ score: Double, tuned: Bool) -> Double {
        var c = VSChain()
        c.normalizer.actionTuned = tuned
        var out: [Double] = []
        for _ in 0..<60 {
            var w = MotionWindow(meanEnergy: 2, peakEnergy: 2, frames: 5, cutCount: 0, heldCount: 0)
            w.subjectFrames = 5
            w.subjectScore = score
            w.nearField = 1
            out.append(c.step(w))
        }
        return vs3Late(out)
    }
    let vigOld = nearRun(0.9, tuned: false)
    let vigNew = nearRun(0.9, tuned: true)
    let lightOld = nearRun(0.3, tuned: false)
    let lightNew = nearRun(0.3, tuned: true)
    vcheck(abs(vigOld - vigNew) < 1e-9 && vigNew >= 20 && lightNew < lightOld,
           "动作调优：近景大幅动作不被 gentle 再压一遍（关 \(Int(vigOld)) / 开 \(Int(vigNew))），近景轻动作照样压（\(Int(lightOld)) → \(Int(lightNew))）")
}

do {
    // 臀部特写不动、块运动带着真实的残余噪声（压缩闪烁 / 暗场，主体分 0.12~0.2 来回）：调优整条链输出 ≤ 3
    var seed: UInt64 = 7
    func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    var tracker = PoseMotionTracker()
    tracker.actionTuned = true
    tracker.contextEnabled = true
    var oldTracker = PoseMotionTracker()
    var acc = MotionWindowAccumulator()
    var oldAcc = MotionWindowAccumulator()
    var chain = VSChain()
    chain.normalizer.actionTuned = true
    var oldChain = VSChain()
    var outs: [Double] = []
    var oldOuts: [Double] = []
    var i = 0
    for k in 0..<Int(14 * 15) {
        let t = Double(k) * vsDt
        let flow = 0.12 + 0.08 * noise()
        let sample = MotionSample(time: t, energy: 1, coverage: 0.2, isCut: false, isHeld: false,
                                  subject: SubjectReading(valid: true, score: flow))
        acc.add(sample)
        oldAcc.add(sample)
        if k % 5 == 0 || k % 5 == 2 || k % 5 == 4 {
            let p = [vs3Jittered(atPartialHips(), i: i, sigma: 0.6)]
            acc.addPose(tracker.update(time: t, candidates: p, camera: .identity, continuous: true, frameHeight: 36))
            oldAcc.addPose(oldTracker.update(time: t, candidates: p, camera: .identity, continuous: true, frameHeight: 36))
            i += 1
        }
        if k % 5 == 4 {
            outs.append(chain.step(acc.drain()))
            oldOuts.append(oldChain.step(oldAcc.drain()))
        }
    }
    let newMax = outs.max() ?? 99
    let oldLate = vs3Late(oldOuts)
    vcheck(newMax <= 3 && oldLate >= 10,
           "动作调优（真机 b）：臀部特写不动 + 残余块运动噪声 0.12~0.2 + 关键点抖动：输出 92681ea \(Int(oldLate)) → 调优最高 \(String(format: "%.1f", newMax))")
}

// MARK: - rhythm-action tune 复审 2：在胸口前的真往复不封顶、gentle 要正面依据、没纹理的真运动、轻抚的放开

/// H1 反例：同一个胸口窗口，但那只手规则、大幅（0.2 躯干）地 1.2 Hz 往复
/// kind：handjob = 一只手在胸口前撸（POV，被撸的人不在画面里）；titjob = 两只手都在胸口；cowgirl = 一只手放胸口、髋出画
func atReciprocationWindow(time: Double, kind: String, chest: Bool) -> MotionWindow {
    var w = atChestWindow(time: time, chest: chest, region: true, amplitude: 0.2)
    if kind == "titjob", chest {
        w.context.body.hasLeftWrist = true
        w.context.body.leftWristX = 29
        w.context.body.leftWristY = 13
        w.context.body.leftWristRhythm = w.context.body.rightWristRhythm
    }
    if kind == "cowgirl" {
        w.context.body.hasHip = false
        w.context.body.hips = PartRhythm()
    }
    return w
}

do {
    var ok = true
    var notes: [String] = []
    for kind in ["handjob", "titjob", "cowgirl"] {
        let old = atRun(tuned: false, context: true) { atReciprocationWindow(time: $0, kind: kind, chest: false) }
        let new = atRun(tuned: true, context: true) { atReciprocationWindow(time: $0, kind: kind, chest: true) }
        let oldMean = vs3Late(old.values)
        let newMean = vs3Late(new.values)
        let newPeak = new.out.suffix(15).map { $0.max() ?? 0 }.max() ?? 0
        let ac = atSettle { atReciprocationWindow(time: $0, kind: kind, chest: true) }
        let fine = !new.kinds.contains(.caress) && ac.intensityCeiling == nil && !ac.suppressesRhythm
            && newMean >= 0.9 * oldMean && newPeak > 20 && new.locked.last == true
        ok = ok && fine
        notes.append("\(kind): \(ac.kind) \(Int(oldMean))→\(Int(newMean)) 峰 \(newPeak) 锁 \(new.locked.last ?? false)")
    }
    vcheck(ok, "动作调优（H1）：胸口前规则大幅的真往复（POV 撸动 / 乳交 / 骑乘手放胸口、髋出画）不认轻抚、不封顶 20、照常跟节奏（\(notes)）")
}

do {
    // M2：没认到身体的特写里慢的、不规则的真插入（0.6 Hz、跟随置信度 0.35 < 锁定门 0.4，跟随器锁不上）≈ 92681ea
    func slow(_ t: Double) -> MotionWindow {
        var w = MotionWindow(meanEnergy: 2, peakEnergy: 3, frames: 5, cutCount: 0, heldCount: 0)
        w.subjectFrames = 5
        w.subjectScore = 0.32
        w.subjectHz = 0.6
        w.subjectFollowHz = 0.6
        w.subjectFollowRhythm = 0.35
        w.subjectFollowAmplitude = 2
        return w
    }
    let old = atRun(tuned: false, context: true, window: slow)
    let new = atRun(tuned: true, context: true, window: slow)
    // 画面完全没节奏（静止特写的残余噪声 0.2）：照样压到几乎 0
    let still = atRun(tuned: true, context: true) { t in
        var w = slow(t)
        w.subjectScore = 0.2
        w.subjectFollowRhythm = 0
        w.subjectFollowHz = 0
        return w
    }
    let oldMean = vs3Late(old.values)
    let newMean = vs3Late(new.values)
    let stillMax = still.values.max() ?? 99
    vcheck(newMean >= 0.95 * oldMean && oldMean >= 20 && stillMax <= 3 && !(new.locked.last ?? true),
           "动作调优（M2）：没骨架的慢速不规则真插入不被 gentle 压（92681ea \(Int(oldMean)) / 调优 \(Int(newMean))）；"
           + "完全没节奏的静止画面照样压（最高 \(String(format: "%.1f", stillMax))）")
}

do {
    // M3：边缘清楚、里面很平滑的一块皮肤（圆盘，中间圆顶的明暗梯度 < 4）每帧往右移 2.5 像素：
    // 噪声防护开着时里面的平滑块靠旁边在动的边缘块采用法向流，和关着时差不多；到处闪烁的平面照样 0
    func disk(_ cx: Double) -> [UInt8] {
        var f = [UInt8](repeating: 60, count: 64 * 36)
        let r0 = 14.0
        for y in 0..<36 {
            for x in 0..<64 {
                let dx = Double(x) - cx
                let dy = Double(y) - 18
                let r2 = dx * dx + dy * dy
                if r2 < r0 * r0 { f[y * 64 + x] = UInt8(120 + 20 * (1 - r2 / (r0 * r0))) }
            }
        }
        return f
    }
    let prev = disk(28)
    let cur = disk(30.5)
    func run(_ guardOn: Bool) -> BlockMotionResult {
        var e = BlockMotionEstimator()
        e.noiseGuard = guardOn
        return cur.withUnsafeBufferPointer { c in
            prev.withUnsafeBufferPointer { p in e.estimate(cur: c, prev: p, width: 64, height: 36, gap: vsDt) }
        }
    }
    let off = run(false)
    let on = run(true)
    vcheck(on.movingBlocks >= off.movingBlocks - 1 && on.speed >= 0.8 * off.speed && on.movingBlocks >= 3,
           "动作调优（M3）：平滑皮肤真的在动时噪声防护不丢运动（关 \(off.movingBlocks) 块 \(String(format: "%.2f", off.speed)) / "
           + "开 \(on.movingBlocks) 块 \(String(format: "%.2f", on.speed))）")
}

do {
    // L2：轻抚中手离开胸口、画面开始大幅动（主体 0.8）/ 髋开始往复：这一拍就放开轻抚
    for variant in ["strong", "hips"] {
        var ac = atSettle { atChestWindow(time: $0, chest: true, region: true) }
        let was = ac.kind == .caress
        var w = atChestWindow(time: 13, chest: false, region: true)
        if variant == "strong" {
            w.subjectScore = 0.8
        } else {
            w.context.body.hips.follow = StrokeRhythm.FollowEstimate(hz: 1.2, confidence: 0.8, amplitude: 0.2, sampleRate: 9)
        }
        _ = ac.refine(w, now: 13)
        vcheck(was && ac.kind != .caress && ac.intensityCeiling == nil && !ac.suppressesRhythm,
               "动作调优（L2）：轻抚中手离开胸口且\(variant == "strong" ? "画面大幅动" : "髋开始往复")：当拍放开（\(ac.kind)）")
    }
}

// MARK: - rhythm-action tune R3：轻抚依据的频率一致放宽；归给自己的手要安静

/// 摸胸口的窗口，但姿态手腕（和手检测）的频率是 wristHz，块运动 / 区域 / 姿态读数是 refHz（两个估计对不上 / 一个减半）
func atCaressHzWindow(time: Double, wristHz: Double, refHz: Double) -> MotionWindow {
    var w = atChestWindow(time: time, chest: true, region: true)
    w.subjectHz = refHz
    w.subjectFollowHz = refHz
    w.poseRhythmHz = refHz
    w.roi.region.hz = refHz
    var rh = PartRhythm()
    rh.follow = StrokeRhythm.FollowEstimate(hz: wristHz, confidence: 0.8, amplitude: 0.08, sampleRate: 9)
    w.context.hand.rhythm = rh
    w.context.body.wrists = rh
    w.context.body.rightWristRhythm = rh.follow
    return w
}

// R3 的检查都放在函数里：顶层 do 块的局部变量都算在 main 的栈帧里，main 已经接近 8 MB 栈上限
func atCaressHzCheck() {
    // H3：慢慢摸胸口，手腕 1.0 Hz / 画面 1.25 Hz（差 25%），手腕减半（0.6 / 1.2）、画面减半（1.25 / 0.625）：照样认轻抚、输出 ≤ 20
    var ok = true
    var notes: [String] = []
    for (wristHz, refHz) in [(1.0, 1.25), (0.6, 1.2), (1.25, 0.625)] {
        var strict = PartRhythm()
        strict.follow = StrokeRhythm.FollowEstimate(hz: wristHz, confidence: 0.8, amplitude: 0.08, sampleRate: 9)
        // 严的 ±15% 下这只手的依据是 0（这几组确实对不上）
        let strictZero = ActionContext.support(strict, x: 33, y: 12, size: 8, refHz: refHz, region: nil,
                                               frameWidth: 64, frameHeight: 36) == 0
        let run = atRun(tuned: true, context: true) { atCaressHzWindow(time: $0, wristHz: wristHz, refHz: refHz) }
        let ac = atSettle { atCaressHzWindow(time: $0, wristHz: wristHz, refHz: refHz) }
        let peak = run.out.suffix(15).map { $0.max() ?? 0 }.max() ?? 99
        let fine = strictZero && run.kinds.last == .caress && ac.kind == .caress && ac.suppressesRhythm
            && run.locked.suffix(10).allSatisfy { !$0 } && peak <= 20
        ok = ok && fine
        notes.append("\(wristHz)/\(refHz): \(ac.kind) 峰 \(peak) 锁 \(run.locked.last ?? true)")
    }
    vcheck(ok, "动作调优 R3（H3）：手腕 / 画面频率差 25% 或差一个八度时摸胸口照样认轻抚、不跟节奏、输出 ≤ 20（\(notes)）")

    // 放宽只到 ±35% / 八度 ±15%：锁在 1.67 倍（2.0 / 1.2）仍算锁在别的频率上（不认轻抚）
    var lockedElse = ActionContext()
    var t = 10.0
    while t < 13 {
        _ = lockedElse.refine(atChestWindow(time: t, chest: true, region: true), now: t, followerHz: 2.0)
        t += 0.3
    }
    vcheck(lockedElse.kind != .caress && !lockedElse.allowsGentle(followerLocked: true),
           "动作调优 R3（H3）：放宽后跟随器锁在 1.67 倍频率上仍不认轻抚（\(lockedElse.kind)）")
}
atCaressHzCheck()

/// 别人给被认到的人撸（1.5 Hz、手检测在胯上），被撸的人右手放在小腹上不动、离撸动的手 5 像素（0.3 个身体尺度）
func atPartnerHandjobWindow(time: Double) -> MotionWindow {
    var w = atChestWindow(time: time, chest: true)
    w.subjectHz = 1.5
    w.subjectFollowHz = 1.5
    w.poseRhythmHz = 1.5
    var stroke = PartRhythm()
    stroke.follow = StrokeRhythm.FollowEstimate(hz: 1.5, confidence: 0.8, amplitude: 0.2, sampleRate: 9)
    w.context.body.rightWristX = 33
    w.context.body.rightWristY = 16
    w.context.body.rightWristRhythm = StrokeRhythm.FollowEstimate()
    w.context.body.wristX = 33
    w.context.body.wristY = 16
    w.context.body.wrists = PartRhythm()
    w.context.hand.x = 33
    w.context.hand.y = 21
    w.context.hand.rhythm = stroke
    w.roi.region = atRegion(x: 33, y: 21, time: time - 0.05, hz: 1.5)
    return w
}

func atPartnerHandjobCheck() {
    // H2：手检测落在别人撸动的手上、离被撸的人放着的手腕很近：不能归给自己（以前 → quietSelf：不跟节奏 + gentle 压）
    let w0 = atPartnerHandjobWindow(time: 10)
    let near = ActionContext.selfTouch(w0.context.body).map {
        (($0.x - w0.context.hand.x) * ($0.x - w0.context.hand.x) + ($0.y - w0.context.hand.y) * ($0.y - w0.context.hand.y))
            .squareRoot() <= ActionContext.selfHandReach * w0.context.body.scale
    } ?? false
    let ac = atSettle { atPartnerHandjobWindow(time: $0) }
    let base = atRun(tuned: false, context: false) { atPartnerHandjobWindow(time: $0) }
    let new = atRun(tuned: true, context: true) { atPartnerHandjobWindow(time: $0) }
    let baseMean = vs3Late(base.values)
    let newMean = vs3Late(new.values)
    let baseThrust = Double(base.out.suffix(15).map { $0[0] }.reduce(0, +)) / 15
    let newThrust = Double(new.out.suffix(15).map { $0[0] }.reduce(0, +)) / 15
    vcheck(near && ac.kind == .stroke && ac.usesHand && !ac.suppressesRhythm && ac.intensityCeiling == nil
           && ac.evidence.caress == 0 && !ac.allowsGentle(followerLocked: false)
           && !new.kinds.contains(.caress) && new.locked.last == true
           && newMean >= 0.95 * baseMean && newThrust >= 0.9 * baseThrust,
           "动作调优 R3（H2）：别人撸、被撸的人手放小腹（离撸的手 0.3 尺度）→ 撸动（看手），不是轻抚 / 只来自自己的手；"
           + "强度 \(Int(baseMean)) → \(Int(newMean))、伸缩 \(Int(baseThrust)) → \(Int(newThrust))（\(ac.kind)）")
}
atPartnerHandjobCheck()

/// 骑乘、手放自己胸口、髋出画：头 / 肩 / 两腕整个上身一起 1.2 Hz 上下（幅度 0.25 躯干），右手腕贴在胸口，左手垂在身侧。
/// 真的跑 PoseMotionTracker（调优开），每拍把它的 bodyContext 放进胸口窗口（区域就在胸口，最容易误认轻抚）
func atRidingRun(tuned: Bool, context: Bool) -> (run: ATRun, body: PoseBodyContext) {
    var tracker = PoseMotionTracker()
    tracker.actionTuned = true
    tracker.contextEnabled = true
    let torso = 13.0  // 1.3 × 肩宽 10
    var poseT = 99.0
    var i = 0
    let run = atRun(tuned: tuned, context: context) { now in
        while poseT + 1.0 / 9 <= now - 0.05 {
            poseT += 1.0 / 9
            let dy = 0.25 * torso * sin(2 * Double.pi * 1.2 * poseT)
            var p = PoseCandidate()
            p.confidence = 0.9
            for (j, x, y) in [(PoseJoint.nose, 32.0, 4.0), (.neck, 32, 8), (.leftShoulder, 27, 10), (.rightShoulder, 37, 10),
                              (.rightWrist, 33, 14), (.leftWrist, 24, 19)] {
                p.set(j, x: x, y: y + dy, confidence: 0.9)
            }
            _ = tracker.update(time: poseT, candidates: [vs3Jittered(p, i: i, sigma: 0.1)], camera: .identity,
                               continuous: true, frameHeight: 36)
            i += 1
        }
        var w = atChestWindow(time: now, chest: true, region: true)
        w.context.time = tracker.bodyContext.time
        w.context.body = tracker.bodyContext
        w.context.hand = PartReading()
        w.roi.region = atRegion(x: 33, y: 13, time: now - 0.05, hz: 1.2)
        return w
    }
    return (run, tracker.bodyContext)
}

func atRidingCheck() {
    // H1：手跟着上身一起往复。扣过全身中位速度的手腕节奏只剩 ~40%（看起来像安静的手 → 以前认成轻抚、封顶 20）；
    // 没扣的看得出来 → 不是轻抚、不封顶、照常跟节奏
    let base = atRidingRun(tuned: false, context: false)
    let new = atRidingRun(tuned: true, context: true)
    let bc = new.body
    let residualAmp = bc.rightWristRhythm.amplitude
    let rawAmp = bc.rightWristRaw.amplitude
    let touch = ActionContext.selfTouch(bc)
    let repro = touch != nil && ActionContext.quietTouch(PartRhythm(follow: bc.rightWristRhythm))
        && !ActionContext.quietTouch(PartRhythm(follow: bc.rightWristRaw))
    let baseMean = vs3Late(base.run.values)
    let newMean = vs3Late(new.run.values)
    let newPeak = new.run.out.suffix(15).map { $0.max() ?? 0 }.max() ?? 0
    vcheck(repro && !new.run.kinds.contains(.caress) && new.run.locked.last == true && newPeak > 20
           && newMean >= 0.95 * baseMean,
           "动作调优 R3（H1）：骑乘手放胸口、髋出画（上身整体 1.2 Hz、0.25 躯干）：扣过的手腕幅度 "
           + "\(String(format: "%.3f", residualAmp)) / 没扣的 \(String(format: "%.3f", rawAmp)) → 不认轻抚、不封顶"
           + "（强度 \(Int(baseMean)) → \(Int(newMean))，峰 \(newPeak)，锁 \(new.run.locked.last ?? false)，kinds \(Set(new.run.kinds.map { $0.rawValue }))）")
}
atRidingCheck()

func atPoseCapRhythmCheck() {
    // M1：低纹理近景里的真插入：块运动只有 0.1，姿态 0.7 且髋的节奏置信度 0.8 → 姿态上界不压（和关着一样）；
    // 同样的窗口没有姿态节奏（关键点抖动）→ 照样压
    func run(tuned: Bool, rhythmic: Bool) -> Double {
        var c = VSChain()
        c.normalizer.actionTuned = tuned
        var out: [Double] = []
        for _ in 0..<60 {
            var w = MotionWindow(meanEnergy: 2, peakEnergy: 2, frames: 5, cutCount: 0, heldCount: 0)
            w.subjectFrames = 5
            w.subjectScore = 0.1
            w.subjectFollowHz = 1.5
            w.subjectFollowRhythm = 0.5
            w.poseFrames = 3
            w.posePresentFrames = 3
            w.poseScore = 0.7
            w.poseConfidence = 0.8
            w.poseTrust = 1
            if rhythmic {
                w.poseRhythmHz = 1.5
                w.poseRhythmConfidence = 0.8
                w.poseRhythmPart = 1
                w.poseRhythmRate = 9
            }
            out.append(c.step(w))
        }
        return vs3Late(out)
    }
    let old = run(tuned: false, rhythmic: true)
    let new = run(tuned: true, rhythmic: true)
    let jitter = run(tuned: true, rhythmic: false)
    vcheck(new >= 0.95 * old && old >= 40 && jitter <= 0.6 * old,
           "动作调优 R3（M1）：块运动 0.1 + 姿态 0.7、髋节奏可信 → 姿态上界不压（关 \(Int(old)) / 开 \(Int(new))）；"
           + "没有姿态节奏时照样压（\(Int(jitter))）")
}
atPoseCapRhythmCheck()

func atPartialMovingCheck() {
    // M2：只认到髋 / 膝的近景里慢慢往复：髋 0.8 Hz、0.15 躯干（躯干 = 髋宽 × 2 = 32 像素），膝跟着 0.3 倍，
    // 约 9 Hz 姿态采样、关键点抖 0.3 像素；关节置信度 0.3 / 0.5 → 髋的节奏还在（死区加倍随髋节奏撤回）
    func run(confidence: Double) -> PoseReading {
        var tracker = PoseMotionTracker()
        tracker.actionTuned = true
        tracker.contextEnabled = true
        var last = PoseReading()
        var i = 0
        for k in 0..<Int(14 * 15) where k % 5 == 0 || k % 5 == 2 || k % 5 == 4 {
            let t = Double(k) * vsDt
            let d = 0.15 * 32 * sin(2 * Double.pi * 0.8 * t)
            var p = atPartialHips(confidence: confidence)
            p.y[PoseJoint.leftHip.rawValue] += d
            p.y[PoseJoint.rightHip.rawValue] += d
            p.y[PoseJoint.leftKnee.rawValue] += 0.3 * d
            p.y[PoseJoint.rightKnee.rawValue] += 0.3 * d
            last = tracker.update(time: t, candidates: [vs3Jittered(p, i: i, sigma: 0.3)], camera: .identity,
                                  continuous: true, frameHeight: 36)
            i += 1
        }
        return last
    }
    var ok = true
    var notes: [String] = []
    for c in [0.3, 0.5] {
        let r = run(confidence: c)
        ok = ok && r.present && r.rhythmPart == 1 && abs(r.rhythmHz - 0.8) <= 0.1 && r.rhythmConfidence >= 0.4
        notes.append("置信度 \(c)：第 \(r.rhythmPart) 组 \(String(format: "%.2f", r.rhythmHz)) Hz "
                     + "\(String(format: "%.2f", r.rhythmConfidence))")
    }
    vcheck(ok, "动作调优 R3（M2）：部分骨架慢慢往复（0.8 Hz、0.15 躯干）髋的节奏不被加倍的死区吃掉（\(notes)）")
}
atPartialMovingCheck()

// MARK: - rhythm-lookahead P4：前瞻（另开一路解码提前读后面的画面，默认关）

/// P4 合成画面：有纹理的静止背景 + 一块带纹理的主体按 ox = sign · amp(t) · sin Φ(t) 水平往复（向右为正，位移相位真值 = Φ − 90°）
struct P4Scene {
    var phase: (Double) -> Double
    var amp: (Double) -> Double = { _ in 4 }
    var sign: Double = 1

    func frame(_ t: Double) -> LumaFrame {
        let ox = sign * amp(t) * sin(phase(t))
        var px = [UInt8](repeating: 0, count: 64 * 36)
        for y in 0..<36 {
            for x in 0..<64 {
                let qx = Double(x) + 0.5
                let qy = Double(y) + 0.5
                let v: Double
                if qx >= 22 + ox, qx < 40 + ox, qy >= 10, qy < 26 {
                    v = vs3Value(qx - ox + 100, qy + 100, salt: 2)
                } else {
                    v = vs3Value(qx + 200, qy + 200, salt: 1)
                }
                px[y * 64 + x] = UInt8(min(255, max(0, v.rounded())))
            }
        }
        return LumaFrame(width: 64, height: 36, pixels: px)
    }
}

/// 频率阶跃 f0 → f1（at 秒处，相位连续）
func p4StepPhase(_ f0: Double, _ f1: Double, at s: Double) -> (Double) -> Double {
    { t in t < s ? 2 * Double.pi * f0 * t : 2 * Double.pi * (f0 * s + f1 * (t - s)) }
}

struct P4Run {
    var times: [Double] = []
    var p2Hz: [Double] = []
    var p4Hz: [Double] = []
    var p2Locked: [Bool] = []
    var p4Locked: [Bool] = []
    var p2Err: [Double?] = []
    var p4Err: [Double?] = []
    var states: [RhythmLookahead.State] = []
    var leads: [Double] = []
    var sameWindows = true
    var phaseSubstituted = 0
    var p2LockWeightAfterStop: [Double] = []
    var p4LockWeightAfterStop: [Double] = []
    var p4FollowerLockedAfterStop: [Bool] = []
    var p2FollowerLockedAfterStop: [Bool] = []
    var la = RhythmLookahead()
}

/// 实时（P2）和前瞻（P4）两条链吃同一段画面：实时分析器 15 Hz、每 5 帧一个完整拍；前瞻分析器提前读到「现在 + horizon」。
/// look：前瞻那边看到的画面（默认同一个）；offset：播放器报的视频时间比真实的多多少（模拟时间轴对不上）；
/// active：画面在不在动（RhythmOutput.motionActivity > 0）；latency：延迟补偿（秒）
func p4Run(_ scene: P4Scene, look: P4Scene? = nil, seconds: Double = 24, latency: Double = 0.2, horizon: Double = 3,
           offset: Double = 0, active: (Double) -> Bool = { _ in true }, truthPhase: ((Double) -> Double)? = nil,
           stopAt: Double? = nil) -> P4Run {
    var rt = MotionAnalyzer()
    rt.phaseFitEnabled = true
    var la = MotionAnalyzer()
    la.phaseFitEnabled = true
    var acc = MotionWindowAccumulator()
    var timeline = LookaheadTimeline()
    timeline.restart(at: 0)
    let lookScene = look ?? scene
    var f2 = RhythmFollower()
    var f4 = RhythmFollower()
    var l2 = RhythmPhaseLock()
    var l4 = RhythmPhaseLock()
    var r = P4Run()
    let frames = Int(seconds * 15)
    var kb = 0
    let truth = truthPhase ?? { scene.phase($0) - Double.pi / 2 }
    for k in 0..<frames {
        let t = Double(k) * vsDt
        if let s = rt.analyze(scene.frame(t), time: t) { acc.add(s) }
        guard k % 5 == 4 else { continue }
        let now = t + 0.01
        while kb < frames, Double(kb) * vsDt <= now + horizon {
            let tb = Double(kb) * vsDt
            if let s = la.analyze(lookScene.frame(tb), time: tb) { timeline.append(s) }
            kb += 1
        }
        timeline.prune(playhead: now)
        let w = acc.drain()
        let act = active(now)
        let clock = RhythmLookahead.Clock(hostNow: now, itemNow: now + offset, rate: 1)
        let input = r.la.refine(w, timeline: timeline, clock: clock, latency: latency)
        if input == w { } else { r.sameWindows = false }
        if r.la.phaseEngaged { r.phaseSubstituted += 1 }
        f2.step(w, dt: 5.0 / 15, active: act)
        f4.step(input, dt: 5.0 / 15, active: act)
        l2.step(w, followerHz: f2.hz, followerLocked: f2.locked, followerSource: f2.source, now: now, dt: 5.0 / 15, active: act)
        l4.step(input, followerHz: f4.hz, followerLocked: f4.locked, followerSource: f4.source, now: now, dt: 5.0 / 15, active: act)
        let lead = r.la.stepLead(timeline: timeline, clock: clock, latency: latency, lockOmega: l4.omega,
                                 lockWeight: l4.weight, dt: 5.0 / 15)
        r.times.append(now)
        r.p2Hz.append(f2.hz)
        r.p4Hz.append(f4.hz)
        r.p2Locked.append(l2.locked)
        r.p4Locked.append(l4.locked)
        r.p2Err.append(l2.phase(at: now + latency).map { p2Err($0, truth(now + latency)) })
        r.p4Err.append(l4.phase(at: now + latency).map { p2Err($0 + lead, truth(now + latency)) })
        r.states.append(r.la.state)
        r.leads.append(lead)
        if let s = stopAt, now >= s {
            r.p2LockWeightAfterStop.append(l2.weight)
            r.p4LockWeightAfterStop.append(l4.weight)
            r.p2FollowerLockedAfterStop.append(f2.locked)
            r.p4FollowerLockedAfterStop.append(f4.locked)
        }
    }
    return r
}

func p4Deg(_ x: Double) -> String { String(format: "%.0f", x * 180 / Double.pi) }

/// 手搭一帧前瞻样本（视频时间 t，位移相位 phase、频率 hz）
func p4Sample(_ t: Double, hz: Double, phase: Double, quality: Double = 0.9, cut: Bool = false, held: Bool = false,
              followHz: Double? = nil, epoch: Int = 0) -> MotionSample {
    var s = MotionSample(time: t, energy: 5, coverage: 0.2, isCut: cut, isHeld: held)
    s.subject = SubjectReading(valid: true, score: 0.5, speed: 2, hz: hz, rhythm: 0.8, amplitude: 3,
                               followHz: followHz ?? hz, followRhythm: 0.8, followAmplitude: 3,
                               phase: StrokeRhythm.PhaseFit(time: t, phase: StrokeRhythm.wrapPhase(phase), hz: hz,
                                                            quality: quality, linearity: 0.95, amplitude: 3, epoch: epoch,
                                                            axisX: 1, axisY: 0))
    return s
}

/// 解析前瞻：0~to 秒，15 Hz，相位 = 2π·hz·t + φ0
func p4Analytic(hz: Double, to end: Double, phase0: Double = 0.3, from start: Double = 0) -> LookaheadTimeline {
    var tl = LookaheadTimeline()
    tl.restart(at: start)
    var k = 0
    while Double(k) * vsDt + start <= end {
        let t = start + Double(k) * vsDt
        tl.append(p4Sample(t, hz: hz, phase: 2 * Double.pi * hz * t + phase0))
        k += 1
    }
    return tl
}

do {
    // 时间轴：追加 / 时间不前进丢掉 / 切镜和断档换段 / 保持期不带读数 / 播放头前 5 秒以前丢掉 / 容量
    var tl = LookaheadTimeline()
    tl.restart(at: 0)
    for k in 0..<30 { tl.append(p4Sample(Double(k) * vsDt, hz: 1, phase: 0)) }
    tl.append(p4Sample(1.0, hz: 1, phase: 0))  // 倒退：丢掉
    let n30 = tl.records.count
    let seg0 = tl.segment
    tl.append(p4Sample(2.0, hz: 1, phase: 0, cut: true))
    tl.append(p4Sample(2.0 + vsDt, hz: 1, phase: 0, held: true))
    tl.append(p4Sample(3.0, hz: 1, phase: 0))  // 断档 > 0.5 秒
    let cutRec = tl.records[30]
    let heldRec = tl.records[31]
    vcheck(n30 == 30 && cutRec.segment == seg0 + 1 && heldRec.segment == seg0 + 1 && tl.records[32].segment == seg0 + 2
           && cutRec.followHz == 0 && !cutRec.phase.isValid && heldRec.followHz == 0 && !heldRec.phase.isValid
           && tl.segment(at: 1.0) == seg0 && tl.segment(at: 2.05) == seg0 + 1 && tl.segment(at: 2.6) == nil
           && tl.causal(at: 0.99)?.time == 14 * vsDt && tl.reach(from: 0.5) == 29 * vsDt,
           "P4 前瞻时间轴：倒退的帧丢掉；切镜 / 断档换段；切镜和保持期的帧不带频率 / 相位；按段查到能读多远")
    var big = LookaheadTimeline()
    big.restart(at: 0)
    for k in 0..<500 { big.append(p4Sample(Double(k) * vsDt, hz: 1, phase: 0)) }
    let capOK = big.records.count == LookaheadTimeline.capacity && big.records.last?.time == 499 * vsDt
    big.prune(playhead: 30)
    vcheck(capOK && big.first >= 25 - 1e-9 && big.first < 25 + vsDt && big.head == 499 * vsDt,
           "P4 前瞻时间轴：最多 \(LookaheadTimeline.capacity) 帧（丢最旧的）；播放头之前 5 秒以前的丢掉")
    var re = big
    re.restart(at: 40)
    vcheck(re.isEmpty && re.segment == big.segment + 1 && re.origin == 40 && re.reach(from: 40) == nil
           && re.centeredPhase(at: 40) == nil && re.centeredFollow(at: 40) == nil,
           "P4 前瞻时间轴：重新开读清空、换段，没读到时什么都查不到")
}

do {
    // 居中相位：1 Hz / 2 Hz 解析读数，现在这一刻的相位对得上；读到的不够远（< 四分之一窗口）不给；代次不同不混；居中频率往后看 2 秒
    var worst = 0.0
    for hz in [0.5, 1.0, 2.0, 2.4] {
        let tl = p4Analytic(hz: hz, to: 20)
        for v in stride(from: 8.0, through: 15, by: 0.37) {
            guard let c = tl.centeredPhase(at: v) else { worst = .infinity; continue }
            worst = max(worst, p2Err(c.phase, 2 * Double.pi * hz * v + 0.3))
            if !(abs(c.hz - hz) < 1e-9 && c.coherence > 0.99 && c.centering > 0.9 && c.quality > 0.85) { worst = .infinity }
        }
    }
    let short = p4Analytic(hz: 1, to: 10.2)
    let atEdge = short.centeredPhase(at: 10.0)
    let okFar = short.centeredPhase(at: 9.6)
    var mixed = LookaheadTimeline()
    mixed.restart(at: 0)
    for k in 0..<300 {
        let t = Double(k) * vsDt
        let flipped = t >= 10.5
        mixed.append(p4Sample(t, hz: 1, phase: 2 * Double.pi * t + 0.3 + (flipped ? Double.pi : 0), epoch: flipped ? 1 : 0))
    }
    let m = mixed.centeredPhase(at: 10)
    let tl = p4Analytic(hz: 1, to: 20)
    let follow = tl.centeredFollow(at: 8)
    vcheck(worst <= 1e-6 && atEdge == nil && okFar != nil && m != nil && m.map { p2Err($0.phase, 2 * Double.pi * 10 + 0.3 + ($0.epoch == 1 ? Double.pi : 0)) <= 1e-6 } == true
           && follow.map { abs($0.lead - 2) < vsDt && $0.hz == 1 } == true,
           "P4 居中相位：0.5~2.4 Hz 现在这一刻的相位逐点对上；读到的不够远时不给；主轴代次不同的不混在一起；居中频率往后看 2 秒")

    // 居中频率：段开头不满 4 秒时没有频率 = 还没攒够（nil，不代入）；满了没有 = 真没节奏（0）
    var warm = LookaheadTimeline()
    warm.restart(at: 0)
    for k in 0..<150 { warm.append(p4Sample(Double(k) * vsDt, hz: 1, phase: 0, followHz: 0)) }
    vcheck(warm.centeredFollow(at: 0.5) == nil && warm.centeredFollow(at: 3).map { $0.hz == 0 } == true,
           "P4 居中频率：段开头还没攒满一个节奏窗口时不给（实时照用），攒满了还没有才算「没有节奏」")
}

do {
    // 关着 / 没读到 / 没核对过：窗口原样（逐位相同），提前量 0；相位偏移 = 撞击声校正本身（逐位相同）
    var la = RhythmLookahead()
    let empty = LookaheadTimeline()
    var same = true
    var anchorSame = true
    for i in 0..<3000 {
        var w = plWindow(time: Double(i) * 0.3, hz: 0.5 + vsRandom() * 2, noise: vsRandom(), frames: Int(vsRandom() * 6),
                         valid: vsRandom() < 0.8, cut: vsRandom() < 0.05)
        w.subjectFollowHz = vsRandom() < 0.2 ? 0 : 0.4 + vsRandom() * 3
        w.subjectFollowRhythm = vsRandom()
        w.heldCount = vsRandom() < 0.05 ? 1 : 0
        let clock = RhythmLookahead.Clock(hostNow: Double(i) * 0.3, itemNow: vsRandom() < 0.05 ? .nan : Double(i) * 0.3,
                                          rate: vsRandom() < 0.05 ? 0 : 1)
        let out = la.refine(w, timeline: empty, clock: clock, latency: 0.2)
        let lead = la.stepLead(timeline: empty, clock: clock, latency: 0.2, lockOmega: 2 * Double.pi, lockWeight: vsRandom(), dt: 0.3)
        same = same && out == w && lead == 0 && !la.phaseEngaged && !la.frequencyEngaged
        let a = (vsRandom() - 0.5) * 7
        anchorSame = anchorSame && RhythmLookahead.phaseOffset(anchor: a, lead: 0).bitPattern == a.bitPattern
    }
    vcheck(same && anchorSame && la.state == .waiting && RhythmLookahead().lead == 0,
           "P4 关着 / 没读到：3000 个随机窗口原样交回、提前量 0，相位偏移和撞击声校正逐位相同")

    // 读到了但还没核对上：原样
    let tl = p4Analytic(hz: 1, to: 20)
    var fresh = RhythmLookahead()
    let w = plWindow(time: 10, hz: 1)
    let out = fresh.refine(w, timeline: tl, clock: .init(hostNow: 10, itemNow: 10, rate: 1), latency: 0.2)
    vcheck(out == w && fresh.state == .checking, "P4 还没核对上（实时窗口没有跟随频率）：窗口原样")
}

do {
    // 端到端（稳态 1 Hz）：两条时间轴一致 → 核对通过、方向同向、频率和相位都代入；指令相位误差不比实时差
    let scene = P4Scene(phase: { 2 * Double.pi * $0 })
    let r = p4Run(scene)
    let late = r.times.indices.filter { r.times[$0] >= 12 }
    let p2 = late.compactMap { r.p2Err[$0] }
    let p4 = late.compactMap { r.p4Err[$0] }
    let p2Mean = p2.reduce(0, +) / Double(max(1, p2.count))
    let p4Mean = p4.reduce(0, +) / Double(max(1, p4.count))
    let engaged = late.filter { r.states[$0] == .engaged }.count
    vcheck(r.la.verified && r.la.flip == false && engaged >= late.count - 2 && p4.count == late.count
           && (p4.max() ?? 9) <= 0.4 && p4Mean <= p2Mean + 0.05 && late.allSatisfy { abs(r.leads[$0]) <= 0.15 },
           "P4 端到端 1 Hz：核对通过、同向，\(engaged)/\(late.count) 拍频率和相位都按前瞻；指令相位误差平均 \(p4Deg(p4Mean))°"
           + "（实时 \(p4Deg(p2Mean))°）、最大 \(p4Deg(p4.max() ?? 9))°，稳态提前量 ≈ 0")
}

do {
    // 端到端（频率阶跃 1 → 1.6 Hz）：前瞻比实时更早跟上新频率、更早重新对上相位
    let scene = P4Scene(phase: p4StepPhase(1, 1.6, at: 12))
    let r = p4Run(scene, seconds: 24)
    func reached(_ hz: [Double]) -> Double {
        for i in r.times.indices where r.times[i] >= 9 {
            if (i..<r.times.count).allSatisfy({ abs(hz[$0] - 1.6) <= 0.16 }) { return r.times[i] }
        }
        return 99
    }
    func settled(_ err: [Double?]) -> Double {
        for i in r.times.indices where r.times[i] >= 11 {
            let rest = (i..<r.times.count).filter { r.times[$0] <= r.times[i] + 2 }
            if rest.allSatisfy({ (err[$0] ?? 9) <= 0.6 }) { return r.times[i] }
        }
        return 99
    }
    let p2Reach = reached(r.p2Hz)
    let p4Reach = reached(r.p4Hz)
    let p2Settle = settled(r.p2Err)
    let p4Settle = settled(r.p4Err)
    vcheck(p4Reach <= p2Reach - 0.9 && p4Reach <= 13.5 && p4Settle <= p2Settle - 0.6 && p4Settle <= 14.5
           && r.leads.allSatisfy { abs($0) <= RhythmLookahead.maxLead + 1e-9 },
           "P4 端到端 1→1.6 Hz（12 秒处）：频率跟上 \(String(format: "%.1f", p4Reach)) 秒（实时 \(String(format: "%.1f", p2Reach))），"
           + "相位重新对上 \(String(format: "%.1f", p4Settle)) 秒（实时 \(String(format: "%.1f", p2Settle))）；提前量全程 ≤ 60°")
}

do {
    // 动作停了：前瞻还看得到旧节奏，但「画面不动」照样 2 拍内放开（和实时同一规则、同一时刻）；动作开始前不因前瞻提前锁
    let scene = P4Scene(phase: { 2 * Double.pi * $0 }, amp: { $0 < 16 ? 4 : 0 })
    let r = p4Run(scene, seconds: 20, active: { $0 < 16.05 }, stopAt: 16.05)
    let p4Released = r.p4FollowerLockedAfterStop.dropFirst(2).allSatisfy { !$0 }
        && r.p4LockWeightAfterStop.dropFirst(1).allSatisfy { $0 == 0 }
    vcheck(p4Released && r.p4FollowerLockedAfterStop == r.p2FollowerLockedAfterStop
           && r.p4LockWeightAfterStop.dropFirst(1).elementsEqual(r.p2LockWeightAfterStop.dropFirst(1)),
           "P4 动作停了：前瞻里还有旧节奏，频率跟随 / 相位锁照样和实时同一拍放开（相位锁 weight 归 0）")
    let start = P4Scene(phase: { 2 * Double.pi * $0 }, amp: { $0 < 8 ? 0 : 4 })
    let s = p4Run(start, seconds: 16, active: { $0 >= 8.3 })
    let early = s.times.indices.filter { s.times[$0] < 8.3 }.contains { s.p4Locked[$0] || s.p4Hz[$0] > 0 }
    let later = s.times.indices.filter { s.times[$0] >= 12 }.allSatisfy { s.p4Locked[$0] }
    vcheck(!early && later, "P4 动作开始前（画面不动）：前瞻已经看到后面的节奏也不提前锁；开始动以后照常锁上")
}

do {
    // 两条时间轴对不上：① 前瞻看到的是别的画面（1.4 Hz vs 1 Hz）→ 判「对不上」、窗口一直原样（频率跟随 / 相位锁和实时逐位相同）；
    // ② 播放器时间偏 0.25 秒（1 Hz 下相位差 90°）→ 频率核对通过，但方向一直认不出，相位不代入
    let real = P4Scene(phase: { 2 * Double.pi * $0 })
    let other = P4Scene(phase: { 2 * Double.pi * 1.4 * $0 })
    let mis = p4Run(real, look: other, seconds: 20)
    let late = mis.times.indices.filter { mis.times[$0] >= 10 }
    vcheck(mis.sameWindows && late.allSatisfy { mis.states[$0] == .mismatch || mis.states[$0] == .checking }
           && late.contains { mis.states[$0] == .mismatch } && mis.p4Hz == mis.p2Hz && mis.p4Locked == mis.p2Locked
           && mis.leads.allSatisfy { $0 == 0 },
           "P4 前瞻是别的画面（1.4 vs 1 Hz）：判对不上，窗口全程原样，频率跟随 / 相位锁和只用实时逐位相同")
    let shifted = p4Run(real, seconds: 20, offset: 0.25)
    vcheck(shifted.phaseSubstituted == 0 && shifted.la.flip == nil && shifted.la.verified
           && shifted.times.indices.filter { shifted.times[$0] >= 10 && shifted.times[$0] <= 19 }.allSatisfy { shifted.states[$0] == .frequencyOnly },
           "P4 时间轴偏 0.25 秒（相位差 90°）：频率照常按前瞻，方向认不出、相位一直按实时")
}

do {
    // 前瞻的主轴和实时反向（看到的画面镜像）：认出「反向」，代入的相位按实时的约定折回来，误差照样小
    let real = P4Scene(phase: { 2 * Double.pi * $0 })
    let mirrored = P4Scene(phase: { 2 * Double.pi * $0 }, sign: -1)
    let r = p4Run(real, look: mirrored, seconds: 20)
    let late = r.times.indices.filter { r.times[$0] >= 12 && r.times[$0] <= 19 }
    let err = late.compactMap { r.p4Err[$0] }
    vcheck(r.la.flip == true && late.allSatisfy { r.states[$0] == .engaged } && err.count == late.count && (err.max() ?? 9) <= 0.4,
           "P4 前瞻主轴反向：认成反向，折回实时约定后指令相位误差 ≤ \(p4Deg(err.max() ?? 9))°")
}

do {
    // 切镜：那一拍窗口原样、方向作废；保持期原样
    let tl = p4Analytic(hz: 1, to: 13)
    var la = RhythmLookahead()
    for i in 0..<20 {
        let t = 3 + Double(i) * 0.3
        var w = plWindow(time: t - 0.05, hz: 1)
        w.subjectFollowHz = 1
        w.subjectFollowRhythm = 0.8
        w.subjectFollowAmplitude = 3
        _ = la.refine(w, timeline: tl, clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.2)
    }
    let engagedBefore = la.state == .engaged && la.flip == false
    var cutW = plWindow(time: 9, hz: 1, cut: true)
    cutW.subjectFollowHz = 1
    let cutOut = la.refine(cutW, timeline: tl, clock: .init(hostNow: 9.05, itemNow: 9.05, rate: 1), latency: 0.2)
    let flipAfterCut = la.flip
    var held = plWindow(time: 9.3, hz: 1)
    held.heldCount = 1
    held.subjectFollowHz = 1
    let heldOut = la.refine(held, timeline: tl, clock: .init(hostNow: 9.35, itemNow: 9.35, rate: 1), latency: 0.2)
    // 复审 M2：切镜 / 保持期那两拍不核对，核对历史（同一路时间轴）保留；切镜后第一拍实时还没有节奏、前瞻同一时刻有把握有节奏
    // → 记一次不一致，最近一次不一致就不代入（窗口原样）；下一次对上才再用
    let verifiedAfterHeld = la.verified
    let noRhythm = plWindow(time: 9.6, hz: 1)  // subjectFollowHz 0
    let noRhythmOut = la.refine(noRhythm, timeline: tl, clock: .init(hostNow: 9.65, itemNow: 9.65, rate: 1), latency: 0.2)
    let afterNoRhythm = (la.verified, la.disagreements, la.state)
    var back = plWindow(time: 9.9, hz: 1)
    back.subjectFollowHz = 1
    back.subjectFollowRhythm = 0.8
    back.subjectFollowAmplitude = 3
    _ = la.refine(back, timeline: tl, clock: .init(hostNow: 9.95, itemNow: 9.95, rate: 1), latency: 0.2)
    // 方向在切镜时作废、还没重新确认：对上以后先只代入频率
    vcheck(engagedBefore && cutOut == cutW && flipAfterCut == nil && heldOut == held && verifiedAfterHeld
           && noRhythmOut == noRhythm && !afterNoRhythm.0 && afterNoRhythm.1 == 1 && afterNoRhythm.2 == .checking
           && la.verified && la.state == .frequencyOnly,
           "P4 切镜那一拍原样、方向作废（核对历史保留）；保持期原样；切镜后实时没节奏而前瞻有把握有节奏 = 不一致，"
           + "那一拍原样，下一次对上才再代入")

    // 倍速 2×：视频时间上的频率乘倍速后交给跟随器（实时看到的快慢）；相位读数时间戳是现在
    let tl2 = p4Analytic(hz: 1, to: 17, from: 4)
    var fast = RhythmLookahead()
    var out = MotionWindow()
    for i in 0..<20 {
        let t = 3 + Double(i) * 0.3
        let v = 3 + Double(i) * 0.6
        var w = MotionWindow()
        w.frames = 5
        w.subjectFrames = 5
        w.subjectScore = 0.5
        w.subjectFollowHz = 2
        w.subjectFollowRhythm = 0.8
        w.subjectFollowAmplitude = 3
        let ph = 2 * Double.pi * 1 * (v - 0.1) + 0.3
        w.subjectPhase = StrokeRhythm.PhaseFit(time: t - 0.05, phase: StrokeRhythm.wrapPhase(ph), hz: 2, quality: 0.9,
                                               linearity: 0.95, amplitude: 3, epoch: 0)
        out = fast.refine(w, timeline: tl2, clock: .init(hostNow: t, itemNow: v, rate: 2), latency: 0.2)
    }
    vcheck(fast.state == .engaged && abs(out.subjectFollowHz - 2) < 1e-9 && abs(out.subjectPhase.hz - 2) < 1e-9
           && out.subjectPhase.time == 3 + 19 * 0.3
           && p2Err(out.subjectPhase.phase, 2 * Double.pi * (3 + 19 * 0.6) + 0.3) <= 1e-6,
           "P4 倍速 2×：频率按实时看到的快慢（×2）交给跟随器，相位读数时间戳是现在、相位对上")
}

/// P4 核对用的一拍：实时窗口跟随频率 follow（0 = 实时没有节奏），t 时刻（host = 视频时间，1×）
func p4CheckBeat(_ la: inout RhythmLookahead, _ t: Double, follow: Double, timeline: LookaheadTimeline) -> (MotionWindow, MotionWindow) {
    var w = plWindow(time: t - 0.05, hz: 1)
    w.subjectFollowHz = follow
    w.subjectFollowRhythm = follow > 0 ? 0.8 : 0
    w.subjectFollowAmplitude = follow > 0 ? 3 : 0
    let out = la.refine(w, timeline: timeline, clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.2)
    return (w, out)
}

do {
    // 复审 M2：核对只看最近 8 次（一致 ≥ 3、不一致 ≤ 2、最近一次不是不一致）。
    // ① 对上过以后：最近一次不一致立刻不代入；不一致和一致交替时，最近 8 次里攒到 3 次不一致，即使这一拍对上也不代入
    //   （旧规则按累计一致次数，8 次里 4 次不一致都还算通过）
    let tl = p4Analytic(hz: 1, to: 13)
    var la = RhythmLookahead()
    var t = 3.0
    for _ in 0..<10 {
        _ = p4CheckBeat(&la, t, follow: 1, timeline: tl)
        t += 0.3
    }
    let verifiedFirst = la.verified && la.agreements == RhythmLookahead.historyLength && la.disagreements == 0
    var pattern: [Bool] = []
    var lastAgree: (MotionWindow, MotionWindow)?
    for k in 0..<6 {
        // 偶数拍 1.5 Hz（差 50% > 15%，不一致），奇数拍 1 Hz（一致）
        let beat = p4CheckBeat(&la, t, follow: k % 2 == 0 ? 1.5 : 1, timeline: tl)
        if k % 2 == 1 { lastAgree = beat }
        pattern.append(la.verified)
        t += 0.3
    }
    vcheck(verifiedFirst && pattern == [false, true, false, true, false, false]
           && la.disagreements == 3 && la.agreements == 5 && !la.mismatched && la.state == .checking
           && lastAgree.map { $0.0 == $0.1 } == true,
           "P4 核对只看最近 8 次：最近一次不一致立刻不用；8 次里第 3 次不一致后即使这一拍对上也不代入（窗口原样）"
           + "（核对通过序列 \(pattern)）")

    // ② 实时没有节奏、前瞻同一时刻置信度 ≥ 0.4 有节奏：算不一致；前瞻自己也没把握（0.2）时不算
    var noLive = RhythmLookahead()
    t = 3.0
    for _ in 0..<10 {
        _ = p4CheckBeat(&noLive, t, follow: 1, timeline: tl)
        t += 0.3
    }
    let (nw, nout) = p4CheckBeat(&noLive, t, follow: 0, timeline: tl)
    var tlLow = LookaheadTimeline()
    tlLow.restart(at: 0)
    var k = 0
    while Double(k) * vsDt <= 13 {
        let tk = Double(k) * vsDt
        var s = p4Sample(tk, hz: 1, phase: 2 * Double.pi * tk + 0.3)
        s.subject.followRhythm = 0.2
        tlLow.append(s)
        k += 1
    }
    var unsure = RhythmLookahead()
    t = 3.0
    for _ in 0..<10 {
        _ = p4CheckBeat(&unsure, t, follow: 1, timeline: tlLow)
        t += 0.3
    }
    _ = p4CheckBeat(&unsure, t, follow: 0, timeline: tlLow)
    // 节奏在这一拍真的停了：前瞻在实时相位那一刻（6.05 秒，更早一帧）还有节奏、到「现在」（6.1 秒）已经没了 → 两边一起停，不算不一致
    var tlStop = LookaheadTimeline()
    tlStop.restart(at: 0)
    k = 0
    while Double(k) * vsDt <= 13 {
        let tk = Double(k) * vsDt
        tlStop.append(p4Sample(tk, hz: 1, phase: 2 * Double.pi * tk + 0.3, followHz: tk <= 6.02 ? 1 : 0))
        k += 1
    }
    var stopper = RhythmLookahead()
    t = 3.0
    for _ in 0..<10 {
        _ = p4CheckBeat(&stopper, t, follow: 1, timeline: tlStop)
        t += 0.3
    }
    let stopperVerified = stopper.verified
    _ = p4CheckBeat(&stopper, 6.1, follow: 0, timeline: tlStop)
    vcheck(!noLive.verified && noLive.disagreements == 1 && nout == nw && noLive.state == .checking
           && unsure.verified && unsure.disagreements == 0
           && stopperVerified && stopper.verified && stopper.disagreements == 0,
           "P4 实时没节奏、前瞻有把握有节奏 = 不一致（窗口原样）；前瞻自己也没把握、或节奏这一拍两边一起停时不算")

    // ③ 同一路时间轴的 reset()（seek / 暂停 / 缓冲）不清核对历史；读帧那边重读（origin 变了）清掉，要重新攒 3 次一致
    var re = RhythmLookahead()
    t = 3.0
    for _ in 0..<10 {
        _ = p4CheckBeat(&re, t, follow: 1, timeline: tl)
        t += 0.3
    }
    re.reset()
    let keptAfterReset = re.verified && re.agreements == RhythmLookahead.historyLength
    var tl2 = tl
    tl2.restart(at: 6)
    k = 0
    while 6 + Double(k) * vsDt <= 13 {
        let tk = 6 + Double(k) * vsDt
        tl2.append(p4Sample(tk, hz: 1, phase: 2 * Double.pi * tk + 0.3))
        k += 1
    }
    var afterRestart: [(Bool, Int)] = []
    var firstOut: (MotionWindow, MotionWindow)?
    t = 8.0
    for i in 0..<3 {
        let beat = p4CheckBeat(&re, t, follow: 1, timeline: tl2)
        if i == 0 { firstOut = beat }
        afterRestart.append((re.verified, re.agreements))
        t += 0.3
    }
    vcheck(keptAfterReset && afterRestart.map { $0.0 } == [false, false, true] && afterRestart.map { $0.1 } == [1, 2, 3]
           && re.disagreements == 0 && firstOut.map { $0.0 == $0.1 } == true,
           "P4 reset()（同一路时间轴）保留核对历史；读帧那边重读后历史清掉，重新对上 3 次才代入")
}

/// 0~13 秒、15 Hz 的前瞻：相位 = 2π·t + 0.3；followHz(t) / followRhythm 可设；gap：这段时间不写（断档 > 0.5 秒 = 新段）
func p4Timeline(followHz: (Double) -> Double = { _ in 1 }, followRhythm: Double = 0.8,
                gap: ClosedRange<Double>? = nil) -> LookaheadTimeline {
    var tl = LookaheadTimeline()
    tl.restart(at: 0)
    var k = 0
    while Double(k) * vsDt <= 13 {
        let tk = Double(k) * vsDt
        k += 1
        if let g = gap, g.contains(tk) { continue }
        var s = p4Sample(tk, hz: 1, phase: 2 * Double.pi * tk + 0.3, followHz: followHz(tk))
        s.subject.followRhythm = followRhythm
        tl.append(s)
    }
    return tl
}

do {
    // 复审 R3-M1 ①：核对通过以后，实时有把握有节奏（1 Hz、置信度 0.8），前瞻在同一时刻和「现在」都没有节奏（同一段、已攒满一个窗口）
    // = 不一致：那一拍就不算通过、窗口原样（修之前核对一直停在「通过」，前瞻拿居中的 0 Hz 顶掉实时的 1 Hz）。
    // 前瞻那段刚开头（断档后不满一个窗口）时没有节奏只是还没攒够，不算
    let gone = p4Timeline(followHz: { $0 <= 6.02 ? 1 : 0 })
    var la = RhythmLookahead()
    for i in 0..<10 { _ = p4CheckBeat(&la, 3 + Double(i) * 0.3, follow: 1, timeline: gone) }
    let verifiedBefore = la.verified && la.disagreements == 0
    let (w1, out1) = p4CheckBeat(&la, 7.0, follow: 1, timeline: gone)
    let afterFirst = (la.verified, la.disagreements, la.state)
    let (w2, out2) = p4CheckBeat(&la, 7.3, follow: 1, timeline: gone)
    let young = p4Timeline(followHz: { $0 <= 6.02 ? 1 : 0 }, gap: 6.03...6.6)
    var y = RhythmLookahead()
    for i in 0..<10 { _ = p4CheckBeat(&y, 3 + Double(i) * 0.3, follow: 1, timeline: young) }
    _ = p4CheckBeat(&y, 7.0, follow: 1, timeline: young)
    vcheck(verifiedBefore && out1 == w1 && !afterFirst.0 && afterFirst.1 == 1 && afterFirst.2 == .checking
           && out2 == w2 && !la.verified && la.disagreements == 2
           && y.verified && y.disagreements == 0,
           "P4 实时有把握有节奏、前瞻（攒满一个窗口的同一段）没有节奏 = 不一致：不再代入、窗口原样；前瞻段开头还没攒够时不算")

    // 复审 R3-M1 ②：核对太旧——核对通过后实时一直没节奏、前瞻也没把握（置信度 0.2，两边都不记核对）：
    // 最近一次核对后 3 秒内照旧代入，超过 3 秒就不算通过、窗口原样；重新记到一次一致后恢复
    let low = p4Timeline(followRhythm: 0.2)
    var st = RhythmLookahead()
    for i in 0..<10 { _ = p4CheckBeat(&st, 3 + Double(i) * 0.3, follow: 1, timeline: low) }
    let lastCheck = 3 + 9 * 0.3
    var fresh: [Bool] = []
    for t in [lastCheck + 1.3, lastCheck + 2.3] {
        let (w, out) = p4CheckBeat(&st, t, follow: 0, timeline: low)
        fresh.append(st.verified && out != w && out.subjectFollowHz == 1)
    }
    var stale: [Bool] = []
    for t in [lastCheck + 3.3, lastCheck + 4.3] {
        let (w, out) = p4CheckBeat(&st, t, follow: 0, timeline: low)
        stale.append(!st.verified && out == w && st.state == .checking && st.disagreements == 0 && !st.mismatched)
    }
    _ = p4CheckBeat(&st, lastCheck + 4.6, follow: 1, timeline: low)
    vcheck(fresh == [true, true] && stale == [true, true] && st.verified,
           "P4 核对超过 \(Int(RhythmLookahead.verifyStaleSeconds)) 秒没更新就不算通过（窗口原样）；3 秒内照旧，重新对上一次就恢复")
}

do {
    // 提前量：相位锁的频率比画面快 10%（1.1 vs 1.0 Hz）、延迟 0.4 秒 → 收敛到 2π × (1.0 − 1.1) × 0.4 ≈ −14°；
    // 每拍最多变 90°/秒 × 0.3 秒；差得多时夹在 ±60°；相位锁不用时立刻 0；不代入相位时按速率回 0
    let tl = p4Analytic(hz: 1, to: 16, from: 3)
    var la = RhythmLookahead()
    var w = plWindow(time: 9.95, hz: 1)
    w.subjectFollowHz = 1
    w.subjectFollowRhythm = 0.8
    w.subjectFollowAmplitude = 3
    var leads: [Double] = []
    for i in 0..<20 {
        let t = 5 + Double(i) * 0.3
        w = plWindow(time: t - 0.05, hz: 1)
        w.subjectFollowHz = 1
        w.subjectFollowRhythm = 0.8
        w.subjectFollowAmplitude = 3
        let clock = RhythmLookahead.Clock(hostNow: t, itemNow: t, rate: 1)
        _ = la.refine(w, timeline: tl, clock: clock, latency: 0.4)
        leads.append(la.stepLead(timeline: tl, clock: clock, latency: 0.4, lockOmega: 2 * Double.pi * 1.1, lockWeight: 1, dt: 0.3))
    }
    let expected = StrokeRhythm.wrapPhase(-2 * Double.pi * 0.1 * 0.4)
    var maxStep = 0.0
    for i in 1..<leads.count { maxStep = max(maxStep, abs(leads[i] - leads[i - 1])) }
    var capped = la
    var capLeads: [Double] = []
    for i in 0..<10 {
        let t = 11 + Double(i) * 0.3
        capLeads.append(capped.stepLead(timeline: tl, clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.6,
                                        lockOmega: 2 * Double.pi * 1.5, lockWeight: 1, dt: 0.3))
    }
    var dropped = la
    let zero = dropped.stepLead(timeline: tl, clock: .init(hostNow: 12, itemNow: 12, rate: 1), latency: 0.4,
                                lockOmega: 2 * Double.pi * 1.1, lockWeight: 0, dt: 0.3)
    // 不代入相位（切镜那一拍）时按速率回 0：每拍最多回 90°/秒 × 0.3 秒 = 27°。
    // 草稿原来要求 −14° 的提前量切镜后「变小但不为 0」，可一拍就能回 27° > 14°，按速率回 0 本来就该一拍到 0（断言写错了）；
    // 改成两种情况都钉死：−14° 一拍到 0；夹在 −60° 的那个一拍只回 27°（剩 −33°），再一拍剩 −6°，第三拍到 0
    let step = RhythmLookahead.leadRatePerSecond * 0.3
    var decay = la
    let cutW = plWindow(time: 12, hz: 1, cut: true)
    _ = decay.refine(cutW, timeline: tl, clock: .init(hostNow: 12.05, itemNow: 12.05, rate: 1), latency: 0.4)
    let afterCut = decay.stepLead(timeline: tl, clock: .init(hostNow: 12.05, itemNow: 12.05, rate: 1), latency: 0.4,
                                  lockOmega: 2 * Double.pi * 1.1, lockWeight: 1, dt: 0.3)
    var bigDecay = capped
    var bigLeads: [Double] = []
    for i in 0..<3 {
        let t = 14.05 + Double(i) * 0.3
        _ = bigDecay.refine(plWindow(time: t - 0.05, hz: 1, cut: true), timeline: tl,
                            clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.6)
        bigLeads.append(bigDecay.stepLead(timeline: tl, clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.6,
                                          lockOmega: 2 * Double.pi * 1.5, lockWeight: 1, dt: 0.3))
    }
    let bigStart = capLeads.last ?? 0
    let bigOK = bigLeads.count == 3 && abs(bigLeads[0] - (bigStart + step)) < 1e-9
        && abs(bigLeads[1] - min(0, bigStart + 2 * step)) < 1e-9 && bigLeads[2] == 0
    vcheck(abs((leads.last ?? 9) - expected) <= 1e-6 && maxStep <= step + 1e-9
           && capLeads.allSatisfy { abs($0) <= RhythmLookahead.maxLead + 1e-9 } && abs(abs(capLeads.last ?? 0) - RhythmLookahead.maxLead) < 1e-9
           && bigStart < 0 && zero == 0 && afterCut == 0 && !decay.phaseEngaged && bigOK,
           "P4 提前量：锁快 10% 时收敛到 \(p4Deg(leads.last ?? 9))°（应 \(p4Deg(expected))°），每拍最多变 \(p4Deg(maxStep))°；"
           + "差太多夹在 ±60°；相位锁不用时立刻 0；不代入相位时按速率回 0（−14° 一拍到 0；−60° → \(bigLeads.map { p4Deg($0) + "°" }.joined(separator: " → "))）")
}

/// P4 + 0.1 秒子拍脉动整段（照 VideoSyncPlayer.motionTick 的顺序）。lookahead == false：一行 P4 代码都不走（main 的链）；
/// coordinator：经 LookaheadCoordinator（enabled = lookahead）。readPast：视频比模拟多出来的秒数（前瞻读得到模拟结束之后的画面）
struct P4PulseRun {
    var times: [Double] = []
    var outs: [[Int]] = []
    var offsets: [UInt64] = []
    var fullTimes: [Double] = []
    var lockErr: [Double?] = []
    var subs = 0
    var state = RhythmLookahead.State.off
    var lead: Double = 0
}

func p4PulseRun(_ scene: P4Scene, seconds: Double = 20, lookahead: Bool, coordinator: Bool = true,
                readPast: Double = 3, value: Double = 70, cap: Int = 70) -> P4PulseRun {
    var rtA = MotionAnalyzer()
    rtA.phaseFitEnabled = true
    var laA = MotionAnalyzer()
    laA.phaseFitEnabled = true
    var acc = MotionWindowAccumulator()
    var tl = LookaheadTimeline()
    tl.restart(at: 0)
    var coord = LookaheadCoordinator()
    var follower = RhythmFollower()
    var lock = RhythmPhaseLock()
    var driver = RhythmPulseDriver()
    var stage = SyncOutputStage()
    let st = AudioSyncSettings(enabled: true, maxPercent: Double(cap), channels: .both, minPercent: 10)
    let vis = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: "20:0.6, 60:1.8, 99:2.8", rhythmPulse: true,
                                 rhythmLookahead: lookahead)
    var r = P4PulseRun()
    let frames = Int(seconds * 15)
    let readable = Int((seconds + readPast) * 15)
    var kb = 0
    var lastFull = 0.0
    var tick = 0.0
    let latency = vis.pulseLatencyMs / 1000
    for k in 0..<frames {
        let t = Double(k) * vsDt
        if let s = rtA.analyze(scene.frame(t), time: t) { acc.add(s) }
        while tick + 0.1 <= t {
            tick += 0.1
            let now = tick
            if driver.takesFullBeat(at: now) {
                if lookahead {
                    while kb < readable, Double(kb) * vsDt <= now + LookaheadTimeline.horizon {
                        let tb = Double(kb) * vsDt
                        if let s = laA.analyze(scene.frame(tb), time: tb) { tl.append(s) }
                        kb += 1
                    }
                    tl.prune(playhead: now)
                }
                let dt = now - lastFull
                lastFull = now
                let w = acc.drain()
                let clock = RhythmLookahead.Clock(hostNow: now, itemNow: now, rate: 1)
                let input = coordinator ? coord.refine(w, enabled: vis.usesLookahead, timeline: tl, clock: clock, latency: latency) : w
                follower.step(input, dt: dt, active: true)
                lock.step(input, followerHz: follower.hz, followerLocked: follower.locked, followerSource: follower.source,
                          now: now, dt: dt, active: true)
                if coordinator {
                    // 撞击声校正关着：updateAudioAnchor 不动偏移；前后各一步和播放器一样
                    driver.phaseOffset = coord.removeLead(from: driver.phaseOffset)
                    driver.phaseOffset = coord.applyLead(to: driver.phaseOffset, enabled: vis.usesLookahead, timeline: tl,
                                                         clock: clock, latency: latency, lock: lock, dt: dt)
                }
                let rate = follower.weight > 0 && follower.hz > 0 ? vis.rateMap.level(forHz: follower.hz) : nil
                let levels = RhythmOutput.target(value: value, settings: st, hasSignal: true, rateLevel: rate,
                                                 weight: follower.weight, activity: 1)
                r.outs.append(driver.beat(levels: levels, lock: lock, visual: vis, settings: st, hasSignal: true, value: value,
                                          activity: 1, followerWeight: follower.weight, now: now, stage: &stage))
                r.times.append(now)
                r.offsets.append(driver.phaseOffset.bitPattern)
                r.fullTimes.append(now)
                r.lockErr.append(lock.phase(at: now + latency).map {
                    p2Err($0 + driver.phaseOffset, scene.phase(now + latency) - Double.pi / 2) })
            } else if let o = driver.subBeat(lock: lock, settings: st, now: now, stage: &stage) {
                r.outs.append(o)
                r.times.append(now)
                r.offsets.append(driver.phaseOffset.bitPattern)
                r.subs += 1
            }
        }
    }
    r.state = coord.lookahead.state
    r.lead = coord.lead
    return r
}

/// 出口不变量：上限 / 单步 ≤ 20 / 任意两刻升幅 ≤ 20 × 间隔 / 0.3 + 1 / 通道 3、4 恒 0
func p4Envelope(_ r: P4PulseRun, cap: Int) -> Bool {
    var ok = true
    var prev = [0, 0, 0, 0]
    for (i, o) in r.outs.enumerated() {
        ok = ok && o[2] == 0 && o[3] == 0 && o[0] <= cap && o[1] <= cap && o[0] - prev[0] <= 20 && o[1] - prev[1] <= 20
        prev = o
        for j in (i + 1)..<r.outs.count where r.times[j] - r.times[i] <= 2 {
            for ch in 0..<2 where Double(r.outs[j][ch] - o[ch]) > 20 * (r.times[j] - r.times[i]) / 0.3 + 1 + 1e-9 { ok = false }
        }
    }
    return ok
}

do {
    // 前瞻 + 0.1 秒子拍脉动整段：输出照旧过同一个出口——上限、单步 ≤ 20、任意两刻升幅 ≤ 20 × 间隔 / 0.3 + 1、通道 3 / 4 恒 0；
    // 指令相位（含提前量）峰值落在画面 −45° 附近；频率跳变那几秒相位比只用实时的对得更快。
    //
    // 和草稿相比改了两处断言（算法没动，草稿里这条失败的原因都在断言本身）：
    // ① 峰数：统计窗口是 15~20 秒、1.4 Hz，一共只有 5 × 1.4 = 7 个往复，草稿要求 ≥ 8 个峰不可能做到；改成 ≥ 7（每个往复一个峰）。
    //    只用实时的同一段也是 7 个峰。
    // ② 结束时 state == .engaged：草稿里前瞻只能读到 20 秒（kb < 300），和模拟同时结束，最后 2 秒前瞻没有「后面的画面」，
    //    按设计就该退回 .waiting（读到的不够远 = 只用实时）。真实视频在这一刻之后还有画面，所以让前瞻多读 3 秒；
    //    「视频真的到头了 → 退回只用实时、提前量回 0」另外单独钉住。
    let scene = P4Scene(phase: p4StepPhase(1, 1.4, at: 12))
    let on = p4PulseRun(scene, lookahead: true)
    let base = p4PulseRun(scene, lookahead: false, coordinator: false)
    func peaks(_ r: P4PulseRun) -> (n: Int, err: Double) {
        let late = r.times.indices.filter { r.times[$0] >= 15 }
        var n = 0
        var err = 0.0
        for k in late.dropFirst().dropLast() where r.outs[k][0] > r.outs[k - 1][0] && r.outs[k][0] >= r.outs[k + 1][0] {
            err = max(err, p2Err(scene.phase(r.times[k] + 0.2) - Double.pi / 2, RhythmPulse.peakPhase))
            n += 1
        }
        return (n, err)
    }
    let pk = peaks(on)
    let pkBase = peaks(base)
    // 12~16 秒（跳变之后）：指令相位误差（相位锁 + 偏移 vs 画面真值；锁没在用时记 180°）
    func worst(_ r: P4PulseRun) -> Double {
        r.fullTimes.indices.filter { r.fullTimes[$0] >= 12 && r.fullTimes[$0] <= 16 }.map { r.lockErr[$0] ?? Double.pi }.max() ?? 9
    }
    let worstOn = worst(on)
    let worstBase = worst(base)
    vcheck(p4Envelope(on, cap: 70) && on.subs > 50 && pk.n >= 7 && pk.err <= 2 * Double.pi * 0.15 && on.state == .engaged
           && pkBase.n == pk.n && worstOn <= Double.pi / 4 && worstOn < worstBase,
           "P4 + 子拍脉动整段（1→1.4 Hz）：上限 70 / 单步 ≤ 20 / 升幅包络 / 通道 3、4 恒 0 全程守住；"
           + "\(pk.n) 个峰在画面 −45° ± \(p4Deg(pk.err))°（只用实时 \(pkBase.n) 个 ± \(p4Deg(pkBase.err))°，0.1 秒一档的量化）；"
           + "跳变后 4 秒指令相位最大误差 \(p4Deg(worstOn))°（只用实时 \(p4Deg(worstBase))°）")

    // 视频到头：前瞻读不到后面，最后一段退回只用实时（.waiting）、提前量回 0，出口不变量照旧
    let end = p4PulseRun(scene, lookahead: true, readPast: 0)
    vcheck(p4Envelope(end, cap: 70) && end.state == .waiting && end.lead == 0,
           "P4 视频到头：后面没画面可读时退回只用实时，提前量回 0")
}

do {
    // 开关关着 = main：同一段画面（1→1.4 Hz 跳变、上限 55、子拍脉动），经 LookaheadCoordinator（enabled = false）
    // 和完全不走 P4 代码的链逐位相同（每一拍的输出、脉动相位偏移的位模式）。
    // 「开着但没标定」也一样（usesLookahead 要求已标定）
    let scene = P4Scene(phase: p4StepPhase(1, 1.4, at: 9), amp: { $0 < 17 ? 4 : 0 })
    let base = p4PulseRun(scene, seconds: 20, lookahead: false, coordinator: false, value: 60, cap: 55)
    let off = p4PulseRun(scene, seconds: 20, lookahead: false, coordinator: true, value: 60, cap: 55)
    let uncal = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true, rhythmLookahead: true)
    vcheck(base.outs == off.outs && base.times == off.times && base.offsets == off.offsets && base.subs == off.subs
           && off.offsets.allSatisfy { $0 == 0.0.bitPattern } && off.state == .off && !uncal.usesLookahead,
           "P4 关着：整段 \(off.outs.count) 拍（含 \(off.subs) 个子拍）输出和脉动相位偏移与不走 P4 的链逐位相同；没标定时也不生效")

    // LookaheadCoordinator 关着：3000 个随机窗口 / 偏移原样（含 NaN、切镜、空窗口），状态一直是 .off
    var c = LookaheadCoordinator()
    let tl = p4Analytic(hz: 1, to: 20)
    var same = true
    let lock = plLocked()
    for i in 0..<3000 {
        var w = plWindow(time: Double(i) * 0.3, hz: 0.5 + vsRandom() * 2, noise: vsRandom(), frames: Int(vsRandom() * 6),
                         valid: vsRandom() < 0.8, cut: vsRandom() < 0.05)
        w.subjectFollowHz = vsRandom() < 0.2 ? 0 : 0.4 + vsRandom() * 3
        let clock = RhythmLookahead.Clock(hostNow: 3 + Double(i) * 0.003, itemNow: 3 + Double(i) * 0.003, rate: 1)
        let out = c.refine(w, enabled: false, timeline: tl, clock: clock, latency: 0.2)
        let a = vsRandom() < 0.05 ? Double.nan : (vsRandom() - 0.5) * 3
        let removed = c.removeLead(from: a)
        let applied = c.applyLead(to: removed, enabled: false, timeline: tl, clock: clock, latency: 0.2, lock: lock, dt: 0.3)
        same = same && out == w && removed.bitPattern == a.bitPattern && applied.bitPattern == a.bitPattern
            && c.lookahead.state == .off && c.lead == 0
    }
    vcheck(same, "P4 接线关着：3000 个随机窗口 / 相位偏移原样交回（位模式相同），前瞻状态一直是关")
}

do {
    // 接线：提前量加上 → 下一拍撞击声校正之前撤掉（得回原来的撞击声部分）；中间偏移被别处改过（reset）就不撤；
    // 总偏移夹在 ±90°（撞击声校正自己最宽也是 ±90°）
    let tl = p4Analytic(hz: 1, to: 16, from: 3)
    var c = LookaheadCoordinator()
    var lock = plLocked(hz: 1.1)
    for i in 0..<20 {
        let t = 5 + Double(i) * 0.3
        var w = plWindow(time: t - 0.05, hz: 1)
        w.subjectFollowHz = 1
        w.subjectFollowRhythm = 0.8
        _ = c.refine(w, enabled: true, timeline: tl, clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.4)
    }
    let clock = RhythmLookahead.Clock(hostNow: 10.7, itemNow: 10.7, rate: 1)
    var total = 0.25
    for _ in 0..<6 {
        _ = c.removeLead(from: total)
        total = c.applyLead(to: 0.25, enabled: true, timeline: tl, clock: clock, latency: 0.4, lock: lock, dt: 0.3)
    }
    let restored = c.removeLead(from: total)
    _ = c.applyLead(to: 0.25, enabled: true, timeline: tl, clock: clock, latency: 0.4, lock: lock, dt: 0.3)
    let untouched = c.removeLead(from: 0)
    lock.reset()
    let big = RhythmLookahead.phaseOffset(anchor: AudioPhaseAnchor.unknownLimit, lead: RhythmLookahead.maxLead)
    let bigNeg = RhythmLookahead.phaseOffset(anchor: -AudioPhaseAnchor.unknownLimit, lead: -RhythmLookahead.maxLead)
    let small = RhythmLookahead.phaseOffset(anchor: 0.3, lead: -0.2)
    vcheck(c.lead != 0 && total != 0.25 && restored == 0.25 && untouched == 0
           && big == RhythmLookahead.maxTotalOffset && bigNeg == -RhythmLookahead.maxTotalOffset && abs(small - 0.1) < 1e-12
           && RhythmLookahead.phaseOffset(anchor: 0.3, lead: .nan) == 0.3,
           "P4 接线：提前量（\(p4Deg(c.lead))°）下一拍先撤掉再算撞击声校正；偏移被别处清过就不撤；总偏移夹在 ±90°")
}

do {
    // 设置：默认关、键名、读回；只有跟随画面 + 伸缩跟随频率 + 前瞻都开才生效；不影响 Timer 间隔
    let d = VisualSyncSettings()
    let suite = "p4-settings-\(UInt64(vsRandom() * 1e12))"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: VisualSyncSettings.Keys.rhythmLookahead)
    defaults.set(1, forKey: VisualSyncSettings.Keys.source)
    defaults.set(true, forKey: VisualSyncSettings.Keys.rhythmFollow)
    defaults.set(true, forKey: VisualSyncSettings.Keys.prescan)
    let loaded = VisualSyncSettings.load(from: defaults)
    defaults.removePersistentDomain(forName: suite)
    // 草稿这里没写标定表也断言 p1.usesLookahead：按「没标定 / 没有可信信号时退回 P4 关着的行为」，没标定时必须不生效，
    // 所以生效的几组都带上标定表，另加一组没标定的
    let table = "20:0.6, 60:1.8, 99:2.8"
    let noFollow = VisualSyncSettings(source: .motion, rhythmFollow: false, rateTable: table, rhythmLookahead: true)
    let audio = VisualSyncSettings(source: .audio, rhythmFollow: true, rateTable: table, rhythmLookahead: true)
    let p1 = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: table, rhythmLookahead: true)
    let uncal = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmLookahead: true)
    let p2 = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: table, rhythmPulse: true, rhythmLookahead: true)
    let p2off = VisualSyncSettings(source: .motion, rhythmFollow: true, rateTable: table, rhythmPulse: true)
    let pre = VisualSyncSettings(source: .motion, prescan: true)
    let preFixed = VisualSyncSettings(source: .motion, autoMotion: false, prescan: true)
    let preAudio = VisualSyncSettings(source: .audio, prescan: true)
    let loadedCal = VisualSyncSettings(source: loaded.source, rhythmFollow: loaded.rhythmFollow, rateTable: table,
                                       rhythmLookahead: loaded.rhythmLookahead)
    vcheck(!d.rhythmLookahead && !d.usesLookahead && !d.prescan && !d.usesPrescan && !d.usesExtraDecode
           && VisualSyncSettings.Keys.rhythmLookahead == "bcVisualSyncRhythmLookahead"
           && VisualSyncSettings.Keys.prescan == "bcVisualSyncPrescan"
           && loaded.rhythmLookahead && !loaded.usesLookahead && loadedCal.usesLookahead && loaded.prescan
           && !noFollow.usesLookahead && !audio.usesLookahead && !uncal.usesLookahead && !uncal.usesExtraDecode
           && p1.usesLookahead && p1.usesExtraDecode && p1.tickInterval == AudioReactiveShaper.interval
           && p2.tickInterval == p2off.tickInterval && p2.usesPulseTiming == p2off.usesPulseTiming
           && pre.usesPrescan && pre.usesExtraDecode && !pre.usesLookahead && !preFixed.usesPrescan && !preAudio.usesPrescan
           && VisualSyncSettings.load(from: UserDefaults(suiteName: suite + "-empty")!) == d,
           "P4 设置：默认都关、键名 bcVisualSyncRhythmLookahead / bcVisualSyncPrescan、读回；前瞻要跟随画面 + 频率跟随 + 已标定，"
           + "预扫描要跟随画面 + 自动适应；Timer 间隔不变")
}

do {
    // 状态行
    var la = RhythmLookahead()
    let reader = la.statusText(reader: "手机发热，已暂停")
    let waiting = la.statusText(reader: nil)
    let tl = p4Analytic(hz: 1, to: 13)
    for i in 0..<20 {
        let t = 3 + Double(i) * 0.3
        var w = plWindow(time: t - 0.05, hz: 1)
        w.subjectFollowHz = 1
        w.subjectFollowRhythm = 0.8
        w.subjectFollowAmplitude = 3
        _ = la.refine(w, timeline: tl, clock: .init(hostNow: t, itemNow: t, rate: 1), latency: 0.2)
    }
    let engaged = la.statusText(reader: nil)
    vcheck(reader == "前瞻：手机发热，已暂停，只用实时画面" && waiting == "前瞻：正在提前读后面的画面…"
           && engaged.hasPrefix("前瞻：已读到后面 ") && engaged.contains("频率和相位都按将来的画面"),
           "P4 状态行：读帧那边有问题时说明只用实时；在读 / 已用上时说明读到多远（\(engaged)）")
}

do {
    // 读帧那边：什么时候从播放头重新开读、什么时候还要往后读
    var tl = LookaheadTimeline()
    let fresh = tl.needsRestart(playhead: 5)
    tl.restart(at: 5)
    let emptyNear = !tl.needsRestart(playhead: 5.5) && tl.wantsMore(playhead: 5)
    for k in 0..<60 { tl.append(p4Sample(5 + Double(k) * vsDt, hz: 1, phase: 0)) }   // 读到 ≈ 8.93
    let ahead = !tl.wantsMore(playhead: 5.5) && tl.wantsMore(playhead: 6.5)
    let back = tl.needsRestart(playhead: 4.7) && !tl.needsRestart(playhead: 4.8)
    let jump = tl.needsRestart(playhead: 10) && !tl.needsRestart(playhead: 9.9)
    vcheck(fresh && emptyNear && ahead && back && jump && !tl.needsRestart(playhead: .nan) && !tl.wantsMore(playhead: .nan),
           "P4 读帧：没开读 / 往回 seek > 0.25 秒 / 播放头跑到读到的最远处 1 秒以后 → 从播放头重读；领先 3 秒就先不读")

    // 复审 M1：从 0 开读、一路读到 63 秒、按播放头 60 秒修剪（只留 55 秒以后）：往回 seek 到 10 秒在开读处之后、
    // 却早于还留着的最早一帧，必须重读（原来只和开读处比，要等播放头走回 55 秒才有前瞻）；往回 3 秒（57 秒）还在留着的范围里，不重读
    var pruned = LookaheadTimeline()
    pruned.restart(at: 0)
    var k = 0
    while Double(k) * vsDt <= 63 {
        pruned.append(p4Sample(Double(k) * vsDt, hz: 1, phase: 0))
        k += 1
    }
    pruned.prune(playhead: 60)
    let prunedFirst = pruned.first
    let backFar = pruned.needsRestart(playhead: 10)
    let backNear = !pruned.needsRestart(playhead: 57)
    let stillNear = !pruned.needsRestart(playhead: 60) && !pruned.wantsMore(playhead: 60) && pruned.wantsMore(playhead: 61)
    // 播完重播：30 秒的视频读到文件尾（30 秒）、播放头停在 30 秒（只留 25 秒以后），再从 0 播：
    // 不重读的话 wantsMore(0) 是 false、0 秒附近也查不到，整段重播都没有前瞻 → 必须重读；重读后从 0 接着往后读
    var ended = LookaheadTimeline()
    ended.restart(at: 0)
    k = 0
    while Double(k) * vsDt <= 30 {
        ended.append(p4Sample(Double(k) * vsDt, hz: 1, phase: 0))
        k += 1
    }
    ended.prune(playhead: 30)
    let endedStuck = !ended.wantsMore(playhead: 0) && ended.reach(from: 0) == nil
    let replay = ended.needsRestart(playhead: 0)
    var replayed = ended
    replayed.restart(at: 0)
    let replayOK = !replayed.needsRestart(playhead: 0) && replayed.wantsMore(playhead: 0) && replayed.origin == 0
    // 短视频（全程都还留着）：重播从 0 读得到，不用重读
    var short = LookaheadTimeline()
    short.restart(at: 0)
    for j in 0..<60 { short.append(p4Sample(Double(j) * vsDt, hz: 1, phase: 0)) }
    short.prune(playhead: 3.9)
    let shortKept = !short.needsRestart(playhead: 0) && short.reach(from: 0) != nil
    vcheck(prunedFirst >= 55 - 1e-9 && prunedFirst <= 55 + vsDt + 1e-9 && backFar && backNear && stillNear
           && endedStuck && replay && replayOK && shortKept,
           "P4 读帧（复审 M1）：往回 seek 到还留着的最早一帧之前（开读 0 秒、留 55 秒以后、seek 到 10 秒）要重读，往回 3 秒不重读；"
           + "播完从 0 重播要重读、重读后接着往后读；全程都还留着的短视频重播不用重读")
}

do {
    // 发热：另开一路解码只在 .nominal / .fair 跑，.serious 起停（且这一路不跑 Vision）
    vcheck(LookaheadThermalPolicy.allowsExtraDecode(.nominal) && LookaheadThermalPolicy.allowsExtraDecode(.fair)
           && !LookaheadThermalPolicy.allowsExtraDecode(.serious) && !LookaheadThermalPolicy.allowsExtraDecode(.critical)
           && LookaheadThermalPolicy.note(.nominal) == nil && LookaheadThermalPolicy.note(.serious) != nil,
           "P4 发热：前瞻 / 预扫描只在 .nominal / .fair 跑，.serious / .critical 停掉")
}

do {
    // 预扫描：整段 P4Scene（前 10 秒安静、后 20 秒往复）按 15 Hz 分析 → 0.3 秒窗口 → 10 / 90 分位；
    // 和同一段画面让 MotionNormalizer 实时学 30 秒得到的参考值同一量级；窗口数不够时不给
    let scene = P4Scene(phase: { 2 * Double.pi * 1.2 * $0 }, amp: { $0 < 10 ? 0.5 : 4 })
    var an = MotionAnalyzer()
    var pre = MotionPrescan()
    var acc = MotionWindowAccumulator()
    var live = MotionNormalizer()
    for k in 0..<(30 * 15) {
        let t = Double(k) * vsDt
        if let s = an.analyze(scene.frame(t), time: t) {
            pre.add(s)
            acc.add(s)
        }
        if k % 5 == 4 { _ = live.step(acc.drain(), gainDb: 0, auto: true, dt: 0.3) }
    }
    pre.finish()
    let sum = pre.summary
    var short = MotionPrescan()
    var an2 = MotionAnalyzer()
    for k in 0..<(5 * 15) {
        let t = Double(k) * vsDt
        if let s = an2.analyze(scene.frame(t + 12), time: t) { short.add(s) }
    }
    short.finish()
    vcheck(sum.isValid && sum.scoreWindows >= 90 && sum.scoreLow <= sum.scoreHigh && sum.scoreHigh > 0.05
           && abs(pre.scanned - 29 * 1.0 - 14 * vsDt) < 0.2 && pre.windows >= 95 && pre.windows <= 101
           && !short.summary.isValid && short.summary.refHigh.isNaN,
           "P4 预扫描：30 秒视频 \(pre.windows) 个窗口，主体分数 10 / 90 分位 "
           + String(format: "%.2f / %.2f（实时学 30 秒后 %.2f / %.2f）", sum.scoreLow, sum.scoreHigh, live.scoreLow, live.scoreHigh)
           + "；不满 \(MotionPrescan.minWindows) 个窗口不给")

    // 初始化：只在换视频后还没学过时生效（之后照常实时学）；学过一拍 / 摘要不可信时不动；
    // 夹在实时学习能到的范围里；输出照样在 0~100
    var seeded = MotionNormalizer()
    let used = seeded.seed(sum)
    var learned = MotionNormalizer()
    _ = learned.step(plWindow(time: 0, hz: 1), gainDb: 0, auto: true, dt: 0.3)
    let before = learned
    let late = learned.seed(sum)
    var bad = MotionNormalizer()
    let badUsed = bad.seed(MotionPrescan.Summary())
    var weird = MotionPrescan.Summary()
    weird.energyWindows = 100
    weird.refLow = 9
    weird.refHigh = -3
    weird.scoreWindows = 100
    weird.scoreLow = 2
    weird.scoreHigh = -1
    var clamped = MotionNormalizer()
    _ = clamped.seed(weird)
    var outOK = true
    var probe = seeded
    for i in 0..<300 {
        var w = plWindow(time: Double(i) * 0.3, hz: 1)
        w.subjectScore = vsRandom()
        w.meanEnergy = vsRandom() * 30
        w.peakEnergy = w.meanEnergy * 1.5
        let v = probe.step(w, gainDb: (vsRandom() - 0.5) * 18, auto: true, dt: 0.3)
        outOK = outOK && v >= 0 && v <= 100
    }
    vcheck(used && abs(seeded.scoreHigh - MotionStats.clamp01(sum.scoreHigh)) < 1e-12 && seeded.confidence == 0
           && !late && learned.scoreHigh == before.scoreHigh && learned.refHigh == before.refHigh
           && !badUsed && bad.refHigh == MotionNormalizer.initialHigh && bad.scoreHigh == MotionNormalizer.subjectInitialHigh
           && clamped.refHigh == MotionNormalizer.minHigh && clamped.refLow <= clamped.refHigh && clamped.refLow >= 0
           && clamped.scoreHigh == 0 && clamped.scoreLow == 0 && outOK,
           "P4 预扫描初始化：只在还没学过时用（热身照旧从 0 起）；学过 / 不可信时不动；坏值夹回实时能到的范围；输出仍在 0~100")
}

// MARK: - av-fusion F0（观测与标定）：都放在函数里（顶层栈已经很满）
func avFusionF0Checks() {
    // 调试表格声画列：表头 / 有数 / 空列 三者列数一致；NaN / ∞ 写空；撞击时刻用分号连、没有逗号
    let headerCount = AVDebugColumns.f0Header.split(separator: ",", omittingEmptySubsequences: false).count
    var bands = AudioBandSummary()
    bands.add([AudioBandFrame(time: 1, low: 0.01, mid: 0.001, high: 0), AudioBandFrame(time: 1.01, low: 0.03, mid: 0.001, high: 0)])
    let clock = MediaClockSnapshot(host: 100, item: 5, rate: 1)
    let full = AVDebugColumns.f0Fields(onsets: [1.2345, .nan, 1.8], bands: bands, tapLead: 0.0815, tapValid: 7, tapInvalid: 1,
                                       clock: clock)
    let blank = AVDebugColumns.f0Fields(onsets: [], bands: AudioBandSummary(), tapLead: .nan, tapValid: 0, tapInvalid: 0,
                                        clock: MediaClockSnapshot(host: .infinity, item: .nan, rate: .nan))
    let line = full.joined(separator: ",")
    vcheck(headerCount == 11 && full.count == headerCount && blank.count == headerCount && AVDebugColumns.f0Empty.count == headerCount
           && (full[0] == "1.234;1.800" || full[0] == "1.235;1.800"),
           "F0 调试列：表头 \(headerCount) 列，有数 / 空 / 占位列数一致；撞击时刻分号分隔（\(full[0])）")
    vcheck(full[1] == "2" && full[2] == "-16.99" && full[3] == "-30.00" && full[4] == "-120.00" && full[5] == "81.5"
           && full[6] == "7" && full[7] == "1" && full[8] == "100.0000" && full[10] == "1.000"
           && line.split(separator: ",", omittingEmptySubsequences: false).count == headerCount,
           "F0 调试列数值：频带均值 dB / 提前量毫秒 / 回调计数 / 播放器时钟（\(line)）")
    vcheck(blank[0] == "" && blank[1] == "0" && blank[2] == "" && blank[5] == "" && blank[8] == "" && blank[9] == ""
           && blank[10] == "" && AVDebugColumns.f0Empty.allSatisfy { $0.isEmpty } && AVDebugColumns.field(.nan) == ""
           && AVDebugColumns.field(-.infinity) == "",
           "F0 调试列：NaN / ∞ / 没有块 → 空格子（不是 nan / inf）")

    // tap 回调时间环形缓冲：关着什么都不记；满 64 条后留最新的、旧 → 新；计数照记；drain 清零；开关切换清掉
    let ring = AudioTapTimingRing()
    ring.record(AudioTapTiming(host: 1, itemStart: 0, frames: 512))
    let offEmpty = ring.count == 0 && ring.validCount == 0 && ring.invalidCount == 0 && ring.drain().timings.isEmpty
    ring.setEnabled(true)
    for k in 0..<100 {
        ring.record(AudioTapTiming(host: Double(k), itemStart: k % 10 == 9 ? .nan : Double(k) * 0.01, frames: 480))
    }
    let d = ring.drain()
    let ordered = d.timings.count == AudioTapTimingRing.capacity && d.timings.first?.host == 36 && d.timings.last?.host == 99
        && zip(d.timings, d.timings.dropFirst()).allSatisfy { $0.host + 1 == $1.host }
    let counted = d.valid == 90 && d.invalid == 10 && d.timings.filter { !$0.valid }.count == 7
    let cleared = ring.count == 0 && ring.drain().timings.isEmpty
    ring.record(AudioTapTiming(host: 1, itemStart: 1, frames: 0))
    ring.setEnabled(false)
    ring.record(AudioTapTiming(host: 2, itemStart: 2, frames: 10))
    let offAgain = ring.count == 0 && ring.validCount == 0 && ring.invalidCount == 0
    vcheck(offEmpty && ordered && counted && cleared && offAgain && !AudioTapTiming(host: 1, itemStart: 1, frames: 0).valid,
           "F0 回调时间缓冲：关着不记；满 \(AudioTapTimingRing.capacity) 条留最新、旧 → 新；有效 / 无效计数；取走清零；关掉清掉")

    // 播放器时钟换算：视频时间 ↔ host 时间（倍速 2 时视频走两倍）；倍速 0 / 非有限 → NaN
    let c2 = MediaClockSnapshot(host: 50, item: 10, rate: 2)
    let paused = MediaClockSnapshot(host: 50, item: 10, rate: 0)
    vcheck(abs(c2.host(forItem: 11) - 50.5) < 1e-12 && abs(c2.item(forHost: 51) - 12) < 1e-12
           && abs(c2.item(forHost: c2.host(forItem: 13.37)) - 13.37) < 1e-12
           && paused.host(forItem: 11).isNaN && paused.item(forHost: 51).isNaN && c2.host(forItem: .nan).isNaN,
           "F0 播放器时钟：视频时间 ↔ host 时间按倍速互换，暂停 / 无效 → NaN")

    // tap 提前量：tap 比出声早 L（固定种子抖动 ±3 ms + 几个 seek 离谱值）→ 中位数在 2.5 ms 内；倍速 2 一样；无效时钟 / 无效记录不进
    var leadOK = true
    var leads: [String] = []
    // 自己的固定种子（不受前面测试用掉多少 vsRandom 影响）
    var jSeed: UInt64 = 0xF0F0
    func jRandom() -> Double {
        jSeed = jSeed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(jSeed >> 11) / Double(1 << 53)
    }
    for (rate, lead) in [(1.0, 0.12), (2.0, 0.045), (1.0, -0.02)] {
        var est = AudioTapLeadEstimator()
        var host = 1000.0
        var item = 3.0
        for k in 0..<60 {
            var batch: [AudioTapTiming] = []
            for _ in 0..<3 {
                // 回调时刻抖动 ±3 ms（tap 处理时刻不均匀；声音照样按播放器时钟放出来）
                let jitter = (jRandom() - 0.5) * 0.006
                batch.append(AudioTapTiming(host: host + jitter, itemStart: item, frames: 1024))
                host += 0.0213
                item += 0.0213 * rate
            }
            if k % 17 == 5 { batch.append(AudioTapTiming(host: host, itemStart: item + 30, frames: 1024)) }
            batch.append(AudioTapTiming(host: host, itemStart: .nan, frames: 1024))
            // 主线程这一刻读到的时钟：视频时间 item 在 host + lead 时被听到
            let snap = MediaClockSnapshot(host: host + lead, item: item, rate: rate)
            est.add(batch, clock: snap)
        }
        leads.append(String(format: "%.1f", est.lead * 1000))
        leadOK = leadOK && abs(est.lead - lead) < 0.0025 && est.samples.count == AudioTapLeadEstimator.sampleCapacity
    }
    var none = AudioTapLeadEstimator()
    none.add([AudioTapTiming(host: 1, itemStart: 1, frames: 10)], clock: MediaClockSnapshot(host: 1, item: 1, rate: 0))
    none.add([AudioTapTiming(host: 1, itemStart: .nan, frames: 10)], clock: MediaClockSnapshot(host: 1, item: 1, rate: 1))
    vcheck(leadOK && none.lead.isNaN && none.samples.isEmpty,
           "F0 tap 提前量：中位数 \(leads.joined(separator: " / ")) ms（应 120 / 45 / −20）；seek 离谱值、无效时钟 / 记录不进")
}
avFusionF0Checks()

// MARK: - av-fusion F1：声音特征 + 耦合度（只显示）

/// F1 合成声音（固定种子 LCG；24 kHz 省时间——设备上是 44.1 / 48 kHz，帧长 / 子块 / 降采样倍数都按采样率算）
struct AVSynth {
    static let rate: Double = 24_000
    var seed: UInt64
    init(seed: UInt64) { self.seed = seed }
    mutating func noise() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53) * 2 - 1
    }

    /// 咔哒串：每个时刻一下 20 毫秒衰减的宽带噪声
    static func clicks(_ times: [Double], amp: Double = 0.6) -> (Double, inout AVSynth) -> Double {
        let sorted = times.sorted()
        return { t, s in
            var x = 0.0
            var lo = 0
            var hi = sorted.count
            while lo < hi {
                let m = (lo + hi) / 2
                if sorted[m] <= t { lo = m + 1 } else { hi = m }
            }
            var k = lo - 1
            while k >= 0, t - sorted[k] < 0.15 {
                x += amp * exp(-(t - sorted[k]) / 0.02) * s.noise()
                k -= 1
            }
            return x
        }
    }

    /// 配乐：120 BPM 底鼓（每拍）+ 踩镲（每半拍）+ 持续的强力和弦（196 / 294 / 392 Hz）
    static func music(start: Double = 0, bpm: Double = 120, chord: Double = 0.12) -> (Double, inout AVSynth) -> Double {
        let beat = 60 / bpm
        var lastNoise = 0.0
        return { t, s in
            var x = chord * (sin(2 * .pi * 196 * t) + sin(2 * .pi * 294 * t) + sin(2 * .pi * 392 * t)) / 3
            let tt = t - start
            guard tt >= 0 else { return x }
            let kb = tt - (tt / beat).rounded(.down) * beat
            x += 0.7 * sin(2 * .pi * (55 * kb + 1.5 * (1 - exp(-kb / 0.03)))) * exp(-kb / 0.12)
            let half = beat / 2
            let kh = tt - (tt / half).rounded(.down) * half
            let n = s.noise()
            let hp = n - lastNoise
            lastNoise = n
            x += 0.25 * hp * exp(-kh / 0.015)
            return x
        }
    }

    /// 人声样：150 Hz 谐波（1/h）× 4 Hz 音节包络
    static func voice(f0: Double = 150) -> (Double, inout AVSynth) -> Double {
        { t, _ in
            var x = 0.0
            var h = 1.0
            while f0 * h < 4000 {
                x += sin(2 * .pi * f0 * h * t) / h
                h += 1
            }
            let env = 0.5 - 0.5 * cos(2 * .pi * 4 * t)
            return 0.25 * x * env
        }
    }

    /// 呻吟样：每 1.5 秒一声，200 → 350 Hz 滑音（6 个谐波），1.5 秒的正弦平方包络
    static func moan() -> (Double, inout AVSynth) -> Double {
        { t, _ in
            let p = 1.5
            let k = (t / p).rounded(.down)
            let u = t - k * p
            // 相位 = ∫ f：f = 200 + 150 u / p
            let phase = 2 * .pi * (200 * u + 75 * u * u / p)
            var x = 0.0
            for h in 1...6 { x += sin(Double(h) * phase) / Double(h) }
            let env = pow(sin(.pi * u / p), 2)
            return 0.3 * x * env
        }
    }

    static func whiteNoise(_ amp: Double = 0.2) -> (Double, inout AVSynth) -> Double { { _, s in amp * s.noise() } }

    static func hum(_ amp: Double = 0.3) -> (Double, inout AVSynth) -> Double {
        { t, _ in amp * (sin(2 * .pi * 50 * t) + 0.5 * sin(2 * .pi * 100 * t) + 0.25 * sin(2 * .pi * 150 * t)) }
    }

    static func floor(_ amp: Double = 0.004) -> (Double, inout AVSynth) -> Double { { _, s in amp * s.noise() } }
}

/// F1 测试用的一整条链：合成声音 → 6 段 splitter（+ P3 三频带）→ 每 0.3 秒一拍 AVFusionEngine.beat。
/// 画面相位锁按 hz(t)（nil = 不锁）每拍喂一个读数；倍速 1、host 时间 = 视频时间
struct AVF1Run {
    var beats: [(t: Double, b: AVFusionBeat)] = []
    var engine = AVFusionEngine()
    var frames = 0

    init(seconds: Double, signals: [(Double, inout AVSynth) -> Double], seed: UInt64 = 7,
         lockHz: Double? = nil, phase0: Double = 0, activity: Double = 0.5, cutAt: Double? = nil,
         relockAfterCut: Double = 1.0, chunk: Int = 512) {
        var synth = AVSynth(seed: seed)
        var splitter = AudioFeatureSplitter()
        splitter.configure(sampleRate: AVSynth.rate)
        var bands = AudioBandSplitter()
        bands.configure(sampleRate: AVSynth.rate)
        var lock = RhythmPhaseLock()
        var i = 0
        var tick = 0.0
        var drain = AudioFeatureDrain()
        drain.pcmRate = AudioFeatureSplitter.pcmRate(forSampleRate: AVSynth.rate)
        var bandFrames: [AudioBandFrame] = []
        var cutDone = false
        while tick + 0.3 <= seconds {
            tick += 0.3
            let end = Int(tick * AVSynth.rate)
            while i < end {
                let n = min(chunk, end - i)
                let start = Double(i) / AVSynth.rate
                splitter.begin(start: start, frames: n)
                bands.begin(start: start, frames: n)
                var f = AudioFeatureFrame()
                var p: Float = 0
                for j in 0..<n {
                    let t = Double(i + j) / AVSynth.rate
                    var x = 0.0
                    for s in signals { x += s(t, &synth) }
                    let flags = splitter.add(x, frame: &f, pcm: &p)
                    if flags & AudioFeatureSplitter.frameReady != 0 { drain.frames.append(f) }
                    if flags & AudioFeatureSplitter.pcmReady != 0 { drain.pcm.append(p) }
                    if let b = bands.add(x, at: t) { bandFrames.append(b) }
                }
                i += n
            }
            frames += drain.frames.count
            engine.addBands(bandFrames)
            engine.addFeatures(drain)
            bandFrames.removeAll()
            drain.frames.removeAll()
            drain.pcm.removeAll()
            let now = tick
            var cut = false
            if let c = cutAt, !cutDone, now >= c {
                cut = true
                cutDone = true
                lock.reset()
            }
            if let hz = lockHz, !(cutAt.map { now >= $0 && now < $0 + relockAfterCut } ?? false) {
                var w = MotionWindow()
                w.frames = 5
                w.subjectFrames = 5
                w.subjectScore = 0.5
                let tr = now - 0.03
                w.subjectPhase = StrokeRhythm.PhaseFit(time: tr, phase: StrokeRhythm.wrapPhase(2 * Double.pi * hz * tr + phase0),
                                                       hz: hz, quality: 0.9, linearity: 0.95, amplitude: 3, epoch: 0)
                lock.step(w, followerHz: hz, followerLocked: true, followerSource: .flow, now: now, dt: 0.3, active: true)
            }
            let clock = MediaClockSnapshot(host: now, item: now, rate: 1)
            let b = engine.beat(clock: clock, lock: lock, activity: activity, cut: cut, audioReady: true, dt: 0.3)
            beats.append((now, b))
        }
    }

    func first(_ ok: (AVFusionBeat) -> Bool) -> Double? { beats.first { ok($0.b) }?.t }
    var last: AVFusionBeat { beats.last!.b }
}

/// 画面相位 2π·hz·t（phase0 = 0）每过 0 一下咔哒（再偏 offset 秒）
func avClickTimes(hz: Double, from: Double, to: Double, offset: Double = 0) -> [Double] {
    var out: [Double] = []
    var k = (from * hz).rounded(.up)
    while k / hz <= to {
        out.append(k / hz + offset)
        k += 1
    }
    return out
}

func avFusionF1Checks() {
    func f2(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "—" }
    // 咔哒串和画面同步（1.6 Hz，咔哒落在画面相位 0）：4 秒内 C ≥ 0.6，回差 2 秒后进「耦合」并一直耦合
    let clicks = AVF1Run(seconds: 10, signals: [AVSynth.clicks(avClickTimes(hz: 1.6, from: 0.3, to: 12)), AVSynth.floor()],
                         lockHz: 1.6)
    let clickC = clicks.first { $0.c >= 0.6 }
    let clickIn = clicks.first { $0.state == .coupled }
    vcheck((clickC ?? 99) <= 4.0 + 1e-9 && (clickIn ?? 99) <= 6.3 + 1e-9 && clicks.last.state == .coupled
           && clicks.beats.filter { $0.t >= 7 }.allSatisfy { $0.b.coupled && $0.b.c >= 0.8 },
           "F1 咔哒串和画面同步：C ≥ 0.6 在 \(f2(clickC)) 秒（≤ 4），耦合在 \(f2(clickIn)) 秒，之后一直耦合")
    vcheck(clicks.beats.allSatisfy { $0.b.impacts <= 8 && $0.b.pMusic < 0.3 && $0.b.pVoice < 0.3 }
           && abs(clicks.last.fa - 1.6) < 0.05 && clicks.last.r > 0.9,
           "F1 咔哒串：撞击频率 \(f2(clicks.last.fa)) Hz ≈ 画面 1.6 Hz、相位集中度 \(f2(clicks.last.r))、不像配乐 / 人声")
    // 偏移 +150 毫秒的咔哒串：相位偏一个固定量，集中度不变 → 仍耦合
    let off = AVF1Run(seconds: 10, signals: [AVSynth.clicks(avClickTimes(hz: 1.6, from: 0.3, to: 12, offset: 0.15)),
                                              AVSynth.floor()], lockHz: 1.6)
    let offIn = off.first { $0.state == .coupled }
    vcheck((offIn ?? 99) <= 7 && off.last.state == .coupled && off.last.r > 0.9,
           "F1 偏移 +150 毫秒的咔哒串：仍耦合（\(f2(offIn)) 秒进入，集中度 \(f2(off.last.r))）")
    // 配乐 + 画面恰好同频（2 Hz）：切镜前看起来耦合；12 秒切镜、考验 2 秒节拍接上 → 像配乐，C ≤ 0.3、退出耦合
    let music = AVF1Run(seconds: 22, signals: [AVSynth.music()], lockHz: 2, cutAt: 12)
    let tested = music.beats.filter { $0.t >= 12.4 && $0.t < 13.9 }.allSatisfy { $0.b.state == .cutTest }
    let after = music.beats.filter { $0.t >= 17.5 }
    let musicOut = music.beats.first { $0.t > 14 && !$0.b.coupled }?.t
    vcheck(tested && after.allSatisfy { $0.b.c <= 0.3 && !$0.b.coupled && $0.b.crossCut == 1 && $0.b.pMusic >= 0.8 - 1e-9 }
           && music.last.state == .music && (musicOut ?? 99) <= 17,
           "F1 配乐 + 画面同频：切镜考验 2 秒、节拍接上 → 像配乐（P_music \(f2(music.last.pMusic))），"
           + "C \(f2(music.last.c)) ≤ 0.3，\(f2(musicOut)) 秒退出耦合")
    // 画面静止 + 配乐：画面不动时声音照样有节奏 → P_music ≥ 0.6，状态「像配乐」，不耦合
    let still = AVF1Run(seconds: 12, signals: [AVSynth.music()], activity: 0)
    vcheck(still.beats.filter { $0.t >= 4 }.allSatisfy { $0.b.pMusic >= 0.6 - 1e-9 && $0.b.still == 1 && !$0.b.coupled }
           && still.last.state == .music && still.beats.allSatisfy { $0.b.c == 0 },
           "F1 画面静止 + 配乐：P_music \(f2(still.last.pMusic)) ≥ 0.6，像配乐，C 一直 0")
    // 人声样 / 呻吟样：没有宽带短促的撞击（≤ 1 次/秒）、谐波度高 → P_voice ≥ 0.6，不耦合
    for (name, sig) in [("人声样", AVSynth.voice()), ("呻吟样", AVSynth.moan())] {
        let r = AVF1Run(seconds: 10, signals: [sig, AVSynth.floor()], lockHz: 1.6)
        let maxImpacts = r.beats.map { $0.b.impacts }.max() ?? 0
        vcheck(maxImpacts <= 4 && r.beats.filter { $0.t >= 2 }.allSatisfy { $0.b.pVoice >= 0.6 && !$0.b.coupled && $0.b.c < 0.1 }
               && r.last.state == .voice,
               "F1 \(name)：撞击最多 \(maxImpacts) 次 / 4 秒（≤ 1 次/秒），P_voice \(f2(r.last.pVoice)) ≥ 0.6，不耦合")
    }
    // 白噪声 / 50 Hz 哼声：没有起音 → 0 次撞击、不耦合
    for (name, sig) in [("白噪声", AVSynth.whiteNoise()), ("50 Hz 哼声", AVSynth.hum())] {
        let r = AVF1Run(seconds: 8, signals: [sig], lockHz: 1.6)
        vcheck(r.beats.allSatisfy { $0.b.impacts == 0 && $0.b.c == 0 && !$0.b.coupled } && r.engine.extractor.events.isEmpty
               && r.last.state == .uncoupled,
               "F1 \(name)：0 次撞击、C = 0、不耦合")
    }
    // 画面没锁相位：不耦合，状态「画面相位还没锁上」
    let unlocked = AVF1Run(seconds: 6, signals: [AVSynth.clicks(avClickTimes(hz: 1.6, from: 0.3, to: 12)), AVSynth.floor()])
    vcheck(unlocked.beats.allSatisfy { $0.b.c == 0 && !$0.b.coupled } && unlocked.last.state == .noLock,
           "F1 画面相位没锁：不耦合（状态 no_lock）")

    // 没声音 / 时间不可用
    var silent = AVFusionEngine()
    let silentBeat = silent.beat(clock: MediaClockSnapshot(host: 1, item: 1, rate: 1), lock: RhythmPhaseLock(), activity: 0.5,
                                 cut: false, audioReady: false, dt: 0.3)
    var noTime = AVFusionEngine()
    var bad = AudioFeatureDrain()
    bad.invalidChunks = 3
    noTime.addFeatures(bad)
    let noTimeBeat = noTime.beat(clock: MediaClockSnapshot(host: 1, item: 1, rate: 1), lock: RhythmPhaseLock(), activity: 0.5,
                                 cut: false, audioReady: true, dt: 0.3)
    let paused = silent.beat(clock: MediaClockSnapshot(host: 1, item: .nan, rate: 0), lock: RhythmPhaseLock(), activity: 0.5,
                             cut: false, audioReady: true, dt: 0.3)
    vcheck(silentBeat.state == .noAudio && noTimeBeat.state == .noTime && paused.state == .noAudio
           && silentBeat.statusText.hasPrefix("声画：没声音") && noTimeBeat.statusText.hasPrefix("声画：时间不可用")
           && music.last.statusText.hasPrefix("声画：像配乐") && clicks.last.statusText.hasPrefix("声画：耦合"),
           "F1 状态行：没声音 / 时间不可用 / 像配乐 / 耦合")

    // 实时线程部分：6 段 splitter 在 1~4096 帧随机切块下和一次喂完逐位相同
    func splitRun(_ samples: [Double], chunks: [Int], start: Double = 3.25, rate: Double = 48000)
        -> (frames: [AudioFeatureFrame], pcm: [Float]) {
        var sp = AudioFeatureSplitter()
        sp.configure(sampleRate: rate)
        var frames: [AudioFeatureFrame] = []
        var pcm: [Float] = []
        var i = 0
        var k = 0
        while i < samples.count {
            let n = min(chunks[k % chunks.count], samples.count - i)
            k += 1
            sp.begin(start: start + Double(i) / rate, frames: n)
            var f = AudioFeatureFrame()
            var p: Float = 0
            for j in 0..<n {
                let flags = sp.add(samples[i + j], frame: &f, pcm: &p)
                if flags & AudioFeatureSplitter.frameReady != 0 { frames.append(f) }
                if flags & AudioFeatureSplitter.pcmReady != 0 { pcm.append(p) }
            }
            i += n
        }
        return (frames, pcm)
    }
    var synth = AVSynth(seed: 99)
    let gen = AVSynth.music()
    let clickGen = AVSynth.clicks([0.2, 0.7, 1.1])
    let samples = (0..<72_000).map { j -> Double in
        let t = Double(j) / 48000
        return gen(t, &synth) + clickGen(t, &synth)
    }
    let whole = splitRun(samples, chunks: [samples.count])
    var chunkSame = !whole.frames.isEmpty && whole.frames.count == 150 && whole.pcm.count == 12_000
    var lcg: UInt64 = 0x5eed_f1
    for _ in 0..<6 {
        var chunks: [Int] = []
        for _ in 0..<64 {
            lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
            chunks.append(1 + Int((lcg >> 33) % 4096))
        }
        let r = splitRun(samples, chunks: chunks)
        if r.frames != whole.frames || r.pcm != whole.pcm { chunkSame = false }
    }
    vcheck(chunkSame && abs(whole.frames[0].time - (3.25 + 0.005)) < 1e-12 && whole.frames.allSatisfy { $0.totalEnergy > 0 },
           "F1 6 段 splitter：1~4096 帧随机切块和一次喂完逐位相同（\(whole.frames.count) 帧 / \(whole.pcm.count) 个 PCM）")
    // seek：没满的半帧丢掉，从新位置重新起算；时间拿不到（NaN）这一段不出帧
    var sp = AudioFeatureSplitter()
    sp.configure(sampleRate: 48000)
    var fr = AudioFeatureFrame()
    var pc: Float = 0
    var out: [AudioFeatureFrame] = []
    sp.begin(start: 1, frames: 720)
    for j in 0..<720 where sp.add(samples[j], frame: &fr, pcm: &pc) & AudioFeatureSplitter.frameReady != 0 { out.append(fr) }
    sp.begin(start: 20, frames: 480)
    for j in 0..<480 where sp.add(samples[j], frame: &fr, pcm: &pc) & AudioFeatureSplitter.frameReady != 0 { out.append(fr) }
    var nanCount = 0
    sp.begin(start: .nan, frames: 960)
    for j in 0..<960 where sp.add(samples[j], frame: &fr, pcm: &pc) != 0 { nanCount += 1 }
    var unknown = AudioFeatureSplitter()
    unknown.configure(sampleRate: .nan)
    unknown.begin(start: 0, frames: 10)
    vcheck(out.count == 2 && abs(out[0].time - 1.005) < 1e-12 && abs(out[1].time - 20.005) < 1e-12 && nanCount == 0
           && unknown.add(0.5, frame: &fr, pcm: &pc) == 0 && AudioFeatureSplitter.decimation(forSampleRate: 44100) == 6
           && AudioFeatureSplitter.decimation(forSampleRate: 48000) == 6 && AudioFeatureSplitter.decimation(forSampleRate: 0) == 0,
           "F1 6 段 splitter：seek 丢掉没满的半帧、从新位置起算；时间拿不到 / 采样率认不出不出帧")

    // AudioBandBacklog：融合每拍先取走、撞击声校正晚些再取 ≡ 校正单独从电平计环形缓冲（1024，满了丢最旧的）取
    var backlogSame = true
    var lcg2: UInt64 = 0xb4c1
    func rnd(_ n: Int) -> Int {
        lcg2 = lcg2 &* 6364136223846793005 &+ 1442695040888963407
        return Int((lcg2 >> 33) % UInt64(n))
    }
    for _ in 0..<200 {
        var refRing: [AudioBandFrame] = []      // 融合关着：只有校正取
        var fusedRing: [AudioBandFrame] = []    // 融合开着：两边都从它取
        var backlog = AudioBandBacklog()
        var t = 0.0
        for _ in 0..<40 {
            let produced = rnd(3) == 0 ? rnd(1500) : rnd(60)
            for _ in 0..<produced {
                t += 0.01
                let b = AudioBandFrame(time: t, low: Float(rnd(1000)), mid: Float(rnd(1000)), high: Float(rnd(1000)))
                refRing.append(b)
                fusedRing.append(b)
                if refRing.count > AudioLevelMeterRingModel.capacity { refRing.removeFirst() }
                if fusedRing.count > AudioLevelMeterRingModel.capacity { fusedRing.removeFirst() }
            }
            if rnd(4) != 0 {        // 融合这一拍取走
                backlog.keep(fusedRing)
                fusedRing.removeAll()
            }
            if rnd(3) == 0 {        // 校正这一拍取
                let a = refRing
                refRing.removeAll()
                let b = backlog.take(adding: fusedRing)
                fusedRing.removeAll()
                if a != b { backlogSame = false }
            }
        }
    }
    var plain = AudioBandBacklog()
    let fresh = [AudioBandFrame(time: 1, low: 1, mid: 2, high: 3)]
    vcheck(backlogSame && plain.take(adding: fresh) == fresh && plain.frames.isEmpty
           && AudioBandBacklog.capacity == AudioLevelMeterRingModel.capacity,
           "F1 频带块共用：融合先取 + backlog 接上 ≡ 校正单独取（200 组随机，含溢出）；backlog 空时原样返回")

    // 设置：默认关；读回存的值；只在跟随画面时生效；不改 Timer 间隔 / 其他开关
    let def = VisualSyncSettings()
    var on = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true, avFusion: true)
    let onAudio = VisualSyncSettings(source: .audio, avFusion: true)
    vcheck(!def.avFusion && !VisualSyncSettings.defaultAVFusion && VisualSyncSettings.Keys.avFusion == "bcVisualSyncAVFusion"
           && on.usesAVFusion && !onAudio.usesAVFusion && !def.usesAVFusion,
           "F1 设置：默认关、键名 bcVisualSyncAVFusion、只在跟随画面时生效（跟随声音不变）")
    let offTick = on.tickInterval
    let offAnchor = on.usesAudioAnchor
    on.avFusion = false
    vcheck(on.tickInterval == offTick && on.usesAudioAnchor == offAnchor && !on.usesAVFusion,
           "F1 设置：开关不改 Timer 间隔 / 撞击声校正 / 其他判断")
    if let defaults = UserDefaults(suiteName: "bc.visualsync.f1") {
        defaults.removePersistentDomain(forName: "bc.visualsync.f1")
        let none = VisualSyncSettings.load(from: defaults)
        defaults.set(true, forKey: VisualSyncSettings.Keys.avFusion)
        defaults.set(1, forKey: VisualSyncSettings.Keys.source)
        let stored = VisualSyncSettings.load(from: defaults)
        vcheck(!none.avFusion && stored.avFusion && stored.usesAVFusion, "F1 设置：没存过关、读回存的值")
        defaults.removePersistentDomain(forName: "bc.visualsync.f1")
    } else {
        vcheck(false, "F1 设置：创建测试用 UserDefaults")
    }

    // 调试列：表头 / 有数 / 空列 列数一致；NaN 写空
    let f1Count = AVDebugColumns.f1Header.split(separator: ",", omittingEmptySubsequences: false).count
    let full = AVDebugColumns.f1Fields(clicks.last)
    let empty = AVDebugColumns.f1Fields(AVFusionBeat())
    vcheck(f1Count == 21 && full.count == f1Count && empty.count == f1Count && AVDebugColumns.f1Empty.count == f1Count
           && AVDebugColumns.f1Empty.allSatisfy { $0.isEmpty } && full[0] == "coupled" && full[3] == "1"
           && empty[7] == "" && empty[18] == "" && empty[19] == "" && !full.joined().contains(",")
           && !(full + empty).contains { $0.contains("nan") || $0.contains("inf") },
           "F1 调试列：\(f1Count) 列，有数 / 空 / 占位列数一致；NaN 写空")
}

/// 电平计频带环形缓冲的容量（AudioLevelMeter 在 Linux 上编不了：照它的 bandCapacity 写一份）
enum AudioLevelMeterRingModel {
    static let capacity = 1024
}

avFusionF1Checks()

// MARK: - av-fusion F2：节奏由声音确认（默认关）

/// F2 测试里 AVF2Run 记下的一拍
struct AVF2Beat {
    var t: Double
    var raw: MotionWindow
    var input: MotionWindow
    var followerHz: Double
    var followerLocked: Bool
    var followerWeight: Double
    var lockLocked: Bool
    var fusion: AVFusionBeat
    var action: AVRhythmVote.Action
    var fastJump: Bool
    var anchorActive: Bool
    var anchorUncoupled: Bool
    var anchorOffset: Double
}

/// F2 的整条链（照 VideoSyncPlayer：rhythmLevel 里 P4 / P3 之后 AVRhythmVote（这里不跑 P4 / P3；看上一拍的融合状态、跟随器上一拍的结果）→
/// RhythmFollower（fastJumpHz）/ RhythmPhaseLock → updateFusion（AVFusionEngine.beat）→ updateAudioAnchor）。
/// 合成声音 24 kHz → 6 段 splitter + P3 三频带；倍速 1、host 时间 = 视频时间、每 0.3 秒一拍。
/// window(k, t)：第 k 拍（t 秒）的画面窗口；coupled：nil = 用上一拍的融合状态（S2 = AVRhythmVote.isS2：耦合且相位锁锁着），否则按给的（单元测试用）；
/// anchorGate：撞击声校正看不看耦合（= usesAVRhythmConfirm）
struct AVF2Run {
    var beats: [AVF2Beat] = []
    var engine = AVFusionEngine()

    init(seconds: Double, signals: [(Double, inout AVSynth) -> Double], seed: UInt64 = 7, vote voteOn: Bool,
         active: (Double) -> Bool = { _ in true }, coupled forced: ((Double) -> Bool)? = nil, anchorGate: Bool = false,
         window: (Int, Double) -> MotionWindow) {
        var synth = AVSynth(seed: seed)
        var splitter = AudioFeatureSplitter()
        splitter.configure(sampleRate: AVSynth.rate)
        var bands = AudioBandSplitter()
        bands.configure(sampleRate: AVSynth.rate)
        var follower = RhythmFollower()
        var lock = RhythmPhaseLock()
        var vote = AVRhythmVote()
        var onsets = AudioOnsetDetector()
        var anchor = AudioPhaseAnchor()
        var drain = AudioFeatureDrain()
        drain.pcmRate = AudioFeatureSplitter.pcmRate(forSampleRate: AVSynth.rate)
        var bandFrames: [AudioBandFrame] = []
        var last: AVFusionBeat?
        var i = 0
        var k = 0
        let dt = 0.3
        while Double(k + 1) * dt <= seconds + 1e-9 {
            k += 1
            let now = Double(k) * dt
            let end = Int((now * AVSynth.rate).rounded())
            while i < end {
                let n = min(512, end - i)
                let start = Double(i) / AVSynth.rate
                splitter.begin(start: start, frames: n)
                bands.begin(start: start, frames: n)
                var f = AudioFeatureFrame()
                var p: Float = 0
                for j in 0..<n {
                    let t = Double(i + j) / AVSynth.rate
                    var x = 0.0
                    for s in signals { x += s(t, &synth) }
                    let flags = splitter.add(x, frame: &f, pcm: &p)
                    if flags & AudioFeatureSplitter.frameReady != 0 { drain.frames.append(f) }
                    if flags & AudioFeatureSplitter.pcmReady != 0 { drain.pcm.append(p) }
                    if let b = bands.add(x, at: t) { bandFrames.append(b) }
                }
                i += n
            }
            // 复审 M4：照播放器——节奏确认开着时 motionTick 在投票前先 drainFusionAudio（投票看到的起音到「现在」）；
            // 关着时这一拍的声音在 updateFusion（跟随器 / 相位锁之后）才取走（对跟随器没影响，融合结果也一样）
            func feed() {
                engine.addBands(bandFrames)
                for b in bandFrames { onsets.add(b) }
                engine.addFeatures(drain)
                bandFrames.removeAll()
                drain.frames.removeAll()
                drain.pcm.removeAll()
            }
            if voteOn { feed() }
            let raw = window(k, now)
            let clock = MediaClockSnapshot(host: now, item: now, rate: 1)
            let isCoupled = forced.map { $0(now) } ?? AVRhythmVote.isS2(last)
            let input = vote.refine(raw, enabled: voteOn, coupled: isCoupled, events: engine.extractor.events,
                                    impactHz: last?.fa ?? 0, clock: clock, followerHz: follower.hz,
                                    followerLocked: follower.locked)
            let act = active(now)
            follower.step(input, dt: dt, active: act, fastJumpHz: vote.fastJumpHz)
            lock.step(input, followerHz: follower.hz, followerLocked: follower.locked, followerSource: follower.source,
                      now: now, dt: dt, active: act)
            if !voteOn { feed() }
            let b = engine.beat(clock: clock, lock: lock, activity: act ? 0.5 : 0, cut: raw.cutCount > 0, audioReady: true,
                                dt: dt)
            last = b
            let r = onsets.rhythm()
            let off = anchor.step(onsets: onsets.onsets(since: now - (AudioPhaseAnchor.windowSeconds + 0.5)), audioHz: r.hz,
                                  audioConfidence: r.confidence, lock: lock, directionKnown: false, now: now, dt: dt,
                                  coupled: anchorGate ? b.state == .coupled : nil)
            beats.append(AVF2Beat(t: now, raw: raw, input: input, followerHz: follower.hz, followerLocked: follower.locked,
                                  followerWeight: follower.weight, lockLocked: lock.locked, fusion: b, action: vote.action,
                                  fastJump: vote.fastJump, anchorActive: anchor.active, anchorUncoupled: anchor.uncoupled,
                                  anchorOffset: off))
        }
    }

    func near(_ hz: Double, _ x: Double) -> Bool { x > 0 && abs(log(x / hz)) <= log(1.15) }
}

/// F2 手搭的画面窗口：块运动跟随频率 hz（置信 conf、单程幅度 amp）；phaseHz 不为 nil 时带一个按 phaseHz 拟合的相位
/// （t − 0.03 秒、相位 2π·phaseHz·t + phase0）
func f2Window(_ t: Double, hz: Double, conf: Double = 0.6, amp: Double = 6, phaseHz: Double? = nil, phase0: Double = 0,
              cut: Bool = false) -> MotionWindow {
    var w = MotionWindow()
    w.frames = 5
    w.meanEnergy = 6
    w.peakEnergy = 8
    if cut { w.cutCount = 1 }
    w.subjectFrames = 5
    w.subjectScore = 0.5
    w.subjectHz = hz
    w.subjectFollowHz = hz
    w.subjectFollowRhythm = conf
    w.subjectFollowAmplitude = amp
    if let ph = phaseHz, !cut {
        let tr = t - 0.03
        w.subjectPhase = StrokeRhythm.PhaseFit(time: tr, phase: StrokeRhythm.wrapPhase(2 * Double.pi * ph * tr + phase0), hz: ph,
                                               quality: 0.9, linearity: 0.95, amplitude: 3, epoch: 0)
    }
    return w
}

/// F2 跳频：画面 x = 4·cos Φ(t)（15 Hz 采样、速度差分）→ 真的 StrokeRhythm（followEstimate + 相位拟合），
/// 咔哒落在 Φ ≡ 0（每个往复一下，和画面同相）；Φ 在 at 秒处从 f0 跳到 f1（相位连续）。
/// audioF1（复审 M4 的反例用）：咔哒在 at 秒处跳到这个频率（nil = 和画面一样跳到 f1）
func f2JumpRun(vote: Bool, f0: Double = 1, f1: Double = 1.6, audioF1: Double? = nil, at s: Double = 12,
               seconds: Double = 18) -> AVF2Run {
    func phi(_ t: Double) -> Double { t < s ? 2 * Double.pi * f0 * t : 2 * Double.pi * (f0 * s + f1 * (t - s)) }
    let af1 = audioF1 ?? f1
    var clicks: [Double] = []
    var m = 1.0
    while true {
        let t = m <= f0 * s ? m / f0 : s + (m - f0 * s) / af1
        if t > seconds + 1 { break }
        clicks.append(t)
        m += 1
    }
    var sr = StrokeRhythm()
    var ks = 1
    var prevX = 4 * cos(phi(0))
    return AVF2Run(seconds: seconds, signals: [AVSynth.clicks(clicks), AVSynth.floor()], vote: vote) { _, now in
        while Double(ks) / 15 <= now - 1e-9 {
            let t = Double(ks) / 15
            let x = 4 * cos(phi(t))
            sr.add(time: t, x: (x - prevX) * 15, y: 0)
            prevX = x
            ks += 1
        }
        let f = sr.followEstimate
        var w = MotionWindow()
        w.frames = 5
        w.meanEnergy = 6
        w.peakEnergy = 8
        w.subjectFrames = 5
        w.subjectScore = 0.5
        w.subjectHz = sr.estimate.hz
        w.subjectFollowHz = f.hz
        w.subjectFollowRhythm = f.confidence
        w.subjectFollowAmplitude = f.amplitude
        if f.hz > 0 { w.subjectPhase = sr.phaseFit(hz: f.hz) }
        return w
    }
}

/// F2 关着（enabled = false）/ 开着但不在 S2（coupled = false）：随机窗口逐位等于不走投票的链
func f2OffChainSame(events: [AudioOnsetEvent]) -> Bool {
    var lcg: UInt64 = 0xf2_0ff
    func rnd() -> Double {
        lcg = lcg &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(lcg >> 11) / Double(1 << 53)
    }
    var same = true
    var steps = 0
    for run in 0..<30 {
        var fa = RhythmFollower()
        var fb = RhythmFollower()
        var la = RhythmPhaseLock()
        var lb = RhythmPhaseLock()
        var aa = AudioPhaseAnchor()
        var ab = AudioPhaseAnchor()
        var vote = AVRhythmVote()
        let enabled = run % 2 == 1
        var now = 2.0
        for _ in 0..<100 {
            let dt = rnd() < 0.05 ? 0.6 * rnd() : 0.3
            now += dt
            var w = MotionWindow()
            w.frames = rnd() < 0.05 ? 0 : 5
            w.cutCount = rnd() < 0.04 ? 1 : 0
            w.heldCount = rnd() < 0.04 ? 1 : 0
            if rnd() < 0.9 {
                let hz = rnd() < 0.5 ? 1 + 0.1 * rnd() : (rnd() < 0.5 ? 2 + 0.2 * rnd() : 0.3 + 4 * rnd())
                w.subjectFrames = 5
                w.subjectScore = rnd()
                w.subjectFollowHz = hz
                w.subjectFollowRhythm = rnd()
                w.subjectFollowAmplitude = 4 * rnd()
                if rnd() < 0.8 {
                    w.subjectPhase = StrokeRhythm.PhaseFit(time: now - 0.05 * rnd(), phase: StrokeRhythm.wrapPhase(6.3 * rnd()),
                                                           hz: hz * (0.95 + 0.1 * rnd()), quality: rnd(), linearity: 0.5 + 0.5 * rnd(),
                                                           amplitude: 3 * rnd(), epoch: 0)
                }
            }
            if rnd() < 0.3 {
                w.poseFrames = 3
                w.posePresentFrames = 3
                w.poseScore = rnd()
                w.poseRhythmHz = 0.4 + 3 * rnd()
                w.poseRhythmConfidence = rnd()
                w.poseRhythmRate = 9
            }
            let act = rnd() < 0.9
            let clock = MediaClockSnapshot(host: now, item: 2 + 16 * rnd(), rate: rnd() < 0.9 ? 1 : 2)
            let input = vote.refine(w, enabled: enabled, coupled: false, events: events, impactHz: 2 * rnd(), clock: clock,
                                    followerHz: fb.hz, followerLocked: fb.locked)
            if input != w || vote.fastJump || vote.action != .none { same = false }
            fa.step(w, dt: dt, active: act)
            fb.step(input, dt: dt, active: act, fastJumpHz: vote.fastJumpHz)
            la.step(w, followerHz: fa.hz, followerLocked: fa.locked, followerSource: fa.source, now: now, dt: dt, active: act)
            lb.step(input, followerHz: fb.hz, followerLocked: fb.locked, followerSource: fb.source, now: now, dt: dt, active: act)
            var onsets: [Double] = []
            var t = now - 4
            while t < now { t += 0.3 + 0.4 * rnd(); onsets.append(t) }
            let ahz = 0.5 + 2 * rnd()
            let conf = rnd()
            let known = rnd() < 0.5
            let oa = aa.step(onsets: onsets, audioHz: ahz, audioConfidence: conf, lock: la, directionKnown: known, now: now, dt: dt)
            let ob = ab.step(onsets: onsets, audioHz: ahz, audioConfidence: conf, lock: lb, directionKnown: known, now: now,
                             dt: dt, coupled: nil)
            if oa.bitPattern != ob.bitPattern || aa.active != ab.active || ab.uncoupled { same = false }
            if fa.hz.bitPattern != fb.hz.bitPattern || fa.weight.bitPattern != fb.weight.bitPattern || fa.locked != fb.locked
                || fa.confidence.bitPattern != fb.confidence.bitPattern || la.weight.bitPattern != lb.weight.bitPattern
                || la.refPhase.bitPattern != lb.refPhase.bitPattern || la.hz.bitPattern != lb.hz.bitPattern {
                same = false
            }
            steps += 1
        }
    }
    return same && steps == 3000
}

/// 复审 H1：P3 动作识别的判断（动作类型 / 证据 / 部位 / 区域取舍 / 方向 / 轻抚 = activity / 强度上限 / 慢动作压低）
func f2ContextSame(_ a: ActionContext, _ b: ActionContext) -> Bool {
    a.kind == b.kind && a.evidence == b.evidence && a.part == b.part && a.usesHand == b.usesHand && a.usesFace == b.usesFace
        && a.usesRoi == b.usesRoi && a.usesOtherHips == b.usesOtherHips && a.selfPaced == b.selfPaced
        && a.flowDirection == b.flowDirection && a.poseDirection == b.poseDirection && a.inwardKnown == b.inwardKnown
        && a.quietSelf == b.quietSelf && a.suppressesRhythm == b.suppressesRhythm && a.intensityCeiling == b.intensityCeiling
        && a.allowsGentle(followerLocked: true) == b.allowsGentle(followerLocked: true)
        && a.allowsGentle(followerLocked: false) == b.allowsGentle(followerLocked: false) && a.directionKnown == b.directionKnown
}

/// 复审 H1：随机的 P3 输入（手 / 脸 / 髋的节奏、区域读数、整幅主体置信 0.15~0.5 跨过动作识别的 0.3 门），强制 S2、跟随器锁着。
/// 照播放器的顺序（AVRhythmVote.contextThenVote：先 P3 再投票）投票开 / 关时 P3 的判断逐位相同；
/// 旧顺序（投票在 P3 之前）同样的输入有拍不一样 = 这组输入确实碰得到（测试有牙）
func f2ContextIndependent(events: [AudioOnsetEvent]) -> (same: Bool, oldDiffers: Int, voted: Int, beats: Int) {
    var lcg: UInt64 = 0xf2_c0de
    func rnd() -> Double {
        lcg = lcg &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(lcg >> 11) / Double(1 << 53)
    }
    var same = true
    var oldDiffers = 0
    var voted = 0
    var beats = 0
    for _ in 0..<20 {
        var on = ActionContext()
        var off = ActionContext()
        var old = ActionContext()
        var voteOn = AVRhythmVote()
        var voteOld = AVRhythmVote()
        var t = 6.0
        for _ in 0..<40 {
            t += 0.3
            func part() -> (hz: Double, conf: Double, amp: Double)? {
                guard rnd() < 0.6 else { return nil }
                let hz = rnd() < 0.4 ? 2 : (rnd() < 0.5 ? 1 : 0.5 + 2.5 * rnd())
                return (hz, rnd(), 0.4 * rnd())
            }
            let subject = rnd() < 0.5 ? 2 * (0.97 + 0.06 * rnd()) : (rnd() < 0.5 ? 1 : 0.5 + 3 * rnd())
            var w = p3Window(time: t, hand: part(), face: rnd() < 0.3 ? part() : nil, hips: part(), subjectHz: subject,
                             handAt: rnd() < 0.5 ? (30, 22) : (32, 18))
            w.subjectFollowRhythm = 0.15 + 0.35 * rnd()
            if rnd() < 0.5 {
                var s = SubjectReading()
                s.valid = true
                s.score = 0.5
                s.followHz = rnd() < 0.5 ? 2 : 1 + rnd()
                s.followRhythm = w.subjectFollowRhythm - 0.05 + 0.15 * rnd()
                s.followAmplitude = 3
                w.roiFrames = 1
                w.roi.valid = true
                w.roi.time = t - 0.05
                w.roi.subject = s
            }
            let clock = MediaClockSnapshot(host: t, item: t, rate: 1)
            let lockHz = rnd() < 0.5 ? 2.0 : 0
            func vote(_ v: inout AVRhythmVote, _ x: MotionWindow) -> MotionWindow {
                v.refine(x, enabled: true, coupled: true, events: events, impactHz: 2, clock: clock, followerHz: 2,
                         followerLocked: true)
            }
            _ = AVRhythmVote.contextThenVote(w, context: { on.refine($0, now: t, followerHz: lockHz) },
                                             vote: { vote(&voteOn, $0) })
            _ = AVRhythmVote.contextThenVote(w, context: { off.refine($0, now: t, followerHz: lockHz) }, vote: nil)
            _ = old.refine(vote(&voteOld, w), now: t, followerHz: lockHz)
            if voteOn.action != .none || voteOn.fastJump { voted += 1 }
            if !f2ContextSame(on, off) { same = false }
            if !f2ContextSame(old, off) { oldDiffers += 1 }
            beats += 1
        }
    }
    return (same, oldDiffers, voted, beats)
}

func avFusionF2Checks() {
    func f2(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "—" }
    let clicks2 = AVSynth.clicks(avClickTimes(hz: 2, from: 0.3, to: 40))

    // 1a.（refine 的单元测试，复审 M3：耦合是强行给的，真链路里误报从头开始时不会耦合，见 1c）
    //     画面 2 Hz、15 fps 上半整数周期（7.5 格），halvedLag 没减半 → 块运动报 1 Hz；声音 2 Hz 咔哒、耦合（S2 从 3 秒起，单元测试直接给）
    //     → 窗口副本改成 2 Hz，跟随器 1.5 秒内正确锁在 2 Hz；不投票时一直锁在 1 Hz
    let misOn = AVF2Run(seconds: 9, signals: [clicks2, AVSynth.floor()], vote: true, coupled: { $0 >= 3 }) { _, t in
        f2Window(t, hz: 1, phaseHz: 1)
    }
    let misOff = AVF2Run(seconds: 9, signals: [clicks2, AVSynth.floor()], vote: false, coupled: { $0 >= 3 }) { _, t in
        f2Window(t, hz: 1, phaseHz: 1)
    }
    let corrected = misOn.beats.first { $0.t >= 3 && $0.followerLocked && misOn.near(2, $0.followerHz) }?.t
    let stays = misOn.beats.filter { $0.t >= (corrected ?? 99) }.allSatisfy { $0.followerLocked && misOn.near(2, $0.followerHz) }
    let octaveCopies = misOn.beats.filter { $0.t >= 3 }.allSatisfy {
        $0.action == .octaveUp && abs($0.input.subjectFollowHz - 2) < 1e-12 && abs($0.input.subjectFollowAmplitude - 3) < 1e-12
            && !$0.input.subjectPhase.isValid
    }
    let before = misOn.beats.filter { $0.t < 3 }.allSatisfy { $0.input == $0.raw && $0.action == .none }
    vcheck(corrected != nil && (corrected ?? 99) - 3 <= 1.5 + 1e-9 && stays && octaveCopies && before
           && misOff.beats.allSatisfy { !$0.followerLocked || misOff.near(1, $0.followerHz) },
           "F2 八度消歧：画面误报 1 Hz + 声音 2 Hz（耦合）→ 副本 2 Hz，\(f2(corrected.map { $0 - 3 })) 秒锁对（≤ 1.5）；不投票一直 1 Hz")

    // 1b. 端到端（真的耦合度）：画面 2 Hz，前 7 秒读数正确（耦合建立），之后每 3 拍里有 2 拍误报 1 Hz（相位拟合按错的八度，作废）。
    //     投票：跟随器一直锁在 2 Hz；不投票：跟随器被拉到 1 Hz
    func flaky(_ k: Int, _ t: Double) -> MotionWindow {
        t >= 7 && k % 3 != 0 ? f2Window(t, hz: 1) : f2Window(t, hz: 2, phaseHz: 2)
    }
    let flakyOn = AVF2Run(seconds: 18, signals: [clicks2, AVSynth.floor()], vote: true, window: flaky)
    let flakyOff = AVF2Run(seconds: 18, signals: [clicks2, AVSynth.floor()], vote: false, window: flaky)
    let coupledAt = flakyOn.beats.first { $0.fusion.state == .coupled }?.t
    let late = flakyOn.beats.filter { $0.t >= 7 }
    let wrongOn = late.filter { !($0.followerLocked && flakyOn.near(2, $0.followerHz)) }.count
    let wrongOff = flakyOff.beats.filter { $0.t >= 7 && !($0.followerLocked && flakyOff.near(2, $0.followerHz)) }.count
    vcheck((coupledAt ?? 99) < 7 && wrongOn == 0 && late.allSatisfy { $0.fusion.state == .coupled }
           && late.contains { $0.action == .octaveUp } && wrongOff >= 5,
           "F2 八度消歧端到端：\(f2(coupledAt)) 秒进入耦合；之后 2/3 拍误报 1 Hz，投票时跟随器一直 2 Hz、一直耦合；"
           + "不投票时 \(wrongOff) 拍不在 2 Hz")

    // 1c（复审 M3）端到端、持续误报：画面 2 Hz 前 7 秒读对（耦合建立），之后一直误报 1 Hz（相位作废）。
    //     F2 只桥接短暂翻八度：桥接有界（≤ 4 秒）后干净地回到画面的 1 Hz 一次、不来回摆，耦合退出；不投票时 1c 之后就是 1 Hz
    func sustained(_ k: Int, _ t: Double) -> MotionWindow {
        t >= 7 ? f2Window(t, hz: 1) : f2Window(t, hz: 2, phaseHz: 2)
    }
    let susOn = AVF2Run(seconds: 18, signals: [clicks2, AVSynth.floor()], vote: true, window: sustained)
    let susLate = susOn.beats.filter { $0.t >= 7 }
    let bridgeEnd = susLate.last { $0.followerLocked && susOn.near(2, $0.followerHz) }?.t
    let afterBridge = susLate.filter { $0.t > (bridgeEnd ?? 7) }
    var flips = 0
    for j in 1..<max(1, susLate.count) where susOn.near(2, susLate[j - 1].followerHz) != susOn.near(2, susLate[j].followerHz) { flips += 1 }
    vcheck(((bridgeEnd ?? 7) - 7) <= 4 + 1e-9 && flips <= 1
           && !afterBridge.contains { susOn.near(2, $0.followerHz) }
           && (susOn.beats.last.map { $0.fusion.state != .coupled } ?? false)
           && !afterBridge.suffix(5).contains { $0.action == .octaveUp },
           "F2 持续误报（7 秒后画面一直报 1 Hz）：桥接 \(f2(bridgeEnd.map { $0 - 7 })) 秒（≤ 4）后回到画面读数、切换 \(flips) 次（≤ 1）、耦合退出")

    // 一下两响（往里重、往外轻，半个周期隔开）：撞击间隔中位数 = 2 倍、强度加权的自相关 = 整周期 → 不干净，不改八度
    var twoClicks: [Double] = []
    var strong: [Double] = []
    for k in 1...30 {
        strong.append(Double(k))
        twoClicks.append(Double(k) + 0.5)
    }
    let inOut = AVF2Run(seconds: 12, signals: [AVSynth.clicks(strong, amp: 0.6), AVSynth.clicks(twoClicks, amp: 0.15), AVSynth.floor()],
                        vote: true, coupled: { $0 >= 6 }) { _, t in f2Window(t, hz: 1, phaseHz: 1) }
    let inOutLate = inOut.beats.filter { $0.t >= 6 }
    vcheck(inOutLate.allSatisfy { $0.action != .octaveUp && $0.action != .octaveDown && abs($0.input.subjectFollowHz - 1) < 1e-12 }
           && inOutLate.allSatisfy { $0.followerLocked && inOut.near(1, $0.followerHz) },
           "F2 一下两响（强弱不同）：不改八度，跟随器留在 1 Hz（f_a \(f2(inOut.beats.last?.fusion.fa))）")

    // 2. 同频配乐（120 BPM，画面 2 Hz，12 秒切镜）：考验后像配乐、不耦合 → 副本原样（逐位相同）、不投票
    let music = AVF2Run(seconds: 22, signals: [AVSynth.music()], vote: true) { _, t in
        abs(t - 12) < 0.15 ? f2Window(t, hz: 2, cut: true) : f2Window(t, hz: 2, phaseHz: 2)
    }
    var unchanged = true
    for (j, b) in music.beats.enumerated() where j == 0 || music.beats[j - 1].fusion.state != .coupled {
        if b.input != b.raw || b.action != .none || b.fastJump { unchanged = false }
    }
    let musicLate = music.beats.filter { $0.t >= 17.5 }
    vcheck(unchanged && musicLate.allSatisfy { $0.fusion.state == .music && $0.input == $0.raw && $0.action == .none }
           && (musicLate.last?.fusion.pMusic ?? 0) >= 0.8 - 1e-9,
           "F2 同频配乐：P_music \(f2(musicLate.last?.fusion.pMusic))、不耦合 → 窗口副本原样、不投票")

    // 3. 画面静止 + 有节奏的声音：activity = 0 → 不锁（即使给了耦合、画面有弱候选），投票不开锁
    let still = AVF2Run(seconds: 10, signals: [clicks2, AVSynth.floor()], vote: true, active: { _ in false },
                        coupled: { _ in true }) { _, t in f2Window(t, hz: 2, conf: 0.35, phaseHz: 2) }
    let stillNatural = AVF2Run(seconds: 10, signals: [clicks2, AVSynth.floor()], vote: true, active: { _ in false }) { _, t in
        f2Window(t, hz: 2, conf: 0.35, phaseHz: 2)
    }
    vcheck(still.beats.allSatisfy { !$0.followerLocked && $0.followerWeight == 0 && !$0.lockLocked }
           && stillNatural.beats.allSatisfy { !$0.followerLocked && $0.fusion.state != .coupled && $0.input == $0.raw },
           "F2 画面静止 + 有节奏的声音：不锁（activity 只看画面；给了耦合也不锁）")

    // 复审 M1：画面在动、块运动候选只有 0.35（画面自己锁不上：开锁门 0.40），强制耦合、声音同频——
    // 前 4 秒画面 0.6 先锁上，4 秒切镜（解锁）后只剩 0.35 的弱候选：投票开 / 关跟随器逐位相同，切镜后一直不锁
    func weak(_ k: Int, _ t: Double) -> MotionWindow {
        if abs(t - 4.2) < 0.15 { return f2Window(t, hz: 2, cut: true) }
        return f2Window(t, hz: 2, conf: t < 4 ? 0.6 : 0.35, phaseHz: 2)
    }
    let weakOn = AVF2Run(seconds: 12, signals: [clicks2, AVSynth.floor()], vote: true, coupled: { _ in true }, window: weak)
    let weakOff = AVF2Run(seconds: 12, signals: [clicks2, AVSynth.floor()], vote: false, coupled: { _ in true }, window: weak)
    let weakSame = zip(weakOn.beats, weakOff.beats).allSatisfy {
        $0.0.followerLocked == $0.1.followerLocked && $0.0.followerHz.bitPattern == $0.1.followerHz.bitPattern
            && $0.0.followerWeight.bitPattern == $0.1.followerWeight.bitPattern && $0.0.lockLocked == $0.1.lockLocked
    }
    let weakLockedEarly = weakOn.beats.contains { $0.t < 4 && $0.followerLocked }
    let weakAfterCut = weakOn.beats.filter { $0.t > 4.3 }.allSatisfy { !$0.followerLocked && $0.action == .none }
    let agreedWhileLocked = weakOn.beats.contains { $0.t < 4 && $0.action == .agree }
    var staleBeat = AVFusionBeat()
    staleBeat.state = .coupled
    staleBeat.fv = 0
    var freshBeat = staleBeat
    freshBeat.fv = 2
    vcheck(weakSame && weakLockedEarly && weakAfterCut && agreedWhileLocked && !AVRhythmVote.isS2(staleBeat)
           && AVRhythmVote.isS2(freshBeat) && !AVRhythmVote.isS2(nil),
           "F2 声音不开锁（复审 M1）：画面在动、弱候选 0.35 + 强制耦合 → 投票开 / 关跟随器逐位相同、切镜后不锁；"
           + "S2 要相位锁还锁着（耦合但 fv = 0 不算）")

    // 4. 跳频 1 → 1.6 Hz（12 秒），声音同样跳：耦合时跳变确认只要 1 拍，比不投票至少早 0.3 秒
    let jumpOn = f2JumpRun(vote: true)
    let jumpOff = f2JumpRun(vote: false)
    let thresh = 1.6 / 1.15
    let jOn = jumpOn.beats.first { $0.t > 12 && $0.followerHz >= thresh }?.t
    let jOff = jumpOff.beats.first { $0.t > 12 && $0.followerHz >= thresh }?.t
    let coupledBefore = jumpOn.beats.filter { $0.t >= 9 && $0.t < 12 }.allSatisfy { $0.fusion.state == .coupled }
    let sameBefore = zip(jumpOn.beats, jumpOff.beats).filter { $0.0.t < 12 }.allSatisfy {
        $0.0.followerLocked == $0.1.followerLocked && (!$0.0.followerLocked || jumpOn.near(1, $0.0.followerHz))
    }
    vcheck(jOn != nil && jOff != nil && (jOff ?? 0) - (jOn ?? 99) >= 0.3 - 1e-9 && coupledBefore && sameBefore
           && jumpOn.beats.contains { $0.fastJump },
           "F2 跳频 1 → 1.6 Hz：耦合时 \(f2(jOn)) 秒确认，不投票 \(f2(jOff)) 秒（早 \(f2((jOff ?? 0) - (jOn ?? 0))) 秒 ≥ 0.3）")

    // 复审 M4 反例 1：画面一直 1 Hz、只有声音在 12 秒跳到 1.6 Hz → 声音不发起跳频：从不 fastJump，跟随器和不投票逐位相同
    let audioOnlyOn = f2JumpRun(vote: true, f1: 1, audioF1: 1.6)
    let audioOnlyOff = f2JumpRun(vote: false, f1: 1, audioF1: 1.6)
    let audioOnlySame = zip(audioOnlyOn.beats, audioOnlyOff.beats).allSatisfy {
        $0.0.followerHz.bitPattern == $0.1.followerHz.bitPattern && $0.0.followerLocked == $0.1.followerLocked
    }
    vcheck(audioOnlySame && !audioOnlyOn.beats.contains { $0.fastJump }
           && audioOnlyOn.beats.filter { $0.t > 13 }.allSatisfy { $0.followerLocked && audioOnlyOn.near(1, $0.followerHz) },
           "F2 只有声音变速（画面一直 1 Hz、声音跳到 1.6 Hz）：不 fastJump，跟随器和不投票逐位相同、留在 1 Hz")
    // 复审 M4 反例 2：画面 1 → 1.6 Hz、声音反方向 1 → 0.625 Hz → 从不 fastJump，跟随器和不投票逐位相同（跳变照常 2 拍确认）
    let oppositeOn = f2JumpRun(vote: true, audioF1: 0.625)
    let oppositeOff = f2JumpRun(vote: false, audioF1: 0.625)
    let oppositeSame = zip(oppositeOn.beats, oppositeOff.beats).allSatisfy {
        $0.0.followerHz.bitPattern == $0.1.followerHz.bitPattern && $0.0.followerLocked == $0.1.followerLocked
    }
    let oppositeJump = oppositeOn.beats.first { $0.t > 12 && $0.followerHz >= thresh }?.t
    vcheck(oppositeSame && !oppositeOn.beats.contains { $0.fastJump } && oppositeJump != nil,
           "F2 声音反方向跳（画面 1 → 1.6、声音 1 → 0.625 Hz）：不 fastJump，跟随器和不投票逐位相同（\(f2(oppositeJump)) 秒照常确认）")

    // 复审 M2：声音核对的是块运动读数（1.6 Hz），跟随器这一拍却挑了反方向的姿态读数（0.6 Hz，置信更高、采样率看得清）→
    // fastJumpHz 不缩短确认，逐位等于不给；跟随器挑的就是块运动读数时 1 拍就跳
    func poseWindow(_ t: Double, flow: Double, pose: Double?) -> MotionWindow {
        var w = f2Window(t, hz: flow)
        if let p = pose {
            w.poseFrames = 3
            w.posePresentFrames = 3
            w.poseScore = 0.5
            w.poseRhythmHz = p
            w.poseRhythmConfidence = 0.8
            w.poseRhythmPart = 1
            w.poseRhythmRate = 9
        }
        return w
    }
    var withTarget = RhythmFollower()
    var plain = RhythmFollower()
    var flowOnly = RhythmFollower()
    var pt = 0.0
    for _ in 0..<10 {
        pt += 0.3
        let w = poseWindow(pt, flow: 1, pose: 1)
        withTarget.step(w, dt: 0.3)
        plain.step(w, dt: 0.3)
        flowOnly.step(w, dt: 0.3)
    }
    var poseSame = withTarget.locked && abs(withTarget.hz - 1) < 1e-9
    var poseHz: [Double] = []
    var flowHz: [Double] = []
    for _ in 0..<3 {
        pt += 0.3
        let w = poseWindow(pt, flow: 1.6, pose: 0.6)
        withTarget.step(w, dt: 0.3, fastJumpHz: 1.6)
        plain.step(w, dt: 0.3)
        flowOnly.step(poseWindow(pt, flow: 1.6, pose: nil), dt: 0.3, fastJumpHz: 1.6)
        if withTarget.hz.bitPattern != plain.hz.bitPattern || withTarget.locked != plain.locked
            || withTarget.weight.bitPattern != plain.weight.bitPattern || withTarget.source != plain.source {
            poseSame = false
        }
        poseHz.append(withTarget.hz)
        flowHz.append(flowOnly.hz)
    }
    vcheck(poseSame && withTarget.source == .pose && abs(poseHz[0] - 1) < 0.05 && abs(flowHz[0] - 1.6) < 1e-9,
           "F2 跳频确认只认声音核对过的读数（复审 M2）：跟随器挑了反方向的姿态读数时不缩（第 1 拍仍 \(f2(poseHz[0])) Hz，"
           + "和不给目标逐位相同）；挑的是块运动读数时 1 拍跳到 \(f2(flowHz[0])) Hz")

    // 5. 撞击声校正 + 同频节拍音轨（2 Hz 咔哒跨 12 秒切镜不断 = 配乐）：F2 开着（要耦合）时考验后不再「已对齐」，
    //    关着时（= P3）照旧对齐
    let beatTrack = AVSynth.clicks(avClickTimes(hz: 2, from: 0.3, to: 40, offset: 0.1))
    let anchorOff = AVF2Run(seconds: 22, signals: [beatTrack, AVSynth.floor()], vote: false, anchorGate: false) { _, t in
        abs(t - 12) < 0.15 ? f2Window(t, hz: 2, cut: true) : f2Window(t, hz: 2, phaseHz: 2)
    }
    let anchorOn = AVF2Run(seconds: 22, signals: [beatTrack, AVSynth.floor()], vote: true, anchorGate: true) { _, t in
        abs(t - 12) < 0.15 ? f2Window(t, hz: 2, cut: true) : f2Window(t, hz: 2, phaseHz: 2)
    }
    let offAligned = anchorOff.beats.filter { $0.t >= 17.5 && $0.anchorActive }.count
    let onLate = anchorOn.beats.filter { $0.t >= 17.5 }
    vcheck(offAligned > 0 && onLate.allSatisfy { !$0.anchorActive && $0.anchorUncoupled && $0.fusion.state == .music }
           && anchorOff.beats.allSatisfy { !$0.anchorUncoupled } && anchorOn.beats.contains { $0.anchorActive },
           "F2 撞击声校正 + 同频节拍音轨：关着 \(offAligned) 拍「已对齐」，开着（要耦合）切镜考验认出配乐后不对齐")

    // 6. 开关关着 / 不在 S2：3000 组随机窗口逐位等于 P4 的链（跟随器 / 相位锁 / 撞击声校正），窗口副本原样、fastJump 恒 false
    vcheck(f2OffChainSame(events: flakyOn.engine.extractor.events), "F2 关着 / 不耦合：3000 组随机窗口和 P4 的链逐位相同")

    // 复审 H1：投票排在 P3 动作识别之后——动作识别的判断（activity / 强度上限 / 区域取舍…）和投票开关无关
    let ctx = f2ContextIndependent(events: flakyOn.engine.extractor.events)
    vcheck(ctx.same && ctx.oldDiffers > 0 && ctx.voted > 0,
           "F2 投票不进 P3 动作识别（复审 H1）：\(ctx.beats) 拍随机输入、投票 \(ctx.voted) 拍，开 / 关时动作识别逐位相同"
           + "（旧顺序「投票在 P3 前」\(ctx.oldDiffers) 拍不同）")

    // 设置：默认关、键名、只在融合 + 伸缩跟随频率 + 跟随画面时生效、不改 Timer 间隔
    let def = VisualSyncSettings()
    let on = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true, avFusion: true, avRhythmConfirm: true)
    let noFollow = VisualSyncSettings(source: .motion, rhythmFollow: false, avFusion: true, avRhythmConfirm: true)
    let noFusion = VisualSyncSettings(source: .motion, rhythmFollow: true, avFusion: false, avRhythmConfirm: true)
    let audio = VisualSyncSettings(source: .audio, rhythmFollow: true, avFusion: true, avRhythmConfirm: true)
    var offF2 = on
    offF2.avRhythmConfirm = false
    vcheck(!def.avRhythmConfirm && !VisualSyncSettings.defaultAVRhythmConfirm && !def.usesAVRhythmConfirm
           && VisualSyncSettings.Keys.avRhythmConfirm == "bcVisualSyncAVRhythmConfirm" && on.usesAVRhythmConfirm
           && !noFollow.usesAVRhythmConfirm && !noFusion.usesAVRhythmConfirm && !audio.usesAVRhythmConfirm
           && on.tickInterval == offF2.tickInterval && on.usesAudioAnchor == offF2.usesAudioAnchor && offF2.usesAVFusion,
           "F2 设置：默认关、键名 bcVisualSyncAVRhythmConfirm、要融合 + 伸缩跟随频率 + 跟随画面，不改 Timer 间隔 / 其他判断")
    if let defaults = UserDefaults(suiteName: "bc.visualsync.f2") {
        defaults.removePersistentDomain(forName: "bc.visualsync.f2")
        let none = VisualSyncSettings.load(from: defaults)
        defaults.set(true, forKey: VisualSyncSettings.Keys.avRhythmConfirm)
        let stored = VisualSyncSettings.load(from: defaults)
        vcheck(!none.avRhythmConfirm && stored.avRhythmConfirm && !stored.usesAVRhythmConfirm, "F2 设置：没存过关、读回存的值")
        defaults.removePersistentDomain(forName: "bc.visualsync.f2")
    } else {
        vcheck(false, "F2 设置：创建测试用 UserDefaults")
    }

    // 复审 L2–L6
    func evs(_ hz: Double, from a: Double = 0.2, to b: Double) -> [AudioOnsetEvent] {
        var out: [AudioOnsetEvent] = []
        var t = a
        while t <= b { out.append(AudioOnsetEvent(time: t, strength: 30, risingBands: 6, steepBands: 6, shortBands: 6)); t += 1 / hz }
        return out
    }
    // L2：倍速 2、视频里 0.3 Hz（画面上 0.6 Hz，在跟随器范围里）→ 按倍速搜得到；倍速 1 时 0.3 Hz 不在范围、搜不到
    let slow = evs(0.3, to: 20)
    let at2 = AVRhythmVote.audioRhythm(slow, start: 0, end: 20, rate: 2)
    let at1 = AVRhythmVote.audioRhythm(slow, start: 0, end: 20, rate: 1)
    vcheck(abs(at2.hz - 0.3) / 0.3 < 0.1 && !(abs(at1.hz - 0.3) / 0.3 < 0.1),
           "F2 L2 声音滞后搜索按倍速：2× 时找到视频 0.3 Hz（\(f2(at2.hz))），1× 时不找（\(f2(at1.hz))）")
    // L3：画面 2.1 Hz、声音 3.9 Hz（像两倍）→ 换过去 4.2 Hz 超出跟随器范围，不换；画面 1.95 Hz 时照常换到 3.9
    let fast = evs(3.9, to: 10)
    let clk = MediaClockSnapshot(host: 10, item: 10, rate: 1)
    var v3 = AVRhythmVote()
    let o3 = v3.refine(f2Window(10, hz: 2.1, phaseHz: 2.1), enabled: true, coupled: true, events: fast, impactHz: 3.9, clock: clk,
                       followerHz: 2.1, followerLocked: true)
    var v3b = AVRhythmVote()
    let o3b = v3b.refine(f2Window(10, hz: 1.95, phaseHz: 1.95), enabled: true, coupled: true, events: fast, impactHz: 3.9,
                         clock: clk, followerHz: 1.95, followerLocked: true)
    vcheck(v3.action != .octaveUp && abs(o3.subjectFollowHz - 2.1) < 1e-12 && v3b.action == .octaveUp
           && abs(o3b.subjectFollowHz - 3.9) < 1e-9,
           "F2 L3 换八度要落在跟随器范围：2.1 Hz 不换到 4.2（声音 \(f2(v3.audioHz))）、1.95 Hz 换到 3.9")
    // L4：画面 1.6 Hz、声音最近也 1.6、跟随器还在 1 Hz → 平时 1 拍确认；P4 前瞻频率接管时不缩短
    let jumpEv = evs(1.6, to: 10)
    var v4 = AVRhythmVote()
    _ = v4.refine(f2Window(10, hz: 1.6, phaseHz: 1.6), enabled: true, coupled: true, events: jumpEv, impactHz: 1.6, clock: clk,
                  followerHz: 1, followerLocked: true)
    var v4b = AVRhythmVote()
    _ = v4b.refine(f2Window(10, hz: 1.6, phaseHz: 1.6), enabled: true, coupled: true, events: jumpEv, impactHz: 1.6, clock: clk,
                   followerHz: 1, followerLocked: true, lookaheadFrequency: true)
    vcheck(v4.fastJump && v4.fastJumpHz > 0 && !v4b.fastJump && v4b.fastJumpHz == 0,
           "F2 L4 P4 前瞻频率接管时不缩短跳频确认（平时 fastJump \(v4.fastJump)，前瞻时 \(v4b.fastJump)）")
    // L5：相位脉动关着 → 节奏确认不生效
    let noPulse = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: false, avFusion: true, avRhythmConfirm: true)
    vcheck(!noPulse.usesAVRhythmConfirm && noPulse.usesAVFusion, "F2 L5 相位脉动关着时节奏确认不生效（融合照旧）")
    // L6：融合特征要不要算的真值表
    var table = true
    for m in 0..<8 {
        let a = m & 1 != 0, r = m & 2 != 0, z = m & 4 != 0
        if VisualSyncSettings.fusionFeaturesWanted(usesAVFusion: a, running: r, analyzing: z) != (a && r && z) { table = false }
    }
    vcheck(table, "F2 L6 fusionFeaturesWanted 真值表（融合 && 在联动 && 画面分析在跑）")

    // 调试列 / 状态行
    let f2Count = AVDebugColumns.f2Header.split(separator: ",", omittingEmptySubsequences: false).count
    var someVote = AVRhythmVote()
    _ = someVote.refine(f2Window(5, hz: 1, phaseHz: 1), enabled: true, coupled: true, events: misOn.engine.extractor.events,
                        impactHz: 2, clock: MediaClockSnapshot(host: 5, item: 5, rate: 1), followerHz: 1, followerLocked: true)
    let fields = AVDebugColumns.f2Fields(someVote)
    vcheck(f2Count == 5 && fields.count == f2Count && AVDebugColumns.f2Empty.count == f2Count
           && AVDebugColumns.f2Empty.allSatisfy { $0.isEmpty } && fields[0] == "octave_up" && fields[4] == "1"
           && !fields.joined().contains(",") && someVote.statusText.hasPrefix("节奏确认：画面读成了一半")
           && AVRhythmVote().statusText.hasPrefix("节奏确认：没有投票"),
           "F2 调试列 \(f2Count) 列 / 状态行（八度改正：\(fields.joined(separator: " "))）")
}

avFusionF2Checks()

/// av-fusion F3 / F3b 的检查（放在函数里：顶层 main 离 8 MB 栈上限很近）
func avFusionF3Checks() {
    var seed: UInt64 = 0xF3F3
    func rnd() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }
    func ev(_ t: Double, _ strength: Double = 30) -> AudioOnsetEvent {
        AudioOnsetEvent(time: t, strength: strength, risingBands: 6, steepBands: 6, shortBands: 6)
    }
    func s2Beat(pMusic: Double = 0, crossCut: Double = 0, still: Double = 0) -> AVFusionBeat {
        var b = AVFusionBeat()
        b.state = .coupled
        b.coupled = true
        b.fv = 0.5
        b.pMusic = pMusic
        b.crossCut = crossCut
        b.still = still
        return b
    }
    func clock(_ t: Double, rate: Double = 1) -> MediaClockSnapshot { MediaClockSnapshot(host: t, item: t, rate: rate) }
    // 1 Hz 撞击，最后一下（t = 9.9）的强度可调
    func train(last: Double, base: Double = 30, shift: Double = 0) -> [AudioOnsetEvent] {
        var out: [AudioOnsetEvent] = []
        for k in 0..<9 { out.append(ev(1.9 + Double(k), base + shift)) }
        out.append(ev(9.9, last + shift))
        return out
    }

    // 设置：默认关、键名、深度夹 0~30、生效条件
    let def = VisualSyncSettings()
    let on = VisualSyncSettings(source: .motion, rhythmFollow: true, rhythmPulse: true, avFusion: true, avAccent: true,
                                avVibrationAudio: true)
    let noFusion = VisualSyncSettings(source: .motion, avFusion: false, avAccent: true, avVibrationAudio: true)
    var noPulse = on
    noPulse.rhythmPulse = false
    let audioSrc = VisualSyncSettings(source: .audio, avFusion: true, avAccent: true, avVibrationAudio: true)
    let subOnly = VisualSyncSettings(source: .motion, avFusion: true, avAccent: false, avVibrationAudio: true)
    var off3 = on
    off3.avAccent = false
    off3.avVibrationAudio = false
    vcheck(!def.avAccent && !def.avVibrationAudio && def.avAccentDepth == 15 && !def.usesAVAccent && !def.usesAVVibrationAudio
           && VisualSyncSettings.Keys.avAccent == "bcVisualSyncAVAccent"
           && VisualSyncSettings.Keys.avAccentDepth == "bcVisualSyncAVAccentDepth"
           && VisualSyncSettings.Keys.avVibrationAudio == "bcVisualSyncAVVibrationAudio"
           && on.usesAVAccent && on.usesAVVibrationAudio && !noFusion.usesAVAccent && !audioSrc.usesAVAccent
           && !noPulse.usesAVAccent && !noPulse.usesAVVibrationAudio
           && !subOnly.usesAVVibrationAudio && on.tickInterval == off3.tickInterval
           && VisualSyncSettings(avAccentDepth: 99).avAccentDepth == 30 && VisualSyncSettings(avAccentDepth: -5).avAccentDepth == 0
           && VisualSyncSettings(avAccentDepth: .nan).avAccentDepth == 15,
           "F3 设置：默认关、键名、深度夹 0~30（NaN → 15）、重音要融合、F3b 要重音，不改 Timer 间隔")

    // 重音系数：S2 + 最近一个周期里有撞击才 ≠ 1；响 → 1 + β，轻 → 1 − β，一样响 → 1；不在 S2 / 撞击不够 / 这个周期没撞击 → 1
    var a = AVAccent()
    let loud = a.step(events: train(last: 90 + 6 * 20, base: 90), clock: clock(10), s2: true, lockHz: 1, depth: 0.15)
    let quiet = a.step(events: train(last: 90 - 6 * 10, base: 90), clock: clock(10), s2: true, lockHz: 1, depth: 0.15)
    let same = a.step(events: train(last: 90, base: 90), clock: clock(10), s2: true, lockHz: 1, depth: 0.15)
    let notS2 = a.step(events: train(last: 90 + 6 * 20, base: 90), clock: clock(10), s2: false, lockHz: 1, depth: 0.15)
    let few = a.step(events: [ev(9.5, 90), ev(9.9, 150)], clock: clock(10), s2: true, lockHz: 1, depth: 0.15)
    let stale = a.step(events: train(last: 150), clock: clock(11.5), s2: true, lockHz: 1, depth: 0.15)
    let noLock = a.step(events: train(last: 150), clock: clock(10), s2: true, lockHz: 0, depth: 0.15)
    let zeroDepth = a.step(events: train(last: 150), clock: clock(10), s2: true, lockHz: 1, depth: 0)
    vcheck(abs(loud - 1.15) < 1e-12 && abs(quiet - 0.85) < 1e-12 && abs(same - 1) < 1e-12
           && notS2 == 1 && few == 1 && stale == 1 && noLock == 1 && zeroDepth == 1,
           "F3 重音系数：响 \(String(format: "%.3f", loud))、轻 \(String(format: "%.3f", quiet))、一样 1；不在 S2 / 撞击 < 3 / 这个周期没撞击 / 没锁 / 深度 0 → 1")
    // 整体响度抬 12 dB（各段都 +12）：g 不变；随机输入 g ∈ [1 − β, 1 + β]
    let lifted = a.step(events: train(last: 30 + 6 * 7, shift: 6 * 12), clock: clock(10), s2: true, lockHz: 1, depth: 0.2)
    let plain = a.step(events: train(last: 30 + 6 * 7), clock: clock(10), s2: true, lockHz: 1, depth: 0.2)
    var bounded = true
    for _ in 0..<5000 {
        var evs: [AudioOnsetEvent] = []
        var t = 6 + rnd() * 0.5
        while t < 10 { evs.append(ev(t, rnd() < 0.05 ? .nan : rnd() * 300 - 20)); t += 0.2 + rnd() * 0.8 }
        let beta = rnd() < 0.05 ? Double.nan : rnd() * 0.5
        let g = a.step(events: evs, clock: clock(10, rate: 0.5 + rnd() * 1.5), s2: rnd() < 0.8, lockHz: 0.3 + rnd() * 4,
                       depth: beta)
        let bb = beta.isFinite ? min(0.3, max(0, beta)) : 0
        if !(g.isFinite && g >= 1 - bb - 1e-12 && g <= 1 + bb + 1e-12) { bounded = false }
    }
    vcheck(abs(lifted - plain) < 1e-9 && plain > 1 && bounded,
           "F3 重音：整体 +12 dB 时 g 不变（\(String(format: "%.4f", plain))）；5000 组随机 g ∈ [1 − β, 1 + β]（β 夹 0~0.3）")

    // 脉动深度上界：随机设置 / 频率 / 权重下 depth ≤ depthCeiling（重音放大也不超过满深度）
    var ceilingOK = true
    for _ in 0..<2000 {
        let setting = rnd() * 40, hz = rnd() * 3, w = rnd(), act = rnd(), inten = Int(rnd() * 100)
        let d = RhythmPulse.depth(setting: setting, hz: hz, weight: w, activity: act, intensity: inten)
        if d > RhythmPulse.depthCeiling(setting: setting, hz: hz) { ceilingOK = false }
    }
    vcheck(ceilingOK, "F3 重音调脉动：有效深度 ≤ 这个设置 / 频率下的满深度（2000 组随机）")

    // 5000 组随机（强度、z、上限、最低强度、通道）× 重音 / F3b → 出口：≤ 上限、单拍升 ≤ 20、归零保持、通道 2 / 3 = 0、NaN → 0
    var stage = SyncOutputStage()
    var prev = [0, 0, 0, 0]
    let heldRun = SyncOutputStage.zeroHoldTicks + 1
    var zeroRun = [heldRun, heldRun]
    var ok = true
    var bad = ""
    var vib = AVVibrationAudio()
    let channels = AudioSyncChannels.allCases
    var tNow = 0.0
    for i in 0..<5000 {
        if i % 200 == 0 { stage.reset(); prev = [0, 0, 0, 0]; zeroRun = [heldRun, heldRun]; vib.reset() }
        tNow += 0.3
        let st = AudioSyncSettings(maxPercent: 5 + rnd() * 100, channels: channels[Int(rnd() * 3) % 3], minPercent: rnd() * 60)
        let value = rnd() < 0.05 ? Double.nan : rnd() * 120 - 10
        let sig = rnd() < 0.85
        let beta = rnd() * 0.3
        let g = 1 + beta * (rnd() * 2 - 1)
        let accented = value.isFinite ? min(100, max(0, value * g)) : value
        var levels = RhythmOutput.target(value: accented, settings: st, hasSignal: sig, rateLevel: Int(rnd() * 99),
                                         weight: rnd())
        let fp = SyncOutputStage.floorPercent(settings: st, hasSignal: sig)
        var evs: [AudioOnsetEvent] = []
        var et = tNow - 4
        while et < tNow { evs.append(ev(et, rnd() * 200)); et += 0.2 + rnd() * 0.6 }
        levels[1] = vib.step(video: levels[1], floor: fp.isFinite ? max(0, Int(fp.rounded())) : 0, events: evs,
                             clock: clock(tNow), beat: rnd() < 0.7 ? s2Beat(pMusic: rnd() * 0.4) : nil,
                             activity: rnd() < 0.8 ? rnd() : 0, channelsBoth: st.channels == .both, depth: beta,
                             now: tNow, dt: 0.3)
        let out = stage.step(levels: levels, settings: st)
        let cap = SyncOutputStage.hardCap(st)
        if out.count != 4 || out[2] != 0 || out[3] != 0 { ok = false; bad = "通道 \(out)" }
        for ch in 0..<2 {
            if out[ch] < 0 || out[ch] > cap { ok = false; bad = "上限 \(out) cap \(cap)" }
            if out[ch] - prev[ch] > SyncOutputStage.maxRisePerTick { ok = false; bad = "升幅 \(prev) → \(out)" }
            if out[ch] > 0, prev[ch] == 0, zeroRun[ch] < heldRun { ok = false; bad = "归零保持 \(zeroRun[ch]) 拍" }
            zeroRun[ch] = out[ch] == 0 ? min(heldRun, zeroRun[ch] + 1) : 0
        }
        prev = out
    }
    vcheck(ok, "F3 / F3b：5000 组随机（强度、重音、上限、最低强度、通道、声音）经出口后 ≤ 上限、单拍升 ≤ 20、归零保持、通道 2 / 3 = 0 \(bad)")
    // 时间折算的出口：按实际间隔升幅 ≤ 20 × Δt / 0.3 + 1
    var timedStage = SyncOutputStage()
    var tPrev = [0, 0, 0, 0]
    var tt = 0.0
    var timedOK = true
    for _ in 0..<2000 {
        let dt = 0.1 + rnd() * 0.3
        tt += dt
        let st = AudioSyncSettings(maxPercent: 30 + rnd() * 70, channels: .both, minPercent: rnd() * 30)
        let g = 1 + 0.3 * (rnd() * 2 - 1)
        let lv = RhythmOutput.target(value: min(100, rnd() * 100 * g), settings: st, hasSignal: true, rateLevel: nil, weight: 0)
        let out = timedStage.step(levels: lv, settings: st, now: tt, timed: true)
        for ch in 0..<2 where Double(out[ch] - tPrev[ch]) > 20 * dt / 0.3 + 1 { timedOK = false }
        tPrev = out
    }
    vcheck(timedOK, "F3：按时间的出口升幅 ≤ 20 × Δt / 0.3 + 1（2000 组随机间隔）")

    // F3b 四道门：不满足 → 逐位等于画面值
    func vibRun(_ beat: AVFusionBeat?, activity: Double = 0.5, both: Bool = true, video: Int = 50,
                beats: Int = 12) -> [Int] {
        var v = AVVibrationAudio()
        var out: [Int] = []
        for k in 0..<beats {
            let t = 10 + Double(k) * 0.3
            var evs: [AudioOnsetEvent] = []
            var e = t - 4 + 0.05
            var n = 0
            while e <= t { evs.append(ev(e, n % 3 == 1 ? 150 : 30)); e += 0.3; n += 1 }
            out.append(v.step(video: video, floor: 10, events: evs, clock: clock(t), beat: beat, activity: activity,
                              channelsBoth: both, depth: 0.15, now: t, dt: 0.3))
        }
        return out
    }
    let passes = vibRun(s2Beat())
    var uncoupled = s2Beat()
    uncoupled.state = .uncoupled
    var stale2 = s2Beat()
    stale2.fv = 0
    let gatesOff = [vibRun(nil), vibRun(uncoupled), vibRun(stale2), vibRun(s2Beat(pMusic: 0.5)), vibRun(s2Beat(), activity: 0),
                    vibRun(s2Beat(), both: false), vibRun(s2Beat(crossCut: 1)), vibRun(s2Beat(still: 0.2))]
    vcheck(passes.contains { $0 != 50 } && passes.allSatisfy { $0 >= 10 && $0 <= 57 }
           && gatesOff.allSatisfy { $0.allSatisfy { $0 == 50 } },
           "F3b 四道门：耦合 + 不像配乐 + 画面在动 + 两个通道才跟声音（\(passes.min() ?? 0)~\(passes.max() ?? 0) ≤ 57）；"
           + "不耦合 / 相位锁放开 / P_music 0.5 / 画面静止 / 单通道 / 跨切镜证据 / 静止仍有节奏 → 逐位等于画面值")
    // 最近 10 秒内有过跨切镜证据：之后 10 秒内都不生效，过了才生效
    var ve = AVVibrationAudio()
    var evidenceHeld = true
    var reopened = false
    for k in 0..<50 {
        let t = 10 + Double(k) * 0.3
        let evs = (0..<14).map { ev(t - 4 + 0.05 + Double($0) * 0.3, $0 % 3 == 1 ? 150 : 30) }
        let b = k == 0 ? s2Beat(crossCut: 1) : s2Beat()
        let o = ve.step(video: 50, floor: 10, events: evs, clock: clock(t), beat: b, activity: 0.5, channelsBoth: true,
                        depth: 0.15, now: t, dt: 0.3)
        if t - 10 < 10 - 1e-9, o != 50 { evidenceHeld = false }
        if t - 10 >= 10, o != 50 { reopened = true }
    }
    vcheck(evidenceHeld && reopened, "F3b：跨切镜证据之后 10 秒内震动 = 画面值，之后才跟声音")
    // 离开耦合：1.5 秒内回到画面值、每拍降 ≤ 12（画面值不变）
    var vf = AVVibrationAudio()
    var lastOn = 0
    for k in 0..<20 {
        let t = 10 + Double(k) * 0.3
        let evs = (0..<14).map { ev(t - 4 + 0.05 + Double($0) * 0.3, $0 % 3 == 1 ? 150 : 30) }
        lastOn = vf.step(video: 50, floor: 10, events: evs, clock: clock(t), beat: s2Beat(), activity: 0.5,
                         channelsBoth: true, depth: 0.3, now: t, dt: 0.3)
    }
    var fade: [Int] = [lastOn]
    for k in 0..<8 {
        let t = 16 + Double(k) * 0.3
        fade.append(vf.step(video: 50, floor: 10, events: [], clock: clock(t), beat: nil, activity: 0.5, channelsBoth: true,
                            depth: 0.3, now: t, dt: 0.3))
    }
    let backAt = fade.firstIndex(of: 50)
    let drops = zip(fade, fade.dropFirst()).allSatisfy { $0.0 - $0.1 <= AVVibrationAudio.maxDropPerBeat }
    vcheck(lastOn > 50 && (backAt ?? 99) <= 5 && fade.suffix(from: backAt ?? 0).allSatisfy { $0 == 50 } && drops && vf.mix == 0,
           "F3b 离开耦合：\(fade.map(String.init).joined(separator: "→"))，1.5 秒内回到画面值、每拍降 ≤ 12")
    // 复审 H2：淡回中画面值降了 → 上界跟着压；画面停了 / 震动为 0 / 换成单通道 → 当拍回画面值；淡回每拍降 ≤ 12（含混合比到 0 之后）
    func engaged(depth: Double = 0.3) -> AVVibrationAudio {
        var v = AVVibrationAudio()
        for k in 0..<20 {
            let t = 10 + Double(k) * 0.3
            let evs = (0..<14).map { ev(t - 4 + 0.05 + Double($0) * 0.3, $0 % 3 == 1 ? 150 : 30) }
            _ = v.step(video: 50, floor: 10, events: evs, clock: clock(t), beat: s2Beat(), activity: 0.5, channelsBoth: true,
                       depth: depth, now: t, dt: 0.3)
        }
        return v
    }
    var falling = engaged()
    var fallOut: [Int] = []
    var fallOK = true
    for (k, video) in [40, 30, 20, 10, 10, 10, 10, 10].enumerated() {
        let t = 16 + Double(k) * 0.3
        let o = falling.step(video: video, floor: 10, events: [], clock: clock(t), beat: nil, activity: 0.5, channelsBoth: true,
                             depth: 0.3, now: t, dt: 0.3)
        if o > Int((Double(video) * 1.3).rounded(.down)) { fallOK = false }
        fallOut.append(o)
    }
    var still = engaged()
    let stillOut = still.step(video: 50, floor: 10, events: [], clock: clock(16), beat: nil, activity: 0, channelsBoth: true,
                              depth: 0.3, now: 16, dt: 0.3)
    var zero = engaged()
    let zeroOut = zero.step(video: 0, floor: 10, events: [], clock: clock(16), beat: s2Beat(), activity: 0.5, channelsBoth: true,
                            depth: 0.3, now: 16, dt: 0.3)
    var single = engaged()
    let singleOut = single.step(video: 50, floor: 10, events: [], clock: clock(16), beat: s2Beat(), activity: 0.5,
                                channelsBoth: false, depth: 0.3, now: 16, dt: 0.3)
    // 卡顿：dt = 5 秒也只当一拍
    var stall = engaged()
    let stallOut = stall.step(video: 50, floor: 10, events: [], clock: clock(21), beat: nil, activity: 0.5, channelsBoth: true,
                              depth: 0.3, now: 21, dt: 5)
    vcheck(fallOK && fallOut.last == 10 && stillOut == 50 && still.mix == 0 && zeroOut == 0 && zero.mix == 0
           && singleOut == 50 && single.mix == 0 && stallOut > 50 && stall.mix > 0,
           "F3b（复审 H2）：淡回时画面降了上界跟着压（\(fallOut.map(String.init).joined(separator: "→"))）；画面停 / 震动 0 / 单通道当拍回画面值；卡顿 dt 只当一拍")

    // 调试列
    let f3Count = AVDebugColumns.f3Header.split(separator: ",", omittingEmptySubsequences: false).count
    vcheck(f3Count == 3 && AVDebugColumns.f3Fields(accent: a, vibration: vf).count == 3 && AVDebugColumns.f3Empty.count == 3
           && AVDebugColumns.f3Empty.allSatisfy { $0.isEmpty },
           "F3 调试列 3 列")
}



/// av-fusion F4 的检查（互为回落 + 相位飞轮）
func avFusionF4Checks() {
    var seed: UInt64 = 0xF4F4
    func rnd() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }
    func beat(_ state: AVFusionBeat.State, pMusic: Double = 0) -> AVFusionBeat {
        var b = AVFusionBeat()
        b.state = state
        b.pMusic = pMusic
        return b
    }

    // 设置
    let def = VisualSyncSettings()
    let on = VisualSyncSettings(source: .motion, avFusion: true, avFallback: true)
    var offF = on
    offF.avFallback = false
    vcheck(!def.avFallback && !def.usesAVFallback && VisualSyncSettings.Keys.avFallback == "bcVisualSyncAVFallback"
           && on.usesAVFallback && !VisualSyncSettings(source: .audio, avFusion: true, avFallback: true).usesAVFallback
           && !VisualSyncSettings(source: .motion, avFusion: false, avFallback: true).usesAVFallback
           && on.tickInterval == offF.tickInterval,
           "F4 设置：默认关、键名、要融合 + 跟随画面，不改 Timer 间隔")

    // 爬坡抽成纯函数：和原式逐位相同
    var rampSame = true
    for _ in 0..<5000 {
        let e = rnd() < 0.05 ? Double.nan : rnd() * 4 - 1
        let sec = 0.5 + rnd() * 3
        let a = HandoverRamp.share(elapsed: e, seconds: sec)
        let b = min(1, max(0, e / sec))
        if a.bitPattern != b.bitPattern { rampSame = false }
    }
    vcheck(rampSame, "F4：HandoverRamp.share 和 SourceHandover 原来的爬坡式逐位相同（5000 组随机，含 NaN）")

    // 画面断开 → 0.6 秒后 1.5 秒爬到声音；值 ≤ max(画面, 声音)
    func run(gate: AVFusionBeat?, audio: Double = 80, audioSignal: Bool = true, goneBeats: Int = 12,
             backBeats: Int = 0, video: Double = 10) -> (values: [Double], signals: [Bool], fb: AVFallbackBlend) {
        var f = AVFallbackBlend()
        var vals: [Double] = []
        var sigs: [Bool] = []
        var now = 0.0
        for _ in 0..<10 {   // 画面正常 3 秒
            now += 0.3
            f.note(beat: gate, now: now)
            let o = f.step(blended: (video, true), motionSignal: true, audio: audio, audioSignal: audioSignal, now: now, dt: 0.3)
            vals.append(o.value)
            sigs.append(o.hasSignal)
        }
        for _ in 0..<goneBeats {
            now += 0.3
            let o = f.step(blended: (0, false), motionSignal: false, audio: audio, audioSignal: audioSignal, now: now, dt: 0.3)
            vals.append(o.value)
            sigs.append(o.hasSignal)
        }
        for _ in 0..<backBeats {
            now += 0.3
            let o = f.step(blended: (video, true), motionSignal: true, audio: audio, audioSignal: audioSignal, now: now, dt: 0.3)
            vals.append(o.value)
            sigs.append(o.hasSignal)
        }
        return (vals, sigs, f)
    }
    let coupled = run(gate: beat(.coupled, pMusic: 0.9))
    let gone = Array(coupled.values[10...])
    // 断开第 1 拍 0.3 秒、第 2 拍 0.6 秒（到 0.6 秒那拍起爬，每拍 +0.2）
    let expect: [Double] = [0, 16, 32, 48, 64, 80, 80, 80, 80, 80, 80, 80]
    let rampOK = zip(gone, expect).allSatisfy { abs($0.0 - $0.1) < 1e-9 } && coupled.values.prefix(10).allSatisfy { $0 == 10 }
    let bounded = coupled.values.allSatisfy { $0 <= 80 + 1e-9 }
    vcheck(rampOK && bounded && coupled.signals[10] == false && coupled.signals[11] && coupled.fb.substituting,
           "F4 画面断开：0.6 秒前照原路径（0、没信号），之后 1.5 秒线性爬到声音 80，≤ max(画面, 声音)：\(gone.map { String(Int($0)) }.joined(separator: "→"))")
    // 门：最近 10 秒耦合过或 P_music < 0.3 才补；像配乐又没耦合 → 维持现状（0、没信号）
    let music = run(gate: beat(.uncoupled, pMusic: 0.8))
    let lowMusic = run(gate: beat(.uncoupled, pMusic: 0.1))
    let noAudioBeat = run(gate: beat(.noAudio, pMusic: 0))
    var voiceBeat = beat(.voice, pMusic: 0)
    voiceBeat.pVoice = 0.9
    let voice = run(gate: voiceBeat)
    vcheck(music.values[10...].allSatisfy { $0 == 0 } && music.signals[10...].allSatisfy { !$0 } && !music.fb.active
           && lowMusic.values[10...].allSatisfy { $0 == 0 } && voice.values[10...].allSatisfy { $0 == 0 }
           && noAudioBeat.values[10...].allSatisfy { $0 == 0 },
           "F4 门（复审 H1）：只认最近 10 秒内真的耦合过；像配乐 / P_music 低但没耦合（单镜头配乐的默认值）/ 人声 / 没声音 → 不补（0、不加最低强度）")
    // 复审 M1：交回到一半又断开、门不满足 → 占比淡回 0（不冻住）；一次替补最多 30 秒
    var halfBack = run(gate: beat(.coupled), backBeats: 2).fb
    let shareMid = halfBack.share
    var later: [Double] = []
    for k in 1...12 {
        _ = halfBack.step(blended: (0, false), motionSignal: false, audio: 80, audioSignal: true, now: 100 + Double(k) * 0.3, dt: 0.3)
        later.append(halfBack.share)
    }
    let capped = run(gate: beat(.coupled), goneBeats: Int((AVFallbackBlend.maxSubstituteSeconds + 3) / 0.3))
    vcheck(shareMid > 0 && shareMid < 1 && later.last == 0 && zip(later, later.dropFirst()).allSatisfy { $0.1 <= $0.0 }
           && capped.values.last == 0 && capped.values.contains(80),
           "F4（复审 M1）：门不满足时占比淡回 0、不冻在交回的一半；替补 30 秒后淡回原路径")
    // 门只在断开 0.6 秒那一刻判一次：之后过了 10 秒照样补（不中途掉）；门过期之后新断开不补
    let longGone = run(gate: beat(.coupled), goneBeats: 60)
    var stale = AVFallbackBlend()
    stale.note(beat: beat(.coupled), now: 0)
    var staleVals: [Double] = []
    for k in 1...20 {
        let o = stale.step(blended: (0, false), motionSignal: false, audio: 80, audioSignal: true, now: 10 + Double(k) * 0.3, dt: 0.3)
        staleVals.append(o.value)
    }
    vcheck(longGone.values.last == 80 && staleVals.allSatisfy { $0 == 0 },
           "F4 门：断开那一刻判，一次断开里不中途掉；门（10 秒）过期后再断开不补")
    // 声音也没了：0、没信号
    let silent = run(gate: beat(.coupled), audioSignal: false)
    vcheck(silent.values[10...].allSatisfy { $0 == 0 } && silent.signals[10...].allSatisfy { !$0 },
           "F4：画面、声音都没了 → 0、没信号（不加最低强度）")
    // 画面回来：每拍降 ≤ 12、交回后逐位等于原路径
    let back = run(gate: beat(.coupled), backBeats: 14)
    let tail = Array(back.values[22...])
    let drops = zip([back.values[21]] + tail, tail).allSatisfy { $0.0 - $0.1 <= 12 + 1e-9 }
    vcheck(drops && tail.last == 10 && !back.fb.active && back.signals[22...].allSatisfy { $0 },
           "F4 画面回来：每拍降 ≤ 12、交回后逐位等于原路径：\(tail.map { String(Int($0.rounded())) }.joined(separator: "→"))")
    // 中途 reset（暂停 / seek / 缓冲 / 关联动）：下一拍原样
    var mid = run(gate: beat(.coupled)).fb
    mid.reset()
    let afterReset = mid.step(blended: (0, false), motionSignal: false, audio: 80, audioSignal: true, now: 100, dt: 0.3)
    vcheck(afterReset.value == 0 && !afterReset.hasSignal && !mid.active,
           "F4：暂停 / seek / 缓冲 / 关联动 reset 后当拍走原路径（0）")

    // 5000 组随机：经出口 ≤ 上限、升幅 ≤ 20、归零保持、通道 2 / 3 = 0；值 ≤ max(画面, 声音)；画面一直在时逐位原样
    var f = AVFallbackBlend()
    var stage = SyncOutputStage()
    var prev = [0, 0, 0, 0]
    var ok = true
    var bad = ""
    var alwaysVideo = AVFallbackBlend()
    var identical = true
    var now = 0.0
    for i in 0..<5000 {
        if i % 300 == 0 { f.reset(); stage.reset(); prev = [0, 0, 0, 0] }
        now += 0.1 + rnd() * 0.3
        if rnd() < 0.2 { f.note(beat: beat(rnd() < 0.5 ? .coupled : .uncoupled, pMusic: rnd()), now: now) }
        let ms = rnd() < 0.6
        let m = rnd() < 0.03 ? Double.nan : rnd() * 120 - 10
        let a = rnd() < 0.03 ? Double.nan : rnd() * 120 - 10
        let asig = rnd() < 0.8
        let blendedIn = (value: ms ? m : 0, hasSignal: ms)
        let prevF = f.lastValue
        let o = f.step(blended: blendedIn, motionSignal: ms, audio: a, audioSignal: asig, now: now, dt: 0.3)
        let mm = ms && m.isFinite ? min(100, max(0, m)) : 0
        let aa = asig && a.isFinite ? min(100, max(0, a)) : 0
        if !(o.value.isFinite || o.value.isNaN && blendedIn.value.isNaN) { ok = false; bad = "值 \(o.value)" }
        // F4 起作用时：≤ max(画面, 声音)，交回降速托着时 ≤ 上一拍
        if f.active, o.value > max(mm, aa, prevF ?? 0) + 1e-9 { ok = false; bad = "上界 \(o.value)" }
        if f.active, let p = prevF, o.value > max(mm, aa) + 1e-9, o.value > p - 12 + 1e-9 { ok = false; bad = "托住 \(o.value)" }
        let st = AudioSyncSettings(maxPercent: 10 + rnd() * 90, channels: .both, minPercent: rnd() * 40)
        let out = stage.step(levels: RhythmOutput.target(value: o.value, settings: st, hasSignal: o.hasSignal, rateLevel: nil,
                                                         weight: 0), settings: st)
        let cap = SyncOutputStage.hardCap(st)
        if out[2] != 0 || out[3] != 0 { ok = false; bad = "通道" }
        for ch in 0..<2 {
            if out[ch] < 0 || out[ch] > cap { ok = false; bad = "上限" }
            if out[ch] - prev[ch] > SyncOutputStage.maxRisePerTick { ok = false; bad = "升幅" }
        }
        prev = out
        let v = alwaysVideo.step(blended: (m, true), motionSignal: true, audio: a, audioSignal: asig, now: now, dt: 0.3)
        if v.value.bitPattern != m.bitPattern || !v.hasSignal { identical = false }
    }
    vcheck(ok && identical,
           "F4：5000 组随机（画面断续、NaN、声音有无、门开关）经出口 ≤ 上限、升幅 ≤ 20、通道 2 / 3 = 0；画面一直在时逐位原样 \(bad)")

    // 相位飞轮：S2 里锁丢了、撞击频率一致 → 维持 ≤ 1.5 秒；不在 S2 / 频率不一致 / 超时 → 放开
    let locked = plLocked(hz: 1, until: 13)
    var lost = locked
    lost.step(plWindow(time: 13, hz: 1, cut: true), followerHz: 1, followerLocked: true, followerSource: .flow,
              now: 13.1, dt: 0.3, active: true)
    func fly(s2: Bool, audioHz: Double) -> [Bool] {
        var w = AVPhaseFlywheel()
        _ = w.step(lock: locked, s2: s2, audioHz: audioHz, now: 13)
        var held: [Bool] = []
        for k in 1...8 { held.append(w.step(lock: lost, s2: false, audioHz: audioHz, now: 13 + Double(k) * 0.3) != nil) }
        return held
    }
    let held = fly(s2: true, audioHz: 1.05)
    let notS2 = fly(s2: false, audioHz: 1)
    let wrongHz = fly(s2: true, audioHz: 1.4)
    let noAudio = fly(s2: true, audioHz: 0)
    var w = AVPhaseFlywheel()
    let liveLocked = w.step(lock: locked, s2: true, audioHz: 1, now: 13) == nil
    let snapPhase = w.step(lock: lost, s2: false, audioHz: 1, now: 13.3)?.phase(at: 13.3)
    vcheck(locked.locked && !lost.locked && held.prefix(5).allSatisfy { $0 } && held.suffix(2).allSatisfy { !$0 }
           && notS2.allSatisfy { !$0 } && wrongHz.allSatisfy { !$0 } && noAudio.allSatisfy { !$0 } && liveLocked
           && snapPhase != nil && snapPhase == locked.phase(at: 13.3),
           "F4 相位飞轮：S2 里锁丢了、撞击 1.05 Hz 跟得上 → 用丢之前的锁 1.5 秒（\(held.filter { $0 }.count) 拍）后放开；不在 S2 / 频率差 > 15% / 没撞击 → 不维持；锁着时用实时锁")

    let f4Count = AVDebugColumns.f4Header.split(separator: ",", omittingEmptySubsequences: false).count
    vcheck(f4Count == 3 && AVDebugColumns.f4Fields(fallback: back.fb, flywheel: w).count == 3
           && AVDebugColumns.f4Empty.allSatisfy { $0.isEmpty }, "F4 调试列 3 列")
}

avFusionF3Checks()

/// av-fusion F5 的检查（音画偏移估计 + 手动偏移）
func avFusionF5Checks() {
    var seed: UInt64 = 0xF5F5
    func rnd() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(1 << 53)
    }
    func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }

    // 设置
    let def = VisualSyncSettings()
    let fusionOn = VisualSyncSettings(source: .motion, avFusion: true, avOffsetMs: 120)
    let fusionOff = VisualSyncSettings(source: .motion, avFusion: false, avOffsetMs: 120, avAutoOffset: true)
    vcheck(def.avOffsetMs == 0 && !def.avAutoOffset && !def.usesAVAutoOffset && def.manualAVOffset == 0
           && VisualSyncSettings.Keys.avOffsetMs == "bcVisualSyncAVOffsetMs"
           && VisualSyncSettings.Keys.avAutoOffset == "bcVisualSyncAVAutoOffset"
           && VisualSyncSettings(avOffsetMs: 999).avOffsetMs == 300 && VisualSyncSettings(avOffsetMs: -999).avOffsetMs == -300
           && VisualSyncSettings(avOffsetMs: .nan).avOffsetMs == 0
           && abs(fusionOn.manualAVOffset - 0.12) < 1e-12 && fusionOff.manualAVOffset == 0 && !fusionOff.usesAVAutoOffset
           && fusionOn.tickInterval == def.tickInterval,
           "F5 设置：默认 0 / 关、键名、夹 ±300（NaN → 0）、融合没生效时偏移 0、不改 Timer 间隔")

    // 时钟挪动：0 / NaN 原样（逐位）；正偏移 = 撞击按 t − τ 算
    let c = MediaClockSnapshot(host: 100.123, item: 12.5, rate: 1.5)
    let s0 = c.shifted(byItem: 0)
    let sn = c.shifted(byItem: .nan)
    let sp = c.shifted(byItem: 0.12)
    vcheck(s0.host.bitPattern == c.host.bitPattern && s0.item.bitPattern == c.item.bitPattern && s0.rate.bitPattern == c.rate.bitPattern
           && sn == c && abs(sp.host(forItem: 12.62) - c.host(forItem: 12.5)) < 1e-9,
           "F5 时钟挪动：偏移 0 / NaN 逐位原样；+120 毫秒时 12.62 秒的撞击按 12.50 秒对画面")
    // 复审 M5：真的撞击时刻 + 非零偏移。声音比画面晚 120 毫秒的撞击，用挪过的时钟算出的画面相位和「没偏移的片子」一样；
    // 不挪时相位整体转 2π·f·τ
    let lock = plLocked(hz: 1.2, until: 20)
    let clk0 = MediaClockSnapshot(host: 20, item: 20, rate: 1)
    let truth = [17.2, 17.9, 18.6, 19.3]
    let late = truth.map { $0 + 0.12 }
    let mTruth = AVOffsetEstimator.meanPhase(itemTimes: truth, clock: clk0, lock: lock)
    let mFixed = AVOffsetEstimator.meanPhase(itemTimes: late, clock: clk0.shifted(byItem: 0.12), lock: lock)
    let mRaw = AVOffsetEstimator.meanPhase(itemTimes: late, clock: clk0, lock: lock)
    let rot = lock.omega * 0.12
    let fixedOK = mTruth != nil && mFixed != nil && abs(wrap(mFixed!.mu - mTruth!.mu)) < 1e-6
    let rawOK = mTruth != nil && mRaw != nil && abs(wrap(mRaw!.mu - mTruth!.mu - rot)) < 0.02
    // 窗口：τ = 0 时撞击集合和不挪逐位相同；τ > 0 时窗口右端跟着挪
    var evs: [AudioOnsetEvent] = []
    for t in late { evs.append(AudioOnsetEvent(time: t, strength: 60, risingBands: 6, steepBands: 6, shortBands: 6)) }
    let w0 = AVRhythmVote.impacts(evs, start: 15.9, end: 19.4).map { $0.time }
    let c0 = clk0.shifted(byItem: 0)
    let w0b = AVRhythmVote.impacts(evs, start: c0.item(forHost: 20) - 4.1, end: c0.item(forHost: 20) - 0.6).map { $0.time }
    let cP = clk0.shifted(byItem: 0.12)
    let wP = AVRhythmVote.impacts(evs, start: cP.item(forHost: 20) - 4.1, end: cP.item(forHost: 20) - 0.6).map { $0.time }
    vcheck(fixedOK && rawOK && w0 == w0b && wP.count == w0.count + 1,
           "F5：声音晚 120 毫秒时，按挪过的时钟算的撞击相位和没偏移时一样（不挪差 \(String(format: "%.0f", rot * 180 / .pi))°）；"
           + "τ = 0 窗口逐位相同、τ > 0 窗口右端跟着挪")

    // 合成 (f, μ)：μ = φ0 + 2π f τ + 噪声 → 分离出 τ 和 φ0
    func estimate(tau: Double, phi0: Double, freqs: [Double], noise: Double = 0.1, n: Int = 40,
                  random: Bool = false) -> AVOffsetEstimator {
        var est = AVOffsetEstimator()
        for k in 0..<n {
            let f = freqs[k % freqs.count] + (rnd() - 0.5) * 0.02
            let mu = random ? rnd() * 2 * Double.pi : wrap(phi0 + 2 * Double.pi * f * tau + (rnd() - 0.5) * 2 * noise)
            est.add(hz: f, mu: mu, r: 0.8, now: Double(k))
        }
        return est
    }
    let a = estimate(tau: 0.12, phi0: 1.0, freqs: [0.8, 1.0, 1.3, 1.6])
    let b = estimate(tau: -0.2, phi0: 3.0, freqs: [0.7, 1.1, 1.5])
    let z = estimate(tau: 0, phi0: -2.5, freqs: [0.9, 1.15, 1.4])
    let aOK = a.estimate.map { abs($0 - 0.12) <= 0.012 } ?? false
    let bOK = b.estimate.map { abs($0 + 0.2) <= 0.015 } ?? false
    let zOK = z.estimate.map { abs($0) <= 0.015 } ?? false
    // φ0 是格中心频率上拟合出来的，和真值差 ≤ 0.15 弧度
    let phiOK = abs(wrap(a.phi0 - 1.0)) <= 0.15 && abs(wrap(b.phi0 - 3.0)) <= 0.2
    vcheck(aOK && bOK && zOK && phiOK,
           "F5 估计：+120 / −200 / 0 毫秒分别估成 \(a.estimate.map { String(format: "%.0f", $0 * 1000) } ?? "–") / "
           + "\(b.estimate.map { String(format: "%.0f", $0 * 1000) } ?? "–") / \(z.estimate.map { String(format: "%.0f", $0 * 1000) } ?? "–") 毫秒，"
           + "φ0 分开（含绕过 ±π）")
    // 频率跨度不够 / 样本不够 / 相位和频率没关系 → 不估
    let narrow = estimate(tau: 0.12, phi0: 1.0, freqs: [1.0, 1.15])
    let single = estimate(tau: 0.12, phi0: 1.0, freqs: [1.2])
    let few = estimate(tau: 0.12, phi0: 1.0, freqs: [0.8, 1.2, 1.6], n: 8)
    // 复审 M4：7 + 1 个样本（一个格只有 1 个）、两格、三格纯随机相位 → 都不估
    var sevenOne = AVOffsetEstimator()
    for k in 0..<7 { sevenOne.add(hz: 0.8, mu: 1, r: 0.8, now: Double(k)) }
    sevenOne.add(hz: 1.2, mu: -2, r: 0.5, now: 8)
    let twoBins = estimate(tau: 0.12, phi0: 1.0, freqs: [0.8, 1.6], n: 40)
    var randomHits = 0
    for trial in 0..<200 {
        _ = trial
        if estimate(tau: 0, phi0: 0, freqs: [0.8, 1.2, 1.6], n: 30, random: true).estimate != nil { randomHits += 1 }
    }
    let noisy = estimate(tau: 0.12, phi0: 1.0, freqs: [0.8, 1.0, 1.2, 1.4, 1.6, 1.8], n: 80, random: true)
    var weak = AVOffsetEstimator()
    for k in 0..<40 { weak.add(hz: k % 2 == 0 ? 0.8 : 1.6, mu: 1, r: 0.3, now: Double(k)) }
    vcheck(narrow.estimate == nil && single.estimate == nil && few.estimate == nil && noisy.estimate == nil
           && weak.sampleCount == 0 && narrow.spanHz < AVOffsetEstimator.minSpanHz
           && sevenOne.estimate == nil && twoBins.estimate == nil && randomHits == 0,
           "F5：频率跨度 < 0.4 Hz / 只有一个频率 / 每格样本 < 5 / 7 + 1 / 只有两格 / 相位和频率没关系（200 次随机 \(randomHits) 次误估）/ 集中度 < 0.5 → 不估 τ")
    // 复审 M4：估计值每次最多挪 20 毫秒（先学 +120，再换成 −120 的数据）
    var drift = estimate(tau: 0.12, phi0: 1.0, freqs: [0.8, 1.2, 1.6])
    let before = drift.estimate ?? 9
    var maxJump = 0.0
    var prevE = before
    for k in 0..<200 {
        let f = [0.8, 1.2, 1.6][k % 3]
        drift.add(hz: f, mu: wrap(1.0 + 2 * Double.pi * f * -0.12), r: 0.9, now: 50 + Double(k))
        if let e = drift.estimate { maxJump = max(maxJump, abs(e - prevE)); prevE = e }
    }
    // 复审 R2 M2：第一次估出来也从手动值起步、每次 ≤ 20 毫秒；S2 结束后过期（expire 每拍调）
    var firstStep = AVOffsetEstimator()
    firstStep.seed = -0.05
    var firstValue: Double?
    for k in 0..<60 {
        let f = [0.8, 1.2, 1.6][k % 3]
        firstStep.add(hz: f, mu: wrap(0.5 + 2 * Double.pi * f * 0.25), r: 1, now: Double(k))
        if firstValue == nil, let e = firstStep.estimate { firstValue = e }
    }
    let converged = firstStep.estimate ?? 9
    var stale5 = firstStep
    stale5.expire(now: 59 + 60)
    let keptAt119 = stale5.estimate != nil
    stale5.expire(now: 59 + 200)
    vcheck(firstValue.map { abs($0 + 0.03) < 1e-9 } == true && abs(converged - 0.25) < 0.015 && keptAt119 && stale5.estimate == nil
           && stale5.bins.isEmpty,
           "F5（复审 R2 M2）：第一次估计从手动值 −50 起步只挪 20 毫秒，之后收敛到 +250（\(String(format: "%.0f", converged * 1000))）；没新样本 120 秒后过期")
    vcheck(abs(before - 0.12) < 0.012 && maxJump <= AVOffsetEstimator.maxStepPerUpdate + 1e-12,
           "F5：估计值每次更新最多挪 20 毫秒（最大一步 \(String(format: "%.1f", maxJump * 1000)) 毫秒）")
    // 120 秒前的样本过期：只剩一个频率时估计消失
    var aging = estimate(tau: 0.12, phi0: 1.0, freqs: [0.8, 1.2, 1.6])
    let hadIt = aging.estimate != nil
    for k in 0..<10 { aging.add(hz: 1.6, mu: wrap(1.0 + 2 * Double.pi * 1.6 * 0.12), r: 0.8, now: 200 + Double(k)) }
    vcheck(hadIt && aging.estimate == nil && aging.bins.count == 1, "F5：120 秒前的样本过期，频率只剩一格时不再估")
    // 实际用的偏移：自动开且估出来 → 估计；自动开没估出 → 手动；自动关 → 手动；融合关 → 0；都夹 ±0.3
    let autoOn = VisualSyncSettings(source: .motion, avFusion: true, avOffsetMs: -50, avAutoOffset: true)
    let autoOff = VisualSyncSettings(source: .motion, avFusion: true, avOffsetMs: -50, avAutoOffset: false)
    vcheck(abs(AVOffset.effective(settings: autoOn, estimator: a) - (a.estimate ?? 9)) < 1e-12
           && abs(AVOffset.effective(settings: autoOn, estimator: narrow) + 0.05) < 1e-12
           && abs(AVOffset.effective(settings: autoOff, estimator: a) + 0.05) < 1e-12
           && AVOffset.effective(settings: fusionOff, estimator: a) == 0
           && AVOffset.effective(settings: autoOn, estimator: nil) == -0.05,
           "F5 实际偏移：自动估出 → 估计值；估不出 / 自动关 → 手动值；融合关 → 0")
    // 撞击上的相位均值：没锁 / < 3 次 → nil；锁着时 μ 是各撞击相位的圆均值
    let clk = clk0
    let times = [18.0, 18.4, 19.1, 19.6]
    let mp = AVOffsetEstimator.meanPhase(itemTimes: times, clock: clk, lock: lock)
    var sx = 0.0, sy = 0.0
    for t in times { if let ph = lock.phase(at: t) { sx += cos(ph); sy += sin(ph) } }
    vcheck(mp != nil && abs(wrap(mp!.mu - atan2(sy, sx))) < 1e-12
           && AVOffsetEstimator.meanPhase(itemTimes: [18, 19], clock: clk, lock: lock) == nil
           && AVOffsetEstimator.meanPhase(itemTimes: times, clock: clk, lock: RhythmPhaseLock()) == nil,
           "F5：撞击相位均值（锁着、≥ 3 次才有）")
    vcheck(AVDebugColumns.f5Header.split(separator: ",").count == 4 && AVDebugColumns.f5Fields(effective: 0.12, estimator: a).count == 4
           && AVDebugColumns.f5Fields(effective: 0, estimator: nil)[0] == "0" && AVDebugColumns.f5Empty.allSatisfy { $0.isEmpty },
           "F5 调试列 4 列")
}

avFusionF4Checks()
avFusionF5Checks()

if vsFailures > 0 {
    print("VisualSyncChecks: \(vsFailures) FAIL")
    exit(1)
}
print("VisualSyncChecks: all passed")
