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
                // 退后台/锁屏：申请后台时间，一直持有到停止帧整条链出最终结果（最多约 4.5 秒）。
                // 设备不能停在某个强度上等人回来（修 Factory M1：不再阻塞主线程、不再 2 秒就放手）
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                ble.emergencyStop {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
            } else if phase == .active {
                // 回到前台：设备可能还在输出时补发停止帧（修 Factory M1）
                ble.resumeFromBackground()
            }
        }
    }
}
