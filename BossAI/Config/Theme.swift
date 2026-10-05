import SwiftUI

/// 主题：不再是单一主色，而是「主色 / 渐变次色 / 浅底」三层 token。
/// 收敛到 3 套（MVP 裁剪：六套完整主题暂缓，先做三套把 token 体系立起来）。
enum AppTheme: String, CaseIterable, Identifiable {
    case blue
    case graphite
    case emerald

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "海蓝"
        case .graphite: return "石墨"
        case .emerald: return "翡翠"
        }
    }

    var symbol: String {
        switch self {
        case .blue: return "drop.fill"
        case .graphite: return "circle.hexagongrid.fill"
        case .emerald: return "leaf.fill"
        }
    }

    /// 主色（强调色）：通过根视图 .tint() 全局生效
    var accent: Color {
        switch self {
        case .blue: return Color(red: 0.20, green: 0.42, blue: 0.88)
        case .graphite: return Color(red: 0.35, green: 0.37, blue: 0.42)
        case .emerald: return Color(red: 0.07, green: 0.55, blue: 0.40)
        }
    }

    /// 渐变第二色：比主色浅/亮，用于液态玻璃按钮的渐变尾部等
    var accentSecondary: Color {
        switch self {
        case .blue: return Color(red: 0.44, green: 0.64, blue: 0.95)
        case .graphite: return Color(red: 0.55, green: 0.57, blue: 0.62)
        case .emerald: return Color(red: 0.25, green: 0.70, blue: 0.56)
        }
    }

    /// 浅底：选中态 / 标签底 / 强调区块的极浅底色
    var accentSoft: Color {
        switch self {
        case .blue: return Color(red: 0.90, green: 0.94, blue: 0.99)
        case .graphite: return Color(red: 0.93, green: 0.93, blue: 0.95)
        case .emerald: return Color(red: 0.90, green: 0.96, blue: 0.93)
        }
    }

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
