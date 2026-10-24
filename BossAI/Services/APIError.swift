import Foundation

// ============================================================================
// APIError.swift —— 服务端结构化错误信封（10-24 新增）
//
// 背景：服务端已经统一输出「自然语言 message + 受控 actions + requestId +
// errorDetail(category/retryable)」，但客户端此前只取 message 字符串，
// 于是 actions 永远到不了 UI，用户只能看到一句错误、没有任何可点的下一步。
//
// 设计原则：
//   1. **向后兼容**：旧服务端没有 actions/errorDetail/requestId 时，各字段取默认值，
//      行为与旧版完全一致（只显示 message）。
//   2. **动作是白名单**：这里只解析 ID，不执行；真正执行由 FriendlyError.actions 过滤后
//      交给 RecoverableErrorView 的处理器，未知动作静默丢弃。
//   3. **不解析即丢弃**：字段缺失不抛错、不崩，宁可少一个按钮，也不要一个假按钮。
// ============================================================================

/// 服务端错误信封（值类型，便于跨线程传递与相等比较）。
struct APIErrorEnvelope: Equatable {
    /// HTTP 状态码（0 表示本地错误，未经过网络）
    let status: Int
    /// 机器可读错误码，仅用于判断与日志，**绝不直接展示**
    let code: String
    /// 面向用户的自然语言说明
    let message: String
    /// 受控动作 ID（白名单见 FriendlyError.actions）
    let actions: [String]
    /// 请求编号：反馈问题 / 查日志时使用
    let requestId: String
    /// 用户能否原样重试
    let retryable: Bool
    /// 机器分类：input/auth/capability/upstream_*/storage/billing/internal
    let category: String
    /// 组图等批量任务的失败序号（1 基）
    let failedIndices: [Int]
    /// 是否为部分成功（例如组图 3/4）
    let partial: Bool

    init(status: Int,
         code: String,
         message: String,
         actions: [String] = [],
         requestId: String = "",
         retryable: Bool = false,
         category: String = "",
         failedIndices: [Int] = [],
         partial: Bool = false) {
        self.status = status
        self.code = code
        self.message = message
        self.actions = actions
        self.requestId = requestId
        self.retryable = retryable
        self.category = category
        self.failedIndices = failedIndices
        self.partial = partial
    }

    /// 会话失效（停用 / 改密 / 顶号 / 到期）——调用方据此强制登出。
    var isSessionFailure: Bool {
        if status == 401 { return true }
        return ["ACCOUNT_SUSPENDED", "MEMBERSHIP_EXPIRED", "UNAUTHORIZED", "SESSION_REPLACED"].contains(code)
    }

    /// 解析服务端 JSON。没有任何可展示信息时返回 nil（调用方回落到本地文案）。
    static func parse(status: Int, json: [String: Any]) -> APIErrorEnvelope? {
        let code = (json["error"] as? String) ?? ""
        let message = (json["message"] as? String) ?? (json["msg"] as? String) ?? ""
        guard !code.isEmpty || !message.isEmpty else { return nil }

        let detail = json["errorDetail"] as? [String: Any]
        let actions = (json["actions"] as? [String]) ?? []
        let requestId = (json["requestId"] as? String) ?? ""
        let retryable = (detail?["retryable"] as? Bool) ?? ((json["retryable"] as? Bool) ?? false)
        let category = (detail?["category"] as? String) ?? ""

        // JSON 数字可能是 Int 也可能是 NSNumber，两种都兼容
        var failed: [Int] = []
        if let arr = json["failedIndices"] as? [Int] {
            failed = arr
        } else if let arr = json["failedIndices"] as? [NSNumber] {
            failed = arr.map { $0.intValue }
        }

        return APIErrorEnvelope(
            status: status,
            code: code,
            message: message.isEmpty ? "这次没有完成，可以稍后再试。" : message,
            actions: actions,
            requestId: requestId,
            retryable: retryable,
            category: category,
            failedIndices: failed,
            partial: (json["partial"] as? Bool) ?? false
        )
    }
}

/// 统一的信封提取入口：任何 Error 只要携带信封就能被 UI 消费。
protocol APIErrorCarrying {
    var envelope: APIErrorEnvelope? { get }
}
