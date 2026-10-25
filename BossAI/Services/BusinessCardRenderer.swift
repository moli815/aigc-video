import Foundation
import UIKit

// BusinessCardRenderer.swift —— 名片专用渲染器（2026-10-25）
//
// 为什么不复用 PosterComposer：后者只会画"标题 + 副标题 + ≤4 条要点"，
// 名片真正需要的是**横版左右分栏 + 六个固定字段**（Logo/姓名/职位/电话/邮箱/地址），
// 还要保证长地址不溢出、不重叠。硬塞进 PosterComposer 只会把两个场景都拖坏。
//
// 硬约束：
//   1. **只有一个合成入口** `render(card:on:)`，不提供分层拼装 API —— 杜绝二次渲染。
//   2. 精确文字（姓名/电话/邮箱/地址）**只能**由这里用系统字体绘制，绝不交给图片模型。
//   3. 放不下就抛 `BusinessCardError.textOverflow`，绝不悄悄缩字号或截断。
//   4. 版式固定横版：左侧 Logo + 姓名 + 职位，右侧联系方式。不套用竖版海报布局。

/// 名片业务字段（全部为客户真实信息，不允许模型生成）
struct BusinessCard: Equatable {
    var name: String
    var title: String
    var phone: String
    var email: String
    var address: String
    var company: String
    /// Logo 可选；为 nil 时左侧留白，不画占位图形
    var logo: UIImage?

    static func == (lhs: BusinessCard, rhs: BusinessCard) -> Bool {
        lhs.name == rhs.name && lhs.title == rhs.title && lhs.phone == rhs.phone
            && lhs.email == rhs.email && lhs.address == rhs.address
            && lhs.company == rhs.company && lhs.logo === rhs.logo
    }
}

enum BusinessCardError: LocalizedError, Equatable {
    case emptyRequiredFields
    case textOverflow(String)     // 附带是哪个字段溢出
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .emptyRequiredFields: return "名片缺少必填信息（至少要有姓名）"
        case .textOverflow(let field): return "名片「\(field)」过长，放不进版面，请缩短后重试"
        case .renderFailed: return "名片排版失败，请重试"
        }
    }
}

enum BusinessCardRenderer {

    /// 版式常量（画布宽度的比例，保证不同分辨率下观感一致）
    private static let marginRatio: CGFloat = 0.06
    private static let leftColumnRatio: CGFloat = 0.42     // 左栏（Logo/姓名/职位）
    private static let gutterRatio: CGFloat = 0.04

    // MARK: - 排版校验（纯函数，可单测）

    /// 文本在给定字号下的宽度（真实字体度量）
    static func textWidth(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]).width
    }

    /// 估算行数（至少 1 行）
    static func lines(_ text: String, size: CGFloat, maxWidth: CGFloat, weight: UIFont.Weight = .regular) -> Int {
        guard !text.isEmpty, maxWidth > 0 else { return 0 }
        return max(1, Int(ceil(textWidth(text, size: size, weight: weight) / maxWidth)))
    }

    /// 绘制前判定能否放下。放不下就返回问题，由调用方拒绝出图。
    static func checkLayout(card: BusinessCard, canvas: CGSize) -> [String] {
        guard canvas.width > 0, canvas.height > 0 else { return ["画布尺寸无效"] }
        var issues: [String] = []
        if card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("姓名为空")
        }
        let margin = canvas.width * marginRatio
        let leftW = canvas.width * leftColumnRatio - margin
        let rightW = canvas.width - leftW - margin * 2 - canvas.width * gutterRatio
        if lines(card.name, size: 34, maxWidth: leftW, weight: .bold) > 2 { issues.append("姓名") }
        if lines(card.title, size: 18, maxWidth: leftW) > 2 { issues.append("职位") }
        if lines(card.company, size: 16, maxWidth: leftW) > 2 { issues.append("公司") }
        if lines(card.phone, size: 20, maxWidth: rightW) > 1 { issues.append("电话") }
        if lines(card.email, size: 18, maxWidth: rightW) > 1 { issues.append("邮箱") }
        if lines(card.address, size: 18, maxWidth: rightW) > 3 { issues.append("地址") }
        // 六行联系信息 + 行距必须落在画布 62% 高度内（剩下给底图呼吸）
        let contactH = CGFloat(3) * 30 + CGFloat(2) * 34
        if contactH > canvas.height * 0.62 { issues.append("联系方式整体过高") }
        return issues
    }

    // MARK: - 唯一合成入口

    /// 在无字底图上完成**一次**名片合成。
    /// - Note: 调用方拿到返回值后不得再叠加任何文字层（这是"只渲染一次"的保证）。
    static func render(card: BusinessCard, on base: UIImage) throws -> UIImage {
        let size = base.size.width > 0 ? base.size : CGSize(width: 1600, height: 1000)
        let issues = checkLayout(card: card, canvas: size)
        if !issues.isEmpty {
            if issues.contains("姓名为空") { throw BusinessCardError.emptyRequiredFields }
            throw BusinessCardError.textOverflow(issues[0])
        }

        let margin = size.width * marginRatio
        let leftW = size.width * leftColumnRatio - margin
        let gutter = size.width * gutterRatio
        let rightX = margin + leftW + gutter
        let rightW = size.width - rightX - margin

        let renderer = UIGraphicsImageRenderer(size: size)
        let output = renderer.image { ctx in
            base.draw(in: CGRect(origin: .zero, size: size))

            // 左侧压暗带：保证白字在任意底图上可读（只画一次）
            UIColor.black.withAlphaComponent(0.42).setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: margin + leftW + gutter * 0.6, height: size.height)).fill()

            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping

            func draw(_ text: String, font: UIFont, color: UIColor, rect: CGRect) {
                guard !text.isEmpty else { return }
                (text as NSString).draw(in: rect, withAttributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: para,
                ])
            }

            // ── 左栏：Logo → 公司 → 姓名 → 职位（自下而上排，底对齐更稳） ──
            var cursorY = size.height - margin
            let titleH: CGFloat = 26
            let nameH: CGFloat = 44
            let companyH: CGFloat = 24

            cursorY -= titleH
            draw(card.title, font: .systemFont(ofSize: 18), color: UIColor.white.withAlphaComponent(0.88),
                 rect: CGRect(x: margin, y: cursorY, width: leftW, height: titleH))
            cursorY -= nameH + 4
            draw(card.name, font: .boldSystemFont(ofSize: 34), color: .white,
                 rect: CGRect(x: margin, y: cursorY, width: leftW, height: nameH))
            cursorY -= companyH + 2
            draw(card.company, font: .systemFont(ofSize: 16), color: UIColor.white.withAlphaComponent(0.8),
                 rect: CGRect(x: margin, y: cursorY, width: leftW, height: companyH))

            if let logo = card.logo {
                let logoMax = min(leftW * 0.55, size.height * 0.22)
                let ratio = logo.size.height > 0 ? logo.size.width / logo.size.height : 1
                let logoW = min(logoMax, logoMax * ratio)
                let logoH = logoW / max(ratio, 0.01)
                let logoRect = CGRect(x: margin, y: cursorY - logoH - 18, width: logoW, height: logoH)
                // 保持比例绘制，不裁切 Logo
                logo.draw(in: logoRect)
            }

            // ── 右栏：电话 / 邮箱 / 地址（从上到下，标签 + 值同一行） ──
            var y = size.height - margin - 96
            let labelW: CGFloat = 64
            func drawContact(_ label: String, _ value: String, size fontSize: CGFloat) {
                guard !value.isEmpty else { return }
                draw(label, font: .systemFont(ofSize: fontSize - 2), color: UIColor.white.withAlphaComponent(0.55),
                     rect: CGRect(x: rightX, y: y, width: labelW, height: 28))
                draw(value, font: .systemFont(ofSize: fontSize), color: .white,
                     rect: CGRect(x: rightX + labelW, y: y, width: rightW - labelW, height: 28))
                y -= 34
            }
            drawContact("电话", card.phone, size: 20)
            drawContact("邮箱", card.email, size: 18)
            y -= 6
            draw("地址", font: .systemFont(ofSize: 16), color: UIColor.white.withAlphaComponent(0.55),
                 rect: CGRect(x: rightX, y: y, width: labelW, height: 90))
            draw(card.address, font: .systemFont(ofSize: 18), color: .white,
                 rect: CGRect(x: rightX + labelW, y: y, width: rightW - labelW, height: 90))
        }
        return output
    }
}
