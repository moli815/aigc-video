import SwiftUI
import SwiftData

@main
struct BossAIApp: App {
    @StateObject private var credentials = CredentialStore()
    @AppStorage(ThemeStore.key) private var themeRaw = AppTheme.blue.rawValue

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
            .environment(\.appTheme, AppTheme(rawValue: themeRaw) ?? .blue)
            .fontDesign((AppTheme(rawValue: themeRaw) ?? .blue).fontDesign)
            .tint((AppTheme(rawValue: themeRaw) ?? .blue).accent)
        }
        .modelContainer(for: [Conversation.self, Message.self, MemoryItem.self, StoredFile.self],
                        inMemory: ProcessInfo.processInfo.arguments.contains("--render-fixture") || ProcessInfo.processInfo.arguments.contains("--performance-fixture") || ProcessInfo.processInfo.arguments.contains("--acceptance-fixture"))
    }
}
