import XCTest
@testable import BossAI

final class ImageQualityPolicyTests: XCTestCase {
    func testAutoRoutingScenarioMatrix() {
        let cases: [(String,String,Int,String?,String?,String)] = [
            ("先出一版草稿","image_generate",0,nil,nil,"fast"),
            ("简单苹果图标","image_generate",0,"fast","simple_visual","fast"),
            ("产品背景改纯白","image_edit",1,"fast","simple_edit","fast"),
            ("保留人脸换背景","image_edit",1,"fast","simple_edit","high"),
            ("两个人友好握手","image_edit",1,"fast","simple_visual","high"),
            ("替换公司Logo","image_edit",2,"fast","simple_edit","high"),
            ("正式终稿","image_generate",0,"fast","final_delivery","high"),
            ("最高质量画一只猫","image_generate",0,"fast","draft","high"),
            ("复杂信息图","image_generate",0,"fast","detailed_layout","high"),
            ("保留产品细节","image_edit",1,nil,nil,"high"),
            ("重新设计这张海报","image_generate",1,nil,nil,"high"),
            ("设计一张海报","image_generate",0,"fast",nil,"high"),
            ("设计一张海报","image_generate",0,"high","simple_visual","high"),
        ]
        for (text,tool,count,tier,reason,expected) in cases {
            XCTAssertEqual(ImageQualityPolicy.decide(userText:text,tool:tool,referenceCount:count,
                modelTier:tier,modelReason:reason,structured:nil).tier,expected,text)
        }
    }
    func testCopyAndPreservedAssetOverrideUnsafeLowTierRecommendation() {
        let copy=(0..<4).map{["text":"信息\($0)"]}
        let cases: [[String:Any]] = [["text":copy],["preserve_assets":[]]]
        for fields in cases {
            XCTAssertEqual(ImageQualityPolicy.decide(userText:"快速做图",tool:"image_generate",referenceCount:0,
                modelTier:"fast",modelReason:"draft",structured:fields).tier,"high")
        }
    }
    func testDesignLibraryIsDiverseAndInjectedInBoundedSubsets() {
        XCTAssertGreaterThanOrEqual(ImageDesignGuidance.references.count,16)
        XCTAssertLessThanOrEqual(ImageDesignGuidance.suggestions(for:"设计海报").count,6)
        XCTAssertTrue(ImageDesignGuidance.suggestions(for:"要动漫绘本风").contains{$0.id=="anime-story"})
        XCTAssertTrue(ImageDesignGuidance.suggestions(for:"水墨国风").contains{$0.id=="ink-space"})
        XCTAssertLessThanOrEqual(ImageDesignGuidance.suggestions(for:"水墨国风").count,4)
        XCTAssertFalse(ImageDesignGuidance.suggestions(for:"不要动漫，要水墨").contains{$0.id=="anime-story"})
    }
    func testLogoReplacementCannotFallThroughToGenerativeRedrawing() {
        for request in ["把海报左上角旧Logo换成我上传的原素材", "将标志替换为这张原图", "Please replace the logo with the uploaded original"] {
            XCTAssertTrue(ImageToolArguments.requiresOriginalAsset(request))
            XCTAssertThrowsError(try ImageToolArguments.decode("{\"prompt\":\"替换标识\",\"source\":\"both\"}", toolName: "image_edit", userText: request))
        }
        for request in ["设计一个新Logo", "把Logo换成红色", "给这张照片换个背景"] {
            XCTAssertFalse(ImageToolArguments.requiresOriginalAsset(request))
        }
        XCTAssertThrowsError(try ImageToolArguments.decode("{\"prompt\":\"替换logo\",\"source\":\"last\"}",
            toolName:"image_edit",userText:"把你生成的海报中的logo换成我们的logo"))
        XCTAssertThrowsError(try ImageToolArguments.decode("{\"prompt\":\"替换logo\",\"source\":\"attached\"}",
            toolName:"image_generate",userText:"把你生成的海报中的logo换成我们的logo"))
        XCTAssertNoThrow(try ImageToolArguments.decode("{\"prompt\":\"设计海报\",\"source\":\"none\"}",
            toolName:"image_generate",userText:"设计一张新海报，不要Logo"))
    }
    func testOptionalFreeTextRouteReasonDoesNotBlockExecutionOrSelectFlash() throws {
        let args=try ImageToolArguments.decode("{\"prompt\":\"测试背景改色\",\"source\":\"attached\",\"quality_tier\":\"fast\",\"quality_reason\":\"中文描述\"}",
            toolName:"image_edit",userText:"调整这张图片")
        XCTAssertNil(args["quality_reason"])
        XCTAssertEqual(ImageQualityPolicy.decide(userText:"调整这张图片",tool:"image_edit",referenceCount:1,
            modelTier:args["quality_tier"] as? String,modelReason:args["quality_reason"] as? String,structured:nil).tier,"high")
    }
}
