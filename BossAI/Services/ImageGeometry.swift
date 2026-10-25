import Foundation
import UIKit
import ImageIO
import CoreGraphics

// ============================================================================
// ImageGeometry.swift —— 图片几何（2026-10-25）
//
// 为什么必须单独做一层：
//   旧实现判断"原图比例"用的是 UIImage.size（点，且受缩放/朝向影响），
//   然后由 ImageTaskPlanner 猜一个"最接近的常见比例"，编辑任务没指定时直接落到 1:1。
//   于是横版照片被要求"画面比例 1:1"，模型只能中心裁切 —— 左右边缘、主体就没了。
//
// 这里的职责只有四件事：
//   1. 读**真实像素**宽高（ImageIO 读文件头，不解码整图，快且不受朝向干扰）；
//   2. 把任意像素尺寸夹到服务端允许的显式尺寸（512..4096 / 90 万~420 万像素，8 的倍数），
//      保证「请求比例 == 原图比例」，从参数层面就不给裁切留空间；
//   3. 生成后校验输出比例是否与要求一致（不一致就是被裁了）；
//   4. 一个廉价的 16×16 灰度相关性，作为 editSimilarity 的近似指标（只进日志）。
//
// 与服务端 cloudfunctions/bf-image/media-guards.js 的常量必须一致，
// 否则客户端算出的尺寸会被服务端再夹一次，比例就悄悄变了。
// ============================================================================

enum ImageGeometry {

    // MARK: - 与服务端对齐的尺寸预算
    static let minEdge = 512
    static let maxEdge = 4096
    static let minPixels = 921_600        // 960×960 级别
    static let maxPixels = 4_200_000
    /// 比例判定容差：超过 3% 视为"比例不一致"（约 1:1.03，肉眼已能看出被切边）
    static let aspectTolerance = 0.03

    /// 读真实像素宽高。失败返回 nil —— 调用方必须据此**放弃**"保证原图比例"的承诺，
    /// 而不是拿一个猜的尺寸继续（那正是裁切的根源）。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        // 方向信息：EXIF 里 5~8 表示旋转 90°，此时像素宽高要交换，否则算出来的比例是错的。
        // 注意用 NSNumber 取值（直接 as? UInt32 在部分格式下取不到，会静默回落成 1）。
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard let w0 = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h0 = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w0 > 0, h0 > 0 else { return nil }
        if orientation >= 5, orientation <= 8 {
            return (width: h0, height: w0)
        }
        return (width: w0, height: h0)
    }

    /// 把任意像素尺寸夹到服务端允许的显式尺寸（保持宽高比，8 的倍数）。
    /// 返回 "WxH"；连夹都做不到（极端窄长）返回 nil。
    static func clampedSize(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        var w = Double(width)
        var h = Double(height)

        // ① 单边越界：先等比缩到边内
        let edgeScale = min(1.0, min(Double(maxEdge) / w, Double(maxEdge) / h))
        w *= edgeScale; h *= edgeScale
        // ② 单边过小（例如极窄长图缩放后）：整体放大
        if w < Double(minEdge) || h < Double(minEdge) {
            let up = max(Double(minEdge) / w, Double(minEdge) / h)
            w *= up; h *= up
        }
        // ③ 像素预算
        if w * h > Double(maxPixels) {
            let s = sqrt(Double(maxPixels) / (w * h))
            w *= s; h *= s
        }
        if w * h < Double(minPixels) {
            let s = sqrt(Double(minPixels) / (w * h))
            w *= s; h *= s
        }
        // ④ 取 8 的倍数（服务端同样按 8 对齐）
        w = (w / 8).rounded(.down) * 8
        h = (h / 8).rounded(.down) * 8
        // 向下取整可能把总像素压到下限之下（例如 800x801），补一格而不是直接判失败——
        // 判失败会让这类尺寸落到"补边兜底"，白白多一道流程。
        if w * h < Double(minPixels), w + 8 <= Double(maxEdge), h + 8 <= Double(maxEdge) {
            w += 8; h += 8
        }
        guard w >= Double(minEdge), h >= Double(minEdge),
              w <= Double(maxEdge), h <= Double(maxEdge),
              w * h >= Double(minPixels), w * h <= Double(maxPixels) else { return nil }
        return "\(Int(w))x\(Int(h))"
    }

    /// 输出比例与原图比例的相对偏差（0 = 完全一致）。
    /// 返回 nil 表示参数非法。
    static func aspectDeviation(outputWidth: Int, outputHeight: Int, expectedAspect: Double) -> Double? {
        guard outputWidth > 0, outputHeight > 0, expectedAspect > 0 else { return nil }
        let actual = Double(outputWidth) / Double(outputHeight)
        return abs(actual - expectedAspect) / expectedAspect
    }

    /// 是否判定为"被裁切/被重构"（偏差超过容差）
    static func isAspectBroken(outputWidth: Int, outputHeight: Int, expectedAspect: Double) -> Bool {
        guard let dev = aspectDeviation(outputWidth: outputWidth, outputHeight: outputHeight, expectedAspect: expectedAspect) else {
            return false
        }
        return dev > aspectTolerance
    }

    /// 16×16 灰度相关性（-1...1），仅作为日志里的 editSimilarity 近似值。
    /// 用途是"这次编辑有没有把整张画面重画一遍"的可观测信号，不参与展示决策。
    static func thumbnailSimilarity(_ a: UIImage, _ b: UIImage, side: Int = 16) -> Double? {
        guard let ga = grayGrid(a, side: side), let gb = grayGrid(b, side: side), ga.count == gb.count, !ga.isEmpty else {
            return nil
        }
        let n = Double(ga.count)
        let ma = ga.reduce(0, +) / n
        let mb = gb.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<ga.count {
            let x = ga[i] - ma, y = gb[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return nil }
        return num / sqrt(da * db)
    }

    // MARK: - 固定比例兜底：等比缩放 + 留白补边 → 生成 → 映射回原画布

    /// 服务端/上游支持的固定比例（与 bf-image 的 ASPECT_SIZES 一致）
    static let supportedRatios: [String] = ["1:1", "3:4", "4:3", "9:16", "16:9"]

    /// 找一个与该宽高比最接近的受支持比例
    static func nearestSupportedRatio(_ aspect: Double) -> String {
        guard aspect > 0 else { return "1:1" }
        var best = "1:1"
        var bestDelta = Double.greatestFiniteMagnitude
        for r in supportedRatios {
            let parts = r.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { continue }
            let delta = abs(parts[0] / parts[1] - aspect)
            if delta < bestDelta { bestDelta = delta; best = r }
        }
        return best
    }

    /// 把原图等比缩放后居中放到目标比例的画布上，四周留白（用原图边缘色，不引入突兀白框）。
    /// 返回合成后的 JPEG + 内容区在画布中的**归一化**矩形，供生成后裁回。
    static func composePaddedReference(_ image: UIImage, ratio: String) -> (data: Data, contentRect: CGRect)? {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        let targetAspect = parts[0] / parts[1]

        let srcSize = CGSize(width: max(1, image.size.width), height: max(1, image.size.height))
        let srcAspect = srcSize.width / srcSize.height
        // 画布：以原图长边为基准，保证内容不被缩小
        var canvas = srcSize
        if srcAspect > targetAspect {
            canvas = CGSize(width: srcSize.width, height: (srcSize.width / targetAspect).rounded())
        } else {
            canvas = CGSize(width: (srcSize.height * targetAspect).rounded(), height: srcSize.height)
        }
        let content = CGRect(x: ((canvas.width - srcSize.width) / 2).rounded(),
                             y: ((canvas.height - srcSize.height) / 2).rounded(),
                             width: srcSize.width, height: srcSize.height)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1                     // 用真实像素作图，避免 scale 把尺寸放大
        format.opaque = true
        let composed = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            // 底色取原图平均色，留白不会像贴了一圈白纸
            averageColor(of: image).setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: content)
        }
        guard let data = composed.jpegData(compressionQuality: 0.92) else { return nil }
        let normalized = CGRect(x: content.minX / canvas.width, y: content.minY / canvas.height,
                                width: content.width / canvas.width, height: content.height / canvas.height)
        return (data, normalized)
    }

    /// 生成后把画布裁回原图内容区（把补边去掉，恢复原始构图与比例）
    static func cropBack(_ image: UIImage, contentRect: CGRect) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: contentRect.minX * w, y: contentRect.minY * h,
                          width: contentRect.width * w, height: contentRect.height * h).integral
        guard rect.width >= 1, rect.height >= 1, let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    private static func averageColor(of image: UIImage) -> UIColor {
        guard let grid = grayGrid(image, side: 8), !grid.isEmpty else { return .white }
        let mean = grid.reduce(0, +) / Double(grid.count) / 255.0
        return UIColor(white: CGFloat(mean), alpha: 1)
    }

    private static func grayGrid(_ image: UIImage, side: Int) -> [Double]? {
        guard let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels.map { Double($0) }
    }
}
