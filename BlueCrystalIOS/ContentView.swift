import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        TabView {
            NavigationView {
                ManualControlView()
            }
            .tabItem {
                Label("手动控制", systemImage: "sliders.horizontal.3")
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
