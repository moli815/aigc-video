// ExpertSkillSheet.swift —— 专家技能说明弹层（sheet）。
// 职责：展示某个专家（Expert）的能力画像：开始前需要什么输入、执行步骤、
//   可执行的计算器、文件交付标准、能力边界，并提供进入"经营计算工作台"的入口。
// 用户交互流程：从专家详情打开 → 浏览各 Section 说明 → （如有计算器）点
//   "打开经营计算工作台" 进入 ExpertWorkbenchView → 点"完成"关闭弹层。
// 关键设计决策与防呆/安全冗余：
//   1. 能力画像来自 ExpertCapabilityCatalog.profile(expert.id)，解析失败时
//      （try? 返回 nil）降级显示"技能配置未加载"，而不是崩溃或留白——这是对
//      安装包资源缺失/损坏的兜底。
//   2. 只有存在 calculators 时才显示工作台入口，避免用户进入一个空工作台。
//   3. "能力边界"Section 明确声明：本地计算只做公式/输入范围验证与结构校验，
//      专业结论仍需可靠资料与人工审核——这是产品层面的免责与防过度信任设计。
//   4. workflow 用 enumerated + id: \.offset 渲染编号步骤：步骤文本可能重复，
//      不能用文本本身当 id，用下标保证 ForEach 身份稳定（防呆）。
import SwiftUI

/// 专家技能说明弹层：展示指定专家的能力画像（输入要求、步骤、计算器、
/// 交付标准、能力边界），并提供跳转经营计算工作台的入口。
struct ExpertSkillSheet: View {
    /// 要展示技能说明的目标专家。
    let expert: Expert
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                // 尝试加载专家能力画像；失败则整体降级为提示文案（不崩溃）。
                if let capability = try? ExpertCapabilityCatalog.profile(expert.id) {
                    // 仅当专家确实有计算器时才显示工作台入口，防空入口误导用户。
                    if !capability.calculators.isEmpty {
                        Section {
                            // accessibilityIdentifier 供 UI 自动化测试定位入口。
                            NavigationLink("打开经营计算工作台") { ExpertWorkbenchView(expert: expert) }
                                .accessibilityIdentifier("open-calculator-workbench")
                        }
                    }
                    Section("开始前需要") {
                        // requiredInputs 为字符串数组且无重复，可直接用文本作 id。
                        ForEach(capability.requiredInputs, id: \.self) { Text($0) }
                    }
                    Section("执行步骤") {
                        // enumerated + id:\.offset：步骤文本可能重复，不能用文本当 id，
                        // 用下标保证身份稳定；同时把下标转为 1 起始的人类可读编号。
                        ForEach(Array(capability.workflow.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                        }
                    }
                    Section("可执行计算") {
                        // 无计算器的专家（如证据整理类）给出明确说明而非空 Section。
                        if capability.calculators.isEmpty { Text("此专家以证据整理和审核清单为主") }
                        ForEach(capability.calculators, id: \.self) { Text(BusinessCalculators.displayName($0)) }
                    }
                    Section("文件交付标准") {
                        ForEach(capability.documentSections, id: \.self) { Text($0) }
                        Text("格式：\(capability.documentFormats.joined(separator: " / "))")
                    }
                    // 能力边界：明确本地校验的能力范围，防止用户把自动校验当作专业背书。
                    Section("能力边界") {
                        ForEach(capability.boundaries, id: \.self) { Text($0).font(.footnote) }
                        Text("本地计算验证公式和输入范围；章节校验检查结构。专业结论仍需可靠资料与必要的人工审核。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    // 兜底：技能配置资源缺失/解析失败时给出可理解的提示。
                    Text("技能配置未加载，请检查应用安装包。")
                }
            }
            .navigationTitle("\(expert.name)技能")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
