import UIKit
import CoreGraphics

// ============================================================================
// 文件职责：P0-35 海报图文分离的客户端合成器——服务端只出"无文字底图"，
//   本文件用 CoreText/UIKit 在客户端叠加中文标题/副标题/要点，实现**零乱码**海报。
// 在 App 中的角色：行业实证表明即使最强生图模型，中文小字仍会出现"重复字符、
//   自创字形"（如"太阳能→太田形"）；零乱码的唯一根治方案是图文分离：
//   底图交给模型画、文字交给真实字体渲染——改文案也不用重新生成图片。
// 关键设计决策：
//   1. 布局计算抽成**纯函数**（computeTextLayout）——不依赖 UIKit 渲染即可单测，
//      锁定"文字区块不越界、字号在可读区间"两个不变量。
//   2. 文字恒定白字 + 半透明深色阴影：保证在任意底图（浅色/深色/复杂纹理）上可读。
//   3. 合成失败不抛错——返回 nil，调用方降级为"只展示底图 + 文字由模型回答给出"。
// ============================================================================

/// 海报文字合成器。
enum PosterComposer {

    /// 一条待绘制的文字块（纯数据，便于断言）。
    struct TextBlock: Equatable {
        let text: String
        /// 相对画布的绘制区域（归一化 0~1，乘以画布尺寸得到实际像素矩形）
        let rect: CGRect
        /// 字号相对画布宽度的比例（实际字号 = 画布宽 × fontSizeRatio，并有绝对上下限）
        let fontSizeRatio: CGFloat
        /// 是否使用粗体
        let bold: Bool
        /// 对齐方式（标题居中、要点左对齐）
        let centered: Bool
    }

    /// 可读字号绝对区间（像素）：太小看不清、太大挤爆版面
    static let fontSizeRange: ClosedRange<CGFloat> = 22...72

    // MARK: - 布局（纯函数，供单测）

    /// 计算海报文字布局。三段式：
    /// - 标题：画布上方 6%~30% 区域居中（大号粗体，最多两行）
    /// - 副标题：标题下方（中小号，居中）
    /// - 要点：画布 46% 起纵向排列（小号，左对齐，最多 6 条）
    /// 防呆：所有区块经过边界钳制，任何输入都不会产生越界矩形。
    static func computeTextLayout(canvasSize: CGSize, title: String, subtitle: String, bullets: [String]) -> [TextBlock] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        var blocks: [TextBlock] = []

        // 标题（最多两行由绘制层换行处理，这里给足高度）
        if !title.isEmpty {
            blocks.append(TextBlock(
                text: title,
                rect: CGRect(x: 0.08, y: 0.06, width: 0.84, height: 0.20),
                fontSizeRatio: 0.075,
                bold: true,
                centered: true
            ))
        }
        // 副标题
        if !subtitle.isEmpty {
            blocks.append(TextBlock(
                text: subtitle,
                rect: CGRect(x: 0.08, y: 0.27, width: 0.84, height: 0.09),
                fontSizeRatio: 0.036,
                bold: false,
                centered: true
            ))
        }
        // 要点列表：从 46% 起，每条一行，最多 6 条
        let shown = bullets.filter { !$0.isEmpty }.prefix(6)
        for (index, item) in shown.enumerated() {
            let y = 0.46 + CGFloat(index) * 0.075
            blocks.append(TextBlock(
                text: item,
                rect: CGRect(x: 0.12, y: min(y, 0.9), width: 0.76, height: 0.066),
                fontSizeRatio: 0.030,
                bold: false,
                centered: false
            ))
        }
        return blocks
    }

    /// 把归一化矩形换算为像素矩形（含边界钳制：任何块不得超出画布）。
    static func pixelRect(for block: TextBlock, canvasSize: CGSize) -> CGRect {
        let r = CGRect(
            x: block.rect.origin.x * canvasSize.width,
            y: block.rect.origin.y * canvasSize.height,
            width: block.rect.width * canvasSize.width,
            height: block.rect.height * canvasSize.height
        )
        return r.intersection(CGRect(origin: .zero, size: canvasSize))
    }

    // MARK: - 合成

    /// 字号换算：画布宽 × 比例，并钳制到可读区间。
    static func fontSize(for block: TextBlock, canvasWidth: CGFloat) -> CGFloat {
        min(max(canvasWidth * block.fontSizeRatio, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// 合成海报：底图 + 文字。返回新图（原图不动）；失败返回 nil（调用方降级）。
    static func compose(base: UIImage, title: String, subtitle: String, bullets: [String]) -> UIImage? {
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }
        let blocks = computeTextLayout(canvasSize: size, title: title, subtitle: subtitle, bullets: bullets)
        guard !blocks.isEmpty else { return base }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = base.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let output = renderer.image { ctx in
            // 1) 底图铺满
            base.draw(in: CGRect(origin: .zero, size: size))

            // 2) 逐块绘制文字
            for block in blocks {
                let rect = pixelRect(for: block, canvasSize: size)
                guard rect.width > 1, rect.height > 1 else { continue }
                let sizePt = fontSize(for: block, canvasWidth: size.width)
                let font: UIFont = block.bold
                    ? .systemFont(ofSize: sizePt, weight: .heavy)
                    : .systemFont(ofSize: sizePt, weight: .semibold)
                let style = NSMutableParagraphStyle()
                style.alignment = block.centered ? .center : .left
                style.lineBreakMode = .byTruncatingTail
                // 白字 + 深色阴影：任意底图上都可读（对比度保护）
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: style,
                    .shadow: {
                        let s = NSShadow()
                        s.shadowColor = UIColor.black.withAlphaComponent(0.55)
                        s.shadowBlurRadius = sizePt * 0.12
                        s.shadowOffset = CGSize(width: 0, height: sizePt * 0.04)
                        return s
                    }(),
                ]
                (block.text as NSString).draw(in: rect, withAttributes: attrs)
            }
        }
        return output
    }
}
