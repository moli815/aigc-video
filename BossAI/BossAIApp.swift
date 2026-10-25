// BossAIApp.swift —— App 入口（@main）。
// 职责：装配根视图、主题环境、SwiftData 容器、崩溃上报与云端同步触发。
// 在整个 App 中的角色：所有 Scene 的组装点，决定启动后用户看到哪个页面。
// 关键设计决策：
// 1) 根视图按"渲染夹具 → 验收夹具 → 性能夹具 → 登录态 → Key 配置"优先级分支，
//    保证自动化测试夹具永远优先于业务分支，避免测试被真实登录态污染。
// 2) hostedAccount 用 @ObservedObject 观察（而非 @StateObject），
//    因为它是全局单例，App 销毁不应销毁它。
// 3) 强制 .preferredColorScheme(.dark)：深空玻璃设计依赖深色底衬，
//    浅色模式下毛玻璃质感不成立，属于设计约束而非偏好。
// 4) 崩溃上报在 init 最早时机安装，确保后续代码崩溃也能被捕获并补报。
import SwiftUI
import Combine
import UIKit
import SwiftData

@main
/// App 主结构：负责窗口装配、主题注入、登录态分支与生命周期钩子。
struct BossAIApp: App {
    /// 全局凭证单例：持有对话/作图 API Key，注入到所有子视图。
    @StateObject private var credentials = CredentialStore()
    /// 观察云端登录态：登录/登出/被踢下线时根视图立即切换（修复"登出后不返回登录页"）
    @ObservedObject private var hostedAccount = HostedAccount.shared
    @AppStorage(ThemeStore.key) private var themeRaw = AppTheme.blue.rawValue
    /// 当前生效主题：夹具模式优先（命令行指定），否则读用户设置；解析失败兜底 .blue。
    private var activeTheme: AppTheme {
        if ProcessInfo.processInfo.arguments.contains("--render-fixture"),
           let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--fixture-theme=") }),
           let raw = flag.split(separator: "=").last, let theme = AppTheme(rawValue: String(raw)) { return theme }
        return AppTheme(rawValue: themeRaw) ?? .blue
    }

    /// 初始化：准备本地文件目录、安装崩溃上报并补报上次崩溃。
    init() {
        FileStore.prepare()
        // P0 崩溃上报：挂异常/信号处理器；并把上次崩溃的待发文件补报
        CrashReporter.install()
        CrashReporter.uploadPendingIfNeeded()
    }

    /// 根视图分支（自上而下短路求值，顺序即优先级，不可调换）。
    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--render-fixture") {
                    ChatRenderingFixtureView()
                } else if ProcessInfo.processInfo.arguments.contains("--acceptance-fixture") {
                    OfflineAcceptanceView()
                } else if ProcessInfo.processInfo.arguments.contains("--performance-fixture") {
                    PerformanceFixtureView()
                } else if hostedAccount.isLoggedIn {
                    // 云端账号已登录 → 主界面（放在最前：否则登出后 credentials.isConfigured 仍为真会卡在主界面）
                    MainView().environmentObject(credentials)
                } else if HostedAccount.isHostedActive {
                    // 云端账号模式但未登录 → 会员登录页（模型 Key 全部在服务端）
                    HostedLoginView().environmentObject(credentials)
                } else if credentials.isConfigured {
                    // 自备 API Key 模式
                    MainView().environmentObject(credentials)
                } else {
                    SetupView().environmentObject(credentials)
                }
            }
            .environmentObject(credentials)
            .environment(\.appTheme, activeTheme)
            .overlay(SessionReplacedAlertView())
            // P0-17 登录态/额度自动刷新：启动时 + 每次回到前台（后台通过审核后打开 App 即生效）
            .task { await hostedAccount.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await hostedAccount.refresh() }
            }
            // P0-18 云端同步：启动 + 回前台时做"每日 3 点补偿"（失败静默，不影响使用）
            .modifier(DailySyncTrigger())
            .fontDesign(activeTheme.fontDesign)
            .tint(activeTheme.accent)
            // 深空玻璃（方案 B）：深色外观是这套设计的一部分，毛玻璃需要深底才成立
            .preferredColorScheme(.dark)
            .background(AmbientBackground(theme: activeTheme))
        }
        .modelContainer(for: [Conversation.self, Message.self, MemoryItem.self, StoredFile.self],
                        // 测试夹具运行时使用内存数据库：避免污染沙盒里的真实用户数据。
                        inMemory: ProcessInfo.processInfo.arguments.contains("--render-fixture") || ProcessInfo.processInfo.arguments.contains("--performance-fixture") || ProcessInfo.processInfo.arguments.contains("--acceptance-fixture"))
    }
}


/// P0-18 每日同步触发器：拿得到 modelContext 才能同步，因此放在独立 Modifier 里
private struct DailySyncTrigger: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { await SyncService.shared.dailySyncIfNeeded(context: modelContext) }
            .onChange(of: scenePhase) { _, phase in
                // 10-25 底图缓存生命周期：进后台只清过期的（切个 App 回来还能复用，不白花钱）；
                // 真正退出时整个缓存随进程消失，这里再显式清一次，避免"以为还在其实已失效"。
                if phase == .background { BaseImageCache.shared.evictExpired() }
                guard phase == .active else { return }
                Task { await SyncService.shared.dailySyncIfNeeded(context: modelContext) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                BaseImageCache.shared.evictAll()
            }
    }
}
