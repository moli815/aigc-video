import XCTest
import UIKit
@testable import BossAI

final class TextLayoutPlannerTests: XCTestCase {
    private var copy: [TextItem] {
        [TextItem(role: .title, key: "title", text: "让城市安全 更有温度"),
         TextItem(role: .subtitle, key: "subtitle", text: "城市综合安全风险管理解决方案"),
         TextItem(role: .label, key: "a", text: "智慧安消 · 隐患闭环"),
         TextItem(role: .label, key: "b", text: "远程监控 · 智能预警"),
         TextItem(role: .label, key: "c", text: "风险减量 · 科技保险"),
         TextItem(role: .contact, key: "phone", text: "185-6866-4567"),
         TextItem(role: .footer, key: "company", text: "中防保全（苏州）科技有限公司")]
    }

    func testDefaultSceneSeparatesHeadlineHeroAndInformation() throws {
        for size in [CGSize(width: 2048, height: 1152), CGSize(width: 1152, height: 2048)] {
            let blocks = try TextLayoutPlanner.placements(items: copy, layout: LayoutSpec(), canvas: size)
            XCTAssertEqual(blocks.map(\.item.text), copy.map(\.text))
            XCTAssertGreaterThan(blocks[0].fontSize, blocks[2].fontSize * 1.5)
            XCTAssertGreaterThan(blocks[2].frame.minY, size.height * 0.45)
            XCTAssertGreaterThan(blocks.last!.frame.minY, size.height * 0.8)
            for (index, block) in blocks.enumerated() {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(block.frame))
                for other in blocks.dropFirst(index + 1) { XCTAssertFalse(block.frame.intersects(other.frame)) }
            }
        }
    }

    func testTypographyScalesWithCanvasInsteadOfRemaining34Points() throws {
        let small = try TextLayoutPlanner.placements(items: copy, layout: LayoutSpec(), canvas: CGSize(width: 1024, height: 576))
        let big = try TextLayoutPlanner.placements(items: copy, layout: LayoutSpec(), canvas: CGSize(width: 2048, height: 1152))
        XCTAssertEqual(big[0].fontSize / small[0].fontSize, 2, accuracy: 0.01)
        XCTAssertGreaterThan(big[0].fontSize, 70)
    }

    func testAuthoredSceneControlsPositionAndAlignment() throws {
        let items = [TextItem(role: .title, key: "headline", text: "春日来信")]
        let layout = LayoutSpec.from(["blocks": [["key": "headline", "x": 0.2, "y": 0.4,
                                                   "width": 0.6, "height": 0.2, "align": "center"]]])
        let result = try TextLayoutPlanner.placements(items: items, layout: layout, canvas: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(result[0].frame.minY, 400, accuracy: 0.01)
        XCTAssertEqual(result[0].alignment, .center)
    }

    func testOverlappingOrPartialAgentSceneFallsBackWithoutLosingCopy() throws {
        let invalid = LayoutSpec.from(["blocks": copy.map { item in
            ["key": item.key, "x": 0.1, "y": 0.1, "width": 0.8, "height": 0.1] as [String: Any]
        }])
        let placements = try TextLayoutPlanner.placements(items: copy, layout: invalid, canvas: CGSize(width: 2048, height: 1152))
        XCTAssertEqual(placements.map(\.item.text), copy.map(\.text))
        XCTAssertGreaterThan(placements[2].frame.minY, 500)
    }

    func testBackgroundReservationContainsCoordinatesButNeverVisibleCopy() {
        let prompt = TextLayoutPlanner.backgroundConstraint(items: copy, layout: LayoutSpec(), aspect: 16.0 / 9)
        XCTAssertTrue(prompt.contains("x="))
        for item in copy { XCTAssertFalse(prompt.contains(item.text)) }
    }

    func testRequestedTypefaceIsSharedByMeasurementAndDrawing() throws {
        let layout = LayoutSpec.from(["fontStyle": "serif"])
        let placements = try TextLayoutPlanner.placements(items: copy, layout: layout, canvas: CGSize(width: 2048, height: 1152))
        XCTAssertTrue(placements.allSatisfy { $0.fontStyle == "serif" })
    }

    func testLightBackgroundGetsOnlyALocalContrastLayer() throws {
        let size = CGSize(width: 1200, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let base = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let items = [TextItem(role: .title, key: "headline", text: "清晰阅读")]
        let result = try TextOverlayRenderer.render(base: base, items: items, layout: LayoutSpec(),
            canvas: CanvasSpec(size: size, expectedAspect: 1))
        let attachment = XCTAttachment(image: result)
        attachment.name = "design-bright-background-contrast"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(result.cgImage?.width, 1200)
    }

    func testTextModeSurvivesEveryDerivedRequest() {
        let original = ImageRequestContext(prompt: "scene", references: [], taskKind: "reference", qualityTier: "high",
            requestedCount: 1, aspectRatio: "16:9", renderIntent: "flat_artwork", structured: nil, layerDecomposition: false)
        let background = original.forTextlessBackground(items: copy)
        XCTAssertEqual(background.textMode, .overlay)
        XCTAssertEqual(background.appendingPrompt(" reserve space").retrying(note: "retry").textMode, .overlay)
        XCTAssertEqual(original.textMode, .native)
    }

    func testRenderVisualSamplesAtExactPixelDimensions() throws {
        for size in [CGSize(width: 2048, height: 1152), CGSize(width: 1152, height: 2048)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let base = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let colors = [UIColor(red: 0.12, green: 0.20, blue: 0.32, alpha: 1).cgColor,
                              UIColor(red: 0.68, green: 0.36, blue: 0.29, alpha: 1).cgColor] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                    end: CGPoint(x: size.width, y: size.height), options: [])
                UIColor.white.withAlphaComponent(0.12).setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width * 0.35, y: size.height * 0.36,
                    width: size.width * 0.4, height: size.height * 0.26)).fill()
            }
            let result = try TextOverlayRenderer.render(base: base, items: copy, layout: LayoutSpec(),
                canvas: CanvasSpec(size: size, expectedAspect: size.width / size.height))
            XCTAssertEqual(result.cgImage?.width, Int(size.width))
            XCTAssertEqual(result.cgImage?.height, Int(size.height))
            let attachment = XCTAttachment(image: result)
            attachment.name = size.width > size.height ? "design-landscape" : "design-portrait"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
