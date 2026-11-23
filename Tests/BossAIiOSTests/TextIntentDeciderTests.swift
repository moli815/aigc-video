import XCTest
@testable import BossAI

final class TextIntentDeciderTests: XCTestCase {
    func testLongCopyAloneKeepsNativeProviderDesign() {
        XCTAssertFalse(TextIntentDecider.needsOverlay(userText: "做一张宣传视觉",
                                                      extractedFieldCount: 1,
                                                      extractedCharCount: 40))
    }

    func testFormalDesignAloneDoesNotForceProgrammaticLayout() {
        XCTAssertFalse(TextIntentDecider.needsOverlay(userText: "制作正式宣传图",
                                                      extractedFieldCount: 3,
                                                      extractedCharCount: 20))
    }

    func testExplicitAccuracyUsesOverlayEvenForShortCopy() {
        XCTAssertTrue(TextIntentDecider.needsOverlay(userText: "文字必须准确",
                                                      extractedFieldCount: 1,
                                                      extractedCharCount: 6,
                                                      accuracyRequired: true))
    }

    func testExplicitNoTextOverridesDensity() {
        XCTAssertFalse(TextIntentDecider.needsOverlay(userText: "不要文字",
                                                       extractedFieldCount: 5,
                                                       extractedCharCount: 100))
    }

    func testDecorativeTextCanRemainModelGenerated() {
        XCTAssertFalse(TextIntentDecider.needsOverlay(userText: "文字可以艺术化处理",
                                                       extractedFieldCount: 5,
                                                       extractedCharCount: 100))
    }

    func testLayoutFreedomDoesNotMeanCustomerCopyMayBeWrong() {
        XCTAssertTrue(TextIntentDecider.needsOverlay(userText: "排版随意，但文字必须准确",
            extractedFieldCount: 4, extractedCharCount: 80, accuracyRequired: true))
    }
}
