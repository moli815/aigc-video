import Foundation

/// 图像服务：火山引擎 Seedream 4.0（OpenAI 兼容 images/generations）。
/// 支持文生图与参考图编辑（Seedream 4.0 原生支持）。
final class ImageService {
    enum ImageError: LocalizedError {
        case missingKey, badResponse(Int, String), noImage
        var errorDescription: String? {
            switch self {
            case .missingKey: return "未配置作图 API Key"
            case .badResponse(let code, let body): return "生图失败（\(code)）：\(body.prefix(300))"
            case .noImage: return "生图接口未返回图片"
            }
        }
    }

    private let apiKeyProvider: () -> String?
    init(apiKeyProvider: @escaping () -> String?) {
        self.apiKeyProvider = apiKeyProvider
    }

    /// 生成图片；reference 非空时为参考图编辑（多轮改图）。
    func generate(prompt: String, reference: Data? = nil) async throws -> Data {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw ImageError.missingKey }

        var request = URLRequest(url: URL(string: "\(AppConfig.imageBaseURL)/images/generations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        var body: [String: Any] = [
            "model": AppConfig.imageModel,
            "prompt": prompt,
            "size": "2K",
            "response_format": "b64_json",
            "watermark": false,
        ]
        if let reference {
            // 火山方舟 Seedream 4.0 参考图：base64 data URI
            body["image"] = "data:image/png;base64,\(reference.base64EncodedString())"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ImageError.badResponse(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]], let first = arr.first else {
            throw ImageError.noImage
        }
        if let b64 = first["b64_json"] as? String, let img = Data(base64Encoded: b64) {
            return img
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            let (img, _) = try await URLSession.shared.data(from: url)
            return img
        }
        throw ImageError.noImage
    }
}
