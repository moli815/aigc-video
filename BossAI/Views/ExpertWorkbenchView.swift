import SwiftUI

struct ExpertWorkbenchView: View {
    let expert: Expert
    @State private var selected = ""
    @State private var values: [String: String] = [:]
    @State private var result: [(String, String)] = []
    @State private var error: String?
    @State private var notes: [String] = []
    private var calculators: [String] { (try? ExpertCapabilityCatalog.profile(expert.id).calculators) ?? [] }
    private var fields: [(String, String)] {
        switch selected {
        case "unit_economics": return [("unit_price", "单价"), ("unit_variable_cost", "单位变动成本"), ("period_fixed_cost", "期间固定成本"), ("period_quantity", "销量")]
        case "marketing_funnel": return [("impressions", "曝光量"), ("click_rate", "点击率（0到1）"), ("order_rate", "成交率（0到1）"), ("average_order_value", "客单价"), ("ad_spend", "广告费"), ("contribution_per_order", "每单贡献金额")]
        case "equity_dilution": return [("owner_shares", "持有股数"), ("existing_total_shares", "融资前总股数"), ("new_shares", "新发行股数")]
        case "cash_runway": return [("available_cash", "现有现金"), ("monthly_cash_outflow", "月支出"), ("monthly_cash_inflow", "月流入")]
        case "commission": return [("base_pay", "基本薪资"), ("eligible_revenue", "业绩额"), ("commission_rate", "提成率（0到1）")]
        case "speech_duration": return [("character_count", "演讲字数"), ("characters_per_minute", "每分钟字数"), ("pause_seconds", "停顿秒数")]
        default: return []
        }
    }
    var body: some View {
        Form {
            Section("本机经营计算") {
                Picker("计算项目", selection: $selected) {
                    ForEach(calculators.filter { $0 != "weighted_decision" }, id: \.self) { name in
                        Text(BusinessCalculators.displayName(name)).tag(name)
                    }
                }
                ForEach(fields, id: \.0) { key, label in
                    TextField(label, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }))
                        .keyboardType(.numbersAndPunctuation)
                }
                Button("计算") { calculate() }.disabled(fields.isEmpty)
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
        .onAppear { selected = calculators.first(where: { $0 != "weighted_decision" }) ?? "" }
        .onChange(of: selected) { _, _ in values = [:]; result = []; notes = []; error = nil }
    }
    private func calculate() {
        do {
            let numbers = try Dictionary(uniqueKeysWithValues: fields.map { key, _ -> (String, Double) in
                guard let number = Double(values[key] ?? ""), number.isFinite else { throw ExpertSkillError.invalidInput("请填写全部有效数字") }
                return (key, number)
            })
            let inputs = String(decoding: try JSONSerialization.data(withJSONObject: numbers), as: UTF8.self)
            let args: [String: String] = ["operation": "calculate", "calculator": selected, "inputs_json": inputs]
            let output = try ExpertSkillRuntime.execute(arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self), expertID: expert.id)
            let calculation = try JSONDecoder().decode(BusinessCalculation.self, from: Data(output.utf8))
            let labels = ["unit_contribution": "单位贡献", "contribution_margin": "贡献率", "period_profit_before_tax": "期间税前贡献利润", "break_even_quantity": "盈亏平衡销量", "expected_clicks": "预计点击量", "expected_orders": "预计订单数", "expected_revenue": "预计收入", "contribution_after_ads": "扣广告费后贡献", "cost_per_order": "每单广告成本", "revenue_roas": "收入ROAS", "ownership_before": "原持股比例", "ownership_after": "增发后持股比例", "new_investor_ownership": "新投资人比例", "monthly_net_cashflow": "月现金净流入", "runway_months": "现金续航月数", "commission": "提成", "gross_pay": "税前报酬", "estimated_minutes": "预计分钟数"]
            result = calculation.values.sorted { $0.key < $1.key }.map { key, number in
                let ratio = ["contribution_margin", "ownership_before", "ownership_after", "new_investor_ownership"].contains(key)
                return (labels[key] ?? key, ratio ? String(format: "%.2f%%", number * 100) : String(format: "%.2f", number))
            }
            notes = calculation.formulas + calculation.notes
            error = nil
        } catch { self.error = error.localizedDescription; result = [] }
    }
}
