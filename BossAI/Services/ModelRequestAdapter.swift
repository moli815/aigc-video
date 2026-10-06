import Foundation

/// Provider-specific wire parameters stay here; tasks, evidence and UI use a common model contract.
enum ModelRequestAdapter {
    enum Purpose: Equatable { case chat, memory }
    static func apply(to body: inout [String: Any], profile: ChatProfile, purpose: Purpose) {
        switch profile.id {
        case "deepseek":
            // Explicit fast mode avoids an implicit provider default changing tool-loop behavior.
            body["thinking"] = ["type": "disabled"]
            body["temperature"] = purpose == .memory ? 0.1 : 0.2
            body["max_tokens"] = purpose == .memory ? 2048 : 8192
        default: break // OpenAI-compatible provider defaults; no DeepSeek fields sent elsewhere.
        }
    }
}
