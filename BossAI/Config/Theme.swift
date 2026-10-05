import SwiftUI
import UIKit

/// 主题：不再是单一主色，而是「主色 / 渐变次色 / 浅底」三层 token。
/// 六套主题共享语义色，字体、形状、密度、阅读宽度通过环境同步。
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

    /// 主色（强调色）：通过根视图 .tint() 全局生效
    var accent: Color {
        switch self {
        case .blue: return Color(red: 0.20, green: 0.42, blue: 0.88)
        case .graphite: return Color(red: 0.35, green: 0.37, blue: 0.42)
        case .emerald: return Color(red: 0.07, green: 0.55, blue: 0.40)
        case .violet: return .purple
        case .coral: return Color(red: 0.75, green: 0.22, blue: 0.20)
        case .gold: return Color(red: 0.56, green: 0.39, blue: 0.10)
        }
    }

    /// 渐变第二色：比主色浅/亮，用于液态玻璃按钮的渐变尾部等
    var accentSecondary: Color {
        switch self {
        case .blue: return Color(red: 0.44, green: 0.64, blue: 0.95)
        case .graphite: return Color(red: 0.55, green: 0.57, blue: 0.62)
        case .emerald: return Color(red: 0.25, green: 0.70, blue: 0.56)
        case .violet: return .indigo
        case .coral: return .orange
        case .gold: return Color(red: 0.72, green: 0.56, blue: 0.25)
        }
    }

    /// 浅底：选中态 / 标签底 / 强调区块的极浅底色
    var accentSoft: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark { return UIColor(self.accent).withAlphaComponent(0.20) }
            return UIColor(self.accent).withAlphaComponent(0.10)
        })
    }

    private var legacySoft: Color {
        switch self {
        case .blue: return Color(red: 0.90, green: 0.94, blue: 0.99)
        case .graphite: return Color(red: 0.93, green: 0.93, blue: 0.95)
        case .emerald: return Color(red: 0.90, green: 0.96, blue: 0.93)
        case .violet, .coral, .gold: return accent.opacity(0.10)
        }
    }

    var cardRadius: CGFloat { self == .graphite ? 6 : self == .gold ? 8 : self == .coral ? 24 : self == .emerald ? 20 : self == .violet ? 18 : 14 }
    var messageWidth: CGFloat { self == .graphite ? 860 : self == .gold ? 800 : self == .emerald ? 780 : self == .violet ? 720 : self == .coral ? 740 : 760 }
    var cardPadding: CGFloat { self == .graphite ? 10 : self == .coral ? 18 : self == .emerald ? 16 : self == .violet ? 15 : 14 }
    var fontDesign: Font.Design { self == .gold ? .serif : self == .coral ? .rounded : self == .graphite ? .monospaced : .default }
    var canvas: Color { Color(UIColor.systemGroupedBackground) }
    var surface: Color { Color(UIColor.secondarySystemGroupedBackground) }
    var border: Color { self == .graphite || self == .gold ? accent.opacity(0.35) : Color(UIColor.separator).opacity(0.55) }
    var userBubble: Color { accentSoft }

    /// 展示用的色块
    var swatch: Color { accent }
}

/// 主题存取（@AppStorage 字符串）
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
extension EnvironmentValues { var appTheme: AppTheme { get { self[AppThemeEnvironmentKey.self] } set { self[AppThemeEnvironmentKey.self] = newValue } } }
