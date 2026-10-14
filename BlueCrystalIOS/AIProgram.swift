import Foundation

// 纯逻辑（只依赖 Foundation + BCProtocol）：指令解析、回复授权、本地停止词、接口完整性检查。
// CI 的 ProtocolChecks 直接编译本文件做单元检查。

enum WireProtocol {
    case chatCompletions // OpenAI /chat/completions
    case anthropicMessages // Anthropic /messages
    case responses // OpenAI /responses
}

// MARK: - 指令格式：[CH c0 c1 c2 c3] / [HOLD 毫秒] / [STOP]（提示词里约定，控制器解析）

/// 一步：设置强度（nil = 不改强度，只等待）+ 持续秒数
struct AIStep: Equatable {
    var levels: [Int]?
    var duration: Double

    var isZero: Bool { levels?.allSatisfy { $0 <= 0 } ?? false }

    var summary: String {
        guard let lv = levels else { return "保持 \(Self.fmt(duration)) 秒" }
        return "伸缩 \(lv[0]) · 震动 \(lv[1]) · 吮吸 \(lv[2])" + (duration > 0 ? " · \(Self.fmt(duration)) 秒" : "")
    }

    static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
    }
}

/// 模型回复解析后的结果
///
/// 解析规则（宁可不执行，也不猜）：
/// - 指令必须单独占一行（前后只允许空白），且不在 ``` / ~~~ 代码块里。
///   代码块按 CommonMark 围栏判断：记住开头的字符和长度，只有同一种字符、长度不短于开头、
///   后面只剩空白的行才闭合；没闭合就算到回复结尾。围栏长度按 Unicode 标量数（和 CommonMark 一致）。
///   围栏样式含糊（缩进 4 格以上/制表符、引用或列表里的围栏、行内 ```、` / ~ 后紧跟组合符号）
///   或出现 <pre / <code / <textarea / <script / <style / <template / <!--（HTML 可能把指令藏起来）时，只要有指令就整条作废。
/// - 代码块外的指令行只允许 0~3 个空格缩进；制表符或 4 格以上可能是缩进代码块，整条作废。
/// - 参数个数精确：CH 恰好 4 个非负十进制整数，HOLD 恰好 1 个正十进制整数，STOP 没有参数。
///   不接受小数、负号、科学计数法、逗号分隔，不补齐、不跳过坏参数、不挪通道。
/// - 只要出现任何不算数的指令样式文字（行内、引用、代码块里、格式错、STOP 之后还有指令），
///   或步数超过 maxSteps，整条回复的程序都作废：只显示文字，一步都不执行
///   （调用方此时如果在输出，要安全停止）。
/// - 合法时 c3（旋转）恒为 0，强度夹到 0~BCProtocol.maxManualLevel，HOLD 夹到 500~60000 毫秒。
struct AIReply {
    /// 去掉合法指令行之后给用户看的文字
    var text: String
    /// 本条回复里的强度序列；最后一步的强度会一直保持到下一条回复（或安全上限）
    var steps: [AIStep]
    var stop: Bool
    /// 非 nil：程序作废的原因，steps 为空、stop 为 false
    var rejection: String?

    static let maxSteps = 40
    static let minHoldMs = 500
    static let maxHoldMs = 60_000
    /// 两条 [CH] 之间没写 [HOLD] 时的默认间隔
    static let defaultGap: Double = 1.5

    private enum Command: Equatable {
        case ch([Int])
        case hold(Int)
        case stop
    }

    /// 任何看起来像指令的文字："[" 后接 CH/HOLD/STOP 且后面不是字母（[CH30 …] 也算，[CHANGE] 不算）
    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"\[\s*(?:CH|HOLD|STOP)(?![A-Za-z])"#, options: [.caseInsensitive])

    private static func containsCommandToken(_ s: String) -> Bool {
        guard let re = tokenRegex else { return s.contains("[") }
        return re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func isDecimal(_ s: Substring) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// 单独一行的指令；格式不对返回 nil
    private static func parseCommandLine(_ line: String) -> Command? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 else { return nil }
        let inner = line.dropFirst().dropLast()
        guard !inner.contains("["), !inner.contains("]") else { return nil }
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
        guard let head = tokens.first else { return nil }
        let args = tokens.dropFirst()
        switch head.uppercased() {
        case "CH":
            guard args.count == 4, args.allSatisfy(isDecimal) else { return nil }
            var lv: [Int] = []
            for a in args {
                guard let v = Int(a) else { return nil }
                lv.append(min(v, BCProtocol.maxManualLevel))
            }
            // 第 4 通道（旋转）这台设备不用，恒 0
            lv[3] = 0
            return .ch(lv)
        case "HOLD":
            guard args.count == 1, let a = args.first, isDecimal(a),
                  let ms = Int(a), ms > 0 else { return nil }
            return .hold(max(minHoldMs, min(maxHoldMs, ms)))
        case "STOP":
            return args.isEmpty ? .stop : nil
        default:
            return nil
        }
    }

    private struct Fence {
        var char: Unicode.Scalar
        var count: Int
    }

    /// 去掉行首空白后以 3 个以上 ` 或 ~ 开头：返回围栏字符、长度和后面剩下的部分。
    /// 按标量数：Character 会把紧跟的组合符号并进最后一个 `，少数一个
    private static func fenceRun(_ body: Substring) -> (fence: Fence, rest: Substring)? {
        let scalars = body.unicodeScalars
        guard let c = scalars.first, c == "`" || c == "~" else { return nil }
        let n = scalars.prefix(while: { $0 == c }).count
        guard n >= 3 else { return nil }
        return (Fence(char: c, count: n), Substring(scalars.dropFirst(n)))
    }

    /// 渲染时可能藏住指令、但这里不解析的写法：<pre、<code、<textarea、<script、<style、<template、<!--
    /// （不分大小写；后几个是 CommonMark 的原样文本块，里面的内容不会显示成正文），
    /// 或 ` / ~ 后紧跟组合符号（U+0300~U+036F，各家渲染器对围栏的判断可能不同）
    private static func hasHidingMarkup(_ line: Substring) -> Bool {
        let lower = line.lowercased()
        for tag in ["<pre", "<code", "<textarea", "<script", "<style", "<template", "<!--"] where lower.contains(tag) {
            return true
        }
        var prev: Unicode.Scalar?
        for u in line.unicodeScalars {
            if let p = prev, p == "`" || p == "~", (0x300...0x36F).contains(u.value) { return true }
            prev = u
        }
        return false
    }

    /// 行内任何位置有连续 3 个以上 ` 或 ~（按标量数）
    private static func hasFenceLikeRun(_ line: Substring) -> Bool {
        var prev: Unicode.Scalar?
        var run = 0
        for u in line.unicodeScalars {
            run = (u == "`" || u == "~") ? (u == prev ? run + 1 : 1) : 0
            if run >= 3 { return true }
            prev = u
        }
        return false
    }

    static func parse(_ raw: String) -> AIReply {
        var commands: [Command] = []
        var textLines: [String] = []
        var rejection: String?
        // 当前所在代码块的开头围栏；没闭合就一直算在代码块里，直到回复结束
        var fence: Fence?
        // 出现了无法和 Markdown 渲染结果对齐的写法（缩进 4 格/制表符、引用或列表里的围栏、行内 ```、
        // 代码块外 HTML 的 <pre / <code / <textarea / <script / <style / <template / <!--、围栏字符后的组合符号）
        var markupAmbiguous = false

        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let hasToken = containsCommandToken(line)
            let indent = rawLine.prefix(while: { $0.isWhitespace })
            let plainIndent = indent.count <= 3 && indent.allSatisfy { $0 == " " }
            let run = fenceRun(rawLine.dropFirst(indent.count))

            // 代码块里的内容本来就不执行（有指令直接作废），HTML 写法只在代码块外判断
            if let open = fence {
                // CommonMark 闭合围栏：同一种字符、长度不短于开头、后面只有空格/制表符
                if let r = run, r.fence.char == open.char, r.fence.count >= open.count,
                   r.rest.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    if plainIndent { fence = nil } else { markupAmbiguous = true }
                    textLines.append(line)
                    continue
                }
                if hasToken, rejection == nil { rejection = "代码块里出现了指令" }
                if !line.isEmpty { textLines.append(line) }
                continue
            }
            // 反引号围栏的信息串里不能再有反引号（否则是行内代码，不是代码块）
            if let r = run, r.fence.char == "~" || !r.rest.unicodeScalars.contains("`") {
                if !plainIndent { markupAmbiguous = true }
                fence = r.fence
                if hasToken, rejection == nil { rejection = "代码块里出现了指令" }
                textLines.append(line)
                continue
            }
            if hasFenceLikeRun(rawLine) || hasHidingMarkup(rawLine) { markupAmbiguous = true }
            // 制表符或 4 格以上缩进的行可能在缩进代码块里（渲染成代码，不是指令）
            if hasToken, !plainIndent, rejection == nil {
                rejection = "指令有缩进（制表符或 4 格以上），可能在代码块里：\(line)"
            }
            if hasToken, line.hasPrefix("[") {
                if let c = parseCommandLine(line) {
                    if commands.last == .stop, rejection == nil {
                        rejection = "[STOP] 之后还有指令"
                    }
                    commands.append(c)
                    continue
                }
                if rejection == nil { rejection = "指令格式不对：\(line)" }
            } else if hasToken, rejection == nil {
                rejection = "指令没有单独占一行：\(line)"
            }
            if !line.isEmpty { textLines.append(line) }
        }
        // 写法含糊时无法确定指令在渲染后是不是代码/被隐藏：只要有指令就整条作废
        if rejection == nil, markupAmbiguous, !commands.isEmpty {
            rejection = "代码块或 HTML 格式不明确，无法确认指令是否在代码块里或被隐藏"
        }
        let text = textLines.joined(separator: "\n")

        var steps: [AIStep] = []
        var stop = false
        var lastHeld = false // 最后一步后面是否已经跟了 HOLD
        for c in commands {
            switch c {
            case .ch(let lv):
                steps.append(AIStep(levels: lv, duration: defaultGap))
                lastHeld = false
            case .hold(let ms):
                let sec = Double(ms) / 1000
                if let i = steps.indices.last, steps[i].levels != nil, !lastHeld {
                    steps[i].duration = sec
                } else {
                    steps.append(AIStep(levels: nil, duration: sec))
                }
                lastHeld = true
            case .stop:
                stop = true
            }
        }
        // 整条程序算完再比步数：超了就整条作废，绝不执行前缀、也不丢掉末尾的 [STOP] / 全零
        if rejection == nil, steps.count > maxSteps {
            rejection = "指令共 \(steps.count) 步，超过上限 \(maxSteps) 步"
        }
        if let r = rejection {
            return AIReply(text: text, steps: [], stop: false, rejection: r)
        }
        // 最后一步保持到下一条回复：持续时间置 0，表示"不再推进"
        if !stop, let i = steps.indices.last, !lastHeld { steps[i].duration = 0 }
        return AIReply(text: text, steps: steps, stop: stop, rejection: nil)
    }
}

// MARK: - 回复授权

/// 回复授权的生命周期（纯状态，只在主线程用）：
/// - 发消息时 issue() 领一张票（停止词那句在本地停止之前领，所以它的回复也会被作废）；
/// - 任何真正的停止都 revoke()：用户停止、本地停止词、程序以 [STOP] / 全零自动结束、被动停机
///   （看门狗/上限/冷却/输出被拒）、退后台、连接离开 ready、离开 AI 页面。之前领的票全部失效；
/// - 执行前在主线程用 block(_:) 验票：票失效的回复只显示文字，绝不启动设备。
struct ReplyAuthorization {
    struct Ticket: Equatable {
        fileprivate let generation: Int
    }

    private var generation = 0

    func issue() -> Ticket { Ticket(generation: generation) }

    mutating func revoke() { generation &+= 1 }

    /// nil 表示授权仍有效
    func block(_ ticket: Ticket) -> String? {
        ticket.generation == generation ? nil : "发送后已停止或连接/页面状态变化"
    }

    /// 序列走完时是否算真正停止（带 [STOP]，或最后一个强度步是全零）：是就要走停止并 revoke()；
    /// 否则保持最后的强度，等下一条回复，授权不变
    static func programEndIsTerminal(steps: [AIStep], endWithStop: Bool) -> Bool {
        endWithStop || steps.last(where: { $0.levels != nil })?.isZero == true
    }
}

// MARK: - 本地停止词

/// 本地停止词（不等模型，立刻停）。匹配策略刻意保守，宁可误停：
/// - 中文安全短语在消息任意位置出现就算（"我疼，停止"、"别停"、"心疼" 都会停）；
/// - 英文 "stop" 作为独立单词出现就算，不分大小写（"please stop"、"STOP!"、"don't stop" 都会停；
///   "stopped"、"nonstop" 不算）。全角字母先转半角。
/// - "慢"（慢一点）不是停止词，交给模型降档；"慢点停" 含 "停"，仍然本地停。
enum AIStopWords {
    static let phrases = ["停", "停下", "停止", "停一下", "慢点停", "别动了", "别弄了", "够了", "不要了",
                          "疼", "痛", "受不了", "住手"]
    static let englishWords: Set<String> = ["stop"]

    static func matches(_ text: String) -> Bool {
        let normalized = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).lowercased()
        if phrases.contains(where: { normalized.contains($0) }) { return true }
        let words = normalized.split(whereSeparator: { (c: Character) -> Bool in !(c >= "a" && c <= "z") })
        return words.contains { englishWords.contains(String($0)) }
    }
}

// MARK: - 接口回复：取文字 + 完整性检查

enum LLMResponse {
    static func extractText(_ obj: [String: Any], wire: WireProtocol) -> String? {
        switch wire {
        case .chatCompletions:
            let choices = obj["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            return msg?["content"] as? String
        case .anthropicMessages:
            let blocks = obj["content"] as? [[String: Any]] ?? []
            return blocks.filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.joined()
        case .responses:
            if let t = obj["output_text"] as? String, !t.isEmpty { return t }
            let output = obj["output"] as? [[String: Any]] ?? []
            return output.filter { ($0["type"] as? String) == "message" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .filter { ($0["type"] as? String) == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
        }
    }

    /// 回复没有正常结束时返回说明；nil 表示完整。缺字段也按不完整处理
    static func incompleteReason(_ obj: [String: Any], wire: WireProtocol) -> String? {
        switch wire {
        case .chatCompletions:
            let choices = obj["choices"] as? [[String: Any]]
            let reason = choices?.first?["finish_reason"] as? String
            return reason == "stop" ? nil : "回复没有正常结束（finish_reason=\(reason ?? "缺失")）"
        case .anthropicMessages:
            let reason = obj["stop_reason"] as? String
            return reason == "end_turn" || reason == "stop_sequence"
                ? nil : "回复没有正常结束（stop_reason=\(reason ?? "缺失")）"
        case .responses:
            let status = obj["status"] as? String
            return status == "completed" ? nil : "回复没有正常结束（status=\(status ?? "缺失")）"
        }
    }
}
