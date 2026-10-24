import XCTest
@testable import BossAI

// ============================================================================
// ImageTaskPlannerTests —— 图片任务规划器的规则回归（2026-10-24 新增）
//
// 规划器是纯函数（不联网、不调模型），所以这里能给出确定性断言。
// 覆盖五类任务 + 参数推断 + 追问：
//   文生图 / 编辑 / 参考图 / 海报 / 组图，以及比例、张数、档位、文字策略、保留约束。
// ============================================================================

final class ImageTaskPlannerTests: XCTestCase {

    // MARK: - 五类任务分类

    func testPlainGenerate() {
        let plan = ImageTaskPlanner.plan(userText: "画一只橘猫坐在窗台看夕阳，写实摄影")
        XCTAssertEqual(plan.taskType, .generate)
        XCTAssertEqual(plan.outputCount, 1)
        XCTAssertFalse(plan.preserveOriginal)
        XCTAssertEqual(plan.textPolicy, .avoid)
    }

    func testEditWithReferenceImage() {
        let plan = ImageTaskPlanner.plan(userText: "把这张照片的背景改成海边，人物保持不变", referenceCount: 1)
        XCTAssertEqual(plan.taskType, .edit)
        XCTAssertTrue(plan.preserveOriginal, "编辑任务必须保留原图约束")
        XCTAssertTrue(plan.negativeConstraints.contains { $0.contains("不要改变人物面部特征") })
        XCTAssertEqual(plan.qualityTier, "pro", "编辑走高质量档")
    }

    func testReferenceStyleTransfer() {
        let plan = ImageTaskPlanner.plan(userText: "参考这张图的配色，生成一张科技封面", referenceCount: 1)
        XCTAssertEqual(plan.taskType, .reference, "说的是借风格，不该判成编辑")
        XCTAssertFalse(plan.preserveOriginal)
    }

    func testPosterForcesProgrammaticText() {
        let plan = ImageTaskPlanner.plan(userText: "做一张 AI 职业培训宣传海报，价格 2999 元")
        XCTAssertEqual(plan.taskType, .poster)
        XCTAssertEqual(plan.textPolicy, .programmatic, "海报文字必须程序排版")
        XCTAssertEqual(plan.qualityTier, "pro")
        XCTAssertEqual(plan.aspectRatio, "3:4")
        XCTAssertTrue(plan.prompt.contains("不要绘制任何文字"), "海报提示词必须禁止模型画字")
    }

    func testSeriesWithCount() {
        let plan = ImageTaskPlanner.plan(userText: "生成四张风格统一的 AI 科普封面")
        XCTAssertEqual(plan.taskType, .series)
        XCTAssertEqual(plan.outputCount, 4)
        XCTAssertTrue(plan.negativeConstraints.contains { $0.contains("统一配色") })
    }

    // MARK: - 参数推断

    func testCountParsingRejectsNonImageNumbers() {
        XCTAssertEqual(ImageTaskPlanner.parseCount("画 3 张猫"), 3)
        XCTAssertEqual(ImageTaskPlanner.parseCount("四张海报"), 4)
        XCTAssertEqual(ImageTaskPlanner.parseCount("做一个 3 秒的动效说明图"), 1, "3 秒不是 3 张")
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

    // MARK: - 提示词只加约束、不编造内容

    func testPromptKeepsUserWordsAndAddsDirectives() {
        let text = "画一只橘猫坐在窗台看夕阳"
        let plan = ImageTaskPlanner.plan(userText: text)
        XCTAssertTrue(plan.prompt.contains(text), "用户原话必须保留")
        XCTAssertTrue(plan.prompt.contains("画面比例"), "应补充比例要求")
        XCTAssertFalse(plan.prompt.contains("橘猫坐在沙发上"), "不得替用户编造画面内容")
    }

    // MARK: - 与服务端 task_kind 的映射（规划类型必须能落到服务端认识的四个值）

    func testTaskKindMapping() {
        XCTAssertEqual(ImageService.taskKind(for: .generate), "generate")
        XCTAssertEqual(ImageService.taskKind(for: .edit), "edit")
        XCTAssertEqual(ImageService.taskKind(for: .series), "series")
        XCTAssertEqual(ImageService.taskKind(for: .reference), "generate", "参考图生成走普通生成")
        XCTAssertEqual(ImageService.taskKind(for: .poster), "generate", "海报底图仍走生成，文字由排版层负责")
    }
}
