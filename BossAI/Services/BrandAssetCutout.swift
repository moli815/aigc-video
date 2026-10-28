import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision

/// Local background removal preserves source pixels; the image model never redraws a brand.
enum BrandAssetCutout {
    enum Mode: String { case auto, keep, remove }
    enum Kind: String { case logo, qr, image }
    enum Failure: LocalizedError {
        case unclear, invalidImage, qrBackground
        var errorDescription: String? {
            switch self {
            case .unclear: return "这次标识处理暂未完成，请重试；原始素材和已生成内容会保留。"
            case .invalidImage: return "这张标识图片暂时无法读取，请重新上传。"
            case .qrBackground: return "二维码需要保留清晰的浅色留白，不能按普通Logo直接去底，请保留二维码底色。"
            }
        }
    }
    static func prepare(_ data: Data, mode: Mode, kind: Kind) async throws -> Data {
        try Task.checkCancellation()
        if mode == .keep || (kind == .image && mode == .auto) || !HostedAccount.behaviorBool("logoCutout", default: true) { return data }
        if kind == .qr {
            if mode == .remove { throw Failure.qrBackground }
            return data
        }
        let bestEffort = HostedAccount.behaviorBool("logoCutoutBestEffort", default: true)
        let edge = min(2048, max(256, HostedAccount.behaviorInt("logoCutoutMaxEdge", default: 2048)))
        let tolerance = min(80, max(8, HostedAccount.behaviorInt("logoCutoutTolerance", default: 32)))
        let task = Task.detached(priority: .userInitiated) { try process(data, mode: mode, bestEffort: bestEffort, edge: edge, tolerance: tolerance) }
        return try await withTaskCancellationHandler(operation: {
            let result = try await task.value; try Task.checkCancellation(); return result
        }, onCancel: { task.cancel() })
    }
    private struct Raster {
        let width: Int, height: Int
        var pixels: [UInt8]
        init(_ image: CGImage) throws {
            let w = image.width, h = image.height
            width = w; height = h
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
            }
            guard ok else { throw Failure.invalidImage }; pixels = bytes
        }
        var border: [Int] {
            let step = max(1, max(width, height) / 128)
            return stride(from: 0, to: width, by: step).flatMap { [$0, (height - 1) * width + $0] }
                + stride(from: 0, to: height, by: step).flatMap { [$0 * width, $0 * width + width - 1] }
        }
        func png() throws -> Data {
            var left = width, top = height, right = -1, bottom = -1, visible = 0
            for index in 0..<(width * height) where pixels[index * 4 + 3] > 8 {
                visible += 1; left = min(left, index % width); right = max(right, index % width)
                top = min(top, index / width); bottom = max(bottom, index / width)
            }
            guard visible >= 16 else { throw Failure.unclear }
            left = max(0, left - 1); top = max(0, top - 1)
            right = min(width - 1, right + 1); bottom = min(height - 1, bottom + 1)
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let cropped = image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) else { throw Failure.invalidImage }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw Failure.invalidImage }
            CGImageDestinationAddImage(destination, cropped, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
            return output as Data
        }
    }
    private static func process(_ data: Data, mode: Mode, bestEffort: Bool, edge: Int, tolerance: Int) throws -> Data {
        guard data.count <= 32 * 1024 * 1024, let size = ImageGeometry.pixelSize(of: data),
              Double(size.width) * Double(size.height) <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge
              ] as CFDictionary) else { throw Failure.invalidImage }
        var raster = try Raster(image)
        let border = raster.border
        if border.filter({ raster.pixels[$0 * 4 + 3] < 128 }).count * 10 >= border.count * 9 { return data }
        try Task.checkCancellation()
        // A QR quiet zone is functional data, not a disposable white background.
        let barcode = VNDetectBarcodesRequest(); barcode.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([barcode])
        if !(barcode.results ?? []).isEmpty {
            if mode == .remove { throw Failure.qrBackground }
            return data
        }
        if try removeUniformBackground(&raster, tolerance: tolerance) { return try raster.png() }
        // Apple's on-device subject lifting handles non-uniform backgrounds. If it
        // cannot preserve the mark/text, reject before the paid background request.
        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let request = VNGenerateForegroundInstanceMaskRequest(); request.preferBackgroundProcessing = true
            try handler.perform([request]); try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.unclear }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let masked = CIContext().createCGImage(ci, from: ci.extent), masked.width == image.width, masked.height == image.height else { throw Failure.unclear }
            let result = try Raster(masked)
            let visible = stride(from: 3, to: result.pixels.count, by: 4).filter { result.pixels[$0] > 16 }.count
            guard visible >= 16, visible < result.width * result.height else { throw Failure.unclear }
            if !bestEffort {
                guard Double(visible) / Double(result.width * result.height) < 0.95,
                      result.border.filter({ result.pixels[$0 * 4 + 3] < 128 }).count * 4 >= result.border.count * 3 else { throw Failure.unclear }
                let before = recognizedText(image), after = recognizedText(masked).joined()
                guard before.allSatisfy({ after.contains($0) }) else { throw Failure.unclear }
            }
            try Task.checkCancellation(); return try result.png()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw Failure.unclear
        }
    }
    private static func recognizedText(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { result in
            guard let text = result.topCandidates(1).first, text.confidence >= 0.65 else { return nil }
            return String(text.string.lowercased().filter { !$0.isWhitespace })
        }
    }
    /// Only border-connected background pixels are removed; enclosed white artwork stays.
    private static func removeUniformBackground(_ image: inout Raster, tolerance: Int) throws -> Bool {
        let w = image.width, h = image.height, count = w * h
        guard w > 2, h > 2 else { throw Failure.unclear }
        let corners = [0, w - 1, (h - 1) * w, count - 1]
        let colors = image.pixels
        let background = (0..<3).map { channel in corners.reduce(0) { $0 + Int(colors[$1 * 4 + channel]) } / 4 }
        func close(_ index: Int) -> Bool {
            colors[index * 4 + 3] < 8 || (0..<3).allSatisfy { abs(Int(colors[index * 4 + $0]) - background[$0]) <= tolerance }
        }
        guard corners.allSatisfy(close), image.border.filter(close).count * 10 >= image.border.count * 9 else { return false }
        var seen = [UInt8](repeating: 0, count: count), queue: [Int32] = []
        func append(_ index: Int) {
            if seen[index] == 0 && close(index) { seen[index] = 1; queue.append(Int32(index)) }
        }
        for x in 0..<w { append(x); append((h - 1) * w + x) }
        for y in 0..<h { append(y * w); append(y * w + w - 1) }
        var head = 0
        while head < queue.count {
            if head % 16384 == 0 { try Task.checkCancellation() }
            let index = Int(queue[head]); head += 1
            if index % w > 0 { append(index - 1) }; if index % w < w - 1 { append(index + 1) }
            if index >= w { append(index - w) }; if index < count - w { append(index + w) }
        }
        guard queue.count > count / 50, count - queue.count >= max(16, count / 500) else { throw Failure.unclear }
        for raw in queue { for channel in 0..<4 { image.pixels[Int(raw) * 4 + channel] = 0 } }
        return true
    }
}
