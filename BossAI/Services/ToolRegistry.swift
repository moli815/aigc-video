import Foundation

// ============================================================================
// ToolRegistry —— 能力插件注册表（Hermes「一切皆插件」架构核心 · 阶段一）
//
// 设计目标：一个"能力"的所有信息只允许存在一份声明，其余全部从它派生：
//   · tools[]          → schema 交给 ChatService 组装（声明驱动，不再散落）
//   · 系统提示能力清单  → abilities/limits 自动生成（根治"模型不知道工具能做什么"的能力幻觉）
//   · 失败回注          → failureAdvice 由 ToolPipeline 统一生成（根治防谎报漏写）
//   · 产出落库          → producesArtifact 标记产出物（根治漏 save）
//
// 维护规则（重要）：新增/修改能力时只改本文件——改一处，全局一致。
// ============================================================================

/// 能力插件声明：一个工具/能力的单一真相来源
struct CapabilityPlugin {
    /// 执行位置（为阶段三云端下发预留：server 执行的能力无需 App 出包）
    enum Executor: String { case local, server }
    /// 所属端（能力清单展示用）
    enum Surface: String { case app, cloud }

    let id: String
    let displayName: String
    let executor: Executor
    /// 能力清单：模型据此判断"能做什么"
    let abilities: [String]
    /// 能力边界：模型据此避免幻觉（如"文档不能插图"）
    let limits: [String]
    /// 瞬时失败（网络/5xx）是否自动重试
    let retryOnTransient: Bool
    /// 是否产出需要落库展示的产物（图片/文档/图表）——由管道统一 save
    let producesArtifact: Bool
    /// 失败时给用户的建议（防谎报文案的一部分）
    let failureAdvice: String
}

enum ToolRegistry {

    /// 全部能力插件（单一真相来源——维护只改这里）
    static let plugins: [CapabilityPlugin] = [
        CapabilityPlugin(
            id: "web_search", displayName: "联网搜索", executor: .local,
            abilities: ["实时资讯/价格/政策/行情检索", "带来源标注与发布日期的证据收集"],
            limits: ["搜索无结果时必须明确标注「未核实」，禁止用记忆中的数字填空"],
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "明确告知本轮未能联网核实，缺失字段标注未核实"
        ),
        CapabilityPlugin(
            id: "generate_image", displayName: "图片生成", executor: .local,
            abilities: [
                "文生图（海报、插画、封面等）",
                "编辑 AI 已生成的图片（edit_last_image）",
                "编辑用户上传的图片（use_attached_image=true）",
                "用户上传多图参考时的融合编辑",
            ],
            limits: [
                "默认只产出常规比例（1:1 / 4:3 / 3:4 / 16:9 / 9:16），用户明确指定其他比例时按预算精确输出",
                "画面中极小文字可能出错，长文/小字建议用文档承载",
            ],
            retryOnTransient: true, producesArtifact: true,
            failureAdvice: "建议点击重试或稍后再试（这类接口异常通常是临时的）"
        ),
        CapabilityPlugin(
            id: "create_document", displayName: "文档导出", executor: .local,
            abilities: ["生成 Word / PPT / Excel / PDF 纯文字文档并存入资料库"],
            limits: [
                "【重要】只能生成纯文字文档，不能插入图片或 Logo——用户要求插图时必须明确告知做不到、需用户手动插入，禁止声称「已插入」",
            ],
            retryOnTransient: false, producesArtifact: true,
            failureAdvice: "可稍后重试，或先用文字形式输出内容"
        ),
        CapabilityPlugin(
            id: "render_chart", displayName: "统计图渲染", executor: .local,
            abilities: ["把已核实的数值渲染成柱状图 / 折线图 / 环形图"],
            limits: [
                "数据必须精确（来自本轮已核实来源或用户直接提供），禁止估计值",
                "最多 8 个数据点；示意性/装饰性图像改用图片生成",
            ],
            retryOnTransient: false, producesArtifact: true,
            failureAdvice: "可改用 Markdown 表格呈现数据"
        ),
        CapabilityPlugin(
            id: "search_library", displayName: "资料库检索", executor: .local,
            abilities: ["检索用户资料库中已上传的文档与资料"],
            limits: ["只能检索用户已上传的内容，资料库里没有的不能当作有"],
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "明确告知检索失败、未找到相关资料"
        ),
        CapabilityPlugin(
            id: "expert_skill", displayName: "专家技能", executor: .local,
            abilities: ["执行当前专家配置的专业方法论与交付模板"],
            limits: ["仅限当前已配置的专家技能"],
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "明确告知该操作未能完成"
        ),
    ]

    static func plugin(_ id: String) -> CapabilityPlugin? {
        plugins.first { $0.id == id }
    }

    /// ① 能力清单文本：注入系统提示——让模型清楚"能做什么 / 不能做什么"
    /// （根治能力幻觉：今天的"文档谎报已插入Logo""生图以为能编辑上传图"都不会再发生）
    /// - cloudExtra：云端补充说明（管理台可改）
    /// - overrides：云端按 id 覆盖（enabled=false 关闭某能力 / limits 追加边界）——能力声明云端化
    static func capabilityManifest(cloudExtra: String? = nil, overrides: [String: Any]? = nil) -> String {
        var lines: [String] = ["【当前对话的真实能力清单·最高优先级·必须严格遵守】"]
        for p in plugins {
            var limits = p.limits
            if let ov = overrides?[p.id] as? [String: Any] {
                if let enabled = ov["enabled"] as? Bool, enabled == false { continue }   // 云端关闭该能力
                if let extraLimits = ov["limits"] as? [String] { limits.append(contentsOf: extraLimits) }
            }
            lines.append("- \(p.displayName)（\(p.id)）：可做「\(p.abilities.joined(separator: "、"))」；边界：\(limits.joined(separator: "；"))")
        }
        lines.append("清单之外的能力不存在，禁止声称拥有；清单内标注的边界禁止越过（如文档工具不能插图）。")
        if let extra = cloudExtra, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("【云端补充能力说明】")
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }
}
