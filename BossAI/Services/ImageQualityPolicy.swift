import Foundation

/// The Agent recommends a tier and a reason; this boundary protects fidelity-sensitive
/// requests. No second LLM call and no server-side re-interpretation of prose.
enum ImageQualityPolicy {
    struct Decision: Equatable { let tier: String; let reason: String }
    static let reasons = ["draft", "simple_visual", "simple_edit", "detailed_layout", "identity_sensitive", "brand_accuracy", "complex_edit", "final_delivery"]
    static func decide(userText: String, tool: String, referenceCount: Int,
                       modelTier: String?, modelReason: String?, structured: [String: Any]?) -> Decision {
        let text = userText.lowercased()
        func has(_ words:[String])->Bool { words.contains { text.contains($0) } }
        let requested = ImageTaskPlanner.normalizeQualityTier(modelTier)
        if has(["必须用pro", "用 pro", "使用pro", "最高质量", "高精度", "精修", "印刷", "一字不差", "逐字一致"]) {
            return Decision(tier:"high",reason:"explicit_quality")
        }
        if structured?["preserve_assets"] != nil || has(["logo", "商标", "徽标", "二维码", "标识不变"]) {
            return Decision(tier:"high",reason:"brand_accuracy")
        }
        if referenceCount > 0 && has(["保脸", "人脸", "本人", "人物", "人像", "换装", "换衣", "握手", "表情", "动作"]) {
            return Decision(tier:"high",reason:"identity_sensitive")
        }
        let items = structured?["text"] as? [[String:Any]] ?? []
        let charCount = items.reduce(0) { $0 + (($1["text"] as? String)?.count ?? 0) }
        if items.count >= 4 || charCount >= 60 || ["detailed_layout","identity_sensitive","brand_accuracy","complex_edit","final_delivery"].contains(modelReason ?? "") {
            return Decision(tier:"high",reason:modelReason ?? "detailed_layout")
        }
        if requested == "high" { return Decision(tier:"high",reason:"agent_quality") }
        let cheapIntent = ["draft","simple_visual","simple_edit"].contains(modelReason ?? "")
        if requested == "fast" && cheapIntent { return Decision(tier:"fast",reason:modelReason!) }
        if referenceCount == 0 && has(["草稿", "先看大概", "快速", "先出一版看看"]) {
            return Decision(tier:"fast",reason:"explicit_draft")
        }
        // An unexplained `fast`, missing classification, or a reference redesign
        // does not silently lower quality. The Agent can classify a safe draft.
        return Decision(tier:"high",reason:"conservative_default")
    }
}
