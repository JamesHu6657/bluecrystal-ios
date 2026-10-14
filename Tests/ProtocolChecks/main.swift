import Foundation

// CI 检查（修 L15）：swiftc 直接编译 Protocol.swift + Models.swift + SafetyLedger.swift + 本文件后运行。
// 钉住实抓帧字节、官方换算和 legacy 安全上限，任何一项不符就以非零退出码失败。

var failures = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond {
        print("ok   \(msg)")
    } else {
        print("FAIL \(msg) (main.swift:\(line))")
        failures += 1
    }
}

func near(_ a: Double?, _ b: Double) -> Bool {
    guard let a = a else { return false }
    return abs(a - b) < 0.001
}

func hex(_ d: Data) -> String { BCProtocol.hex(d) }

// MARK: - 帧字节

// 实抓（legacy research/protocol.md）
check(hex(BCProtocol.stopFrame) == "AA06050000000000B5", "停止帧 = 实抓暂停帧")
check(hex(BCProtocol.officialStartFrame) == "AA06050406050000C4", "如影随形 = 实抓启动帧")
// 官方源码 at([0,0,0,0], 0)
check(hex(BCProtocol.manualZeroFrame) == "AA0806000000000000B8", "0x08 归零帧")
// 旋转通道恒为 0（N5），0x06 夹到 9，0x08 夹到 99
check(hex(BCProtocol.modeFrame(channels: [1, 2, 3, 9])) == "AA06050102030000BB", "0x06 帧旋转恒 0")
check(hex(BCProtocol.modeFrame(channels: [12, -3, 0, 0])) == "AA06050900000000BE", "0x06 帧夹到 0~9")
check(hex(BCProtocol.manualFrame(channels: [99, 50, 0, 7])) == "AA08066332000000004D", "0x08 帧旋转恒 0、尾部 00 00")
check(hex(BCProtocol.videoFrame(levels: [60, 0, 0, 0])) == "AA08063C0000000000F4", "视频帧走 0x08")
check(BCProtocol.Channel.uiChannels == [.thrust, .vibration, .suction], "界面不显示旋转")

// F1：纯状态重现 t=10ms 首帧错误，100ms 仍发第二帧；调度由 BLEManager 执行。
var earlyErrorPair = StopPairAttempt()
check(!earlyErrorPair.recordFailure("zero error at 10ms"), "10ms 首帧错误只记录，不进入退避")
check(earlyErrorPair.phase == .gap, "首帧错误后仍保留 100ms 第二帧发送状态")
check(earlyErrorPair.didSendStopFrame() == "zero error at 10ms", "100ms 发出 0x06 后才处理首帧错误")
earlyErrorPair.stopAcked = true
check(!earlyErrorPair.confirmed, "首帧失败时 0x06 回执不能单独确认停止")
check(earlyErrorPair.recordFailure("retry pair"), "第二帧发出后允许整对重试")
earlyErrorPair.phase = .backoff
earlyErrorPair = StopPairAttempt()
check(!earlyErrorPair.confirmed && !earlyErrorPair.stopAcked, "整对重试清掉旧回执和错误")
earlyErrorPair.zeroAcked = true
check(!earlyErrorPair.confirmed, "只有首帧回执也不能确认停止")
_ = earlyErrorPair.didSendStopFrame()
earlyErrorPair.stopAcked = true
check(earlyErrorPair.confirmed, "新一轮两帧回执才确认停止")

// MARK: - 官方脚本强度换算（video.js executeIntensityCommand → BV(…, 10)）

check(BCProtocol.officialScriptLevel(status: 0) == 0, "status 0 → 0")
check(BCProtocol.officialScriptLevel(status: 0.5) == 0, "status 0.5 取整为 0、不加权")
check(BCProtocol.officialScriptLevel(status: 1) == 11, "status 1 → 11")
check(BCProtocol.officialScriptLevel(status: 10) == 20, "status 10 → 20")
check(BCProtocol.officialScriptLevel(status: 25.7) == 35, "status 25.7 → 35")
check(BCProtocol.officialScriptLevel(status: 88.9) == 98, "status 88.9 → 98")
check(BCProtocol.officialScriptLevel(status: 89) == 99, "status 89 → 99")
check(BCProtocol.officialScriptLevel(status: 100) == 99, "status 100 夹到 99")
check(BCProtocol.officialScriptLevel(status: .nan) == 0, "NaN → 0")
check(BCProtocol.officialScriptLevel(status: .infinity) == 99, "无穷大 → 99")
check(BCProtocol.officialScriptLevel(status: -5) == 0, "负数 → 0")

func script(_ json: String) -> TimelineScript? {
    try? JSONDecoder().decode(TimelineScript.self, from: Data(json.utf8))
}

func cmd(_ type: String, _ level: Double) -> String {
    "{\"commandType\":\"\(type)\",\"startTimeSeconds\":0,\"durationSeconds\":1,\"intensityLevel\":\(level)}"
}

if let s = script("{\"intensityScale\":\"ten\",\"commands\":[\(cmd("Thrust", 5)),\(cmd("Vibration", 10)),\(cmd("Suction", 0)),\(cmd("Thrust", 2.5))]}") {
    check(s.useTenScale && !s.scaleAmbiguous, "十档声明")
    check(s.deviceLevel(for: s.commands[0]) == 60, "十档 5 → 60")
    check(s.deviceLevel(for: s.commands[1]) == 99, "十档 10 → 99")
    check(s.deviceLevel(for: s.commands[2]) == 0, "十档 0 → 0")
    check(s.deviceLevel(for: s.commands[3]) == 35, "十档 2.5 → 35")
} else {
    check(false, "十档脚本解析")
}
if let s = script("{\"intensityScale\":\"percent\",\"commands\":[\(cmd("Thrust", 50))]}") {
    check(!s.useTenScale && s.deviceLevel(for: s.commands[0]) == 60, "百分制 50 → 60")
} else {
    check(false, "百分制脚本解析")
}
if let s = script("{\"commands\":[\(cmd("Thrust", 5)),\(cmd("Rotation", 3))]}") {
    check(s.scaleAmbiguous && !s.useTenScale, "未声明且 ≤10：按较弱的百分制并提示（L9）")
    check(s.deviceLevel(for: s.commands[0]) == 15, "未声明 5 → 15")
    check(s.ignoredRotationCount == 1, "旋转命令计数")
    check(s.commands[1].channel?.isUsed == false, "旋转命令不发")
} else {
    check(false, "未声明刻度脚本解析")
}
if let s = script("{\"commands\":[\(cmd("Thrust", 50)),\(cmd("Thrust", 5))]}") {
    check(!s.scaleAmbiguous && !s.useTenScale, "未声明但有 >10：确定是百分制")
} else {
    check(false, "百分制自动判断脚本解析")
}

// L11：播放起点作为 previous，连续采样不以 0.5s 为界；seek 的 previous=nil 不覆盖跳过部分。
let firstShort = TimelineCommand(commandType: "Thrust", startTimeSeconds: 0,
                                 durationSeconds: 0.05, intensityLevel: 5)
check(firstShort.isCovered(at: 0.1, previous: 0, fromPlaybackStart: true),
      "第一采样覆盖 [0,0.05) 的短命令")
check(!firstShort.isCovered(at: 0.1, previous: 0),
      "正常采样不重发恰好从上个采样点开始且已结束的命令")
let delayedShort = TimelineCommand(commandType: "Vibration", startTimeSeconds: 0.2,
                                   durationSeconds: 0.05, intensityLevel: 5)
check(delayedShort.isCovered(at: 1, previous: 0.1), "连续播放延迟 >0.5s 仍覆盖短命令")
let overlappingShort = TimelineCommand(commandType: "Suction", startTimeSeconds: 0.05,
                                       durationSeconds: 0.1, intensityLevel: 5)
check(overlappingShort.isCovered(at: 0.2, previous: 0.1, fromPlaybackStart: true),
      "恢复播放后的首个采样覆盖播放起点已经激活的短命令")
check(!overlappingShort.isCovered(at: 0.2, previous: 0.1),
      "正常采样不重复已经发过的命令，不延长结束后的输出")
check(!delayedShort.isCovered(at: 1, previous: nil), "seek 重置后不覆盖跳过的短命令")
check(!delayedShort.isCovered(at: 0.1, previous: 1), "倒退时间不覆盖跨越区间")
check(!firstShort.isCovered(at: 0.2, previous: 0.1), "不会重复覆盖已经过去的短命令")
check(delayedShort.isCovered(at: 0.22, previous: nil), "seek 到当前激活命令仍会同步")

// 自然结束必须补采样 [9.90,9.95]，包括最后一次 Timer 未碰到的 [9.91,9.93)。
check(PlaybackCompletion.reachedEnd(position: 9.95, duration: 9.95), "实际终点判定自然结束")
check(!PlaybackCompletion.reachedEnd(position: 9.90, duration: 9.95), "末尾外部暂停不判定自然结束")
check(!PlaybackCompletion.reachedEnd(position: .nan, duration: 9.95), "无效播放位置不判定自然结束")
check(!PlaybackCompletion.reachedEnd(position: 9.95, duration: .infinity), "未知时长不判定自然结束")
if let s = script("""
{"intensityScale":"ten","commands":[
 {"commandType":"Thrust","startTimeSeconds":9.91,"durationSeconds":0.02,"intensityLevel":5},
 {"commandType":"Vibration","startTimeSeconds":9.94,"durationSeconds":0.01,"intensityLevel":7},
 {"commandType":"Suction","startTimeSeconds":9.96,"durationSeconds":0.02,"intensityLevel":9},
 {"commandType":"Rotation","startTimeSeconds":9.91,"durationSeconds":0.02,"intensityLevel":9}]}
""") {
    check(s.levels(at: 9.90, previous: 9.80) == [0, 0, 0, 0], "最后 Timer 采样尚未覆盖末尾命令")
    check(s.levels(at: 9.95, previous: 9.90) == [60, 80, 0, 0], "终点补采样发送最后区间命令，仍忽略旋转")
    check(s.levels(at: 9.95, previous: nil) == [0, 0, 0, 0], "seek 到终点不补发跳过的命令")
    check(s.levels(at: 9.95, previous: 9.95) == [0, 0, 0, 0], "终点区间不重复覆盖已发命令")
} else {
    check(false, "最终区间脚本解析")
}

// MARK: - 安全上限（legacy limits.py / duty_cycle.py）

final class FakeClock {
    var t: TimeInterval = 1000
    var wall: TimeInterval = 1_700_000_000
    var boot: String? = "boot-a"
    func advance(_ s: TimeInterval) { t += s; wall += s }
}
let fc = FakeClock()
func makeLedger() -> DutyCycleLedger {
    DutyCycleLedger(clock: { fc.t }, wallClock: { fc.wall }, bootIdentity: { fc.boot })
}

check(SafetyLimits.maxRunSeconds == 300, "单次上限 300 秒")
check(SafetyLimits.dutyWindowSeconds == 1800 && SafetyLimits.dutyBudgetSeconds == 600, "30 分钟 600 秒")
check(SafetyLimits.minCooldownSeconds == 60 && SafetyLimits.cooldownRatio == 0.5, "冷却 max(60, 0.5×时长)")
check(SafetyLimits.unknownElapsedCooldownSeconds == 300 && SafetyLimits.checkpointIntervalSeconds == 5,
      "未知时长最大额度冷却 300 秒，每 5 秒保存下界")

let ledger = makeLedger()
check(ledger.checkAdmissible() == nil, "初始可以开始")
check(near(ledger.begin(), 300), "第一次最长 300 秒")
check(ledger.checkAdmissible() == .openRun, "运行中不能再开一次")
fc.advance(300)
check((ledger.runRemaining() ?? 1) <= 0, "300 秒到点")
ledger.end()
check(near(ledger.cooldownRemaining(), 150), "跑满 300 秒后冷却 150 秒")
if case .cooldown(let s)? = ledger.checkAdmissible() {
    check(near(s, 150), "冷却中拒绝开始")
} else {
    check(false, "冷却中拒绝开始")
}
fc.advance(150)
check(ledger.checkAdmissible() == nil, "冷却结束可以开始")
check(near(ledger.begin(), 300), "第二次 300 秒（额度还剩 300）")
fc.advance(300)
ledger.end()
fc.advance(150)
if case .budget(let wait)? = ledger.checkAdmissible() {
    check(near(wait, 1200), "600 秒额度用完，等最早一笔滑出窗口（1200 秒）")
} else {
    check(false, "600 秒额度用完应拒绝")
}
fc.advance(1200)
check(near(ledger.begin(), 300), "最早一笔滑出窗口后可再跑 300 秒")
fc.advance(10)
ledger.end()
check(near(ledger.cooldownRemaining(), 60), "短运行冷却下限 60 秒")

// 只剩部分额度时本次上限更短
let short = makeLedger()
short.begin()
fc.advance(300)
short.end()
fc.advance(150)
short.begin()
fc.advance(290)
short.end()
fc.advance(145)
check(near(short.remainingBudget(), 10) && near(short.begin(), 10), "额度只剩 10 秒时本次上限 10 秒")
fc.advance(10)
short.end()

// 持久化：重启 App 后冷却继续
let persisted = makeLedger()
persisted.begin()
fc.advance(100)
persisted.end()
let data = persisted.snapshotData()
fc.advance(30)
let restored = makeLedger()
if let d = data { restored.restore(from: d) }
check(near(restored.cooldownRemaining(), 30), "重启后冷却继续计时")
check(near(restored.remainingBudget(), 500), "重启后额度保留")

// F2：进程不在时不能执行软件截止停机，直到确认停止都记账，不限于 300s。
let orphan = makeLedger()
orphan.begin()
let orphanData = orphan.snapshotData()
fc.advance(1000)
let orphanRestored = makeLedger()
if let d = orphanData { orphanRestored.restore(from: d) }
check(orphanRestored.hasOpenRun && orphanRestored.openOrphaned, "未结束的运行跨进程保留")
check(!orphanRestored.openElapsedUnknown, "同 boot 遗留运行使用可验证的 uptime，不标记未知")
fc.advance(20)
orphanRestored.end()
check(near(orphanRestored.cooldownRemaining(), 510), "遗留运行 1020 秒含确认前等待，冷却 510 秒")
check(near(orphanRestored.remainingBudget(), 0), "遗留运行超过 600 秒耗尽额度，不按 300 秒封顶")

// 同 boot 墙钟被往回调：仍按 uptime，冷却不缩短。
let wallBack = makeLedger()
wallBack.begin()
fc.advance(100)
wallBack.end()
let wallData = wallBack.snapshotData()
fc.wall -= 3600
let wallRestored = makeLedger()
if let d = wallData { wallRestored.restore(from: d) }
check(near(wallRestored.cooldownRemaining(), 60), "墙钟回拨后冷却不缩短")
fc.wall += 3600

// F3：同 boot 跨 relaunch 只使用单调时间，前拨墙钟不能清掉预算或冷却。
let wallForward = makeLedger()
wallForward.begin()
fc.advance(300)
wallForward.end()
let forwardData = wallForward.snapshotData()
fc.advance(5)
fc.wall += 3600
let forwardRestored = makeLedger()
if let d = forwardData { forwardRestored.restore(from: d) }
check(near(forwardRestored.cooldownRemaining(), 145), "同 boot 前拨一小时后冷却只流逝 5 秒")
check(near(forwardRestored.remainingBudget(), 300), "同 boot 前拨一小时不清掉记账")
fc.wall -= 7200
let backwardRestored = makeLedger()
if let d = forwardData { backwardRestored.restore(from: d) }
check(near(backwardRestored.cooldownRemaining(), 145), "同 boot 后拨墙钟也只用 uptime")
fc.wall += 3600

// 同 boot 的 future openStart 墙钟值不会变成零时长。
let futureOpen = makeLedger()
futureOpen.begin()
let futureData = futureOpen.snapshotData()
fc.advance(1000)
fc.wall -= 3600
let futureRestored = makeLedger()
if let d = futureData { futureRestored.restore(from: d) }
futureRestored.end()
check(near(futureRestored.cooldownRemaining(), 500), "墙钟回拨的未结束运行仍按 uptime 计 1000 秒")
fc.wall += 3600

// 重启/uptime 倒退：不信任前拨墙钟，完整保留记账和冷却。
fc.boot = "boot-b"
fc.t = 10
fc.wall += 86400
let rebootRestored = makeLedger()
if let d = forwardData { rebootRestored.restore(from: d) }
check(near(rebootRestored.remainingBudget(), 300), "reboot 加前拨一天不剪掉记账")
check(near(rebootRestored.cooldownRemaining(), 150), "reboot 加前拨一天不缩短冷却")
// 保存保守恢复的新锚点后再次 relaunch，仍只流逝实际 uptime。
let rebasedData = rebootRestored.snapshotData()
fc.advance(5)
fc.wall += 86400
let rebasedRestored = makeLedger()
if let d = rebasedData { rebasedRestored.restore(from: d) }
check(near(rebasedRestored.cooldownRemaining(), 145), "保守恢复后再次 relaunch 不丢掉冷却")
check(near(rebasedRestored.remainingBudget(), 300), "保守恢复后的记账继续保留")

// 启动 UUID 即使相同，uptime 倒退也必须保守恢复。
let rollbackData = rebasedRestored.snapshotData()
fc.t = 1
let rollbackRestored = makeLedger()
if let d = rollbackData { rollbackRestored.restore(from: d) }
check(near(rollbackRestored.cooldownRemaining(), 150), "uptime 倒退不缩短冷却")
check(near(rollbackRestored.remainingBudget(), 300), "uptime 倒退不清掉记账")

// 兼容旧墙钟账本；缺少启动锚点时必须保持未知，而非估成 300 秒。
let legacyFuture = Data("""
{"completed":[],"openStart":\(fc.wall + 3600),"openAllowed":300,
 "lastEnd":null,"appliedCooldown":0}
""".utf8)
let legacyRestored = makeLedger()
legacyRestored.restore(from: legacyFuture)
check(legacyRestored.openElapsedUnknown && legacyRestored.checkAdmissible() == .openRun,
      "旧账本缺锚点保持未知、拒绝新运行")
legacyRestored.end()
check(near(legacyRestored.cooldownRemaining(), 300), "旧账本未知运行按全部额度应用最大冷却")
check(near(legacyRestored.remainingBudget(), 0), "旧账本未知运行停止后耗尽全部 600 秒额度")
let legacyCompleted = Data("""
{"completed":[{"end":\(fc.wall - 86400),"charge":600}],"openStart":null,
 "openAllowed":0,"lastEnd":\(fc.wall - 86400),"appliedCooldown":300}
""".utf8)
let legacyCompletedRestored = makeLedger()
legacyCompletedRestored.restore(from: legacyCompleted)
check(near(legacyCompletedRestored.remainingBudget(), 0), "旧墙钟账本的前拨不能抹掉 600 秒记账")
check(near(legacyCompletedRestored.cooldownRemaining(), 300), "旧墙钟账本的前拨不能清掉冷却")

// 重启且墙钟回拨：保留快照前已知 1000 秒，不能把 future openStart 改成现在。
fc.boot = "boot-c"
fc.t = 100
let rebootOpen = makeLedger()
rebootOpen.begin()
fc.advance(1000)
let rebootOpenData = rebootOpen.snapshotData()
fc.boot = "boot-d"
fc.t = 5
fc.wall -= 3600
let rebootOpenRestored = makeLedger()
if let d = rebootOpenData { rebootOpenRestored.restore(from: d) }
check(rebootOpenRestored.openElapsedUnknown, "reboot 后未知区间不能靠已知下界变成可信完整时长")
fc.advance(20)
rebootOpenRestored.end()
check(near(rebootOpenRestored.cooldownRemaining(), 512.5), "reboot 回拨计入已知时长、启动后 5 秒及确认等待")
check(near(rebootOpenRestored.remainingBudget(), 0), "reboot 回拨的遗留运行不按软件上限封顶")

// 审查重现：begin 快照后失联 1000 秒，reboot 且墙钟回拨，确认前又等 20 秒。
fc.boot = "unknown-a"
fc.t = 100
let unknownRun = makeLedger()
unknownRun.begin()
let unknownData = unknownRun.snapshotData()
fc.advance(1000)
fc.boot = "unknown-b"
fc.t = 10
fc.wall -= 3600
let unknownRestored = makeLedger()
if let d = unknownData { unknownRestored.restore(from: d) }
check(unknownRestored.hasOpenRun && unknownRestored.openElapsedUnknown,
      "reboot/回拨恢复显式未知运行，不伪造 300 秒")
check(unknownRestored.checkAdmissible() == .openRun && unknownRestored.begin() == nil,
      "未知运行在停止恢复前不能开新运行")
check(near(unknownRestored.remainingBudget(), 0), "未知运行的预留已耗尽全部额度")
let unknownRebasedData = unknownRestored.snapshotData()
if let d = unknownRebasedData,
   let fields = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
    check(fields["openElapsedUnknown"] as? Bool == true, "快照持久化未知标记")
    check(near(fields["openElapsedLowerBound"] as? Double, 10), "快照保存已验证下界而非 300 秒估计")
} else {
    check(false, "未知运行快照编码")
}
fc.advance(5)
let unknownRelaunched = makeLedger()
if let d = unknownRebasedData { unknownRelaunched.restore(from: d) }
check(unknownRelaunched.openElapsedUnknown, "重存同 boot 锚点再 relaunch 不能清掉未知状态")
fc.advance(15)
unknownRelaunched.end() // BLEManager 的确认停止/物理停机路径；物理锁存由 BLEManager 保留。
check(!unknownRelaunched.hasOpenRun && !unknownRelaunched.openElapsedUnknown, "确认停止结束未知运行")
check(near(unknownRelaunched.cooldownRemaining(), 300), "未知运行停止后至少冷却 300 秒")
check(near(unknownRelaunched.remainingBudget(), 0) && near(unknownRelaunched.secondsUntilBudget(), 1800),
      "未知运行恢复后完整 30 分钟没有新额度")
let unknownStoppedData = unknownRelaunched.snapshotData()
fc.advance(300)
let unknownStoppedRestored = makeLedger()
if let d = unknownStoppedData { unknownStoppedRestored.restore(from: d) }
check(near(unknownStoppedRestored.cooldownRemaining(), 0), "未知运行最大额度冷却计时跨进程保留")
check(unknownStoppedRestored.checkAdmissible() == .budget(1500), "冷却后仍须等满额度窗口")
fc.advance(1499)
check(near(unknownStoppedRestored.remainingBudget(), 0), "确认停止后 1799 秒仍无额度")
fc.advance(1)
check(unknownStoppedRestored.checkAdmissible() == nil, "确认停止后完整窗口才恢复额度")
fc.boot = "unknown-c"
fc.t = 5
fc.wall += 86400
let unknownStopRebootRestored = makeLedger()
if let d = unknownStoppedData { unknownStopRebootRestored.restore(from: d) }
check(near(unknownStopRebootRestored.cooldownRemaining(), 300)
      && near(unknownStopRebootRestored.remainingBudget(), 0)
      && near(unknownStopRebootRestored.secondsUntilBudget(), 1800),
      "恢复后的完整预算禁用和最大冷却跨 reboot/前拨继续保守保留")

// 每 5 秒持久化 checkpoint，停止/断链前的已验证时长跨 reboot 成为冷却下界。
fc.boot = "checkpoint-a"
fc.t = 100
let checkpointRun = makeLedger()
var checkpointData: Data?
var checkpointWrites = 0
checkpointRun.onChange = {
    checkpointWrites += 1
    checkpointData = checkpointRun.snapshotData()
}
checkpointRun.begin()
fc.advance(4)
checkpointRun.checkpoint()
check(checkpointWrites == 1, "checkpoint 不在每次看门狗 tick 写入")
fc.advance(1)
checkpointRun.checkpoint()
check(checkpointWrites == 2, "开放运行每 5 秒写入已验证时长")
fc.advance(995)
checkpointRun.checkpoint()
check(checkpointWrites == 3, "停止未确认的长运行仍持续保存 checkpoint")
let preRebootCheckpointData = checkpointData
checkpointRun.end()
let writesAfterEnd = checkpointWrites
fc.advance(5)
checkpointRun.checkpoint()
check(checkpointWrites == writesAfterEnd, "无开放运行时 checkpoint 不写入")
fc.boot = "checkpoint-b"
fc.t = 5
fc.wall -= 3600
let checkpointRestored = makeLedger()
if let d = preRebootCheckpointData { checkpointRestored.restore(from: d) }
check(checkpointRestored.openElapsedUnknown, "checkpoint 不会掩盖 reboot 的未知区间")
fc.advance(20)
checkpointRestored.end()
check(near(checkpointRestored.cooldownRemaining(), 512.5),
      "reboot 使用 checkpoint 的 1000 秒下界、启动 5 秒和等待 20 秒，不缩短冷却")
// 启动标识缺失、uptime 倒退或坏的开始锚点都必须显式未知。
fc.boot = "anchors-a"
fc.t = 100
let anchorsRun = makeLedger()
anchorsRun.begin()
fc.advance(10)
let anchorsData = anchorsRun.snapshotData()
fc.boot = nil
let missingBootRestored = makeLedger()
if let d = anchorsData { missingBootRestored.restore(from: d) }
check(missingBootRestored.openElapsedUnknown, "当前启动标识缺失时不信任开放运行锚点")
fc.boot = "anchors-a"
fc.t = 1
let openRollbackRestored = makeLedger()
if let d = anchorsData { openRollbackRestored.restore(from: d) }
check(openRollbackRestored.openElapsedUnknown, "同 boot 的 uptime 倒退也标记未知运行")
let invalidStartData = Data("""
{"completed":[],"openStart":\(fc.wall + 10),"openAllowed":300,
 "lastEnd":null,"appliedCooldown":0,"savedWall":\(fc.wall),
 "savedUptime":\(fc.t),"bootIdentity":"anchors-a"}
""".utf8)
let invalidStartRestored = makeLedger()
invalidStartRestored.restore(from: invalidStartData)
check(invalidStartRestored.openElapsedUnknown, "开始时间晚于保存锚点不能恢复成可信时长")

if failures > 0 {
    print("\(failures) 项检查失败")
    exit(1)
}
print("全部检查通过")
