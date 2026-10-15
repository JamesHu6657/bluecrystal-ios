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
func vsTexture(_ x: Int, _ y: Int) -> UInt8 {
    let h = (x &* 73_856_093) ^ (y &* 19_349_663)
    return UInt8(40 + (h & 0x7fff_ffff) % 160)
}

do {
    var an = MotionAnalyzer()
    _ = an.analyze(vsFrame { x, y in vsTexture(x, y) }, time: 0)
    let panned = an.analyze(vsFrame { x, y in vsTexture(x - 2, y + 1) }, time: vsDt)
    let e = panned?.energy ?? 99
    vcheck(e < 0.5, "平移补偿：整幅画面平移 (2, −1) 像素 → 能量 < 0.5（得到 \(e)）")
    var raw = MotionAnalyzer()
    _ = raw.analyze(vsFrame { x, y in vsTexture(x, y) }, time: 0)
    let changed = raw.analyze(vsFrame { x, y in vsTexture(x + 37, y + 11) }, time: vsDt)
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
    vcheck(lateMean >= 70, "归一化：大动作视频（e 8~20）动作段 ≥ 70%（后 20 秒均值 \(Int(lateMean))）")
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

if vsFailures > 0 {
    print("VisualSyncChecks: \(vsFailures) FAIL")
    exit(1)
}
print("VisualSyncChecks: all passed")
