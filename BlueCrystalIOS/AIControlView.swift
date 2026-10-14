import SwiftUI
import Combine
import Security

// MARK: - 配置（接口地址/模型存 UserDefaults，API Key 存钥匙串）

enum AIConfig {
    static let baseURLKey = "bc.ai.baseURL"
    static let modelKey = "bc.ai.model"
    static let keychainAccount = "bc.ai.apiKey"
    static let defaultBaseURL = "https://api.deepseek.com/v1"
    static let defaultModel = "deepseek-chat"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: baseURLKey) }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
    static var apiKey: String {
        get { Keychain.read(account: keychainAccount) ?? "" }
        set { Keychain.write(account: keychainAccount, value: newValue) }
    }
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

// MARK: - 指令格式（对应官方 device-control.js 的 commandList：通道强度 + 持续时间）

/// 一步：三通道强度（官方 0~10 档）+ 持续秒数
struct AIStep: Equatable {
    var stroke: Int
    var vibrate: Int
    var suck: Int
    var duration: Double

    /// 官方换算：≤10 的档位 ×10（VF），迷姬每通道夹到 99（MF）；旋转恒 0
    var levels: [Int] {
        func lv(_ v: Int) -> Int { v <= 0 ? 0 : min(BCProtocol.maxManualLevel, v * 10) }
        var arr = [0, 0, 0, 0]
        arr[BCProtocol.Channel.thrust.rawValue] = lv(stroke)
        arr[BCProtocol.Channel.vibration.rawValue] = lv(vibrate)
        arr[BCProtocol.Channel.suction.rawValue] = lv(suck)
        return arr
    }

    var isZero: Bool { stroke <= 0 && vibrate <= 0 && suck <= 0 }

    var summary: String {
        "伸缩 \(stroke) · 震动 \(vibrate) · 吮吸 \(suck) · \(Int(duration.rounded())) 秒"
    }
}

/// 模型回复解析后的结果
struct AIReply {
    var text: String
    var steps: [AIStep]?
    var loop: Bool
    var stop: Bool

    static let maxSteps = 30
    static let maxStepSeconds: Double = 60
    static let maxLevel = 10

    /// 从模型输出里取第一个到最后一个花括号之间的 JSON；解析不了就当纯文字，不动设备
    static func parse(_ raw: String) -> AIReply {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return AIReply(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), steps: nil, loop: false, stop: false)
        }
        let text = (obj["reply"] as? String) ?? ""
        let stop = (obj["stop"] as? Bool) ?? false
        let loop = (obj["loop"] as? Bool) ?? false
        var steps: [AIStep]?
        if let arr = obj["steps"] as? [[String: Any]] {
            func num(_ any: Any?) -> Double {
                if let n = any as? NSNumber { return n.doubleValue }
                if let s = any as? String, let d = Double(s) { return d }
                return 0
            }
            func level(_ any: Any?) -> Int {
                let v = num(any)
                guard v.isFinite else { return 0 }
                return Int(max(0, min(Double(maxLevel), v.rounded())))
            }
            steps = arr.prefix(maxSteps).compactMap { d in
                let dur = num(d["duration"])
                guard dur.isFinite, dur > 0 else { return nil }
                return AIStep(stroke: level(d["stroke"]), vibrate: level(d["vibrate"]),
                              suck: level(d["suck"]), duration: min(maxStepSeconds, max(0.5, dur)))
            }
        }
        return AIReply(text: text, steps: steps, loop: loop, stop: stop)
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
    var model: String
    var apiKey: String

    func chat(_ messages: [[String: String]]) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey }
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw LLMError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["model": model, "messages": messages, "temperature": 0.7]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String, !content.isEmpty else {
            throw LLMError.empty
        }
        return content
    }
}

// MARK: - ViewModel：聊天 + 执行指令

final class AIControlVM: ObservableObject {
    struct ChatMessage: Identifiable {
        let id = UUID()
        let isUser: Bool
        var text: String
        var program: String?
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
    private var loop = false
    private var heartbeatTimer: Timer?
    private var stepWork: DispatchWorkItem?
    /// 发消息时的停止代次：模型回复回来前用户点了停止，回复就不再启动设备
    private var requestStopGen = 0
    private var stopCount = 0

    static let systemPrompt = """
    你在帮用户控制他自己的一台蓝牙设备。设备有三个通道：伸缩 stroke、震动 vibrate、吮吸 suck，每个通道强度是 0 到 10 的整数，0 表示关闭。
    根据用户的话决定节奏，用简短、自然的中文回复他。
    你只能输出一个 JSON 对象，不要输出任何其他文字或代码块标记，格式：
    {"reply":"对用户说的话","steps":[{"stroke":0,"vibrate":0,"suck":0,"duration":5}],"loop":false,"stop":false}
    规则：
    - steps 按顺序执行，duration 是这一步持续的秒数（1 到 60），最多 30 步。
    - loop 为 true 时，steps 播完从头循环，直到用户的下一条指令；为 false 时播完自动停止。
    - 用户说停、不舒服、够了、疼，或者意思是要停下时：stop 为 true，steps 为空数组。
    - 只是聊天、不需要改变当前节奏时，不要输出 steps 字段。
    - 强度循序渐进，除非用户明确要求，不要一开始就用 8 以上。
    """

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
        messages.append(ChatMessage(isUser: true, text: text, program: nil))
        // 明确的停止词本地立刻停，不等模型
        if Self.isStopWord(text) {
            stopAll(reason: "已停止")
        }
        let history = messages.suffix(20).map { m -> [String: String] in
            ["role": m.isUser ? "user" : "assistant", "content": m.isUser ? m.text : (m.program.map { "\(m.text)\n[已执行：\($0)]" } ?? m.text)]
        }
        let payload = [["role": "system", "content": Self.systemPrompt]] + history
        let client = LLMClient(baseURL: AIConfig.baseURL, model: AIConfig.model, apiKey: AIConfig.apiKey)
        let stopAtSend = stopCount
        isThinking = true
        Task { [weak self] in
            do {
                let raw = try await client.chat(payload)
                await MainActor.run { self?.handle(raw: raw, stopAtSend: stopAtSend) }
            } catch {
                await MainActor.run {
                    guard let self = self else { return }
                    self.isThinking = false
                    self.messages.append(ChatMessage(isUser: false, text: "出错了：\(error.localizedDescription)", program: nil))
                }
            }
        }
    }

    private func handle(raw: String, stopAtSend: Int) {
        isThinking = false
        let reply = AIReply.parse(raw)
        var programText: String?
        if reply.stop {
            stopAll(reason: "AI 已停止")
            programText = "停止"
        } else if let steps = reply.steps {
            if stopCount != stopAtSend {
                // 等回复期间用户点过停止：只显示文字，不启动设备
                programText = "未执行（你已停止）"
            } else if steps.isEmpty || steps.allSatisfy({ $0.isZero }) {
                stopAll(reason: "AI 已停止")
                programText = "停止"
            } else {
                start(steps: steps, loop: reply.loop)
                programText = steps.map(\.summary).joined(separator: " → ") + (reply.loop ? "（循环）" : "")
            }
        }
        let text = reply.text.isEmpty ? (programText == nil ? raw : "") : reply.text
        messages.append(ChatMessage(isUser: false, text: text, program: programText))
    }

    private func start(steps: [AIStep], loop: Bool) {
        guard let ble = ble, ble.state == .ready else {
            statusLine = "设备未连接，没有执行"
            return
        }
        if let reason = ble.safety.blockReason {
            statusLine = reason
            return
        }
        programGen += 1
        self.steps = steps
        self.loop = loop
        running = true
        // 用户刚发了指令：显式开闸（和手动/视频页点"播放"一样）
        ble.userResumeOutput()
        startHeartbeat()
        runStep(0, gen: programGen, first: true)
    }

    private func runStep(_ i: Int, gen: Int, first: Bool = false) {
        guard gen == programGen, running, let ble = ble else { return }
        guard i < steps.count else {
            if loop {
                runStep(0, gen: gen)
            } else {
                haltProgram(reason: "这段节奏播完了，已停止", sendStop: true)
            }
            return
        }
        let step = steps[i]
        let frame = BCProtocol.manualFrame(channels: step.levels)
        // 第一帧走开闸路径；之后的自动帧不开闸，停机/锁闸后会被丢掉
        if first { ble.send(frame: frame) } else { ble.sendThrottled(frame: frame) }
        ble.heartbeat()
        statusLine = "第 \(i + 1)/\(steps.count) 步：\(step.summary)" + (loop ? "（循环）" : "")
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
        let words = ["停", "停下", "停止", "停一下", "别动了", "够了", "不要了", "疼", "stop"]
        return words.contains(t) || t.hasPrefix("停")
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
                        Text("告诉 AI 你想要的感觉，比如“先慢一点，震动为主，慢慢加强”。随时说“停”或点停止。")
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
    @State private var baseURL = AIConfig.baseURL
    @State private var model = AIConfig.model
    @State private var apiKey = AIConfig.apiKey

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("接口地址", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("模型", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                } header: {
                    Text("大模型（OpenAI 兼容接口）")
                } footer: {
                    Text("默认 DeepSeek：https://api.deepseek.com/v1，模型 deepseek-chat。也可以填其他兼容 /chat/completions 的服务。Key 只存在本机钥匙串。")
                }
                Section {
                    Button("恢复默认地址和模型") {
                        baseURL = AIConfig.defaultBaseURL
                        model = AIConfig.defaultModel
                    }
                }
            }
            .navigationTitle("AI 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        AIConfig.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        AIConfig.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
                        AIConfig.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
        }
    }
}
