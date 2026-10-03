import SwiftUI
import SwiftData
import UIKit

/// 主界面：ChatGPT 风格的侧栏 + 对话区。
struct MainView: View {
    @EnvironmentObject var credentials: CredentialStore
    @State private var selectedExpertId: String? = ExpertCatalog.general.id
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showPinEntry = false
    @State private var showHiddenSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedExpertId: $selectedExpertId) {
                showPinEntry = true
            }
        } detail: {
            ChatContainerView(expert: ExpertCatalog.find(selectedExpertId ?? ExpertCatalog.general.id))
        }
        .navigationSplitViewStyle(.balanced)
        .task { ensureProvidersDetected() }
        .sheet(isPresented: $showPinEntry) {
            HiddenPinGate {
                // 先收起密码页，再弹出设置页（避免两个 sheet 同时切换）
                showPinEntry = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    showHiddenSettings = true
                }
            }
        }
        .sheet(isPresented: $showHiddenSettings) {
            SetupView(isModal: true)
        }
    }

    /// 首次启动：用内置 Key 自动识别服务商（无需任何手动配置）
    private func ensureProvidersDetected() {
        guard !ProviderCatalog.providersDetected else { return }
        Task {
            if let ck = credentials.chatKey,
               let p = await ProviderDetector.detectChat(key: ck) {
                ProviderCatalog.saveChatProvider(p.id)
            }
            if let ik = credentials.imageKey,
               let p = await ProviderDetector.detectImage(key: ik) {
                ProviderCatalog.saveImageProvider(p.id)
            }
        }
    }
}

/// 侧栏：普通对话 + 10 个专家入口（顶部仅一个 Logo，连点 5 次 = 密码验证进入设置）
struct SidebarView: View {
    @Binding var selectedExpertId: String?
    var onHiddenSettings: () -> Void = {}

    @State private var tapCount = 0
    @State private var lastTapAt = Date.distantPast

    var body: some View {
        List(selection: $selectedExpertId) {
            Section {
                Label(ExpertCatalog.general.name, systemImage: ExpertCatalog.general.symbol)
                    .tag(String?.some(ExpertCatalog.general.id))
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
                    .tag(String?.some(expert.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Boss AI")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { registerTap() }
            .accessibilityLabel("Boss AI")
        }
    }

    /// 隐藏入口：连点 AppConfig.hiddenTriggerTaps 次，且每次间隔小于 0.8 秒
    private func registerTap() {
        let now = Date()
        if now.timeIntervalSince(lastTapAt) > 0.8 {
            tapCount = 0
        }
        lastTapAt = now
        tapCount += 1
        guard tapCount >= AppConfig.hiddenTriggerTaps else { return }
        tapCount = 0
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
        onHiddenSettings()
    }
}

/// 隐藏设置门禁：输入密码才能进入
struct HiddenPinGate: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var wrong = false
    var onSuccess: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("输入密码", text: $pin)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if wrong {
                        Text("密码错误")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("验证身份")
                } footer: {
                    Text("入口：在侧栏顶部 \"Boss AI\" 标题上快速连点 \(AppConfig.hiddenTriggerTaps) 次（间隔小于 0.8 秒）")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解锁") { check() }
                        .disabled(pin.isEmpty)
                }
            }
        }
    }

    private func check() {
        if pin == AppConfig.hiddenPIN {
            onSuccess()
        } else {
            wrong = true
            pin = ""
        }
    }
}
