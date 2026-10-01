import SwiftUI
import SwiftData

/// 主界面：ChatGPT 风格的侧栏 + 对话区。
struct MainView: View {
    @EnvironmentObject var credentials: CredentialStore
    @State private var selectedExpertId: String = ExpertCatalog.general.id
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedExpertId: $selectedExpertId)
                .navigationTitle("Boss AI")
        } detail: {
            ChatContainerView(expert: ExpertCatalog.find(selectedExpertId))
                .id(selectedExpertId) // 切换专家时重建对话视图
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// 侧栏：普通对话 + 10 个专家入口
struct SidebarView: View {
    @Binding var selectedExpertId: String

    var body: some View {
        List(selection: $selectedExpertId) {
            Section {
                Label(ExpertCatalog.general.name, systemImage: ExpertCatalog.general.symbol)
                    .tag(ExpertCatalog.general.id)
            }
            Section("专家顾问") {
                ForEach(ExpertCatalog.experts) { expert in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expert.name)
                            Text(expert.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: expert.symbol)
                            .foregroundStyle(Color.accentColor)
                    }
                    .tag(expert.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            // Boss AI 品牌区（长按 5 秒重新打开 Key 配置页——隐藏入口）
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 30, height: 30)
                    Text("B").font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text("Boss AI").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 5) {
                CredentialResetRequest.shared.request()
            }
            .accessibilityLabel("Boss AI")
        }
    }
}

/// 长按 Logo 重置 Key 的全局通知（避免在侧栏里持有 CredentialStore）
final class CredentialResetRequest: ObservableObject {
    static let shared = CredentialResetRequest()
    @Published var requested = false
    func request() { requested = true }
}
