import SwiftUI
import UIKit

// Theme.swift —— 深空玻璃设计系统：几何基准 + 主题色 + 玻璃组件。
// 职责：定义全局固定的设计 token（GlassDesign）、六套主题色（AppTheme）、
//       主题存取（ThemeStore）、环境键注入与液态玻璃视图组件。
// 在整个 App 中的角色：所有视图的视觉基础层；BossAIApp 根视图注入 appTheme 环境。
// 关键设计决策：
// 1) "几何与颜色解耦"：主题切换只换颜色不换布局，保证任意主题下版式一致。
// 2) 涉及白字对比度的色值（accentDeep、inkGlyph、bannerFill）均按 WCAG 反推校准，
//    防止高饱和 accent 压白字不达标——这是可读性防呆冗余。
// 3) 明暗自适应色用 UIColor 动态提供者实现，暗/浅模式无需手动刷新。

/// 设计基准：**深空玻璃**（方案 B）
///
/// 三层结构：
/// 1. `GlassDesign` —— 全局固定的几何、间距、字体基准（**主题不再改动这些**）
/// 2. `AppTheme`    —— 主题只负责更换强调色（accent 及其派生色），布局保持一致
/// 3. 玻璃材质 token —— 毛玻璃填充、高光描边、辉光，供各视图复用
enum GlassDesign {
    /// 卡片 / 气泡圆角
    static let cardRadius: CGFloat = 16
    /// 长文最大阅读宽度
    static let messageWidth: CGFloat = 760
    /// 卡片内边距
    static let cardPadding: CGFloat = 16
    /// 额度环直径
    static let ringSize: CGFloat = 58
    /// 深空底渐变的两个端点（#070B14 → #0B1220）
    static let inkTop = Color(red: 0.027, green: 0.043, blue: 0.078)
    static let inkBottom = Color(red: 0.043, green: 0.071, blue: 0.125)
    /// 玻璃高光描边（顶部亮、底部暗）
    static let strokeHighlight = LinearGradient(
        colors: [Color.white.opacity(0.55), Color.white.opacity(0.06), Color.white.opacity(0.28)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 玻璃表面高光（叠在毛玻璃上的一层斜向反光）
    static let surfaceSheen = LinearGradient(
        colors: [Color.white.opacity(0.16), Color.white.opacity(0.02), Color.white.opacity(0.07)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// 亮色渐变上的深墨图标色：在 #22D3EE → #3B82F6 全域对比度 ≥ 4.4，
    /// 白色图标压亮青只有 1.8，因此亮底上一律改用这个深墨色。
    static let inkGlyph = Color(red: 0.016, green: 0.071, blue: 0.122)   // #04121F
}

/// 主题：**只更换颜色**。几何、间距、字体一律由 `GlassDesign` 固定，
/// 因此任意主题切换都不会改变布局节奏。
enum AppTheme: String, CaseIterable, Identifiable {
    case blue
    case graphite
    case emerald
    case violet, coral, gold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "海蓝"
        case .graphite: return "石墨"
        case .emerald: return "翡翠"
        case .violet: return "紫晶"
        case .coral: return "珊瑚"
        case .gold: return "商务金"
        }
    }

    var symbol: String {
        switch self {
        case .blue: return "drop.fill"
        case .graphite: return "circle.hexagongrid.fill"
        case .emerald: return "leaf.fill"
        case .violet: return "sparkles"
        case .coral: return "sun.max.fill"
        case .gold: return "square.stack.3d.up.fill"
        }
    }

    /// 强调色（渐变尾色）：通过根视图 .tint() 全局生效
    var accent: Color {
        switch self {
        case .blue: return Color(red: 0.231, green: 0.510, blue: 0.965)     // #3B82F6
        case .graphite: return Color(red: 0.580, green: 0.639, blue: 0.722)  // #94A3B8
        case .emerald: return Color(red: 0.063, green: 0.725, blue: 0.506)   // #10B981
        case .violet: return Color(red: 0.608, green: 0.455, blue: 0.973)    // #9B74F8
        case .coral: return Color(red: 0.957, green: 0.247, blue: 0.369)     // #F43F5E
        case .gold: return Color(red: 0.851, green: 0.467, blue: 0.024)      // #D97706
        }
    }

    /// 渐变首色：比 accent 更亮，用于「液态玻璃」高光与渐变起点
    var accentSecondary: Color {
        switch self {
        case .blue: return Color(red: 0.133, green: 0.827, blue: 0.933)      // #22D3EE
        case .graphite: return Color(red: 0.796, green: 0.835, blue: 0.882)  // #CBD5E1
        case .emerald: return Color(red: 0.204, green: 0.827, blue: 0.600)   // #34D399
        case .violet: return Color(red: 0.655, green: 0.545, blue: 0.980)    // #A78BFA
        case .coral: return Color(red: 0.984, green: 0.443, blue: 0.522)     // #FB7185
        case .gold: return Color(red: 0.984, green: 0.749, blue: 0.141)      // #FBBF24
        }
    }

    /// 主题渐变（首色 → 尾色），用于强调块、选中态、CTA
    var accentGradient: LinearGradient {
        LinearGradient(colors: [accentSecondary, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 浅底：选中态 / 标签底 / 强调区块。暗色下略高、浅色下略低，保证对比一致。
    var accentSoft: Color {
        Color(UIColor { trait in
            let alpha: CGFloat = trait.userInterfaceStyle == .dark ? 0.18 : 0.10
            return UIColor(self.accent).withAlphaComponent(alpha)
        })
    }

    /// 辉光：用于智能体头像、进度环、关键数据的发光外圈
    var glow: Color {
        Color(UIColor { trait in
            UIColor(self.accentSecondary).withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.45 : 0.22)
        })
    }

    /// **深色强调**：用于「承载白字的大色块」（实底按钮、Logo 底）。
    /// 亮色 accent 饱和度太高，白字压上去对比度只有 1.5~4.2（不达 4.5:1 标准）；
    /// 这里按 WCAG 反推的加深值，白字对比度实测 ≥ 4.6。
    var accentDeep: Color {
        switch self {
        case .blue: return Color(red: 0.196, green: 0.427, blue: 0.812)      // #326DCF
        case .graphite: return Color(red: 0.400, green: 0.439, blue: 0.498)  // #66707F
        case .emerald: return Color(red: 0.043, green: 0.502, blue: 0.349)   // #0B8059
        case .violet: return Color(red: 0.494, green: 0.329, blue: 0.878)    // #7E54E0
        case .coral: return Color(red: 0.804, green: 0.208, blue: 0.310)     // #CD354F
        case .gold: return Color(red: 0.663, green: 0.365, blue: 0.020)      // #A95D05
        }
    }

    /// 深色强调渐变（实底按钮 / Logo 底用，白字可读）
    var accentDeepGradient: LinearGradient {
        LinearGradient(colors: [accentDeep, accentDeep.opacity(0.82)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 专家横幅底：深空墨 + 主题色微染。白字对比度实测 13:1 以上。
    var bannerFill: Color {
        switch self {
        case .blue: return Color(red: 0.082, green: 0.165, blue: 0.310)      // #152A4F
        case .graphite: return Color(red: 0.161, green: 0.192, blue: 0.255)  // #293141
        case .emerald: return Color(red: 0.047, green: 0.212, blue: 0.208)   // #0C3635
        case .violet: return Color(red: 0.153, green: 0.133, blue: 0.310)    // #27224F
        case .coral: return Color(red: 0.243, green: 0.106, blue: 0.176)     // #3E1B2D
        case .gold: return Color(red: 0.220, green: 0.157, blue: 0.102)      // #38281A
        }
    }

    // MARK: 固定几何（主题不再影响布局节奏）

    var cardRadius: CGFloat { GlassDesign.cardRadius }
    var messageWidth: CGFloat { GlassDesign.messageWidth }
    var cardPadding: CGFloat { GlassDesign.cardPadding }
    /// 长文保留系统正文字体，主题身份体现在色与面上
    var fontDesign: Font.Design { .default }
    var headingDesign: Font.Design { .default }

    // MARK: 玻璃底与描边

    /// 画布（应用最底层）
    var canvas: Color { Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.027, green: 0.043, blue: 0.078, alpha: 1)   // #070B14
            : UIColor(red: 0.949, green: 0.961, blue: 0.980, alpha: 1)   // #F2F5FA
    }) }

    /// 玻璃面（侧栏、卡片、气泡底）
    var surface: Color { Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.082, blue: 0.149, alpha: 1)   // #0E1526
            : UIColor.white
    }) }

    /// 描边：暗色下发丝白光，浅色下发丝暗线
    var border: Color { Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.08)
    }) }

    /// 用户气泡底
    var userBubble: Color { accentSoft }

    /// 展示用色块（设置页主题预览）
    var swatch: Color { accent }
}

/// 主题存取（@AppStorage 字符串）。UserDefaults 单一事实源，解析失败兜底海蓝。
enum ThemeStore {
    static let key = "app_theme"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .blue
    }

    static func set(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: key)
    }
}

private struct AppThemeEnvironmentKey: EnvironmentKey { static let defaultValue = AppTheme.blue }
// 自定义环境键：任意子视图可用 @Environment(\.appTheme) 取当前主题，无需逐层传参。
extension EnvironmentValues { var appTheme: AppTheme { get { self[AppThemeEnvironmentKey.self] } set { self[AppThemeEnvironmentKey.self] = newValue } } }

// MARK: - 液态玻璃组件

/// 深空环境底：深色基底 + 两团极淡的主题辉光。
/// 毛玻璃需要有"可折射的内容"才看得出质感，这层渐变就是玻璃的底衬。
struct AmbientBackground: View {
    let theme: AppTheme

    var body: some View {
        ZStack {
            LinearGradient(colors: [GlassDesign.inkTop, GlassDesign.inkBottom],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [theme.accentSecondary.opacity(0.18), .clear],
                           center: UnitPoint(x: 0.10, y: 0.04), startRadius: 0, endRadius: 640)
            RadialGradient(colors: [theme.accent.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.94, y: 0.98), startRadius: 0, endRadius: 760)
        }
        .ignoresSafeArea()
    }
}

/// 液态玻璃面：毛玻璃 + 斜向反光 + 高光描边 + 柔和投影
struct LiquidGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(GlassDesign.surfaceSheen)
                }
            }
            .overlay { shape.strokeBorder(GlassDesign.strokeHighlight, lineWidth: 1) }
            .clipShape(shape)
            .shadow(color: .black.opacity(elevated ? 0.22 : 0),
                    radius: elevated ? 14 : 0, x: 0, y: elevated ? 6 : 0)
    }
}

extension View {
    /// 给任意可内缩形状套上液态玻璃质感（胶囊、圆角矩形、圆形均可）
    func liquidGlass<S: InsettableShape>(_ shape: S, elevated: Bool = true) -> some View {
        modifier(LiquidGlassSurface(shape: shape, elevated: elevated))
    }

    /// 10-23 原生 Liquid Glass 兼容修饰符：
    /// - iOS 26+ 使用系统 `glassEffect(.regular, in: shape)`
    /// - iOS 17–25 回退到现有 `.ultraThinMaterial` + 高光描边的毛玻璃实现
    /// 这样无需强迫所有用户升级系统，也不必完全重写现有主题组件。
    func liquidGlassCompat<S: InsettableShape>(_ shape: S, elevated: Bool = true) -> some View {
        modifier(LiquidGlassCompat(shape: shape, elevated: elevated))
    }
}

/// 原生 Liquid Glass 兼容修饰符：iOS 26+ 使用系统 glassEffect，低版本回退到现有毛玻璃。
struct LiquidGlassCompat<S: InsettableShape>: ViewModifier {
    let shape: S
    var elevated: Bool = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // 系统原生 Liquid Glass：自动处理材质、折射与高光边缘
            content.glassEffect(.regular, in: shape)
        } else {
            // iOS 17–25 兼容路径：保留现有深空玻璃风格
            content.modifier(LiquidGlassSurface(shape: shape, elevated: elevated))
        }
    }
}
