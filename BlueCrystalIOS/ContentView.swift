import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        TabView {
            NavigationView {
                ManualControlView()
            }
            .tabItem {
                Label("手动控制", systemImage: "slider.horizontal.3")
            }

            NavigationView {
                VideoSyncView()
            }
            .tabItem {
                Label("视频联动", systemImage: "play.rectangle")
            }
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

/// 两个 Tab 共用的"设备"区块：连接状态、红字、安全状态（单次上限 / 冷却 / 额度）、锁存解除、强制断开
struct DeviceStatusSection: View {
    @EnvironmentObject var ble: BLEManager
    var allowDisconnect: Bool
    var connectTitle: String
    @State private var confirmForceDisconnect = false
    @State private var confirmPhysicalAck = false

    var body: some View {
        Section("设备") {
            HStack {
                Text(ble.state.rawValue)
                    .foregroundColor(ble.state == .ready ? .green : .secondary)
                Spacer()
                if ble.state == .ready {
                    if allowDisconnect {
                        Button("断开") { ble.disconnect() }
                    }
                } else if ble.state == .disconnecting {
                    // 修 M5：停止迟迟确认不了时才提供，且必须在警告框里再确认一次
                    if ble.forceDisconnectOffered {
                        Button("强制断开", role: .destructive) { confirmForceDisconnect = true }
                    }
                } else {
                    Button(connectTitle) { ble.startScan() }
                        .disabled(ble.state == .scanning || ble.state == .connecting || ble.state == .discovering)
                }
            }
            // 修 L12：行内按钮用 borderless，点状态文字不会触发按钮
            .buttonStyle(.borderless)
            .alert("强制断开？", isPresented: $confirmForceDisconnect) {
                Button("强制断开", role: .destructive) { ble.forceDisconnect() }
                Button("继续重试", role: .cancel) {}
            } message: {
                Text("停止还没有得到设备确认，设备可能仍在输出。强制断开后 App 无法再停止它，请立即关闭设备电源。")
            }
            if let err = ble.lastError {
                Text(err).font(.caption).foregroundColor(.red)
            }
            // 修 M4 / L5：锁存期间拒绝输出，只有用户确认已物理关机才解除
            if ble.safety.needsPhysicalAck {
                Button("已物理关机，解除锁定", role: .destructive) { confirmPhysicalAck = true }
                    .buttonStyle(.borderless)
                    .alert("确认设备已停止？", isPresented: $confirmPhysicalAck) {
                        Button("已关机，解除锁定", role: .destructive) { ble.acknowledgePhysicalStop() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("只有在你已经关闭设备电源、确认设备不再输出时才解除。解除后 App 才允许再次输出。")
                    }
            }
            // 修 M2/M3：单次上限、冷却、30 分钟额度
            Text(ble.safety.summary)
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
