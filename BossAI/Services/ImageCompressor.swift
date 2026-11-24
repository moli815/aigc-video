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

    // P0-46 云端覆盖：服务端 /me 下发 uiConfig（改参数不出包）；未下发时用内置默认。
    // 用锁保护写入（applyCloudConfig 可能从非 MainActor 上下文触发）。
    private static let lock = NSLock()
    private static var cloudEdge: CGFloat?
    private static var cloudQuality: CGFloat?

    /// 应用云端压缩参数（HostedAccount 拉取 /me 时调用）。nil 参数表示该字段不变。
    static func applyCloudConfig(edge: CGFloat?, quality: CGFloat?) {
        lock.lock(); defer { lock.unlock() }
        if let edge, edge > 0 { cloudEdge = edge }
        if let quality, (0.1...1.0).contains(quality) { cloudQuality = quality }
    }

    /// 复位云端覆盖（测试隔离用；生产不应调用）
    static func resetCloudConfig() {
        lock.lock(); defer { lock.unlock() }
        cloudEdge = nil; cloudQuality = nil
    }

    /// Combine ordered previews into numbered sheets while keeping the stored attachments intact.
    static func referenceSheets(_ inputs: [Data], numbered: Bool = true) -> [Data]? {
        guard !inputs.isEmpty, inputs.count <= ImageReferenceResolver.maxAttachments else { return nil }
        let previews = inputs.compactMap { input -> UIImage? in
            guard let jpeg = compressedData(from: input) else { return nil }
            return UIImage(data: jpeg)
        }
        guard previews.count == inputs.count else { return nil }
        var output: [Data] = []
        for start in stride(from: 0, to: previews.count, by: 8) {
            let batch = Array(previews[start..<min(start + 8, previews.count)])
            let cell = CGSize(width: 384, height: 310)
            let size = CGSize(width: cell.width * 2, height: cell.height * CGFloat((batch.count + 1) / 2))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let bitmap = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor.white.setFill()
                renderer.fill(CGRect(origin: .zero, size: size))
                for (index, image) in batch.enumerated() {
                    let x = CGFloat(index % 2) * cell.width
                    let y = CGFloat(index / 2) * cell.height
                    let scale = min((cell.width - 24) / image.size.width, (cell.height - 46) / image.size.height)
                    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: x + (cell.width - target.width) / 2, y: y + 30,
                                          width: target.width, height: target.height))
                    guard numbered else { continue }
                    NSString(string: "REF \(start + index + 1)").draw(at: CGPoint(x: x + 12, y: y + 7),
                        withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold),
                                         .foregroundColor: UIColor.black])
                }
            }
            guard let data = bitmap.jpegData(compressionQuality: 0.83), data.count <= maxBytes else { return nil }
            output.append(data)
        }
        return output
    }

    /// 生效的长边（云端优先，否则内置默认）
    static var effectiveMaxEdge: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return cloudEdge ?? maxEdge
    }
    /// 生效的质量（云端优先，否则内置默认）
    static var effectiveQuality: CGFloat {
        lock.lock(); defer { lock.unlock() }
        return cloudQuality ?? quality
    }

    /// 把原始图片数据压缩为适合多模态上传的 JPEG 数据。
    /// - Parameter raw: 原始图片数据（任意常见格式，UIImage 可解码即可）
    /// - Returns: 压缩后的 JPEG Data；无法解码或压缩后仍超限时返回 nil。
    static func compressedData(from raw: Data) -> Data? {
        guard let image = UIImage(data: raw) else { return nil }

        // 等比缩放到长边不超过 effectiveMaxEdge（小图不放大：scale 上限 1）
        let longest = max(image.size.width, image.size.height)
        let edge = effectiveMaxEdge
        let scale = longest > edge ? edge / longest : 1
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

        // 首选质量（云端可覆盖）
        let qualityValue = effectiveQuality
        if let jpeg = resized.jpegData(compressionQuality: qualityValue), jpeg.count <= maxBytes {
            return jpeg
        }
        // 降质重试一次（大面积纯色/噪点图可能体积异常大）
        if let jpeg = resized.jpegData(compressionQuality: 0.6), jpeg.count <= maxBytes {
            return jpeg
        }
        return nil
    }
}
