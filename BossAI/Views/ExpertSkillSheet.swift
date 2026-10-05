import SwiftUI

struct ExpertSkillSheet: View {
    let expert: Expert
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { NavigationLink("打开经营计算工作台") { ExpertWorkbenchView(expert: expert) } }
                if let capability = try? ExpertCapabilityCatalog.profile(expert.id) {
                    Section("开始前需要") {
                        ForEach(capability.requiredInputs, id: \.self) { Text($0) }
                    }
                    Section("执行步骤") {
                        ForEach(Array(capability.workflow.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                        }
                    }
                    Section("可执行计算") {
                        if capability.calculators.isEmpty { Text("此专家以证据整理和审核清单为主") }
                        ForEach(capability.calculators, id: \.self) { Text(BusinessCalculators.displayName($0)) }
                    }
                    Section("文件交付标准") {
                        ForEach(capability.documentSections, id: \.self) { Text($0) }
                        Text("格式：\(capability.documentFormats.joined(separator: " / "))")
                    }
                    Section("能力边界") {
                        ForEach(capability.boundaries, id: \.self) { Text($0).font(.footnote) }
                        Text("本地计算验证公式和输入范围；章节校验检查结构。专业结论仍需可靠资料与必要的人工审核。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("技能配置未加载，请检查应用安装包。")
                }
            }
            .navigationTitle("\(expert.name)技能")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
