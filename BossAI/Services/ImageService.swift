import Foundation

/// 图像服务：按识别到的服务商档案调用（火山 Seedream 4.0 / 智谱 CogView）。
/// 支持文生图；火山 Seedream 支持参考图编辑（多轮改图）。
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

    private let profile: ImageProfile
    private let apiKeyProvider: () -> String?
    init(profile: ImageProfile, apiKeyProvider: @escaping () -> String?) {
        self.profile = profile
        self.apiKeyProvider = apiKeyProvider
    }

    /// 生成图片；reference 非空时为参考图编辑（仅火山 Seedream 支持，
    /// 其他厂商收到 reference 时退化为按新描述重新生成）。
    func generate(prompt: String, reference: Data? = nil) async throws -> Data {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw ImageError.missingKey }

        var request = URLRequest(url: URL(string: "\(profile.baseURL)/images/generations")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        var body: [String: Any] = [
            "model": profile.model,
            "prompt": prompt,
        ]
        switch profile.style {
        case .volc:
            body["size"] = "2K"
            body["response_format"] = "b64_json"
            body["watermark"] = false
            if let reference {
                // 火山方舟 Seedream 4.0 参考图：base64 data URI
                body["image"] = "data:image/png;base64,\(reference.base64EncodedString())"
            }
        case .zhipu:
            // CogView：仅文生图，返回 URL
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ImageError.badResponse(
                http.statusCode,
                "服务商 \(profile.displayName)｜\(profile.baseURL)/images/generations｜模型 \(profile.model)\n\(String(data: data, encoding: .utf8) ?? "")"
            )
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
