import Foundation
import UIKit

// PosterLayout.swift —— 名片 / 海报的「程序排版」层（2026-10-24 第二阶段）
//
// 为什么必须自己排字：图像模型画汉字必错（笔画粘连、错字、数字变形）。
// 正确分工是——模型只出**不含文字**的底图，所有标题/姓名/电话/价格/地址由这里用真实字体绘制。
//
// 设计边界（刻意不做的东西）：
//   · 不做可视化模板编辑器，不做拖拽；模板是代码里的固定版式。
//   · 不猜内容：字段由调用方（规划器 + 工具参数）给全，缺就少画一行，不编造。
//   · 不做自动缩放全图适配：文字放不下就**报问题**（调用方决定截断还是换版式），
//     悄悄缩字号会出现"打印出来看不清"的坑。

/// 版式：目前只有一种通用竖版（底图 + 底部信息区），先满足名片/宣传图。
enum PosterStyle: String {
    case card      // 名片/宣传图：底部压暗 + 标题/副标题/要点
    case plain     // 只要标题：图上一个标题就够
}

/// 要绘制的文字内容（全部为真实文本，不由模型生成）
struct PosterContent: Equatable {
    var title: String
    var subtitle: String
    var bullets: [String]
    var footer: String

    /// 从工具参数里取内容；取不到标题返回 nil（调用方应退回普通生图）。
    /// 兼容两种来源：模型给的 `structured`，以及用户原话的第一行。
    static func from(args: [String: Any]?, prompt: String) -> PosterContent? {
        let structured = args?["structured"] as? [String: Any] ?? [:]
        func pick(_ keys: [String]) -> String {
            for k in keys {
                if let v = structured[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return v.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }
        var title = pick(["title", "标题", "名称", "姓名", "company", "公司"])
        let subtitle = pick(["subtitle", "副标题", "slogan", "职位", "title_sub"])
        var bullets: [String] = []
        if let arr = structured["bullets"] as? [String] {
            bullets = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let arr = structured["points"] as? [String] {
            bullets = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let footer = pick(["footer", "底部", "contact", "电话", "联系方式"])

        if title.isEmpty {
            // 退回用户原话：取第一行、去掉指令性前缀，控制长度
            let firstLine = prompt.split(separator: "\n").first.map(String.init) ?? prompt
            title = firstLine
                .replacingOccurrences(of: "帮我", with: "")
                .replacingOccurrences(of: "做一张", with: "")
                .replacingOccurrences(of: "生成一张", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = PosterLayout.sanitized(title, max: 40)
        guard !title.isEmpty else { return nil }
        return PosterContent(title: title,
                             subtitle: PosterLayout.sanitized(subtitle, max: 40),
                             bullets: Array(bullets.prefix(PosterLayout.maxBullets)).map { PosterLayout.sanitized($0, max: 30) },
                             footer: PosterLayout.sanitized(footer, max: 40))
    }
}

/// 排版问题（给调用方决策，不吞掉）
enum PosterLayoutIssue: String, Equatable {
    case titleTooLong      // 标题预计超过 2 行
    case subtitleTooLong   // 副标题预计超过 2 行
    case tooManyBullets    // 要点超过上限
    case textOverflow      // 文字块总高度超过安全区
}

enum PosterLayout {

    static let maxBullets = 4
    /// 底部信息区最多占图高比例（超过就报溢出，不自动缩字号）
    static let maxTextAreaRatio: CGFloat = 0.55

    // MARK: - 纯函数（可单测）

    /// 去掉换行/多余空格并截断
    static func sanitized(_ raw: String, max: Int) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max))
    }

    /// 文本在给定字号下的估算宽度（用真实字体度量，不用瞎猜）
    static func textWidth(_ text: String, fontSize: CGFloat, weight: UIFont.Weight = .regular) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// 估算行数（至少 1 行）。用于排版前的溢出判断。
    static func estimatedLines(_ text: String, fontSize: CGFloat, maxWidth: CGFloat, weight: UIFont.Weight = .regular) -> Int {
        guard !text.isEmpty, maxWidth > 0 else { return 0 }
        let width = textWidth(text, fontSize: fontSize, weight: weight)
        return max(1, Int(ceil(width / maxWidth)))
    }

    /// 检查内容是否能在给定画布里放下（在绘制**之前**给结论）
    static func checkLayout(_ content: PosterContent, canvas: CGSize) -> [PosterLayoutIssue] {
        guard canvas.width > 0, canvas.height > 0 else { return [.textOverflow] }
        let margin = canvas.width * 0.06
        let textWidthMax = canvas.width - margin * 2
        var issues: [PosterLayoutIssue] = []

        if estimatedLines(content.title, fontSize: 34, maxWidth: textWidthMax, weight: .bold) > 2 {
            issues.append(.titleTooLong)
        }
        if !content.subtitle.isEmpty,
           estimatedLines(content.subtitle, fontSize: 20, maxWidth: textWidthMax) > 2 {
            issues.append(.subtitleTooLong)
        }
        if content.bullets.count > maxBullets {
            issues.append(.tooManyBullets)
        }
        let titleH = CGFloat(estimatedLines(content.title, fontSize: 34, maxWidth: textWidthMax, weight: .bold)) * 41
        let subH = content.subtitle.isEmpty ? 0
            : CGFloat(estimatedLines(content.subtitle, fontSize: 20, maxWidth: textWidthMax)) * 26
        let bulletH = CGFloat(content.bullets.count) * 26
        let footerH: CGFloat = content.footer.isEmpty ? 0 : 22
        if (titleH + subH + bulletH + footerH) > canvas.height * maxTextAreaRatio {
            issues.append(.textOverflow)
        }
        return issues
    }

    // MARK: - 绘制

    /// 把文字画到底图上，返回新图（**不修改原图**，调用方另存为新版本）。
    static func render(background: UIImage, content: PosterContent, style: PosterStyle = .card) -> UIImage {
        let size = background.size.width > 0 ? background.size : CGSize(width: 1024, height: 1365)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            background.draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            let margin = size.width * 0.06
            let textWidthMax = size.width - margin * 2

            // 底部压暗：保证白字在任何底图上都读得清（对比度问题在这里一次性解决）
            if style == .card {
                let scrimHeight = size.height * 0.5
                let colors = [UIColor.black.withAlphaComponent(0).cgColor,
                              UIColor.black.withAlphaComponent(0.78).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                             colors: colors as CFArray,
                                             locations: [0, 1]) {
                    cg.saveGState()
                    cg.clip(to: CGRect(x: 0, y: size.height - scrimHeight, width: size.width, height: scrimHeight))
                    cg.drawLinearGradient(gradient,
                                          start: CGPoint(x: 0, y: size.height - scrimHeight),
                                          end: CGPoint(x: 0, y: size.height),
                                          options: [])
                    cg.restoreGState()
                }
            }

            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            para.alignment = .left

            // 测量与绘制分两步：先算出整块文字的高度，再从底部往上定起点，
            // 确保无论几条要点都不会出界（一次性算位置最容易犯的错就是画到画布外）。
            // 重新精确排版（测量与绘制分离，避免一次性算错导致文字出界）
            var blocks: [(String, UIFont, UIColor, CGFloat)] = []
            if !content.footer.isEmpty {
                blocks.append((content.footer, .systemFont(ofSize: 13), UIColor.white.withAlphaComponent(0.82), 8))
            }
            for bullet in content.bullets.reversed() {
                blocks.append(("· " + bullet, .systemFont(ofSize: 16), UIColor.white.withAlphaComponent(0.95), 6))
            }
            if !content.subtitle.isEmpty {
                blocks.append((content.subtitle, .systemFont(ofSize: 20), UIColor.white.withAlphaComponent(0.92), 12))
            }
            blocks.append((content.title, .boldSystemFont(ofSize: 34), .white, 0))

            var y = size.height - margin
            for (text, font, color, gap) in blocks {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
                let h = (text as NSString).boundingRect(with: CGSize(width: textWidthMax, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                        attributes: attrs, context: nil).height
                y -= (ceil(h) + gap)
            }
            // 若整体高于安全区，从顶部截断而不是缩字号（缩字号会看不清）
            let minY = size.height * (1 - maxTextAreaRatio)
            if y < minY { y = minY }

            var cursor = y
            for (text, font, color, gap) in blocks {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
                let h = (text as NSString).boundingRect(with: CGSize(width: textWidthMax, height: .greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                        attributes: attrs, context: nil).height
                let rect = CGRect(x: margin, y: cursor, width: textWidthMax, height: ceil(h))
                (text as NSString).draw(in: rect, withAttributes: attrs)
                cursor += ceil(h) + gap
            }
        }
    }
}
