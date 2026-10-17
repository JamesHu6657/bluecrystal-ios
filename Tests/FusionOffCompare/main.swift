import Foundation
// 声画融合关着 = f706431（v1.8.3）的跨版本对照（Tests/FusionOffCompare/run.sh，PR Checks 里跑）：只用 f706431 已有的接口，
// 同一份整条链模拟分别和 BASE 的 VisualSync.swift、当前分支的编译，输出必须逐字节相同（证明融合关着时已有类型的行为一位没变）。
// 链：声音模式（电平 → 声音整形 → 出口）、画面 P1 / P2 / P3（含撞击声相位校正：频带 → 撞击 → 相位偏移）、P4 前瞻；
// 编译时加 -D AV_FUSION_ON（F1 起）：融合各部件在旁边跟着跑（喂同样的画面 / 声音），输出照样必须和 BASE 逐字节相同（只显示）
// 再加 -D AV_F2_ON（F2 起）：融合开着、「节奏由声音确认」关着，F2 的接线全部走一遍（AVRhythmVote.refine → 跟随器 fastJump →
// 撞击声校正的 coupled），输出照样必须和 BASE 逐字节相同
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

/// 声音：画面相位每过一次峰（sin = 1）一下 15 ms 衰减的宽带撞击（偏 offset 秒）+ 白噪声底 + 120 Hz 哼声；48 kHz，按 1024 一段
struct SynthAudio {
    static let rate: Double = 48_000
    var clicks: [Double] = []
    var i = 0
    var ci = 0
    var s: UInt64 = 0xC0FFEE
    init(hz: (Double) -> Double, seconds: Double, offset: Double, music: Bool) {
        var prev = hz(0)
        var t = 0.001
        while t < seconds + 1 {
            let p = hz(t)
            let k0 = floor((prev - .pi / 2) / (2 * .pi)), k1 = floor((p - .pi / 2) / (2 * .pi))
            if k1 > k0 { clicks.append(t + offset) }
            prev = p
            t += 0.001
        }
        // 配乐：再叠一路 2 Hz 的鼓点（和画面无关）
        if music { for k in 0..<Int(seconds * 2) { clicks.append(0.25 + Double(k) * 0.5) }; clicks.sort() }
    }
    mutating func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) - 0.5 }
    /// 生成到 t 为止，按段交给 body（第一个样本的时间、样本）
    mutating func render(until t: Double, _ body: (Double, [Double]) -> Void) {
        let end = Int(t * Self.rate)
        while i + 1024 <= end {
            var buf = [Double](repeating: 0, count: 1024)
            for j in 0..<1024 {
                let tt = Double(i + j) / Self.rate
                while ci + 1 < clicks.count, clicks[ci + 1] <= tt { ci += 1 }
                var x = 0.01 * r() * 2 + 0.05 * sin(2 * Double.pi * 120 * tt)
                if ci < clicks.count, tt >= clicks[ci], tt - clicks[ci] < 0.06 { x += 0.8 * exp(-(tt - clicks[ci]) / 0.015) * r() * 2 }
                buf[j] = x
            }
            body(Double(i) / Self.rate, buf)
            i += 1024
        }
    }
}

#if AV_FUSION_ON
/// 融合部件在旁边跟着跑（只用当前分支的接口；结果只写 stderr，不进逐字节对照的输出）。
/// F0：观测部件（tap 回调时间缓冲 / 提前量 / 调试列格式化）
/// F1：6 段特征 splitter → AVFusionEngine（耦合度 / 配乐 / 人声）；P3 频带块照 VideoSyncPlayer 经 AudioBandBacklog
///     先给融合、再原样交给撞击声校正（shareBands）；撞击声校正关着时融合自己分频带（= 电平计频带照开）
struct FusionShadow {
    let ring = AudioTapTimingRing()
    var lead = AudioTapLeadEstimator()
    var bands = AudioBandSummary()
    var rows = 0
    let anchor: Bool
    var features = AudioFeatureSplitter()
    var ownBands = AudioBandSplitter()
    var drain = AudioFeatureDrain()
    var ownPending: [AudioBandFrame] = []
    var backlog = AudioBandBacklog()
    var engine = AVFusionEngine()
    var coupledBeats = 0
    var last: AVFusionBeat?
    init(vis: VisualSyncSettings) {
        ring.setEnabled(true)
        anchor = vis.usesAudioAnchor
        features.configure(sampleRate: SynthAudio.rate)
        ownBands.configure(sampleRate: SynthAudio.rate)
        drain.pcmRate = AudioFeatureSplitter.pcmRate(forSampleRate: SynthAudio.rate)
    }
    mutating func audio(start: Double, samples: [Double]) {
        ring.record(AudioTapTiming(host: start - 0.1, itemStart: start, frames: samples.count))
        features.begin(start: start, frames: samples.count)
        if !anchor { ownBands.begin(start: start, frames: samples.count) }
        var f = AudioFeatureFrame()
        var p: Float = 0
        for (j, x) in samples.enumerated() {
            let flags = features.add(x, frame: &f, pcm: &p)
            if flags & AudioFeatureSplitter.frameReady != 0 { drain.frames.append(f) }
            if flags & AudioFeatureSplitter.pcmReady != 0 { drain.pcm.append(p) }
            if !anchor, let b = ownBands.add(x, at: start + Double(j) / SynthAudio.rate) { ownPending.append(b) }
        }
    }
    /// 照 VideoSyncPlayer.updateFusion / updateAudioAnchor：融合先取走，校正开着时存进 backlog，校正取的时候原样接上
    mutating func shareBands(_ pending: [AudioBandFrame]) -> [AudioBandFrame] {
        guard anchor else { return pending }
        backlog.keep(pending)
        engine.addBands(pending)
        return backlog.take(adding: [])
    }
    mutating func beat(window: MotionWindow, activity: Double, lock: RhythmPhaseLock, now: Double, dt: Double) {
        let d = ring.drain()
        let clock = MediaClockSnapshot(host: now, item: now, rate: 1)
        lead.add(d.timings, clock: clock)
        rows += AVDebugColumns.f0Fields(onsets: [], bands: bands, tapLead: lead.lead, tapValid: d.valid, tapInvalid: d.invalid,
                                        clock: clock).count
        if !anchor {
            engine.addBands(ownPending)
            ownPending.removeAll()
        }
        engine.addFeatures(drain)
        drain.frames.removeAll()
        drain.pcm.removeAll()
        let b = engine.beat(clock: clock, lock: lock, activity: activity, cut: window.cutCount > 0, audioReady: true, dt: dt)
        rows += AVDebugColumns.f1Fields(b).count
        if b.coupled { coupledBeats += 1 }
        last = b
    }
}
#endif

func run(_ name: String, pulse: Bool, context: Bool, anchor: Bool, lookahead: Bool, cap: Double, gain: Double, auto: Bool,
         hz: @escaping (Double) -> Double, amp: @escaping (Double) -> Double, cutAt: Double?, offset: Double = 0,
         music: Bool = false, seconds: Double = 24) {
    var an = MotionAnalyzer()
    an.phaseFitEnabled = pulse
    if context { an.contextEnabled = true }
    var laA = MotionAnalyzer()
    laA.phaseFitEnabled = true
    var tl = LookaheadTimeline()
    tl.restart(at: 0)
    var coord = LookaheadCoordinator()
    var acc = MotionWindowAccumulator()
    var norm = MotionNormalizer()
    var shaper = MotionShaper()
    var follower = RhythmFollower()
    var lock = RhythmPhaseLock()
    var driver = RhythmPulseDriver()
    var stage = SyncOutputStage()
    var ctx = ActionContext()
    var splitter = AudioBandSplitter()
    splitter.configure(sampleRate: SynthAudio.rate)
    var onsetDetector = AudioOnsetDetector()
    var audioAnchor = AudioPhaseAnchor()
    var audio = SynthAudio(hz: hz, seconds: seconds, offset: offset, music: music)
    var pendingBands: [AudioBandFrame] = []
    let st = AudioSyncSettings(enabled: true, maxPercent: cap, channels: .both, minPercent: 10)
    let vis = VisualSyncSettings(source: .motion, motionGainDb: gain, autoMotion: auto, rhythmFollow: true,
                                 rateTable: "20:0.6, 60:1.8, 99:2.8", rhythmPulse: pulse, rhythmContext: context,
                                 rhythmAudioAnchor: anchor, rhythmLookahead: lookahead)
#if AV_FUSION_ON
    var fusion = FusionShadow(vis: vis)
#endif
#if AV_F2_ON
    // F2：融合开着、节奏确认关着（= 开关默认值）
    var f2vis = vis
    f2vis.avFusion = true
    var vote = AVRhythmVote()
    var voted = 0
#endif
    var tick = 0.0
    var lastFull = 0.0
    var out = ""
    var kb = 0
    let interval = vis.tickInterval
    let latency = vis.pulseLatencyMs / 1000
    for k in 0..<Int(seconds * 15) {
        let t = Double(k) / 15
        let f = frame(t, hz: hz, amp: amp, cutAt: cutAt)
        if let s = an.analyze(f, time: t) { acc.add(s) }
        audio.render(until: t) { start, buf in
            if vis.usesAudioAnchor {
                splitter.begin(start: start, frames: buf.count)
                for (j, x) in buf.enumerated() {
                    if let b = splitter.add(x, at: start + Double(j) / SynthAudio.rate) { pendingBands.append(b) }
                }
            }
#if AV_FUSION_ON
            fusion.audio(start: start, samples: buf)
#endif
        }
        while tick + interval <= t {
            tick += interval
            let now = tick
            if interval == AudioReactiveShaper.interval { driver.noteFullBeat(at: now) }
            else if !driver.takesFullBeat(at: now) {
                if let o = driver.subBeat(lock: lock, settings: st, now: now, stage: &stage) { out += "s\(o)" }
                continue
            }
            if vis.usesLookahead {
                while kb < Int((seconds + 3) * 15), Double(kb) / 15 <= now + LookaheadTimeline.horizon {
                    let tb = Double(kb) / 15
                    if let s = laA.analyze(frame(tb, hz: hz, amp: amp, cutAt: cutAt), time: tb) { tl.append(s) }
                    kb += 1
                }
                tl.prune(playhead: now)
            }
            let dt = now - lastFull
            lastFull = now
            let w = acc.drain()
            let target = norm.step(w, gainDb: vis.motionGainDb, auto: vis.autoMotion, dt: dt)
            let shaped = shaper.step(target: target, dt: dt)
            let value = norm.confidence * shaped.smoothed
            let act = RhythmOutput.motionActivity(level: shaped.level, smoothed: shaped.smoothed, confidence: norm.confidence, motionSignal: true)
            let clock = RhythmLookahead.Clock(hostNow: now, itemNow: now, rate: 1)
            var input = coord.refine(w, enabled: vis.usesLookahead, timeline: tl, clock: clock, latency: latency)
#if AV_F2_ON
            // 照 VideoSyncPlayer.rhythmLevel：P4 之后、P3 之前投票（看上一拍融合状态、跟随器上一拍的结果）
            input = vote.refine(input, enabled: f2vis.usesAVRhythmConfirm, coupled: fusion.last?.state == .coupled,
                                events: fusion.engine.extractor.events, impactHz: fusion.last?.fa ?? 0,
                                clock: MediaClockSnapshot(host: now, item: now, rate: 1), followerHz: follower.hz,
                                followerLocked: follower.locked)
            if vote.action != .none || vote.fastJump { voted += 1 }
#endif
            if vis.usesRhythmContext { input = ctx.refine(input, now: now) }
#if AV_F2_ON
            follower.step(input, dt: dt, active: act > 0, fastJump: vote.fastJump)
#else
            follower.step(input, dt: dt, active: act > 0)
#endif
            if pulse { lock.step(input, followerHz: follower.hz, followerLocked: follower.locked, followerSource: follower.source, now: now, dt: dt, active: act > 0) }
            let rate = follower.weight > 0 && follower.hz > 0 ? vis.rateMap.level(forHz: follower.hz) : nil
            let levels = RhythmOutput.target(value: value, settings: st, hasSignal: true, rateLevel: rate, weight: follower.weight, activity: act)
#if AV_FUSION_ON
            // F1：融合每拍先取走频带块（撞击声校正开着时经 backlog 原样交回）
            pendingBands = fusion.shareBands(pendingBands)
#endif
            let o: [Int]
            if pulse {
                driver.phaseOffset = coord.removeLead(from: driver.phaseOffset)
                // 撞击声相位校正：照 VideoSyncPlayer.updateAudioAnchor（倍速 1、host 时间 = 视频时间）
                if vis.usesAudioAnchor {
                    for b in pendingBands { onsetDetector.add(b) }
                    let onsets = onsetDetector.onsets(since: now - (AudioPhaseAnchor.windowSeconds + 0.5))
                    let r = onsetDetector.rhythm()
                    let known = vis.usesRhythmContext && ctx.directionKnown
#if AV_F2_ON
                    // 照 updateAudioAnchor：节奏确认关着时 coupled = nil（P3 原样）
                    let coupled: Bool? = f2vis.usesAVRhythmConfirm ? fusion.last?.state == .coupled : nil
                    driver.phaseOffset = audioAnchor.step(onsets: onsets, audioHz: r.hz, audioConfidence: r.confidence, lock: lock,
                                                          directionKnown: known, now: now, dt: dt, coupled: coupled)
#else
                    driver.phaseOffset = audioAnchor.step(onsets: onsets, audioHz: r.hz, audioConfidence: r.confidence, lock: lock,
                                                          directionKnown: known, now: now, dt: dt)
#endif
                    out += "a\(audioAnchor.offset.bitPattern)|\(onsets.count)|\(r.hz.bitPattern)|"
                }
                pendingBands.removeAll()
                if vis.usesLookahead {
                    driver.phaseOffset = coord.applyLead(to: driver.phaseOffset, enabled: true, timeline: tl, clock: clock,
                                                         latency: latency, lock: lock, dt: dt)
                }
                o = driver.beat(levels: levels, lock: lock, visual: vis, settings: st, hasSignal: true, value: value, activity: act,
                                followerWeight: follower.weight, now: now, stage: &stage)
            } else {
                o = stage.step(levels: levels, settings: st, now: now, timed: false)
            }
#if AV_FUSION_ON
            fusion.beat(window: w, activity: act, lock: lock, now: now, dt: dt)
#endif
            let plain = SyncOutputStage.preview(value, settings: st, hasSignal: true)
            out += "f\(o)|\(plain)|\(target.bitPattern)|\(follower.hz.bitPattern)|\(lock.weight.bitPattern)|\(driver.phaseOffset.bitPattern)|\(coord.lead.bitPattern)\n"
        }
    }
#if AV_FUSION_ON
    // 融合的结果只写 stderr（不进逐字节对照的 stdout）
    FileHandle.standardError.write("fusion \(name): rows \(fusion.rows) coupled beats \(fusion.coupledBeats)\n".data(using: .utf8)!)
#endif
#if AV_F2_ON
    FileHandle.standardError.write("f2 \(name): voted beats \(voted) (switch off → 0)\n".data(using: .utf8)!)
#endif
    print(name, out.count)
    print(out)
}

/// 声音模式：照 VideoSyncPlayer 声音侧（电平 → AudioReactiveShaper → 通道档位；画面→声音交接时经出口限速）
func runAudio(_ name: String, cap: Double, sensitivity: Double, auto: Bool, seconds: Double = 20) {
    let st = AudioSyncSettings(enabled: true, sensitivityDb: sensitivity, maxPercent: cap, channels: .both, minPercent: 10,
                               autoGain: auto, softDuck: !auto)
    var shaper = AudioReactiveShaper()
    var stage = SyncOutputStage()
    var accum = AudioWindowAccumulator()
    var audio = SynthAudio(hz: ph(1.2, 2, 8), seconds: seconds, offset: 0, music: true)
    var carry = AudioBlockCarry()
    var out = ""
    var t = 0.0
    while t < seconds {
        t += AudioReactiveShaper.interval
        audio.render(until: t) { _, buf in
            var s = AudioChannelStats(carry: carry)
            for x in buf { s.add(x * (0.3 + 0.7 * abs(sin(t)))) }
            carry = s.carry
            accum.add(peakToPeak: s.peakToPeak, meanSquare: s.meanSquare, frames: buf.count, blocks: s.blocks)
        }
        let w = accum.drain()
        let o = shaper.step(w, settings: st, dt: AudioReactiveShaper.interval, hasAudio: true)
        let vals = st.channels.levels(percent: o.percent)
        let limited = stage.step(shaper.smoothed, settings: st, hasSignal: true, now: t)
        out += "\(o.level.bitPattern)|\(o.percent)|\(vals)|\(limited)\n"
    }
    print(name, out.count)
    print(out)
}

runAudio("audio1", cap: 80, sensitivity: 0, auto: true)
runAudio("audio2", cap: 45, sensitivity: 6, auto: false)
run("p1", pulse: false, context: false, anchor: false, lookahead: false, cap: 80, gain: 0, auto: true, hz: ph(1, 1.6, 12), amp: { $0 < 18 ? 4 : 0 }, cutAt: nil)
run("p2", pulse: true, context: false, anchor: false, lookahead: false, cap: 55, gain: 3, auto: true, hz: ph(1, 1.4, 9), amp: { $0 < 17 ? 4 : 0 }, cutAt: 14)
run("p3", pulse: true, context: true, anchor: false, lookahead: false, cap: 70, gain: -2, auto: false, hz: ph(0.8, 2.2, 10), amp: { _ in 3 }, cutAt: nil)
run("p3a", pulse: true, context: true, anchor: true, lookahead: false, cap: 70, gain: 0, auto: true, hz: ph(1.6, 1.6, 0), amp: { _ in 4 }, cutAt: nil, offset: 0.08)
run("p3m", pulse: true, context: false, anchor: true, lookahead: false, cap: 60, gain: 0, auto: true, hz: ph(1.6, 1.2, 12), amp: { _ in 4 }, cutAt: 15, music: true)
run("p4", pulse: true, context: false, anchor: true, lookahead: true, cap: 70, gain: 0, auto: true, hz: ph(1.3, 1.8, 11), amp: { $0 < 20 ? 4 : 0 }, cutAt: nil)
let d = VisualSyncSettings()
print("defaults", d.source, d.tickInterval, d.usesPulseTiming, d.usesRhythmContext, d.usesAudioAnchor, d.usesLookahead, d.usesPrescan, d.rhythmFollow)
