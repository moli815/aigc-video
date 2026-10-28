import Foundation

//
//  FriendlyError.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：统一友好错误文案转换器。把任意底层 Error（网络/解码/HTTP 状态码/
//  自定义错误）映射成一句可直接展示给用户的中文文案。
//
//  在整个 App 中的角色：全 App 错误展示的唯一出口（P0-13 规范）。UI 层一律通过
//  FriendlyError.message(for:) 取文案，保证各场景风格一致。
//
//  关键设计决策：
//  - 文案只回答"发生了什么 + 该怎么办"，不透出技术细节。
//  - 分层匹配：先 URLError 按错误码细分 → 再 DecodingError → 再按错误描述里的
//    HTTP 状态码关键词（401/403/413/429/50+UPSTREAM）→ 最后按场景兜底。
//  - 服务端是文案权威：带 { error, message } 的响应直接用服务端文案。
//
//  防呆/安全冗余理由：
//  - 状态码匹配只能命中错误描述文本中的数字，不会把原始报文透出给用户。
//  - 一切未知错误都有场景兜底文案，永不出现空白或英文技术报错。
//
/// P0-13 统一友好错误规范
/// ------------------------------------------------------------
/// 规则（全 App 一致）：
/// 1. 面向用户的文案只回答两件事：**发生了什么** + **该怎么办**；
/// 2. 绝不透出系统级错误码、技术栈、上游标识（HTTP 状态码/URLError 原文/JSON 解析错误等）；
/// 3. 服务端已返回带 { error, message } 的友好文案时直接使用（服务端是文案权威）；
/// 4. 一切未知错误统一兜底文案，并提示联系客服的路径。
enum FriendlyError {

    /// 错误发生的业务场景，决定兜底文案的措辞
    enum Scene {
        case chat        // 对话请求
        case image       // 生图
        case upload      // 附件上传/导入
        case login       // 登录/鉴权
        case generic     // 其他操作
    }

    /// 把任意 Error 转成一句可以直接展示给客户的中文文案。
    /// 匹配顺序：URLError 错误码 → DecodingError → 错误描述中的 HTTP 状态码
    /// → 按场景兜底；绝不透出技术细节
    /// 10-24：把服务端下发的受控动作转成可直接渲染的按钮。
    ///
    /// 设计要点：
    /// - 客户端只认识白名单里的动作，**未知 id 静默忽略** —— 服务端新增动作不能让旧 App 崩或出现空按钮；
    /// - 顺序沿用服务端给的顺序，服务端可以决定"再试一次"排在"修改描述"前面；
    /// - 文案由客户端维护（而不是服务端下发中文），避免同一动作在不同版本里措辞漂移。
    static func actions(from json: [String: Any]?) -> [(id: String, title: String)] {
        guard let raw = json?["actions"] as? [String] else { return [] }
        return actions(from: raw)
    }

    /// 10-24：直接吃信封里的 action ID 列表（APIErrorEnvelope.actions）。
    /// 白名单之外一律丢弃 —— 服务端新增动作不能让旧 App 崩或出现空按钮。
    static func actions(from raw: [String]) -> [(id: String, title: String)] {
        guard !raw.isEmpty else { return [] }
        let titles: [String: String] = [
            "retry": "再试一次",
            "edit_request": "修改描述",
            "cancel": "取消",
            "relogin": "重新登录",
            "renew": "去续费",
            "view_quota": "查看额度",
            "contact_support": "联系客服",
            "feedback": "反馈问题",
            "single_only": "先生成一张",
        ]
        var seen = Set<String>()
        var out: [(id: String, title: String)] = []
        for id in raw {
            guard let title = titles[id], !seen.contains(id) else { continue }
            seen.insert(id)
            out.append((id: id, title: title))
        }
        return out
    }

    /// 10-24：错误是否可由用户原样重试（服务端 errorDetail.retryable）。
    /// 旧服务端没有这个字段时返回 false —— 宁可少给一个按钮，也不要误导用户反复重试不可恢复的错误。
    static func isRetryable(_ json: [String: Any]?) -> Bool {
        guard let detail = json?["errorDetail"] as? [String: Any] else { return false }
        return (detail["retryable"] as? Bool) ?? false
    }

    /// 10-24：取服务端请求编号，供"反馈问题"时贴给客服。
    static func requestId(from json: [String: Any]?) -> String {
        (json?["requestId"] as? String) ?? ""
    }

    static func message(for error: Error, scene: Scene = .generic) -> String {
        // Structured business failures already carry server-filtered public copy.
        if let envelope = (error as? APIErrorCarrying)?.envelope {
            return envelope.message
        }
        // 第一层：网络类错误按 URLError 细分，给最贴切的行动建议
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "网络连接似乎断开了。请检查 Wi-Fi 或流量后重试。"
            case .timedOut:
                return "请求超时了，可能是网络较慢。请稍后重试。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "暂时连不上服务器。请稍后重试；若持续出现请联系客服。"
            case .cancelled:
                return "操作已取消。"
            default:
                return "网络好像不太稳定，请重试一次。"
            }
        }
        // 第二层：数据解码失败——统一话术，不暴露具体解析错误
        if error is DecodingError {
            return "数据读取异常，请重试；若持续出现请联系客服。"
        }
        // 第三层：从错误描述中识别 HTTP 状态码关键词做映射
        let text = String(describing: error)
        if text.contains("401") { return "登录状态已失效，请重新登录后再试。" }
        if text.contains("403") { return "当前账号暂时没有这项权限，请联系管理员。" }
        if text.contains("413") { return "内容太长了，请精简后再试一次。" }
        if text.contains("429") { return "操作太频繁了，请稍等一会儿再试。" }
        if text.contains("50") && text.contains("UPSTREAM") { return "服务暂时繁忙，请稍后重试。" }
        // 兜底：按场景给固定文案，永不出现空白报错
        switch scene {
        case .chat:   return "回答没有成功生成，请重试一次。"
        case .image:  return "图片没有生成成功，请调整描述后重试。"
        case .upload: return "这个文件没能读取成功，请换一个文件或重试。"
        case .login:  return "登录没有成功，请检查账号密码后重试。"
        case .generic: return "操作没有成功，请重试；若持续出现请联系客服。"
        }
    }

    /// 服务端返回体的统一解析：{ error, message }。
    /// - Parameter json: 服务端返回的 JSON 对象（可为 nil）
    /// - Returns: 有可展示的服务端中文文案时返回之；成功（ok）或无 message 返回 nil
    static func serverMessage(from json: [String: Any]?) -> String? {
        guard let json else { return nil }
        // 成功响应不算错误
        if let ok = json["ok"] as? Bool, ok { return nil }
        // 服务端 message 优先：服务端是文案权威
        if let msg = json["message"] as? String, !msg.isEmpty { return msg }
        return nil
    }

    /// 附件保存/读取失败（含文件名，便于用户自行核对）。
    /// - Parameters:
    ///   - name: 文件名（空白时用"该文件"占位）
    ///   - reason: 失败原因短语（不带句号）
    /// - Returns: 一句含文件名与建议的完整中文文案
    static func fileProblem(_ name: String, reason: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? "该文件" : "「\(trimmed)」"
        return "\(shown)\(reason)。请重新选择文件，或换用 PDF / Word / 文本类格式。"
    }
}
