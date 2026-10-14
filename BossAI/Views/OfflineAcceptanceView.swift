//
//  OfflineAcceptanceView.swift
//  BossAI
//
//  离线功能验收入口页（Views 层）：
//  - 职责：不依赖网络/模型/账号，本地即可遍历核心 UI 能力的验收清单页，
//    供开发与测试在离线环境下检查主题切换与各专家工作台的渲染。
//  - 交互流程：先在"主题"分组切换 AppTheme（实时生效整页），再从"专家技能"
//    分组逐个进入 ExpertWorkbenchView 验收。
//  - 关键设计决策：
//    1) 纯本地数据源（AppTheme.allCases / ExpertCatalog.all），无任何网络请求，
//       保证离线可跑、结果可复现。
//    2) 所有关键控件都带 accessibilityIdentifier，供自动化验收脚本定位。
//    3) 主题通过 .environment + .fontDesign + .tint 三处同时注入，
//       模拟真实 App 的全局主题链路。
//

import SwiftUI

/// 离线验收首页：本地切换主题 + 遍历专家工作台的导航清单
struct OfflineAcceptanceView: View {
    /// 本页本地主题状态（不写全局，仅为验收主题渲染而设）
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
        // 主题同时注入环境与字体/着色，验收时整页立即反映主题差异
        .environment(\.appTheme, theme).fontDesign(theme.fontDesign).tint(theme.accent)
    }
}
