import SwiftUI
import LocalAuthentication

// MARK: - 18+ 入口、面容 ID 解锁、后台隐私遮罩
// 只是外观和隐私包装：不发帧、不碰 BLEManager 的任何状态。退后台的停止仍由 BlueCrystalIOSApp 的 scenePhase 处理。
// 设备可能仍在输出 / 停止未确认 / 断开中 / 正在运行时，入口和解锁页一律不显示，停止和警告永远直接可达。

final class PrivacyLock: ObservableObject {
    static let consentKey = "bc.ui.adultConsent.v1"
    static let biometricKey = "bc.ui.biometricLock"

    @Published private(set) var consented: Bool
    @Published private(set) var biometricEnabled: Bool
    @Published private(set) var locked: Bool
    @Published private(set) var authenticating = false
    @Published var message: String?

    /// 每次上锁只自动弹一次面容 ID：取消后不反复弹（弹框本身会让 App 短暂离开 active）
    private var autoPrompted = false

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

    /// 退到后台：下次回来需要解锁
    func didEnterBackground() {
        guard consented, biometricEnabled else { return }
        locked = true
        autoPrompted = false
    }

    /// 回到前台：自动弹一次验证
    func autoUnlockIfNeeded() {
        guard locked, !autoPrompted, !authenticating else { return }
        autoPrompted = true
        unlock()
    }

    func unlock() {
        guard locked else { return }
        authenticate(reason: "解锁 BlueCrystal") { [weak self] ok in
            guard let self = self, ok else { return }
            self.locked = false
        }
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
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.authenticating = false
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

    /// 设备侧需要人处理的状态：这时绝不盖任何东西
    private var safetyNeedsAttention: Bool {
        ble.safety.needsPhysicalAck || ble.safety.stopRetrying || ble.safety.runRemaining != nil
            || ble.state == .disconnecting || ble.forceDisconnectOffered
    }

    var body: some View {
        ZStack {
            content()
                .environmentObject(lock)

            if !safetyNeedsAttention {
                if !lock.consented {
                    AgeGateView(lock: lock)
                        .transition(.opacity)
                        .zIndex(2)
                } else if lock.locked {
                    LockScreenView(lock: lock)
                        .transition(.opacity)
                        .zIndex(2)
                }
            }

            if scenePhase != .active {
                PrivacyVeil()
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lock.consented)
        .animation(.easeInOut(duration: 0.25), value: lock.locked)
        .animation(.easeInOut(duration: 0.2), value: scenePhase)
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                lock.didEnterBackground()
            } else if phase == .active, !safetyNeedsAttention {
                lock.autoUnlockIfNeeded()
            }
        }
        .onAppear {
            if scenePhase == .active, !safetyNeedsAttention { lock.autoUnlockIfNeeded() }
        }
    }
}

/// 后台 / 多任务界面的遮罩：真正的系统模糊（也能盖住视频播放器），不露出任何内容
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
                        Label("任何时候点红色「停止」，或说“停”，都会立刻停下", systemImage: "stop.circle.fill")
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

/// 面容 ID 解锁页
struct LockScreenView: View {
    @ObservedObject var lock: PrivacyLock

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
    }
}
