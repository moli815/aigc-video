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
                if credentials.isConfigured {
                    MainView().environmentObject(credentials)
                } else {
                    SetupView().environmentObject(credentials)
                }
            }
            .tint(AppTheme(rawValue: themeRaw)?.accent ?? .blue)
        }
        .modelContainer(for: [Conversation.self, Message.self, MemoryItem.self, StoredFile.self])
    }
}
