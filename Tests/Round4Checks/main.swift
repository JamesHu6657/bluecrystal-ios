import Foundation

// 第四轮修复的回归检查：只编译纯类型（Protocol / Models / SafetyLedger / AIProgram），和 ProtocolChecks 同一套方式。
// 每条失败打印 FAIL，最后有失败就以非零退出（PR Checks 据此判失败并把 FAIL 行评论到 PR 上）

var r4Failures = 0
func r4check(_ ok: Bool, _ name: String) {
    if ok {
        print("PASS \(name)")
    } else {
        r4Failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - M2：写法不标准的指令（全角 / 中文括号、全角字母、零宽字符）整条作废

r4check(AIReply.detectionForm("［STOP］") == "[STOP]", "M2 归一化：全角方括号 → 方括号")
r4check(AIReply.detectionForm("[ST\u{200B}OP]") == "[STOP]", "M2 归一化：去掉零宽空格")
for s in ["［STOP］", "【STOP】", "〔STOP〕", "[ＳＴＯＰ]", "[ST\u{200B}OP]", "\u{FEFF}[ST\u{200C}OP]"] {
    r4check(AIReply.looksLikeNonstandardCommand(s), "M2 判为写法不标准：\(s.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))")
}
r4check(!AIReply.looksLikeNonstandardCommand("[STOP]"), "M2 标准 [STOP] 不算写法不标准")
r4check(!AIReply.looksLikeNonstandardCommand("好的，我们慢慢来【注意节奏】"), "M2 普通中文括号文字不误判")

let fullWidthStop = AIReply.parse("好的，马上停\n［STOP］")
r4check(fullWidthStop.rejection != nil && fullWidthStop.steps.isEmpty, "M2 ［STOP］ 整条作废（调用方在输出中会安全停止）")
let zwStop = AIReply.parse("[ST\u{200B}OP]")
r4check(zwStop.rejection != nil && zwStop.steps.isEmpty, "M2 夹零宽字符的 STOP 整条作废")
// STOP 后面紧跟零宽字符：原文已经匹配指令正则（(?![A-Za-z]) 不挡零宽），不归 M2 新规则管，走原有格式错路径整条作废
r4check(!AIReply.looksLikeNonstandardCommand("[STOP\u{200D}]"), "M2 原文已像指令的不重复判定")
r4check(AIReply.parse("\u{FEFF}[STOP\u{200D}]").rejection != nil, "M2 STOP 后夹零宽字符走原有格式错路径整条作废")
let lenticular = AIReply.parse("【STOP】")
r4check(lenticular.rejection != nil && lenticular.steps.isEmpty, "M2 【STOP】 整条作废")
r4check(AIReply.parse("[STOP]").rejection == nil, "M2 标准 [STOP] 照常解析")
let normal = AIReply.parse("[CH 30 0 0 0]\n[HOLD 1000]")
r4check(normal.rejection == nil && !normal.steps.isEmpty, "M2 标准 CH/HOLD 照常解析")
r4check(AIReply.parse("【注意节奏】慢慢来").rejection == nil, "M2 没有指令时中文括号文字不影响")

// MARK: - 设备只有伸缩 / 震动：旧通道仍兼容，但源值和输出都归零

for mode in BCProtocol.Mode.allCases {
    let data = mode.frame(channels: [4, 6, 99, 0])
    let bytes = [UInt8](data)
    r4check(bytes[5] == 0 && bytes[6] == 0, "\(mode.title)：未使用通道恒 0")
    r4check(bytes.count == (mode == .manual ? 10 : 9), "\(mode.title)：仍保留四通道帧长度")
}
let legacyCH = AIReply.parse("[CH 30 20 99 0]\n[HOLD 1000]\n[STOP]")
r4check(legacyCH.rejection == nil && legacyCH.stop
        && legacyCH.steps == [AIStep(levels: [30, 20, 0, 0], duration: 1)],
        "AI：旧四值 CH 兼容，清除通道 2，保持 HOLD / STOP")
for raw in ["[CH 30 20 100 0]", "[CH 30 20 bad 0]", "引用 [CH 30 20 99 0]", "[STOP]\n[CH 30 20 99 0]"] {
    let reply = AIReply.parse(raw)
    r4check(reply.rejection != nil && reply.steps.isEmpty && !reply.stop, "AI：未使用通道不绕过严格解析 / STOP")
}
for types in [["Suction"], ["Suction", "Rotation"], ["Suction", "Thrust", "Vibration"]] {
    let commands = types.map {
        ["commandType": $0, "startTimeSeconds": 0, "durationSeconds": 1, "intensityLevel": 5] as [String: Any]
    }
    if let data = try? JSONSerialization.data(withJSONObject: ["intensityScale": "ten", "commands": commands]),
       let script = try? JSONDecoder().decode(TimelineScript.self, from: data) {
        let expected = types.contains("Thrust") ? [60, 60, 0, 0] : [0, 0, 0, 0]
        r4check(script.levels(at: 0.5, previous: nil) == expected, "脚本 \(types)：Suction 接受但无输出")
        r4check(script.levels(at: 2, previous: 0, fromPlaybackStart: true) == expected, "脚本 \(types)：跨越命令也忽略 Suction")
        r4check((script.ignoredOnlyNote != nil) == !types.contains("Thrust"), "脚本 \(types)：仅忽略通道有简短提示")
        r4check([UInt8](BCProtocol.videoFrame(levels: script.levels(at: 0.5, previous: nil)))[5] == 0,
                "脚本 \(types)：视频帧通道 2 为 0")
    } else { r4check(false, "旧脚本 \(types) 加载") }
}
// 直接构造旧存储 JSON，不经过新建收藏的归零逻辑。
let legacyFavoriteID = UUID()
let legacyFavoritesJSON = """
[{"id":"\(legacyFavoriteID.uuidString)","name":"旧","modeRaw":3,"levels":[30,20,99,0]},
 {"id":"\(UUID().uuidString)","name":"仅旧通道","modeRaw":3,"levels":[0,0,99,0]}]
"""
let legacyFavorites = FavoriteCodec.decodeReport(Data(legacyFavoritesJSON.utf8))
r4check(legacyFavorites.unreadable == 0 && legacyFavorites.items.map(\.id) == [legacyFavoriteID],
        "旧收藏：混合值仍加载，只有未使用通道的收藏忽略，不算坏记录")
r4check(legacyFavorites.items.first?.levels == [30, 20, 0, 0], "旧收藏：加载时就清除通道 2 源值")
if let favorite = legacyFavorites.items.first, let mode = favorite.mode {
    r4check([UInt8](mode.frame(channels: favorite.levels))[5] == 0, "旧收藏：召回帧通道 2 恒 0")
}
let legacyGlide = FavoriteGlide.plan(from: [0, 50, 99, 0], to: [60, 10, 99, 0], maxLevel: 99)
r4check(legacyGlide.allSatisfy { $0[2] == 0 && [UInt8](BCProtocol.manualFrame(channels: $0))[5] == 0 },
        "旧收藏缓推：所有源值和帧的通道 2 恒 0")

// MARK: - 收藏：逐条解码，一条坏记录不清空全部

let goodFav = FavoriteSetting(id: UUID(), name: "好", modeRaw: BCProtocol.Mode.manual.rawValue, levels: [30, 0, 0, 0])
if let goodData = FavoriteCodec.encode([goodFav]),
   var rows = (try? JSONSerialization.jsonObject(with: goodData)) as? [Any] {
    rows.append(["bogus": 1])
    rows.append("not an object")
    if let mixed = try? JSONSerialization.data(withJSONObject: rows) {
        let report = FavoriteCodec.decodeReport(mixed)
        r4check(report.items.map { $0.id } == [goodFav.id], "收藏：坏记录只丢自己，好的保留")
        r4check(report.unreadable == 2, "收藏：读不出来的条数如实上报（2）")
        r4check(FavoriteCodec.decode(mixed).count == 1, "收藏：decode 同样保留好的那条")
    } else {
        r4check(false, "收藏：构造混合数据")
    }
} else {
    r4check(false, "收藏：编码一条有效收藏")
}
let garbage = FavoriteCodec.decodeReport(Data("garbage".utf8))
r4check(garbage.items.isEmpty && garbage.unreadable == 1, "收藏：整体不是数组算 1 条读不出来")
r4check(FavoriteCodec.decodeReport(nil) == FavoriteCodec.Decoded(items: [], unreadable: 0), "收藏：没有数据不算读不出来")
r4check(FavoriteCodec.decodeReport(Data("[]".utf8)) == FavoriteCodec.Decoded(items: [], unreadable: 0), "收藏：空数组")

// MARK: - 收藏：连续删除后任意顺序撤销都回到原顺序

let a = UUID(), b = UUID(), c = UUID()
func undo(_ id: UUID, order: [UUID], into list: [UUID], fallback: Int) -> [UUID] {
    var l = list
    let at = FavoriteRestore.insertionIndex(of: id, order: order, current: l, fallback: fallback)
    l.insert(id, at: min(max(0, at), l.count))
    return l
}
// 删 B（快照 [A,B,C]，原下标 1），再删 A（快照 [A,C]，原下标 0），剩 [C]
let orderB = [a, b, c], orderA = [a, c]
let bThenA = undo(a, order: orderA, into: undo(b, order: orderB, into: [c], fallback: 1), fallback: 0)
r4check(bThenA == [a, b, c], "撤销：先撤 B 再撤 A → [A,B,C]（之前是 [A,C,B]）")
let aThenB = undo(b, order: orderB, into: undo(a, order: orderA, into: [c], fallback: 0), fallback: 1)
r4check(aThenB == [a, b, c], "撤销：先撤 A 再撤 B → [A,B,C]")
r4check(FavoriteRestore.insertionIndex(of: c, order: [], current: [a, b], fallback: 9) == 2, "撤销：没有快照时退回原下标并夹到范围内")

// MARK: - 时间轴脚本校验

func tl(_ start: Double, _ duration: Double, _ level: Double = 5) -> TimelineCommand {
    TimelineCommand(commandType: "Thrust", startTimeSeconds: start, durationSeconds: duration, intensityLevel: level)
}
r4check(TimelineScript.validationError([tl(0, 1), tl(10, 2.5)]) == nil, "时间轴：正常脚本通过")
r4check(TimelineScript.validationError([tl(-1, 5)]) != nil, "时间轴：负的开始时间拒绝")
r4check(TimelineScript.validationError([tl(0, 1e9)]) != nil, "时间轴：超长时长拒绝")
r4check(TimelineScript.validationError([tl(.nan, 1)]) != nil, "时间轴：开始时间 NaN 拒绝")
r4check(TimelineScript.validationError([tl(0, .infinity)]) != nil, "时间轴：时长无穷大拒绝")
r4check(TimelineScript.validationError([tl(86_000, 1_000)]) != nil, "时间轴：结束时间超过 24 小时拒绝")
r4check(TimelineScript.validationError([tl(0, 1, .nan)]) != nil, "时间轴：强度 NaN 拒绝")
let many = Array(repeating: tl(0, 1), count: TimelineLimits.maxCommands + 1)
r4check(TimelineScript.validationError(many) != nil, "时间轴：命令数超过上限拒绝")
r4check(TimelineScript.validationError(Array(many.dropLast())) == nil, "时间轴：命令数正好等于上限通过")

// MARK: - 第五轮：拖动预览独立于播放时间，松手 / 旁白才提交 seek

var scrubber = PlaybackScrubber()
scrubber.begin(at: 12)
r4check(scrubber.update(to: 80) == nil, "seek：拖动不提交 seek")
r4check(scrubber.position == 80 && scrubber.isEditing, "seek：拖动位置保持 80，不被旧播放时间覆盖")
r4check(scrubber.end() == 80 && scrubber.position == nil && !scrubber.isEditing, "seek：松手提交最后拖动位置并结束预览")
r4check(scrubber.update(to: 90) == 90, "seek：旁白离散调整立即提交")
scrubber.begin(at: 90)
_ = scrubber.update(to: 30)
scrubber.cancel()
r4check(scrubber.end() == nil, "seek：控件离开屏幕后不再提交取消的拖动")

// seek 后零输出等待前进，不把 seek / 缓冲算成卡住；前进后恢复原来的 1.5 秒看门狗。
var watch = PlaybackProgressWatch()
watch.reset(now: 100)
r4check(watch.observe(at: 12, now: 100) == .moving, "卡住：初次采样启动监视")
r4check(watch.observe(at: 12, now: 101.4) == .moving, "卡住：未超过 1.5 秒不停止")
r4check(watch.observe(at: 12, now: 101.6) == .stalled, "卡住：超过 1.5 秒停止")
watch.awaitSeekProgress(from: 80, now: 105)
r4check(watch.observe(at: 80, now: 110) == .waitingAfterSeek, "seek：跳转后的长缓冲不触发卡住（设备保持 0）")
r4check(watch.observe(at: .nan, now: 115) == .waitingAfterSeek, "seek：缓冲时无有效位置仍保持零输出")
r4check(watch.observe(at: 80.1, now: 116) == .moving && !watch.awaitingSeekProgress, "seek：前进后恢复采样和监视")
r4check(watch.observe(at: 80.1, now: 117.6) == .stalled, "seek：恢复后真正卡住仍在 1.5 秒停止")
watch.awaitSeekProgress(from: 20, now: 120)
r4check(watch.observe(at: 20, now: 125) == .waitingAfterSeek, "seek：向后跳转也等待新落点前进")
r4check(watch.observe(at: 20.1, now: 126) == .moving, "seek：向后跳转后照常恢复")

// 暂停中完成 seek 后再点播放：落点不算前进，缓冲再久也不误发、不误停。
watch.awaitSeekProgress(from: 60, now: 130)
r4check(watch.observe(at: 60, now: 135, isPaused: true) == .paused && watch.awaitingSeekProgress,
        "seek：暂停不清掉等待落点前进的状态")
watch.startPlayback(at: 60, now: 140)
r4check(watch.observe(at: 60, now: 145) == .waitingAfterSeek,
        "seek：暂停→拖动→播放，长缓冲不发帧、不触发 1.5 秒停机")
// 暂停前已走过几帧，但首次采样还没来：暂停必须压过位置变化。
r4check(watch.observe(at: 60.1, now: 146, isPaused: true) == .paused && watch.awaitingSeekProgress,
        "seek：等待期间外部暂停，位置变了也不恢复非零输出")
watch.startPlayback(at: 60.1, now: 150)
r4check(watch.observe(at: 60.1, now: 155) == .waitingAfterSeek,
        "seek：外部暂停后再播放，从新的停点等待，不把暂停前的进度当成恢复")
r4check(watch.observe(at: 60.2, now: 156) == .moving, "seek：用户再次播放、真正前进后才恢复")
r4check(watch.observe(at: 60.3, now: 157, isPaused: true) == .paused,
        "播放：普通外部暂停也不采样暂停前的进度")
watch.startPlayback(at: 60.3, now: 160)
r4check(watch.observe(at: 60.3, now: 160) == .moving
        && watch.observe(at: 60.3, now: 161.6) == .stalled,
        "播放：非 seek 的再次播放仍保留 1.5 秒卡住检测")
watch.awaitSeekProgress(from: 0, now: 170)
watch.reset(now: 171)
watch.startPlayback(at: 0, now: 172)
r4check(!watch.awaitingSeekProgress && watch.observe(at: 0, now: 172) == .moving
        && watch.observe(at: 0, now: 173.6) == .stalled,
        "换视频：不继承旧视频的 seek 等待，普通卡住仍停机")

let skipped = tl(30, 0.05)
let landing = tl(80, 0.05)
r4check(!skipped.isCovered(at: 80.1, previous: 80, fromPlaybackStart: true), "seek：落点前跳过的命令不补发")
r4check(landing.isCovered(at: 80.1, previous: 80, fromPlaybackStart: true), "seek：恢复首个采样仍覆盖落点的短命令")

// MARK: - 声音联动：采样格式、窗口电平、灵敏度 / 噪声门 / 平滑 / 上限

let lpcm = AudioSampleFormat.linearPCM
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 1 | 8 | 32, bitsPerChannel: 32) == .float32,
        "声音：Float32 非交错可分析")
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 1 | 8, bitsPerChannel: 64) == .float64, "声音：Float64 可分析")
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 4 | 8, bitsPerChannel: 16) == .int16, "声音：Int16 可分析")
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 4 | 8, bitsPerChannel: 32) == .int32, "声音：Int32 可分析")
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 1 | 2, bitsPerChannel: 32) == nil, "声音：大端不分析")
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 4, bitsPerChannel: 24) == nil, "声音：24 位打包不分析")
r4check(AudioSampleFormat.resolve(formatID: lpcm, flags: 8, bitsPerChannel: 16) == nil, "声音：无符号整数不分析")
r4check(AudioSampleFormat.resolve(formatID: 0x6161_6320, flags: 0, bitsPerChannel: 0) == nil, "声音：压缩格式不分析")
r4check(AudioSampleFormat.int16.scale * 32_768 == 1 && AudioSampleFormat.int16.bytesPerSample == 2, "声音：Int16 归一化")

var chStats = AudioChannelStats()
for v in [0.5, -0.5, 0.5, -0.5, .nan, .infinity] { chStats.add(v) }
r4check(chStats.count == 4 && chStats.peakToPeak == 1 && chStats.meanSquare == 0.25, "声音：峰峰值 / 均方，非有限值跳过")
r4check(AudioChannelStats().peakToPeak == 0 && AudioChannelStats().meanSquare == 0, "声音：空段为 0")

var acc = AudioWindowAccumulator()
acc.add(peakToPeak: 1, meanSquare: 0.25, frames: 100)
acc.add(peakToPeak: 0.2, meanSquare: 0.01, frames: 300)
acc.add(peakToPeak: .nan, meanSquare: 1, frames: 100)
acc.add(peakToPeak: 5, meanSquare: 1, frames: 0)
let win = acc.drain()
r4check(win.peakToPeak == 1 && win.frames == 400 && abs(win.rms - 0.07.squareRoot()) < 1e-9,
        "声音：窗口取最大峰峰值、按帧数加权 RMS，坏数据不进窗口")
r4check(acc.drain() == .silent, "声音：取走后清零")

/// 幅度为 10^(dB/20) 的正弦窗口：峰值与 RMS 归一后都等于幅度，电平正好是 dB
func sineWindow(_ db: Double) -> AudioWindow {
    let a = pow(10, db / 20)
    return AudioWindow(peakToPeak: 2 * a, rms: a / 2.0.squareRoot(), frames: 4_800)
}
r4check(abs(AudioReactiveShaper.loudnessDb(sineWindow(0))) < 1e-9, "声音：满幅正弦 0 dB")
r4check(AudioReactiveShaper.loudnessDb(.silent) == -.infinity, "声音：没有音频 = 静音")
r4check(AudioReactiveShaper.loudnessDb(AudioWindow(peakToPeak: 0, rms: 0, frames: 100)) == -.infinity, "声音：全零 = 静音")
r4check(AudioReactiveShaper.targetPercent(loudnessDb: -3, sensitivityDb: 0) == 100, "声音：-3 dB 映射 100")
r4check(AudioReactiveShaper.targetPercent(loudnessDb: -45, sensitivityDb: 0) == 0, "声音：-45 dB 映射 0")
r4check(abs(AudioReactiveShaper.targetPercent(loudnessDb: -24, sensitivityDb: 0) - 50) < 1e-9, "声音：-24 dB 映射 50")
r4check(abs(AudioReactiveShaper.targetPercent(loudnessDb: -30, sensitivityDb: 6) - 50) < 1e-9, "声音：灵敏度 +6 dB 等于电平 +6 dB")
r4check(AudioReactiveShaper.targetPercent(loudnessDb: 0, sensitivityDb: -12) < 100, "声音：灵敏度调低后响的视频不再顶满")
r4check(AudioReactiveShaper.targetPercent(loudnessDb: -61, sensitivityDb: 18) == 0, "声音：底噪在增益前就归零，灵敏度最大也不放大")
r4check(AudioReactiveShaper.targetPercent(loudnessDb: .nan, sensitivityDb: 0) == 0, "声音：NaN 电平按 0")

let cautious = AudioSyncSettings()
r4check(cautious.enabled && cautious.maxPercent == 60 && cautious.sensitivityDb == 0 && cautious.channels == .both,
        "声音：默认设置保守（上限 60%）")
var shaper = AudioReactiveShaper()
let gateLow = shaper.step(sineWindow(-45 + 0.06 * 42), settings: cautious, dt: 0.3)
r4check(gateLow.percent == 0 && !shaper.gateOpen && abs(gateLow.level - 6) < 1e-6, "声音：门槛以下的小声音输出 0（电平条仍显示）")
let loud1 = shaper.step(sineWindow(-3), settings: cautious, dt: 0.3)
r4check(shaper.gateOpen && loud1.percent >= 55 && loud1.percent <= 60, "声音：变响一步就跟上（攻击快），不超过上限")
for _ in 0..<5 { _ = shaper.step(sineWindow(-3), settings: cautious, dt: 0.3) }
let loudHold = shaper.step(sineWindow(0), settings: cautious, dt: 0.3)
r4check(loudHold.percent == 60, "声音：持续最响 = 强度上限（60），不会更高")
let quiet1 = shaper.step(.silent, settings: cautious, dt: 0.3)
r4check(quiet1.percent > 30 && quiet1.percent < 60 && !shaper.gateOpen, "声音：变静慢慢落（释放慢），门已关")
var released = quiet1
for _ in 0..<20 { released = shaper.step(.silent, settings: cautious, dt: 0.3) }
r4check(released.percent == 0, "声音：持续安静 6 秒内落到 0")

shaper.reset()
_ = shaper.step(sineWindow(-24), settings: cautious, dt: 0.3)
_ = shaper.step(sineWindow(-45 + 0.06 * 42), settings: cautious, dt: 0.3)
r4check(shaper.gateOpen, "声音：噪声门回差——门槛之间不关门")
_ = shaper.step(sineWindow(-45 + 0.03 * 42), settings: cautious, dt: 0.3)
r4check(!shaper.gateOpen, "声音：低于关门值才关")

shaper.reset()
let full = AudioSyncSettings(maxPercent: 100)
var fullOut = shaper.step(sineWindow(0), settings: full, dt: 0.3)
for _ in 0..<10 { fullOut = shaper.step(sineWindow(0), settings: full, dt: 0.3) }
r4check(fullOut.percent == 100 && AudioSyncChannels.both.levels(percent: fullOut.percent) == [99, 99, 0, 0],
        "声音：上限 100% 时最高 99 档（0x08 帧上限）")

shaper.reset()
let weird = shaper.step(AudioWindow(peakToPeak: .infinity, rms: .nan, frames: 10), settings: cautious, dt: .nan)
r4check(weird.percent == 0 && shaper.smoothed.isFinite, "声音：坏数据 / NaN 步长不产生输出")
_ = shaper.step(sineWindow(-3), settings: cautious, dt: 1_000)
r4check(shaper.smoothed <= 100, "声音：超长步长也夹在 0~100")

// 随机输入：任何时候都不超过上限，吮吸 / 未使用通道恒 0
var seed: UInt64 = 0x5EED
func nextRandom() -> Double {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(seed >> 11) / Double(1 << 53)
}
var withinCap = true
var randomShaper = AudioReactiveShaper()
for _ in 0..<2_000 {
    let s = AudioSyncSettings(sensitivityDb: -20 + nextRandom() * 50, maxPercent: nextRandom() * 120,
                              channels: AudioSyncChannels(rawValue: Int(nextRandom() * 3)) ?? .both)
    let w = AudioWindow(peakToPeak: nextRandom() * 2.5, rms: nextRandom(), frames: Int(nextRandom() * 3) * 1_000)
    let out = randomShaper.step(w, settings: s, dt: nextRandom() * 1.5)
    let levels = s.channels.levels(percent: out.percent)
    let frame = [UInt8](BCProtocol.videoFrame(levels: levels))
    if out.percent < 0 || out.percent > Int(s.maxPercent) || levels[2] != 0 || levels[3] != 0
        || frame[5] != 0 || frame[6] != 0 || levels.contains(where: { $0 > 99 }) {
        withinCap = false
    }
}
r4check(withinCap, "声音：2000 次随机输入都不超过上限，通道 2 / 3 恒 0")

r4check(AudioSyncChannels.thrust.levels(percent: 40) == [40, 0, 0, 0], "声音：仅伸缩")
r4check(AudioSyncChannels.vibration.levels(percent: 40) == [0, 40, 0, 0], "声音：仅震动")
r4check(AudioSyncChannels.both.levels(percent: -5) == [0, 0, 0, 0], "声音：负值按 0")
let audioFrame = [UInt8](BCProtocol.videoFrame(levels: AudioSyncChannels.both.levels(percent: 60)))
r4check(audioFrame[1] == 0x08 && audioFrame[3] == 60 && audioFrame[4] == 60 && audioFrame[5] == 0 && audioFrame[6] == 0
        && audioFrame[7] == 0 && audioFrame[8] == 0, "声音：0x08 帧伸缩 / 震动同值、吮吸 0、尾部 00 00")

let clamped = AudioSyncSettings(sensitivityDb: 99, maxPercent: 500)
r4check(clamped.sensitivityDb == 18 && clamped.maxPercent == 100, "声音设置：超范围夹回")
let clampedLow = AudioSyncSettings(sensitivityDb: -99, maxPercent: 1)
r4check(clampedLow.sensitivityDb == -12 && clampedLow.maxPercent == 10, "声音设置：过低夹回")
let nanSettings = AudioSyncSettings(sensitivityDb: .nan, maxPercent: .infinity)
r4check(nanSettings.sensitivityDb == 0 && nanSettings.maxPercent == 60, "声音设置：NaN / 无穷按默认")
r4check(abs(AudioSyncSettings(sensitivityDb: 6).gainMultiplier - 1.9953) < 1e-3, "声音设置：+6 dB ≈ ×2")
// 不归零：播放中有音轨时安静片段保持最低强度；没有音轨不输出
do {
    let floorSettings = AudioSyncSettings(maxPercent: 60, minPercent: 10)
    var fs = AudioReactiveShaper()
    var o = fs.step(.silent, settings: floorSettings, dt: 0.3)
    r4check(o.percent == 10, "不归零：一开始安静也保持 10%")
    for _ in 0..<5 { o = fs.step(sineWindow(0), settings: floorSettings, dt: 0.3) }
    r4check(o.percent == 60, "不归零：最响仍到上限 60")
    for _ in 0..<40 { o = fs.step(.silent, settings: floorSettings, dt: 0.3) }
    r4check(o.percent == 10, "不归零：持续安静落回 10%，不到 0")
    fs.reset()
    r4check(fs.step(.silent, settings: floorSettings, dt: 0.3, hasAudio: false).percent == 0, "不归零：没有音轨时输出 0")
    r4check(AudioSyncSettings(maxPercent: 20, minPercent: 50).minPercent == 20, "最低强度不超过上限")
    r4check(AudioSyncSettings(minPercent: .nan).minPercent == 0 && AudioSyncSettings(minPercent: 99).minPercent == 50,
            "最低强度夹回 0~50")
    var withinFloorCap = true
    var rs = AudioReactiveShaper()
    for _ in 0..<2_000 {
        let s = AudioSyncSettings(sensitivityDb: -20 + nextRandom() * 50, maxPercent: nextRandom() * 120,
                                  minPercent: nextRandom() * 60, autoGain: nextRandom() < 0.5)
        let w = AudioWindow(peakToPeak: nextRandom() * 2.5, rms: nextRandom(), frames: Int(nextRandom() * 3) * 1_000)
        let out = rs.step(w, settings: s, dt: nextRandom() * 1.5)
        let lowest = s.minPercent >= 1 ? min(Int(s.minPercent.rounded()), Int(s.maxPercent.rounded(.down))) : 0
        if out.percent < lowest || out.percent > Int(s.maxPercent) { withinFloorCap = false }
    }
    r4check(withinFloorCap, "不归零：随机输入始终在 最低强度 ~ 上限 之间")
}

// 自动灵敏度：安静的视频和响的视频都能用满范围
do {
    let auto = AudioSyncSettings(maxPercent: 100, autoGain: true)
    var quietVideo = AudioReactiveShaper()
    var q = quietVideo.step(sineWindow(-35), settings: auto, dt: 0.3)
    for _ in 0..<120 { q = quietVideo.step(sineWindow(-35), settings: auto, dt: 0.3) }
    var manual = AudioReactiveShaper()
    var m = manual.step(sineWindow(-35), settings: AudioSyncSettings(maxPercent: 100), dt: 0.3)
    for _ in 0..<120 { m = manual.step(sineWindow(-35), settings: AudioSyncSettings(maxPercent: 100), dt: 0.3) }
    r4check(q.percent > m.percent && q.percent <= 60, "自动灵敏度：小声视频会被适度放大但不顶到很强（自动 \(q.percent)，手动 \(m.percent)）")
    var loudVideo = AudioReactiveShaper()
    var l = loudVideo.step(sineWindow(-1), settings: auto, dt: 0.3)
    for _ in 0..<60 { l = loudVideo.step(sineWindow(-1), settings: auto, dt: 0.3) }
    r4check(l.percent >= 70 && l.percent <= 95, "自动灵敏度：大声视频不长期顶死在 100%")
    r4check(quietVideo.autoGainDb <= AudioReactiveShaper.autoGainRange.upperBound, "自动增益有上限")
    var silentAuto = AudioReactiveShaper()
    var sOut = silentAuto.step(.silent, settings: auto, dt: 0.3)
    for _ in 0..<100 { sOut = silentAuto.step(AudioWindow(peakToPeak: 0.0004, rms: 0.0001, frames: 1000), settings: auto, dt: 0.3) }
    r4check(sOut.percent == 0, "自动灵敏度：纯底噪（低于 -60 dB）不会被放大")
    // 自动模式：响视频里的安静段底噪（约 -55 dB）不放大，只剩最低强度
    let autoFloor = AudioSyncSettings(sensitivityDb: 18, maxPercent: 100, minPercent: 10, autoGain: true)
    var gated = AudioReactiveShaper()
    var g = gated.step(sineWindow(-3), settings: autoFloor, dt: 0.3)
    for _ in 0..<80 { g = gated.step(sineWindow(-3), settings: autoFloor, dt: 0.3) }
    for _ in 0..<1_000 { g = gated.step(sineWindow(-55), settings: autoFloor, dt: 0.3) }
    r4check(g.percent == 10, "自动灵敏度：安静段底噪不被放大，只保持最低强度（得到 \(g.percent)）")
    var allQuiet = AudioReactiveShaper()
    for _ in 0..<1_000 { _ = allQuiet.step(sineWindow(-50), settings: auto, dt: 0.3) }
    r4check(allQuiet.refDb < -40, "自动灵敏度：整段都很安静的视频几分钟内也能学会自己的响度（refDb \(allQuiet.refDb)）")
    var intro = AudioReactiveShaper()
    for _ in 0..<33 { _ = intro.step(sineWindow(-30), settings: auto, dt: 0.3) }
    for _ in 0..<1_000 { _ = intro.step(sineWindow(-48), settings: auto, dt: 0.3) }
    r4check(intro.refDb < -40, "自动灵敏度：10 秒片头之后的小声对白仍能学会（refDb \(intro.refDb)）")
    var bang = AudioReactiveShaper()
    _ = bang.step(sineWindow(-15), settings: auto, dt: 0.3)
    for _ in 0..<1_000 { _ = bang.step(sineWindow(-50), settings: auto, dt: 0.3) }
    r4check(bang.refDb < -40, "自动灵敏度：开头一声关门声不会把安静视频锁死（refDb \(bang.refDb)）")
    quietVideo.resetAdaptation()
    r4check(quietVideo.refDb == AudioReactiveShaper.autoInitialRefDb, "换视频重新学习响度")
    var learning = AudioReactiveShaper()
    var learnOut = learning.step(sineWindow(-40), settings: AudioSyncSettings(maxPercent: 100), dt: 0.3)
    for _ in 0..<60 { learnOut = learning.step(sineWindow(-40), settings: AudioSyncSettings(maxPercent: 100), dt: 0.3) }
    r4check(learning.refDb < -30 && learnOut.percent == 12,
            "自动灵敏度：开关关着也在学响度（中途打开立刻合适），输出仍按手动灵敏度")
}

// 最低强度只在声音真的在流时生效：开播首拍、缓冲、AirPlay（窗口空）都不加
do {
    var flow = AudioFlowWatch()
    r4check(!flow.allowsFloor(tapReady: true, playerPlaying: true, now: 10), "最低强度：开播首拍还没有样本时不加")
    flow.note(.silent, now: 10)
    r4check(!flow.isFlowing(now: 10), "最低强度：空窗口不算有声音")
    flow.note(AudioWindow(peakToPeak: 0, rms: 0, frames: 4_800), now: 10.5)
    r4check(flow.allowsFloor(tapReady: true, playerPlaying: true, now: 10.5), "最低强度：数字静音也算声音在流（不归零）")
    r4check(!flow.allowsFloor(tapReady: true, playerPlaying: false, now: 10.5), "最低强度：缓冲中（播放器没在播）不加")
    r4check(!flow.allowsFloor(tapReady: false, playerPlaying: true, now: 10.5), "最低强度：tap 没就绪不加")
    flow.note(.silent, now: 10.75)
    r4check(flow.isFlowing(now: 10.75), "最低强度：一拍空窗口容忍抖动")
    flow.note(.silent, now: 11.5)
    r4check(!flow.isFlowing(now: 11.5), "最低强度：连续没有样本就停（缓冲 / 外部播放）")
    flow.note(sineWindow(-20), now: 12)
    flow.reset()
    r4check(!flow.isFlowing(now: 12), "最低强度：开播 / 跳转后旧样本不作数")
    flow.note(sineWindow(-20), now: 13)
    r4check(!flow.isFlowing(now: 12.5) && flow.isFlowing(now: 13.25), "最低强度：时间倒退不算新鲜")
    // 和 shaper 连起来：没有新鲜样本时安静片段是 0，不是最低强度
    var gated = AudioReactiveShaper()
    let floorOn = AudioSyncSettings(maxPercent: 60, minPercent: 10)
    r4check(gated.step(.silent, settings: floorOn, dt: 0.3,
                       hasAudio: AudioFlowWatch().allowsFloor(tapReady: true, playerPlaying: true, now: 1)).percent == 0,
            "最低强度：首拍空窗口输出 0")
}

// 跳转后等落点前进：往回走 / 跳太远都算又一次跳转（系统进度条连续拖动），只有正常播放的小步前进才恢复
do {
    var w = PlaybackProgressWatch()
    w.awaitSeekProgress(from: 30, now: 0)
    r4check(w.observe(at: 45, now: 0.25) == .waitingAfterSeek && w.awaitingSeekProgress, "跳转等待：又跳了 15 秒不算恢复")
    r4check(w.observe(at: 40, now: 0.5) == .waitingAfterSeek && w.awaitingSeekProgress, "跳转等待：往回走不算恢复")
    r4check(w.observe(at: 40.5, now: 0.75) == .moving && !w.awaitingSeekProgress, "跳转等待：2 倍速一拍的前进算恢复")
    r4check(w.observe(at: 52, now: 1) == .moving, "跳转等待结束后：普通播放中的跳变照旧算前进")
    w.awaitSeekProgress(from: 10, now: 2)
    r4check(w.observe(at: 11, now: 2.25) == .moving, "跳转等待：正好 1 秒的前进仍算恢复")
}

// 系统控件开播：只认暂停 → 播放的边沿；停止后的第一次外部续播先拦下
do {
    var gate = ExternalPlayGate()
    r4check(gate.observe(paused: true) == .ignore, "外部开播：初始暂停不是开播")
    r4check(gate.observe(paused: false) == .takeOver, "外部开播：暂停 → 播放接管")
    r4check(gate.observe(paused: false) == .ignore && gate.observe(paused: false) == .ignore,
            "外部开播：等待 ↔ 播放来回不再接管（只放视频时连上设备也不会自动输出）")
    _ = gate.observe(paused: true)
    gate.latchStop()
    r4check(gate.observe(paused: false) == .rejectAfterStop && !gate.stopLatched, "外部开播：停止后系统续播先拦下一次")
    _ = gate.observe(paused: true)
    r4check(gate.observe(paused: false) == .takeOver, "外部开播：拦下后再点播放照常接管")
    gate.latchStop()
    gate.clearLatch()
    _ = gate.observe(paused: true)
    r4check(gate.observe(paused: false) == .takeOver, "外部开播：本页播放键清掉锁存")
    gate.latchStop()
    r4check(gate.observe(paused: false) == .ignore && gate.stopLatched, "外部开播：不是边沿时锁存保留")
}

// App 自己 seek 的 timeJumped 回声：落点附近、0.5 秒内的那一条忽略，只消费一次
do {
    var echo = OwnSeekEcho()
    r4check(!echo.consumeIfEcho(position: 30, now: 1), "seek 回声：没记录时不算")
    echo.record(landed: 30, now: 1)
    r4check(echo.consumeIfEcho(position: 30.25, now: 1.25), "seek 回声：落点附近、0.5 秒内的通知忽略")
    r4check(!echo.consumeIfEcho(position: 30.25, now: 1.25), "seek 回声：只消费一次")
    echo.record(landed: 30, now: 2)
    r4check(!echo.consumeIfEcho(position: 40, now: 2.125), "seek 回声：紧接着的系统快进 10 秒照常处理")
    r4check(!echo.consumeIfEcho(position: 30, now: 2.75), "seek 回声：超过 0.5 秒不再当回声")
    echo.record(landed: 30, now: 3)
    r4check(!echo.consumeIfEcho(position: 20, now: 3.125), "seek 回声：往回跳不是回声")
    r4check(!echo.consumeIfEcho(position: .nan, now: 3.125), "seek 回声：位置读不出来不算")
}

let suite = "bc.round4.audiosync"
if let defaults = UserDefaults(suiteName: suite) {
    defaults.removePersistentDomain(forName: suite)
    r4check(AudioSyncSettings.load(from: defaults) == AudioSyncSettings(minPercent: AudioSyncSettings.defaultMinPercent,
                                                                         autoGain: AudioSyncSettings.defaultAutoGain,
                                                                         softDuck: AudioSyncSettings.defaultSoftDuck),
            "声音设置：没存过用默认（最低强度 10%、自动灵敏度开、轻柔声音降权开）")
    defaults.set("abc", forKey: AudioSyncSettings.Keys.maxPercent)
    defaults.set(9, forKey: AudioSyncSettings.Keys.channels)
    defaults.set(400.0, forKey: AudioSyncSettings.Keys.sensitivityDb)
    defaults.set(false, forKey: AudioSyncSettings.Keys.enabled)
    let loaded = AudioSyncSettings.load(from: defaults)
    r4check(loaded.maxPercent == 60 && loaded.channels == .both && loaded.sensitivityDb == 18 && !loaded.enabled,
            "声音设置：存储里的坏值不放大输出")
    defaults.removePersistentDomain(forName: suite)
} else {
    r4check(false, "声音设置：创建测试用 UserDefaults")
}
r4check(!AudioSyncSettings.Keys.enabled.contains(".") && !AudioSyncSettings.Keys.sensitivityDb.contains(".")
        && !AudioSyncSettings.Keys.maxPercent.contains(".") && !AudioSyncSettings.Keys.channels.contains("."),
        "声音设置：@AppStorage 键名不带点")

if r4Failures > 0 {
    print("Round4Checks: \(r4Failures) FAIL")
    exit(1)
}
print("Round4Checks: all passed")
