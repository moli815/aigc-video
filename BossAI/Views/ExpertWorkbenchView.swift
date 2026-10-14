// ExpertWorkbenchView.swift —— 本机经营计算工作台。
// 职责：按专家能力画像列出可用的经营计算器，用户选择计算项并输入参数后，
//   调用 ExpertSkillRuntime 在本机执行公式，展示结果、口径与公式说明。
// 用户交互流程：选择计算项 → 填写动态生成的数值字段 → 点"计算" →
//   查看"计算结果"与"口径与公式"两个 Section；出错时显示红色错误文案。
// 关键设计决策与防呆/安全冗余：
//   1. 全部计算在本机完成（不联网、不传数据），页面固定声明"结果不含税费、
//      法律判断或行业预测"，防止用户把结果当作专业意见。
//   2. 输入校验三重防呆：必须可解析为有限 Double（拒绝 NaN/Inf）；非可选字段
//      留空直接报错；可选字段（optionalKeys）留空才允许跳过。
//   3. Dictionary(uniqueKeysWithValues:) 依赖 fields 的 key 天然唯一，重复会
//      抛错——这是对字段表配置错误的隐式防呆。
//   4. 切换计算项时清空 values/result/notes/error，避免上一个计算器的输入或
//      结果"串场"误导用户。
//   5. weighted_decision（多维加权决策）被刻意排除在本机表单之外，提示用户
//      在专家对话中调用该技能——因为它的输入结构复杂，表单化反而易错。
//   6. 结果行带 accessibilityIdentifier("calculator-result-<key>")，便于 UI
//      自动化断言具体数值。
import SwiftUI

/// 专家经营计算工作台：选择计算器 → 动态生成输入表单 → 本机执行 → 展示结果与公式说明。
struct ExpertWorkbenchView: View {
    /// 所属专家，决定可用的计算器集合（来自能力画像）。
    let expert: Expert
    /// 当前选中的计算器标识；空串表示尚未选择。
    @State private var selected = ""
    /// 各输入字段的原始文本值（key 为字段标识）。
    @State private var values: [String: String] = [:]
    /// 计算结果（中文字段名, 格式化后的数值字符串）。
    @State private var result: [(String, String)] = []
    /// 计算或解析失败的错误文案；nil 表示无错误。
    @State private var error: String?
    /// 结果附带的口径与公式说明文案。
    @State private var notes: [String] = []
    /// 当前专家可用的计算器列表；能力画像解析失败时降级为空数组。
    private var calculators: [String] { (try? ExpertCapabilityCatalog.profile(expert.id).calculators) ?? [] }
    // 可选输入：留空时不传给计算器（如 risk_exposure 的整改投入/消除比例、coverage_need 的参考费率）
    private static let optionalKeys: Set<String> = ["mitigation_cost", "mitigation_effect", "premium_rate"]
    /// 当前选中计算器对应的输入字段表（字段标识, 中文标签）。
    /// 集中维护在 switch 里，key 唯一由本表保证，供表单渲染与输入校验共用。
    private var fields: [(String, String)] {
        switch selected {
        case "unit_economics": return [("unit_price", "单价"), ("unit_variable_cost", "单位变动成本"), ("period_fixed_cost", "期间固定成本"), ("period_quantity", "销量")]
        case "marketing_funnel": return [("impressions", "曝光量"), ("click_rate", "点击率（0到1）"), ("order_rate", "成交率（0到1）"), ("average_order_value", "客单价"), ("ad_spend", "广告费"), ("contribution_per_order", "每单贡献金额")]
        case "equity_dilution": return [("owner_shares", "持有股数"), ("existing_total_shares", "融资前总股数"), ("new_shares", "新发行股数")]
        case "cash_runway": return [("available_cash", "现有现金"), ("monthly_cash_outflow", "月支出"), ("monthly_cash_inflow", "月流入")]
        case "commission": return [("base_pay", "基本薪资"), ("eligible_revenue", "业绩额"), ("commission_rate", "提成率（0到1）")]
        case "speech_duration": return [("character_count", "演讲字数"), ("characters_per_minute", "每分钟字数"), ("pause_seconds", "停顿秒数")]
        case "content_roi": return [("content_cost", "内容总成本"), ("views", "曝光量"), ("lead_rate", "留资率（0到1）"), ("close_rate", "成交率（0到1）"), ("order_value", "客单价")]
        case "risk_exposure": return [("probability", "发生概率（0到1）"), ("loss_amount", "单次损失金额"), ("mitigation_cost", "整改投入（可选）"), ("mitigation_effect", "风险消除比例（0到1，可选）")]
        case "coverage_need": return [("annual_income", "年收入"), ("replacement_years", "收入替代年限"), ("total_debt", "负债总额"), ("liquid_assets", "可变现资产"), ("premium_rate", "参考费率（0到1，可选）")]
        case "loss_prevention_roi": return [("annual_loss", "年损失金额"), ("reduction_rate", "降损比例（0到1）"), ("prevention_investment", "一次性投入"), ("annual_maintenance", "年维保费用")]
        case "protection_budget": return [("area_m2", "面积（㎡）"), ("unit_cost_per_m2", "每平米造价"), ("annual_maintenance", "年维保费用")]
        default: return []
        }
    }
    var body: some View {
        Form {
            Section("本机经营计算") {
                // weighted_decision 不适合表单化输入（需完整维度/权重/候选方案），
                // 因此从选择器里过滤掉，只在下方单独提示走对话技能。
                Picker("计算项目", selection: $selected) {
                    ForEach(calculators.filter { $0 != "weighted_decision" }, id: \.self) { name in
                        Text(BusinessCalculators.displayName(name)).tag(name)
                    }
                }
                // 动态字段：用自定义 Binding 让缺失的 key 表现为空串，避免字典膨胀；
                // 数字+标点键盘匹配"小数/百分数"类输入。
                ForEach(fields, id: \.0) { key, label in
                    TextField(label, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }))
                        .keyboardType(.numbersAndPunctuation)
                }
                // 没有可选字段表（fields 为空）时禁用计算按钮，防呆。
                Button("计算") { calculate() }.disabled(fields.isEmpty)
                // 固定免责说明：本机公式计算的能力边界。
                Text("直接执行本机公式。金额须统一币种与期间；结果不包含税费、法律判断或行业预测。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if !result.isEmpty { Section("计算结果") { ForEach(result, id: \.0) { key, value in LabeledContent(key, value: value).accessibilityIdentifier("calculator-result-" + key) } } }
            if !notes.isEmpty { Section("口径与公式") { ForEach(notes, id: \.self) { Text($0).font(.footnote) } } }
            if calculators.contains("weighted_decision") {
                Section { Text("多维加权决策需要完整维度、权重及候选方案，请在专家对话中调用加权决策技能。") }
            }
        }
        .navigationTitle(expert.name + " · 工作台")
        // onAppear：默认选中第一个可表单化的计算器，减少一次点击。
        .onAppear { selected = calculators.first(where: { $0 != "weighted_decision" }) ?? "" }
        // 切换计算器时彻底重置输入与结果，防止上个计算器的数据串场误导。
        .onChange(of: selected) { _, _ in values = [:]; result = []; notes = []; error = nil }
    }
    /// 执行计算：解析并校验输入 → 组装 JSON 参数调用本机 ExpertSkillRuntime →
    /// 解码结果并按中文名/百分比规则格式化展示。任何一步失败都只更新 error 文案，
    /// 同时清空旧结果，避免展示过期数据。
    private func calculate() {
        do {
            // 输入校验：trim 后必须为有效有限数字；可选字段留空可跳过。
            // uniqueKeysWithValues 会在 key 重复时抛错，是对字段表的隐式防呆。
            let numbers = try Dictionary(uniqueKeysWithValues: fields.compactMap { key, _ -> (String, Double)? in
                let raw = (values[key] ?? "").trimmingCharacters(in: .whitespaces)
                if raw.isEmpty, Self.optionalKeys.contains(key) { return nil }
                guard let number = Double(raw), number.isFinite else { throw ExpertSkillError.invalidInput("请填写全部有效数字") }
                return (key, number)
            })
            let inputs = String(decoding: try JSONSerialization.data(withJSONObject: numbers), as: UTF8.self)
            let args: [String: String] = ["operation": "calculate", "calculator": selected, "inputs_json": inputs]
            let output = try ExpertSkillRuntime.execute(arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self), expertID: expert.id)
            let calculation = try JSONDecoder().decode(BusinessCalculation.self, from: Data(output.utf8))
            // 结果字段的中文名映射表（结果 key → 展示文案）。
            let labels = ["unit_contribution": "单位贡献", "contribution_margin": "贡献率", "period_profit_before_tax": "期间税前贡献利润", "break_even_quantity": "盈亏平衡销量", "expected_clicks": "预计点击量", "expected_orders": "预计订单数", "expected_revenue": "预计收入", "contribution_after_ads": "扣广告费后贡献", "cost_per_order": "每单广告成本", "revenue_roas": "收入ROAS", "ownership_before": "原持股比例", "ownership_after": "增发后持股比例", "new_investor_ownership": "新投资人比例", "monthly_net_cashflow": "月现金净流入", "runway_months": "现金续航月数", "commission": "提成", "gross_pay": "税前报酬", "estimated_minutes": "预计分钟数", "expected_leads": "预计线索", "cost_per_lead": "单线索成本", "roi": "投产比ROI", "expected_loss": "期望损失", "residual_expected_loss": "残余期望损失", "mitigation_net_benefit": "整改净收益", "coverage_need": "保额需求", "premium_estimate": "参考年保费", "annual_saved": "年挽回损失", "net_annual_benefit": "年净收益", "payback_months": "回本月数", "three_year_net": "三年净收益", "initial_investment": "一次性投入", "first_year_total": "首年总投入", "first_year_cost_per_m2": "首年每平米投入"]
            // 比率类字段（0~1 的小数）转为百分号展示；其余保留两位小数。
            result = calculation.values.sorted { $0.key < $1.key }.map { key, number in
                let ratio = ["contribution_margin", "ownership_before", "ownership_after", "new_investor_ownership", "roi"].contains(key)
                return (labels[key] ?? key, ratio ? String(format: "%.2f%%", number * 100) : String(format: "%.2f", number))
            }
            notes = calculation.formulas + calculation.notes
            error = nil
        // 统一错误出口：只展示文案并清空结果，不让异常冒泡崩溃。
        } catch { self.error = error.localizedDescription; result = [] }
    }
}
