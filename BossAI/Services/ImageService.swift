import Foundation

// ============================================================================
// 文件职责：文生图 / 参考图编辑服务。
// 在 App 中的角色：ChatService 之外的第二条模型调用链——按 ImageProfile（火山
//   Seedream / 智谱 CogView / 云端 hosted）调用 /images/generations 并解码图片。
// 关键设计决策与防呆：
//   1. 统一走 BoundedHTTPClient（限响应体大小 + 专用超时会话），防止异常大响应拖垮内存；
//   2. 云端 hosted 模式只透出服务端中文 message，不泄露上游错误细节；401 等会话
//      失效错误统一交给 HostedAccount 强制登出；
//   3. b64 与 URL 两种返回形态都支持，URL 限定 https 且校验 MIME，防止误下载。
// ============================================================================

/// 图像服务：按识别到的服务商档案调用（火山 Seedream 4.0 / 智谱 CogView）。
/// 支持文生图；火山 Seedream 支持参考图编辑（多轮改图）。
final class ImageService {
    /// 生图相关错误的统一封装（errorDescription 均为用户可读中文）。
    /// missingKey=未配置 Key；badResponse=上游响应异常(状态码+脱敏片段)；
    /// noImage=响应里没有图片；unsupportedEdit=当前服务商不支持参考图编辑。
    enum ImageError: LocalizedError {
        case missingKey, badResponse(Int, String), noImage, unsupportedEdit
        /// 云端会员模式的结构化错误（不泄露上游细节）
        case hosted(Int, String, String)
        var errorDescription: String? {
            switch self {
            case .unsupportedEdit: return "当前作图服务不支持参考图编辑，请切换支持编辑的服务商。"
            case .missingKey: return "未配置作图 API Key"
            case .badResponse(let code, let body): return "生图失败（\(code)）：\(body.prefix(300))"
            case .noImage: return "生图接口未返回图片"
            case .hosted(_, _, let message): return message
            }
        }
        /// 会话失效（重置密码/封停/到期）——调用方据此强制登出
        var isSessionFailure: Bool {
            if case .hosted(let status, let code, _) = self {
                return status == 401 || code == "ACCOUNT_SUSPENDED" || code == "MEMBERSHIP_EXPIRED"
            }
            return false
        }
        /// P0-52 是否可重试：仅上游网关/超时类错误（5xx）可自动重试；
        /// 参数(4xx)/额度/会话失效等不可重试（重试无意义或有副作用）。
        var isRetryable: Bool {
            switch self {
            case .badResponse(let code, _): return code >= 500
            case .hosted(let code, _, _): return code >= 500
            default: return false
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
    /// 返回：图片二进制（PNG/JPEG）。失败抛 ImageError。
    func generate(prompt: String, reference: Data? = nil) async throws -> Data {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw ImageError.missingKey }
        guard let url = URL(string: "\(profile.baseURL)/images/generations") else {
            throw ImageError.badResponse(400, "服务地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // P0-64 超时云端可调（在线可修复）：管理台改 APP_IMAGE_TIMEOUT 即生效
        request.timeoutInterval = HostedAccount.isHostedActive ? HostedAccount.cachedImageTimeout : 180

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
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            // 云端会员模式：只透出服务端中文消息，不泄露上游细节；会话失效统一强制登出
            if profile.id == "hosted",
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = obj["message"] as? String {
                let code = (obj["error"] as? String) ?? ""
                let hostedErr = ImageError.hosted(response.statusCode, code, message)
                if hostedErr.isSessionFailure {
                    await HostedAccount.shared.handleSessionFailure(message)
                }
                throw hostedErr
            }
            // 手动 Key 模式：脱敏展示
            throw ImageError.badResponse(
                response.statusCode,
                "服务商响应异常（\(response.statusCode)），请稍后重试。\(String(bodyText.suffix(200)))"
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]], let first = arr.first else {
            throw ImageError.noImage
        }
        if let b64 = first["b64_json"] as? String, let img = Data(base64Encoded: b64), img.count <= 32 * 1024 * 1024 {
            // b64 优先：数据已在手，省一次网络往返；32MB 上限防异常大图
            return img
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString), url.scheme == "https" {
            // URL 形态：仅接受 https，防明文下载被劫持
            let (img, response) = try await BoundedHTTPClient.data(for: URLRequest(url: url), session: BoundedHTTPClient.imageSession, limit: 32 * 1024 * 1024)
            guard response.statusCode == 200, response.mimeType?.hasPrefix("image/") == true else { throw ImageError.noImage }
            return img
        }
        throw ImageError.noImage
    }
}
