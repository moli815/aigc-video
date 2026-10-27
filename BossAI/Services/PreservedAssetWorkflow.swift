import Foundation
import UIKit

/// Immutable originals (logos/QR codes) are composited after generation, never redrawn.
/// The provider may clean the destination; original canvas pixels outside it are retained.
enum PreservedAssetWorkflow {
    struct Placement {
        let referenceIndex: Int
        let box: CGRect
        let image: UIImage
    }
    struct Plan {
        let original: UIImage
        let placements: [Placement]
        let preserveOutside: Bool
        let background: ImageRequestContext
    }
    enum Failure: LocalizedError {
        case invalidPlacement, missingOriginal, compositionFailed
        var errorDescription: String? {
            switch self {
            case .invalidPlacement: return "标识的替换位置还不够明确，请指定要替换的区域后再试。"
            case .missingOriginal: return "找不到原始标识素材或海报，请重新选择这两张图片。"
            case .compositionFailed: return "底图已保留，标识暂未合成完成，请重试保存。"
            }
        }
    }
    static func plan(_ context: ImageRequestContext) throws -> Plan? {
        guard let value = context.structured?["preserve_assets"] else { return nil }
        guard let entries = value as? [[String: Any]], !entries.isEmpty, entries.count <= 4,
              context.taskKind == "edit", let baseData = context.references.first,
              let original = orientedImage(baseData) else { throw Failure.missingOriginal }
        if let flag = context.structured?["preserve_outside"] {
            guard let flag = flag as? NSNumber, String(cString:flag.objCType)=="c" else { throw Failure.invalidPlacement }
        }
        var used = Set<Int>(), placements: [Placement] = []
        func number(_ value: Any?) throws -> Double {
            guard let n = value as? NSNumber, String(cString: n.objCType) != "c", n.doubleValue.isFinite else { throw Failure.invalidPlacement }
            return n.doubleValue
        }
        for entry in entries {
            let indexValue = try number(entry["reference_index"])
            guard indexValue.rounded() == indexValue, indexValue >= 2,
                  indexValue <= Double(context.references.count), used.insert(Int(indexValue)).inserted,
                  let image = orientedImage(context.references[Int(indexValue)-1]),
                  let raw = entry["box"] as? [String: Any] else { throw Failure.missingOriginal }
            let x = try number(raw["x"]), y = try number(raw["y"])
            let w = try number(raw["width"]), h = try number(raw["height"])
            guard x >= 0, y >= 0, w > 0, h > 0, x+w <= 1, y+h <= 1, w*h <= 0.35 else { throw Failure.invalidPlacement }
            let box = CGRect(x:x,y:y,width:w,height:h)
            guard !placements.contains(where: { $0.box.intersects(box) }) else { throw Failure.invalidPlacement }
            placements.append(Placement(referenceIndex:Int(indexValue),box:box,image:image))
        }
        var fields = context.structured ?? [:]
        fields.removeValue(forKey:"preserve_assets"); fields.removeValue(forKey:"preserve_outside")
        let materialIndices = Set(placements.map { $0.referenceIndex-1 })
        let references = context.references.enumerated().filter { !materialIndices.contains($0.offset) }.map(\.element)
        let regions = placements.map { p in
            "<bbox>\(Int(p.box.minX*999)),\(Int(p.box.minY*999)),\(Int(p.box.maxX*999)),\(Int(p.box.maxY*999))</bbox>"
        }.joined(separator:"；")
        let background = ImageRequestContext(prompt:context.prompt + "\n本次仅处理底图：清除区域\(regions)中的旧标识并自然补齐背景，不绘制替换Logo/商标/二维码。原始素材将于后续直接合成，其形状与文字不得由模型重新设计。",
            references:references,taskKind:context.taskKind,qualityTier:context.qualityTier,
            requestedCount:context.requestedCount,aspectRatio:context.aspectRatio,renderIntent:context.renderIntent,
            structured:fields,layerDecomposition:context.layerDecomposition,targetSize:context.targetSize,
            textMode:context.textMode,requestId:context.requestId)
        return Plan(original:original,placements:placements,
                    preserveOutside:context.structured?["preserve_outside"] as? Bool ?? true,background:background)
    }
    private static func orientedImage(_ data: Data) -> UIImage? {
        // Source photos can exceed the provider's *output* pixel budget. Inspect
        // their headers before decoding, without silently shrinking brand artwork.
        guard data.count <= 32*1024*1024, let pixels = ImageGeometry.pixelSize(of:data),
              pixels.width <= 16384, pixels.height <= 16384,
              Double(pixels.width)*Double(pixels.height) <= 40_000_000,
              let image = UIImage(data:data) else { return nil }
        if image.imageOrientation == .up && image.scale == 1 { return image }
        let size = CGSize(width:pixels.width,height:pixels.height)
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:size,format:format).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
    }
    static func compose(plan: Plan, cleaned: UIImage) throws -> Data {
        let size = plan.original.size
        guard size.width > 0, size.height > 0,
              abs((cleaned.size.width/cleaned.size.height)/(size.width/size.height)-1) <= ImageGeometry.aspectTolerance else {
            throw Failure.compositionFailed
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = plan.original.scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size:size,format:format).image { renderer in
            let full = CGRect(origin:.zero,size:size)
            (plan.preserveOutside ? plan.original : cleaned).draw(in:full)
            for placement in plan.placements {
                let box = CGRect(x:placement.box.minX*size.width,y:placement.box.minY*size.height,
                                 width:placement.box.width*size.width,height:placement.box.height*size.height)
                renderer.cgContext.saveGState(); renderer.cgContext.clip(to:box)
                cleaned.draw(in:full)
                let padding = min(box.width,box.height)*0.025
                let area = box.insetBy(dx:padding,dy:padding)
                let scale = min(area.width/placement.image.size.width,area.height/placement.image.size.height)
                let target = CGSize(width:placement.image.size.width*scale,height:placement.image.size.height*scale)
                placement.image.draw(in:CGRect(x:area.midX-target.width/2,y:area.midY-target.height/2,
                                               width:target.width,height:target.height))
                renderer.cgContext.restoreGState()
            }
        }
        guard let bytes = image.pngData() else { throw Failure.compositionFailed }
        return bytes
    }
    static func generate(plan: Plan, generateBackground: (ImageRequestContext) async throws -> Data) async throws -> Data {
        let owner = await MainActor.run { HostedAccount.scopeKey }
        let signature = try JSONSerialization.data(withJSONObject:["owner":owner,"prompt":plan.background.prompt,
            "aspect":plan.background.aspectRatio,"size":plan.background.targetSize ?? "","tier":plan.background.qualityTier,
            "kind":plan.background.taskKind,"intent":plan.background.renderIntent,"textMode":plan.background.textMode.rawValue,
            "structured":plan.background.structured ?? [:]],options:[.sortedKeys])
        let key = CloudAssetStore.sha256(signature
            + plan.background.references.reduce(Data(), { $0 + Data(CloudAssetStore.sha256($1).utf8) }))
        let directory = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("PreservedAssetBackgrounds",isDirectory:true)
        let file = directory.appendingPathComponent(key+".image")
        let cached = try? file.resourceValues(forKeys:[.contentModificationDateKey])
        let bytes: Data
        if let date = cached?.contentModificationDate, Date().timeIntervalSince(date)<900,
           let stored = try? Data(contentsOf:file), stored.count <= 24*1024*1024 { bytes = stored }
        else {
            bytes = try await generateBackground(plan.background)
            try Task.checkCancellation()
            guard await MainActor.run(body:{HostedAccount.scopeKey==owner}) else { throw CancellationError() }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            // Cache before composition: a local failure must not repeat the paid call.
            try bytes.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            let files = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []
            let oldest = files.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in oldest.prefix(max(0,oldest.count-4)) where old != file { try? FileManager.default.removeItem(at:old) }
        }
        try Task.checkCancellation()
        guard await MainActor.run(body:{HostedAccount.scopeKey==owner}), let cleaned = UIImage(data:bytes) else { throw Failure.compositionFailed }
        return try compose(plan:plan,cleaned:cleaned)
    }
}
