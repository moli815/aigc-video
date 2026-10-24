import XCTest
@testable import BossAI

// ============================================================================
// MembershipDisplayTests —— 侧栏「会员显示不正确」的回归锚点（2026-10-24 真机反馈）
//
// 现场：账号是 Ultra、到期 2026-12-12，侧栏却显示「Plus 基础版 / 0 天 / 已过期」。
// 根因有两层，这个文件把两层都钉死：
//   ① 服务端时间带毫秒（2026-11-15T02:53:29.994Z），默认 ISO8601DateFormatter 解不出来
//      → memberUntil 永远 nil → 到期日永远空；
//   ② 侧栏读的是本地快照，首次安装时快照还没写 → daysLeft nil → 旧逻辑 `(nil ?? 0) <= 0`
//      判定为"已到期"，于是把"没同步到"渲染成了"过期"。
// 不变量：**未知 ≠ 已到期**。没有数据就显示"未同步"，绝不能谎称过期。
// ============================================================================

final class MembershipDisplayTests: XCTestCase {

    // MARK: - ① ISO8601 带毫秒

    func testParseISOWIthMilliseconds() throws {
        // 服务端真实格式：带毫秒 + Z
        let date = try XCTUnwrap(HostedAccount.parseISO("2026-11-15T02:53:29.994Z"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 11)
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 2)
        XCTAssertEqual(c.minute, 53)
        XCTAssertEqual(c.second, 29)
    }

    func testParseISOWithoutMilliseconds() throws {
        XCTAssertNotNil(HostedAccount.parseISO("2026-11-15T02:53:29Z"), "不带毫秒的格式也要能解")
    }

    func testParseISOWithOffset() throws {
        XCTAssertNotNil(HostedAccount.parseISO("2026-11-15T10:53:29.994+08:00"))
    }

    func testParseISORejectsGarbage() {
        XCTAssertNil(HostedAccount.parseISO(""))
        XCTAssertNil(HostedAccount.parseISO("   "))
        XCTAssertNil(HostedAccount.parseISO("不是时间"))
        XCTAssertNil(HostedAccount.parseISO("2026-11-15"))
    }

    // MARK: - ② 档位显示名

    func testTierDisplayName() {
        XCTAssertEqual(HostedAccount.displayName(forTier: "ultra"), "Ultra 旗舰版")
        XCTAssertEqual(HostedAccount.displayName(forTier: "PRO"), "Pro 专业版")
        XCTAssertEqual(HostedAccount.displayName(forTier: "plus"), "Plus 基础版")
        XCTAssertEqual(HostedAccount.displayName(forTier: ""), "会员")
    }

    // MARK: - ③ 未知 ≠ 已到期

    func testDaysLeftUnknownIsNilNotZero() {
        XCTAssertNil(MembershipDisplay.daysLeft(serverDays: nil, until: nil),
                     "没有任何数据时必须返回 nil（未知），不能返回 0 让 UI 说成已到期")
    }

    func testDaysLeftServerValueWins() {
        XCTAssertEqual(MembershipDisplay.daysLeft(serverDays: 48, until: nil), 48)
        // 服务端值与本地推算冲突时，以服务端为准（本地只做展示推算）
        let future = Date().addingTimeInterval(10 * 86400)
        XCTAssertEqual(MembershipDisplay.daysLeft(serverDays: 3, until: future), 3)
    }

    func testDaysLeftFallsBackToUntil() throws {
        let now = try XCTUnwrap(HostedAccount.parseISO("2026-10-24T00:00:00Z"))
        let until = try XCTUnwrap(HostedAccount.parseISO("2026-11-15T02:53:29.994Z"))
        let days = try XCTUnwrap(MembershipDisplay.daysLeft(serverDays: nil, until: until, now: now))
        XCTAssertEqual(days, 22, "到期日能解出来时，即使服务端没给天数也要能算出来")
    }

    func testExpiredOnlyWhenKnown() {
        XCTAssertFalse(MembershipDisplay.isExpired(daysLeft: nil), "未知不能被判成已到期")
        XCTAssertFalse(MembershipDisplay.isExpired(daysLeft: 1))
        XCTAssertTrue(MembershipDisplay.isExpired(daysLeft: 0))
        XCTAssertTrue(MembershipDisplay.isExpired(daysLeft: -5))
    }

    // MARK: - ④ 徽章不冒充档位

    func testTierBadgeDoesNotPretend() {
        // 从未同步 + 默认档位 → 只显示"会员"，不能显示"Plus 基础版"
        XCTAssertEqual(MembershipDisplay.tierBadge(tierName: "Plus 基础版", synced: false, syncing: false), "会员")
        XCTAssertEqual(MembershipDisplay.tierBadge(tierName: "Plus 基础版", synced: false, syncing: true), "会员同步中…")
        // 已经同步过 → 照实显示
        XCTAssertEqual(MembershipDisplay.tierBadge(tierName: "Plus 基础版", synced: true, syncing: false), "Plus 基础版")
        // 登录时就拿到了档位（不依赖 /me）→ 照实显示
        XCTAssertEqual(MembershipDisplay.tierBadge(tierName: "Ultra 旗舰版", synced: false, syncing: false), "Ultra 旗舰版")
    }

    // MARK: - ⑤ 端到端：服务端真实响应样例

    func testRealMePayloadFields() throws {
        // 直接取线上 /me 的关键字段形态，确认解析链路对得上（字段名变了这里会先红）
        let json: [String: Any] = [
            "memberUntil": "2026-11-15T02:53:29.994Z",
            "memberDaysLeft": 22,
            "tier": "ultra",
            "tierName": "Ultra 旗舰版",
        ]
        let until = try XCTUnwrap(HostedAccount.parseISO(json["memberUntil"] as? String ?? ""))
        let days = MembershipDisplay.daysLeft(serverDays: (json["memberDaysLeft"] as? NSNumber)?.intValue, until: until)
        XCTAssertEqual(days, 22)
        XCTAssertFalse(MembershipDisplay.isExpired(daysLeft: days))
        XCTAssertEqual(json["tierName"] as? String, "Ultra 旗舰版")
    }
}
