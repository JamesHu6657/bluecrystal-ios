import SwiftUI
import UIKit
import Combine
import Security

// MARK: - 配置：三家服务商预设，每家一个 Key（存钥匙串）

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

    一条回复里可以写多条指令（最多 40 步），按顺序执行；两条 [CH] 之间没写 [HOLD] 时间隔约 1.5 秒。
    回复结束时最后的强度会一直保持到他下一句话。
    每条指令必须独占一行，不要写在句子中间、引号里或代码块里，参数个数和整数写法要完全正确；
    否则控制器会把整条回复的指令全部作废并停止。

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

    /// 读不出来（不论原因）都当空 Key 用于请求；设置页的回滚要区分时用 storedAPIKey
    static func apiKey(for p: AIProvider) -> String { (try? storedAPIKey(for: p)) ?? "" }
    /// nil = 钥匙串里没有；读取失败时抛错
    static func storedAPIKey(for p: AIProvider) throws -> String? {
        try Keychain.read(account: p.keychainAccount)
    }
    static func setAPIKey(_ key: String, for p: AIProvider) throws {
        try Keychain.write(account: p.keychainAccount, value: key)
    }
}

enum KeychainError: LocalizedError {
    case status(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .status(let op, let s):
            let msg = (SecCopyErrorMessageString(s, nil) as String?) ?? "未知错误"
            return "钥匙串\(op)失败（\(s)）：\(msg)"
        }
    }
}

enum Keychain {
    private static let service = "com.bluecrystal.ios"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// nil 只表示条目不存在；其他失败（含读到的数据解不出来）都抛错，调用方不能把它当成"没有 Key"
    static func read(account: String) throws -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw KeychainError.status("读取", s) }
        guard let d = out as? Data, let v = String(data: d, encoding: .utf8) else {
            throw KeychainError.status("读取", errSecDecode)
        }
        return v
    }

    /// 已有条目用 SecItemUpdate 原地替换，没有才 SecItemAdd；失败时原条目保持不变。空值表示删除
    static func write(account: String, value: String) throws {
        let query = base(account)
        guard !value.isEmpty else {
            let s = SecItemDelete(query as CFDictionary)
            guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError.status("删除", s) }
            return
        }
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let s = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if s == errSecSuccess { return }
        guard s == errSecItemNotFound else { throw KeychainError.status("更新", s) }
        var add = query
        add.merge(attrs) { _, new in new }
        let a = SecItemAdd(add as CFDictionary, nil)
        guard a == errSecSuccess else { throw KeychainError.status("写入", a) }
    }
}

// MARK: - 大模型客户端（三种接口：chat completions / Anthropic messages / responses）

enum LLMError: LocalizedError {
    case missingKey, badURL, http(Int, String), empty, incomplete(String)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "还没填 API Key，点右上角设置"
        case .badURL: return "接口地址不对"
        case .http(let code, let body): return "接口返回 \(code)：\(body.prefix(200))"
        case .empty: return "模型没有返回内容"
        case .incomplete(let why): return "\(why)，没有内容"
        }
    }
}

struct LLMResult {
    var text: String
    /// 非 nil：回复没有正常结束（被截断等），里面的指令一律不执行
    var incompleteReason: String?
}

struct LLMClient {
    var baseURL: String
    var model: AIModel
    var apiKey: String

    /// messages 第一条是 system，其余 user/assistant 交替
    func chat(_ messages: [[String: String]]) async throws -> LLMResult {
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
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LLMError.empty
        }
        let incomplete = LLMResponse.incompleteReason(obj, wire: model.wire)
        guard let text = LLMResponse.extractText(obj, wire: model.wire), !text.isEmpty else {
            if let why = incomplete { throw LLMError.incomplete(why) }
            throw LLMError.empty
        }
        return LLMResult(text: text, incompleteReason: incomplete)
    }
}

// MARK: - ViewModel：聊天 + 执行指令

final class AIControlVM: ObservableObject {
    struct ChatMessage: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
        var program: String?
        /// 模型原始输出（含指令行）：只有程序真的执行了才保存并回传给模型；没执行的回复回传显示文字
        var raw: String?
    }

    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isThinking = false
    @Published var running = false
    @Published var statusLine = "未运行"

    /// 每次请求带上最近这么多条消息（不是轮数）
    static let historyLimit = 20

    private weak var ble: BLEManager?
    private var cancellables = Set<AnyCancellable>()
    /// 停止/换指令就 +1：旧的步骤定时器不再动设备
    private var programGen = 0
    private var steps: [AIStep] = []
    private var heartbeatTimer: Timer?
    private var stepWork: DispatchWorkItem?
    private var endWithStop = false
    /// 回复授权（只在主线程读写，规则见 ReplyAuthorization）：所有停止都经 terminalStop 作废
    private var auth = ReplyAuthorization()
    /// 只有最新一次请求的结果会被处理；被取代的请求（停止词打断）结果直接丢弃
    private var requestID = 0
    private var requestTask: Task<Void, Never>?
    private var tabActive = false
    private var sceneActive = true

    /// 输入框有字、且（没在等回复，或这句是停止词）时可以发
    var canSubmit: Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return !isThinking || AIStopWords.matches(t)
    }

    func attach(ble: BLEManager) {
        cancellables.removeAll()
        self.ble = ble
        // 被动停机（看门狗/单次上限/冷却/输出被拒/退后台）：BLEManager 已经发了停止，这里停程序并作废待执行的回复
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reason in
                self?.terminalStop(reason: reason ?? "已自动停止", sendStop: false)
            }
            .store(in: &cancellables)
        ble.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                guard let self = self, s != .ready else { return }
                // 没在运行也作废：断开期间发出的请求，重连后回来也不许执行
                self.terminalStop(reason: "设备已断开，AI 控制已停止", sendStop: false)
            }
            .store(in: &cancellables)
    }

    func viewAppeared(ble: BLEManager, scenePhase: ScenePhase) {
        attach(ble: ble)
        tabActive = true
        sceneActive = scenePhase == .active
    }

    /// 离开 AI 页面：停止并作废所有待执行的回复
    func viewDisappeared() {
        tabActive = false
        stopAll(reason: "已离开 AI 页面，已停止")
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        sceneActive = phase == .active
        if phase == .background {
            // 停止帧对由 BLEManager.emergencyStop 发，这里只停程序并作废回复
            terminalStop(reason: "App 已退到后台，已停止", sendStop: false)
        }
    }

    /// 用户点停止 / 说了停止词 / 离开页面
    func stopAll(reason: String = "已停止") {
        terminalStop(reason: reason, sendStop: true)
    }

    /// 所有真正的停止都走这里：先作废停止前发出的请求，再停程序。
    /// sendStop 为 false 表示 BLEManager 已经发过停止帧对（被动停机/断开/退后台）
    private func terminalStop(reason: String, sendStop: Bool) {
        auth.revoke()
        haltProgram(reason: reason, sendStop: sendStop)
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let isStop = AIStopWords.matches(text)
        // 在本地停止之前领授权票：说了停止词，模型这次回什么强度都不执行，只显示文字
        let ticket = auth.issue()
        // 停止词先于"等待回复"检查：请求进行中也必须立刻本地停
        if isStop {
            stopAll(reason: "已停止（本地停止词）")
        } else if isThinking {
            statusLine = "她还在回复；说“停”或点停止随时有效"
            return
        }
        input = ""
        messages.append(ChatMessage(isUser: true, text: text, program: nil, raw: nil))
        // 停止词打断进行中的请求：旧请求作废（授权已撤销，结果也不再处理），带上停止这句重新问
        requestTask?.cancel()
        requestID &+= 1
        let id = requestID
        let history = messages.suffix(Self.historyLimit).map { m -> [String: String] in
            let content = m.raw ?? (m.text.isEmpty ? (m.program ?? "…") : m.text)
            return ["role": m.isUser ? "user" : "assistant", "content": content]
        }
        let payload = [["role": "system", "content": AIConfig.systemPrompt]] + history
        let provider = AIConfig.provider
        let client = LLMClient(baseURL: provider.baseURL, model: AIConfig.model, apiKey: AIConfig.apiKey(for: provider))
        isThinking = true
        requestTask = Task { [weak self] in
            do {
                let result = try await client.chat(payload)
                await MainActor.run { self?.handle(result, requestID: id, ticket: ticket) }
            } catch {
                await MainActor.run { self?.handleError(error, requestID: id) }
            }
        }
    }

    private func handleError(_ error: Error, requestID id: Int) {
        guard id == requestID else { return }
        isThinking = false
        requestTask = nil
        if let e = error as? LLMError, case .incomplete(_) = e, running {
            stopAll(reason: "回复不完整，已停止")
        }
        messages.append(ChatMessage(isUser: false, text: "出错了：\(error.localizedDescription)", program: nil, raw: nil))
    }

    /// 执行前的最后检查（主线程，紧挨着 start）：返回不能执行的原因
    private func executionBlock(ticket: ReplyAuthorization.Ticket) -> String? {
        if let reason = auth.block(ticket) { return reason }
        if !tabActive { return "已离开 AI 页面" }
        if !sceneActive || UIApplication.shared.applicationState != .active { return "App 不在前台" }
        guard let ble = ble, ble.state == .ready else { return "设备未连接" }
        if let reason = ble.safety.blockReason { return reason }
        return nil
    }

    /// 程序作废：一步都不执行；正在输出就安全停止
    private func rejectProgram(_ reason: String) {
        if running { stopAll(reason: reason) }
    }

    private func handle(_ result: LLMResult, requestID id: Int, ticket: ReplyAuthorization.Ticket) {
        guard id == requestID else { return }
        isThinking = false
        requestTask = nil
        let reply = AIReply.parse(result.text)
        var programText: String?
        var executed = false
        if let why = result.incompleteReason {
            programText = "\(why)，指令未执行"
            rejectProgram("回复不完整，已停止")
        } else if let why = reply.rejection {
            programText = "未执行：\(why)"
            rejectProgram("回复指令无效，已停止")
        } else if !reply.steps.isEmpty {
            if let block = executionBlock(ticket: ticket) {
                programText = "未执行（\(block)）"
                rejectProgram("已停止")
            } else {
                start(steps: reply.steps, endWithStop: reply.stop)
                executed = true
                programText = reply.steps.map(\.summary).joined(separator: " → ") + (reply.stop ? " → 停止" : "")
            }
        } else if reply.stop {
            stopAll(reason: "已停止")
            executed = true
            programText = "停止"
        }
        messages.append(ChatMessage(isUser: false, text: reply.text, program: programText,
                                    raw: executed ? result.text : nil))
    }

    /// 调用方先用 executionBlock 确认授权、连接、安全状态和前台
    private func start(steps: [AIStep], endWithStop: Bool) {
        guard let ble = ble else { return }
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
            // 序列走完：带 [STOP] 或最后是全零 → 真正停止（和用户停止一样作废期间发出的请求）；
            // 否则保持最后的强度，等下一条回复
            if ReplyAuthorization.programEndIsTerminal(steps: steps, endWithStop: endWithStop) {
                terminalStop(reason: "已停止", sendStop: true)
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
}

// MARK: - 界面

struct AIControlView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.scenePhase) private var scenePhase
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
                // 等回复期间输入框也保持可用：停止词随时能发
                TextField(vm.isThinking ? "她在回复…说“停”随时停" : "说点什么…", text: $vm.input)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { vm.send() }
                Button { vm.send() } label: {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(!vm.canSubmit)
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
        .onAppear { vm.viewAppeared(ble: ble, scenePhase: scenePhase) }
        .onDisappear { if !showSettings { vm.viewDisappeared() } }
        .onChange(of: scenePhase) { phase in vm.scenePhaseChanged(phase) }
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var provider = AIConfig.provider
    @State private var modelID = AIConfig.model.id
    @State private var prompt = AIConfig.systemPrompt
    @State private var keys: [AIProvider: String] = AISettingsView.loadKeys()
    /// 钥匙串里当前的值：只写改过的 Key。读取失败的服务商不在表里（原值未知），回滚时跳过，绝不删除
    @State private var savedKeys: [AIProvider: String] = AISettingsView.loadSavedKeys()
    @State private var saveError: String?

    private static func loadKeys() -> [AIProvider: String] {
        Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, AIConfig.apiKey(for: $0)) })
    }

    private static func loadSavedKeys() -> [AIProvider: String] {
        var out: [AIProvider: String] = [:]
        for p in AIProvider.allCases {
            do { out[p] = try AIConfig.storedAPIKey(for: p) ?? "" } catch { continue }
        }
        return out
    }

    var body: some View {
        NavigationView {
            Form {
                if let err = saveError {
                    Section {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                }
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
                    Text("指令格式：[CH 伸缩 震动 吮吸 0]（0~99）、[HOLD 毫秒]、[STOP]，每条单独占一行。改提示词时别改这三条的写法。")
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
                    Button("保存") { save() }
                }
            }
        }
    }

    /// 先写钥匙串；任何一个 Key 写失败就把这次已写入的 Key 改回原值，服务商/模型/提示词也不保存。
    /// 原值读取失败（未知）的 Key 不回滚：写回空值会删掉原条目
    private func save() {
        var written: [AIProvider] = []
        for p in AIProvider.allCases {
            let key = (keys[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard key != (savedKeys[p] ?? "") else { continue }
            do {
                try AIConfig.setAPIKey(key, for: p)
                written.append(p)
            } catch {
                var notRestored: [String] = []
                for w in written {
                    let newKey = (keys[w] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let old = savedKeys[w] else {
                        notRestored.append(w.title)
                        savedKeys[w] = newKey
                        continue
                    }
                    do {
                        try AIConfig.setAPIKey(old, for: w)
                    } catch {
                        notRestored.append(w.title)
                        savedKeys[w] = newKey
                    }
                }
                var msg = "\(p.title) 的 API Key 保存失败：\(error.localizedDescription)\n设置都没有保存。"
                if !notRestored.isEmpty {
                    msg += "\n注意：\(notRestored.joined(separator: "、")) 的新 Key 已写入且无法改回（原 Key 读取失败或改回失败）。"
                }
                saveError = msg
                return
            }
        }
        AIConfig.provider = provider
        AIConfig.systemPrompt = prompt
        if let m = provider.models.first(where: { $0.id == modelID }) { AIConfig.model = m }
        dismiss()
    }
}
