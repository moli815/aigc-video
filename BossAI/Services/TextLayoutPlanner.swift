import Foundation
import UIKit

/// Scene coordinates follow the same normalized-box approach used by design editors.
/// Copy, geometry, measurement and painting remain separate; no material-specific branches.
struct TextBlockSpec {
    let key: String
    let frame: CGRect
    var alignment: NSTextAlignment = .left
    var colorHex: String = "#FFFFFF"
    var fontScale: CGFloat = 1
    var backdrop: Bool = true

    static func parse(_ raw: [String: Any]) -> TextBlockSpec? {
        guard let key = raw["key"] as? String, !key.isEmpty,
              let x = raw["x"] as? Double, let y = raw["y"] as? Double,
              let width = raw["width"] as? Double, let height = raw["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite),
              x >= 0.02, y >= 0.02, width >= 0.04, height >= 0.025,
              x + width <= 0.98, y + height <= 0.98 else { return nil }
        var block = TextBlockSpec(key: key, frame: CGRect(x: x, y: y, width: width, height: height))
        block.alignment = raw["align"] as? String == "center" ? .center :
            (raw["align"] as? String == "right" ? .right : .left)
        if let hex = raw["color"] as? String,
           hex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil { block.colorHex = hex }
        if let scale = raw["fontScale"] as? Double, scale.isFinite {
            block.fontScale = CGFloat(min(1.5, max(0.75, scale)))
        }
        block.backdrop = raw["backdrop"] as? Bool ?? true
        return block
    }
}

struct TextPlacement {
    let item: TextItem
    let role: TextItem.Role
    let frame: CGRect
    let fontSize: CGFloat
    let alignment: NSTextAlignment
    let colorHex: String
    let backdrop: Bool
}

enum TextLayoutPlanner {
    /// A valid authored scene is used as a whole; partial/malformed scenes use the generic
    /// composition so one missing/duplicate key can never silently omit customer copy.
    static func blocks(items: [TextItem], layout: LayoutSpec, aspect: CGFloat) -> [TextBlockSpec] {
        let proposed = layout.blocks
        if proposed.count == items.count,
           Set(items.map(\.key)).count == items.count,
           Set(proposed.map(\.key)) == Set(items.map(\.key)),
           proposed.allSatisfy({ block in
               let r = block.frame
               return [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) &&
                   r.minX >= 0.02 && r.minY >= 0.02 && r.maxX <= 0.98 && r.maxY <= 0.98 &&
                   r.width >= 0.04 && r.height >= 0.025
           }), !hasCollisions(proposed) {
            return items.map { item in proposed.first(where: { $0.key == item.key })! }
        }
        return fallback(items: items, layout: layout, aspect: aspect)
    }

    static func placements(items: [TextItem], layout: LayoutSpec, canvas: CGSize) throws -> [TextPlacement] {
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else {
            throw TextOverlayError.invalidCanvas
        }
        guard !items.isEmpty else { throw TextOverlayError.emptyContent }
        let boxes = blocks(items: items, layout: layout, aspect: canvas.width / canvas.height)
        let shortEdge = min(canvas.width, canvas.height)
        return try items.enumerated().map { index, item in
            // Fallback uses item order, authored scenes use stable keys. No dictionary trap on
            // duplicated model-generated keys, and no text is discarded.
            let block = boxes[index]
            let role = effectiveRole(item, index: index, items: items)
            let frame = CGRect(x: block.frame.minX * canvas.width, y: block.frame.minY * canvas.height,
                               width: block.frame.width * canvas.width, height: block.frame.height * canvas.height)
            let bounds = fontRange(role)
            let low = shortEdge * bounds.0
            let high = shortEdge * bounds.1 * block.fontScale
            let size = try fittedSize(item: item, role: role, frame: frame, minimum: low, maximum: max(low, high), alignment: block.alignment)
            return TextPlacement(item: item, role: role, frame: frame, fontSize: size,
                                 alignment: block.alignment, colorHex: block.colorHex, backdrop: block.backdrop)
        }
    }

    /// Used BEFORE generating the background. The same boxes drive the final renderer.
    /// Only role and coordinates are transmitted here, never customer copy.
    static func backgroundConstraint(items: [TextItem], layout: LayoutSpec, aspect: CGFloat) -> String {
        let boxes = blocks(items: items, layout: layout, aspect: aspect)
        let regions = boxes.prefix(24).map { box in
            String(format: "x=%.0f%% y=%.0f%% 宽=%.0f%% 高=%.0f%%", Double(box.frame.minX * 100),
                   Double(box.frame.minY * 100), Double(box.frame.width * 100), Double(box.frame.height * 100))
        }.joined(separator: "；")
        return "\n\n【后期文字区域】以下区域稍后由程序排字：\(regions)。为这些区域预留低细节、对比稳定的负空间，视觉主体安排在其他区域。保持用户要求的风格与颜色；不要画文字、伪字、占位字或文本框。"
    }

    static func attributes(role: TextItem.Role, size: CGFloat, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        paragraph.lineSpacing = size * 0.16
        let font = UIFont.systemFont(ofSize: size, weight: role == .title ? .bold : (role == .subtitle ? .medium : .regular))
        return [.font: font, .paragraphStyle: paragraph]
    }

    static func measured(_ text: String, width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> CGSize {
        (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).size
    }

    private static func fittedSize(item: TextItem, role: TextItem.Role, frame: CGRect,
                                   minimum: CGFloat, maximum: CGFloat, alignment: NSTextAlignment) throws -> CGFloat {
        func fits(_ size: CGFloat) -> Bool {
            let attributes = self.attributes(role: role, size: size, alignment: alignment)
            let measured = self.measured(item.text, width: frame.width, attributes: attributes)
            return ceil(measured.height) <= frame.height && ceil(measured.width) <= frame.width + 1
        }
        guard fits(minimum) else { throw TextOverlayError.textOverflow(field: item.key) }
        var low = minimum, high = maximum
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    private static func effectiveRole(_ item: TextItem, index: Int, items: [TextItem]) -> TextItem.Role {
        // Legacy payloads contain only body lines. Give the first short line hierarchy.
        if index == 0, !items.contains(where: { $0.role == .title }), item.role == .body, item.text.count <= 48 { return .title }
        return item.role
    }

    private static func fontRange(_ role: TextItem.Role) -> (CGFloat, CGFloat) {
        switch role {
        case .title: return (0.040, 0.085)
        case .subtitle: return (0.024, 0.037)
        case .body: return (0.020, 0.028)
        case .label: return (0.021, 0.031)
        case .contact: return (0.018, 0.025)
        case .footer: return (0.016, 0.022)
        }
    }

    private static func hasCollisions(_ blocks: [TextBlockSpec]) -> Bool {
        for index in blocks.indices {
            for other in blocks.indices where other > index {
                if blocks[index].frame.intersects(blocks[other].frame) { return true }
            }
        }
        return false
    }

    private static func fallback(items: [TextItem], layout: LayoutSpec, aspect: CGFloat) -> [TextBlockSpec] {
        guard !items.isEmpty else { return [] }
        let margin = min(0.12, max(0.04, layout.marginRatio))
        let width = 1 - margin * 2
        let roles = items.enumerated().map { effectiveRole($0.element, index: $0.offset, items: items) }
        var result = items.map { TextBlockSpec(key: $0.key, frame: .zero) }
        let heads = items.indices.filter { roles[$0] == .title || roles[$0] == .subtitle }
        let details = items.indices.filter { roles[$0] == .body || roles[$0] == .label }
        let feet = items.indices.filter { roles[$0] == .contact || roles[$0] == .footer }
        let centered = layout.preset == "centered"
        let split = layout.preset == "split" || layout.columns == .two
        let bodyChars = details.reduce(0) { $0 + items[$1].text.count }
        let bodyHeight: CGFloat = min(0.43, max(0.19, CGFloat(bodyChars) / (aspect > 1 ? 950 : 650)))
        let footerHeight: CGFloat = feet.isEmpty ? 0 : min(0.19, max(0.07, CGFloat(feet.count) * 0.047))
        func distribute(_ indices: [Int], in area: CGRect, columns: Int, weighted: Bool = false) {
            guard !indices.isEmpty else { return }
            let columns = min(columns, indices.count)
            let rows = Int(ceil(Double(indices.count) / Double(columns)))
            let gap: CGFloat = 0.016
            // Long paragraphs get a full-width region instead of microscopic grid cells.
            if weighted && columns == 1 {
                let weights = indices.map { index -> CGFloat in
                    if roles[index] == .title { return max(2.4, CGFloat(items[index].text.count) / 12) }
                    return max(1, CGFloat(items[index].text.count) / 32)
                }
                let total = weights.reduce(0, +)
                var y = area.minY
                for (offset, index) in indices.enumerated() {
                    let height = (area.height - gap * CGFloat(indices.count - 1)) * weights[offset] / total
                    result[index] = TextBlockSpec(key: items[index].key, frame: CGRect(x: area.minX, y: y, width: area.width, height: height), alignment: centered ? .center : .left)
                    y += height + gap
                }
                return
            }
            let cellWidth = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            for (offset, index) in indices.enumerated() {
                result[index] = TextBlockSpec(key: items[index].key,
                    frame: CGRect(x: area.minX + CGFloat(offset % columns) * (cellWidth + gap),
                                  y: area.minY + CGFloat(offset / columns) * (cellHeight + gap),
                                  width: cellWidth, height: cellHeight), alignment: centered ? .center : .left)
            }
        }
        if split && aspect >= 1.1 {
            distribute(heads, in: CGRect(x: margin, y: 0.12, width: width * 0.48, height: 0.29), columns: 1, weighted: true)
            distribute(details, in: CGRect(x: 0.55, y: 0.14, width: 0.45 - margin, height: 0.63 - footerHeight), columns: 1, weighted: true)
        } else {
            // Headline, visual hero, information band and footer occupy distinct zones.
            distribute(heads, in: CGRect(x: margin, y: 0.07, width: width, height: 0.26), columns: 1, weighted: true)
            let cols = details.count >= 3 && bodyChars < 300 ? (aspect >= 1.2 ? 3 : 2) : 1
            let bodyTop = max(0.37, 0.94 - footerHeight - bodyHeight)
            distribute(details, in: CGRect(x: margin, y: bodyTop, width: width,
                height: 0.92 - footerHeight - bodyTop), columns: cols, weighted: true)
        }
        distribute(feet, in: CGRect(x: margin, y: 0.96 - footerHeight, width: width,
                                    height: max(0.04, footerHeight - 0.02)), columns: aspect >= 1.2 ? 3 : 1, weighted: true)
        return result
    }
}
