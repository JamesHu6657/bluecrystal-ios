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
    var normalizer = MotionNormalizer()
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
func vs3Output(_ windows: [MotionWindow], cap: Double = 100, auto: Bool = true) -> (mean: Double, max: Int, rise: Int) {
    var chain = VSChain()
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

if vsFailures > 0 {
    print("VisualSyncChecks: \(vsFailures) FAIL")
    exit(1)
}
print("VisualSyncChecks: all passed")
