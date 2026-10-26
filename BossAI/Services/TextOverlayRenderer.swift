import Foundation
import UIKit

// TextOverlayRenderer.swift —— 通用「文字后处理」渲染器（2026-10-25）
//
// 定位：**不是**名片专用。任何"大面积、必须准确可读"的文字任务都走它：
// 名片 / 海报 / 证书 / 宣传单 / 菜单 / 信息图 / 课程表 / 价目表 / 包装标签…
//
// 分流原则（不看 taskType，看文字本身）：
//   · 文字少、只是装饰、用户说"可以艺术化" → 直接 Pro 生图，不调本渲染器
//   · 文字多、必须可读、要用于正式场合 → Pro 只出**无字底图**，本渲染器叠字
//   · 用户明确"不要文字" → 只出底图，不叠
//
// 硬约束：
//   1. 唯一合成入口 `render(base:items:layout:canvas:)`，不提供分层拼装 API → 杜绝二次叠字。
//   2. 文字只来自 `items`（由模型提取 / 用户原文），渲染器**不改写**任何字符。
//   3. 在可读字号范围内适配文本框，完整文案仍放不下才报错，不截断。
//   4. 支持横版/竖版/自定义比例，多列、多行、中英文混排。

// MARK: - 输入模型

/// 一条待绘制的文字（字段名 + 原文 + 视觉角色）
struct TextItem: Equatable {
    enum Role: String { case title, subtitle, body, label, contact, footer }
    var role: Role
    var key: String          // 字段名，仅用于报错定位（如 "phone"）
    var text: String         // 原文，逐字绘制，不做任何改写

    /// 新契约用有语义的逐条文字；兼容旧版 structured.text 字符串。
    static func parse(_ value: Any?) -> [TextItem] {
        if let entries = value as? [[String: Any]] {
            return entries.enumerated().compactMap { index, entry in
                guard let text = entry["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                let role = (entry["role"] as? String).flatMap { Role(rawValue: $0) } ?? .body
                let key = (entry["key"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "text-\(index + 1)"
                return TextItem(role: role, key: key, text: text)
            }
        }
        if let legacy = value as? String, !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return legacy.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TextItem(role: .body, key: "legacy-text-\(index + 1)", text: text)
            }
        }
        return []
    }

    static func values(from value: Any?) -> [String] {
        parse(value).map(\.text)
    }
}

/// 版式意图（由模型给出，宽泛描述；渲染器负责落地）
struct LayoutSpec {
    enum Columns: Int { case one = 1, two = 2 }
    var columns: Columns = .one
    /// 左列放哪些角色（默认：标题类）
    var primaryRoles: [TextItem.Role] = [.title, .subtitle, .label]
    var marginRatio: CGFloat = 0.06
    var gutterRatio: CGFloat = 0.04
    /// Generic composition, independent of the deliverable's name.
    var preset: String = "editorial"
    var blocks: [TextBlockSpec] = []
}

extension LayoutSpec {
    /// 从大模型给出的 layout 意图构造；缺什么用安全默认值，但**不丢弃**已给出的字段
    static func from(_ raw: [String: Any]?) -> LayoutSpec {
        var spec = LayoutSpec()
        guard let raw else { return spec }
        if let preset = raw["preset"] as? String,
           ["editorial", "centered", "split"].contains(preset) { spec.preset = preset }
        spec.blocks = (raw["blocks"] as? [[String: Any]] ?? []).compactMap(TextBlockSpec.parse)
        if let cols = raw["columns"] as? Int, cols == 1 || cols == 2 {
            spec.columns = (cols == 1) ? .one : .two
        }
        if let margin = raw["marginRatio"] as? Double, margin > 0.02, margin < 0.2 {
            spec.marginRatio = CGFloat(margin)
        }
        if let gutter = raw["gutterRatio"] as? Double, gutter > 0.01, gutter < 0.15 {
            spec.gutterRatio = CGFloat(gutter)
        }
        if let roles = raw["primaryRoles"] as? [String], !roles.isEmpty {
            let mapped = roles.compactMap { TextItem.Role(rawValue: $0) }
            if !mapped.isEmpty { spec.primaryRoles = mapped }
        }
        return spec
    }
}

struct CanvasSpec {
    var size: CGSize
    /// 期望宽高比（如 16/9）；nil 表示不校验
    var expectedAspect: CGFloat?
    var aspectTolerance: CGFloat = 0.08
}

enum TextOverlayError: LocalizedError, Equatable {
    case emptyContent
    case invalidCanvas
    case wrongAspect(actual: CGFloat, expected: CGFloat)
    case textOverflow(field: String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent: return "没有可绘制的文字内容"
        case .invalidCanvas: return "画布尺寸无效"
        case .wrongAspect(let a, let e):
            return String(format: "底图比例不符（实际 %.2f，要求 %.2f）", a, e)
        case .textOverflow(let field): return "「\(field)」过长，放不进版面，请缩短或调整版式"
        case .renderFailed: return "文字排版失败，请重试"
        }
    }
}

// MARK: - 分流判定（纯函数，可单测）

enum TextIntentDecider {
    /// 是否需要"无字底图 + 程序叠字"
    /// - Parameters:
    ///   - userText: 用户原话
    ///   - extractedFieldCount: 模型提取到的字段数
    ///   - extractedCharCount: 提取到的总字数
    static func needsOverlay(userText: String,
                             extractedFieldCount: Int,
                             extractedCharCount: Int,
                             accuracyRequired: Bool = false) -> Bool {
        let t = userText.lowercased()
        // 明确不要文字 → 不叠
        if t.contains("不要文字") || t.contains("无文字") || t.contains("不要加字") { return false }
        // 大模型判定"必须精确" → 直接程序排版（优先级最高，不受字数影响）
        if accuracyRequired && extractedCharCount > 0 { return true }
        // “排版随意”不是允许写错客户文案，只有明确授权文字艺术化才交给模型。
        if t.contains("艺术字") || t.contains("文字可以艺术化") || t.contains("文字可以随意") { return false }
        // 单个长文案字段同样属于文字密集内容；不能因为 Agent 把多字段合并成一段而漏分流。
        if extractedCharCount >= 40 { return true }
        // 字段多且字数大 → 必须程序排版
        if extractedFieldCount >= 3 && extractedCharCount >= 20 { return true }
        // 关键词兜底（信息类物料，本身就要求文字准确）
        let heavy = ["海报", "名片", "证书", "宣传单", "菜单", "信息图", "课程表", "价目表", "价格表", "标签", "易拉宝"]
        if heavy.contains(where: { t.contains($0) }) && extractedCharCount >= 12 { return true }
        return false
    }
}

// MARK: - 渲染器

enum TextOverlayRenderer {
    static func check(items: [TextItem], layout: LayoutSpec, canvas: CanvasSpec) -> [String] {
        if let expected = canvas.expectedAspect, expected > 0, canvas.size.height > 0,
           abs(canvas.size.width / canvas.size.height - expected) / expected > canvas.aspectTolerance {
            return ["底图比例不符"]
        }
        do {
            _ = try TextLayoutPlanner.placements(items: items, layout: layout, canvas: canvas.size)
            return []
        } catch { return [error.localizedDescription] }
    }

    /// Layout and drawing use identical font metrics. One render, exact output pixels.
    static func render(base: UIImage, items: [TextItem], layout: LayoutSpec, canvas: CanvasSpec) throws -> UIImage {
        let size = canvas.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              base.size.width > 0, base.size.height > 0 else { throw TextOverlayError.invalidCanvas }
        let aspect = size.width / size.height
        let sourceAspect = base.size.width / base.size.height
        guard abs(sourceAspect - aspect) / aspect <= canvas.aspectTolerance else {
            throw TextOverlayError.wrongAspect(actual: sourceAspect, expected: aspect)
        }
        if let expected = canvas.expectedAspect, expected > 0,
           abs(aspect - expected) / expected > canvas.aspectTolerance {
            throw TextOverlayError.wrongAspect(actual: aspect, expected: expected)
        }
        let placements = try TextLayoutPlanner.placements(items: items, layout: layout, canvas: size)
        let format = UIGraphicsImageRendererFormat()
        // UIKit defaults to the DEVICE scale; on a 3x device the old renderer silently
        // created a 6K image from a 2K background, wasting memory without adding detail.
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            base.draw(in: CGRect(origin: .zero, size: size))
            for placement in placements {
                let color = textColor(placement.colorHex)
                if placement.backdrop { drawBackdrop(placement.frame, color: color, canvas: size, in: context.cgContext) }
                var attributes = TextLayoutPlanner.attributes(role: placement.role, size: placement.fontSize, alignment: placement.alignment)
                attributes[.foregroundColor] = color
                let shadow = NSShadow()
                shadow.shadowColor = UIColor.black.withAlphaComponent(0.22)
                shadow.shadowBlurRadius = placement.fontSize * 0.08
                shadow.shadowOffset = CGSize(width: 0, height: placement.fontSize * 0.025)
                attributes[.shadow] = shadow
                (placement.item.text as NSString).draw(with: placement.frame,
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            }
        }
    }

    private static func textColor(_ hex: String) -> UIColor {
        guard hex.count == 7, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return .white }
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static func drawBackdrop(_ frame: CGRect, color: UIColor, canvas: CGSize, in context: CGContext) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let lightText = 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.5
        let background: UIColor = lightText ? .black : .white
        let padding = min(canvas.width, canvas.height) * 0.012
        let region = frame.insetBy(dx: -padding, dy: -padding)
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: region, cornerRadius: padding).cgPath)
        context.clip()
        let colors = [background.withAlphaComponent(lightText ? 0.52 : 0.88).cgColor,
                      background.withAlphaComponent(lightText ? 0.18 : 0.50).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: region.midX, y: region.minY),
                                       end: CGPoint(x: region.midX, y: region.maxY), options: [])
        }
        context.restoreGState()
    }
}
