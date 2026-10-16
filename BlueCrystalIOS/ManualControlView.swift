import SwiftUI
import Combine

/// 手动控制的 ViewModel：带后缘节流的强度发送
final class ManualControlVM: ObservableObject {
    @Published var channels: [Double] = [0, 0, 0, 0]
    /// 当前控制方式（官方三个 tab：技能 / 变频 / 手动）
    @Published private(set) var mode: BCProtocol.Mode = .frequency
    /// 技能 tab 当前选中的预设
    @Published private(set) var selectedPreset: String?

    private weak var ble: BLEManager?
    /// 上次发送时间（单调时钟，修 L7）
    private var lastSend = -Double.infinity
    private var pendingWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// 手动页心跳定时器：滑杆停住不动时也要告诉看门狗"我还活着"，
    /// 否则 5 秒就被误杀（修 N1）
    private var heartbeatTimer: Timer?
    /// 上次停止以来发过输出（有输出才需要空闲停机）
    private var outputSinceStop = false
    /// 最近一次用户操作（单调时钟）
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    /// 空闲停机后的提示；用户再操作时清掉
    @Published private(set) var idleNotice: String?
    /// 召回收藏时的缓推（FavoriteGlide）：代次 +1 就作废后面的步骤
    private var glideGen = 0
    private var glideWork: DispatchWorkItem?
    @Published private(set) var isGliding = false

    static let throttleInterval: TimeInterval = 0.12
    /// 手动页这么久没有任何操作就自动停止输出（L7）：心跳只证明界面活着，不证明有人在操作。
    /// 判断逻辑在 ManualIdle（纯类型，ProtocolChecks 覆盖）
    static let idleTimeout: TimeInterval = ManualIdle.timeoutSeconds

    func attach(ble: BLEManager) {
        // N4：切 Tab 回来会重复 attach，先清掉旧的订阅
        cancellables.removeAll()
        self.ble = ble
        // 断开后滑杆归零，避免 UI 显示和设备实际状态不一致
        ble.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in
                if s != .ready { self?.reset() }
            }
            .store(in: &cancellables)
        // 被动停机（看门狗/退后台/上限/输出被拒）：滑杆归零（修 高1）；原因由 BLEManager 显示在红字里
        ble.forceZeroOutputs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reset() }
            .store(in: &cancellables)
        startHeartbeatTimer()
    }

    /// 离开手动页时调用：停心跳、清订阅（stopAll 另行调用）
    func detach() {
        cancelGlide()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        cancellables.removeAll()
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if ManualIdle.expired(now: ProcessInfo.processInfo.systemUptime,
                                  lastInteraction: self.lastInteraction,
                                  outputSinceStop: self.outputSinceStop) {
                self.stopAll()
                self.idleNotice = "\(Int(Self.idleTimeout / 60)) 分钟没有操作，已自动停止输出"
                return
            }
            self.ble?.heartbeat()
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    private func noteInteraction() {
        lastInteraction = ProcessInfo.processInfo.systemUptime
        idleNotice = nil
    }

    func setChannel(_ index: Int, _ value: Double) {
        guard mode != .skill, BCProtocol.Channel(rawValue: index)?.isUsed == true else { return }
        // 用户亲手拖滑杆：缓推让位，以手上的为准
        cancelGlide()
        noteInteraction()
        outputSinceStop = true
        channels[index] = value
        scheduleSend()
    }

    /// 切换控制方式：先停机归零，避免 0~9 和 0~99 的值串用
    func setMode(_ newMode: BCProtocol.Mode) {
        guard newMode != mode else { return }
        noteInteraction()
        stopAll()
        mode = newMode
    }

    /// 技能 tab：发官方预设（0x06）
    func selectPreset(_ preset: BCProtocol.Preset) {
        cancelGlide()
        noteInteraction()
        outputSinceStop = true
        pendingWork?.cancel()
        pendingWork = nil
        selectedPreset = preset.key
        channels = preset.channels.map(Double.init)
        ble?.send(frame: BCProtocol.modeFrame(channels: preset.channels))
        ble?.heartbeat()
    }

    func stopAll() {
        cancelGlide()
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        selectedPreset = nil
        outputSinceStop = false
        // 停止会锁闸（M3）：下一次拖动必须是开闸的前沿帧，不能落进节流尾帧
        lastSend = -Double.infinity
        // 停止帧对：0x08 归零帧 → 100ms → 0x06 停止帧（BLEManager 统一处理）
        ble?.sendStop()
    }

    func reset() {
        cancelGlide()
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        selectedPreset = nil
        outputSinceStop = false
        lastSend = -Double.infinity
    }

    /// 召回收藏：需要时先切模式（和点模式胶囊一样先停机），再从当前值缓缓推到收藏的强度。
    /// 第一步是这次点按（send：用户操作，会开闸，照常过准入 / 额度）；后面的步骤走 sendThrottled，不开闸：
    /// 中途任何停止（用户停止、看门狗、上限、输出被拒、断开、退后台）锁了闸，后面的步骤都会被 BLEManager 丢掉，
    /// 而且 stopAll / reset 会立刻作废缓推。强度已经按模式范围夹过（FavoriteSetting.clampedLevels）
    func applyFavorite(_ fav: FavoriteSetting) {
        guard let target = fav.clampedLevels, let favMode = fav.mode else { return }
        // 正在输出时召回别的模式：切模式要先停机并等确认。
        // 界面上这类收藏已锁住，这里再兜一次底：什么也不做（不发任何帧，也不停机）
        if favMode != mode, ble?.safety.runRemaining != nil { return }
        noteInteraction()
        if favMode != mode {
            stopAll()
            mode = favMode
        }
        cancelGlide()
        pendingWork?.cancel()
        pendingWork = nil
        outputSinceStop = true
        let from = channels.map { Int($0) }
        let plan = FavoriteGlide.plan(from: from, to: target, maxLevel: favMode.maxLevel)
        runGlide(plan, index: 0, gen: glideGen, mode: favMode)
    }

    private func cancelGlide() {
        glideGen += 1
        glideWork?.cancel()
        glideWork = nil
        isGliding = false
    }

    private func runGlide(_ plan: [[Int]], index: Int, gen: Int, mode stepMode: BCProtocol.Mode) {
        guard gen == glideGen, stepMode == mode, index < plan.count else { return }
        isGliding = true
        let lv = plan[index]
        channels = lv.map(Double.init)
        // 重复档位只等待，不重复写入；计时步骤不合并，变频的小量程也保留缓推用时。
        if index == 0 || lv != plan[index - 1] {
            lastSend = ProcessInfo.processInfo.systemUptime
            let frame = stepMode.frame(channels: lv)
            if index == 0 {
                ble?.send(frame: frame)
            } else {
                ble?.sendThrottled(frame: frame)
            }
        }
        ble?.heartbeat()
        guard index + 1 < plan.count else {
            glideWork = nil
            isGliding = false
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runGlide(plan, index: index + 1, gen: gen, mode: stepMode)
        }
        glideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FavoriteGlide.stepInterval, execute: work)
    }

    /// 后缘节流：120ms 内只发一帧，但最后一次的值一定补发（降强度不能丢）
    private func scheduleSend() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSend
        if elapsed >= Self.throttleInterval {
            lastSend = now
            pendingWork?.cancel()
            pendingWork = nil
            sendNow()
        } else {
            pendingWork?.cancel()
            let snapshot = channels
            let snapMode = mode
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastSend = ProcessInfo.processInfo.systemUptime
                // 延迟帧走 sendThrottled：不断开输出闸门。
                // 停机/断开后这帧会被丢掉，避免"停止帧之后又来一帧非零"（修 N2）
                self.ble?.sendThrottled(frame: snapMode.frame(channels: snapshot.map { Int($0) }))
                self.ble?.heartbeat()
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.throttleInterval - elapsed),
                execute: work
            )
        }
    }

    private func sendNow() {
        ble?.send(frame: mode.frame(channels: channels.map { Int($0) }))
        ble?.heartbeat()
    }
}

/// rhythm-phase P2：FFA2 通知的被动观察（NotifyPeriodProbe 的界面壳）。只记录收到的通知、最多每秒算一次摘要；
/// 不发帧、不改 BLEManager。用来在真机上判断 FFA2 有没有带位置 / 行程信息（docs/rhythm-calibration.md）
final class NotifyProbeMonitor: ObservableObject {
    @Published private(set) var summary = "FFA2 观察：还没有收到通知"
    private var probe = NotifyPeriodProbe()
    private var lastRefresh: TimeInterval = -.infinity

    func note(_ hex: String) {
        let now = ProcessInfo.processInfo.systemUptime
        probe.add(time: now, hex: hex)
        guard now - lastRefresh >= 1 else { return }
        lastRefresh = now
        let text = NotifyPeriodProbe.summary(probe.report(now: now))
        if text != summary { summary = text }
    }
}

/// 手感：两通道强度滑杆 / 技能 / 变频 + 常驻停止
struct ManualControlView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var privacy: PrivacyLock
    @StateObject private var vm = ManualControlVM()
    @StateObject private var favorites = FavoriteStore()
    /// rhythm-phase P2：FFA2 通知的被动周期观察（只显示，不参与控制）
    @StateObject private var notifyProbe = NotifyProbeMonitor()
    /// 「隐私与设备」默认收起：面容 ID 开关、最后一帧、FFA2、版本都不抢主角
    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var modeFooter: String {
        switch vm.mode {
        case .skill: return "五种官方节奏，轻点一下就开始"
        case .frequency: return "九档起伏，一档一档慢慢推上去"
        case .manual: return "细腻到每一分，0~99 任你拿捏"
        }
    }

    /// 设备详情里的协议说明（原来写在模式下面）
    private var modeProtocolNote: String {
        switch vm.mode {
        case .skill: return "技能：官方五个固定预设，0x06 帧"
        case .frequency: return "变频：每通道 0~9，0x06 帧"
        case .manual: return "手动：每通道 0~99，0x08 帧"
        }
    }

    private var currentLevels: [Int] { vm.channels.map { Int($0) } }

    /// 收藏为什么现在点不了（和 canOutput 同一组条件，只是把原因说出来）
    private var favoritesBlockReason: String? {
        if ble.state != .ready { return "连上设备后，点一下就回到收藏的手感" }
        return ble.safety.blockReason
    }

    /// 收藏卡片能不能点（纯展示；applyFavorite 和 BLEManager 另有兜底）
    private var recallRules: FavoriteRecallRules {
        FavoriteRecallRules(mode: vm.mode, levels: currentLevels, canOutput: canOutput,
                            blockReason: favoritesBlockReason, running: ble.safety.runRemaining != nil)
    }

    /// 空闲停机说明只在它管得着的时候出现：正在输出，或者刚因为空闲停了
    private var showsIdleNote: Bool {
        vm.idleNotice != nil || ble.safety.runRemaining != nil
    }

    private var isConnected: Bool { ble.state == .ready }

    /// 普通未连接 / 扫描状态由邀请卡片说明；任何安全提示仍直接显示，不挂动画。
    private var showsDeviceStatus: Bool {
        isConnected || ble.lastError != nil || ble.safety.needsPhysicalAck ||
        ble.safety.blockReason != nil || ble.safety.stopRetrying ||
        ble.state == .disconnecting || ble.forceDisconnectOffered
    }

    /// 连上了且现在允许开始/继续输出（额度、锁存、停止未确认时禁用；停止按钮不受影响）
    private var canOutput: Bool {
        ble.state == .ready && ble.safety.blockReason == nil
    }

    /// 版本号 + 构建提交（修 L14：CI 构建时写入 BCGitCommit）
    private var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["BCGitCommit"] as? String ?? "").prefix(7)
        return commit.isEmpty ? "版本 \(ver) (\(build))" : "版本 \(ver) (\(build)) · \(commit)"
    }

    /// 界面上的"热度"（0~1）：只是滑杆/技能的当前值，用来驱动光晕，不代表设备回执
    private var heat: Double {
        let maxLevel = Double(vm.mode.maxLevel)
        guard maxLevel > 0 else { return 0 }
        let peak = BCProtocol.Channel.uiChannels.map { vm.channels[$0.rawValue] }.max() ?? 0
        return min(1, max(0, peak / maxLevel))
    }

    var body: some View {
        // 页头问候和连接卡片的邀请用同一次取到的时段：跨过整点时两句不会一个说午后、一个说傍晚
        let daypart = Velvet.Daypart()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "手感", subtitle: daypart.greeting)

                // 连接键在下面的邀请卡片上（未连接时）；设备卡片只管状态、红字、解除锁定和断开
                if showsDeviceStatus {
                    DeviceStatusCard(allowDisconnect: true, connectTitle: "连接设备", showsConnect: false)
                }

                // 连上之前由邀请卡片负责连接；连上后才显示心、模式和滑杆
                VStack(alignment: .leading, spacing: 18) {
                    if isConnected {
                        connectedContent
                            .transition(.opacity)
                    } else {
                        ConnectHero(favoriteCount: favorites.items.count, daypart: daypart)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isConnected)

                // 连接前也能查看、重命名、删除；召回仍由 rules 锁住。只保留一份收藏区。
                FavoritesSection(store: favorites, rules: recallRules, isGliding: vm.isGliding, isConnected: isConnected) {
                    vm.applyFavorite($0)
                }

                settingsCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(VelvetBackground(glow: heat).ignoresSafeArea())
        // 停止常驻底部：不随内容滚走，一下就停。任何连接状态下都可以点（修：之前未连接 / 断开中时被禁用，
        // 断开流程里停止正在退避时，点停止本可以立刻整对重发；没有链路时 sendStop 本身什么也不发）
        .safeAreaInset(edge: .bottom) {
            StopDockBar { vm.stopAll() }
        }
        // 修 CC r2 L7：attach 挂在整个页面上，与 detach 对称；设备区块滚出屏幕也能重新挂上
        .onAppear { vm.attach(ble: ble) }
        // 切走 Tab 时停机：避免滑杆显示 50、设备实际跟视频走的不一致（修 #6 的小尾巴）
        .onDisappear {
            vm.stopAll()
            vm.detach()
        }
        // 解锁页上的停止：和本页停止键同一个 stopAll
        .onReceive(privacy.stopAllRequested) { _ in vm.stopAll() }
        // P2：每条 FFA2 通知记一笔（只读 lastNotifyHex，不发任何帧）
        .onReceive(ble.$lastNotifyHex) { notifyProbe.note($0) }
    }

    /// 连上之后：心、模式、滑杆（主角，尽量不用滚动就够得着）、空闲说明
    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeatCore(heat: heat, active: true)
                .frame(maxWidth: .infinity)

            modeSection

            // 空闲停机说明紧跟在滑杆下面：它说的就是这几根滑杆。动画只挂在这一小块上
            VStack(alignment: .leading, spacing: 12) {
                controlsSection
                if showsIdleNote {
                    idleNote
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsIdleNote)
        }
    }

    /// 技能 / 变频 / 手动 的切换和一句说明
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModeSelector(selection: vm.mode) { vm.setMode($0) }
                .disabled(ble.state != .ready)
            Text(modeFooter)
                .font(.caption)
                .foregroundColor(Velvet.textSecondary)
                .padding(.horizontal, 6)
                .id(vm.mode)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: vm.mode)
    }

    /// 技能卡片，或两个通道的滑杆
    @ViewBuilder private var controlsSection: some View {
        if vm.mode == .skill {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "官方技能", systemImage: "sparkles")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(BCProtocol.presets) { p in
                        PresetTile(preset: p, selected: vm.selectedPreset == p.key) {
                            vm.selectPreset(p)
                            Haptics.soft()
                        }
                        .disabled(!canOutput)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "通道强度（0~\(vm.mode.maxLevel)）", systemImage: "slider.horizontal.3")
                // 修 N5：旋转通道不显示（协议里恒发 0）
                ForEach(BCProtocol.Channel.uiChannels, id: \.rawValue) { ch in
                    ChannelControl(channel: ch,
                                   value: vm.channels[ch.rawValue],
                                   maxLevel: vm.mode.maxLevel) { vm.setChannel(ch.rawValue, $0) }
                        .disabled(!canOutput)
                }
            }
        }
    }

    /// 空闲提示（原停止区块的 footer）：停止键本身常驻在底部
    private var idleNote: some View {
        HStack(alignment: .top, spacing: 6) {
            if let notice = vm.idleNotice {
                Image(systemName: "moon.zzz.fill")
                Text(notice)
            } else {
                Image(systemName: "clock")
                Text("\(Int(ManualControlVM.idleTimeout / 60)) 分钟没有操作会自动停止")
            }
        }
        .font(.caption)
        .foregroundColor(vm.idleNotice != nil ? Velvet.warning : Velvet.textSecondary)
        .padding(.horizontal, 6)
    }

    /// 收起时的一句概要：不展开也知道隐私保护开着没有
    private var settingsSummary: String {
        if privacy.biometricEnabled {
            let name: String = privacy.biometry?.name ?? "面容 ID"
            return "打开时用\(name)解锁 · 后台自动模糊"
        }
        return "后台自动模糊 · 可开启面容 ID 解锁"
    }

    /// 隐私与设备（点标题展开）：面容 ID 开关、最后一帧、FFA2 通知、协议说明、版本。
    /// 隐私提示（privacy.message）不收起，任何时候都看得到
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showDetails.toggle() }
                Haptics.select()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(title: "隐私与设备", systemImage: "eye.slash")
                        Text(settingsSummary)
                            .font(.caption)
                            .foregroundColor(Velvet.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Velvet.gold.opacity(0.9))
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("隐私与设备，\(settingsSummary)")
            .accessibilityValue(showDetails ? "已展开" : "已收起")
            .accessibilityHint("面容 ID 解锁、最后一帧、设备通知和版本号")
            if let m = privacy.message {
                Text(m)
                    .font(.caption)
                    .foregroundColor(Velvet.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showDetails {
                privacyControls
                    .transition(.opacity)
                Divider().overlay(Velvet.stroke)
                deviceDetailRows
                    .transition(.opacity)
            }
        }
        .velvetCard()
    }

    @ViewBuilder private var privacyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 已开启时即使生物识别暂不可用也保留开关，随时能关掉
            if privacy.biometry != nil || privacy.biometricEnabled {
                // 打开开关会弹系统验证框（失败时是全屏密码页），会盖住底部停止键：
                // 输出中、断开中或设备需要处理时不许改
                Toggle(isOn: Binding(get: { privacy.biometricEnabled },
                                     set: { privacy.setBiometric($0) })) {
                    Text("打开 App 时用\(privacy.biometry?.name ?? "面容 ID")解锁").foregroundColor(Velvet.text)
                }
                .tint(Velvet.rose)
                .disabled(ble.privacyCoverBlocked)
                if ble.privacyCoverBlocked {
                    Text("输出中或设备需要处理时不能更改，先停止")
                        .font(.caption)
                        .foregroundColor(Velvet.textMuted)
                }
            }
            Text("切到后台或多任务界面时，画面会自动模糊。")
                .font(.caption)
                .foregroundColor(Velvet.textMuted)
        }
    }

    private var deviceDetailRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最后一帧")
                .font(.caption2.weight(.semibold))
                .foregroundColor(Velvet.textSecondary)
            Text(ble.lastSentHex)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Velvet.textSecondary)
            Text("仅在收到写入回执后更新（链路层回执，不代表设备已执行）")
                .font(.caption2).foregroundColor(Velvet.textMuted)
            // 修 L1：FFA2 通知原样显示（含义未知，只记录）
            Text("设备通知（FFA2）：\(ble.lastNotifyHex)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(Velvet.textMuted)
            // rhythm-phase P2：最近 20 秒通知的周期分析（标定用：固定伸缩档位跑 10 秒，看有没有和往复同频的字节）
            Text(notifyProbe.summary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(Velvet.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Text(modeProtocolNote)
                .font(.caption2).foregroundColor(Velvet.textMuted)
            Text("旋转通道官方 mizzzee 配置未使用，已隐藏（恒发 0）")
                .font(.caption2).foregroundColor(Velvet.textMuted)
            Text(versionText)
                .font(.caption2).foregroundColor(Velvet.textMuted)
        }
    }
}

/// 未连接时的主角：一团慢慢呼吸的光、一句话、一个大大的连接键（连接中 / 没连上 / 断开中各有各的说法）。
/// 只调 ble.startScan()，和设备卡片上原来的连接键是同一个入口
private struct ConnectHero: View {
    @EnvironmentObject var ble: BLEManager
    let favoriteCount: Int
    /// 页头那句问候用的同一个时段（由手感页传进来）
    let daypart: Velvet.Daypart
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    private var busy: Bool {
        ble.state == .scanning || ble.state == .connecting || ble.state == .discovering
    }

    private var title: String {
        switch ble.state {
        case .scanning, .connecting, .discovering: return "正在找你的它…"
        case .failed: return "这次没连上"
        case .disconnecting: return "正在断开…"
        // 跟页头的问候同一个时段（同一次取值），但换一句接话，不重复页头的开头
        case .idle, .ready: return daypart.connectInvite
        }
    }

    private var message: String {
        switch ble.state {
        case .scanning, .connecting, .discovering: return "让设备开着机、靠近手机，马上就好"
        case .failed: return "确认设备已开机、电量充足、就在手机旁边，再试一次"
        case .disconnecting: return "等设备确认停下；需要你处理时，上面的设备卡片会说明"
        case .idle, .ready: return "打开设备电源，放在手机旁边，轻点下面就好"
        }
    }

    private var buttonTitle: String {
        if busy { return ble.state.rawValue }
        return ble.state == .failed ? "再试一次" : "连接设备"
    }

    var body: some View {
        VStack(spacing: 18) {
            orb
            VStack(spacing: 6) {
                Text(title)
                    .font(Velvet.display(.title2))
                    .foregroundColor(Velvet.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(Velvet.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 断开中不给连接键：断开流程（含停止确认）走完之前不开始新的连接
            if ble.state != .disconnecting {
                Button {
                    ble.startScan()
                } label: {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        Text(buttonTitle)
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(busy)
            }
            if favoriteCount > 0 {
                Label("你收藏的 \(favoriteCount) 组手感，连上后点一下就能回到", systemImage: "heart.fill")
                    .font(.caption)
                    .foregroundColor(Velvet.blush)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .velvetCard(padding: 20)
        .onAppear { startBreathing() }
        // 中途打开减弱动态效果：正在循环的呼吸立刻停下；关掉时再呼吸起来
        .onChange(of: reduceMotion) { rm in
            if rm {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { glow = false }
            } else {
                startBreathing()
            }
        }
    }

    /// 只在没在呼吸时起动画：切走再回来不叠一层 repeatForever
    private func startBreathing() {
        guard !reduceMotion, !glow else { return }
        withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) { glow = true }
    }

    private var orb: some View {
        let scale: CGFloat = glow ? 1.06 : 0.94
        return ZStack {
            Circle()
                .fill(RadialGradient(colors: [Velvet.rose.opacity(0.5), .clear],
                                     center: .center, startRadius: 0, endRadius: 70))
                .frame(width: 140, height: 140)
                .scaleEffect(scale)
            Circle()
                .fill(RadialGradient(colors: [Velvet.blush.opacity(0.85), Velvet.rose.opacity(0.8), Velvet.wine.opacity(0.9)],
                                     center: .center, startRadius: 2, endRadius: 40))
                .frame(width: 76, height: 76)
                .shadow(color: Velvet.rose.opacity(0.5), radius: 18)
            Image(systemName: "heart.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(height: 140)
        .accessibilityHidden(true)
    }
}

/// 中央的"心"：随热度呼吸，热度越高越快越亮（纯展示）
private struct HeatCore: View {
    let heat: Double
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 热度为 0 时停住不画（连着也不空转，省电）；减弱动态效果时一直静止
        let interval: Double = 1.0 / 30.0
        let displayedHeat: Int = Int((heat * 100.0).rounded())
        TimelineView(.animation(minimumInterval: interval, paused: reduceMotion || heat == 0)) { ctx in
            let t: Double = ctx.date.timeIntervalSinceReferenceDate
            // 空闲时 0.2 Hz 慢呼吸，满热度约 1.6 Hz
            let freq: Double = 0.2 + 1.4 * heat
            let angle: Double = t * 2.0 * Double.pi * freq
            let wave: Double = reduceMotion ? 0.0 : sin(angle)
            let breatheStrength: Double = 0.6 + heat
            let breatheAmount: Double = 0.035 * wave * breatheStrength
            let breathe: CGFloat = CGFloat(1.0 + breatheAmount)
            let ringStrength: Double = 0.5 + heat
            let ringBaseOpacity: Double = 0.10 + 0.25 * heat
            let blushOpacity: Double = 0.55 + 0.4 * heat
            let roseOpacity: Double = 0.55 + 0.35 * heat
            let shadowOpacity: Double = 0.25 + 0.5 * heat
            let shadowRadius: Double = 18.0 + 26.0 * heat
            let shadowSize: CGFloat = CGFloat(shadowRadius)
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let ringNumber: Double = Double(i + 1)
                    let ringOpacity: Double = ringBaseOpacity / ringNumber
                    let ringSize: CGFloat = 118.0 + CGFloat(i) * 26.0
                    let ringAmount: Double = 0.02 * wave * ringNumber * ringStrength
                    let ringScale: CGFloat = 1.0 + CGFloat(ringAmount)
                    Circle()
                        .stroke(Velvet.rose.opacity(ringOpacity), lineWidth: 1)
                        .frame(width: ringSize, height: ringSize)
                        .scaleEffect(ringScale)
                }
                Circle()
                    .fill(RadialGradient(colors: [Velvet.blush.opacity(blushOpacity),
                                                  Velvet.rose.opacity(roseOpacity),
                                                  Velvet.wine.opacity(0.9)],
                                         center: .center, startRadius: 4, endRadius: 60))
                    .frame(width: 112, height: 112)
                    .shadow(color: Velvet.rose.opacity(shadowOpacity), radius: shadowSize)
                    .scaleEffect(breathe)
                VStack(spacing: 0) {
                    Text("\(displayedHeat)")
                        .font(Velvet.serif(34, .light))
                        .monospacedDigit()
                        .foregroundColor(.white)
                    Text(mood)
                        .font(.caption2.weight(.semibold))
                        .tracking(3)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            // 比原来矮一截（220 → 176）：小屏上第一根滑杆不用滚动就够得着
            .frame(height: 176)
            .opacity(active ? 1 : 0.55)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("热度 \(displayedHeat)，\(mood)")
    }

    private var mood: String { HeatMood.word(for: heat) }
}

/// 技能 / 变频 / 手动 的切换胶囊
private struct ModeSelector: View {
    let selection: BCProtocol.Mode
    let onSelect: (BCProtocol.Mode) -> Void
    @Namespace private var ns
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BCProtocol.Mode.allCases) { m in
                Button {
                    guard m != selection else { return }
                    onSelect(m)
                    Haptics.select()
                } label: {
                    Text(m.title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundColor(selection == m ? Color.white : Velvet.textSecondary)
                        .background {
                            if selection == m {
                                Capsule()
                                    .fill(Velvet.roseGradient)
                                    .matchedGeometryEffect(id: "mode", in: ns)
                                    .shadow(color: Velvet.rose.opacity(0.4), radius: 8)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == m ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Velvet.stroke, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selection)
    }
}

/// 一个通道：名字、大号数值、系统滑杆（染通道色）、变频档位点
private struct ChannelControl: View {
    let channel: BCProtocol.Channel
    let value: Double
    let maxLevel: Int
    let onChange: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled
    /// 数值跟着动态字体放大（低视力用户也要读得到当前强度）
    @ScaledMetric(relativeTo: .title2) private var valueFontSize: CGFloat = 30
    /// 上次触感的档位桶。拖动事件可能比渲染更密（一帧里连跳几档），
    /// 以"上次处理过的拖动"为基准，不以还没渲染回来的 value 为基准
    @State private var lastHapticBucket: Int = 0

    var body: some View {
        let color = Velvet.channel(channel)
        let normalizedValue: Double = maxLevel > 0 ? value / Double(maxLevel) : 0.0
        let frac: Double = min(1.0, max(0.0, normalizedValue))
        let shadowRadius: Double = 2.0 + 6.0 * frac
        let shadowSize: CGFloat = CGFloat(shadowRadius)
        let glowOpacity: Double = 0.28 * frac
        let strokeOpacity: Double = 0.12 + 0.35 * frac
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color, radius: shadowSize)
                Text(channel.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Velvet.text)
                Spacer()
                Text("\(Int(value))")
                    .font(Velvet.serif(valueFontSize, .light))
                    .monospacedDigit()
                    .foregroundColor(Velvet.text)
                Text("/ \(maxLevel)")
                    .font(.caption)
                    .foregroundColor(Velvet.textMuted)
            }
            Slider(value: Binding(get: { value }, set: { changed(to: $0) }),
                   in: 0...Double(maxLevel), step: 1)
                .tint(color)
                .accessibilityLabel(channel.displayName)
                .accessibilityValue("\(Int(value))，最高 \(maxLevel)")
                .onChange(of: Int(value)) { v in
                    // 缓推 / 归零这类不经 changed() 的变化：只同步触感基准，不震
                    lastHapticBucket = v / hapticBucket
                }
                .onAppear {
                    // onChange 不管初值：出现时就有的档位先记为基准，第一次拖动不多震也不少震
                    lastHapticBucket = Int(value) / hapticBucket
                }
            if maxLevel <= 9 {
                HStack(spacing: 0) {
                    ForEach(0...maxLevel, id: \.self) { i in
                        Circle()
                            .fill(i <= Int(value) && i > 0 ? color : Color.white.opacity(0.12))
                            .frame(width: 5, height: 5)
                        if i < maxLevel { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Velvet.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(RadialGradient(colors: [color.opacity(glowOpacity), .clear],
                                             center: .trailing, startRadius: 0, endRadius: 220))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(color.opacity(strokeOpacity), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.2), value: value)
    }

    /// 档位感的粒度：变频每一档、手动每 10
    private var hapticBucket: Int {
        maxLevel <= BCProtocol.maxModeLevel ? 1 : 10
    }

    /// 档位感：变频每一档、手动每 10 轻轻一下（选择触感；只在手指拖动时，停止归零不震）
    private func changed(to newValue: Double) {
        let bucket = Int(newValue) / hapticBucket
        if lastHapticBucket != bucket {
            lastHapticBucket = bucket
            Haptics.select()
        }
        onChange(newValue)
    }
}

/// 技能卡片：名字、两通道的小柱、档位
private struct PresetTile: View {
    let preset: BCProtocol.Preset
    let selected: Bool
    let action: () -> Void

    private var symbol: String {
        switch preset.key {
        case "shadow_follow": return "moon.stars.fill"
        case "wind_spin": return "tornado"
        case "phantom_follow": return "sparkles"
        case "water_ring": return "drop.fill"
        case "dragon_tail": return "flame.fill"
        default: return "sparkle"
        }
    }

    /// 和小柱一样只列界面上的两个通道
    private var levelsText: String {
        let parts: [String] = BCProtocol.Channel.uiChannels.map { (ch: BCProtocol.Channel) -> String in
            let v: Int = preset.channels.indices.contains(ch.rawValue) ? preset.channels[ch.rawValue] : 0
            return String(v)
        }
        return parts.joined(separator: " ")
    }

    /// 旁白：名字和两个通道各自的档位（同收藏卡片），不只读一串数字
    private var a11yLabel: String {
        let parts: [String] = BCProtocol.Channel.uiChannels.map { (ch: BCProtocol.Channel) -> String in
            let v: Int = preset.channels.indices.contains(ch.rawValue) ? preset.channels[ch.rawValue] : 0
            return "\(ch.displayName) \(v)"
        }
        return "\(preset.title)，" + parts.joined(separator: "，")
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Velvet.roseGradient))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.white)
                    }
                }
                Text(preset.title)
                    .font(Velvet.display(.title3))
                    .foregroundColor(.white)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(BCProtocol.Channel.uiChannels, id: \.rawValue) { ch in
                        let v: Int = preset.channels.indices.contains(ch.rawValue) ? preset.channels[ch.rawValue] : 0
                        let barHeight: CGFloat = 4.0 + CGFloat(v) * 2.4
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Velvet.channel(ch))
                            .frame(width: 6, height: barHeight)
                    }
                    Spacer()
                    Text(levelsText)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(selected ? Color.white.opacity(0.85) : Velvet.textMuted)
                }
                .frame(height: 28, alignment: .bottom)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Velvet.roseGradient) : AnyShapeStyle(Velvet.cardFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.3 : 0.09), lineWidth: 1)
            )
            .shadow(color: selected ? Velvet.rose.opacity(0.45) : .clear, radius: 14)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
