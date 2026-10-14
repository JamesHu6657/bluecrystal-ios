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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatusOrb(color: orbColor, pulsing: isBusy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ble.state.rawValue)
                        .font(.headline)
                        .foregroundColor(ble.state == .ready ? Velvet.ok : Velvet.text)
                    Text(BLEManager.deviceName)
                        .font(.caption)
                        .foregroundColor(Velvet.textMuted)
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
                } else {
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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundColor(Velvet.danger)
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

            // 修 M2/M3：单次上限、冷却、30 分钟额度
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ble.safety.blockReason == nil ? "hourglass" : "lock.fill")
                Text(ble.safety.summary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundColor(ble.safety.blockReason == nil ? Velvet.textSecondary : Velvet.warning)
        }
        .velvetCard(tint: ble.lastError != nil || ble.safety.needsPhysicalAck ? Velvet.danger : nil)
    }
}
