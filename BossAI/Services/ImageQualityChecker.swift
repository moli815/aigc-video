import Foundation
import UIKit

// ImageQualityChecker.swift —— 生成结果的轻量质检（纯程序，不调视觉模型）
//
// 为什么要有它：现在"模型返回了 URL"就当成功。实际踩过的问题包括——
//   返回体解不出图、图只有几百字节（下载被截断）、比例和要求差很远（要 3:4 给了 16:9），
//   而这些都发生在"保存"之前，必须在保存前拦一次，否则用户拿到的是坏文件或错版。
//
// 边界：
//   · 只做**可程序判定**的检查（能解码、尺寸、比例、体积下限）；
//   · 不做审美判断，也不判断"画得对不对"（那需要视觉模型，成本高，另立开关）；
//   · 返回问题列表而不是抛错，让调用方决定是重试、降级还是如实告知用户。

enum ImageQualityIssue: String, Equatable {
    case emptyPayload          // 一个字节都没有
    case undecodable           // 解不出图片（截断/格式错）
    case tooSmall              // 尺寸过小，放大必糊
    case unexpectedRatio       // 比例与要求偏差过大
    case suspiciouslySmallPayload // 体积异常小（多见于下载中断）
}

struct ImageQualityReport: Equatable {
    let issues: [ImageQualityIssue]
    /// 解码出来的像素尺寸（解不出时为 nil）
    let pixelSize: CGSize?

    var isAcceptable: Bool { issues.isEmpty }

    /// 给人看的一句话（写日志/提示用，不含技术细节）
    var summary: String {
        guard !issues.isEmpty else { return "通过" }
        return issues.map { issue -> String in
            switch issue {
            case .emptyPayload: return "没有拿到图片数据"
            case .undecodable: return "图片无法解码"
            case .tooSmall: return "图片尺寸过小"
            case .unexpectedRatio: return "图片比例不符合要求"
            case .suspiciouslySmallPayload: return "图片数据不完整"
            }
        }.joined(separator: "、")
    }
}

enum ImageQualityChecker {

    /// 检查一张生成结果。
    /// - Parameters:
    ///   - data: 图片二进制
    ///   - expectedAspect: 期望比例（如 "3:4"），nil 表示不校验比例
    ///   - minEdge: 允许的最小边像素（默认 256，低于此值放大到全屏会明显糊）
    ///   - maxRatioDeviation: 允许的比例相对偏差（默认 8%）
    static func check(_ data: Data,
                      expectedAspect: String? = nil,
                      minEdge: CGFloat = 256,
                      maxRatioDeviation: Double = 0.08) -> ImageQualityReport {
        guard !data.isEmpty else {
            return ImageQualityReport(issues: [.emptyPayload], pixelSize: nil)
        }

        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return ImageQualityReport(issues: [.undecodable], pixelSize: nil)
        }

        let size = CGSize(width: image.size.width * image.scale,
                          height: image.size.height * image.scale)
        var issues: [ImageQualityIssue] = []

        if min(size.width, size.height) < minEdge {
            issues.append(.tooSmall)
        }
        // 体积下限只用于识别"下载被截断"，正常 PNG/JPEG 不可能小于 1KB
        if data.count < 1024 {
            issues.append(.suspiciouslySmallPayload)
        }
        if let expectedAspect,
           let target = aspectValue(expectedAspect),
           target > 0 {
            let actual = Double(size.width / size.height)
            let deviation = abs(actual - target) / target
            if deviation > maxRatioDeviation {
                issues.append(.unexpectedRatio)
            }
        }
        return ImageQualityReport(issues: issues, pixelSize: size)
    }

    /// "3:4" → 0.75；无法解析返回 nil
    static func aspectValue(_ raw: String) -> Double? {
        guard let normalized = ImageTaskPlanner.normalizeAspect(raw) else { return nil }
        let parts = normalized.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]), h > 0 else { return nil }
        return w / h
    }

    /// 是否需要重新生成（而不是单纯重存）。
    /// 规则：解不出/空/过小 → 重生成；仅体积异常（可能截断）→ 先重下一次再说。
    static func shouldRegenerate(_ report: ImageQualityReport) -> Bool {
        report.issues.contains(.undecodable)
            || report.issues.contains(.emptyPayload)
            || report.issues.contains(.tooSmall)
    }
}
