import XCTest
@testable import BossAI

// ============================================================================
// 图片任务可见文案 + 比例策略（10-25）
//
// 锁两件事：
//   1) 用户能看到的图片文案**只有那五句**，任何新文案都必须先改这里；
//   2) 编辑任务默认锁原图比例：模型自己塞的 aspect_ratio 不算用户授权。
// ============================================================================
final class ImageTaskStatusTests: XCTestCase {

    private static let allowed = [
        "正在生成图片", "正在处理图片", "正在整理图片",
        "图片已生成", "图片生成失败，请重试", "原图无法完整保留，请重新选择比例",
    ]

    func testWaitTextPerKind() {
        XCTAssertEqual(ImageTaskStatus.waitText(.generate), "正在生成图片")
        XCTAssertEqual(ImageTaskStatus.waitText(.edit), "正在处理图片")
        XCTAssertEqual(ImageTaskStatus.waitText(.textOverlay), "正在整理图片")
        XCTAssertEqual(ImageTaskStatus.waitText(.series), "正在生成图片")
    }

    func testDoneAndFailureTextAreInAllowedSet() {
        XCTAssertEqual(ImageTaskStatus.doneText, "图片已生成")
        XCTAssertEqual(ImageTaskStatus.Failure.generateFailed.message, "图片生成失败，请重试")
        XCTAssertEqual(ImageTaskStatus.Failure.aspectMismatch.message, "原图无法完整保留，请重新选择比例")
        for text in [ImageTaskStatus.doneText,
                     ImageTaskStatus.Failure.generateFailed.message,
                     ImageTaskStatus.Failure.aspectMismatch.message] {
            XCTAssertTrue(Self.allowed.contains(text), "出现了不在白名单里的文案：\(text)")
        }
    }

    /// 文案里不许出现内部信息（模型名/耗时/阶段/字段名）
    func testNoInternalLeakInVisibleText() {
        let banned = ["秒", "Pro", "pro", "prompt", "taskKind", "requestId", "规划", "字段", "比例 ", "FLASH"]
        let all = Self.allowed
        for text in all {
            for word in banned where text.contains(word) {
                // "重新选择比例" 里的"比例"是允许的（用户能照做），只拦"比例 "带参数的形式
                if word == "比例 " { continue }
                XCTFail("文案「\(text)」包含内部信息「\(word)」")
            }
        }
    }

    func testWaitStateExposesKindText() {
        XCTAssertEqual(ImageWaitState(kind: .edit).text, "正在处理图片")
    }
}

// MARK: - 编辑任务的几何策略（P 图不裁切的规则层）

final class ImageEditAspectPolicyTests: XCTestCase {

    private let landscape: (width: Int, height: Int) = (4032, 3024)   // 4:3 横图
    private let portrait: (width: Int, height: Int) = (1200, 1600)    // 3:4 竖图

    func testEditWithoutRatioLocksSourceAspect() {
        let plan = ImageTaskPlanner.plan(userText: "把背景换成海边",
                                         referenceCount: 1,
                                         sourceSize: landscape,
                                         userSaid: "把背景换成海边")
        XCTAssertEqual(plan.taskType, .edit)
        XCTAssertTrue(plan.preserveSourceAspect, "编辑任务默认必须保留原图画布")
        XCTAssertFalse(plan.allowCrop, "用户没要求改比例就不许裁切")
        XCTAssertNotNil(plan.targetSize, "必须给出显式像素尺寸，比例才锁得住")
        XCTAssertFalse(plan.aspectRatio.hasPrefix("1:1"), "编辑任务绝不能再默认 1:1")
        XCTAssertTrue(plan.prompt.contains("不裁切"), "提示词必须带几何约束")
        XCTAssertFalse(plan.prompt.contains("画面比例 1:1"), "不能写死 1:1 这种重构指令")
    }

    func testModelSuppliedRatioIsIgnoredForEdit() {
        // 模型经常顺手传 aspect_ratio=1:1；这不是用户授权，必须忽略
        let plan = ImageTaskPlanner.plan(userText: "把这张照片里的女士旁边加一个人",
                                         referenceCount: 1,
                                         aspectRatio: "1:1",
                                         sourceSize: landscape,
                                         userSaid: "在这个人左边 p 一个马云 两个人友好握手")
        XCTAssertFalse(plan.allowCrop, "模型自带的比例不算用户授权")
        XCTAssertTrue(plan.preserveSourceAspect)
        XCTAssertNotNil(plan.targetSize)
    }

    func testUserExplicitRatioAllowsCrop() {
        let plan = ImageTaskPlanner.plan(userText: "把这张照片改成 1:1 方图",
                                         referenceCount: 1,
                                         sourceSize: landscape,
                                         userSaid: "把这张照片改成 1:1 方图")
        XCTAssertTrue(plan.allowCrop, "用户明确要方图，才允许裁切")
        XCTAssertEqual(plan.aspectRatio, "1:1")
        XCTAssertFalse(plan.preserveSourceAspect)
    }

    func testSixteenByNinePhotoNotForcedToSquare() {
        let plan = ImageTaskPlanner.plan(userText: "只换背景，别的不动",
                                         referenceCount: 1,
                                         sourceSize: (1920, 1080),
                                         userSaid: "只换背景，别的不动")
        XCTAssertTrue(plan.preserveSourceAspect)
        guard let size = plan.targetSize else { return XCTFail("缺 targetSize") }
        let parts = size.split(separator: "x").compactMap { Double($0) }
        XCTAssertEqual(parts[0] / parts[1], 1920.0 / 1080.0, accuracy: 0.01, "16:9 不能变成 1:1")
    }

    func testPortraitEditKeepsPortrait() {
        let plan = ImageTaskPlanner.plan(userText: "在下半部分加一行人群",
                                         referenceCount: 1,
                                         sourceSize: portrait,
                                         userSaid: "在下半部分加一行人群")
        guard let size = plan.targetSize else { return XCTFail("缺 targetSize") }
        let parts = size.split(separator: "x").compactMap { Double($0) }
        XCTAssertLessThan(parts[0] / parts[1], 1.0, "竖图必须还是竖图")
    }

    /// 文生图不受编辑规则影响：没有参考图就按用户要求/默认比例走
    func testGeneratePathUnaffected() {
        let plan = ImageTaskPlanner.plan(userText: "画一只橘猫，横版 banner",
                                         referenceCount: 0,
                                         sourceSize: landscape)
        XCTAssertEqual(plan.aspectRatio, "16:9")
        XCTAssertFalse(plan.preserveSourceAspect)
        XCTAssertNil(plan.targetSize)
    }
}
