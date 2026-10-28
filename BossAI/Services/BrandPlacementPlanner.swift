import Foundation
import UIKit

/// 品牌素材放置器（2026-10-28）
///
/// 事故：用户要求「在海报左上角加我们的 logo」，结果 logo 被按 Agent 估算的框
/// 拉伸铺满、紧贴边缘，看上去是贴纸而不是设计的一部分。
///
/// 根因不在模型：`PreservedAssetWorkflow.compose` 拿到的 `box` 是模型凭视觉估的归一化
/// 矩形，合成时又把 logo 缩放到"填满整个 box"。框大一点，logo 就跟着撑大；框贴边，
/// logo 就贴边。位置与尺寸全靠估，当然生硬。
///
/// 这里把"放哪儿、多大"改成确定性规则，模型只负责给**方位**：
///   ① 品牌比例：logo 宽度取画布短边的 16%，prompt 里说"大一点/小一点"时按比例缩放；
///   ② 栅格边距：短边 5.5%，位置吸附到四角或居中，不再使用估算的小数点；
///   ③ 比例锁定：按素材真实宽高比缩放，**绝不拉伸**；
///   ④ 安全区：任何情况下不越出画布，且不小于短边 4%（否则印出来看不清）。
///
/// 边界：这只能解决"放置"，解决不了"重新排版"。让标题给 logo 让位、把版面拆开重排，
/// 属于重绘，必须走参考图重设计（模型重新构图），不是贴图能做的——不在这里假装能做到。
enum BrandPlacementPlanner {
    /// logo 宽度占画布短边的比例
    static let baseRatio: CGFloat = 0.16
    /// 边距占画布短边的比例
    static let marginRatio: CGFloat = 0.055
    /// 下限：再小就失去识别度
    static let minRatio: CGFloat = 0.04
    /// 上限：再大就抢主体
    static let maxRatio: CGFloat = 0.30

    /// 把模型估算的框，换算成符合品牌规范的位置与尺寸。返回画布像素坐标。
    /// - Parameters:
    ///   - box: 模型给出的归一化框，只用来判断方位（左上/右下/居中）
    ///   - logoAspect: 素材真实宽高比（w/h）
    ///   - canvas: 底图像素尺寸
    ///   - hint: 用户原话，用于识别"大一点/小一点"
    static func adjust(box: CGRect, logoAspect: CGFloat, canvas: CGSize, hint: String) -> CGRect {
        let width = max(1, canvas.width)
        let height = max(1, canvas.height)
        let shortEdge = min(width, height)
        let aspect = logoAspect.isFinite && logoAspect > 0.05 ? logoAspect : 1

        // ① 尺寸：按短边比例，再按用户的"大/小"微调
        let scale = sizeScale(hint)
        var logoWidth = shortEdge * baseRatio * scale
        var logoHeight = logoWidth / aspect
        // 过高时改用高度反推，避免竖向 logo 顶破版面
        let maxHeight = height * 0.30
        if logoHeight > maxHeight {
            logoHeight = maxHeight
            logoWidth = logoHeight * aspect
        }
        // 下限/上限都按短边约束
        let minWidth = shortEdge * minRatio
        let maxWidth = shortEdge * maxRatio
        if logoWidth < minWidth { logoWidth = minWidth; logoHeight = logoWidth / aspect }
        if logoWidth > maxWidth { logoWidth = maxWidth; logoHeight = logoWidth / aspect }

        // ② 方位：用框中心判断落在哪个象限，吸附到栅格
        let margin = shortEdge * marginRatio
        let centerX = box.midX
        let centerY = box.midY
        let horizontal: Horizontal = centerX < 0.34 ? .left : (centerX > 0.66 ? .right : .center)
        let vertical: Vertical = centerY < 0.34 ? .top : (centerY > 0.66 ? .bottom : .middle)

        let maxX = width - logoWidth - margin
        let maxY = height - logoHeight - margin
        let x: CGFloat
        switch horizontal {
        case .left: x = margin
        case .center: x = (width - logoWidth) / 2
        case .right: x = max(margin, maxX)
        }
        let y: CGFloat
        switch vertical {
        case .top: y = margin
        case .middle: y = (height - logoHeight) / 2
        case .bottom: y = max(margin, maxY)
        }

        // ③ 安全区兜底：极端画布（比 logo 还窄）也不许越界
        let clampedX = min(max(0, x), max(0, width - logoWidth))
        let clampedY = min(max(0, y), max(0, height - logoHeight))
        return CGRect(x: clampedX.rounded(), y: clampedY.rounded(),
                      width: logoWidth.rounded(), height: logoHeight.rounded())
    }

    /// 用户是否明确要求"重新排版给 logo 让位"——这种请求靠贴图做不到，必须走重绘。
    static func requestsRelayout(_ text: String) -> Bool {
        let value = text.lowercased()
        let relayout = ["重新排版", "重排版", "重新布局", "重新排布", "调整排版", "版式调整",
                        "让位", "留出位置", "挪开", "重新设计版式"]
        return relayout.contains { value.contains($0) }
    }

    private enum Horizontal { case left, center, right }
    private enum Vertical { case top, middle, bottom }

    private static func sizeScale(_ hint: String) -> CGFloat {
        let value = hint.lowercased()
        if ["大一点", "大一些", "放大", "大点", "醒目一点", "更大"].contains(where: { value.contains($0) }) { return 1.35 }
        if ["小一点", "小一些", "缩小", "小点", "不要太大"].contains(where: { value.contains($0) }) { return 0.78 }
        return 1
    }
}
