import Foundation

// CI 检查（修 L15）：swiftc 直接编译 Protocol.swift + Models.swift + SafetyLedger.swift + AIProgram.swift + 本文件后运行。
// 钉住实抓帧字节、官方换算、legacy 安全上限、AI 指令解析/停止词/回复授权，任何一项不符就以非零退出码失败。

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
// 官方源码 at([0,0,0,0], 255)（迷姬专用停止，video.js handleSlide；L7：之前注释误写成 at(…, 0)）
check(hex(BCProtocol.manualZeroFrame) == "AA08060000000000FFB7", "0x08 停止帧 at([0,0,0,0],255)")
check(hex(BCProtocol.manualFrame(channels: [0, 0, 0, 0])) == "AA0806000000000000B8", "0x08 强度 0 帧")
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

// MARK: - 全零输出（H1/L5）和写入合并（M2）：BLEManager.submitOutput 的纯决策

check(BCProtocol.isAllZeroOutput(BCProtocol.manualFrame(channels: [0, 0, 0, 0])), "0x08 强度 0 帧算全零输出")
check(BCProtocol.isAllZeroOutput(BCProtocol.manualZeroFrame), "0x08 at(0,255) 算全零输出")
check(BCProtocol.isAllZeroOutput(BCProtocol.modeFrame(channels: [0, 0, 0, 0])), "0x06 全零帧算全零输出")
check(!BCProtocol.isAllZeroOutput(BCProtocol.manualFrame(channels: [0, 1, 0, 0])), "有一个通道非零就不算全零")
check(!BCProtocol.isAllZeroOutput(BCProtocol.officialStartFrame), "技能预设不算全零")
check(!BCProtocol.isAllZeroOutput(Data([0xAA, 0x08])), "残缺数据不算全零输出")
check(OutputGate.decide(allZero: false, isActive: false, zeroHeld: false) == .write, "非零帧照常走准入")
check(OutputGate.decide(allZero: true, isActive: false, zeroHeld: false) == .skipIdleZero,
      "设备没在输出：全零帧丢掉，不开始运行（L5）")
check(OutputGate.decide(allZero: true, isActive: true, zeroHeld: false) == .zeroStopPair,
      "运行中的全零帧换成完整停止帧对（H1）")
check(OutputGate.decide(allZero: true, isActive: true, zeroHeld: true) == .alreadyZeroed,
      "已经为全零发过停止帧对：重复的全零帧不再发")
check(OutputGate.decide(allZero: false, isActive: true, zeroHeld: true) == .write,
      "全零之后的非零帧照常输出（运行没有结束）")

let frameA = BCProtocol.manualFrame(channels: [10, 0, 0, 0])
let frameB = BCProtocol.manualFrame(channels: [20, 0, 0, 0])
let frameC = BCProtocol.manualFrame(channels: [30, 0, 0, 0])
var coalescer = OutputWriteCoalescer()
check(coalescer.submit(frameA) == .write(frameA) && coalescer.inFlight, "没有在途写入时立刻发")
check(coalescer.submit(frameB) == .coalesced, "有在途写入时不发")
check(coalescer.submit(frameC) == .coalesced, "在途期间继续合并")
check(coalescer.pending == frameC, "只保留最新一帧")
check(coalescer.writeFinished(canSend: true) == frameC && coalescer.inFlight, "回执后发最新一帧，仍只有一笔在途")
check(coalescer.writeFinished(canSend: true) == nil && !coalescer.inFlight, "没有待发帧时回到空闲")
_ = coalescer.submit(frameA)
_ = coalescer.submit(frameB)
coalescer.dropPending()
check(coalescer.pending == nil && coalescer.inFlight, "停止前丢掉待发输出；已在途的那笔照常等回执")
check(coalescer.writeFinished(canSend: true) == nil, "停止插队后，回执不会补发旧输出")
_ = coalescer.submit(frameA)
_ = coalescer.submit(frameB)
check(coalescer.writeFinished(canSend: false) == nil && coalescer.pending == nil && !coalescer.inFlight,
      "锁闸或停止进行中：回执后丢掉待发帧")
_ = coalescer.submit(frameA)
coalescer.reset()
check(!coalescer.inFlight && coalescer.submit(frameB) == .write(frameB), "断链重置后重新开始")

// MARK: - Brain 审查 M1/L3：升幅在出口按实际发出的上一帧再限一次

let r20 = BCProtocol.manualFrame(channels: [20, 0, 0, 0])
let r40 = BCProtocol.manualFrame(channels: [40, 0, 0, 0])
let r60 = BCProtocol.manualFrame(channels: [60, 0, 0, 0])
var ramp = OutputWriteCoalescer()
check(ramp.submit(r20, maxRise: 20) == .write(r20), "从 0 升 20：原样发出")
check(ramp.submit(r40, maxRise: 20) == .coalesced && ramp.submit(r60, maxRise: 20) == .coalesced,
      "回执慢：40、60 都在合并，40 被 60 覆盖")
check(ramp.writeFinished(canSend: true) == r40, "合并后发出的是 20+20=40，设备不会一步从 20 跳到 60（M1）")
check(ramp.baseline == [40, 0, 0, 0], "基准跟着实际发出的帧走")
check(ramp.writeFinished(canSend: true) == nil && !ramp.inFlight, "夹掉的差距不自动补（偏低方向安全）")
check(ramp.submit(r60, maxRise: 20) == .write(r60), "下一步从实际的 40 再升 20 到 60")
_ = ramp.writeFinished(canSend: true)
var idleJump = OutputWriteCoalescer()
check(idleJump.submit(BCProtocol.manualFrame(channels: [70, 70, 0, 0]), maxRise: 20)
      == .write(BCProtocol.manualFrame(channels: [20, 20, 0, 0])),
      "基准为 0（VM 起点偏高、帧被丢等，L3）：AI 帧要 70 也只发 20")
_ = idleJump.writeFinished(canSend: true)
check(idleJump.submit(BCProtocol.manualFrame(channels: [5, 0, 0, 0]), maxRise: 20)
      == .write(BCProtocol.manualFrame(channels: [5, 0, 0, 0])), "降低不受限、立即生效")
var manualCo = OutputWriteCoalescer()
let manual99 = BCProtocol.manualFrame(channels: [99, 0, 0, 0])
check(manualCo.submit(manual99) == .write(manual99), "手动/视频帧（不带 maxRise）不限速")
_ = manualCo.writeFinished(canSend: true)
manualCo.resetBaseline()
check(manualCo.submit(BCProtocol.manualFrame(channels: [50, 0, 0, 0]), maxRise: 20) == .write(r20),
      "停止帧对确认后基准归 0，AI 重新从 0 限速")
_ = manualCo.writeFinished(canSend: true)
manualCo.reset()
check(manualCo.baseline == nil, "断链重置清掉基准")
let mode999 = BCProtocol.modeFrame(channels: [9, 9, 9, 0])
check(OutputWriteCoalescer.limitRise(mode999, from: [0, 0, 0, 0], maxRise: 20) == mode999, "0x06 帧不改（AI 只发 0x08）")
check(BCProtocol.manualLevels(mode999) == nil && BCProtocol.manualLevels(r40) == [40, 0, 0, 0], "只从 0x08 帧取强度")
check(hex(OutputWriteCoalescer.limitRise(BCProtocol.manualFrame(channels: [90, 0, 0, 0], tail: 0x0102),
                                         from: [0, 0, 0, 0], maxRise: 20))
      == hex(BCProtocol.manualFrame(channels: [20, 0, 0, 0], tail: 0x0102)), "限速保留帧尾")

// MARK: - Brain 审查 M3：submitOutput 的完整准入顺序（OutputAdmission）

check(OutputAdmission.decide(.init(linkWritable: false)) == .drop, "链路不可写/后台/断开中：丢掉")
check(OutputAdmission.decide(.init(linkWritable: false, mayStillBeOutputting: true)) == .drop,
      "链路不可写时不提示（之后重连会先发停止）")
check(OutputAdmission.decide(.init(gateOpen: false)) == .drop, "闸门关着（停止后的尾帧、tick）：丢掉")
check(OutputAdmission.decide(.init(gateOpen: false, allZero: true, isActive: true)) == .drop,
      "闸门关着时全零帧也不另发停止")
check(OutputAdmission.decide(.init(mayStillBeOutputting: true, stopInProgress: true)) == .rejectMayBeActive,
      "设备可能仍在输出（锁存）：拒绝并提示，优先于停止进行中")
check(OutputAdmission.decide(.init(stopInProgress: true)) == .deferUntilStopped,
      "停止帧对在路上：输出挂起，绝不插进两帧之间")
check(OutputAdmission.decide(.init(stopInProgress: true, allZero: true, isActive: true)) == .deferUntilStopped,
      "停止进行中连全零帧也只挂起")
check(OutputAdmission.decide(.init(stopInProgress: true, stopFailed: true)) == .rejectStopUnconfirmed,
      "停止失败过还在重试：拒绝输出")
check(OutputAdmission.decide(.init(allZero: true, isActive: true)) == .zeroStopPair, "运行中全零：完整停止帧对")
check(OutputAdmission.decide(.init(allZero: true, isActive: true, zeroHeld: true)) == .alreadyZeroed, "重复全零不再发")
check(OutputAdmission.decide(.init(allZero: true)) == .skipIdleZero, "空闲全零：丢掉，不开始运行")
check(OutputAdmission.decide(.init()) == .write(startsRun: true), "空闲时的非零帧：先过冷却/额度再开始运行")
check(OutputAdmission.decide(.init(isActive: true)) == .write(startsRun: false), "运行中的非零帧：直接写")

// MARK: - Brain 审查 M5：开闸核对被动停机代次

check(OutputGate.mayOpen(requestEpoch: nil, currentEpoch: 7), "用户直接操作（手动拖动、视频页播放）不比代次")
check(OutputGate.mayOpen(requestEpoch: 7, currentEpoch: 7), "执行前读到的代次仍是最新：可以开闸")
check(!OutputGate.mayOpen(requestEpoch: 6, currentEpoch: 7), "执行前检查之后发生过被动停机：不开闸，不再只靠冷却兜底")

// MARK: - Brain 审查 L1：回执 FIFO 重新对齐

check(!WriteAckFIFO.canRealign([]), "空队列不用对齐")
check(WriteAckFIFO.canRealign([(isStop: true, timedOut: true), (isStop: true, timedOut: true)]),
      "只剩已超时的停止帧：清空重新对齐，丢失的回执不再让之后的停止永远确认不了")
check(!WriteAckFIFO.canRealign([(isStop: false, timedOut: true), (isStop: true, timedOut: true)]),
      "还有输出帧：不清，不能把输出帧的回执当成停止确认")
check(!WriteAckFIFO.canRealign([(isStop: true, timedOut: true), (isStop: true, timedOut: false)]),
      "还有没超时的条目（回执可能马上到）：不清")

// MARK: - Brain 审查 M3：手动页 300 秒空闲停机（ManualIdle）

check(ManualIdle.timeoutSeconds == 300, "手动页空闲时限 300 秒")
check(!ManualIdle.expired(now: 1299, lastInteraction: 1000, outputSinceStop: true), "299 秒没操作：继续")
check(ManualIdle.expired(now: 1300, lastInteraction: 1000, outputSinceStop: true), "300 秒没操作：停止")
check(!ManualIdle.expired(now: 9999, lastInteraction: 1000, outputSinceStop: false), "停止后没有输出：不计时")

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

check(SafetyLimits.maxRunSeconds == 1200, "单次上限 20 分钟")
check(SafetyLimits.dutyWindowSeconds == 1800 && SafetyLimits.dutyBudgetSeconds == 1200, "30 分钟 1200 秒")
check(SafetyLimits.minCooldownSeconds == 60 && SafetyLimits.cooldownRatio == 0.5, "冷却 max(60, 0.5×时长)")
check(SafetyLimits.unknownElapsedCooldownSeconds == 600 && SafetyLimits.checkpointIntervalSeconds == 5,
      "未知时长最大额度冷却 600 秒，每 5 秒保存下界")

let ledger = makeLedger()
check(ledger.checkAdmissible() == nil, "初始可以开始")
check(near(ledger.begin(), 1200), "第一次最长 1200 秒")
check(ledger.checkAdmissible() == .openRun, "运行中不能再开一次")
fc.advance(1200)
check((ledger.runRemaining() ?? 1) <= 0, "1200 秒到点")
ledger.end()
check(near(ledger.cooldownRemaining(), 600), "跑满 1200 秒后冷却 600 秒")
if case .cooldown(let s)? = ledger.checkAdmissible() {
    check(near(s, 600), "冷却中拒绝开始")
} else {
    check(false, "冷却中拒绝开始")
}
fc.advance(600)
if case .budget(let wait)? = ledger.checkAdmissible() {
    check(near(wait, 1200), "1200 秒额度用完，等这一笔滑出窗口（1200 秒）")
} else {
    check(false, "1200 秒额度用完应拒绝")
}
fc.advance(1200)
check(ledger.checkAdmissible() == nil, "滑出窗口后可以开始")
check(near(ledger.begin(), 1200), "滑出窗口后可再跑 1200 秒")
fc.advance(10)
ledger.end()
check(near(ledger.cooldownRemaining(), 60), "短运行冷却下限 60 秒")

// M1：断链很久才确认停止（同进程、时长已知）：冷却封顶 600 秒，额度照实际时长记账
let longLink = makeLedger()
longLink.begin()
fc.advance(5000)
longLink.end()
check(near(longLink.cooldownRemaining(), 600), "运行 5000 秒后确认停止：冷却封顶 600 秒")
check(near(longLink.remainingBudget(), 0), "冷却封顶不减少记账：5000 秒仍耗尽额度")
fc.advance(1800)

// 只剩部分额度时本次上限更短
let short = makeLedger()
short.begin()
fc.advance(600)
short.end()
fc.advance(300)
short.begin()
fc.advance(590)
short.end()
fc.advance(295)
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
check(near(restored.remainingBudget(), 1100), "重启后额度保留")

// F2：进程不在时不能执行软件截止停机，直到确认停止都记账，不限于单次上限。
let orphan = makeLedger()
orphan.begin()
let orphanData = orphan.snapshotData()
fc.advance(1500)
let orphanRestored = makeLedger()
if let d = orphanData { orphanRestored.restore(from: d) }
check(orphanRestored.hasOpenRun && orphanRestored.openOrphaned, "未结束的运行跨进程保留")
check(!orphanRestored.openElapsedUnknown, "同 boot 遗留运行使用可验证的 uptime，不标记未知")
fc.advance(20)
orphanRestored.end()
check(near(orphanRestored.cooldownRemaining(), 600), "遗留运行 1520 秒含确认前等待，冷却封顶 600 秒（M1）")
check(near(orphanRestored.remainingBudget(), 0), "遗留运行超过 1200 秒耗尽额度，不按单次上限封顶")

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
check(near(forwardRestored.remainingBudget(), 900), "同 boot 前拨一小时不清掉记账")
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
check(near(rebootRestored.remainingBudget(), 900), "reboot 加前拨一天不剪掉记账")
check(near(rebootRestored.cooldownRemaining(), 150), "reboot 加前拨一天不缩短冷却")
// 保存保守恢复的新锚点后再次 relaunch，仍只流逝实际 uptime。
let rebasedData = rebootRestored.snapshotData()
fc.advance(5)
fc.wall += 86400
let rebasedRestored = makeLedger()
if let d = rebasedData { rebasedRestored.restore(from: d) }
check(near(rebasedRestored.cooldownRemaining(), 145), "保守恢复后再次 relaunch 不丢掉冷却")
check(near(rebasedRestored.remainingBudget(), 900), "保守恢复后的记账继续保留")

// 启动 UUID 即使相同，uptime 倒退也必须保守恢复。
let rollbackData = rebasedRestored.snapshotData()
fc.t = 1
let rollbackRestored = makeLedger()
if let d = rollbackData { rollbackRestored.restore(from: d) }
check(near(rollbackRestored.cooldownRemaining(), 150), "uptime 倒退不缩短冷却")
check(near(rollbackRestored.remainingBudget(), 900), "uptime 倒退不清掉记账")

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
check(near(legacyRestored.cooldownRemaining(), 600), "旧账本未知运行按全部额度应用最大冷却")
check(near(legacyRestored.remainingBudget(), 0), "旧账本未知运行停止后耗尽全部 1200 秒额度")
let legacyCompleted = Data("""
{"completed":[{"end":\(fc.wall - 86400),"charge":1200}],"openStart":null,
 "openAllowed":0,"lastEnd":\(fc.wall - 86400),"appliedCooldown":600}
""".utf8)
let legacyCompletedRestored = makeLedger()
legacyCompletedRestored.restore(from: legacyCompleted)
check(near(legacyCompletedRestored.remainingBudget(), 0), "旧墙钟账本的前拨不能抹掉 1200 秒记账")
check(near(legacyCompletedRestored.cooldownRemaining(), 600), "旧墙钟账本的前拨不能清掉冷却")

// 重启且墙钟回拨：保留快照前已知 1500 秒，不能把 future openStart 改成现在。
fc.boot = "boot-c"
fc.t = 100
let rebootOpen = makeLedger()
rebootOpen.begin()
fc.advance(1500)
let rebootOpenData = rebootOpen.snapshotData()
fc.boot = "boot-d"
fc.t = 5
fc.wall -= 3600
let rebootOpenRestored = makeLedger()
if let d = rebootOpenData { rebootOpenRestored.restore(from: d) }
check(rebootOpenRestored.openElapsedUnknown, "reboot 后未知区间不能靠已知下界变成可信完整时长")
fc.advance(20)
rebootOpenRestored.end()
check(near(rebootOpenRestored.cooldownRemaining(), 600), "reboot 回拨的未知运行冷却封顶 600 秒（M1）")
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
check(near(unknownRelaunched.cooldownRemaining(), 600), "未知运行停止后至少冷却 600 秒")
check(near(unknownRelaunched.remainingBudget(), 0) && near(unknownRelaunched.secondsUntilBudget(), 1800),
      "未知运行恢复后完整 30 分钟没有新额度")
let unknownStoppedData = unknownRelaunched.snapshotData()
fc.advance(600)
let unknownStoppedRestored = makeLedger()
if let d = unknownStoppedData { unknownStoppedRestored.restore(from: d) }
check(near(unknownStoppedRestored.cooldownRemaining(), 0), "未知运行最大额度冷却计时跨进程保留")
check(unknownStoppedRestored.checkAdmissible() == .budget(1200), "冷却后仍须等满额度窗口")
fc.advance(1199)
check(near(unknownStoppedRestored.remainingBudget(), 0), "确认停止后 1799 秒仍无额度")
fc.advance(1)
check(unknownStoppedRestored.checkAdmissible() == nil, "确认停止后完整窗口才恢复额度")
fc.boot = "unknown-c"
fc.t = 5
fc.wall += 86400
let unknownStopRebootRestored = makeLedger()
if let d = unknownStoppedData { unknownStopRebootRestored.restore(from: d) }
check(near(unknownStopRebootRestored.cooldownRemaining(), 600)
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
fc.advance(1495)
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
check(near(checkpointRestored.cooldownRemaining(), 600),
      "reboot 后 checkpoint 下界 1525 秒的未知运行冷却封顶 600 秒（M1）")
check(near(checkpointRestored.remainingBudget(), 0), "冷却封顶不减少保守记账：额度仍耗尽")
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

// MARK: - AI 指令解析（AIProgram.swift）

func executable(_ r: AIReply) -> Bool { r.rejection == nil && (!r.steps.isEmpty || r.stop) }

let okReply = AIReply.parse("宝宝，开始了哦\n[CH 30 20 10 0]\n  [HOLD 3000]  \n[CH 0 0 0 0]\n[STOP]")
check(okReply.rejection == nil && okReply.stop, "合法程序：独占一行（允许前后空白）")
check(okReply.steps == [AIStep(levels: [30, 20, 10, 0], duration: 3), AIStep(levels: [0, 0, 0, 0], duration: 1.5)],
      "CH + HOLD 合并、默认间隔 1.5 秒")
check(okReply.text == "宝宝，开始了哦", "显示文字去掉指令行")

let persist = AIReply.parse("[CH 40 0 0 0]")
check(persist.rejection == nil && persist.steps == [AIStep(levels: [40, 0, 0, 0], duration: 0)] && !persist.stop,
      "没有 STOP 时最后一步保持（duration 0）")

let clamped = AIReply.parse("[ch 99 0 0 77]\n[HOLD 100]\n[CH 5 5 5 5]\n[HOLD 999999]")
check(clamped.steps.first?.levels == [99, 0, 0, 0], "强度 99 原样保留（上限 70 由 AISafety 处理），c3 恒 0，关键字不分大小写")
check(clamped.steps.first?.duration == 0.5, "HOLD 夹到最少 500 毫秒")
check(clamped.steps.last?.levels == [5, 5, 5, 0] && clamped.steps.last?.duration == 60, "HOLD 夹到最多 60000 毫秒")

// 只有独占一行才算指令；行内、引用、代码块里的指令样式文字让整条作废
for (raw, name) in [
    ("不要执行 [CH 99 0 0 0]", "行内指令"),
    ("[CH 30 0 0 0] 宝宝来了", "指令后面跟文字"),
    ("宝宝\n> [CH 60 0 0 0]", "引用里的指令"),
    ("例子：\n```\n[CH 60 0 0 0]\n```", "代码块里的指令"),
    ("“[CH 60 0 0 0]”", "引号里的指令"),
    ("[CH 30 0 0 0]\n宝宝说[STOP]我就停", "合法行 + 行内 STOP"),
] {
    let r = AIReply.parse(raw)
    check(r.rejection != nil && !executable(r), "\(name)：整条不执行")
}

// 代码块按 CommonMark 围栏：同字符、长度不短于开头、后面只剩空白才闭合；没闭合算到结尾
for (raw, name) in [
    ("````\n```\n[CH 99 0 0 0]\n````", "4 反引号块里的 3 反引号行之后"),
    ("````\n```\n[CH 99 0 0 0]", "短围栏不能闭合长围栏"),
    ("~~~\n```\n[CH 99 0 0 0]\n```\n~~~", "波浪线块里的反引号围栏"),
    ("```\n~~~\n[CH 99 0 0 0]\n~~~\n```", "反引号块里的波浪线围栏"),
    ("```\n``` 还没完\n[CH 99 0 0 0]\n```", "围栏后面有文字不算闭合"),
    ("```\n```\u{3000}\n[CH 99 0 0 0]", "全角空格不算闭合围栏后的空白"),
    ("例子：\n```\n[CH 99 0 0 0]", "没闭合的代码块"),
    ("```python\nprint(1)\n\n[STOP]", "没闭合的代码块里的 STOP"),
    ("``` [CH 99 0 0 0]", "围栏信息串里的指令"),
    ("```\n    ```\n[CH 99 0 0 0]", "缩进 4 格的闭合围栏（含糊）"),
    ("- ```\n  [CH 99 0 0 0]\n  ```", "列表里的围栏（含糊）"),
    ("> ```\n[CH 99 0 0 0]", "引用里的围栏（含糊）"),
    ("```a`b\n[CH 99 0 0 0]\n```", "信息串带反引号不是围栏（含糊）"),
] {
    let r = AIReply.parse(raw)
    check(r.rejection != nil && !executable(r), "\(name)：整条不执行")
}

let afterFence = AIReply.parse("示例：\n```\n[笑]\n```\n[CH 30 0 0 0]\n[HOLD 2000]\n[STOP]")
check(afterFence.rejection == nil && afterFence.stop
      && afterFence.steps == [AIStep(levels: [30, 0, 0, 0], duration: 2)], "闭合代码块之后的指令正常执行")
let longFence = AIReply.parse("````\n```\n````  \n[CH 25 0 0 0]")
check(longFence.rejection == nil && longFence.steps == [AIStep(levels: [25, 0, 0, 0], duration: 0)],
      "4 反引号块用 4 反引号闭合（后面允许空格），之后的指令正常执行")
let tildeFence = AIReply.parse("~~~~\n~~~\n```\n~~~~~\n[CH 15 0 0 0]")
check(tildeFence.rejection == nil && tildeFence.steps == [AIStep(levels: [15, 0, 0, 0], duration: 0)],
      "波浪线块只被更长或等长的波浪线闭合")
check(AIReply.parse("用 ``` 包代码就行").rejection == nil, "没有指令时含糊围栏不影响")

// 代码块外的指令行：制表符或 4 格以上缩进可能是缩进代码块，整条作废；0~3 个空格照常
// 渲染时可能藏住指令的 HTML、围栏字符后的组合符号：有指令就整条作废
for (raw, name) in [
    ("x\n\n    [CH 99 0 0 0]", "空行后缩进 4 格的指令（缩进代码块）"),
    ("\t[CH 99 0 0 0]", "制表符缩进的指令"),
    ("宝宝\n     [STOP]", "缩进 5 格的 STOP"),
    ("<pre>\n[CH 99 0 0 0]\n</pre>", "<pre> 里的指令"),
    ("<PRE class=\"x\">\n[CH 99 0 0 0]\n</PRE>", "大写 <PRE>"),
    ("<Code>\n[CH 99 0 0 0]\n</Code>", "<code> 里的指令"),
    ("<!--\n[CH 99 0 0 0]\n-->", "HTML 注释里的指令"),
    ("<textarea>\n[CH 99 0 0 0]\n</textarea>", "<textarea> 里的指令"),
    ("<SCRIPT>\n[CH 99 0 0 0]\n</SCRIPT>", "<script> 里的指令"),
    ("<style>\n[CH 99 0 0 0]\n</style>", "<style> 里的指令"),
    ("<template>\n[CH 99 0 0 0]\n</template>", "<template> 里的指令"),
    ("[CH 30 0 0 0]\n<!-- 注释 -->", "合法指令 + HTML 注释"),
    ("```\u{301}\n[CH 99 0 0 0]", "反引号后紧跟组合符号的围栏"),
    ("~~~\u{300}\n[CH 99 0 0 0]\n~~~", "波浪线后紧跟组合符号的围栏"),
    ("说明 ``\u{301}` 示例\n[CH 99 0 0 0]", "行内反引号中间夹组合符号"),
    ("```\n```\u{301}\n[CH 99 0 0 0]", "带组合符号的行不能闭合围栏"),
] {
    let r = AIReply.parse(raw)
    check(r.rejection != nil && !executable(r), "\(name)：整条不执行")
}
for (raw, name) in [
    (" [CH 20 0 0 0]", "缩进 1 格"),
    ("  [CH 20 0 0 0]", "缩进 2 格"),
    ("宝宝\n\n   [CH 20 0 0 0]", "空行后缩进 3 格"),
] {
    let r = AIReply.parse(raw)
    check(r.rejection == nil && r.steps == [AIStep(levels: [20, 0, 0, 0], duration: 0)], "\(name)的指令照常执行")
}
check(AIReply.parse("宝宝\n    继续缩进的文字").rejection == nil, "没有指令时缩进文字不影响")
check(AIReply.parse("<pre>乖</pre>\n<!-- 嘘 -->").rejection == nil, "没有指令时 HTML 不影响")
do {
    // 代码块里的 HTML 只是示例文字，不让代码块外的合法指令作废
    let r = AIReply.parse("```\n<pre>示例</pre>\n<textarea>\n```\n[CH 20 0 0 0]")
    check(r.rejection == nil && r.steps == [AIStep(levels: [20, 0, 0, 0], duration: 0)], "代码块里的 HTML 不影响块外指令")
}

// 参数必须精确
for (raw, name) in [
    ("[CH bad 99 0 0]", "坏参数不挪通道"),
    ("[CH 30 20 0]", "CH 少一个参数"),
    ("[CH 30 20 0 0 0]", "CH 多一个参数"),
    ("[CH 1e2 0 0 0]", "科学计数法"),
    ("[CH 30.5 0 0 0]", "小数"),
    ("[CH -5 0 0 0]", "负数"),
    ("[CH 30,20,0,0]", "逗号分隔"),
    ("[CH30 0 0 0]", "关键字粘连"),
    ("[CH 99999999999999999999999 0 0 0]", "溢出整数"),
    ("[HOLD]", "HOLD 缺参数"),
    ("[HOLD 0]", "HOLD 0"),
    ("[HOLD 1000 2000]", "HOLD 多参数"),
    ("[HOLD 1.5e3]", "HOLD 科学计数法"),
    ("[STOP now]", "STOP 带参数"),
    ("[CH 30 20 0 0", "缺右括号"),
    ("[STOP]\n[CH 30 0 0 0]", "STOP 之后还有指令"),
] {
    let r = AIReply.parse("宝宝\n[CH 10 0 0 0]\n" + raw)
    check(r.rejection != nil && r.steps.isEmpty && !r.stop, "\(name)：整条作废，前面的合法指令也不执行")
}

// 超过步数上限：整条作废，不执行前缀，也不丢 STOP
let fortyCH = (0..<AIReply.maxSteps).map { _ in "[CH 20 0 0 0]" }.joined(separator: "\n")
let atLimit = AIReply.parse(fortyCH + "\n[STOP]")
check(atLimit.rejection == nil && atLimit.steps.count == AIReply.maxSteps && atLimit.stop,
      "正好 40 步 + 末尾 STOP：STOP 保留")
let oversized = AIReply.parse(fortyCH + "\n[CH 0 0 0 0]\n[STOP]")
check(oversized.rejection != nil && oversized.steps.isEmpty && !oversized.stop, "41 步：整条作废，不执行前缀")
check(AIReply.parse("[STOP]").stop && AIReply.parse("[STOP]").steps.isEmpty, "单独 STOP")
check(AIReply.parse("[笑] 宝宝乖").rejection == nil, "非指令的方括号文字不受影响")

// H3：CH 超过 99 不夹紧，整条回复不执行
for (raw, name) in [
    ("[CH 150 0 0 0]", "伸缩 150"),
    ("[CH 30 0 0 100]", "旋转位 100"),
    ("宝宝\n[CH 30 0 0 0]\n[CH 100 0 0 0]\n[STOP]", "后面一步 100"),
] {
    let r = AIReply.parse(raw)
    check(r.rejection != nil && !executable(r), "\(name)：超过 99 整条不执行")
}
check(AIReply.parse("[CH 150 150 150 0]").rejection?.contains("超过 99") == true, "超过 99 的作废原因写明")

// H3：AI 强度上限 70、每步最多 +20、从空闲开始从 0 爬升（AISafety）
check(AISafety.maxLevel == 70 && AISafety.maxStepIncrease == 20 && AISafety.rampStepSeconds == 1
      && AISafety.holdIdleTimeout == 120, "AI 安全常数：上限 70、每步 +20、爬升 1 秒、保持空闲 120 秒")
let fromIdle = AISafety.enforce([AIStep(levels: [60, 0, 0, 0], duration: 0)], from: [0, 0, 0, 0])
check(fromIdle.steps == [AIStep(levels: [20, 0, 0, 0], duration: 1), AIStep(levels: [40, 0, 0, 0], duration: 1),
                         AIStep(levels: [60, 0, 0, 0], duration: 0)],
      "从空闲开始：第一步每秒 +20 从 0 爬到目标，目标步保持原时长")
check(fromIdle.rampSteps == 2 && fromIdle.clampedValues == 0, "爬升步计数")
let overCap = AISafety.enforce([AIStep(levels: [99, 80, 10, 0], duration: 2)], from: [70, 70, 0, 0])
check(overCap.steps == [AIStep(levels: [70, 70, 10, 0], duration: 2)] && overCap.clampedValues == 2,
      "超过 70 的值压到 70")
check(overCap.displaySteps == [AIStep(levels: [70, 70, 10, 0], duration: 2)], "界面显示压低后的值")
check(AISafety.describe(overCap, stop: false).contains("已压到 70"), "程序说明标出压到 70")
let fullIdle = AISafety.enforce(AIReply.parse("[CH 99 99 99 0]").steps, from: [0, 0, 0, 0])
check(fullIdle.steps.first == AIStep(levels: [20, 20, 20, 0], duration: 1)
      && fullIdle.steps.last == AIStep(levels: [70, 70, 70, 0], duration: 0) && fullIdle.rampSteps == 3,
      "开场拉满：压到 70，从 0 每秒 +20 爬上去")
let goingDown = AISafety.enforce([AIStep(levels: [10, 0, 0, 0], duration: 1.5)], from: [70, 60, 0, 0])
check(goingDown.steps == [AIStep(levels: [10, 0, 0, 0], duration: 1.5)] && goingDown.rampSteps == 0,
      "降低立刻生效，不插爬升步")
let mixedMove = AISafety.enforce([AIStep(levels: [50, 0, 0, 0], duration: 1.5)], from: [20, 60, 0, 0])
check(mixedMove.steps == [AIStep(levels: [40, 0, 0, 0], duration: 1), AIStep(levels: [50, 0, 0, 0], duration: 1.5)],
      "升的通道爬升，降的通道在第一步就降")
let chained = AISafety.enforce([AIStep(levels: [20, 0, 0, 0], duration: 1.5), AIStep(levels: nil, duration: 3),
                                AIStep(levels: [65, 0, 0, 0], duration: 0)], from: [0, 0, 0, 0])
check(chained.steps == [AIStep(levels: [20, 0, 0, 0], duration: 1.5), AIStep(levels: nil, duration: 3),
                        AIStep(levels: [40, 0, 0, 0], duration: 1), AIStep(levels: [60, 0, 0, 0], duration: 1),
                        AIStep(levels: [65, 0, 0, 0], duration: 0)],
      "每一步都和上一步比，HOLD 不改强度")
let fromHold = AISafety.enforce([AIStep(levels: [55, 0, 0, 0], duration: 0)], from: [40, 0, 0, 0])
check(fromHold.steps == [AIStep(levels: [55, 0, 0, 0], duration: 0)], "接着保持的强度继续：差不超过 20 不爬升")
let zeroEnding = AISafety.enforce(AIReply.parse("[CH 30 0 0 0]\n[CH 0 0 0 0]").steps, from: [0, 0, 0, 0])
check(zeroEnding.steps.first == AIStep(levels: [20, 0, 0, 0], duration: 1)
      && ReplyAuthorization.programEndIsTerminal(steps: zeroEnding.steps, endWithStop: false),
      "爬升不改变全零结尾的停止判断")

// Brain 审查 M2：时间限速，两次升高至少隔 1 秒（真正的"每秒每通道最多 +20"）

/// 按执行时间轴检查：每次升高每通道 ≤20，且离上次升高 ≥ 1 秒
func riseGapsOK(_ steps: [AIStep], from start: [Int], sinceRise: Double = .infinity) -> Bool {
    var cur = start
    var t = 0.0
    var lastRise = -sinceRise
    for s in steps {
        if let lv = s.levels {
            if lv.indices.contains(where: { lv[$0] > cur[$0] }) {
                if t - lastRise < AISafety.rampStepSeconds - 1e-9 { return false }
                if lv.indices.contains(where: { lv[$0] - cur[$0] > AISafety.maxStepIncrease }) { return false }
                lastRise = t
            }
            cur = lv
        }
        t += s.duration
    }
    return true
}

let fastClimbSteps = AIReply.parse("[CH 20 0 0 0]\n[HOLD 500]\n[CH 40 0 0 0]\n[HOLD 500]\n[CH 60 0 0 0]").steps
check(!riseGapsOK(fastClimbSteps, from: [0, 0, 0, 0]), "原始程序 0.5 秒升一次 20（审查重现）")
let fastClimb = AISafety.enforce(fastClimbSteps, from: [0, 0, 0, 0])
check(fastClimb.steps == [AIStep(levels: [20, 0, 0, 0], duration: 0.5), AIStep(levels: nil, duration: 0.5),
                          AIStep(levels: [40, 0, 0, 0], duration: 0.5), AIStep(levels: nil, duration: 0.5),
                          AIStep(levels: [60, 0, 0, 0], duration: 0)] && fastClimb.waitSteps == 2,
      "HOLD 500 连续 +20：每次升高前补等待到满 1 秒")
check(riseGapsOK(fastClimb.steps, from: [0, 0, 0, 0]), "限速后每秒每通道最多 +20")
check(AISafety.describe(fastClimb, stop: false).contains("等待"), "程序说明标出插入的等待")
check(riseGapsOK(fullIdle.steps, from: [0, 0, 0, 0]) && riseGapsOK(chained.steps, from: [0, 0, 0, 0]),
      "爬升步本身就是 1 秒一步")
let crossReply = AISafety.enforce([AIStep(levels: [40, 0, 0, 0], duration: 0)], from: [20, 0, 0, 0],
                                  secondsSinceRise: 0.3)
check(crossReply.steps.count == 2 && crossReply.steps[0].levels == nil && near(crossReply.steps[0].duration, 0.7)
      && crossReply.steps[1] == AIStep(levels: [40, 0, 0, 0], duration: 0),
      "跨回复：上次升高 0.3 秒前，先等 0.7 秒再升")
let waitLowers = AISafety.enforce([AIStep(levels: [40, 0, 0, 0], duration: 1.5)], from: [20, 60, 0, 0],
                                  secondsSinceRise: 0.5)
check(waitLowers.steps == [AIStep(levels: [20, 0, 0, 0], duration: 0.5), AIStep(levels: [40, 0, 0, 0], duration: 1.5)],
      "等待期间降低的通道立即生效，只有升高要等")
check(AISafety.enforce([AIStep(levels: [10, 0, 0, 0], duration: 1)], from: [50, 0, 0, 0], secondsSinceRise: 0).waitSteps == 0,
      "只降低不用等")

var seed: UInt64 = 0x5EED
func nextRand(_ n: Int) -> Int {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Int((seed >> 33) % UInt64(n))
}
var fuzzOK = true
for _ in 0..<300 {
    var program: [AIStep] = []
    for _ in 0..<(1 + nextRand(10)) {
        if nextRand(4) == 0 {
            program.append(AIStep(levels: nil, duration: [0.5, 1, 3][nextRand(3)]))
        } else {
            program.append(AIStep(levels: [nextRand(100), nextRand(100), nextRand(100), 0],
                                  duration: [0.5, 1, 1.5, 3][nextRand(4)]))
        }
    }
    let start = [nextRand(71), nextRand(71), nextRand(71), 0]
    let since = [0.0, 0.3, 0.9, 5][nextRand(4)]
    let p = AISafety.enforce(program, from: start, secondsSinceRise: since)
    let capped = p.steps.allSatisfy { ($0.levels ?? [0]).allSatisfy { $0 <= AISafety.maxLevel } }
    if !capped || !riseGapsOK(p.steps, from: start, sinceRise: since) { fuzzOK = false }
}
check(fuzzOK, "随机 300 段程序：每次升高 ≤20、两次升高至少隔 1 秒、强度 ≤70（M2）")

// H2：保持最后强度时，120 秒没有新的用户消息就停止
check(!AISafety.holdIdleExpired(now: 5000, holdStartedAt: nil, lastUserMessageAt: 0), "没在保持时不计时")
check(!AISafety.holdIdleExpired(now: 1119, holdStartedAt: 1000, lastUserMessageAt: 990), "保持 119 秒未超时")
check(AISafety.holdIdleExpired(now: 1120, holdStartedAt: 1000, lastUserMessageAt: 990), "保持 120 秒没有新消息就停止")
check(!AISafety.holdIdleExpired(now: 1120, holdStartedAt: 1000, lastUserMessageAt: 1050), "保持期间的新消息重新计时")
check(AISafety.holdIdleExpired(now: 1170, holdStartedAt: 1000, lastUserMessageAt: 1050), "新消息之后 120 秒仍没有回应就停止")
check(AISafety.holdIdleExpired(now: 1120, holdStartedAt: 1000, lastUserMessageAt: nil), "没有用户消息记录时从保持开始算")

// Brain 审查 H1：在场超时覆盖整个运行（执行程序期间也算），单条程序总时长 ≤120 秒
check(!AISafety.presenceExpired(now: 1119, lastUserMessageAt: 1000, runStartedAt: 1010), "最近一条消息后 119 秒：继续")
check(AISafety.presenceExpired(now: 1120, lastUserMessageAt: 1000, runStartedAt: 1010),
      "程序还在执行，离最近一条消息 120 秒也停止")
check(AISafety.presenceExpired(now: 1130, lastUserMessageAt: nil, runStartedAt: 1010), "没有用户消息记录时从开始运行算")
check(!AISafety.presenceExpired(now: 5000, lastUserMessageAt: nil, runStartedAt: nil), "没在运行不计时")
check(AISafety.maxProgramSeconds == AISafety.holdIdleTimeout, "单条程序总时长上限 = 在场时限 120 秒")
let longHolds = (0..<AIReply.maxSteps).map { _ in "[CH 20 0 0 0]\n[HOLD 60000]" }.joined(separator: "\n")
let longReply = AIReply.parse(longHolds)
check(longReply.rejection == nil && longReply.steps.count == AIReply.maxSteps, "40 × HOLD 60000 的格式本身合法")
let longProgram = AISafety.enforce(longReply.steps, from: [0, 0, 0, 0])
check(longProgram.totalSeconds >= 2400 && AISafety.programTooLong(longProgram) != nil,
      "40 分钟的程序整条不执行（审查重现：之前能无人值守跑到 1200 秒单次上限）")
check(AISafety.programTooLong(AISafety.enforce(okReply.steps, from: [0, 0, 0, 0])) == nil, "普通程序不受影响")
let edgeProgram = AISafety.enforce([AIStep(levels: [20, 0, 0, 0], duration: 60), AIStep(levels: nil, duration: 60)],
                                   from: [0, 0, 0, 0])
check(near(edgeProgram.totalSeconds, 120) && AISafety.programTooLong(edgeProgram) == nil, "正好 120 秒可以执行")

// L2：请求历史不含出错提示，从用户消息开始，同角色相邻合并
let historyTurns = [
    AIHistory.Turn(isUser: false, isError: false, content: "a0"),
    AIHistory.Turn(isUser: true, isError: false, content: "u1"),
    AIHistory.Turn(isUser: false, isError: true, content: "出错了：超时"),
    AIHistory.Turn(isUser: true, isError: false, content: "u2"),
    AIHistory.Turn(isUser: false, isError: false, content: "a2"),
]
let fullWindow = AIHistory.window(historyTurns, limit: 20)
check(fullWindow.first?["role"] == "user", "历史窗口从用户消息开始")
check(fullWindow.count == 2 && fullWindow[0]["content"] == "u1\nu2" && fullWindow[1]["content"] == "a2",
      "出错提示不进历史，相邻用户消息合并")
check(!fullWindow.contains { $0["content"]?.contains("出错了") == true }, "历史里没有出错提示")
let shortWindow = AIHistory.window(historyTurns, limit: 2)
check(shortWindow.count == 2 && shortWindow[0]["role"] == "user" && shortWindow[0]["content"] == "u2",
      "截断后的窗口仍从用户消息开始")
check(AIHistory.window(historyTurns, limit: 1).isEmpty, "窗口里只剩 assistant 时整段丢掉")

// Brain 审查 L6：回传给模型的内容
check(AIHistory.content(raw: "[CH 20 0 0 0]\n乖", text: "乖") == "[CH 20 0 0 0]\n乖", "执行过的回复回传原文")
check(AIHistory.content(raw: nil, text: "乖") == "乖", "没执行的回复回传显示文字")
check(AIHistory.content(raw: nil, text: "") == "…", "没执行且没有文字：回传…，不把\"未执行：…\"当成模型发言")

// MARK: - 回复授权（AIControlVM 的 send → 停止 → 执行前验票）

// 发送后程序以 [STOP] / 全零自动结束（AIControlVM.runStep 走 terminalStop）：之后到的回复不执行
for (raw, name) in [("[CH 30 0 0 0]\n[HOLD 2000]\n[STOP]", "[STOP] 结尾"), ("[CH 30 0 0 0]\n[CH 0 0 0 0]", "全零结尾")] {
    var auth = ReplyAuthorization()
    let running = AIReply.parse(raw)
    let pending = auth.issue()
    let terminal = ReplyAuthorization.programEndIsTerminal(steps: running.steps, endWithStop: running.stop)
    check(terminal, "\(name)的程序走完算真正停止")
    if terminal { auth.revoke() }
    check(auth.block(pending) != nil, "\(name)自动停止后，停止前发出的请求的回复不执行")
    check(auth.block(auth.issue()) == nil, "\(name)自动停止后再发的新消息可以执行")
}
// 用户点停止 / 本地停止词（票在本地停止之前领）：之后到的回复不执行
var userStopAuth = ReplyAuthorization()
let beforeUserStop = userStopAuth.issue()
userStopAuth.revoke()
check(userStopAuth.block(beforeUserStop) != nil, "用户停止后，停止前发出的请求的回复不执行")
var stopWordAuth = ReplyAuthorization()
let stopWordTicket = stopWordAuth.issue()
stopWordAuth.revoke()
check(stopWordAuth.block(stopWordTicket) != nil, "停止词那句的回复也不执行")
// 发送后没有任何停止：回复可以执行；保持最后强度的程序走完不算停止，不作废授权
let openAuth = ReplyAuthorization()
let openTicket = openAuth.issue()
check(openAuth.block(openTicket) == nil, "发送后没有停止：回复可以执行")
let holding = AIReply.parse("[CH 30 0 0 0]\n[HOLD 2000]\n[CH 40 0 0 0]")
check(!ReplyAuthorization.programEndIsTerminal(steps: holding.steps, endWithStop: holding.stop),
      "保持最后强度的程序走完不算停止")
check(openAuth.block(openTicket) == nil, "保持中的程序不作废待执行的回复")
// 多次停止后，任何旧票都不会重新生效
var multiAuth = ReplyAuthorization()
let oldTicket = multiAuth.issue()
multiAuth.revoke()
let midTicket = multiAuth.issue()
multiAuth.revoke()
check(multiAuth.block(oldTicket) != nil && multiAuth.block(midTicket) != nil, "连续停止后旧票都失效")

// MARK: - 本地停止词

for s in ["停", "停下", "停止", "别动了", "够了", "不要了", "疼", "受不了", "慢点停", "我疼，停止",
          "宝宝受不了了", "stop", "STOP!", "please stop", "Stop now", "ｓｔｏｐ", "停一下好吗",
          "暂停", "等等", "疼死了", "pause", "Wait!", "wait a sec", "enough", "that's ENOUGH", "ｐａｕｓｅ"] {
    check(AIStopWords.matches(s), "停止词：\(s)")
}
for s in ["慢", "慢一点", "再快点", "继续", "stopped", "nonstop", "unstoppable", "好舒服",
          "waiting", "paused", "awaited"] {
    check(!AIStopWords.matches(s), "不是停止词：\(s)")
}

// MARK: - 接口完整性

check(LLMResponse.incompleteReason(["choices": [["finish_reason": "stop"]]], wire: .chatCompletions) == nil,
      "chat finish_reason=stop 完整")
check(LLMResponse.incompleteReason(["choices": [["finish_reason": "length"]]], wire: .chatCompletions) != nil,
      "chat finish_reason=length 不完整")
check(LLMResponse.incompleteReason([:], wire: .chatCompletions) != nil, "chat 缺 finish_reason 不完整")
check(LLMResponse.incompleteReason(["stop_reason": "end_turn"], wire: .anthropicMessages) == nil, "Anthropic end_turn 完整")
check(LLMResponse.incompleteReason(["stop_reason": "stop_sequence"], wire: .anthropicMessages) == nil,
      "Anthropic stop_sequence 完整")
check(LLMResponse.incompleteReason(["stop_reason": "max_tokens"], wire: .anthropicMessages) != nil,
      "Anthropic max_tokens 不完整")
check(LLMResponse.incompleteReason(["status": "completed"], wire: .responses) == nil, "Responses completed 完整")
check(LLMResponse.incompleteReason(["status": "incomplete"], wire: .responses) != nil, "Responses incomplete 不完整")

// Brain 审查 L4：接口错误只显示说明，遮掉 Key 和长串标识
let echoed = Data(#"{"error":{"message":"Incorrect API key provided: sk-abc1*****wxyz. req_0123456789abcdefghij"}}"#.utf8)
let echoedSummary = LLMResponse.errorSummary(echoed, apiKey: "sk-abc1secretwxyz")
check(echoedSummary.contains("Incorrect API key") && !echoedSummary.contains("sk-abc1")
      && !echoedSummary.contains("0123456789abcdefghij"), "错误说明保留，回显的部分 Key 和长串标识被遮掉")
let fullKeyEcho = Data(#"{"message":"bad key sk-live-SECRET"}"#.utf8)
check(!LLMResponse.errorSummary(fullKeyEcho, apiKey: "sk-live-SECRET").contains("SECRET"), "回显的完整 Key 被遮掉")
check(LLMResponse.errorSummary(Data(#"{"error":"rate limited"}"#.utf8), apiKey: "k") == "rate limited", "error 是字符串时照常显示")
check(LLMResponse.errorSummary(Data("<html>502 Bad Gateway</html>".utf8), apiKey: "k") == "", "不是 JSON 的正文不显示")
let longMessage = Data("{\"error\":{\"message\":\"\(String(repeating: "慢 ", count: 300))\"}}".utf8)
check(LLMResponse.errorSummary(longMessage, apiKey: "k").count <= 200, "错误说明最多 200 字")

// Brain 审查 L5：请求总时长上限
check(AIRequestPolicy.totalTimeoutSeconds == 45 && AIRequestPolicy.totalTimeoutSeconds < AISafety.holdIdleTimeout,
      "单次请求总时长 45 秒，短于在场时限")

if failures > 0 {
    print("\(failures) 项检查失败")
    exit(1)
}
print("全部检查通过")
