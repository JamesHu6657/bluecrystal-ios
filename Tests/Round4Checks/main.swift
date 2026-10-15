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

if r4Failures > 0 {
    print("Round4Checks: \(r4Failures) FAIL")
    exit(1)
}
print("Round4Checks: all passed")
