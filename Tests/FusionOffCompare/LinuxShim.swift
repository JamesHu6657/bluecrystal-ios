import Foundation
// 只在 Linux 上编译检查程序时用（swift-corelibs-foundation 没有 ProcessInfo.ThermalState）；iOS / macOS 上是空的
#if os(Linux)
extension ProcessInfo {
    enum ThermalState: Int { case nominal = 0, fair, serious, critical }
}
#endif
