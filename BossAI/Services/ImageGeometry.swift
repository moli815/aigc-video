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
//   2. 把可表达的源图尺寸映射到 Provider 支持的像素预算；不可表达时返回 nil，调用方必须 fail closed；
//   3. 生成后校验输出画布比例是否与要求一致；这不能证明模型没有在同一比例内裁切/重构主体；
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
    static let maxPixels = 4_622_220
    /// 比例判定容差：超过 3% 视为"比例不一致"（约 1:1.03，肉眼已能看出被切边）
    static let aspectTolerance = 0.03

    /// 读真实像素宽高。失败返回 nil —— 调用方必须据此**放弃**"保证原图比例"的承诺，
    /// 而不是拿一个猜的尺寸继续（那正是裁切的根源）。
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        // 注意：这里必须桥接成 [String: Any]。`as? [CFString: Any]` 在运行时会失败（CFString 不是 Swift 的 String key），
        // 结果是"永远读不到像素尺寸"，编辑任务全部退化成兜底路径。
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
        // 方向信息：EXIF 里 5~8 表示旋转 90°，此时像素宽高要交换，否则算出来的比例是错的。
        // 注意用 NSNumber 取值（直接 as? UInt32 在部分格式下取不到，会静默回落成 1）。
        let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard let w0 = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let h0 = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              w0 > 0, h0 > 0 else { return nil }
        if orientation >= 5, orientation <= 8 {
            return (width: h0, height: w0)
        }
        return (width: w0, height: h0)
    }

    /// 把像素尺寸夹到服务端允许的显式尺寸（尽量保持宽高比，8 的倍数）。
    /// 极端窄长比例无法在边长/像素预算内表达时返回 nil；调用方不能补边后再裁回。
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
        // 向下取整可能把总像素压到下限之下（例如 800x801），补一格再做边界校验。
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

    /// 是否检测到输出画布比例不一致（偏差超过容差；不是内容完整性/主体保真检测）
    static func isAspectBroken(outputWidth: Int, outputHeight: Int, expectedAspect: Double) -> Bool {
        // 期望保比例时，无法读取尺寸同样属于不合格结果，调用方应 fail closed。
        guard let dev = aspectDeviation(outputWidth: outputWidth, outputHeight: outputHeight, expectedAspect: expectedAspect) else { return true }
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

    private static func grayGrid(_ image: UIImage, side: Int) -> [Double]? {
        guard let cg = image.cgImage, side > 0 else { return nil }
        // 用 RGBA 上下文 + 自持缓冲区：
        // · 把 Swift Array 的 &pixels 交给 CGContext 在 CI 上会整体画空（返回 nil）；
        // · DeviceGray 上下文对带 alpha 的源图也不稳定，RGBA 最省事。
        let count = side * side
        let bytesPerRow = side * 4
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count * 4)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0, count: count * 4)
        guard let ctx = CGContext(data: buffer, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let r = Double(buffer[i * 4]), g = Double(buffer[i * 4 + 1]), b = Double(buffer[i * 4 + 2])
            out[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        return out
    }
}
