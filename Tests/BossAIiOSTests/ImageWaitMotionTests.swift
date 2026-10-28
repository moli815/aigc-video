import XCTest
import SwiftUI
@testable import BossAI

final class ImageWaitMotionTests: XCTestCase {
    func testMotionGathersThenExpandsAndLoops() {
        func radius(_ t: Double) -> Double {
            let p = ImageWaitMotion.frame(index: 7, elapsed: t, width: 360, height: 210)
            return hypot(p.x - 180, p.y - 107.1)
        }
        XCTAssertLessThan(radius(2.7), radius(0.3) * 0.5)
        XCTAssertGreaterThan(radius(5), radius(2.7) * 2)
        XCTAssertEqual(radius(0.3), radius(6.1), accuracy: 0.00001)
    }

    func testStaticAndInvalidInputsStayFinite() {
        for index in 0..<240 {
            let a = ImageWaitMotion.frame(index: index, elapsed: 0, width: 360, height: 210, still: true)
            let b = ImageWaitMotion.frame(index: index, elapsed: 80, width: 360, height: 210, still: true)
            XCTAssertEqual(a.x, b.x); XCTAssertEqual(a.y, b.y)
            XCTAssertTrue((0...1).contains(a.opacity))
            let invalid = ImageWaitMotion.frame(index: index, elapsed: .nan, width: .infinity, height: 210, cycle: .nan)
            XCTAssertTrue(invalid.x.isFinite && invalid.y.isFinite && invalid.radius.isFinite)
        }
    }

    @MainActor func testWaitingCardVisual() throws {
        let renderer = ImageRenderer(content: ImageWaitingRow(state: ImageWaitState(kind: .generate))
            .frame(width: 360).padding(20).environment(\.accessibilityReduceMotion, true))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = "image-wait-c-native"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPoolErrorShowsQuotaAndRenewWithoutLoggingOut() throws {
        let envelope = try XCTUnwrap(APIErrorEnvelope.parse(status: 429, json: [
            "error": "POOL_EXHAUSTED", "message": "本月额度已用完",
            "actions": ["view_quota", "renew"],
            "errorDetail": ["category": "billing", "retryable": false]
        ]))
        XCTAssertFalse(envelope.isSessionFailure)
        XCTAssertFalse(envelope.retryable)
        XCTAssertEqual(FriendlyError.actions(from: envelope.actions).map { $0.id }, ["view_quota", "renew"])
        XCTAssertEqual(FriendlyError.message(for: ChatService.ChatError.envelope(envelope), scene: .chat), "本月额度已用完")
    }
}
