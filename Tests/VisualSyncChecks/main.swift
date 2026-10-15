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

if vsFailures > 0 {
    print("VisualSyncChecks: \(vsFailures) FAIL")
    exit(1)
}
print("VisualSyncChecks: all passed")
