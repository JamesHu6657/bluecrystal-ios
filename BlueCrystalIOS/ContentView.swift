import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        PrivacyShell {
            TabView {
                ManualControlView()
                    .velvetTab()
                    .tabItem {
                        Label("手感", systemImage: "hand.draw.fill")
                    }

                VideoSyncView()
                    .velvetTab()
                    .tabItem {
                        Label("一起看", systemImage: "play.tv.fill")
                    }

                AIControlView()
                    .velvetTab()
                    .tabItem {
                        Label("她", systemImage: "heart.text.square.fill")
                    }
            }
            .tint(Velvet.rose)
        }
        .preferredColorScheme(.dark)
        // 触感（纯反馈，不改任何状态）：连上了轻轻一下"成功"；连接失败、出现新的红字（自动停机、停止未确认等）
        // 震一下"警告"，手机不在眼前时也能感觉到发生了什么
        .onChange(of: ble.state) { s in
            if s == .ready { Haptics.success() }
            if s == .failed { Haptics.warning() }
        }
        .onChange(of: ble.lastError) { err in
            if err != nil { Haptics.warning() }
        }
        // 发现未绑定过的设备时弹确认框（防连到别人的设备）。
        // 直接用 showDeviceConfirm 做 binding：点"连接"和点"取消"走各自的方法，
        // 不会像之前那样在 set(false) 里误调 cancel 把 confirm 的设备抢掉（修 N7）。
        .alert("发现设备", isPresented: $ble.showDeviceConfirm) {
            Button("连接") { ble.confirmPendingDevice() }
            Button("取消", role: .cancel) { ble.cancelPendingDevice() }
        } message: {
            Text("发现 \(ble.pendingDeviceName ?? "")\n\(ble.pendingDeviceUUID ?? "")\n\n这台设备没有绑定过，确认是你的设备再连接。")
        }
    }
}

private extension View {
    /// 每个 Tab 的底栏：深色、半透明
    func velvetTab() -> some View {
        self
            .toolbarBackground(Velvet.ink.opacity(0.92), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)
    }
}

/// 三个 Tab 共用的"设备"卡片：连接状态、红字、安全状态（单次上限 / 冷却 / 额度）、锁存解除、强制断开
struct DeviceStatusCard: View {
    @EnvironmentObject var ble: BLEManager
    var allowDisconnect: Bool
    var connectTitle: String
    /// 紧凑版：钉在 AI 页页头（聊天自动滚到底时红字、解除锁定键和安全状态不会被带走）。
    /// 省掉设备名，安全状态挪到状态名下面；红字、解除锁定、强制断开和对话框都和完整版一样
    var compact = false
    /// 解锁页上不给连接键：一点连接，"连接中"就会撤掉解锁页
    var showsConnect = true
    /// 收起版（AI 页打字、键盘弹起时）：红字和安全状态最多两行，点红字收起键盘看全文；
    /// 解除锁定、强制断开照常显示
    var collapsed = false
    @State private var confirmForceDisconnect = false
    @State private var confirmPhysicalAck = false

    private var orbColor: Color {
        switch ble.state {
        case .ready: return Velvet.ok
        case .scanning, .connecting, .discovering: return Velvet.gold
        case .disconnecting: return Velvet.warning
        case .failed: return Velvet.danger
        case .idle: return Velvet.textMuted
        }
    }

    private var isBusy: Bool {
        ble.state == .scanning || ble.state == .connecting || ble.state == .discovering || ble.state == .disconnecting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(spacing: compact ? 8 : 12) {
                StatusOrb(color: orbColor, pulsing: isBusy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.state.rawValue)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .foregroundColor(ble.state == .ready ? Velvet.ok : Velvet.text)
                    if compact {
                        safetySummary
                    } else {
                        Text(BLEManager.deviceName)
                            .font(.caption)
                            .foregroundColor(Velvet.textMuted)
                    }
                }
                Spacer(minLength: 8)
                if ble.state == .ready {
                    if allowDisconnect {
                        Button("断开") { ble.disconnect() }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                } else if ble.state == .disconnecting {
                    // 修 M5：停止迟迟确认不了时才提供，且必须在警告框里再确认一次
                    if ble.forceDisconnectOffered {
                        Button("强制断开", role: .destructive) { confirmForceDisconnect = true }
                            .buttonStyle(PillButtonStyle(kind: .danger))
                    }
                } else if showsConnect {
                    Button(connectTitle) { ble.startScan() }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .disabled(ble.state == .scanning || ble.state == .connecting || ble.state == .discovering)
                }
            }
            .alert("强制断开？", isPresented: $confirmForceDisconnect) {
                Button("强制断开", role: .destructive) { ble.forceDisconnect() }
                Button("继续重试", role: .cancel) {}
            } message: {
                Text("停止还没有得到设备确认，设备可能仍在输出。强制断开后 App 无法再停止它，请立即关闭设备电源。")
            }

            if let err = ble.lastError {
                if collapsed {
                    Button {
                        PrivacyLock.dismissKeyboard()
                    } label: {
                        errorText(err)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("收起键盘，显示完整提示")
                } else {
                    errorText(err)
                }
            }

            // 修 M4 / L5：锁存期间拒绝输出，只有用户确认已物理关机才解除
            if ble.safety.needsPhysicalAck {
                Button(role: .destructive) {
                    confirmPhysicalAck = true
                } label: {
                    Label("已物理关机，解除锁定", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(kind: .danger))
                .alert("确认设备已停止？", isPresented: $confirmPhysicalAck) {
                    Button("已关机，解除锁定", role: .destructive) { ble.acknowledgePhysicalStop() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("只有在你已经关闭设备电源、确认设备不再输出时才解除。解除后 App 才允许再次输出。")
                }
            }

            if !compact {
                safetySummary
            }
            runMeter
        }
        .velvetCard(padding: compact ? 10 : 16,
                    tint: ble.lastError != nil || ble.safety.needsPhysicalAck ? Velvet.danger : nil)
    }

    private func errorText(_ err: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(err)
                .lineLimit(collapsed ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundColor(Velvet.danger)
    }

    /// 正在输出时：本次还剩多少的细条（纯展示；文字说明在 safetySummary 里，旁白读那一行）
    @ViewBuilder private var runMeter: some View {
        if let remaining = ble.safety.runRemaining, ble.safety.runAllowed > 0 {
            let total: Double = Double(ble.safety.runAllowed)
            let left: Double = Double(max(0, remaining))
            let frac: CGFloat = CGFloat(min(1.0, left / total))
            let warn: Bool = remaining <= 60
            GeometryReader { geo in
                let width: CGFloat = geo.size.width * frac
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(warn ? AnyShapeStyle(Velvet.warning) : AnyShapeStyle(Velvet.roseGradient))
                        .frame(width: width)
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 1), value: remaining)
            .accessibilityHidden(true)
        }
    }

    /// 修 M2/M3：单次上限、冷却、30 分钟额度
    private var safetySummary: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ble.safety.blockReason == nil ? "hourglass" : "lock.fill")
            Text(ble.safety.summary)
                .lineLimit(collapsed ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundColor(ble.safety.blockReason == nil ? Velvet.textSecondary : Velvet.warning)
    }
}
