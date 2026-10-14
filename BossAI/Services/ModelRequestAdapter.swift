import Foundation

// ============================================================================
// 文件职责：按服务商注入各家专有的请求参数（wire format 适配层）。
// 在 App 中的角色：任务/证据/UI 全部使用统一的模型契约，只有这里知道
//   某家厂商的私有字段（thinking 开关、temperature、max_tokens 等）怎么填。
// 关键设计决策：新增服务商时只改本文件的 switch，其余调用链零改动；
//   云端 hosted 模式由服务端透传 thinking 给上游，客户端只在极速档显式关闭。
// ============================================================================

/// Provider-specific wire parameters stay here; tasks, evidence and UI use a common model contract.
enum ModelRequestAdapter {
    /// 请求用途：chat=主对话（成本上限高），memory=记忆抽取（用轻量模型、限 max_tokens）
    enum Purpose: Equatable { case chat, memory }
    /// 思考档位：default=跟随默认（深度）；fast=关闭深度思考（极速档，服务端透传给上游）
    enum ThinkingMode { case `default`, fast }

    /// 把当前 profile 的专有参数合并进请求体 body（就地修改）。
    /// 默认重载：跟随默认思考档位（深度），供既有调用方零改动过渡。
    static func apply(to body: inout [String: Any], profile: ChatProfile, purpose: Purpose) {
        apply(to: &body, profile: profile, purpose: purpose, thinking: .default)
    }

    /// 完整版本：可指定思考档位。
    /// body：OpenAI 兼容请求体（就地修改）；profile：目标服务商档案；
    /// purpose：用途（决定温度与 max_tokens）；thinking：思考档位。
    static func apply(to body: inout [String: Any], profile: ChatProfile, purpose: Purpose,
                      thinking: ThinkingMode) {
        switch profile.id {
        case "deepseek":
            // Explicit fast mode avoids an implicit provider default changing tool-loop behavior.
            // DeepSeek 无条件关闭思考：其思考模型会改变工具循环行为，这里显式 disabled 锁定表现。
            body["thinking"] = ["type": "disabled"]
            body["temperature"] = purpose == .memory ? 0.1 : 0.2
            body["max_tokens"] = purpose == .memory ? 2048 : 8192
        case "hosted":
            // 云端会员模式：服务端透传 thinking 给上游（V4.1-Flash 支持 enabled/disabled）；
            // 只在极速档显式关闭，默认档交给服务端；记忆用途压缩 max_tokens 控成本
            if thinking == .fast { body["thinking"] = ["type": "disabled"] }
            if purpose == .memory { body["max_tokens"] = 512 }
        default: break // OpenAI-compatible provider defaults; no DeepSeek fields sent elsewhere.
        }
    }
}
