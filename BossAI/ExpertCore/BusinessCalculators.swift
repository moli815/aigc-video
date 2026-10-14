import Foundation

// BusinessCalculators.swift —— 专家技能的确定性业务计算器集合。
// 职责：实现 12 个纯函数计算器（决策矩阵、单位经济、营销漏斗、股权稀释、现金续航、
//       提成、演讲时长、内容 ROI、风险敞口、保额需求、损失预防 ROI、防护预算）。
// 在整个 App 中的角色：ExpertCore 的"数学引擎"，由 ExpertSkillRuntime.execute 的
//       calculate 操作调用，模型只能通过受控入口使用，不能自由算数。
// 防呆/合规冗余（本文件的核心设计）：
// 1) 输入硬校验：仅接受 JSON 数字（JSONDecoder 天然拒绝字符串/布尔冒充数值），
//    非负/正值、比例必须落在 0...1、输入上限 64KiB，杜绝 NaN/Infinity 污染。
// 2) 除零防呆：分母为 0 时不输出对应指标（如零广告费不输出 ROAS），而非给 Infinity。
// 3) 结果兜底：输出前统一检查 isFinite，任何溢出直接抛错。
// 4) 合规护栏：每类结果附 notes 免责声明——输入是假设而非事实、不构成投资/投保/
//    法律建议、费率需联网核实。计算正确 ≠ 输入真实。
// 5) rate 用 0...1 小数而非百分比，guide 中明示，避免歧义。

/// 一次计算的完整输出：中间值、所用公式与免责说明（可编码回 JSON 给模型）。
struct BusinessCalculation: Codable {
    let calculator: String
    let values: [String: Double]
    let formulas: [String]
    let notes: [String]
}

/// Deterministic scenario calculations. Rates are fractions (0...1), not percentages.
enum BusinessCalculators {
    static let names = ["weighted_decision", "unit_economics", "marketing_funnel", "equity_dilution", "cash_runway", "commission", "speech_duration", "content_roi", "risk_exposure", "coverage_need", "loss_prevention_roi", "protection_budget"]
    static func displayName(_ name: String) -> String {
        ["weighted_decision": "加权决策矩阵", "unit_economics": "单位经济与盈亏平衡",
         "marketing_funnel": "营销漏斗与广告场景", "equity_dilution": "增发股权稀释",
         "cash_runway": "现金续航", "commission": "平率提成", "speech_duration": "演讲时长估算",
         "content_roi": "内容投产比", "risk_exposure": "风险敞口与整改收益",
         "coverage_need": "保额需求测算", "loss_prevention_roi": "损失预防投入产出",
         "protection_budget": "防护投入预算"][name] ?? name
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
    content_roi: content_cost>0, views, lead_rate(0...1), close_rate(0...1), order_value；
    risk_exposure: probability(0...1), loss_amount, 可选 mitigation_cost、mitigation_effect(0...1)；
    coverage_need: annual_income, replacement_years, total_debt, liquid_assets, 可选 premium_rate(0...1)；
    loss_prevention_roi: annual_loss, prevention_investment, reduction_rate(0...1), annual_maintenance；
    protection_budget: area_m2>0, unit_cost_per_m2, annual_maintenance。
    不接受数字字符串或布尔值。币种、周期、单位必须一致；用户输入和假设不得伪装为外部事实。
    """

    /// 统一入口：校验计算器名与输入体积后分发到各计算分支。
    static func calculate(name: String, json: String) throws -> BusinessCalculation {
        // 名称白名单 + 体积上限：防止未知调用与超大输入拖垮主线程内存。
        guard names.contains(name) else { throw ExpertSkillError.invalidInput("未知计算器") }
        guard json.utf8.count <= 64 * 1024 else { throw ExpertSkillError.invalidInput("输入超过64KiB") }
        let data = Data(json.utf8)
        if name == "weighted_decision" { return try weighted(data) }
        // JSONDecoder rejects booleans and strings as numeric values.
        // —— 这是刻意的类型防线：模型传 "3" 或 true 都会在此抛错，而不是被隐式转换。
        let inputs = try JSONDecoder().decode([String: Double].self, from: data)
        // 局部辅助：number 校验有限性与非负/正性；rate 追加 0...1 比例约束。
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
        // 公共免责说明，每个计算器的结果都会带上。
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
            // 盈亏平衡销量 = 固定成本 / 单位贡献，向上取整；贡献非正则无解，明确说明。
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
            // 获客成本与 ROAS 各自只在分母非零时输出，避免 0/0 或 x/0 的无穷结果。
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
            // 现金续航只在净流出时定义；净流入场景明确拒绝给"无限续航"的误导性输出。
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
        case "content_roi":
            let cost = try number("content_cost", positive: true)
            let views = try number("views")
            let leadRate = try rate("lead_rate")
            let closeRate = try rate("close_rate")
            let orderValue = try number("order_value")
            let leads = views * leadRate
            let orders = leads * closeRate
            let revenue = orders * orderValue
            values = ["expected_leads": leads, "expected_orders": orders, "expected_revenue": revenue]
            if leads > 0 { values["cost_per_lead"] = cost / leads }
            values["roi"] = (revenue - cost) / cost
            formulas = ["线索=曝光×留资率", "成交=线索×成交率", "ROI=(收入-内容成本)/内容成本"]
            notes.append("留资率与成交率为输入假设；ROI 为期望值，不承诺实际经营结果")
        case "risk_exposure":
            let probability = try rate("probability")
            let loss = try number("loss_amount")
            values = ["expected_loss": probability * loss]
            let hasEffect = inputs["mitigation_effect"] != nil
            let hasCost = inputs["mitigation_cost"] != nil
            guard hasEffect == hasCost else {
                throw ExpertSkillError.invalidInput("mitigation_cost 与 mitigation_effect 必须同时提供")
            }
            if hasEffect, let effect = inputs["mitigation_effect"], effect.isFinite, effect >= 0, effect <= 1 {
                let cost = try number("mitigation_cost")
                let residual = probability * (1 - effect) * loss
                values["residual_expected_loss"] = residual
                values["mitigation_net_benefit"] = (probability * loss) - residual - cost
            }
            formulas = ["期望损失=发生概率×单次损失金额", "整改净收益=原期望损失-残余期望损失-整改成本"]
            notes.append("概率与损失金额为输入假设；净收益>0 仅表示该口径下整改划算，不含合规强制项——法规强制整改不适用收益比较")
        case "coverage_need":
            let income = try number("annual_income")
            let years = try number("replacement_years")
            let debt = try number("total_debt")
            let assets = try number("liquid_assets")
            let need = max(0, income * years + debt - assets)
            values = ["coverage_need": need]
            if let rateValue = inputs["premium_rate"], rateValue.isFinite, rateValue >= 0, rateValue <= 1 {
                values["premium_estimate"] = need * rateValue
            }
            formulas = ["保额需求=年收入×替代年限+负债-可变现资产（下限0）", "参考年保费=保额需求×参考费率"]
            notes.append("费率必须联网核实当期产品报价；本结果为测算口径，不构成投保建议")
        case "loss_prevention_roi":
            let loss = try number("annual_loss")
            let investment = try number("prevention_investment")
            let reduction = try rate("reduction_rate")
            let maintenance = try number("annual_maintenance")
            let saved = loss * reduction
            let net = saved - maintenance
            values = ["annual_saved": saved, "net_annual_benefit": net,
                      "three_year_net": net * 3 - investment]
            if net > 0 { values["payback_months"] = investment / net * 12 }
            formulas = ["年挽回损失=年损失×下降率", "年净收益=挽回损失-年维保", "回本月数=投入/年净收益×12"]
            notes.append("下降率为输入假设；净收益≤0 时不输出回本月数，方案不成立")
        case "protection_budget":
            let area = try number("area_m2", positive: true)
            let unitCost = try number("unit_cost_per_m2")
            let maintenance = try number("annual_maintenance")
            let initial = area * unitCost
            values = ["initial_investment": initial, "first_year_total": initial + maintenance,
                      "first_year_cost_per_m2": (initial + maintenance) / area]
            formulas = ["初始投入=面积×每平米造价", "首年总投入=初始投入+年维保费"]
            notes.append("造价与维保口径需对照当地消防审验要求核实；不含土建与装修")
        default: throw ExpertSkillError.invalidInput("未知计算器")
        }
        // 最后统一兜底：任何中间计算产生的 NaN/Infinity 都不允许流出到结果里。
        guard values.values.allSatisfy(\.isFinite) else { throw ExpertSkillError.invalidInput("数值溢出") }
        return BusinessCalculation(calculator: name, values: values, formulas: formulas, notes: notes)
    }

    /// 加权决策矩阵专用分支：输入是嵌套矩阵而非扁平键值对，故单独解码。
    /// 权重按总和归一化，评分限定 0...5，维度/方案上限 20 防止组合爆炸。
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
