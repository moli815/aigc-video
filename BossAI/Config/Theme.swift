import SwiftUI

/// 主题色板：多套主色调，切换后通过根视图 .tint() 即时全局生效
enum AppTheme: String, CaseIterable, Identifiable {
    case blue
    case graphite
    case emerald
    case violet
    case coral
    case gold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blue: return "海蓝"
        case .graphite: return "石墨"
        case .emerald: return "翡翠"
        case .violet: return "罗兰"
        case .coral: return "珊瑚"
        case .gold: return "鎏金"
        }
    }

    var symbol: String {
        switch self {
        case .blue: return "drop.fill"
        case .graphite: return "circle.hexagongrid.fill"
        case .emerald: return "leaf.fill"
        case .violet: return "sparkles"
        case .coral: return "flame.fill"
        case .gold: return "star.fill"
        }
    }

    var accent: Color {
        switch self {
        case .blue: return Color(red: 0.20, green: 0.42, blue: 0.88)
        case .graphite: return Color(red: 0.35, green: 0.37, blue: 0.42)
        case .emerald: return Color(red: 0.07, green: 0.55, blue: 0.40)
        case .violet: return Color(red: 0.49, green: 0.34, blue: 0.79)
        case .coral: return Color(red: 0.90, green: 0.38, blue: 0.27)
        case .gold: return Color(red: 0.82, green: 0.61, blue: 0.12)
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
