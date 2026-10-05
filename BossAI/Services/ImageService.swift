import Foundation

/// 图像服务：按识别到的服务商档案调用（火山 Seedream 4.0 / 智谱 CogView）。
/// 支持文生图；火山 Seedream 支持参考图编辑（多轮改图）。
final class ImageService {
    enum ImageError: LocalizedError {
        case missingKey, badResponse(Int, String), noImage, unsupportedEdit
        var errorDescription: String? {
            switch self {
            case .unsupportedEdit: return "当前作图服务不支持参考图编辑，请切换支持编辑的服务商。"
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
                let mime = reference.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                body["image"] = "data:\(mime);base64,\(reference.base64EncodedString())"
            }
        case .zhipu:
            if reference != nil { throw ImageError.unsupportedEdit }
            // CogView：仅文生图，返回 URL
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await BoundedHTTPClient.data(for: request, session: BoundedHTTPClient.imageSession, limit: 48 * 1024 * 1024)
        if response.statusCode != 200 {
            let http = response
            throw ImageError.badResponse(
                http.statusCode,
                "服务商 \(profile.displayName)｜\(profile.baseURL)/images/generations｜模型 \(profile.model)\n\(String(data: data, encoding: .utf8) ?? "")"
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]], let first = arr.first else {
            throw ImageError.noImage
        }
        if let b64 = first["b64_json"] as? String, let img = Data(base64Encoded: b64), img.count <= 32 * 1024 * 1024 {
            return img
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString), url.scheme == "https" {
            let (img, response) = try await BoundedHTTPClient.data(for: URLRequest(url: url), session: BoundedHTTPClient.imageSession, limit: 32 * 1024 * 1024)
            guard response.statusCode == 200, response.mimeType?.hasPrefix("image/") == true else { throw ImageError.noImage }
            return img
        }
        throw ImageError.noImage
    }
}
