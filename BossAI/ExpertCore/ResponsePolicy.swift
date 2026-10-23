import Foundation

// ============================================================================
// 表达策略唯一合成器（2026-10-23 C 阶段）
//
// 历史问题：system prompt 里同时注入 ReplyStyle.prompt（设置页"回复风格"）与
// AnswerStyle.prompt（对话里的"清晰简答 / 详细分析"）。两者都能规定"多长、多细"，
// 用户选「简明扼要 + 详细分析」时模型收到互相矛盾的指令，只能猜。
//
// 现在明确分工，并在 prompt 里写死冲突仲裁规则：
//   · 语气（ReplyStyle）：只决定措辞、情感与专业度 → 不决定长度
//   · 详略（AnswerStyle）：只决定信息密度与结构   → 不决定语气
//   · 冲突时：以详略为准（用户当轮选择优先于长期偏好）
// ============================================================================

enum ResponsePolicy {
    /// 合成后的表达策略块。放在 stable system 块里：两项都是用户级长期设置，不随轮次变化，
    /// 因此不会破坏前缀缓存。
    static func prompt(reply: ReplyStyle, answer: AnswerStyle) -> String {
        var lines: [String] = []
        // auto 表示"不设定语气"，不给模型额外约束，避免与详略指令叠加
        if reply != .auto {
            lines.append("【表达策略·语气】" + reply.prompt)
        }
        lines.append("【表达策略·详略】" + answer.prompt)
        lines.append(
            "【冲突处理】语气只影响措辞与情感，不改变长度或结构；详略只影响信息密度与结构，不改变语气。" +
            "两者冲突时，以【表达策略·详略】为准。"
        )
        return "\n" + lines.joined(separator: "\n")
    }
}
