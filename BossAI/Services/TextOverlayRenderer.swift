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
//   3. 放不下就抛 `textOverflow`，不缩字号、不截断。
//   4. 支持横版/竖版/自定义比例，多列、多行、中英文混排。

// MARK: - 输入模型

/// 一条待绘制的文字（字段名 + 原文 + 视觉角色）
struct TextItem: Equatable {
    enum Role: String { case title, subtitle, body, label, contact, footer }
    var role: Role
    var key: String          // 字段名，仅用于报错定位（如 "phone"）
    var text: String         // 原文，逐字绘制，不做任何改写
}

/// 版式意图（由模型给出，宽泛描述；渲染器负责落地）
struct LayoutSpec {
    enum Columns: Int { case one = 1, two = 2 }
    var columns: Columns = .two
    /// 左列放哪些角色（默认：标题类）
    var primaryRoles: [TextItem.Role] = [.title, .subtitle, .label]
    var marginRatio: CGFloat = 0.06
    var gutterRatio: CGFloat = 0.04
}

extension LayoutSpec {
    /// 从大模型给出的 layout 意图构造；缺什么用安全默认值，但**不丢弃**已给出的字段
    static func from(_ raw: [String: Any]?) -> LayoutSpec {
        var spec = LayoutSpec()
        guard let raw else { return spec }
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
        // 明确"可以艺术化/随便画" → 交给模型
        if t.contains("艺术字") || t.contains("文字可以") || t.contains("随意") { return false }
        // 大模型判定"必须精确" → 直接程序排版（优先级最高，不受字数影响）
        if accuracyRequired && extractedCharCount > 0 { return true }
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

    /// 校验：能否放下。返回问题列表（空 = 可渲染）
    static func check(items: [TextItem], layout: LayoutSpec, canvas: CanvasSpec) -> [String] {
        guard canvas.size.width > 0, canvas.size.height > 0 else { return ["画布尺寸无效"] }
        guard !items.isEmpty else { return ["没有可绘制的文字内容"] }

        var issues: [String] = []
        if let expected = canvas.expectedAspect, expected > 0 {
            let actual = canvas.size.width / canvas.size.height
            if abs(actual - expected) / expected > canvas.aspectTolerance {
                issues.append("底图比例不符")
            }
        }
        let (leftRect, rightRect) = columnRects(layout: layout, canvas: canvas.size)
        let leftItems = items.filter { layout.primaryRoles.contains($0.role) }
        let others = items.filter { !layout.primaryRoles.contains($0.role) }

        if usedHeight(leftItems, width: leftRect.width) > leftRect.height { issues.append("左栏文字超出") }
        if usedHeight(others, width: rightRect.width) > rightRect.height { issues.append("右栏文字超出") }
        // 单条超长也要报出来（定位到具体字段）
        for item in items {
            let w = item.role == .title ? leftRect.width : rightRect.width
            if lines(item.text, size: fontSize(for: item.role), bold: item.role == .title, maxWidth: w) > maxLines(for: item.role) {
                issues.append(item.key)
            }
        }
        return issues
    }

    /// 唯一合成入口：在无字底图上完成**一次**文字绘制
    static func render(base: UIImage, items: [TextItem], layout: LayoutSpec, canvas: CanvasSpec) throws -> UIImage {
        let size = canvas.size.width > 0 ? canvas.size : base.size
        guard size.width > 0, size.height > 0 else { throw TextOverlayError.invalidCanvas }
        guard !items.isEmpty else { throw TextOverlayError.emptyContent }
        if let expected = canvas.expectedAspect, expected > 0 {
            let actual = size.width / size.height
            if abs(actual - expected) / expected > canvas.aspectTolerance {
                throw TextOverlayError.wrongAspect(actual: actual, expected: expected)
            }
        }
        let issues = check(items: items, layout: layout, canvas: CanvasSpec(size: size,
                                                                          expectedAspect: canvas.expectedAspect,
                                                                          aspectTolerance: canvas.aspectTolerance))
        if let field = issues.first(where: { $0 != "底图比例不符" }) {
            throw TextOverlayError.textOverflow(field: field)
        }

        let margin = size.width * layout.marginRatio
        let (leftRect, rightRect) = columnRects(layout: layout, canvas: size)

        let renderer = UIGraphicsImageRenderer(size: size)
        let out = renderer.image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))

            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping

            func draw(_ item: TextItem, in rect: CGRect, y: inout CGFloat) {
                let font = item.role == .title
                    ? UIFont.boldSystemFont(ofSize: fontSize(for: item.role))
                    : UIFont.systemFont(ofSize: fontSize(for: item.role))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color(for: item.role),
                    .paragraphStyle: para,
                ]
                let h = (item.text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                             attributes: attrs, context: nil).height
                (item.text as NSString).draw(in: CGRect(x: rect.minX, y: y, width: rect.width, height: ceil(h)),
                                             withAttributes: attrs)
                y += ceil(h) + lineGap(for: item.role)
            }

            // 左栏：标题类，自底向上排（与常见名片/海报版式一致）
            var leftY = leftRect.maxY
            for item in items.filter({ layout.primaryRoles.contains($0.role) }).reversed() {
                let font = item.role == .title
                    ? UIFont.boldSystemFont(ofSize: fontSize(for: item.role))
                    : UIFont.systemFont(ofSize: fontSize(for: item.role))
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
                let h = (item.text as NSString).boundingRect(with: CGSize(width: leftRect.width, height: .greatestFiniteMagnitude),
                                                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                             attributes: attrs, context: nil).height
                leftY -= ceil(h) + lineGap(for: item.role)
                var y = leftY
                draw(item, in: leftRect, y: &y)
            }

            // 右栏：正文/联系方式，自顶向下
            var rightY = rightRect.minY
            for item in items.filter({ !layout.primaryRoles.contains($0.role) }) {
                draw(item, in: rightRect, y: &rightY)
            }
            _ = margin
        }
        return out
    }

    // MARK: - 版式计算

    private static func columnRects(layout: LayoutSpec, canvas: CGSize) -> (CGRect, CGRect) {
        let margin = canvas.width * layout.marginRatio
        let gutter = canvas.width * layout.gutterRatio
        if layout.columns == .one {
            let r = CGRect(x: margin, y: margin, width: canvas.width - margin * 2, height: canvas.height - margin * 2)
            return (r, r)
        }
        let leftW = (canvas.width - margin * 2 - gutter) * 0.42
        let left = CGRect(x: margin, y: margin, width: leftW, height: canvas.height - margin * 2)
        let right = CGRect(x: margin + leftW + gutter, y: margin,
                           width: canvas.width - margin * 2 - leftW - gutter,
                           height: canvas.height - margin * 2)
        return (left, right)
    }

    private static func fontSize(for role: TextItem.Role) -> CGFloat {
        switch role {
        case .title: return 34
        case .subtitle: return 22
        case .label: return 16
        case .contact: return 18
        case .body: return 17
        case .footer: return 13
        }
    }

    private static func lineGap(for role: TextItem.Role) -> CGFloat {
        switch role {
        case .title: return 12
        case .subtitle: return 8
        default: return 6
        }
    }

    private static func maxLines(for role: TextItem.Role) -> Int {
        switch role {
        case .title: return 2
        case .subtitle: return 2
        case .body, .contact, .label: return 3
        case .footer: return 2
        }
    }

    private static func color(for role: TextItem.Role) -> UIColor {
        role == .footer ? UIColor.white.withAlphaComponent(0.8) : .white
    }

    private static func textWidth(_ text: String, size: CGFloat, bold: Bool) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)]).width
    }

    static func lines(_ text: String, size: CGFloat, bold: Bool, maxWidth: CGFloat) -> Int {
        guard !text.isEmpty, maxWidth > 0 else { return 0 }
        return max(1, Int(ceil(textWidth(text, size: size, bold: bold) / maxWidth)))
    }

    private static func usedHeight(_ items: [TextItem], width: CGFloat) -> CGFloat {
        items.reduce(0) { acc, item in
            let n = lines(item.text, size: fontSize(for: item.role), bold: item.role == .title, maxWidth: width)
            return acc + CGFloat(n) * (fontSize(for: item.role) * 1.3) + lineGap(for: item.role)
        }
    }
}
