import SwiftUI
import SwiftData

@main
struct BossAIApp: App {
    @StateObject private var credentials = CredentialStore()
    @ObservedObject private var resetRequest = CredentialResetRequest.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if credentials.isConfigured && !resetRequest.requested {
                    MainView()
                } else {
                    SetupView()
                }
            }
            .environmentObject(credentials)
            .onChange(of: credentials.isConfigured) { _, configured in
                if configured { resetRequest.requested = false }
            }
        }
        .modelContainer(for: [Conversation.self, Message.self, MemoryItem.self])
    }
}
