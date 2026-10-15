import UIKit

// ============================================================================
// 文件职责：P0-42 图片上传前压缩——视觉识别成本控制的核心环节。
// 在 App 中的角色：用户发图 → OCR 文本之外还要把图片本体走多模态通道（真·看图）。
//   视觉模型的计费与"像素数 ÷ 750"近似成正比：一张 1200 万像素的手机原图 ≈ 1.6 万 token，
//   压缩到长边 1024（约 80 万像素）后 ≈ 1 千 token —— 单次识别成本降约 90%。
// 关键设计决策：
//   1. 长边 1024：实测（2026-10-15，qwen3-vl-plus）名片/密集海报/财务报表在 1K 长边下
//      识别全部正确，未见质量损失；再降会开始影响小字场景。
//   2. 统一重编码为 JPEG（质量 0.78）：既保证 data URL 的 MIME 与真实内容一致，
//      也让体积可控；产物超 1.5MB 时降质重试一次。
//   3. 失败（无法解码/压缩后仍超标）返回 nil——调用方降级为"仅 OCR 文本"，绝不中断发送。
// ============================================================================

/// 图片压缩工具（纯函数，便于 XCTest 直接验证尺寸与体积断言）。
enum ImageCompressor {

    /// 目标长边（像素）。选 1024 的依据见文件头注释。
    static let maxEdge: CGFloat = 1024
    /// JPEG 编码质量：0.78 在 1K 尺寸下视觉无损、体积可控。
    static let quality: CGFloat = 0.78
    /// 压缩产物的体积上限（超过则降质重试；仍超则放弃）。
    static let maxBytes = 1_500_000

    /// 把原始图片数据压缩为适合多模态上传的 JPEG 数据。
    /// - Parameter raw: 原始图片数据（任意常见格式，UIImage 可解码即可）
    /// - Returns: 压缩后的 JPEG Data；无法解码或压缩后仍超限时返回 nil。
    static func compressedData(from raw: Data) -> Data? {
        guard let image = UIImage(data: raw) else { return nil }

        // 等比缩放到长边不超过 maxEdge（小图不放大：scale 上限 1）
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )

        // scale = 1：以像素为单位直接渲染到目标尺寸，避免屏幕倍率（2x/3x）意外放大像素数
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        // 首选质量
        if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
            return jpeg
        }
        // 降质重试一次（大面积纯色/噪点图可能体积异常大）
        if let jpeg = resized.jpegData(compressionQuality: 0.6), jpeg.count <= maxBytes {
            return jpeg
        }
        return nil
    }
}
