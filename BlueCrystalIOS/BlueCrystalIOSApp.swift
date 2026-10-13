import SwiftUI
import UIKit

@main
struct BlueCrystalIOSApp: App {
    @StateObject private var ble = BLEManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                // 退后台/锁屏：申请一点后台时间，尽力把停止帧发出去
                // 设备不能停在某个强度上等人回来
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                ble.emergencyStop()
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
    }
}
