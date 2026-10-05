import Foundation

struct BusinessCalculation: Codable {
    let calculator: String
    let values: [String: Double]
    let formulas: [String]
    let notes: [String]
}

/// Deterministic scenario calculations. Rates are fractions (0...1), not percentages.
enum BusinessCalculators {
    static let names = ["weighted_decision", "unit_economics", "marketing_funnel", "equity_dilution", "cash_runway", "commission", "speech_duration"]
    static func displayName(_ name: String) -> String {
        ["weighted_decision": "加权决策矩阵", "unit_economics": "单位经济与盈亏平衡",
         "marketing_funnel": "营销漏斗与广告场景", "equity_dilution": "增发股权稀释",
         "cash_runway": "现金续航", "commission": "平率提成", "speech_duration": "演讲时长估算"][name] ?? name
    }
    static let inputGuide = """
    输入为JSON，数值有限且非负，rate用0...1：
    weighted_decision: {"weights":[0.4,0.6],"scores":[[4,3],[3,5]]}，每评分0...5；
    unit_economics: unit_price>0, unit_variable_cost, period_fixed_cost, period_quantity；
    marketing_funnel: impressions, click_rate, order_rate, average_order_value, ad_spend, contribution_per_order；
    equity_dilution: existing_total_shares>0, owner_shares, new_shares；
    cash_runway: available_cash, monthly_cash_inflow, monthly_cash_outflow；
    commission: base_pay, eligible_revenue, commission_rate；
    speech_duration: character_count, characters_per_minute>0, pause_seconds。
    不接受数字字符串或布尔值。币种、周期、单位必须一致；用户输入和假设不得伪装为外部事实。
    """

    static func calculate(name: String, json: String) throws -> BusinessCalculation {
        guard names.contains(name) else { throw ExpertSkillError.invalidInput("未知计算器") }
        guard json.utf8.count <= 64 * 1024 else { throw ExpertSkillError.invalidInput("输入超过64KiB") }
        let data = Data(json.utf8)
        if name == "weighted_decision" { return try weighted(data) }
        // JSONDecoder rejects booleans and strings as numeric values.
        let inputs = try JSONDecoder().decode([String: Double].self, from: data)
        func number(_ key: String, positive: Bool = false) throws -> Double {
            guard let value = inputs[key], value.isFinite, (positive ? value > 0 : value >= 0) else {
                throw ExpertSkillError.invalidInput("\(key) 必须为\(positive ? "正" : "非负")有限数值")
            }
            return value
        }
        func rate(_ key: String) throws -> Double {
            let value = try number(key)
            guard value <= 1 else { throw ExpertSkillError.invalidInput("\(key) 为0...1比例") }
            return value
        }
        var values: [String: Double] = [:]
        var formulas: [String] = []
        var notes = ["输入由用户/模型提供，计算正确不代表输入真实", "金额币种、期间、税费和单位需一致；结果为场景估算"]
        switch name {
        case "unit_economics":
            let price = try number("unit_price", positive: true)
            let cost = try number("unit_variable_cost")
            let fixed = try number("period_fixed_cost")
            let quantity = try number("period_quantity")
            let contribution = price - cost
            values = ["unit_contribution": contribution, "contribution_margin": contribution / price,
                      "period_profit_before_tax": contribution * quantity - fixed]
            formulas = ["单位贡献=单价-单位变动成本", "期间税前贡献利润=单位贡献×数量-固定成本"]
            if contribution > 0 { values["break_even_quantity"] = ceil(fixed / contribution) }
            else { notes.append("单位贡献不为正，不存在有限盈亏平衡销量；不能通过扩大销量解决") }
        case "marketing_funnel":
            let impressions = try number("impressions")
            let clicks = impressions * (try rate("click_rate"))
            let orders = clicks * (try rate("order_rate"))
            let price = try number("average_order_value")
            let spend = try number("ad_spend")
            let contribution = try number("contribution_per_order")
            values = ["expected_clicks": clicks, "expected_orders": orders, "expected_revenue": orders * price,
                      "contribution_after_ads": orders * contribution - spend]
            if orders > 0 { values["cost_per_order"] = spend / orders }
            if spend > 0 { values["revenue_roas"] = orders * price / spend }
            formulas = ["订单期望=曝光×点击率×订单转化率", "ROAS=收入/广告费，不等于利润ROI"]
            notes.append("订单为期望值；零订单不输出获客成本，零广告费不输出ROAS")
        case "equity_dilution":
            let total = try number("existing_total_shares", positive: true)
            let owned = try number("owner_shares")
            let issued = try number("new_shares")
            guard owned <= total else { throw ExpertSkillError.invalidInput("持有股数不能超过原总股数") }
            values = ["ownership_before": owned / total, "ownership_after": owned / (total + issued),
                      "new_investor_ownership": issued / (total + issued)]
            formulas = ["增发后持股比例=原持有股数/(原总股数+新增股数)"]
            notes.append("不包含期权池、可转债、优先权及公司法效力；只是增发场景计算")
        case "cash_runway":
            let cash = try number("available_cash")
            let inflow = try number("monthly_cash_inflow")
            let outflow = try number("monthly_cash_outflow")
            values = ["monthly_net_cashflow": inflow - outflow]
            if outflow > inflow { values["runway_months"] = cash / (outflow - inflow) }
            else { notes.append("该稳定场景没有现金净消耗，不输出无限大runway；不代表永续安全") }
            formulas = ["现金续航月数=可用现金/(月现金流出-月现金流入)，仅当分母>0"]
        case "commission":
            let salary = try number("base_pay")
            let revenue = try number("eligible_revenue")
            let commission = revenue * (try rate("commission_rate"))
            values = ["commission": commission, "gross_pay": salary + commission]
            formulas = ["提成=可计提业绩×提成比例", "税前报酬=底薪+提成"]
            notes.append("未考虑阶梯、退款、社保、个税或劳动法规；方案需另行确认")
        case "speech_duration":
            let count = try number("character_count")
            let speed = try number("characters_per_minute", positive: true)
            let pauses = try number("pause_seconds")
            values = ["estimated_minutes": count / speed + pauses / 60]
            formulas = ["预计时长=字符数/每分钟字符数+停顿秒数/60"]
            notes.append("仅中文字符口径估算；实际需朗读计时，不预测说服效果")
        default: throw ExpertSkillError.invalidInput("未知计算器")
        }
        guard values.values.allSatisfy(\.isFinite) else { throw ExpertSkillError.invalidInput("数值溢出") }
        return BusinessCalculation(calculator: name, values: values, formulas: formulas, notes: notes)
    }

    private static func weighted(_ data: Data) throws -> BusinessCalculation {
        struct Matrix: Decodable { let weights: [Double]; let scores: [[Double]] }
        let matrix = try JSONDecoder().decode(Matrix.self, from: data)
        guard !matrix.weights.isEmpty, matrix.weights.count <= 20, !matrix.scores.isEmpty,
              matrix.scores.count <= 20, matrix.weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ExpertSkillError.invalidInput("矩阵需1...20维度/方案，权重非负")
        }
        let total = matrix.weights.reduce(0, +)
        guard total.isFinite && total > 0 else { throw ExpertSkillError.invalidInput("权重和必须为正") }
        var values: [String: Double] = [:]
        for (index, row) in matrix.scores.enumerated() {
            guard row.count == matrix.weights.count, row.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 5 }) else {
                throw ExpertSkillError.invalidInput("每方案评分维度必须匹配且在0...5")
            }
            values["alternative_\(index + 1)"] = zip(row, matrix.weights).reduce(0) { $0 + $1.0 * ($1.1 / total) }
        }
        return BusinessCalculation(calculator: "weighted_decision", values: values,
                                   formulas: ["方案分数=Σ(维度分数×权重/总权重)"],
                                   notes: ["权重及评分为输入假设，最高分不等于最优决策；需敏感性分析和止损条件"])
    }
}
