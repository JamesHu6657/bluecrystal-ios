import Foundation

// 纯逻辑（只依赖 Foundation + BCProtocol）：指令解析、本地停止词、接口完整性检查。
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

    static func parse(_ raw: String) -> AIReply {
        var commands: [Command] = []
        var textLines: [String] = []
        var rejection: String?
        var inFence = false

        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                textLines.append(line)
                continue
            }
            let hasToken = containsCommandToken(line)
            if !inFence, hasToken, line.hasPrefix("[") {
                if let c = parseCommandLine(line) {
                    if commands.last == .stop, rejection == nil {
                        rejection = "[STOP] 之后还有指令"
                    }
                    commands.append(c)
                    continue
                }
                if rejection == nil { rejection = "指令格式不对：\(line)" }
            } else if hasToken, rejection == nil {
                rejection = inFence
                    ? "代码块里出现了指令"
                    : "指令没有单独占一行：\(line)"
            }
            if !line.isEmpty { textLines.append(line) }
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
