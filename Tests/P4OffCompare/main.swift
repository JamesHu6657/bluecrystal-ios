import Foundation
// P4 关着 = main 的跨版本对照（Tests/P4OffCompare/run.sh）：只用 main 92681ea 已有的接口；
// 分别和 main 的 VisualSync.swift、当前分支的编译，输出必须逐字节相同（证明 P4 没改动已有类型的行为；播放器接线另由 VisualSyncChecks 的 LookaheadCoordinator 关着对照钉住）
var seed: UInt64 = 0xBEEF
func rnd() -> Double { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Double(seed >> 11) / Double(1 << 53) }
func h(_ i: Int, _ j: Int, _ salt: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263 &+ salt &* 1_442_695_041)
    x = (x ^ (x >> 13)) &* 1_274_126_177; x ^= x >> 16
    return Double(x % 1024) / 1023
}
func val(_ x: Double, _ y: Double, _ salt: Int) -> Double {
    let gx = x / 3, gy = y / 3, i = floor(gx), j = floor(gy), fx = gx - i, fy = gy - j
    let ii = Int(i), jj = Int(j)
    let v = (h(ii, jj, salt) * (1 - fx) + h(ii + 1, jj, salt) * fx) * (1 - fy) + (h(ii, jj + 1, salt) * (1 - fx) + h(ii + 1, jj + 1, salt) * fx) * fy
    return 40 + 180 * v
}
func frame(_ t: Double, hz: (Double) -> Double, amp: (Double) -> Double, cutAt: Double?) -> LumaFrame {
    let ox = amp(t) * sin(hz(t))
    let salt = (cutAt != nil && t >= cutAt!) ? 7 : 1
    var px = [UInt8](repeating: 0, count: 64 * 36)
    for y in 0..<36 { for x in 0..<64 {
        let qx = Double(x) + 0.5, qy = Double(y) + 0.5
        let v = (qx >= 22 + ox && qx < 40 + ox && qy >= 10 && qy < 26) ? val(qx - ox + 100, qy + 100, 2) : val(qx + 200, qy + 200, salt)
        px[y * 64 + x] = UInt8(min(255, max(0, v.rounded())))
    } }
    return LumaFrame(width: 64, height: 36, pixels: px)
}
func ph(_ f0: Double, _ f1: Double, _ s: Double) -> (Double) -> Double { { t in t < s ? 2 * .pi * f0 * t : 2 * .pi * (f0 * s + f1 * (t - s)) } }

func run(_ name: String, pulse: Bool, context: Bool, cap: Double, gain: Double, auto: Bool, hz: @escaping (Double) -> Double,
         amp: @escaping (Double) -> Double, cutAt: Double?, seconds: Double = 24) {
    var an = MotionAnalyzer()
    an.phaseFitEnabled = pulse
    if context { an.contextEnabled = true }
    var acc = MotionWindowAccumulator()
    var norm = MotionNormalizer()
    var shaper = MotionShaper()
    var follower = RhythmFollower()
    var lock = RhythmPhaseLock()
    var driver = RhythmPulseDriver()
    var stage = SyncOutputStage()
    var ctx = ActionContext()
    let st = AudioSyncSettings(enabled: true, maxPercent: cap, channels: .both, minPercent: 10)
    let vis = VisualSyncSettings(source: .motion, motionGainDb: gain, autoMotion: auto, rhythmFollow: true,
                                 rateTable: "20:0.6, 60:1.8, 99:2.8", rhythmPulse: pulse, rhythmContext: context)
    var tick = 0.0
    var lastFull = 0.0
    var out = ""
    let interval = vis.tickInterval
    for k in 0..<Int(seconds * 15) {
        let t = Double(k) / 15
        if let s = an.analyze(frame(t, hz: hz, amp: amp, cutAt: cutAt), time: t) { acc.add(s) }
        while tick + interval <= t {
            tick += interval
            let now = tick
            if interval == AudioReactiveShaper.interval { driver.noteFullBeat(at: now) }
            else if !driver.takesFullBeat(at: now) {
                if let o = driver.subBeat(lock: lock, settings: st, now: now, stage: &stage) { out += "s\(o)" }
                continue
            }
            let dt = now - lastFull
            lastFull = now
            let w = acc.drain()
            let target = norm.step(w, gainDb: vis.motionGainDb, auto: vis.autoMotion, dt: dt)
            let shaped = shaper.step(target: target, dt: dt)
            let value = norm.confidence * shaped.smoothed
            let act = RhythmOutput.motionActivity(level: shaped.level, smoothed: shaped.smoothed, confidence: norm.confidence, motionSignal: true)
            var input = w
            if vis.usesRhythmContext { input = ctx.refine(w, now: now) }
            follower.step(input, dt: dt, active: act > 0)
            if pulse { lock.step(input, followerHz: follower.hz, followerLocked: follower.locked, followerSource: follower.source, now: now, dt: dt, active: act > 0) }
            let rate = follower.weight > 0 && follower.hz > 0 ? vis.rateMap.level(forHz: follower.hz) : nil
            let levels = RhythmOutput.target(value: value, settings: st, hasSignal: true, rateLevel: rate, weight: follower.weight, activity: act)
            let o: [Int]
            if pulse {
                o = driver.beat(levels: levels, lock: lock, visual: vis, settings: st, hasSignal: true, value: value, activity: act,
                                followerWeight: follower.weight, now: now, stage: &stage)
            } else {
                o = stage.step(levels: levels, settings: st, now: now, timed: false)
            }
            let plain = SyncOutputStage.preview(value, settings: st, hasSignal: true)
            out += "f\(o)|\(plain)|\(target.bitPattern)|\(follower.hz.bitPattern)|\(lock.weight.bitPattern)|\(driver.phaseOffset.bitPattern)\n"
        }
    }
    print(name, out.count)
    print(out)
}
run("p1", pulse: false, context: false, cap: 80, gain: 0, auto: true, hz: ph(1, 1.6, 12), amp: { $0 < 18 ? 4 : 0 }, cutAt: nil)
run("p2", pulse: true, context: false, cap: 55, gain: 3, auto: true, hz: ph(1, 1.4, 9), amp: { $0 < 17 ? 4 : 0 }, cutAt: 14)
run("p3", pulse: true, context: true, cap: 70, gain: -2, auto: false, hz: ph(0.8, 2.2, 10), amp: { _ in 3 }, cutAt: nil)
let d = VisualSyncSettings()
print("defaults", d.source, d.tickInterval, d.usesPulseTiming, d.usesRhythmContext, d.usesAudioAnchor, d.rhythmFollow)
