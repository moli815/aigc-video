import SwiftUI
import SwiftData

@main
struct BossAIApp: App {
    @StateObject private var credentials = CredentialStore()

    var body: some Scene {
        WindowGroup {
            if credentials.isConfigured {
                MainView()
            } else {
                SetupView()
            }
            .environmentObject(credentials)
        }
        .modelContainer(for: [Conversation.self, Message.self, MemoryItem.self])
    }
}
