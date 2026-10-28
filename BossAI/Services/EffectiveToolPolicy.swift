//
//  EffectiveToolPolicy.swift
//  BossAI
//
//  当前对话真正可用的工具策略（单一事实源）。
//  10-23 审计修复：此前「配置声明、模型可见工具、执行时权限」使用三套不同规则，
//  导致模型看得见但执行器拒绝、云端开放但本地不挂、云端关闭但执行器仍放行等问题。
//  本结构统一计算一次，供以下四个位置共用：
//    1) ChatService.applyTools() —— 决定 tools[] 实际注册什么
//    2) ToolRegistry.capabilityManifest() —— 模型被告知可以做什么
//    3) ChatViewModel+Streaming —— 执行器入口再次校验（隐藏 ≠ 禁止执行）
//    4) 失败文案/诊断 —— 统一描述当前真实可用能力
//

import Foundation

/// 当前专家 / 当前账号 / 当前云端配置下的有效工具策略。
/// 所有工具相关决策必须由此派生，避免不同文件各自维护开关。
struct EffectiveToolPolicy: Equatable, Sendable {
    /// 是否允许联网搜索（App 自有 web_search / 厂商原生搜索）
    let canSearch: Bool
    /// 是否允许图片生成/编辑
    let canImage: Bool
    /// 可导出的文档格式（word/ppt/excel/pdf 的 rawValue 子集）
    let docFormats: [String]
    /// 被云端显式禁用的工具 ID。这些工具已从 tools[] 移除，但执行器仍需拒绝残留/伪造调用。
    let disabledToolIDs: Set<String>
    /// 经过「本地可用性 + 云端 overrides」过滤后真正可用的能力插件 ID
    let availableToolIDs: Set<String>

    /// 根据专家对象构造策略（执行器路径优先使用）。
    static func forExpert(_ expert: Expert, capabilityOverrides: [String: Any]? = nil) throws -> EffectiveToolPolicy {
        try forExpertID(expert.id, expertTools: expert.skill.tools, capabilityOverrides: capabilityOverrides)
    }

    /// 根据专家 ID 构造策略（注册 tools[] 路径优先使用，可指定云端工具列表）。
    static func forExpertID(_ expertID: String, expertTools: [ExpertTool]? = nil, capabilityOverrides: [String: Any]? = nil) throws -> EffectiveToolPolicy {
        // ① 云端专家工具列表为单一数据源；缺失时回退本地能力档案
        let perms = try ChatService.resolveToolPermissions(expertID: expertID, expertTools: expertTools)
        let overrides = capabilityOverrides ?? HostedAccount.cachedCapabilityOverrides ?? [:]

        // ② 云端 capabilityOverrides：enabled=false 表示显式关闭（隐藏工具且执行器拒绝）
        let disabledToolIDs: Set<String> = Set(overrides.compactMap { id, value -> String? in
            guard let dict = value as? [String: Any], let enabled = dict["enabled"] as? Bool, !enabled else { return nil }
            return id
        })

        // ③ 本地插件可用性预过滤（如 image_series / image_decompose 等本地标记为不可用）
        let availablePlugins = ToolRegistry.availablePlugins(overrides: overrides)
        let availableToolIDs = Set(availablePlugins.map(\.id))

        return EffectiveToolPolicy(
            canSearch: perms.canSearch,
            canImage: perms.canImage,
            docFormats: perms.docFormats,
            disabledToolIDs: disabledToolIDs,
            availableToolIDs: availableToolIDs
        )
    }

    /// 执行器入口：给定工具名是否允许真正执行。
    func permits(_ name: String) -> Bool {
        // 云端显式关闭：即使模型残留/伪造调用也拒绝
        if disabledToolIDs.contains(name) { return false }

        switch name {
        case "expert_skill":
            return availableToolIDs.contains("expert_skill")
        case "search_library":
            return availableToolIDs.contains("search_library")
        case "recall_history":
            return availableToolIDs.contains("recall_history")
        case "render_chart":
            return availableToolIDs.contains("render_chart")
        case "web_search", "$web_search":
            return canSearch && availableToolIDs.contains("web_search")
        case "image_generate", "image_edit", "image_decompose", "image_series", "generate_image":
            return canImage && availableToolIDs.contains(name)
        case "create_document":
            return !docFormats.isEmpty && availableToolIDs.contains("create_document")
        default:
            return false
        }
    }

    /// 给定工具名是否应出现在最终 tools[] / 能力清单中（即模型"看得见"）。
    /// 与 permits 不同：这里不要求 canSearch/canImage，只看插件本地可用性 + 云端开关。
    func isVisible(_ pluginID: String) -> Bool {
        availableToolIDs.contains(pluginID) && !disabledToolIDs.contains(pluginID)
    }
}
