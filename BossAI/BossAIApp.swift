import SwiftUI
import SwiftData

@main
struct BossAIApp: App {
    @StateObject private var credentials = CredentialStore()
    @AppStorage(ThemeStore.key) private var themeRaw = AppTheme.blue.rawValue
    private var activeTheme: AppTheme {
        if ProcessInfo.processInfo.arguments.contains("--render-fixture"),
           let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--fixture-theme=") }),
           let raw = flag.split(separator: "=").last, let theme = AppTheme(rawValue: String(raw)) { return theme }
        return AppTheme(rawValue: themeRaw) ?? .blue
    }

    init() {
        FileStore.prepare()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--render-fixture") {
                    ChatRenderingFixtureView()
                } else if ProcessInfo.processInfo.arguments.contains("--acceptance-fixture") {
                    OfflineAcceptanceView()
                } else if ProcessInfo.processInfo.arguments.contains("--performance-fixture") {
                    PerformanceFixtureView()
                } else if credentials.isConfigured {
                    MainView().environmentObject(credentials)
                } else {
                    SetupView().environmentObject(credentials)
                }
            }
            .environmentObject(credentials)
            .environment(\.appTheme, activeTheme)
            .fontDesign(activeTheme.fontDesign)
            .tint(activeTheme.accent)
        }
        .modelContainer(for: [Conversation.self, Message.self, MemoryItem.self, StoredFile.self],
                        inMemory: ProcessInfo.processInfo.arguments.contains("--render-fixture") || ProcessInfo.processInfo.arguments.contains("--performance-fixture") || ProcessInfo.processInfo.arguments.contains("--acceptance-fixture"))
    }
}
