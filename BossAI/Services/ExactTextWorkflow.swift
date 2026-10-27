import Foundation
import Vision
import ImageIO

/// Opt-in exact-copy workflow. Ordinary image requests remain native provider calls.
enum ExactTextWorkflow {
    struct Line: Sendable { let text: String; let confidence: Float }
    static func preservesSourceCopy(_ request: String) -> Bool {
        ["文案不变", "文字不变", "内容全不变", "保留所有文字", "保留原文", "不改文案", "不修改文字", "文字保持不变"].contains { request.contains($0) }
    }
    static func requiresAccuracy(_ request: String) -> Bool {
        preservesSourceCopy(request) || ["文字必须准确", "文字准确", "逐字", "一字不差", "文字不能错", "文案不能错"].contains { request.contains($0) }
    }
    static func recognize(_ data: Data) async -> [Line] {
        await Task.detached(priority: .userInitiated) { () -> [Line] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = false
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
            do {
                try VNImageRequestHandler(data: data, orientation: orientation, options: [:]).perform([request])
                return (request.results ?? []).compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return Line(text: candidate.string, confidence: candidate.confidence)
                }
            } catch { return [] }
        }.value
    }
    static func resolve(proposed: [TextItem], source: Data?, request: String) async throws -> [TextItem] {
        guard preservesSourceCopy(request), let source else { return proposed }
        let lines = await recognize(source)
        try Task.checkCancellation()
        guard !lines.isEmpty, lines.allSatisfy({ line in
            line.confidence >= (line.text.contains(where: \.isNumber) ? 0.8 : 0.5)
        }) else {
            throw ExpertSkillError.invalidInput("原图有些小字尚未识别清楚，请补充准确文案或上传更清晰的图片，再为你重排版。")
        }
        func compact(_ value: String) -> String { String(value.filter { !$0.isWhitespace }) }
        let provided = compact(proposed.map(\.text).joined())
        if !proposed.isEmpty, lines.allSatisfy({ provided.contains(compact($0.text)) }) { return proposed }
        // Missing or rewritten copy is restored from OCR, never from visual instructions.
        return lines.enumerated().map { index, line in
            TextItem(role: index == 0 && line.text.count <= 30 ? .title : .body, key: "source-\(index)", text: line.text)
        }
    }
}
