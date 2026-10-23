import Foundation

// ============================================================================
// 运行时宣称校验（2026-10-24）
//
// 问题：模型偶尔在**没有发起工具调用**（或工具失败）时直接回复"图片已生成"。
// 此前所有"必须调用工具"的约束只写在提示词里（CHAT_RULES / capabilityPrompt /
// failureNote），运行时没有任何校验——模型可以无视。
//
// 这里补上最小可验证闭环：
//   图片意图（用户文本 或 本轮尝试过图片工具）
//   + 回复文本含成功表述
//   + 本轮没有任何产物落库
//   → 判定为"谎报"，由调用方自动修复一轮；仍失败则改写为如实文案。
//
// 只做图片/图表语境，避免误伤"已生成一段文案""已整理成表格"。
// ============================================================================

enum ToolClaimGuard {

    /// 用户是否在要图（换风格、改图、海报、名片等）。
    /// 注意：这里只做粗筛，真正的拦截还需要"回复宣称成功 + 无产物"同时成立。
    static func isImageRequest(_ text: String) -> Bool {
        let keywords = [
            "图", "海报", "名片", "封面", "配图", "插画", "主视觉", "图标", "logo", "Logo", "LOGO",
            "科技风", "风格", "重绘", "改图", "换背景", "去掉", "抠图", "P掉", "修图", "生成一张",
        ]
        return keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// 回复是否在宣称"已经产出图片/图表"。
    /// 用正则覆盖常见说法，避免把"已生成一段文字"也算进来（由调用方的意图判断兜底）。
    static func claimsArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 失败语境优先：'生成失败了' 里的 '生成…了' 不能当成成功宣称。
        // 只要出现失败/否定标记，就交给失败分支处理（宁可漏拦，不可误拦）。
        let failureMarkers = ["失败", "未能", "无法", "没有生成", "没生成", "未生成", "出错", "报错", "抱歉"]
        if failureMarkers.contains(where: { trimmed.contains($0) }) { return false }
        let patterns = [
            "(已|已经)[^。\\n]{0,8}(生成|重绘|改好|做好|完成|保存|放入|更新|替换)",
            "(生成|重绘|改好|做好|保存)[^。\\n]{0,3}(好|完成|了)",
            "(图片|图像|海报|名片|封面|图标|插画|图表)[^。\\n]{0,10}(已|已经)[^。\\n]{0,6}(生成|更新|保存|完成|替换)",
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }

    /// 是否需要拦截。
    /// - Parameters:
    ///   - artifactPersisted: 本轮是否有产物真正落库（artifactFlag）
    ///   - imageToolAttempted: 本轮是否尝试过图片/图表工具（即使失败）
    static func shouldIntercept(userText: String,
                                reply: String,
                                artifactPersisted: Bool,
                                imageToolAttempted: Bool) -> Bool {
        guard !artifactPersisted else { return false }
        guard imageToolAttempted || isImageRequest(userText) else { return false }
        return claimsArtifact(reply)
    }

    /// 自动修复轮注入的 system 指令。
    /// 写成"系统校验"而不是普通用户消息：避免被当成用户新的需求，也避免污染对话记录。
    static let repairInstruction = """
    【系统校验·必须执行】上一轮你声称已经生成了图片，但系统没有收到任何图片产物（没有成功调用 image_generate / image_edit，或调用失败）。
    现在必须真正调用工具完成：
    - 改已有图片 → image_edit，source 用 last（最近生成的图）或 attached（用户上传的图）
    - 从零做新图 → image_generate
    禁止再用文字声称已完成。若确实无法完成，必须明确说明失败原因，不得谎称成功。
    """

    /// 二次失败时替换给用户的文案（不再让模型的话术出现在界面上）。
    static let honestFailureText = "这次没有真正生成图片：模型声称已完成，但系统没有收到任何图片产物。请点「重新生成」，或把要求再发一次。"
}
