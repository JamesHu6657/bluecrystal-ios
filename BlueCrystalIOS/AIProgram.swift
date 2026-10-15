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
/// - 第四轮 M2：去掉格式类字符（零宽空格等）、做 NFKC、把中文括号当成方括号之后才像指令的文字
///   （［STOP］、【STOP】、[ＳＴＯＰ]、[ST​OP]）也算格式错，整条作废。之前它们被当成普通文字放过，
///   模型想停却继续保持最后的强度。
/// - CH 任何一个值超过 BCProtocol.maxManualLevel（99）都算格式错，整条作废（不夹紧）。
/// - 合法时 c3（旋转）恒为 0，HOLD 夹到 500~60000 毫秒。
///   AI 强度上限 70、每秒每通道最多 +20、从 0 爬升、总时长上限由执行前的 AISafety 处理。
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

    /// 第四轮 M2：常见的中文 / 数学括号，只在"像不像指令"的判断里当成方括号（全角 ［］ NFKC 本来就会折叠，这里一并列上）
    private static let bracketLookalikes: [Character: Character] = [
        "【": "[", "】": "]", "〔": "[", "〕": "]", "〖": "[", "〗": "]",
        "〘": "[", "〙": "]", "〚": "[", "〛": "]", "⟦": "[", "⟧": "]", "［": "[", "］": "]",
    ]

    /// 第四轮 M2：只用来判断"像不像指令"（绝不用来解析执行）。
    /// 去掉格式类字符（Cf：零宽空格、零宽连接符、BOM、方向控制符…），做 NFKC（全角字母 / 括号 → 半角），
    /// 再把中文括号换成方括号
    static func detectionForm(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: s.unicodeScalars.filter { $0.properties.generalCategory != .format })
        let folded = String(scalars).precomposedStringWithCompatibilityMapping
        return String(folded.map { bracketLookalikes[$0] ?? $0 })
    }

    /// 第四轮 M2：原文不算指令、归一化之后却像指令（［STOP］、【STOP】、[ＳＴＯＰ]、[ST​OP]）：写法不标准
    static func looksLikeNonstandardCommand(_ s: String) -> Bool {
        !containsCommandToken(s) && containsCommandToken(detectionForm(s))
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
                guard let v = Int(a), v <= BCProtocol.maxManualLevel else { return nil }
                lv.append(v)
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

    /// 格式对、只是强度超过 99 的 CH（只用来给出更明确的作废原因）
    private static func chOverLimit(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 2 else { return false }
        let tokens = line.dropFirst().dropLast()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{3000}" })
        guard tokens.count == 5, tokens[0].uppercased() == "CH" else { return false }
        let args = tokens.dropFirst()
        return args.allSatisfy(isDecimal) && args.contains { (Int($0) ?? Int.max) > BCProtocol.maxManualLevel }
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
            // 第四轮 M2：写法不标准的"指令"（全角 / 中文括号、全角字母、夹了零宽字符）不再当普通文字放过：
            // 模型很可能就是想停，按格式错整条作废，调用方在输出中会安全停止
            if !hasToken, rejection == nil, looksLikeNonstandardCommand(line) {
                rejection = "指令写法不标准（全角括号、全角字母或隐藏字符），整条不执行：\(line)"
            }
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
                if rejection == nil {
                    rejection = chOverLimit(line)
                        ? "强度超过 \(BCProtocol.maxManualLevel)，整条不执行：\(line)"
                        : "指令格式不对：\(line)"
                }
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
///   （看门狗/上限/输出被拒）、退后台、连接离开 ready、离开 AI 页面。之前领的票全部失效；
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

// MARK: - AI 输出安全（在代码里执行，不靠提示词：提示词用户可以改）

/// 模型给的强度在执行前统一经过这里：
/// - 每通道上限 maxLevel（70）：超过的值压到 70，界面上的程序说明会标出来；
///   超过 99 的值在 AIReply.parse 里已经整条作废，到不了这里。
/// - 相邻两步之间每通道最多升高 maxStepIncrease（20）：升得更多时，在目标步前面插入
///   rampStepSeconds（1 秒）一步的爬升步，每步 +20，直到差距不超过 20 再到目标步。
/// - 时间限速（M2）：任意两次升高之间至少隔 rampStepSeconds（1 秒），所以真的是"每秒每通道最多 +20"。
///   不够 1 秒就先插一步等待；等待步里降低的通道立即生效（降强度是安全方向，用户喊"慢"时不能拖）。
///   跨回复也算：调用方传入距上次升高过了多久（从空闲开始传 .infinity）。
/// - 起点：从空闲开始的程序从 0 算起（所以第一步也是每秒最多 +20 爬上去）；
///   接着上一条回复保持的强度继续时，从保持的强度算起。
/// - BLEManager 发出前还会按实际发出的上一帧再限一次升幅（M1，见 OutputWriteCoalescer）。
enum AISafety {
    static let maxLevel = 70
    static let maxStepIncrease = 20
    static let rampStepSeconds: Double = 1
    /// 在场时限（H1）：运行中（执行程序或保持最后强度）离最近一条用户消息这么久就停止
    /// （不在场的人不能被一直保持输出）
    static let holdIdleTimeout: TimeInterval = 120
    /// 单条程序（含插入的爬升/等待步）总时长上限（H1）：超过的回复整条不执行
    static let maxProgramSeconds: TimeInterval = holdIdleTimeout

    struct Program: Equatable {
        /// 实际执行的步骤（含插入的爬升步、等待步）
        var steps: [AIStep]
        /// 压到上限后的原步骤，给界面显示
        var displaySteps: [AIStep]
        /// 被压到上限的通道值个数
        var clampedValues: Int
        /// 插入的爬升步数
        var rampSteps: Int
        /// 为了"两次升高至少隔 1 秒"插入的等待步数（M2）
        var waitSteps: Int

        /// 实际执行的总时长（最后一步保持的 0 秒不算）
        var totalSeconds: Double { steps.reduce(0) { $0 + $1.duration } }
    }

    static func enforce(_ steps: [AIStep], from start: [Int],
                        secondsSinceRise: TimeInterval = .infinity) -> Program {
        var cur = (0..<4).map { i in i < start.count ? max(0, min(maxLevel, start[i])) : 0 }
        // 距上一次升高（那一步开始的时刻）过了多久
        var sinceRise = secondsSinceRise
        var out: [AIStep] = []
        var display: [AIStep] = []
        var clamped = 0
        var ramps = 0
        var waits = 0
        for s in steps {
            guard let lv = s.levels else {
                out.append(s)
                display.append(s)
                sinceRise += s.duration
                continue
            }
            var target = (0..<4).map { i in i < lv.count ? max(0, lv[i]) : 0 }
            for i in target.indices where target[i] > maxLevel {
                target[i] = maxLevel
                clamped += 1
            }
            let shaped = AIStep(levels: target, duration: s.duration)
            display.append(shaped)
            while true {
                var next = target
                var needsRamp = false
                for i in next.indices where next[i] - cur[i] > maxStepIncrease {
                    next[i] = cur[i] + maxStepIncrease
                    needsRamp = true
                }
                // 下一次要发的强度有升高、离上次升高还不到 1 秒：先等，降低的通道在等待步里立即生效
                if next.indices.contains(where: { next[$0] > cur[$0] }), sinceRise < rampStepSeconds {
                    let lowered = cur.indices.map { min(cur[$0], next[$0]) }
                    out.append(AIStep(levels: lowered == cur ? nil : lowered, duration: rampStepSeconds - sinceRise))
                    waits += 1
                    cur = lowered
                    sinceRise = rampStepSeconds
                }
                guard needsRamp else { break }
                out.append(AIStep(levels: next, duration: rampStepSeconds))
                ramps += 1
                cur = next
                sinceRise = rampStepSeconds
            }
            let rises = target.indices.contains { target[$0] > cur[$0] }
            out.append(shaped)
            sinceRise = rises ? s.duration : sinceRise + s.duration
            cur = target
        }
        return Program(steps: out, displaySteps: display, clampedValues: clamped, rampSteps: ramps, waitSteps: waits)
    }

    /// 程序总时长超过上限时返回作废原因（H1）
    static func programTooLong(_ p: Program) -> String? {
        guard p.totalSeconds > maxProgramSeconds else { return nil }
        return "程序总时长 \(Int(p.totalSeconds.rounded(.up))) 秒，超过上限 \(Int(maxProgramSeconds)) 秒，整条不执行"
    }

    /// 界面上的程序说明：显示压到上限后的强度，并注明压低、爬升和等待
    static func describe(_ p: Program, stop: Bool) -> String {
        var text = p.displaySteps.map(\.summary).joined(separator: " → ") + (stop ? " → 停止" : "")
        if p.clampedValues > 0 {
            text += "\n（AI 强度上限 \(maxLevel)：\(p.clampedValues) 个超过 \(maxLevel) 的值已压到 \(maxLevel)）"
        }
        if p.rampSteps > 0 {
            text += "\n（自动插入 \(p.rampSteps) 步爬升，每秒每通道最多 +\(maxStepIncrease)）"
        }
        if p.waitSteps > 0 {
            text += "\n（自动插入 \(p.waitSteps) 步等待：两次升高至少间隔 \(AIStep.fmt(rampStepSeconds)) 秒）"
        }
        return text
    }

    /// 保持中是否已经超过空闲时限；holdStartedAt 为 nil 表示没在保持
    static func holdIdleExpired(now: TimeInterval, holdStartedAt: TimeInterval?,
                                lastUserMessageAt: TimeInterval?) -> Bool {
        guard let h = holdStartedAt else { return false }
        return now - max(h, lastUserMessageAt ?? h) >= holdIdleTimeout
    }

    /// 在场超时（H1）：运行中不论在执行程序还是保持，离最近一条用户消息 holdIdleTimeout 就停止。
    /// 没有用户消息记录时从开始运行算；两个都没有表示没在运行
    static func presenceExpired(now: TimeInterval, lastUserMessageAt: TimeInterval?,
                                runStartedAt: TimeInterval?) -> Bool {
        guard let ref = lastUserMessageAt ?? runStartedAt else { return false }
        return now - ref >= holdIdleTimeout
    }
}

// MARK: - 请求历史

/// 每次请求带的历史：出错提示不进历史；窗口从用户消息开始（严格的接口不接受 assistant 开头）；
/// 去掉出错提示后相邻同角色的消息合并成一条，保持 user/assistant 交替
enum AIHistory {
    struct Turn {
        var isUser: Bool
        var isError: Bool
        var content: String
    }

    /// 一条消息回传给模型的内容（L6）：执行过的回复回传原文（含指令）；没执行的回传显示文字；
    /// 显示文字为空时用"…"，绝不把"未执行：…"这类本地说明当成模型自己说过的话
    static func content(raw: String?, text: String) -> String {
        if let r = raw { return r }
        return text.isEmpty ? "…" : text
    }

    static func window(_ turns: [Turn], limit: Int) -> [[String: String]] {
        var recent = Array(turns.filter { !$0.isError }.suffix(limit))
        while let first = recent.first, !first.isUser { recent.removeFirst() }
        var out: [[String: String]] = []
        for t in recent {
            let role = t.isUser ? "user" : "assistant"
            if let last = out.last, last["role"] == role {
                out[out.count - 1]["content"] = (last["content"] ?? "") + "\n" + t.content
            } else {
                out.append(["role": role, "content": t.content])
            }
        }
        return out
    }
}

// MARK: - 本地停止词

/// 本地停止词（不等模型，立刻停）。匹配策略刻意保守，宁可误停：
/// - 中文安全短语在消息任意位置出现就算（"我疼，停止"、"别停"、"心疼" 都会停）；
///   第三轮 M3：补上常见的拒绝 / 求救说法（不要、不行、难受、救命、关掉、结束）和繁体写法，
///   之前"不要！""不行了""好难受""救命""夠了"都要等模型自己理解。"要不要再快点"这类也会停（宁可误停）；
/// - 英文 stop / pause / wait / enough / no / ouch / hurt / hurts / pain 作为独立单词出现就算，不分大小写
///   （"please stop"、"STOP!"、"don't stop"、"wait a sec"、"oh no" 都会停；
///   "stopped"、"nonstop"、"waiting"、"nothing"、"painful" 不算）。全角字母先转半角。
/// - "慢"（慢一点）不是停止词，交给模型降档；"慢点停" 含 "停"，仍然本地停。
enum AIStopWords {
    static let phrases = ["停", "停下", "停止", "停一下", "慢点停", "暂停", "别动了", "别弄了", "够了", "不要了",
                          "疼", "疼死", "痛", "受不了", "住手", "等等",
                          // 第三轮 M3：拒绝 / 求救说法和繁体写法
                          "不要", "不行", "难受", "救命", "关掉", "结束",
                          "夠了", "別動了", "別弄了", "難受", "關掉", "結束"]
    static let englishWords: Set<String> = ["stop", "pause", "wait", "enough", "no", "ouch", "hurt", "hurts", "pain"]

    static func matches(_ text: String) -> Bool {
        let normalized = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).lowercased()
        if phrases.contains(where: { normalized.contains($0) }) { return true }
        let words = normalized.split(whereSeparator: { (c: Character) -> Bool in !(c >= "a" && c <= "z") })
        return words.contains { englishWords.contains(String($0)) }
    }
}

// MARK: - 请求时限

enum AIRequestPolicy {
    /// 单次请求总时长上限（L5）：URLRequest.timeoutInterval 只是两次收到数据之间的空闲超时，
    /// 慢慢滴流的响应可以一直挂着。到点按请求错误处理（运行中就停止）
    static let totalTimeoutSeconds: TimeInterval = 45
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

    /// 接口出错时给界面看的摘要（L4）：只取 JSON 里的 error.message / error / message，
    /// 遮掉 Key、疑似 Key 的片段和 20 位以上的长串标识，最多 200 字；不是 JSON 的正文（HTML 错误页等）不显示
    static func errorSummary(_ data: Data, apiKey: String) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        var text: String
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String {
            text = m
        } else if let m = obj["error"] as? String {
            text = m
        } else if let m = obj["message"] as? String {
            text = m
        } else {
            text = ""
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 4 { text = text.replacingOccurrences(of: key, with: "***") }
        for pattern in ["\\b(sk|fw|key)[-_][A-Za-z0-9*_\\-]{2,}", "[A-Za-z0-9_\\-]{20,}"] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                               withTemplate: "***")
        }
        return String(text.prefix(200))
    }
}
