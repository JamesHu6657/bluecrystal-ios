import SwiftUI
import UIKit
import Combine
import Security

// MARK: - 配置：三家服务商预设，每家一个 Key（存钥匙串）

struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let wire: WireProtocol
    /// 支持 reasoning 参数（/responses 的 reasoning.effort）；不支持的模型发了可能被 400 拒绝
    var reasoning: Bool = false
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
                AIModel(id: "meta/muse-spark-1.3-contributor", name: "Muse Spark 1.3 Contributor", wire: .responses,
                        reasoning: true),
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
    整段程序（所有 HOLD 和间隔加起来）不能超过 120 秒，超过的话整条回复都不执行。
    回复结束时最后的强度会一直保持到他下一句话；他 120 秒没说话，控制器会自动停止。
    每条指令必须独占一行，不要写在句子中间、引号里或代码块里，参数个数和整数写法要完全正确；
    否则控制器会把整条回复的指令全部作废并停止。

    ## 行为准则
    1. 中文，简短撩人，一次 1~3 句；每 2~3 句话必须有一次 [CH]/[HOLD] 动作，光说不练不许。
    2. 节奏：[CH 10 10 0 0] 慢热开场 → 逐步升温 → 小恶魔捉弄
       （突然 [HOLD 5000] 停在边缘、快到时降回 15）→ 最后放他释放。
    3. 安全词优先：他说"停"或"受不了"，立刻 [STOP]；说"慢"，立刻降档。
    4. 单通道最高 70（控制器会把更高的值压到 70），每秒每通道最多加 20（控制器会自动插入爬升和等待），全程循序渐进。
    5. 坏得温柔，例如："宝宝忍得住吗？忍不住要求我哦。"、"不许自己偷偷动，只能我来。"
    6. 结束发 [STOP]，说句温柔的话让他休息。

    ## 禁止
    - 不许跳出人设解释自己是 AI 或讲蓝牙原理。
    - 不许开场就把通道拉满。
    - 指令格式严格遵守，方括号、空格、数字缺一不可。
    """

    /// 只给设置页预填输入框用（读取失败时设置页另外显示错误）；发请求用 storedAPIKey，读取失败要报出来
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
    case missingKey, badURL, http(Int, String), empty, incomplete(String), timeout(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .missingKey: return "还没填 API Key，点右上角设置"
        case .badURL: return "接口地址不对"
        case .http(let code, let summary):
            // L4：只显示状态码和接口给的错误说明（已遮掉 Key 和长串标识），不显示原始正文
            return summary.isEmpty ? "接口返回 \(code)" : "接口返回 \(code)：\(summary.prefix(200))"
        case .empty: return "模型没有返回内容"
        case .incomplete(let why): return "\(why)，没有内容"
        case .timeout(let s): return "请求超过 \(Int(s)) 秒没有完成"
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
            body = ["model": model.id, "instructions": system, "input": convo, "max_output_tokens": 3000]
            if model.reasoning { body["reasoning"] = ["effort": "low"] }
        }
        guard let url = URL(string: base + path), url.scheme?.hasPrefix("http") == true else {
            throw LLMError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if model.wire == .anthropicMessages {
            // 原生 Anthropic 接口认 x-api-key，代理可能认 Bearer：两个都带
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, LLMResponse.errorSummary(data, apiKey: apiKey))
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
        /// 本地出错提示：只显示，不进请求历史
        var isError = false
    }

    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var isThinking = false
    @Published var running = false
    @Published var statusLine = "未运行，她在等你开口"

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
    /// 只有最新一次请求的结果会被处理；被取代的请求（停止词打断、总时长到点）结果直接丢弃
    private var requestID = 0
    private var requestTask: Task<Void, Never>?
    private(set) var tabActive = false
    private var sceneActive = true
    /// 程序当前在设备上的强度（爬升的起点）；停止后归零
    private var currentLevels = [0, 0, 0, 0]
    /// 程序走完、开始保持最后强度的时间（单调时钟）；nil = 没在保持
    private var holdStartedAt: TimeInterval?
    /// 最近一条用户消息的时间（单调时钟）
    private var lastUserMessageAt: TimeInterval?
    /// 这次运行开始的时间（单调时钟）：没有用户消息记录时的在场计时起点（H1）
    private var runStartedAt: TimeInterval?
    /// 最近一次升高强度的时间（单调时钟）：下一条回复的时间限速起点（M2）
    private var lastRiseAt: TimeInterval?
    /// 执行前读到的被动停机代次：开闸时交给 BLEManager 核对（M5）
    private var runEpoch: Int?

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 输入框有字、且（没在等回复，或这句是停止词）时可以发
    var canSubmit: Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return !isThinking || AIStopWords.matches(t)
    }

    func attach(ble: BLEManager) {
        cancellables.removeAll()
        self.ble = ble
        // 被动停机（看门狗/单次上限/冷却/输出被拒/退后台）：BLEManager 已经发了停止，这里停程序并作废待执行的回复。
        // 第二轮审查 M1：不再 receive(on: DispatchQueue.main)。BLEManager 在主线程上、和 gateEpoch 同一个 block 里 send，
        // 直接订阅时 terminalStop 在同一个 block 里同步执行；多跳一次主队列的话，中间排着的回复会读到新代次、
        // 授权却还没作废，照样开闸（M5 的代次核对被绕过）。万一不在主线程就退回主队列
        ble.forceZeroOutputs
            .sink { [weak self] reason in
                let why = reason ?? "已自动停止"
                guard Thread.isMainThread else {
                    DispatchQueue.main.async { self?.terminalStop(reason: why, sendStop: false) }
                    return
                }
                self?.terminalStop(reason: why, sendStop: false)
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

    /// 打开设置页（L2）：设置页会盖住停止键，打开前先停止并作废待执行的回复
    func willOpenSettings() {
        if running || isThinking { stopAll(reason: "已打开 AI 设置，AI 控制已停止") }
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
        lastUserMessageAt = Self.now()
        messages.append(ChatMessage(isUser: true, text: text, program: nil, raw: nil))
        // 停止词打断进行中的请求：旧请求作废（授权已撤销，结果也不再处理），带上停止这句重新问
        requestTask?.cancel()
        requestTask = nil
        requestID &+= 1
        let id = requestID
        let turns = messages.map { m in
            AIHistory.Turn(isUser: m.isUser, isError: m.isError, content: AIHistory.content(raw: m.raw, text: m.text))
        }
        let history = AIHistory.window(turns, limit: Self.historyLimit)
        let payload = [["role": "system", "content": AIConfig.systemPrompt]] + history
        let provider = AIConfig.provider
        let apiKey: String
        do {
            apiKey = try AIConfig.storedAPIKey(for: provider) ?? ""
        } catch {
            // 钥匙串读取失败要如实报出来，不能当成"还没填 Key"
            isThinking = false
            handleError(error, requestID: id)
            return
        }
        let client = LLMClient(baseURL: provider.baseURL, model: AIConfig.model, apiKey: apiKey)
        isThinking = true
        requestTask = Task { [weak self] in
            do {
                let result = try await client.chat(payload)
                await MainActor.run { self?.handle(result, requestID: id, ticket: ticket) }
            } catch {
                await MainActor.run { self?.handleError(error, requestID: id) }
            }
        }
        // L5：请求总时长上限（URLRequest 的 timeoutInterval 只是空闲超时）
        DispatchQueue.main.asyncAfter(deadline: .now() + AIRequestPolicy.totalTimeoutSeconds) { [weak self] in
            self?.requestDeadlinePassed(requestID: id)
        }
    }

    /// 请求总时长到点（L5）：按请求错误处理（运行中就停止），然后作废这次请求，被取消后的报错不再处理
    private func requestDeadlinePassed(requestID id: Int) {
        guard id == requestID, isThinking else { return }
        let task = requestTask
        handleError(LLMError.timeout(AIRequestPolicy.totalTimeoutSeconds), requestID: id)
        requestID &+= 1
        task?.cancel()
    }

    /// 任何请求错误（HTTP、超时、429、断网、回复不完整、钥匙串读取失败）在输出中都停止：
    /// 用户这句话没有得到回应，不能让设备停在上一条回复的强度上
    private func handleError(_ error: Error, requestID id: Int) {
        guard id == requestID else { return }
        isThinking = false
        requestTask = nil
        if running {
            if let e = error as? LLMError, case .incomplete(_) = e {
                stopAll(reason: "回复不完整，已停止")
            } else {
                stopAll(reason: "请求出错，已停止")
            }
        }
        messages.append(ChatMessage(isUser: false, text: "出错了：\(error.localizedDescription)", program: nil,
                                    raw: nil, isError: true))
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
                // M5：被动停机代次和执行前检查在同一时刻读；开闸时 BLEManager 在自己的队列上再核对
                let epoch = ble?.gateEpoch ?? -1
                let now = Self.now()
                // M2：接着上一条回复继续时，时间限速从上次升高算起
                let sinceRise: TimeInterval = running ? (lastRiseAt.map { now - $0 } ?? TimeInterval.infinity)
                    : TimeInterval.infinity
                // 上限 70、每秒每通道最多 +20、从空闲开始时从 0 爬升（H3/M2）：在代码里执行，不靠提示词
                let safe = AISafety.enforce(reply.steps, from: running ? currentLevels : [0, 0, 0, 0],
                                            secondsSinceRise: sinceRise)
                if let tooLong = AISafety.programTooLong(safe) {
                    // H1：单条程序不能比在场时限还长
                    programText = "未执行：\(tooLong)"
                    rejectProgram("回复程序太长，已停止")
                } else {
                    start(steps: safe.steps, endWithStop: reply.stop, epoch: epoch)
                    executed = true
                    programText = AISafety.describe(safe, stop: reply.stop)
                }
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
    private func start(steps: [AIStep], endWithStop: Bool, epoch: Int) {
        guard let ble = ble else { return }
        programGen += 1
        stepWork?.cancel()
        self.steps = steps
        self.endWithStop = endWithStop
        holdStartedAt = nil
        if !running { runStartedAt = Self.now() }
        running = true
        runEpoch = epoch
        // 用户刚发了消息、模型回了指令：显式开闸（和手动/视频页点"播放"一样）；
        // 执行前检查之后发生过被动停机（代次变了）时 BLEManager 不开（M5）
        ble.userResumeOutput(epoch: epoch)
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
            } else {
                beginHold()
            }
            return
        }
        let step = steps[i]
        if let lv = step.levels {
            // 全零步照常发强度 0 帧：BLEManager 在运行中把它换成完整停止帧对（at(0,255) → 100ms → Tt(0)），
            // 不锁闸、运行继续，后面还能接着加；空闲时直接丢掉。
            // M1：带升幅上限交给 BLEManager，按实际发出的上一帧再限一次，在途合并也不会一步跳过 +20
            let frame = BCProtocol.manualFrame(channels: lv)
            if first {
                ble.send(frame: frame, maxRise: AISafety.maxStepIncrease, epoch: runEpoch)
            } else {
                ble.sendThrottled(frame: frame, maxRise: AISafety.maxStepIncrease)
            }
            if lv.indices.contains(where: { lv[$0] > currentLevels[$0] }) { lastRiseAt = Self.now() }
            currentLevels = lv
        }
        ble.heartbeat()
        statusLine = step.duration > 0
            ? "第 \(i + 1)/\(steps.count) 步：\(step.summary)"
            : "保持：\(step.summary)"
        guard step.duration > 0 else {
            // 最后一步保持；如果是全零则走上面的停止分支
            if step.isZero { runStep(i + 1, gen: gen) } else { beginHold() }
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
        currentLevels = [0, 0, 0, 0]
        holdStartedAt = nil
        runStartedAt = nil
        lastRiseAt = nil
        runEpoch = nil
        let wasRunning = running
        running = false
        if sendStop { ble?.sendStop() }
        if wasRunning || sendStop { statusLine = reason }
    }

    /// 程序走完、保持最后强度：开始计空闲时限（H2）
    private func beginHold() {
        holdStartedAt = Self.now()
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.running else { return }
            let now = Self.now()
            // H1：不论在执行程序还是保持，离最近一条用户消息 120 秒就停止
            if AISafety.presenceExpired(now: now, lastUserMessageAt: self.lastUserMessageAt,
                                        runStartedAt: self.runStartedAt)
                || AISafety.holdIdleExpired(now: now, holdStartedAt: self.holdStartedAt,
                                            lastUserMessageAt: self.lastUserMessageAt) {
                self.stopAll(reason: "\(Int(AISafety.holdIdleTimeout)) 秒没有新消息，已停止")
                return
            }
            self.ble?.heartbeat()
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }
}

// MARK: - 界面

/// 页头显示的服务商 / 模型：设置保存或快捷切换写进 UserDefaults 后立刻刷新。
/// 不用 @AppStorage：键名带点（bc.ai.provider），KVO 会把点当成路径，外部写入时收不到更新
final class AIConfigWatcher: ObservableObject {
    @Published private(set) var provider = AIConfig.provider
    @Published private(set) var model = AIConfig.model
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let t = token { NotificationCenter.default.removeObserver(t) }
    }

    func refresh() {
        let p = AIConfig.provider
        let m = AIConfig.model
        if p != provider { provider = p }
        if m != model { model = m }
    }

    /// 页头的快捷切换：只改下一次请求用哪家，不影响任何安全规则。运行中 / 等回复时菜单禁用（换模型要先停止）
    func select(_ p: AIProvider, _ m: AIModel) {
        AIConfig.provider = p
        AIConfig.model = m
        refresh()
    }
}

struct AIControlView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var privacy: PrivacyLock
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm = AIControlVM()
    @StateObject private var config = AIConfigWatcher()
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if vm.messages.isEmpty {
                            emptyState
                        }
                        ForEach(vm.messages) { m in
                            ChatBubble(message: m)
                                .id(m.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                        if vm.isThinking {
                            TypingIndicator()
                                .transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.messages.count)
                    .animation(.easeInOut(duration: 0.2), value: vm.isThinking)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: vm.messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    // 她回话了：轻轻一下（出错提示不震，红字另有警告触感）。
                    // 切到别的标签页时回复也可能回来（程序已作废，只是文字）：那时不震，避免没头没脑的一下
                    if vm.tabActive, let last = vm.messages.last, !last.isUser, !last.isError { Haptics.soft() }
                }
                .onChange(of: vm.isThinking) { _ in
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            // 快捷话和输入栏共用一层底色（之前两层深浅不同，中间有一道接缝）
            VStack(spacing: 0) {
                if showQuickReplies {
                    // 减弱动态效果时只淡入淡出，不位移
                    quickReplies
                        .transition(quickReplyTransition)
                }
                inputBar
            }
            // 只给快捷话这一层做动画，不把聊天记录一起带着动
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showQuickReplies)
            .background(.ultraThinMaterial)
            .background(Velvet.ink.opacity(0.5))
        }
        .background(VelvetBackground(glow: vm.running ? 0.55 : (vm.isThinking ? 0.3 : 0.12)).ignoresSafeArea())
        .sheet(isPresented: $showSettings, onDismiss: { config.refresh() }) {
            // 弹出层盖在根视图的入口页 / 解锁页 / 隐私模糊之上，自己也要挂一份
            AISettingsView()
                .privacyCover()
                .environmentObject(privacy)
                .environmentObject(ble)
        }
        .onAppear {
            config.refresh()
            vm.viewAppeared(ble: ble, scenePhase: scenePhase)
        }
        .onDisappear { if !showSettings { vm.viewDisappeared() } }
        .onChange(of: scenePhase) { phase in vm.scenePhaseChanged(phase) }
        // 解锁页上的停止：和本页停止键同一个 stopAll（停程序、作废授权）
        .onReceive(privacy.stopAllRequested) { _ in vm.stopAll() }
    }

    private static let bottomID = "chat-bottom"

    /// 页头：她的名字、当前服务商/模型（可快捷切换）、设置；下面一行是状态和停止（原"当前"区块），
    /// 再下面钉着紧凑的设备卡片：聊天每来一条消息都会自动滚到底，设备卡片放在聊天里会被滚走
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Velvet.roseGradient)
                        .frame(width: 44, height: 44)
                        .shadow(color: Velvet.rose.opacity(vm.running ? 0.7 : 0.3), radius: vm.running ? 12 : 6)
                    Text("栞")
                        .font(Velvet.serif(20, .semibold))
                        .foregroundColor(.white)
                }
                // 模型菜单的点按区高 44pt，自带上下留白，这里不再加间距
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("她")
                            .font(Velvet.display(.title))
                            .foregroundColor(Velvet.text)
                        Text("明月栞那")
                            .font(.footnote)
                            .foregroundColor(Velvet.textSecondary)
                    }
                    modelMenu
                }
                Spacer(minLength: 4)
                Button {
                    // L2：设置页会盖住停止键，打开前先停止
                    vm.willOpenSettings()
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Velvet.text)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("AI 设置")
            }
            HStack(spacing: 10) {
                StatusOrb(color: vm.running ? Velvet.rose : (vm.isThinking ? Velvet.gold : Velvet.textMuted),
                          pulsing: vm.running || vm.isThinking)
                Text(vm.statusLine)
                    .font(.caption)
                    .foregroundColor(Velvet.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("停止", role: .destructive) {
                    vm.stopAll()
                    Haptics.stop()
                }
                .buttonStyle(PillButtonStyle(kind: .danger))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
            // 打字时键盘占了半屏：红字和安全状态先收成两行，点一下收起键盘就完整显示（解除锁定键始终在）
            DeviceStatusCard(allowDisconnect: false, connectTitle: "连接", compact: true, collapsed: inputFocused)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [Velvet.ink.opacity(0.95), Velvet.ink.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    /// 运行中或等回复时不许快捷切换：设置页换模型要先停止，这里也一样；页头也不会显示一个还没在用的模型
    private var modelLocked: Bool { vm.running || vm.isThinking }

    /// 当前服务商 · 模型；点开可以快捷切换（只影响下一次请求）
    private var modelMenu: some View {
        Menu {
            ForEach(AIProvider.allCases) { p in
                Section(p.title) {
                    ForEach(p.models) { m in
                        Button {
                            // 菜单打开期间开始运行时也不换
                            guard !modelLocked else { return }
                            config.select(p, m)
                            Haptics.select()
                        } label: {
                            if p == config.provider && m.id == config.model.id {
                                Label(m.name, systemImage: "checkmark")
                            } else {
                                Text(m.name)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(config.provider.title) · \(config.model.name)")
                    .lineLimit(1)
                Image(systemName: modelLocked ? "lock.fill" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.caption)
            .foregroundColor(Velvet.gold.opacity(modelLocked ? 0.6 : 1))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(modelLocked)
        .accessibilityLabel("当前模型：\(config.provider.title) \(config.model.name)")
        .accessibilityHint(modelLocked ? "运行中不能切换，先停止" : "切换模型")
    }

    /// 盖着入口页 / 解锁页时不发送：系统键盘浮在解锁页上面时，回车也不能把消息发出去
    private func submit() {
        guard !privacy.isCovering(ble) else {
            PrivacyLock.dismissKeyboard()
            return
        }
        vm.send()
    }

    /// 快捷话出现 / 收起：减弱动态效果时只淡入淡出（写成明确类型，避开 iOS 17 Transition 重载的推断）
    private var quickReplyTransition: AnyTransition {
        if reduceMotion { return AnyTransition.opacity }
        let move: AnyTransition = AnyTransition.move(edge: .bottom)
        return move.combined(with: AnyTransition.opacity)
    }

    /// 输入框空着且设备允许输出时才出快捷话（不邀请尚不能开始的输出，也不盖掉输入）。
    /// 等回复期间不收起（之前每发一句都收起再弹出，聊天区跟着上下跳），只是暂时点不了
    private var showQuickReplies: Bool {
        vm.input.isEmpty && ble.state == .ready && ble.safety.blockReason == nil
    }

    /// 快捷话：一点就发，和自己打字回车完全同一条路径（submit → vm.send）。
    /// 都不是停止词（ProtocolChecks 钉住）；停止仍然是左下角的红色停止键或说"停"。
    /// 没开始时是邀请的话，她在带节奏时换成调快慢的话
    private var quickReplies: some View {
        let phrases: [String] = AIQuickReplies.current(running: vm.running)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(phrases, id: \.self) { phrase in
                    Button {
                        sendQuickReply(phrase)
                    } label: {
                        Text(phrase)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(Velvet.text)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .overlay(Capsule().strokeBorder(Velvet.rose.opacity(0.35), lineWidth: 1))
                            // 看起来 36pt 高，点按区 44pt
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(vm.isThinking)
                    .accessibilityHint(vm.isThinking ? "她回复后可以点" : "发送这句话")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 4)
    }

    /// 隐私遮挡期间不发，也不把这句留在输入框里
    private func sendQuickReply(_ phrase: String) {
        guard !privacy.isCovering(ble) else {
            PrivacyLock.dismissKeyboard()
            return
        }
        Haptics.select()
        vm.input = phrase
        submit()
    }

    /// 空状态文案跟着快捷话走：快捷话没出现，就不邀请"点下面的一句"
    private var emptyStateLine: String {
        if showQuickReplies {
            return "跟她说句话，或点下面的一句就开始。随时说“停”或点红色停止，本地立刻停。"
        }
        return "跟她说句话就开始。随时说“停”或点红色停止，本地立刻停。"
    }

    /// 快捷话暂时不出现的原因（设备没连上 / 安全规则暂时不许输出）
    private var emptyStateFootnote: String? {
        if ble.state == .ready && ble.safety.blockReason == nil { return nil }
        if ble.state != .ready { return "连上设备后，这里还会出现一点就能发的快捷话" }
        return "等安全限制解除，这里还会出现一点就能发的快捷话"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(Velvet.roseGradient)
                .shadow(color: Velvet.rose.opacity(0.6), radius: 12)
            Text("她在等你开口")
                .font(Velvet.display(.title3, .medium))
                .foregroundColor(Velvet.text)
            Text(emptyStateLine)
                .font(.caption)
                .foregroundColor(Velvet.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote = emptyStateFootnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundColor(Velvet.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .velvetAppear()
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            // 第三轮 M2：停止键常驻输入栏。聊天记录一长页头之外的内容会滚走，
            // 输入栏始终在底部，不用滚动、不用打字也能一下停
            Button(role: .destructive) {
                vm.stopAll()
                Haptics.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Velvet.stopGradient))
                    .shadow(color: Velvet.danger.opacity(0.5), radius: 8)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("停止")
            .accessibilityHint("立即停止所有输出")
            // 等回复期间输入框也保持可用：停止词随时能发
            TextField(vm.isThinking ? "她在回复…说“停”随时停" : "说点什么…", text: $vm.input)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
                .foregroundColor(Velvet.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(inputFocused ? Velvet.rose.opacity(0.6) : Velvet.stroke, lineWidth: 1))
            Button { submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Velvet.roseGradient))
            }
            .buttonStyle(PressableStyle())
            .disabled(!vm.canSubmit)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 一条消息：用户在右（玫瑰色），她在左（深色丝绒），出错红色；程序说明以小字附在下面（不隐藏）
private struct ChatBubble: View {
    let message: AIControlVM.ChatMessage

    var body: some View {
        let isUser = message.isUser
        VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(message.isError ? Velvet.danger : (isUser ? Color.white : Velvet.text))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(message.isError ? Velvet.danger.opacity(0.5)
                                          : Color.white.opacity(isUser ? 0.0 : 0.08), lineWidth: 1)
                    )
                    .shadow(color: isUser ? Velvet.rose.opacity(0.3) : .clear, radius: 10, y: 3)
                    .textSelection(.enabled)
            }
            if let p = message.program {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "waveform.path")
                    Text(p).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .foregroundColor(Velvet.textMuted)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(isUser ? .leading : .trailing, 44)
    }

    @ViewBuilder private var bubbleBackground: some View {
        if message.isError {
            Velvet.danger.opacity(0.12)
        } else if message.isUser {
            Velvet.chatGradient
        } else {
            LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// 她在打字：三个依次亮起的点（减弱动态效果时静止）
private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let interval: Double = 1.0 / 20.0
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion)) { ctx in
            let t: Double = ctx.date.timeIntervalSinceReferenceDate
            let angle: Double = t * 2.0 * Double.pi / 1.2
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    let delay: Double = Double(i) * 0.7
                    let phase: Double = reduceMotion ? 0.6 : sin(angle - delay)
                    let positivePhase: Double = max(0.0, phase)
                    let opacity: Double = 0.35 + 0.65 * positivePhase
                    let scale: Double = 0.85 + 0.25 * positivePhase
                    let dotScale: CGFloat = CGFloat(scale)
                    Circle()
                        .fill(Velvet.blush)
                        .frame(width: 7, height: 7)
                        .opacity(opacity)
                        .scaleEffect(dotScale)
                }
                Text("她在想…")
                    .font(.caption)
                    .foregroundColor(Velvet.textMuted)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("她在回复")
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
    @State private var saveError: String? = AISettingsView.loadReadErrors()

    private static func loadKeys() -> [AIProvider: String] {
        Dictionary(uniqueKeysWithValues: AIProvider.allCases.map { ($0, AIConfig.apiKey(for: $0)) })
    }

    /// 钥匙串读取失败的服务商：输入框会是空的，这里说明真实原因（不是"没填"）
    private static func loadReadErrors() -> String? {
        var lines: [String] = []
        for p in AIProvider.allCases {
            do { _ = try AIConfig.storedAPIKey(for: p) } catch { lines.append("\(p.title)：\(error.localizedDescription)") }
        }
        return lines.isEmpty ? nil : "读取已保存的 API Key 失败（输入框显示为空，不代表没有 Key）：\n" + lines.joined(separator: "\n")
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
                    Text("指令格式：[CH 伸缩 震动 吮吸 0]（0~99，超过 99 整条不执行）、[HOLD 毫秒]、[STOP]，每条单独占一行。改提示词时别改这三条的写法。不论提示词怎么写，App 都会把强度压到 \(AISafety.maxLevel) 以下、每秒每通道最多加 \(AISafety.maxStepIncrease)，单条程序总长超过 \(Int(AISafety.maxProgramSeconds)) 秒整条不执行，离最近一条消息 \(Int(AISafety.holdIdleTimeout)) 秒没有新消息就停止。")
                }
            }
            .onChange(of: provider) { p in
                if !p.models.contains(where: { $0.id == modelID }) { modelID = p.models[0].id }
            }
            .scrollContentBackground(.hidden)
            .background(VelvetBackground(glow: 0.1).ignoresSafeArea())
            .tint(Velvet.rose)
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
