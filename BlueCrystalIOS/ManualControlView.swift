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
        guard mode != .skill else { return }
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
        pendingWork?.cancel()
        pendingWork = nil
        channels = [0, 0, 0, 0]
        selectedPreset = nil
        outputSinceStop = false
        lastSend = -Double.infinity
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

/// 手感：三通道强度滑杆 / 技能 / 变频 + 常驻停止
struct ManualControlView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var privacy: PrivacyLock
    @StateObject private var vm = ManualControlVM()

    private var modeFooter: String {
        switch vm.mode {
        case .skill: return "官方 App 的五个固定技能，0x06 帧"
        case .frequency: return "官方变频：每通道 0~9，0x06 帧"
        case .manual: return "官方手动：每通道 0~99，0x08 帧"
        }
    }

    /// 连上了且现在允许开始/继续输出（冷却、额度、锁存、停止未确认时禁用；停止按钮不受影响）
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "手感", subtitle: "指尖的每一分力度，都会被温柔地回应")

                DeviceStatusCard(allowDisconnect: true, connectTitle: "连接 mizzzee_0032")

                HeatCore(heat: heat, active: ble.state == .ready)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    ModeSelector(selection: vm.mode) { vm.setMode($0) }
                        .disabled(ble.state != .ready)
                    Text(modeFooter)
                        .font(.caption)
                        .foregroundColor(Velvet.textMuted)
                        .padding(.horizontal, 6)
                }

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
                        Text("旋转通道官方 mizzzee 配置未使用，已隐藏（恒发 0）")
                            .font(.caption)
                            .foregroundColor(Velvet.textMuted)
                            .padding(.horizontal, 6)
                    }
                }

                // 空闲提示（原停止区块的 footer）：停止键本身常驻在底部
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

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "隐私", systemImage: "eye.slash")
                    // 已开启时即使生物识别暂不可用也保留开关，随时能关掉
                    if PrivacyLock.biometryName != nil || privacy.biometricEnabled {
                        Toggle(isOn: Binding(get: { privacy.biometricEnabled },
                                             set: { privacy.setBiometric($0) })) {
                            Text("打开 App 时用\(PrivacyLock.biometryName ?? "面容 ID")解锁").foregroundColor(Velvet.text)
                        }
                        .tint(Velvet.rose)
                    }
                    if let m = privacy.message {
                        Text(m).font(.caption).foregroundColor(Velvet.warning)
                    }
                    Text("切到后台或多任务界面时，画面会自动模糊。")
                        .font(.caption)
                        .foregroundColor(Velvet.textMuted)
                }
                .velvetCard()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "最后一帧", systemImage: "waveform.path.ecg")
                    Text(ble.lastSentHex)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(Velvet.textSecondary)
                    Text("仅在收到写入回执后更新（链路层回执，不代表设备已执行）")
                        .font(.caption2).foregroundColor(Velvet.textMuted)
                    // 修 L1：FFA2 通知原样显示（含义未知，只记录）
                    Text("设备通知（FFA2）：\(ble.lastNotifyHex)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Velvet.textMuted)
                    Text(versionText)
                        .font(.caption2).foregroundColor(Velvet.textMuted)
                }
                .velvetCard()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(VelvetBackground(glow: heat).ignoresSafeArea())
        // 停止常驻底部：不随内容滚走，一下就停（连接后可用，和原来一样）
        .safeAreaInset(edge: .bottom) {
            StopDockBar { vm.stopAll() }
                .disabled(ble.state != .ready)
        }
        // 修 CC r2 L7：attach 挂在整个页面上，与 detach 对称；设备区块滚出屏幕也能重新挂上
        .onAppear { vm.attach(ble: ble) }
        // 切走 Tab 时停机：避免滑杆显示 50、设备实际跟视频走的不一致（修 #6 的小尾巴）
        .onDisappear {
            vm.stopAll()
            vm.detach()
        }
    }
}

/// 中央的"心"：随热度呼吸，热度越高越快越亮（纯展示）
private struct HeatCore: View {
    let heat: Double
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // 空闲时 0.2 Hz 慢呼吸，满热度约 1.6 Hz
            let freq = 0.2 + 1.4 * heat
            let wave = reduceMotion ? 0 : sin(t * 2 * .pi * freq)
            let breathe = 1 + 0.035 * wave * (0.6 + heat)
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(Velvet.rose.opacity((0.10 + 0.25 * heat) / Double(i + 1)), lineWidth: 1)
                        .frame(width: 150 + CGFloat(i) * 34, height: 150 + CGFloat(i) * 34)
                        .scaleEffect(1 + CGFloat(0.02 * wave * Double(i + 1) * (0.5 + heat)))
                }
                Circle()
                    .fill(RadialGradient(colors: [Velvet.blush.opacity(0.55 + 0.4 * heat),
                                                  Velvet.rose.opacity(0.55 + 0.35 * heat),
                                                  Velvet.wine.opacity(0.9)],
                                         center: .center, startRadius: 4, endRadius: 75))
                    .frame(width: 140, height: 140)
                    .shadow(color: Velvet.rose.opacity(0.25 + 0.5 * heat), radius: 18 + 26 * heat)
                    .scaleEffect(CGFloat(breathe))
                VStack(spacing: 0) {
                    Text("\(Int((heat * 100).rounded()))")
                        .font(Velvet.serif(40, .light))
                        .monospacedDigit()
                        .foregroundColor(.white)
                    Text("热度")
                        .font(.caption2.weight(.semibold))
                        .tracking(3)
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            .frame(height: 220)
            .opacity(active ? 1 : 0.55)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("热度 \(Int((heat * 100).rounded()))")
    }
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
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

    var body: some View {
        let color = Velvet.channel(channel)
        let frac = maxLevel > 0 ? min(1, max(0, value / Double(maxLevel))) : 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color, radius: 2 + 6 * frac)
                Text(channel.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Velvet.text)
                Spacer()
                Text("\(Int(value))")
                    .font(Velvet.serif(30, .light))
                    .monospacedDigit()
                    .foregroundColor(Velvet.text)
                Text("/ \(maxLevel)")
                    .font(.caption)
                    .foregroundColor(Velvet.textMuted)
            }
            Slider(value: Binding(get: { value }, set: { onChange($0) }),
                   in: 0...Double(maxLevel), step: 1)
                .tint(color)
                .accessibilityLabel(channel.displayName)
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
                        .fill(RadialGradient(colors: [color.opacity(0.28 * frac), .clear],
                                             center: .trailing, startRadius: 0, endRadius: 220))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(color.opacity(0.12 + 0.35 * frac), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

/// 技能卡片：名字、三通道的小柱、原始档位
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
                    .font(Velvet.serif(19, .semibold))
                    .foregroundColor(.white)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(BCProtocol.Channel.uiChannels, id: \.rawValue) { ch in
                        let v = preset.channels.indices.contains(ch.rawValue) ? preset.channels[ch.rawValue] : 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Velvet.channel(ch))
                            .frame(width: 6, height: 4 + CGFloat(v) * 2.4)
                    }
                    Spacer()
                    Text(preset.channels.map(String.init).joined(separator: " "))
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
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
