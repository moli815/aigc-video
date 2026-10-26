import XCTest
@testable import BossAI

// ============================================================================
// ImageTaskPlannerTests —— 图片任务规划器的规则回归（2026-10-24 新增）
//
// 规划器是纯函数（不联网、不调模型），所以这里能给出确定性断言。
// 覆盖四种执行语义 + 参数推断 + 追问：
//   文生图 / 编辑 / 参考图 / 组图；物料名称不创建额外执行分支。
// ============================================================================

final class ImageTaskPlannerTests: XCTestCase {

    // MARK: - 五类任务分类

    func testPlainGenerate() {
        let plan = ImageTaskPlanner.plan(userText: "画一只橘猫坐在窗台看夕阳，写实摄影")
        XCTAssertEqual(plan.taskType, .generate)
        XCTAssertEqual(plan.outputCount, 1)
    }

    func testEditWithReferenceImage() {
        let plan = ImageTaskPlanner.plan(userText: "把这张照片的背景改成海边，人物保持不变", referenceCount: 1)
        XCTAssertEqual(plan.taskType, .edit)
        XCTAssertEqual(plan.qualityTier, "high", "编辑走高质量档")
    }

    func testReferenceStyleTransfer() {
        let plan = ImageTaskPlanner.plan(userText: "参考这张图的配色，生成一张科技封面", referenceCount: 1)
        XCTAssertEqual(plan.taskType, .reference, "说的是借风格，不该判成编辑")
    }

    func testPosterRedesignWithSourceKeepsReferenceSemanticsAndSourceCanvas() {
        let plan = ImageTaskPlanner.plan(userText: "创建一张现代科技风格海报",
                                         referenceCount: 1,
                                         sourceSize: (width: 1600, height: 900),
                                         userSaid: "帮我重新设计一下这张海报")
        XCTAssertEqual(plan.taskType, .reference, "原图重设计不是纯文生图，也不是像素级局部编辑")
        XCTAssertTrue(plan.preserveSourceAspect, "未要求改比例时沿用原图画布")
        XCTAssertEqual(plan.aspectRatio, "1600:900", "不能被海报默认 3:4 覆盖")
    }

    func testAgentRewriteCannotEraseOriginalReferenceIntent() {
        let plan = ImageTaskPlanner.plan(userText: "生成一张新的蓝色企业宣传图",
                                         referenceCount: 1,
                                         sourceSize: (width: 1200, height: 800),
                                         userSaid: "基于我上传的原图重新设计")
        XCTAssertEqual(plan.taskType, .reference)
        XCTAssertEqual(plan.aspectRatio, "1200:800")
    }

    func testWholePosterRedesignIsNotMisclassifiedAsPixelEditWhenStyleChanges() {
        let text = "重新设计这张海报，整体改成简约科技风"
        let plan = ImageTaskPlanner.plan(userText: text,
                                         referenceCount: 1,
                                         sourceSize: (width: 1600, height: 900),
                                         userSaid: text)
        XCTAssertEqual(plan.taskType, .reference)
        XCTAssertTrue(plan.preserveSourceAspect)
    }

    func testAttachedImageGenerateToolMeansReferenceCreationUnlessUserSaysLocalOnly() {
        let plan = ImageTaskPlanner.plan(userText: "极简科技风企业海报",
                                         referenceCount: 1,
                                         sourceSize: (width: 1600, height: 900),
                                         userSaid: "帮我重新设计一下",
                                         preferReferenceRedesign: true)
        XCTAssertEqual(plan.taskType, .reference)
        XCTAssertTrue(plan.preserveSourceAspect)
    }

    func testReferenceWithUnrepresentableSourceCanvasRequiresExplicitUserChoice() {
        let plan = ImageTaskPlanner.plan(userText: "重新设计这张图",
                                         referenceCount: 1,
                                         sourceSize: (width: 9000, height: 200),
                                         userSaid: "重新设计这张图")
        XCTAssertTrue(plan.needsClarification)
        XCTAssertTrue(plan.preserveSourceAspect)
        XCTAssertNil(plan.targetSize)
        XCTAssertTrue(plan.clarification?.contains("极端比例") == true)
    }

    func testExplicitLocalOnlyChangeRemainsPixelEdit() {
        let text = "重新设计这张照片，只把背景换成海边，其余部分保持原样"
        let plan = ImageTaskPlanner.plan(userText: text,
                                         referenceCount: 1,
                                         sourceSize: (width: 1200, height: 800),
                                         userSaid: text)
        XCTAssertEqual(plan.taskType, .edit)
        XCTAssertTrue(plan.preserveSourceAspect)
    }

    func testArtworkNamesDoNotCreateSpecialPlannerBranches() {
        let plan = ImageTaskPlanner.plan(userText: "做一张 AI 职业培训宣传海报，价格 2999 元")
        XCTAssertEqual(plan.taskType, .generate)
        XCTAssertEqual(plan.qualityTier, "auto")
        XCTAssertEqual(plan.aspectRatio, "1:1", "缺少比例意图时仅使用通用默认，不按物料类型强制竖版")
        XCTAssertEqual(plan.prompt, "做一张 AI 职业培训宣传海报，价格 2999 元",
                       "规划器只分类和归一参数，不再生成第二份提示词")
    }

    func testBusinessCardUsesAgentOrUserAspectWithoutCardSpecificRules() {
        let plan = ImageTaskPlanner.plan(userText: "帮我重新设计一张名片",
                                         aspectRatio: "3:2")
        XCTAssertEqual(plan.taskType, .generate)
        XCTAssertEqual(plan.aspectRatio, "3:2", "名片一词不得覆盖 Agent 对用户需求的比例规划")
        XCTAssertEqual(plan.qualityTier, "auto", "名片一词不得静默触发专属质量档位")
    }

    func testSeriesWithCount() {
        let plan = ImageTaskPlanner.plan(userText: "生成四张风格统一的 AI 科普封面")
        XCTAssertEqual(plan.taskType, .series)
        XCTAssertEqual(plan.outputCount, 4)
    }

    // MARK: - 参数推断

    func testCountParsingRejectsNonImageNumbers() {
        XCTAssertEqual(ImageTaskPlanner.parseCount("画 3 张猫"), 3)
        XCTAssertEqual(ImageTaskPlanner.parseCount("四张海报"), 4)
        XCTAssertEqual(ImageTaskPlanner.parseCount("做一个 3 秒的动效说明图"), 1, "3 秒不是 3 张")
        XCTAssertEqual(ImageTaskPlanner.plan(userText: "生成两张图，每张画四个人").outputCount, 2,
                       "组图数量也不能把四个人读成四张")
    }

    func testAspectNormalization() {
        XCTAssertEqual(ImageTaskPlanner.normalizeAspect("3：4"), "3:4")
        XCTAssertEqual(ImageTaskPlanner.normalizeAspect("16x9"), "16:9")
        XCTAssertEqual(ImageTaskPlanner.normalizeAspect("4*3"), "4:3")
        XCTAssertNil(ImageTaskPlanner.normalizeAspect("随便"))
        XCTAssertNil(ImageTaskPlanner.normalizeAspect(nil))
    }

    func testAspectInferenceFromText() {
        XCTAssertEqual(ImageTaskPlanner.plan(userText: "来一张横版 banner 图").aspectRatio, "16:9")
        XCTAssertEqual(ImageTaskPlanner.plan(userText: "做张方形头像").aspectRatio, "1:1")
        XCTAssertEqual(ImageTaskPlanner.plan(userText: "画一张 9:16 的竖版手机壁纸").aspectRatio, "9:16")
    }

    func testExplicitParametersWin() {
        let plan = ImageTaskPlanner.plan(userText: "画一只猫", requestedCount: 3, aspectRatio: "4:5", qualityTier: "fast")
        XCTAssertEqual(plan.outputCount, 3)
        XCTAssertEqual(plan.aspectRatio, "4:5")
        XCTAssertEqual(plan.qualityTier, "fast")
    }

    // MARK: - 追问

    func testAskForImageWhenEditingWithoutOne() {
        let plan = ImageTaskPlanner.plan(userText: "把背景换成海边", referenceCount: 0)
        XCTAssertTrue(plan.needsClarification, "说改图却没给图，必须问一句")
        XCTAssertNotNil(plan.clarification)
    }

    func testNoQuestionForClearRequest() {
        let plan = ImageTaskPlanner.plan(userText: "画一只橘猫在窗台看夕阳")
        XCTAssertFalse(plan.needsClarification)
        XCTAssertNil(plan.clarification)
    }

    // MARK: - 提示词由 Agent 单独负责，规划器不二次改写

    func testPlannerPreservesPromptWithoutAppendingCompetingDirectives() {
        let text = "画一只橘猫坐在窗台看夕阳"
        let plan = ImageTaskPlanner.plan(userText: text)
        XCTAssertEqual(plan.prompt, text)
        XCTAssertFalse(plan.prompt.contains("画面比例"), "比例走结构化请求参数，不能重复写入 prompt")
    }

    // MARK: - 与服务端 task_kind 的映射（规划类型必须能落到服务端认识的四个值）

    func testTaskKindMapping() {
        XCTAssertEqual(ImageService.taskKind(for: .generate), "generate")
        XCTAssertEqual(ImageService.taskKind(for: .edit), "edit")
        XCTAssertEqual(ImageService.taskKind(for: .series), "series")
        XCTAssertEqual(ImageService.taskKind(for: .reference), "reference", "参考图创作需与局部编辑区分")
    }

    // MARK: - 质量档位契约（10-25 修复：服务端只认 auto/fast/high）

    func testQualityTierNormalization() {
        XCTAssertEqual(ImageTaskPlanner.normalizeQualityTier("pro"), "high", "历史 'pro' 必须映射成 high")
        XCTAssertEqual(ImageTaskPlanner.normalizeQualityTier("HD"), "high")
        XCTAssertEqual(ImageTaskPlanner.normalizeQualityTier("flash"), "fast")
        XCTAssertEqual(ImageTaskPlanner.normalizeQualityTier("auto"), "auto")
        XCTAssertEqual(ImageTaskPlanner.normalizeQualityTier("随便"), "auto", "未知档位不能硬猜")
        XCTAssertEqual(ImageTaskPlanner.normalizeQualityTier(nil), "auto")
    }

    func testPlannerNeverEmitsPro() {
        for text in ["做一张海报", "把这张图改成海边", "画一只猫", "生成四张封面"] {
            let plan = ImageTaskPlanner.plan(userText: text, referenceCount: text.contains("这张") ? 1 : 0)
            XCTAssertTrue(["auto", "fast", "high"].contains(plan.qualityTier),
                          "规划器只能输出 auto/fast/high，实际：\(plan.qualityTier)（\(text)）")
        }
    }
}
