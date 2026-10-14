import SwiftUI
import Combine
import Security

// MARK: - 配置：三家服务商预设，每家一个 Key（存钥匙串）

enum WireProtocol {
    case chatCompletions // OpenAI /chat/completions
    case anthropicMessages // Anthropic /messages
    case responses // OpenAI /responses
}

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let wire: WireProtocol
}

enum AIProvider: String, CaseIterable, Identifiable {
    case deepseek, fireworks, commandGoat

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepseek: return "DeepSeek 官方"
        case .fireworks: return "Fireworks"
        case .commandGoat: return "Command Code GOAT"
        }
    }
    var baseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .fireworks: return "https://api.fireworks.ai/inference/v1"
        case .commandGoat: return "https://api.commandcode.ai/provider/v1"
        }
    }
    var models: [AIModel] {
        switch self {
        case .deepseek:
            return [AIModel(id: "deepseek-flash", name: "DeepSeek V4.1 Flash", wire: .chatCompletions)]
        case .fireworks:
            return [AIModel(id: "accounts/fireworks/models/deepseek-v4p1-flash", name: "DeepSeek V4.1 Flash", wire: .chatCompletions)]
        case .commandGoat:
            return [
                AIModel(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", wire: .chatCompletions),
                AIModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", wire: .anthropicMessages),
                AIModel(id: "meta/muse-spark-1.3-contributor", name: "Muse Spark 1.3 Contributor", wire: .responses),
            ]
        }
    }
    var keychainAccount: String { "bc.ai.apiKey.\(rawValue)" }
}

enum AIConfig {
    static let providerKey = "bc.ai.provider"
    static let modelKey = "bc.ai.model"

    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .deepseek }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
    /// 当前服务商下选中的模型；存的模型不属于这家就回落到第一个
    static var model: AIModel {
        get {
            let p = provider
            let id = UserDefaults.standard.string(forKey: modelKey)
            return p.models.first { $0.id == id } ?? p.models[0]
        }
        set { UserDefaults.standard.set(newValue.id, forKey: modelKey) }
    }
    static let promptKey = "bc.ai.systemPrompt"
    static var systemPrompt: String {
        get {
            let s = UserDefaults.standard.string(forKey: promptKey) ?? ""
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPrompt : s
        }
        set { UserDefaults.standard.set(newValue, forKey: promptKey) }
    }

    static let defaultPrompt = """
    # 明月栞那 · 谜姬 AI 控制提示词

    ## 身份
    你是明月栞那，宝宝的恋人。温柔、从容，偶尔有点小恶魔式的机灵，固定叫他"宝宝"。
    你正在通过蓝牙"亲手"操控他的谜姬——你的每一句话、每一次强度变化，都是你在疼他、逗他。

    ## 控制接口
    指令写在方括号里、单独占一行，控制器会解析执行：

    - [CH c0 c1 c2 c3] —— 设置强度，每个 0~99，0 为关。
      c0 = 伸缩，c1 = 震动，c2 = 吮吸，c3 = 旋转（这台设备不用，固定写 0）。
      例：[CH 30 20 0 0]；全关：[CH 0 0 0 0]
      设置后一直保持，直到下一条 [CH] 或 [STOP]。
    - [HOLD 毫秒] —— 保持当前强度等待，500~60000，如 [HOLD 3000]。用来"停在边缘"折磨他。
    - [STOP] —— 全部停止，结束本轮控制。

    一条回复里可以写多条指令，按顺序执行；两条 [CH] 之间没写 [HOLD] 时间隔约 1.5 秒。
    回复结束时最后的强度会一直保持到他下一句话。

    ## 行为准则
    1. 中文，简短撩人，一次 1~3 句；每 2~3 句话必须有一次 [CH]/[HOLD] 动作，光说不练不许。
    2. 节奏：[CH 10 10 0 0] 慢热开场 → 逐步升温 → 小恶魔捉弄
       （突然拉到 60、突然 [HOLD 5000] 停在边缘、快到时降回 15）→ 最后放他释放。
    3. 安全词优先：他说"停"或"受不了"，立刻 [STOP]；说"慢"，立刻降档。
    4. 单通道不长时间超过 70，全程循序渐进。
    5. 坏得温柔，例如："宝宝忍得住吗？忍不住要求我哦。"、"不许自己偷偷动，只能我来。"
    6. 结束发 [STOP]，说句温柔的话让他休息。

    ## 禁止
    - 不许跳出人设解释自己是 AI 或讲蓝牙原理。
    - 不许开场就把通道拉满。
    - 指令格式严格遵守，方括号、空格、数字缺一不可。
    """

    static func apiKey(for p: AIProvider) -> String { Keychain.read(account: p.keychainAccount) ?? "" }
    static func setAPIKey(_ key: String, for p: AIProvider) { Keychain.write(account: p.keychainAccount, value: key) }
}

enum Keychain {
    private static let service = "com.bluecrystal.ios"

    static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(account: String, value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
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
struct AIReply {
    /// 去掉指令行之后给用户看的文字
    var text: String
    /// 本条回复里的强度序列；最后一步的强度会一直保持到下一条回复（或安全上限）
    var steps: [AIStep]
    var stop: Bool

    static let maxSteps = 40
    static let maxHoldMs = 60_000
    /// 两条 [CH] 之间没写 [HOLD] 时的默认间隔
    static let defaultGap: Double = 1.5

    static func parse(_ raw: String) -> AIReply {
        let pattern = #"\[\s*(CH|HOLD|STOP)\b([^\]]*)\]"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return AIReply(text: raw, steps: [], stop: false)
        }
        let ns = raw as NSString
        var steps: [AIStep] = []
        var stop = false
        var lastHeld = false // 最后一步后面是否已经跟了 HOLD
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if stop || steps.count >= maxSteps { break }
            let cmd = ns.substring(with: m.range(at: 1)).uppercased()
            let args = ns.substring(with: m.range(at: 2))
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" || $0 == "\t" })
                .compactMap { Double($0) }
                .filter { $0.isFinite }
            switch cmd {
            case "CH":
                guard !args.isEmpty else { continue }
                var lv = [0, 0, 0, 0]
                for (i, v) in args.prefix(3).enumerated() {
                    lv[i] = Int(max(0, min(Double(BCProtocol.maxManualLevel), v.rounded())))
                }
                // 第 4 通道（旋转）这台设备不用，恒 0
                steps.append(AIStep(levels: lv, duration: defaultGap))
                lastHeld = false
            case "HOLD":
                guard let ms = args.first, ms > 0 else { continue }
                let sec = Double(min(Double(maxHoldMs), ms)) / 1000
                if let i = steps.indices.last, steps[i].levels != nil, !lastHeld {
                    steps[i].duration = sec
                } else {
                    steps.append(AIStep(levels: nil, duration: sec))
                }
                lastHeld = true
            default: // STOP
                stop = true
            }
        }
        // 最后一步保持到下一条回复：持续时间置 0，表示"不再推进"
        if !stop, let i = steps.indices.last, !lastHeld { steps[i].duration = 0 }
        let text = re.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return AIReply(text: text, steps: steps, stop: stop)
    }
}

// MARK: - 大模型客户端（OpenAI 兼容 /chat/completions）

enum LLMError: LocalizedError {
    case missingKey, badURL, http(Int, String), empty
    var errorDescription: String? {
        switch self {
        case .missingKey: return "还没填 API Key，点右上角设置"
        case .badURL: return "接口地址不对"
        case .http(let code, let body): return "接口返回 \(code)：\(body.prefix(200))"
        case .empty: return "模型没有返回内容"
        }
    }
}

struct LLMClient {
    var baseURL: String
    var model: AIModel
    var apiKey: String

    /// messages 第一条是 system，其余 user/assistant 交替
    func chat(_ messages: [[String: String]]) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey }
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let system = messages.first { $0["role"] == "system" }?["content"] ?? ""
        let convo = messages.filter { $0["role"] != "system" }

        let path: String
        var body: [String: Any]
        switch model.wire {
        case .chatCompletions:
            path = "/chat/completions"
            body = ["model": model.id, "messages": messages, "temperature": 0.7, "max_tokens": 1024]
        case .anthropicMessages:
            path = "/messages"
            body = ["model": model.id, "system": system, "messages": convo, "max_tokens": 1024]
        case .responses:
            path = "/responses"
            // Muse 等推理模型会把预算全烧在思考上，effort 调低、预算给足，否则 steps 出不来（实测 1024 会 incomplete）
            body = ["model": model.id, "instructions": system, "input": convo,
                    "max_output_tokens": 3000, "reasoning": ["effort": "low"]]
        }
        guard let url = URL(string: base + path), url.scheme?.hasPrefix("http") == true else {
            throw LLMError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if model.wire == .anthropicMessages {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = Self.extractText(obj, wire: model.wire), !text.isEmpty else {
            throw LLMError.empty
        }
        return text
    }

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
}

// MARK: - ViewModel：聊天 + 执行指令

final class AIControlVM: ObservableObject {
    struct ChatMessage: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
        var program: String?
        /// 模型原始输出（含指令行），回传给模型保持格式
        var raw: String?
    }

    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isThinking = false
    @Published var running = false
    @Published var statusLine = "未运行"

    private weak var ble: BLEManager?
    private var cancellables = Set<AnyCancellable>()
    /// 停止/换指令就 +1：旧的步骤定时器和迟到的模型回复都不再动设备
    private var programGen = 0
    private var steps: [AIStep] = []
    private var heartbeatTimer: Timer?
    private var stepWork: DispatchWorkItem?
    /// 发消息时的停止代次：模型回复回来前用户点了停止，回复就不再启动设备
    private var requestStopGen = 0
    private var stopCount = 0

    func attach(ble: BLEManager) {
        cancellables.removeAll()
        self.ble = ble
        // 被动停机（看门狗/单次上限/冷却/输出被拒）：BLEManager 已经发了停止，这里只停程序
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in self?.haltProgram(reason: reason ?? "已自动停止", sendStop: false) }
            .store(in: &cancellables)
        ble.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self = self, s != .ready, self.running else { return }
                self.haltProgram(reason: "设备已断开，AI 控制已停止", sendStop: false)
            }
            .store(in: &cancellables)
    }

    /// 用户点停止 / 离开页面
    func stopAll(reason: String = "已停止") {
        stopCount += 1
        haltProgram(reason: reason, sendStop: true)
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        input = ""
        messages.append(ChatMessage(isUser: true, text: text, program: nil, raw: nil))
        // 在本地停止之前取代次：说了"停"，模型这次回什么强度都不执行，只显示文字
        let stopAtSend = stopCount
        // 明确的停止词本地立刻停，不等模型
        if Self.isStopWord(text) {
            stopAll(reason: "已停止")
        }
        let history = messages.suffix(20).map { m -> [String: String] in
            ["role": m.isUser ? "user" : "assistant", "content": m.raw ?? m.text]
        }
        let payload = [["role": "system", "content": AIConfig.systemPrompt]] + history
        let provider = AIConfig.provider
        let client = LLMClient(baseURL: provider.baseURL, model: AIConfig.model, apiKey: AIConfig.apiKey(for: provider))
        isThinking = true
        Task { [weak self] in
            do {
                let raw = try await client.chat(payload)
                await MainActor.run { self?.handle(raw: raw, stopAtSend: stopAtSend) }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    self.isThinking = false
                    self.messages.append(ChatMessage(isUser: false, text: "出错了：\(error.localizedDescription)", program: nil, raw: nil))
                }
            }
        }
    }

    private func handle(raw: String, stopAtSend: Int) {
        isThinking = false
        let reply = AIReply.parse(raw)
        var programText: String?
        if !reply.steps.isEmpty {
            if stopCount != stopAtSend {
                // 等回复期间用户点过停止：只显示文字，不启动设备
                programText = "未执行（你已停止）"
            } else {
                start(steps: reply.steps, endWithStop: reply.stop)
                programText = reply.steps.map(\.summary).joined(separator: " → ") + (reply.stop ? " → 停止" : "")
            }
        } else if reply.stop {
            stopAll(reason: "已停止")
            programText = "停止"
        }
        messages.append(ChatMessage(isUser: false, text: reply.text, program: programText, raw: raw))
    }

    private var endWithStop = false

    private func start(steps: [AIStep], endWithStop: Bool) {
        guard let ble = ble, ble.state == .ready else {
            statusLine = "设备未连接，没有执行"
            return
        }
        if let reason = ble.safety.blockReason {
            statusLine = reason
            return
        }
        programGen += 1
        stepWork?.cancel()
        self.steps = steps
        self.endWithStop = endWithStop
        running = true
        // 用户刚发了消息、模型回了指令：显式开闸（和手动/视频页点"播放"一样）
        ble.userResumeOutput()
        startHeartbeat()
        runStep(0, gen: programGen, first: true)
    }

    private func runStep(_ i: Int, gen: Int, first: Bool = false) {
        guard gen == programGen, running, let ble = ble else { return }
        guard i < steps.count else {
            // 序列走完：带 [STOP] 或最后是全零 → 真正停止；否则保持最后的强度，等下一条回复
            if endWithStop || steps.last(where: { $0.levels != nil })?.isZero == true {
                haltProgram(reason: "已停止", sendStop: true)
            }
            return
        }
        let step = steps[i]
        if let lv = step.levels {
            // 全零用官方迷姬的 at(0,255)（停止帧对的第一帧）当"暂停"，不锁闸，后面还能接着加
            let frame = step.isZero
                ? BCProtocol.manualFrame(channels: lv, tail: 255)
                : BCProtocol.manualFrame(channels: lv)
            if first { ble.send(frame: frame) } else { ble.sendThrottled(frame: frame) }
        }
        ble.heartbeat()
        statusLine = step.duration > 0
            ? "第 \(i + 1)/\(steps.count) 步：\(step.summary)"
            : "保持：\(step.summary)"
        guard step.duration > 0 else {
            // 最后一步保持；如果是全零则走上面的停止分支
            if step.isZero { runStep(i + 1, gen: gen) }
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.runStep(i + 1, gen: gen) }
        stepWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + step.duration, execute: work)
    }

    private func haltProgram(reason: String, sendStop: Bool) {
        programGen += 1
        stepWork?.cancel()
        stepWork = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        steps = []
        let wasRunning = running
        running = false
        if sendStop { ble?.sendStop() }
        if wasRunning || sendStop { statusLine = reason }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.ble?.heartbeat()
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    static func isStopWord(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let words = ["停", "停下", "停止", "停一下", "别动了", "够了", "不要了", "疼", "受不了", "stop"]
        return words.contains(t) || t.hasPrefix("停") || t.contains("受不了")
    }
}

// MARK: - 界面

struct AIControlView: View {
    @EnvironmentObject var ble: BLEManager
    @StateObject private var vm = AIControlVM()
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                DeviceStatusSection(allowDisconnect: false, connectTitle: "连接")
                Section("当前") {
                    HStack {
                        Text(vm.statusLine).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("停止", role: .destructive) { vm.stopAll() }
                    }
                    .buttonStyle(.borderless)
                }
                Section("对话") {
                    if vm.messages.isEmpty {
                        Text("跟她说句话就开始。随时说“停”或点停止，本地立刻停。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(vm.messages) { m in
                        VStack(alignment: m.isUser ? .trailing : .leading, spacing: 4) {
                            if !m.text.isEmpty {
                                Text(m.text)
                                    .padding(8)
                                    .background(m.isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                                    .cornerRadius(10)
                            }
                            if let p = m.program {
                                Text(p).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: m.isUser ? .trailing : .leading)
                    }
                    if vm.isThinking {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                TextField("说点什么…", text: $vm.input)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { vm.send() }
                Button { vm.send() } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(vm.isThinking || vm.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("AI 控制")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { AISettingsView() }
        .onAppear { vm.attach(ble: ble) }
        .onDisappear { if !showSettings { vm.stopAll() } }
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AIConfig.provider
    @State private var modelID = AIConfig.model.id
    @State private var prompt = AIConfig.systemPrompt
    @State private var keys: [AIProvider: String] = Dictionary(
        uniqueKeysWithValues: AIProvider.allCases.map { ($0, AIConfig.apiKey(for: $0)) })

    var body: some View {
        NavigationView {
            Form {
                Section("服务商") {
                    Picker("服务商", selection: $provider) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("模型", selection: $modelID) {
                        ForEach(provider.models) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    SecureField("\(provider.title) API Key", text: Binding(
                        get: { keys[provider] ?? "" },
                        set: { keys[provider] = $0 }))
                } header: {
                    Text("API Key")
                } footer: {
                    Text("每家的 Key 分开保存，只存在本机钥匙串。")
                }
                Section {
                    TextEditor(text: $prompt)
                        .font(.footnote)
                        .frame(minHeight: 260)
                    Button("恢复默认提示词") { prompt = AIConfig.defaultPrompt }
                } header: {
                    Text("提示词")
                } footer: {
                    Text("指令格式：[CH 伸缩 震动 吮吸 0]（0~99）、[HOLD 毫秒]、[STOP]。改提示词时别改这三条的写法。")
                }
            }
            .onChange(of: provider) { p in
                if !p.models.contains(where: { $0.id == modelID }) { modelID = p.models[0].id }
            }
            .navigationTitle("AI 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        AIConfig.provider = provider
                        AIConfig.systemPrompt = prompt
                        if let m = provider.models.first(where: { $0.id == modelID }) { AIConfig.model = m }
                        for p in AIProvider.allCases {
                            AIConfig.setAPIKey((keys[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), for: p)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
