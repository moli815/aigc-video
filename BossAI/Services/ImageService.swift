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
            // P0-80 瞬时错误可重试（App 端双保险）：5xx + 429/430/439（网关限流/上游抖动——
            // "不要直接反馈给用户，先自己多尝试几次"；服务端也有一层重试）
            switch self {
            case .badResponse(let code, _): return code >= 500 || [429, 430, 439].contains(code)
            case .hosted(let code, _, _): return code >= 500 || [429, 430, 439].contains(code)
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

    /// 方案A（10-19）：参考图直传云存储，返回公网临时 URL（1 小时）。
    /// 链路：① 服务端签上传凭证 → ② App 用凭证 PUT 到 COS（App 网络，不受云函数出网限制）
    /// → ③ 回传 fileID 换公网 URL。任何一步失败返回 nil（调用方回退 base64）。
    static func uploadForHosted(_ data: Data) async -> String? {
        let token: String? = await MainActor.run { HostedAccount.isHostedActive ? HostedAccount.shared.token : nil }
        guard let token, !token.isEmpty, !data.isEmpty else { return nil }
        let base = AppConfig.hostedAPIBase

        // ① 签凭证
        guard let credURL = URL(string: base + "/upload-credential") else { return nil }
        var credReq = URLRequest(url: credURL)
        credReq.httpMethod = "POST"
        credReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        credReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        credReq.httpBody = try? JSONSerialization.data(withJSONObject: ["ext": "jpg"])
        // 10-23 P3：凭证请求走受限网络客户端，响应体限制 256KB
        guard let (credData, credResp) = try? await BoundedHTTPClient.data(for: credReq,
                                                                           session: BoundedHTTPClient.chatSession,
                                                                           limit: 256 * 1024),
              credResp.statusCode == 200,
              let credJSON = try? JSONSerialization.jsonObject(with: credData) as? [String: Any],
              let putURLString = credJSON["url"] as? String,
              let putURL = URL(string: putURLString),
              let fileID = credJSON["fileID"] as? String, !fileID.isEmpty else { return nil }

        // 10-22 安全：直传前校验 host 白名单。凭证由服务端签发，但若链路被篡改/配置错误，
        // 原实现会把用户图片 PUT 到任意第三方域名。这里只放行腾讯云 COS / CloudBase 域。
        // 10-23 P3 补充：必须强制 HTTPS，防止授权头经明文传输。
        guard putURL.scheme?.lowercased() == "https",
              let putHost = putURL.host?.lowercased(),
              putHost.hasSuffix(".myqcloud.com") || putHost.hasSuffix(".tcloudbase.com") || putHost.hasSuffix(".tencentcloudapi.com")
        else { return nil }

        // ② 直传 COS（PUT）：图片上传不走 BoundedHTTPClient 的 bytes 流（上传体已知大小），
        // 但仍用 imageSession 保证统一超时；响应体很小，限制 64KB。
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        putReq.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let auth = credJSON["authorization"] as? String { putReq.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let cosToken = credJSON["token"] as? String { putReq.setValue(cosToken, forHTTPHeaderField: "x-cos-security-token") }
        putReq.httpBody = data
        guard let (_, putResp) = try? await BoundedHTTPClient.data(for: putReq,
                                                                  session: BoundedHTTPClient.imageSession,
                                                                  limit: 64 * 1024),
              putResp.statusCode == 200 else { return nil }

        // ③ fileID → 公网 URL
        guard let fileURL = URL(string: base + "/file-url") else { return nil }
        var fileReq = URLRequest(url: fileURL)
        fileReq.httpMethod = "POST"
        fileReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        fileReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        fileReq.httpBody = try? JSONSerialization.data(withJSONObject: ["fileIDs": [fileID]])
        guard let (fileData, fileResp) = try? await BoundedHTTPClient.data(for: fileReq,
                                                                           session: BoundedHTTPClient.chatSession,
                                                                           limit: 256 * 1024),
              fileResp.statusCode == 200,
              let fileJSON = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              let urls = fileJSON["urls"] as? [String],
              let url = urls.first, !url.isEmpty else { return nil }
        return url
    }

    /// 生成图片；reference 非空时为参考图编辑（仅火山 Seedream 支持，
    /// 其他厂商收到 reference 时退化为按新描述重新生成）。
    /// 返回：图片二进制（PNG/JPEG）。失败抛 ImageError。
    func generate(prompt: String, references: [Data] = [], structured: [String: Any]? = nil, requestId: String? = nil, layerDecomposition: Bool = false) async throws -> Data {
        // 10-23 关键修复：hosted 模式必须用「会员 token」鉴权——服务端 bf-image 校验的是账号 token，
        // 供应商 Key 只在服务端。旧实现第一行就 guard apiKey（hosted 下为空）→ 直接抛 missingKey，
        // 模型收到工具失败后转述成"当前专家配置禁止使用 image_generate"（用户看到的错误结论）。
        let apiKey: String
        if profile.id == "hosted" {
            guard let t = HostedAccount.currentToken, !t.isEmpty else { throw ImageError.missingKey }
            apiKey = t
        } else {
            guard let k = apiKeyProvider(), !k.isEmpty else { throw ImageError.missingKey }
            apiKey = k
        }
        // 10-19 关键修复：hosted 模式改走 bf-image 独立函数（/img/image）——
        // 实测 /api/image 这条路径在网关层被特殊对待：同代码 /api/test-upstream 39s、/api/image >320s。
        // 新路径 /img/image 实测 42s 稳定。
        let endpoint: String
        if profile.id == "hosted" {
            let hostBase = AppConfig.hostedAPIBase.replacingOccurrences(of: "/api", with: "/img")
            endpoint = hostBase + "/image"
        } else {
            endpoint = "\(profile.baseURL)/images/generations"
        }
        guard let url = URL(string: endpoint) else {
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
        // 10-21 结构化视觉字段：服务端按模板拼装成专业 prompt（信息可控、画面文字更准）
        if let structured, !structured.isEmpty {
            body["structured"] = structured
        }
        // 10-22 幂等键：同一 requestId 在服务端 5 分钟内复用结果，避免"回填失败重试"重复生成/重复扣费
        if let requestId, !requestId.isEmpty {
            body["requestId"] = requestId
        }
        // 10-23 图层拆分（Seedream 5.0 pro 原生）：仅 1 张图，返回底图 + 最多 16 个透明 PNG 图层
        if layerDecomposition {
            body["layer_decomposition"] = true
        }
        switch profile.style {
        case .volc:
            body["size"] = "2K"
            body["response_format"] = "b64_json"
            body["watermark"] = false
            if !references.isEmpty {
                // P0-65 多图参考：Seedream 支持数组（[底图, 叠加元素] 顺序融合）——
                // 修复「把用户上传的 Logo 加到 AI 上次生成的图上」这类双图场景（此前单图只能传一张，底图会搞错）
                // 方案A（10-19）：hosted 模式下先把参考图直传云存储拿公网 URL——
                // 云函数出网代理会 reset"带二进制图的请求"，只有传 URL 才能打通编辑链路。
                var uris: [String] = []
                for ref in references {
                    if profile.id == "hosted", let u = await Self.uploadForHosted(ref) {
                        uris.append(u)
                    } else {
                        // BYOK 直连 / 上传失败：回退内联 base64（原有行为）
                        let mime = ref.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                        uris.append("data:\(mime);base64,\(ref.base64EncodedString())")
                    }
                }
                body["image"] = uris.count == 1 ? uris[0] : uris   // 单图保持字符串（兼容），多图传数组
            }
        case .zhipu:
            if !references.isEmpty { throw ImageError.unsupportedEdit }
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
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }
        // 10-23 关键修复：bf-image（hosted 模式）返回的是扁平结构 { ok, url, cost, cached, retried }，
        // 而这里此前只解析 OpenAI 的 { data: [ { url | b64_json } ] } ——
        // 结果是「服务端已经出图并扣了 0.45、App 端却抛 noImage」，用户看到"无法出图"。
        // 先认扁平 url，再回落到标准 data 数组。
        if let urlString = json["url"] as? String, let url = URL(string: urlString), url.scheme == "https" {
            let (img, response) = try await BoundedHTTPClient.data(for: URLRequest(url: url),
                                                                 session: BoundedHTTPClient.imageSession,
                                                                 limit: 32 * 1024 * 1024)
            guard response.statusCode == 200, response.mimeType?.hasPrefix("image/") == true else { throw ImageError.noImage }
            return img
        }
        if let b64 = json["b64_json"] as? String, let img = Data(base64Encoded: b64), img.count <= 32 * 1024 * 1024 {
            return img
        }
        guard let arr = json["data"] as? [[String: Any]], let first = arr.first else {
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
