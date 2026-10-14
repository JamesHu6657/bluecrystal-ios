import SwiftUI
import LocalAuthentication

// MARK: - 18+ 入口、面容 ID 解锁、后台隐私遮罩
// 只是外观和隐私包装：不改 BLEManager 的任何状态，唯一发出去的是解锁页上的停止（和各页停止键同一个 sendStop）。
// 退后台的停止仍由 BlueCrystalIOSApp 的 scenePhase 处理。
// 设备可能仍在输出 / 停止未确认 / 有红字 / 连接或断开进行中 / 正在运行时，入口页、解锁页和系统验证框一律不出现，
// 停止和警告永远直接可达。隐私模糊是例外：只在 App 不在前台时出现，不拦点击，回到前台立刻消失。

extension BLEManager {
    /// 这时绝不盖入口页 / 解锁页、不弹系统验证框（已弹出的会被取消）。
    /// 红字也算：停止未确认（stopUnconfirmed）不在 SafetyStatus 里，只体现为 lastError；
    /// 非空闲、非已连接的状态也算（连接中、断开中、连接失败），这时安全状态可能还没刷新
    var privacyCoverBlocked: Bool {
        safety.needsPhysicalAck || safety.stopRetrying || safety.runRemaining != nil
            || forceDisconnectOffered || lastError != nil
            || (state != .idle && state != .ready)
    }
}

final class PrivacyLock: ObservableObject {
    static let consentKey = "bc.ui.adultConsent.v1"
    static let biometricKey = "bc.ui.biometricLock"

    @Published private(set) var consented: Bool
    @Published private(set) var biometricEnabled: Bool
    @Published private(set) var locked: Bool
    @Published private(set) var authenticating = false
    @Published var message: String?

    /// 正在进行的验证：设备侧需要人处理时 cancelAuthentication 把系统验证框收掉
    private var context: LAContext?

    init() {
        let d = UserDefaults.standard
        let consent = d.bool(forKey: Self.consentKey)
        let bio = d.bool(forKey: Self.biometricKey)
        consented = consent
        biometricEnabled = bio
        locked = consent && bio
    }

    /// 本机可用的生物识别名称；没有时为 nil（启动时查一次，界面每次刷新不再新建 LAContext）
    static let biometryName: String? = {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return nil }
        switch ctx.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        default: return nil
        }
    }()

    func accept(enableBiometric: Bool) {
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        consented = true
        if enableBiometric { setBiometric(true) }
    }

    /// 打开需要先验证一次（确认本人、也确认系统允许）；关闭直接生效
    func setBiometric(_ on: Bool) {
        guard on else {
            UserDefaults.standard.set(false, forKey: Self.biometricKey)
            biometricEnabled = false
            return
        }
        authenticate(reason: "开启后，打开 BlueCrystal 时需要验证") { [weak self] ok in
            guard let self = self, ok else { return }
            UserDefaults.standard.set(true, forKey: Self.biometricKey)
            self.biometricEnabled = true
        }
    }

    /// 退到后台：下次回来需要解锁。回来时不自动弹验证（回到前台的那一刻安全状态可能还没刷新，
    /// 系统验证框会盖住停止键和警告），由用户在解锁页点「解锁」
    func didEnterBackground() {
        guard consented, biometricEnabled else { return }
        locked = true
    }

    func unlock() {
        guard locked else { return }
        authenticate(reason: "解锁 BlueCrystal") { [weak self] ok in
            guard let self = self, ok else { return }
            self.locked = false
        }
    }

    /// 收掉正在显示的系统验证框（回调里是 appCancel，不提示错误，也不解锁）
    func cancelAuthentication() {
        context?.invalidate()
        context = nil
    }

    /// 用 deviceOwnerAuthentication：面容 ID 失败可以用锁屏密码，不会把人锁在外面。
    /// 本机连密码都没设、无法验证时直接放行并关闭这个开关
    private func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        guard !authenticating else { return }
        let ctx = LAContext()
        ctx.localizedCancelTitle = "取消"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            UserDefaults.standard.set(false, forKey: Self.biometricKey)
            biometricEnabled = false
            locked = false
            message = "这台 iPhone 无法验证身份（未设置锁屏密码），已关闭解锁保护"
            completion(false)
            return
        }
        authenticating = true
        message = nil
        context = ctx
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.authenticating = false
                if self.context === ctx { self.context = nil }
                if !ok, let e = error as? LAError, e.code != .userCancel, e.code != .appCancel, e.code != .systemCancel {
                    self.message = "验证没有通过，请再试一次"
                }
                completion(ok)
            }
        }
    }
}

/// 包住整个 App：内容始终挂载在下面（各页的 VM、心跳照常），上面按需盖入口页 / 解锁页 / 隐私遮罩
struct PrivacyShell<Content: View>: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lock = PrivacyLock()
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .privacyCover()
            .environmentObject(lock)
            .onChange(of: scenePhase) { phase in
                if phase == .background { lock.didEnterBackground() }
            }
            // 验证框弹着时设备侧变成需要处理：立刻收掉，停止键和警告不能被系统弹框挡住
            .onChange(of: ble.privacyCoverBlocked) { blocked in
                if blocked { lock.cancelAuthentication() }
            }
    }
}

/// 入口页 / 解锁页 / 隐私遮罩。根视图和每个弹出层（全屏视频、AI 设置、文件选择器）各挂一份：
/// 弹出层显示在根视图之上，只挂在根上盖不住它们。需要 BLEManager 和 PrivacyLock 两个环境对象
struct PrivacyCover: ViewModifier {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var lock: PrivacyLock
    @Environment(\.scenePhase) private var scenePhase

    private var showGate: Bool { !ble.privacyCoverBlocked && !lock.consented }
    private var showLock: Bool { !ble.privacyCoverBlocked && lock.consented && lock.locked }

    func body(content: Content) -> some View {
        ZStack {
            // 盖着入口页 / 解锁页时，旁白不能读到、点到下面的内容
            content
                .accessibilityHidden(showGate || showLock)

            if showGate {
                AgeGateView(lock: lock)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .transition(.opacity)
                    .zIndex(2)
            } else if showLock {
                // 解锁页只在设备不需要处理时出现；万一状态还没刷新，底部也有停止键
                LockScreenView(lock: lock) { ble.sendStop() }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lock.consented)
        .animation(.easeInOut(duration: 0.25), value: lock.locked)
        // 隐私遮罩在动画作用域之外、不带过渡：多任务截图不会截到半透明的一帧，回到前台立刻消失
        .overlay {
            if scenePhase != .active {
                PrivacyVeil()
                    .transaction { $0.animation = nil }
            }
        }
    }
}

extension View {
    func privacyCover() -> some View { modifier(PrivacyCover()) }
}

/// 后台 / 多任务界面的遮罩：真正的系统模糊，不露出任何内容；不拦点击
struct PrivacyVeil: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Velvet.ink.opacity(0.72)
            VStack(spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Velvet.roseGradient)
                Text("BlueCrystal")
                    .font(Velvet.serif(22, .semibold))
                    .foregroundColor(Velvet.text)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 18+ 确认（只出现一次）
struct AgeGateView: View {
    @ObservedObject var lock: PrivacyLock
    @State private var useBiometric = false
    @State private var glow = false
    private let biometryName = PrivacyLock.biometryName

    var body: some View {
        ZStack {
            VelvetBackground(glow: 0.35).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 26) {
                    Spacer(minLength: 40)
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [Velvet.rose.opacity(0.55), .clear],
                                                 center: .center, startRadius: 0, endRadius: 90))
                            .frame(width: 180, height: 180)
                            .scaleEffect(glow ? 1.08 : 0.92)
                        Text("18+")
                            .font(Velvet.serif(46, .semibold))
                            .foregroundStyle(LinearGradient(colors: [Velvet.text, Velvet.blush],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                    VStack(spacing: 10) {
                        Text("只属于成年人的夜晚")
                            .font(Velvet.serif(26, .semibold))
                            .foregroundColor(Velvet.text)
                        Text("BlueCrystal 用来控制成人亲密用品，内容仅面向年满 18 周岁的成年人。请在私密、安全、随手能关掉设备电源的环境里使用。")
                            .font(.subheadline)
                            .foregroundColor(Velvet.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Label("点红色「停止」（「她」页面也可以输入“停”）会立刻发送停止，设备确认后才算停下", systemImage: "stop.circle.fill")
                        Label("第一次使用前，先在不接触身体时试一次停止", systemImage: "hand.raised.fill")
                        Label("切到后台时设备自动停止，画面也会被模糊", systemImage: "eye.slash.fill")
                    }
                    .font(.footnote)
                    .foregroundColor(Velvet.textSecondary)
                    .velvetCard()

                    if let name = biometryName {
                        Toggle(isOn: $useBiometric) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("用\(name)解锁").foregroundColor(Velvet.text)
                                Text("可选：每次打开都需要验证").font(.caption).foregroundColor(Velvet.textMuted)
                            }
                        }
                        .tint(Velvet.rose)
                        .velvetCard()
                    }

                    VStack(spacing: 12) {
                        Button {
                            Haptics.soft()
                            lock.accept(enableBiometric: useBiometric)
                        } label: {
                            Text("我已年满 18 岁，进入")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        Text("未满 18 岁请关闭本应用")
                            .font(.caption)
                            .foregroundColor(Velvet.textMuted)
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 24)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

/// 面容 ID 解锁页：不自动弹验证，点「解锁」才弹；底部常驻停止键
struct LockScreenView: View {
    @ObservedObject var lock: PrivacyLock
    let onStop: () -> Void

    var body: some View {
        ZStack {
            VelvetBackground(glow: 0.2).ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Velvet.roseGradient)
                Text("只给你看")
                    .font(Velvet.serif(28, .semibold))
                    .foregroundColor(Velvet.text)
                Text("验证后继续")
                    .font(.subheadline)
                    .foregroundColor(Velvet.textSecondary)
                if let m = lock.message {
                    Text(m).font(.caption).foregroundColor(Velvet.warning).multilineTextAlignment(.center)
                }
                Button {
                    lock.unlock()
                } label: {
                    Label("解锁", systemImage: "faceid")
                        .frame(minWidth: 160, minHeight: 46)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(lock.authenticating)
                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .safeAreaInset(edge: .bottom) {
            StopDockBar(action: onStop)
        }
    }
}
