import XCTest
@testable import BossAI

// ============================================================================
// P0-38 配置面板测试：档位元数据解析 + 面板行为契约。
// 这些测试锚定两个不变量：
//   1. 服务端下发什么档位，面板就显示什么（云端可改、客户端不写死）；
//   2. 任何异常数据（空/脏/缺字段）都必须回退内置三档——面板永不空缺。
// ============================================================================

final class ChatModeConfigTests: XCTestCase {

    /// 正常下发：三档齐全 → 按序解析，字段完整
    func testParseValidModes() {
        let raw: [[String: Any]] = [
            ["key": "standard", "label": "标准", "priceTier": "¥", "speed": "快", "strength": "自动", "desc": "日常问答"],
            ["key": "high", "label": "高", "priceTier": "¥¥", "speed": "标准", "strength": "最高", "desc": "复杂分析"],
            ["key": "ultra", "label": "最高", "priceTier": "¥¥¥", "speed": "标准", "strength": "最高", "desc": "最复杂任务"],
        ]
        let modes = ChatModeOption.parse(raw)
        XCTAssertEqual(modes.map(\.key), ["standard", "high", "ultra"])
        XCTAssertEqual(modes[0].label, "标准")
        XCTAssertEqual(modes[1].priceTier, "¥¥")
        XCTAssertEqual(modes[2].priceTier, "¥¥¥")
    }

    /// 空数组 / nil / 类型不对 → 回退内置三档（防呆：面板永不空缺）
    func testParseFallsBackWhenDataMissing() {
        XCTAssertEqual(ChatModeOption.parse(nil).count, 3)
        XCTAssertEqual(ChatModeOption.parse([] as [[String: Any]]).count, 3)
        XCTAssertEqual(ChatModeOption.parse("not-an-array").count, 3)
        XCTAssertEqual(ChatModeOption.parse(nil).first?.key, "standard")
    }

    /// 条目缺 key → 该条被丢弃；其余正常保留；全被丢 → 回退内置
    func testParseDropsInvalidEntries() {
        let raw: [[String: Any]] = [
            ["label": "没有key的脏数据"],
            ["key": "standard", "label": "标准"],
            ["key": "", "label": "空key"],
        ]
        let modes = ChatModeOption.parse(raw)
        XCTAssertEqual(modes.map(\.key), ["standard"])
        // 缺省字段使用安全默认值而不是崩溃
        XCTAssertEqual(modes[0].priceTier, "¥")
        XCTAssertEqual(modes[0].speed, "")

        let allBad: [[String: Any]] = [["label": "脏"], ["key": ""]]
        XCTAssertEqual(ChatModeOption.parse(allBad).count, 3, "全部非法时应回退内置三档")
    }

    /// 内置兜底与产品定义一致（三档 / 默认标准 / 价格画像升序）
    func testFallbackShape() {
        let fallback = ChatModeOption.fallback
        XCTAssertEqual(fallback.count, 3)
        XCTAssertEqual(fallback.first?.key, "standard")
        XCTAssertEqual(fallback.map(\.priceTier), ["¥", "¥¥", "¥¥¥"])
    }
}
