import XCTest
@testable import BossAIExpertCore

final class ExpertCoreTests: XCTestCase {
    func testAllFifteenExpertsAreConfigured() throws {
        let expected: Set<String> = ["general", "decision", "strategy", "marketing", "traffic", "model", "funding", "equity", "performance", "speech", "legal", "boss_ip", "fire_safety", "security", "insurance"]
        XCTAssertEqual(Set(try ExpertCapabilityCatalog.configuration.get().keys), expected)
    }
    func testWeightedMatrix() throws {
        let result = try BusinessCalculators.calculate(name: "weighted_decision", json: #"{"weights":[0.4,0.6],"scores":[[4,3],[3,5]]}"#)
        XCTAssertEqual(try XCTUnwrap(result.values["alternative_1"]), 3.4, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(result.values["alternative_2"]), 4.2, accuracy: 0.00001)
    }
    func testWeightedZeroWeightsRejected() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "weighted_decision", json: #"{"weights":[0,0],"scores":[[4,3]]}"#))
    }
    func testWeightedDimensionMismatchRejected() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "weighted_decision", json: #"{"weights":[1,1],"scores":[[4]]}"#))
    }
    func testWeightedScoreOutOfBoundsRejected() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "weighted_decision", json: #"{"weights":[1],"scores":[[6]]}"#))
    }
    func testUnitEconomics() throws {
        let r = try BusinessCalculators.calculate(name: "unit_economics", json: #"{"unit_price":100,"unit_variable_cost":60,"period_fixed_cost":1000,"period_quantity":50}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["break_even_quantity"]), 25)
        XCTAssertEqual(try XCTUnwrap(r.values["period_profit_before_tax"]), 1000)
    }
    func testUnprofitableUnitHasNoFiniteBreakEven() throws {
        let r = try BusinessCalculators.calculate(name: "unit_economics", json: #"{"unit_price":10,"unit_variable_cost":12,"period_fixed_cost":100,"period_quantity":20}"#)
        XCTAssertNil(r.values["break_even_quantity"])
        XCTAssertEqual(try XCTUnwrap(r.values["period_profit_before_tax"]), -140)
    }
    func testFunnelScenario() throws {
        let r = try BusinessCalculators.calculate(name: "marketing_funnel", json: #"{"impressions":100000,"click_rate":0.01,"order_rate":0.1,"average_order_value":200,"ad_spend":1000,"contribution_per_order":60}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["expected_orders"]), 100)
        XCTAssertEqual(try XCTUnwrap(r.values["revenue_roas"]), 20)
        XCTAssertEqual(try XCTUnwrap(r.values["contribution_after_ads"]), 5000)
    }
    func testZeroOrdersAndSpendDoNotDivideByZero() throws {
        let r = try BusinessCalculators.calculate(name: "marketing_funnel", json: #"{"impressions":100,"click_rate":0,"order_rate":0.1,"average_order_value":200,"ad_spend":0,"contribution_per_order":60}"#)
        XCTAssertNil(r.values["revenue_roas"])
        XCTAssertNil(r.values["cost_per_order"])
    }
    func testRateAsPercentInsteadOfFractionRejected() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "commission", json: #"{"base_pay":100,"eligible_revenue":1000,"commission_rate":10}"#))
    }
    func testEquityDilution() throws {
        let r = try BusinessCalculators.calculate(name: "equity_dilution", json: #"{"existing_total_shares":100,"owner_shares":20,"new_shares":25}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["ownership_after"]), 0.16, accuracy: 0.000001)
    }
    func testInvalidOwnerSharesRejected() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "equity_dilution", json: #"{"existing_total_shares":100,"owner_shares":200,"new_shares":25}"#))
    }
    func testRunway() throws {
        let r = try BusinessCalculators.calculate(name: "cash_runway", json: #"{"available_cash":1000,"monthly_cash_inflow":20,"monthly_cash_outflow":100}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["runway_months"]), 12.5)
    }
    func testPositiveCashflowDoesNotEncodeInfinity() throws {
        let r = try BusinessCalculators.calculate(name: "cash_runway", json: #"{"available_cash":1000,"monthly_cash_inflow":200,"monthly_cash_outflow":100}"#)
        XCTAssertNil(r.values["runway_months"])
        XCTAssertNoThrow(try JSONEncoder().encode(r))
    }
    func testCommission() throws {
        let r = try BusinessCalculators.calculate(name: "commission", json: #"{"base_pay":5000,"eligible_revenue":10000,"commission_rate":0.1}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["gross_pay"]), 6000)
    }
    func testSpeechDuration() throws {
        let r = try BusinessCalculators.calculate(name: "speech_duration", json: #"{"character_count":1200,"characters_per_minute":240,"pause_seconds":30}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["estimated_minutes"]), 5.5)
    }
    func testBooleanCannotBeNumeric() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "commission", json: #"{"base_pay":true,"eligible_revenue":1000,"commission_rate":0.1}"#))
    }
    func testContentROI() throws {
        let r = try BusinessCalculators.calculate(name: "content_roi", json: #"{"content_cost":5000,"views":100000,"lead_rate":0.02,"close_rate":0.1,"order_value":800}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["expected_leads"]), 2000)
        XCTAssertEqual(try XCTUnwrap(r.values["expected_orders"]), 200)
        XCTAssertEqual(try XCTUnwrap(r.values["expected_revenue"]), 160000)
        XCTAssertEqual(try XCTUnwrap(r.values["roi"]), 31.0, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(r.values["cost_per_lead"]), 2.5, accuracy: 0.000001)
    }
    func testRiskExposure() throws {
        let r = try BusinessCalculators.calculate(name: "risk_exposure", json: #"{"probability":0.05,"loss_amount":2000000,"mitigation_cost":60000,"mitigation_effect":0.8}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["expected_loss"]), 100000)
        XCTAssertEqual(try XCTUnwrap(r.values["residual_expected_loss"]), 20000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(r.values["mitigation_net_benefit"]), 20000, accuracy: 0.000001)
    }
    func testRiskExposurePairedMitigationRequired() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "risk_exposure", json: #"{"probability":0.5,"loss_amount":1000,"mitigation_effect":0.5}"#))
    }
    func testCoverageNeed() throws {
        let r = try BusinessCalculators.calculate(name: "coverage_need", json: #"{"annual_income":300000,"replacement_years":10,"total_debt":500000,"liquid_assets":200000,"premium_rate":0.003}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["coverage_need"]), 3800000)
        XCTAssertEqual(try XCTUnwrap(r.values["premium_estimate"]), 11400, accuracy: 0.000001)
    }
    func testCoverageNeedNeverNegative() throws {
        let r = try BusinessCalculators.calculate(name: "coverage_need", json: #"{"annual_income":100000,"replacement_years":5,"total_debt":0,"liquid_assets":900000}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["coverage_need"]), 0)
    }
    func testLossPreventionROI() throws {
        let r = try BusinessCalculators.calculate(name: "loss_prevention_roi", json: #"{"annual_loss":400000,"prevention_investment":300000,"reduction_rate":0.6,"annual_maintenance":30000}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["annual_saved"]), 240000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(r.values["net_annual_benefit"]), 210000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(r.values["payback_months"]), 300000.0 * 12.0 / 210000.0, accuracy: 0.000001)
    }
    func testLossPreventionNoPaybackWhenNetNegative() throws {
        let r = try BusinessCalculators.calculate(name: "loss_prevention_roi", json: #"{"annual_loss":100000,"prevention_investment":500000,"reduction_rate":0.1,"annual_maintenance":50000}"#)
        XCTAssertNil(r.values["payback_months"])
        XCTAssertEqual(try XCTUnwrap(r.values["net_annual_benefit"]), -40000, accuracy: 0.000001)
    }
    func testProtectionBudget() throws {
        let r = try BusinessCalculators.calculate(name: "protection_budget", json: #"{"area_m2":2000,"unit_cost_per_m2":120,"annual_maintenance":15000}"#)
        XCTAssertEqual(try XCTUnwrap(r.values["initial_investment"]), 240000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(r.values["first_year_total"]), 255000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(r.values["first_year_cost_per_m2"]), 127.5, accuracy: 0.000001)
    }
    func testOversizedAndOverflowInputsRejected() {
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "commission", json: String(repeating: " ", count: 65537)))
        XCTAssertThrowsError(try BusinessCalculators.calculate(name: "unit_economics", json: #"{"unit_price":1e308,"unit_variable_cost":0,"period_fixed_cost":0,"period_quantity":1e308}"#))
    }
    func testForbiddenCalculatorDoesNotUseSpoofedExpertID() {
        let args = #"{"operation":"calculate","expertID":"equity","calculator":"equity_dilution","inputs_json":"{}"}"#
        XCTAssertThrowsError(try ExpertSkillRuntime.execute(arguments: args, expertID: "legal"))
    }
    func testLegalImageAndSpreadsheetDenied() throws {
        let p = try ExpertCapabilityCatalog.profile("legal")
        XCTAssertFalse(ExpertSkillRuntime.permits("generate_image", profile: p))
        XCTAssertThrowsError(try ExpertSkillRuntime.validateDocument("", format: "excel", profile: p))
    }
    func testHeadingsMustBeHeadingsNotBodyWords() throws {
        let p = try ExpertCapabilityCatalog.profile("decision")
        let content = p.documentSections.joined(separator: "。") + String(repeating: "正文", count: 30)
        XCTAssertFalse(try ExpertSkillRuntime.validateDocument(content, format: "word", profile: p).structurePassed)
    }
    func testCompleteStructurePassesButDoesNotVerifyFacts() throws {
        let p = try ExpertCapabilityCatalog.profile("decision")
        let text = p.documentSections.map { "## \($0)\n这里是用户数据、假设与待核实资料。" }.joined(separator: "\n")
        let r = try ExpertSkillRuntime.validateDocument(text, format: "word", profile: p)
        XCTAssertTrue(r.structurePassed)
        XCTAssertFalse(r.warnings.isEmpty)
    }
    func testInvalidSkillConfigurationIsRejected() {
        XCTAssertThrowsError(try ExpertCapabilityCatalog.decode(Data(#"{"version":2,"profiles":[]}"#.utf8)))
    }
}

final class ExpertCorePerformanceTests: XCTestCase {
    func testCalculateThousandScenariosPerformance() throws {
        let input = #"{"unit_price":100,"unit_variable_cost":60,"period_fixed_cost":1000,"period_quantity":50}"#
        // Warm configuration and verify correctness before measurement.
        XCTAssertEqual(try BusinessCalculators.calculate(name: "unit_economics", json: input).values["break_even_quantity"], 25)
        measure {
            for _ in 0..<1000 { _ = try! BusinessCalculators.calculate(name: "unit_economics", json: input) }
        }
    }
    func testSkillLookupTenThousandTimesPerformance() throws {
        _ = try ExpertCapabilityCatalog.profile("decision")
        measure {
            for _ in 0..<10000 { _ = try! ExpertCapabilityCatalog.profile("decision") }
        }
    }
}
