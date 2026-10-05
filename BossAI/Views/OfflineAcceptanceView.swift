import SwiftUI

struct OfflineAcceptanceView: View {
    @State private var theme = AppTheme.blue
    var body: some View {
        NavigationStack {
            List {
                Section("主题") {
                    Picker("主题", selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.displayName).tag($0) }
                    }.accessibilityIdentifier("acceptance-theme")
                }
                Section("专家技能") {
                    ForEach(ExpertCatalog.all) { expert in
                        NavigationLink(expert.name) { ExpertWorkbenchView(expert: expert) }
                            .accessibilityIdentifier("expert-" + expert.id)
                    }
                }
            }
            .navigationTitle("离线功能验收")
        }
        .environment(\.appTheme, theme).fontDesign(theme.fontDesign).tint(theme.accent)
    }
}
