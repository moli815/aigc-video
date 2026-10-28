import Foundation

// ============================================================================
// 文件职责：文生图 / 参考图编辑 / 组图服务。
// 在 App 中的角色：ChatService 之外的第二条模型调用链——按 ImageProfile（火山
//   Seedream / 智谱 CogView / 云端 hosted）调用 /images/generations 并解码图片。
// 关键设计决策与防呆：
//   1. 统一走 BoundedHTTPClient（限响应体大小 + 专用超时会话），防止异常大响应拖垮内存；
//   2. 云端 hosted 模式只透出服务端中文 message，不泄露上游错误细节；401 等会话
//      失效错误统一交给 HostedAccount 强制登出；
//   3. b64 与 URL 两种返回形态都支持，URL 限定 https 且校验 MIME，防止误下载；
//   4. 10-24 组图：新增 generateSeries() 返回**多图结果**，不再把 N 张塞进单个 Data。
//      单图 generate() 保留原契约，旧调用点零改动。
// ============================================================================

/// 图像服务：按识别到的服务商档案调用（火山 Seedream 4.0 / 智谱 CogView）。
/// 支持文生图；火山 Seedream 支持参考图编辑（多轮改图）；云端模式支持组图编排。
/// 单图类任务（文生图 / 编辑 / 参考图 / 图层拆分）的**不可变参数集**。
///
/// 边界：**组图（image_series）不走这里**——它有自己的
/// `runSeriesTask` 子任务编排（逐张 step + 部分成功 + 失败项重试）。
/// 其他单图任务共享这一契约；需要精确可见文案时，另由通用文字后处理完成。
///
/// 为什么需要它：视觉复核失败后的重试曾经只传 prompt/aspectRatio，
/// 把 taskKind、qualityTier、requestedCount 全丢了 —— 于是"Pro 编辑重试变成普通生图"、
/// "组图 4 张重试变 1 张"、"名片重试不走排版"。参数一旦分散在调用点，就一定会漏。
/// 现在首轮构造一次，所有重试从同一份上下文派生，只允许追加"修正说明"。
enum ImageTextMode: String { case native, overlay }

struct ImageRequestContext {
    /// Stable for transport retries. A changed generation intent creates a new instance/ID.
    let requestId: String
    let prompt: String
    let references: [Data]
    let taskKind: String
    let qualityTier: String
    let requestedCount: Int?
    let aspectRatio: String
    let renderIntent: String
    let structured: [String: Any]?
    /// 图层拆分任务（image_decompose）：漏传会退化成普通生图
    let layerDecomposition: Bool
    let textMode: ImageTextMode

    /// 10-25 几何保护：显式像素尺寸（"1200x800"）。
    /// 有值时请求走 size 字段，精确保留来源画布比例；服务端再按该尺寸请求模型。
    let targetSize: String?

    /// 显式初始化不可变请求契约；文字排版状态不属于模型请求参数。
    init(prompt: String, references: [Data], taskKind: String, qualityTier: String,
         requestedCount: Int?, aspectRatio: String, renderIntent: String,
         structured: [String: Any]?, layerDecomposition: Bool,
         targetSize: String? = nil, textMode: ImageTextMode = .native, requestId: String = UUID().uuidString) {
        self.requestId = requestId
        self.prompt = prompt
        self.references = references
        self.taskKind = taskKind
        self.qualityTier = qualityTier
        self.requestedCount = requestedCount
        self.aspectRatio = aspectRatio
        self.renderIntent = renderIntent
        self.structured = structured
        self.layerDecomposition = layerDecomposition
        self.targetSize = targetSize
        self.textMode = textMode
    }

    /// 派生：追加提示词后缀（`prompt` 是 let，不能原地赋值；必须新建实例）
    func appendingPrompt(_ suffix: String) -> ImageRequestContext {
        ImageRequestContext(prompt: prompt + suffix,
                            references: references,
                            taskKind: taskKind,
                            qualityTier: qualityTier,
                            requestedCount: requestedCount,
                            aspectRatio: aspectRatio,
                            renderIntent: renderIntent,
                            structured: structured,
                            layerDecomposition: layerDecomposition,
                            targetSize: targetSize, textMode: textMode)
    }

    /// Builds a text-free background request: remove exact display copy from both prompt
    /// sources while retaining visual direction such as composition, lighting, and style.
    func forTextlessBackground(items: [TextItem]) -> ImageRequestContext {
        var backgroundPrompt = prompt
        let visibleCopy = Set(items.flatMap { item in
            let full = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: "，,；;。"))
            let fragments = item.text.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 3 }
            return ([full] + fragments).filter { $0.count >= 3 }
        })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for text in visibleCopy {
            backgroundPrompt = backgroundPrompt.replacingOccurrences(of: text, with: " ")
        }
        var visualFields = structured ?? [:]
        visualFields.removeValue(forKey: "text")
        visualFields = visualFields.mapValues { Self.removingVisibleCopy($0, values: visibleCopy) }
        return ImageRequestContext(prompt: backgroundPrompt,
                                   references: references,
                                   taskKind: taskKind,
                                   qualityTier: qualityTier,
                                   requestedCount: requestedCount,
                                   aspectRatio: aspectRatio,
                                   renderIntent: renderIntent,
                                   structured: visualFields.isEmpty ? nil : visualFields,
                                   layerDecomposition: layerDecomposition,
                                   targetSize: targetSize, textMode: .overlay)
    }

    private static func removingVisibleCopy(_ value: Any, values: [String]) -> Any {
        if let text = value as? String {
            return values.reduce(text) { partial, visible in
                partial.replacingOccurrences(of: visible, with: " ")
            }
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { removingVisibleCopy($0, values: values) }
        }
        if let array = value as? [Any] {
            return array.map { removingVisibleCopy($0, values: values) }
        }
        return value
    }

    /// 派生重试上下文：除 prompt 追加说明外，**其余参数原样继承**
    func retrying(note: String) -> ImageRequestContext {
        // 重试只能改变 prompt，不逐字段赋值或重新推断请求参数。
        return ImageRequestContext(prompt: prompt + "\n\n【重要修正】" + note,
                                   references: references,
                                   taskKind: taskKind,
                                   qualityTier: qualityTier,
                                   requestedCount: requestedCount,
                                   aspectRatio: aspectRatio,
                                   renderIntent: renderIntent,
                                   structured: structured,
                                   layerDecomposition: layerDecomposition,
                                   targetSize: targetSize, textMode: textMode)
    }
}

final class ImageService {
    var usesHostedIdempotency: Bool { profile.id == "hosted" }
    /// 生图相关错误的统一封装（errorDescription 均为用户可读中文）。
    enum ImageError: LocalizedError, APIErrorCarrying {
        case missingKey
        case badResponse(Int, String)
        case noImage
        case unsupportedEdit
        case unsupportedAspectRatio
        /// 云端会员模式的结构化错误（历史形态，保留兼容）
        case hosted(Int, String, String)
        /// 10-24：带完整信封（actions / requestId / retryable）的云端错误
        case envelope(APIErrorEnvelope)
        /// 10-25：同一 requestId 还在生成中（HTTP 409 + IN_PROGRESS）。
        /// 这不是失败——重复提交也没用，必须提示"稍后查看"而不是报错。
        case inProgress(String)
        /// 10-25：任务类型不被当前模型支持（pro_only 下的组图）。422 + TASK_UNSUPPORTED，不重试不降级
        case taskUnsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedEdit: return "当前作图服务不支持参考图编辑，请切换支持编辑的服务商。"
            case .unsupportedAspectRatio: return "当前图像服务无法准确应用这个画布比例，请切换支持该比例的服务商或改用常见比例。"
            case .missingKey: return "未配置作图 API Key"
            case .badResponse(let code, let body): return "生图失败（\(code)）：\(body.prefix(300))"
            case .noImage: return "生图接口未返回图片"
            case .inProgress(let msg): return msg.isEmpty ? "正在生成，稍后查看" : msg
            case .taskUnsupported(let msg): return msg.isEmpty ? "当前模型暂不支持该任务，请换一种方式" : msg
            case .hosted(_, _, let message): return message
            case .envelope(let e): return e.message
            }
        }

        /// 会话失效（重置密码/封停/到期）—— 调用方据此强制登出
        /// 生成中：调用方据此显示"正在生成，稍后查看"，且**不得**重复提交/计入失败
        var isInProgress: Bool {
            if case .inProgress = self { return true }
            return false
        }

        var isSessionFailure: Bool {
            switch self {
            case .envelope(let e): return e.isSessionFailure
            case .hosted(let status, let code, _):
                return status == 401 || code == "ACCOUNT_SUSPENDED" || code == "MEMBERSHIP_EXPIRED"
            default: return false
            }
        }

        /// 是否可重试：优先用服务端给出的 retryable，旧服务端回落到状态码判断。
        var isRetryable: Bool {
            if case .envelope(let e) = self { return e.retryable }
            switch self {
            case .badResponse(let code, _): return code >= 500 || [429, 430, 439].contains(code)
            case .hosted(let code, _, _): return code >= 500 || [429, 430, 439].contains(code)
            default: return false
            }
        }

        var envelope: APIErrorEnvelope? {
            if case .envelope(let e) = self { return e }
            return nil
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
        guard putURL.scheme?.lowercased() == "https",
              let putHost = putURL.host?.lowercased(),
              putHost.hasSuffix(".myqcloud.com") || putHost.hasSuffix(".tcloudbase.com") || putHost.hasSuffix(".tencentcloudapi.com")
        else { return nil }

        // ② 直传 COS（PUT）
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        putReq.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        if let auth = credJSON["authorization"] as? String { putReq.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let auth = credJSON["authorization"] as? String { putReq.setValue(auth, forHTTPHeaderField: "Signature") }
        if let cloudPath = credJSON["cloudPath"] as? String { putReq.setValue(cloudPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "key") }
        if let fileId = credJSON["cosFileId"] as? String { putReq.setValue(fileId, forHTTPHeaderField: "x-cos-meta-fileid") }
        putReq.setValue("private", forHTTPHeaderField: "x-cos-acl")
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

    // MARK: - 请求构造（单图与组图共用，避免两套 body 漂移）

    /// 组装生图请求。10-24 路由契约：客户端只表达**业务意图**
    /// （taskKind / qualityTier / requestedCount），模型 ID 由服务端决定。
    private func makeRequest(prompt: String,
                             references: [Data],
                             structured: [String: Any]?,
                             requestId: String?,
                             layerDecomposition: Bool,
                             renderIntent: String?,
                             aspectRatio: String?,
                             taskKind: String?,
                             qualityTier: String?,
                             requestedCount: Int?,
                             targetSize: String? = nil,
                             textMode: String? = nil) async throws -> URLRequest {
        let session = profile.id == "hosted" ? await MainActor.run { CloudSession.capture() } : nil
        let apiKey: String
        if profile.id == "hosted" {
            guard let session else { throw ImageError.missingKey }
            apiKey = session.token
        } else {
            guard let k = apiKeyProvider(), !k.isEmpty else { throw ImageError.missingKey }
            apiKey = k
        }

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
        // 10-24：把 requestId 同时放进请求头 —— 服务端日志、幂等任务、账务事件共用同一个 ID，
        // 排障时能一条链路串起来（P1-8）。
        if let requestId, !requestId.isEmpty {
            request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        }
        let baseTimeout = HostedAccount.isHostedActive ? HostedAccount.cachedImageTimeout : 180
        let count = max(1, requestedCount ?? 1)
        // 组图是串行生成，超时必须按时长放大，否则客户端先超时、服务端还在跑（会重复扣费）
        request.timeoutInterval = min(600, baseTimeout * Double(count))

        let isHosted = profile.id == "hosted"
        var body: [String: Any]
        if isHosted {
            body = ImageProviderRequestCompiler.hosted(model: profile.model, prompt: prompt,
                                                       structured: structured, requestId: requestId,
                                                       layerDecomposition: layerDecomposition,
                                                       renderIntent: renderIntent, aspectRatio: aspectRatio,
                                                       taskKind: taskKind, qualityTier: qualityTier,
                                                       requestedCount: requestedCount, targetSize: targetSize,
                                                       textMode: textMode)
        } else {
            switch profile.style {
            case .volc:
                body = try ImageProviderRequestCompiler.seedream(model: profile.model, prompt: prompt,
                                                                 references: references, structured: structured,
                                                                 layerDecomposition: layerDecomposition,
                                                                 aspectRatio: aspectRatio, taskKind: taskKind,
                                                                 requestedCount: requestedCount,
                                                                 targetSize: targetSize)
            case .zhipu:
                body = try ImageProviderRequestCompiler.zhipu(model: profile.model, prompt: prompt,
                                                              references: references, structured: structured,
                                                              layerDecomposition: layerDecomposition,
                                                              aspectRatio: aspectRatio, taskKind: taskKind,
                                                              requestedCount: requestedCount,
                                                              targetSize: targetSize)
            }
        }

        switch profile.style {
        case .volc:
            body["response_format"] = "b64_json"
            body["watermark"] = false
            if !references.isEmpty {
                var uris: [String] = []
                for ref in references {
                    if let session {
                        let asset = try await CloudAssetStore.upload(ref, mime: CloudAssetStore.contentType(ref), session: session)
                        let signed = try await session.request("/assets/urls", method: "POST", body: ["ids": [asset.id]])
                        guard let rows = signed["items"] as? [[String: Any]],
                              let url = rows.first?["url"] as? String,
                              let parsed = URL(string: url), CloudAssetStore.allowed(parsed) else { throw ImageError.noImage }
                        uris.append(url)
                    } else {
                        let mime = ref.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                        uris.append("data:\(mime);base64,\(ref.base64EncodedString())")
                    }
                }
                body["image"] = uris.count == 1 ? uris[0] : uris
            }
        case .zhipu:
            break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let session { try await session.validate() }
        return request
    }

    private func validateSession(for request: URLRequest) async throws {
        try Task.checkCancellation()
        guard profile.id == "hosted" else { return }
        let token = await MainActor.run { HostedAccount.shared.token }
        guard let token, request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else {
            throw CancellationError()
        }
    }

    /// 非 200 响应 → 结构化错误（hosted 模式解析信封；BYOK 脱敏展示）
    private func error(from data: Data, response: HTTPURLResponse) -> ImageError {
        if profile.id == "hosted",
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 409 + IN_PROGRESS：不是错误，是"还在生成"。必须在信封解析前拦下，
            // 否则会被当成普通失败弹窗，用户以为坏了就会重复点、重复扣费。
            if response.statusCode == 409, (obj["error"] as? String) == "IN_PROGRESS" {
                return .inProgress((obj["message"] as? String) ?? "正在生成，稍后查看")
            }
            if response.statusCode == 422, (obj["error"] as? String) == "TASK_UNSUPPORTED" {
                return .taskUnsupported((obj["message"] as? String) ?? (obj["msg"] as? String) ?? "")
            }
            if let env = APIErrorEnvelope.parse(status: response.statusCode, json: obj) {
                return .envelope(env)
            }
            if let message = obj["message"] as? String {
                return .hosted(response.statusCode, (obj["error"] as? String) ?? "", message)
            }
        }
        return .badResponse(
            response.statusCode,
            "作图服务暂时没有完成这次请求（\(response.statusCode)），请稍后重试。"
        )
    }

    /// 下载单张图片：仅 https，校验状态码 + MIME + 体积上限
    private static func downloadImage(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString), url.scheme == "https" else { throw ImageError.noImage }
        let (img, resp) = try await BoundedHTTPClient.data(for: URLRequest(url: url),
                                                          session: BoundedHTTPClient.imageSession,
                                                          limit: 32 * 1024 * 1024)
        guard resp.statusCode == 200, resp.mimeType?.hasPrefix("image/") == true else { throw ImageError.noImage }
        return img
    }

    // MARK: - 单图（保持原契约，旧调用点零改动）

    /// 执行单图请求；reference 可用于整体重设计，edit 才表示局部编辑。返回图片二进制。
    func generate(prompt: String, references: [Data] = [], structured: [String: Any]? = nil, requestId: String? = nil, layerDecomposition: Bool = false, renderIntent: String? = nil, aspectRatio: String? = nil, taskKind: String? = nil, qualityTier: String? = nil, requestedCount: Int? = nil, targetSize: String? = nil, textMode: String? = nil) async throws -> Data {
        let request = try await makeRequest(prompt: prompt, references: references, structured: structured,
                                            requestId: requestId, layerDecomposition: layerDecomposition,
                                            renderIntent: renderIntent, aspectRatio: aspectRatio,
                                            taskKind: taskKind, qualityTier: qualityTier,
                                            requestedCount: requestedCount, targetSize: targetSize,
                                            textMode: textMode)
        let (data, response) = try await BoundedHTTPClient.data(for: request, session: BoundedHTTPClient.imageSession, limit: 48 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 {
            let err = error(from: data, response: response)
            if err.isSessionFailure {
                await HostedAccount.shared.handleSessionFailure(err.errorDescription ?? "")
            }
            throw err
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }
        if let urlString = json["url"] as? String {
            let image = try await Self.downloadImage(urlString)
            try await validateSession(for: request)
            return image
        }
        if let b64 = json["b64_json"] as? String, let img = Data(base64Encoded: b64), img.count <= 32 * 1024 * 1024 {
            return img
        }
        guard let arr = json["data"] as? [[String: Any]], let first = arr.first else {
            throw ImageError.noImage
        }
        if let b64 = first["b64_json"] as? String, let img = Data(base64Encoded: b64), img.count <= 32 * 1024 * 1024 {
            return img
        }
        if let urlString = first["url"] as? String {
            let image = try await Self.downloadImage(urlString)
            try await validateSession(for: request)
            return image
        }
        throw ImageError.noImage
    }

    /// 按规划器的计划直接生成（10-24 新增）。
    /// 只做「计划 → 请求参数」的适配，不改动既有 generate 的任何行为：
    /// 调用方仍然可以随时走原来的长参数版本。
    func generate(plan: ImageTaskPlan,
                  references: [Data] = [],
                  requestId: String? = nil) async throws -> Data {
        try await generate(prompt: plan.prompt,
                           references: references,
                           requestId: requestId,
                           aspectRatio: plan.aspectRatio,
                           taskKind: Self.taskKind(for: plan.taskType),
                           qualityTier: plan.qualityTier,
                           requestedCount: plan.outputCount > 1 ? plan.outputCount : nil,
                           targetSize: plan.targetSize)
    }

    /// 规划类型 → 服务端 task_kind；reference 与 edit 都可带图，但服务端策略不同。
    static func taskKind(for type: ImageTaskType) -> String {
        switch type {
        case .edit: return "edit"
        case .reference: return "reference"
        case .series: return "series"
        case .generate: return "generate"
        }
    }

    // MARK: - 组图（10-24 新增：N 张逐张下载，不再只取第一张）

    /// 单张子任务的结果（成功或失败的**用户可见**信息）
    struct SeriesItemResult: Equatable, Sendable {
        let index: Int
        let ok: Bool
        /// 已下载到本机的图片（ok=true 且下载成功时非空）
        let imageData: Data?
        let remoteURL: String
        let model: String
        let cost: Double
        /// 失败的友好文案（成功时为空）
        let message: String
        /// 机器分类（仅用于日志/重试判断，不展示）
        let errorCategory: String
        /// 上游已出图但本地下载失败 —— 这种情况**不能重新生成**
        let downloadFailed: Bool
        let reused: Bool
    }

    /// 组图结果：请求 N 张时，成功几张、失败哪几张、花了多少，全部结构化。
    struct SeriesOutcome: Equatable, Sendable {
        let requestId: String
        let requested: Int
        let items: [SeriesItemResult]
        let pricedCny: Double
        let committedCny: Double
        let pendingCostCount: Int
        let partial: Bool
        let cached: Bool
        let size: String
        let qualityTier: String

        var succeededItems: [SeriesItemResult] { items.filter { $0.imageData != nil } }
        var failedIndices: [Int] { items.filter { !$0.ok }.map(\.index) }
        var downloadFailedIndices: [Int] { items.filter { $0.downloadFailed }.map(\.index) }
        var succeededCount: Int { succeededItems.count }
        /// 上游确认成功（含下载失败的）张数
        var upstreamSucceeded: Int { items.filter(\.ok).count }
    }

    /// 组图：服务端把它拆成 N 个单图子任务，逐张返回。
    /// 每张单独校验 HTTPS/MIME/体积；单张下载失败只影响该张，不抛整组错误。
    func generateSeries(prompt: String,
                        requestId: String?,
                        requestedCount: Int,
                        qualityTier: String? = nil,
                        aspectRatio: String? = nil,
                        renderIntent: String? = nil,
                        structured: [String: Any]? = nil,
                        references: [Data] = []) async throws -> SeriesOutcome {
        let n = max(2, min(4, requestedCount))
        let request = try await makeRequest(prompt: prompt, references: references, structured: structured,
                                            requestId: requestId, layerDecomposition: false,
                                            renderIntent: renderIntent, aspectRatio: aspectRatio,
                                            taskKind: "series", qualityTier: qualityTier,
                                            requestedCount: n)
        let (data, response) = try await BoundedHTTPClient.data(for: request,
                                                                session: BoundedHTTPClient.imageSession,
                                                                limit: 48 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 {
            let err = error(from: data, response: response)
            if err.isSessionFailure {
                await HostedAccount.shared.handleSessionFailure(err.errorDescription ?? "")
            }
            throw err
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }

        var items: [SeriesItemResult] = []
        if let rawItems = json["items"] as? [[String: Any]] {
            for (offset, raw) in rawItems.enumerated() {
                let index = (raw["index"] as? Int) ?? (offset + 1)
                let ok = (raw["ok"] as? Bool) ?? false
                let remote = (raw["url"] as? String) ?? ""
                let model = (raw["model"] as? String) ?? ""
                let cost = (raw["cost"] as? Double) ?? Double((raw["cost"] as? NSNumber)?.doubleValue ?? 0)
                let message = (raw["message"] as? String) ?? ""
                let category = (raw["errorCategory"] as? String) ?? ""
                let reused = (raw["reused"] as? Bool) ?? false

                var imageData: Data?
                var downloadFailed = false
                if ok, !remote.isEmpty {
                    do {
                        imageData = try await Self.downloadImage(remote)
                    } catch {
                        // 上游已出图、只是本机没拿到：记录为"下载失败"，绝不重新生成
                        downloadFailed = true
                    }
                }
                items.append(SeriesItemResult(index: index, ok: ok, imageData: imageData,
                                              remoteURL: remote, model: model, cost: cost,
                                              message: ok ? "" : (message.isEmpty ? "这一张没有生成成功，可以单独重试。" : message),
                                              errorCategory: category,
                                              downloadFailed: downloadFailed, reused: reused))
            }
        } else if let url = json["url"] as? String {
            // 服务端降级成单图结构（例如旧版本）：包成 1 张，保证不丢结果
            let img = try? await Self.downloadImage(url)
            items = [SeriesItemResult(index: 1, ok: true, imageData: img, remoteURL: url,
                                      model: (json["model"] as? String) ?? "", cost: 0,
                                      message: "", errorCategory: "",
                                      downloadFailed: img == nil, reused: false)]
        } else {
            throw ImageError.noImage
        }

        let priced = (json["pricedCny"] as? Double) ?? (json["billedCny"] as? Double) ?? 0
        let committed = (json["committedCny"] as? Double) ?? 0
        let pending = (json["pendingCostCount"] as? Int) ?? 0
        return SeriesOutcome(
            requestId: (json["requestId"] as? String) ?? (requestId ?? ""),
            requested: (json["requested"] as? Int) ?? n,
            items: items.sorted { $0.index < $1.index },
            pricedCny: priced,
            committedCny: committed,
            pendingCostCount: pending,
            partial: (json["partial"] as? Bool) ?? false,
            cached: (json["cached"] as? Bool) ?? false,
            size: (json["size"] as? String) ?? "",
            qualityTier: (json["quality_tier"] as? String) ?? (qualityTier ?? "")
        )
    }

    // MARK: - 组图任务（10-24 P1-5：服务端状态机 + 客户端驱动）

    /// 任务快照：服务端持久化的状态 + 已成功项的图片
    struct SeriesTaskSnapshot: Equatable, Sendable {
        let taskId: String
        let requestId: String
        /// queued / running / partial / done / failed / cancelled
        let status: String
        let requested: Int
        let items: [SeriesItemResult]
        let pendingIndices: [Int]
        let failedIndices: [Int]
        let pricedCny: Double
        let committedCny: Double
        let pendingCostCount: Int
        let partial: Bool
        let size: String
        let qualityTier: String

        var succeededItems: [SeriesItemResult] { items.filter { $0.imageData != nil } }
        var isFinished: Bool { ["done", "partial", "failed", "cancelled"].contains(status) }
        var isCancelled: Bool { status == "cancelled" }
    }

    private func seriesEndpoint(_ suffix: String) -> URL? {
        URL(string: AppConfig.hostedAPIBase.replacingOccurrences(of: "/api", with: "/img") + suffix)
    }

    /// 把服务端任务 JSON 解析成快照；`downloadIndices` 指定要下载哪几张（其余只保留 URL）
    private func parseTaskSnapshot(_ json: [String: Any], downloadIndices: Set<Int>) async -> SeriesTaskSnapshot {
        var items: [SeriesItemResult] = []
        for (offset, raw) in ((json["items"] as? [[String: Any]]) ?? []).enumerated() {
            let index = (raw["index"] as? Int) ?? (offset + 1)
            let ok = (raw["ok"] as? Bool) ?? false
            let remote = (raw["url"] as? String) ?? ""
            var imageData: Data?
            var downloadFailed = false
            if ok, !remote.isEmpty, downloadIndices.contains(index) {
                do { imageData = try await Self.downloadImage(remote) }
                catch { downloadFailed = true }
            }
            items.append(SeriesItemResult(
                index: index, ok: ok, imageData: imageData, remoteURL: remote,
                model: (raw["model"] as? String) ?? "",
                cost: (raw["cost"] as? Double) ?? Double((raw["cost"] as? NSNumber)?.doubleValue ?? 0),
                message: (raw["message"] as? String) ?? "",
                errorCategory: (raw["errorCategory"] as? String) ?? "",
                downloadFailed: downloadFailed,
                reused: (raw["reused"] as? Bool) ?? false
            ))
        }
        var pending: [Int] = []
        if let raw = json["pendingIndices"] as? [Int] { pending = raw }
        else if let raw = json["pendingIndices"] as? [NSNumber] { pending = raw.map { $0.intValue } }
        var failed: [Int] = []
        if let raw = json["failedIndices"] as? [Int] { failed = raw }
        else if let raw = json["failedIndices"] as? [NSNumber] { failed = raw.map { $0.intValue } }
        return SeriesTaskSnapshot(
            taskId: (json["taskId"] as? String) ?? "",
            requestId: (json["requestId"] as? String) ?? "",
            status: (json["status"] as? String) ?? "",
            requested: (json["requested"] as? Int) ?? items.count,
            items: items.sorted { $0.index < $1.index },
            pendingIndices: pending,
            failedIndices: failed,
            pricedCny: (json["pricedCny"] as? Double) ?? 0,
            committedCny: (json["committedCny"] as? Double) ?? 0,
            pendingCostCount: (json["pendingCostCount"] as? Int) ?? 0,
            partial: (json["partial"] as? Bool) ?? false,
            size: (json["size"] as? String) ?? "",
            qualityTier: (json["quality_tier"] as? String) ?? ""
        )
    }

    private func taskRequest(path: String, body: [String: Any], timeout: Double) throws -> URLRequest {
        guard let url = seriesEndpoint(path) else { throw ImageError.badResponse(400, "服务地址无效") }
        guard let token = HostedAccount.currentToken, !token.isEmpty else { throw ImageError.missingKey }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 创建任务（幂等：同一 requestId 重复调用返回同一任务）
    func startSeries(prompt: String,
                     requestId: String,
                     requestedCount: Int,
                     qualityTier: String? = nil,
                     aspectRatio: String? = nil,
                     renderIntent: String? = nil,
                     structured: [String: Any]? = nil,
                     size: String? = nil) async throws -> SeriesTaskSnapshot {
        var body: [String: Any] = [
            "requestId": requestId,
            "prompt": prompt,
            "requested_count": max(2, min(4, requestedCount)),
        ]
        if let qualityTier, !qualityTier.isEmpty { body["quality_tier"] = qualityTier }
        if let aspectRatio, !aspectRatio.isEmpty { body["aspect_ratio"] = aspectRatio }
        if let renderIntent, !renderIntent.isEmpty { body["render_intent"] = renderIntent }
        if let structured, !structured.isEmpty { body["structured"] = structured }
        if let size, !size.isEmpty { body["size"] = size }

        let request = try taskRequest(path: "/series/start", body: body, timeout: 60)
        let (data, response) = try await BoundedHTTPClient.data(for: request,
                                                                session: BoundedHTTPClient.chatSession,
                                                                limit: 2 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 {
            let err = error(from: data, response: response)
            if err.isSessionFailure {
                await HostedAccount.shared.handleSessionFailure(err.errorDescription ?? "")
            }
            throw err
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }
        // 已成功的项（断点续跑）需要下载，否则用户看不到已有图片
        let existing = Set(((json["items"] as? [[String: Any]]) ?? [])
            .filter { ($0["ok"] as? Bool) == true }
            .compactMap { ($0["index"] as? Int) })
        return await parseTaskSnapshot(json, downloadIndices: existing)
    }

    /// 执行一张。服务端保证：已成功的不重跑、已取消的拒绝执行。
    func stepSeries(taskId: String, index: Int) async throws -> SeriesTaskSnapshot {
        let request = try taskRequest(path: "/series/step",
                                      body: ["taskId": taskId, "index": index],
                                      timeout: min(300, HostedAccount.cachedImageTimeout + 30))
        let (data, response) = try await BoundedHTTPClient.data(for: request,
                                                                session: BoundedHTTPClient.imageSession,
                                                                limit: 48 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 {
            let err = error(from: data, response: response)
            if err.isSessionFailure {
                await HostedAccount.shared.handleSessionFailure(err.errorDescription ?? "")
            }
            throw err
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }
        return await parseTaskSnapshot(json, downloadIndices: [index])
    }

    /// 查询任务状态（重开 App 后续跑/取消都靠它）
    func seriesStatus(taskId: String) async throws -> SeriesTaskSnapshot {
        guard let url = seriesEndpoint("/series/status?taskId=" + (taskId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskId)),
              let token = HostedAccount.currentToken, !token.isEmpty else {
            throw ImageError.missingKey
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await BoundedHTTPClient.data(for: request,
                                                                session: BoundedHTTPClient.chatSession,
                                                                limit: 2 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 {
            throw error(from: data, response: response)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }
        let existing = Set(((json["items"] as? [[String: Any]]) ?? [])
            .filter { ($0["ok"] as? Bool) == true }
            .compactMap { ($0["index"] as? Int) })
        return await parseTaskSnapshot(json, downloadIndices: existing)
    }

    /// 取消：不再启动新的张数；已成功的保留
    func cancelSeries(taskId: String) async throws -> SeriesTaskSnapshot {
        let request = try taskRequest(path: "/series/cancel", body: ["taskId": taskId], timeout: 30)
        let (data, response) = try await BoundedHTTPClient.data(for: request,
                                                                session: BoundedHTTPClient.chatSession,
                                                                limit: 2 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 { throw error(from: data, response: response) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageError.noImage
        }
        return await parseTaskSnapshot(json, downloadIndices: [])
    }

    /// 批量执行未完成的张数（默认并发 2，单张失败不拖垮整批）
    func runSteps(taskId: String, indices: [Int], maxConcurrent: Int = 2) async throws -> [SeriesItemResult] {
        var remaining = indices
        var out: [SeriesItemResult] = []
        let width = max(1, min(2, maxConcurrent))
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let batch = Array(remaining.prefix(width))
            remaining.removeFirst(min(width, remaining.count))
            try await withThrowingTaskGroup(of: SeriesItemResult.self) { group in
                for idx in batch {
                    group.addTask { [weak self] in
                        guard let self else {
                            return SeriesItemResult(index: idx, ok: false, imageData: nil, remoteURL: "",
                                                    model: "", cost: 0, message: "任务已取消。",
                                                    errorCategory: "cancelled", downloadFailed: false, reused: false)
                        }
                        let snap = try await self.stepSeries(taskId: taskId, index: idx)
                        return snap.items.first(where: { $0.index == idx })
                            ?? SeriesItemResult(index: idx, ok: false, imageData: nil, remoteURL: "",
                                                model: "", cost: 0, message: "这一张没有返回结果。",
                                                errorCategory: "empty", downloadFailed: false, reused: false)
                    }
                }
                for try await r in group { out.append(r) }
            }
        }
        return out.sorted { $0.index < $1.index }
    }

    /// 只重试失败的子图（服务端保证已成功的不会重跑、也不重复扣费）
    func retryFailedSeries(parentRequestId: String, indices: [Int]) async throws -> SeriesOutcome {
        guard let url = URL(string: AppConfig.hostedAPIBase.replacingOccurrences(of: "/api", with: "/img") + "/series/retry") else {
            throw ImageError.badResponse(400, "服务地址无效")
        }
        guard let token = HostedAccount.currentToken, !token.isEmpty else { throw ImageError.missingKey }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(parentRequestId, forHTTPHeaderField: "X-Request-Id")
        request.timeoutInterval = min(600, HostedAccount.cachedImageTimeout * Double(max(1, indices.count)) + 30)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "requestId": parentRequestId,
            "indices": indices,
        ])
        let (data, response) = try await BoundedHTTPClient.data(for: request,
                                                                session: BoundedHTTPClient.imageSession,
                                                                limit: 48 * 1024 * 1024)
        try await validateSession(for: request)
        if response.statusCode != 200 {
            let err = error(from: data, response: response)
            if err.isSessionFailure {
                await HostedAccount.shared.handleSessionFailure(err.errorDescription ?? "")
            }
            throw err
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = json["items"] as? [[String: Any]] else {
            throw ImageError.noImage
        }
        var items: [SeriesItemResult] = []
        for (offset, raw) in rawItems.enumerated() {
            let index = (raw["index"] as? Int) ?? (offset + 1)
            let ok = (raw["ok"] as? Bool) ?? false
            let remote = (raw["url"] as? String) ?? ""
            var imageData: Data?
            var downloadFailed = false
            if ok, !remote.isEmpty {
                do { imageData = try await Self.downloadImage(remote) }
                catch { downloadFailed = true }
            }
            items.append(SeriesItemResult(
                index: index, ok: ok, imageData: imageData, remoteURL: remote,
                model: (raw["model"] as? String) ?? "",
                cost: (raw["cost"] as? Double) ?? Double((raw["cost"] as? NSNumber)?.doubleValue ?? 0),
                message: ok ? "" : ((raw["message"] as? String) ?? "这一张仍然没有生成成功。"),
                errorCategory: (raw["errorCategory"] as? String) ?? "",
                downloadFailed: downloadFailed,
                reused: (raw["reused"] as? Bool) ?? false
            ))
        }
        return SeriesOutcome(
            requestId: (json["requestId"] as? String) ?? parentRequestId,
            requested: (json["requested"] as? Int) ?? items.count,
            items: items.sorted { $0.index < $1.index },
            pricedCny: (json["pricedCny"] as? Double) ?? 0,
            committedCny: (json["committedCny"] as? Double) ?? 0,
            pendingCostCount: (json["pendingCostCount"] as? Int) ?? 0,
            partial: (json["partial"] as? Bool) ?? false,
            cached: (json["cached"] as? Bool) ?? false,
            size: (json["size"] as? String) ?? "",
            qualityTier: (json["quality_tier"] as? String) ?? ""
        )
    }
}
