import SwiftUI
import UIKit

// MARK: - 视觉语言「午夜丝绒」：近黑的梅子色底、玫瑰与香槟金的微光、衬线标题、呼吸般的动效。
// 只管外观，不碰任何输出 / 安全逻辑。

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

enum Velvet {
    static let ink = Color(hex: 0x0E0710)
    static let plum = Color(hex: 0x1C0B1A)
    static let wine = Color(hex: 0x4A1236)
    static let rose = Color(hex: 0xF0507E)
    static let blush = Color(hex: 0xFFB8CB)
    static let gold = Color(hex: 0xE9C08A)

    static let text = Color(hex: 0xF8ECF1)
    /// 次要 / 弱化文字：深色底上弱化文字也要 ≥4.5:1（小字号说明、提示都用它）
    static let textSecondary = Color(hex: 0xF8ECF1, alpha: 0.74)
    static let textMuted = Color(hex: 0xF8ECF1, alpha: 0.6)
    static let cardFill = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.09)

    /// 停止 / 危险：纯正的红，和玫瑰色强调色明显区分
    static let danger = Color(hex: 0xFF3346)
    static let warning = Color(hex: 0xFFB04A)
    static let ok = Color(hex: 0x7BE3B6)

    static let roseGradient = LinearGradient(colors: [Color(hex: 0xFF6F98), Color(hex: 0xC2306A)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let stopGradient = LinearGradient(colors: [Color(hex: 0xFF4A5A), Color(hex: 0xD3172C)],
                                             startPoint: .top, endPoint: .bottom)

    /// 通道颜色（伸缩 玫瑰 / 震动 琥珀 / 吮吸 紫罗兰）：深色底上做过色觉辨识校验，各处统一
    static func channel(_ ch: BCProtocol.Channel) -> Color {
        switch ch {
        case .thrust: return Color(hex: 0xF0507E)
        case .vibration: return Color(hex: 0xC08428)
        case .suction: return Color(hex: 0x9575F0)
        case .rotation: return textMuted
        }
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - 触感

enum Haptics {
    static func stop() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - 背景：缓慢漂移的两团光，glow（0~1）越高越亮

struct VelvetBackground: View {
    var glow: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                LinearGradient(colors: [Velvet.plum, Velvet.ink], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Velvet.rose.opacity(0.30 + 0.35 * glow), .clear],
                               center: .center, startRadius: 0, endRadius: max(w, h) * 0.55)
                    .frame(width: w * 1.4, height: w * 1.4)
                    .offset(x: drift ? w * 0.28 : -w * 0.18, y: drift ? -h * 0.30 : -h * 0.18)
                RadialGradient(colors: [Velvet.wine.opacity(0.75), .clear],
                               center: .center, startRadius: 0, endRadius: max(w, h) * 0.5)
                    .frame(width: w * 1.5, height: w * 1.5)
                    .offset(x: drift ? -w * 0.30 : w * 0.10, y: drift ? h * 0.32 : h * 0.20)
                RadialGradient(colors: [Velvet.gold.opacity(0.08 + 0.10 * glow), .clear],
                               center: .center, startRadius: 0, endRadius: w * 0.5)
                    .frame(width: w, height: w)
                    .offset(x: drift ? w * 0.05 : w * 0.25, y: drift ? h * 0.05 : -h * 0.05)
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .animation(.easeInOut(duration: 1.2), value: glow)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 卡片 / 标题

struct VelvetCard: ViewModifier {
    var padding: CGFloat = 16
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Velvet.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill((tint ?? .clear).opacity(0.10))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.03)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 1)
            )
    }
}

extension View {
    func velvetCard(padding: CGFloat = 16, tint: Color? = nil) -> some View {
        modifier(VelvetCard(padding: padding, tint: tint))
    }
}

/// 卡片里的小标题（原来的 Section 标题）
struct SectionLabel: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let s = systemImage {
                Image(systemName: s).font(.system(size: 11, weight: .semibold))
            }
            Text(title).font(.footnote.weight(.semibold)).tracking(1.5)
        }
        .foregroundColor(Velvet.gold.opacity(0.9))
    }
}

/// 页面大标题：衬线字 + 一句低语
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Velvet.serif(34, .semibold))
                    .foregroundStyle(LinearGradient(colors: [Velvet.text, Velvet.blush],
                                                    startPoint: .leading, endPoint: .trailing))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(Velvet.textSecondary)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.top, 8)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - 按钮

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // 大字号下最多两行再缩小一点，不截断安全相关的按钮文字；高度至少 44pt
            configuration.label
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(minHeight: 44)
                .foregroundColor(kind == .secondary ? Velvet.text : .white)
                .background(background)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(kind == .secondary ? 0.14 : 0), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
        }

        @ViewBuilder private var background: some View {
            switch kind {
            case .primary: Velvet.roseGradient
            case .secondary: Color.white.opacity(0.07)
            case .danger: Velvet.stopGradient
            }
        }
    }
}

/// 只做按下缩放的样式（大块的自定义按钮用）
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }

    private struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// 常驻底部的大停止键：一下就停。动作先执行，触感在后，不给停止路径加任何延迟
struct StopDock: View {
    var title = "停止"
    let action: () -> Void

    var body: some View {
        Button(role: .destructive) {
            action()
            Haptics.stop()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stop.fill").font(.system(size: 17, weight: .black))
                Text(title).font(.system(size: 19, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(Velvet.stopGradient))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Velvet.danger.opacity(0.45), radius: 14, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("停止")
    }
}

/// 底部停止键的容器：一层渐隐的底色，不挡住内容
struct StopDockBar: View {
    var title = "停止"
    let action: () -> Void

    var body: some View {
        StopDock(title: title, action: action)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                LinearGradient(colors: [Velvet.ink.opacity(0), Velvet.ink.opacity(0.92)],
                               startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
            )
    }
}

// MARK: - 状态小光点

struct StatusOrb: View {
    let color: Color
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                PulseRing(color: color)
            }
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.9), radius: 5)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private struct PulseRing: View {
        let color: Color
        @State private var expanded = false

        var body: some View {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 12, height: 12)
                .scaleEffect(expanded ? 2.0 : 1)
                .opacity(expanded ? 0 : 1)
                .onAppear {
                    withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
                }
        }
    }
}
