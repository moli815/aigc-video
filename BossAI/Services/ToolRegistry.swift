import Foundation

// ============================================================================
// ToolRegistry —— 能力插件注册表（对照 NousResearch/hermes-agent 真实源码修正版）
//
// 本文件按 Hermes Agent 的 tools/registry.py + toolsets.py 真实设计对齐（非想象）：
//   · ToolEntry 数据类           → CapabilityPlugin（补齐 toolset/availability/maxResultChars/executionTimeout）
//   · check_fn 可用性探测        → availability 闭包 + availablePlugins() 预过滤
//     （Hermes 用 check_fn + 30s TTL + 60s 失败宽限防抖；Swift 端按需探测即可）
//   · toolset 工具集分组         → toolset 字段（web/media/docs/knowledge/skill）
//   · 统一错误契约               → ToolPipeline（{"error":...} 结构化 + 防谎报指令）
//   · execution_timeout / max_result_size_chars → executionTimeout / maxResultChars
//   · 共享核心工具列表           → coreToolIDs（对照 _HERMES_CORE_TOOLS：一处编辑全局跟随）
//
// 核心不变量（对照源码的边界防护）：
//   1. 不可用的能力【不进 tools[]、不进能力清单】——模型看不到就不会误调用（Hermes check_fn 语义）
//   2. 能力信息只在本文件声明一次——schema/边界/失败策略/资源上限全部从这里派生
// 维护规则：新增/修改能力只改本文件。
// ============================================================================

/// 能力插件声明：一个工具/能力的单一真相来源（对照 Hermes ToolEntry）
struct CapabilityPlugin {
    /// 执行位置（server 执行的能力无需 App 出包即可升级）
    enum Executor: String { case local, server }

    let id: String
    /// 工具集分组（对照 Hermes toolset）：web / media / docs / knowledge / skill
    let toolset: String
    let displayName: String
    let executor: Executor
    /// 能力清单：模型据此判断"能做什么"
    let abilities: [String]
    /// 能力边界：模型据此避免幻觉（如"文档不能插图"）
    let limits: [String]
    /// 环境依赖（对照 Hermes requires_env）：云端需要的配置项名（用于诊断展示）
    let requiresEnv: [String]
    /// 可用性探测（对照 Hermes check_fn）：返回 false 时该能力从 tools[] 与清单中移除。
    /// nil = 恒可用。
    let availability: (() -> Bool)?
    /// 结果尺寸上限（对照 Hermes max_result_size_chars）：超出截断并注明
    let maxResultChars: Int
    /// 执行超时（对照 Hermes execution_timeout）
    let executionTimeout: TimeInterval
    /// 瞬时失败（网络/5xx）是否自动重试
    let retryOnTransient: Bool
    /// 是否产出需要落库展示的产物（图片/文档/图表）——由 ToolPipeline 统一 save
    let producesArtifact: Bool
    /// 失败时给用户的建议（防谎报文案的一部分）
    let failureAdvice: String

    init(id: String, toolset: String, displayName: String, executor: Executor,
         abilities: [String], limits: [String],
         requiresEnv: [String] = [], availability: (() -> Bool)? = nil,
         maxResultChars: Int = 12000, executionTimeout: TimeInterval = 120,
         retryOnTransient: Bool, producesArtifact: Bool, failureAdvice: String) {
        self.id = id
        self.toolset = toolset
        self.displayName = displayName
        self.executor = executor
        self.abilities = abilities
        self.limits = limits
        self.requiresEnv = requiresEnv
        self.availability = availability
        self.maxResultChars = maxResultChars
        self.executionTimeout = executionTimeout
        self.retryOnTransient = retryOnTransient
        self.producesArtifact = producesArtifact
        self.failureAdvice = failureAdvice
    }
}

enum ToolManifest {

    /// 共享核心能力（对照 Hermes `_HERMES_CORE_TOOLS`）：所有场景默认启用
    static let coreToolIDs: [String] = ["web_search", "render_chart"]

    /// 全部能力插件（单一真相来源——维护只改这里）
    static let plugins: [CapabilityPlugin] = [
        CapabilityPlugin(
            id: "web_search", toolset: "web", displayName: "联网搜索", executor: .local,
            abilities: ["实时资讯/价格/政策/行情检索", "带来源标注与发布日期的证据收集"],
            limits: ["搜索无结果时必须明确标注「未核实」，禁止用记忆中的数字填空"],
            availability: nil,                       // 恒可用
            maxResultChars: 16000, executionTimeout: 60,
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "明确告知本轮未能联网核实，缺失字段标注未核实"
        ),
        // ── 10-19 拆 4 工具（Harness 插件契约）：每个工具独立能力/边界/可用性/失败建议 ──
        CapabilityPlugin(
            id: "image_generate", toolset: "media", displayName: "文生图", executor: .local,
            abilities: [
                "纯文生图，以及基于用户上传参考图重新设计的新作品",
                "【使用时机】用户说「做图/设计/海报/名片/封面/配图/插画」→ 立即调用本工具；基于上传图创作时必须选择 source=attached 和正确 source_index",
            ],
            limits: ["仅局部修改、换背景、增删元素时使用 image_edit；不得丢弃用户明确指定的参考图"],
            requiresEnv: ["生图 API Key"],
            // 10-23 修复：此前用「额度剩余百分比」决定工具是否出现——
            // 额度显示为 0 时工具直接从 tools[] 消失，模型只能回答"配置禁用了图片生成"（用户看到的能力缺失）。
            // 额度不足应由服务端在执行时返回 429 POOL_EXHAUSTED 兜底，不该让"工具不存在"。
            availability: { true },
            maxResultChars: 4000, executionTimeout: 180,
            retryOnTransient: true, producesArtifact: true,
            failureAdvice: "建议点击重试或稍后再试（这类接口异常通常是临时的）"
        ),
        CapabilityPlugin(
            id: "image_edit", toolset: "media", displayName: "图片编辑", executor: .local,
            abilities: [
                "局部编辑最近生成的图（source=last）",
                "局部编辑用户上传的图（source=attached）",
                "双图融合：上传素材叠加到生成图（source=both）",
            ],
            limits: ["source 必填；找不到底图时明确报错，绝不退化成文生图"],
            requiresEnv: ["生图 API Key"],
            // 10-23 修复：此前用「额度剩余百分比」决定工具是否出现——
            // 额度显示为 0 时工具直接从 tools[] 消失，模型只能回答"配置禁用了图片生成"（用户看到的能力缺失）。
            // 额度不足应由服务端在执行时返回 429 POOL_EXHAUSTED 兜底，不该让"工具不存在"。
            availability: { true },
            maxResultChars: 4000, executionTimeout: 180,
            retryOnTransient: true, producesArtifact: true,
            failureAdvice: "请确认要编辑的图片是否存在，或改用 image_generate 生成新图"
        ),
        // 10-23 P1：image_decompose 当前执行链没有把源图片传进去，ImageService 返回契约也不支持
        // 多图层产物。在完整实现「source → 参考图 → 多图层结果 → 图层元数据 → 资料库落库」之前，
        // 按审计建议关闭该工具，避免模型调用后进入不可预期的执行分支。
        CapabilityPlugin(
            id: "image_decompose", toolset: "media", displayName: "图层拆分", executor: .local,
            abilities: ["【暂未开放】把一张图拆成「底图 + 最多 16 个透明 PNG 图层」"],
            limits: [
                "当前版本未开放：客户端还没有「源图选择 → 多图层解析 → 图层元数据展示」的完整链路，后端能力先不通",
                "模型不要调用本工具；用户问起时如实说明「图层拆分暂未开放」，不要编造已完成",
            ],
            requiresEnv: ["生图 API Key"],
            availability: { false },
            maxResultChars: 4000, executionTimeout: 180,
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "如实告知用户该能力暂未开放"
        ),
        CapabilityPlugin(
            id: "image_series", toolset: "media", displayName: "组图生成", executor: .local,
            abilities: ["一次生成 2~4 张内容关联的图片（分镜、一套物料、品牌视觉系列）"],
            // 10-24：改为服务端编排，不再依赖原生 sequential_image_generation（那是 Lite 专属能力）。
            // bf-image 会把 series 拆成 N 个独立单图子任务：各自 requestId、各自记账、可部分成功。
            // 因此 pro / flash 都能用，availability 不再需要为模型能力让步。
            limits: [
                "一次最多 4 张（服务端串行生成，总耗时约为单张的 N 倍）",
                "单张失败不影响其他张，会明确返回成功张数与失败序号",
                "风格一致性由提示词约束，弱于原生组图；每张构图会刻意做出差异",
                "失败的那几张可在 App 里点「重试失败的几张」单独补画，已成功的不会重新生成、也不会重复扣费",
                "【禁止】不要说「当前模型不支持组图」——该能力已开通",
            ],
            requiresEnv: ["生图 API Key"],
            availability: { true },
            maxResultChars: 4000, executionTimeout: 300,
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "如实告知用户已成功几张、哪几张失败，并给出「重试剩余」与「保留已完成」两个选项；不要重跑已成功的图"
        ),
        CapabilityPlugin(
            id: "generate_image", toolset: "media", displayName: "图片生成", executor: .local,
            abilities: [
                "文生图（海报、插画、封面等）",
                "编辑 AI 已生成的图片（edit_last_image）",
                "编辑用户上传的图片（use_attached_image=true）",
                "双图融合：把用户上传的 Logo/人物叠加到生成的图上（两者同时 true）",
                "【禁止否认】以上编辑能力全部已支持——禁止回答「我无法编辑用户上传的图片」或「只能编辑 AI 生成的图片」（错误的能力否认，用户实测踩坑）",
            ],
            limits: [
                "默认只产出常规比例（1:1 / 4:3 / 3:4 / 16:9 / 9:16），用户明确指定其他比例时按预算精确输出",
                "prompt 是唯一完整视觉指令；精确可见文字按标题/正文/联系方式等语义拆条放 structured.text，不能把整段扁平合成一个 body",
            ],
            requiresEnv: ["生图 API Key"],
            // 10-23 修复：旧 ID 的 availability 同样不能用「额度百分比」——
            // 系统提示的能力清单由 availablePlugins() 生成，额度判断为 false 时清单里就没有生图，
            // 模型会回答"当前专家配置禁用了图片生成"（用户看到的能力缺失）。
            // 额度不足交给服务端执行时 429 兜底。
            availability: { true },
            maxResultChars: 4000, executionTimeout: 180,
            retryOnTransient: true, producesArtifact: true,
            failureAdvice: "建议点击重试或稍后再试（这类接口异常通常是临时的）"
        ),
        CapabilityPlugin(
            id: "create_document", toolset: "docs", displayName: "文档导出", executor: .local,
            abilities: ["生成 Word / PPT / Excel / PDF 纯文字文档并存入资料库"],
            limits: [
                "【重要】只能生成纯文字文档，不能插入图片或 Logo——用户要求插图时必须明确告知做不到、需用户手动插入，禁止声称「已插入」",
            ],
            requiresEnv: ["云端文档导出权限"],
            // 对照 Hermes check_fn：云端档位开关决定可用性（关闭时该能力不进清单——模型不会宣称能做）
            availability: { HostedAccount.cachedExportDocEnabled },
            maxResultChars: 8000, executionTimeout: 90,
            retryOnTransient: false, producesArtifact: true,
            failureAdvice: "可稍后重试，或先用文字形式输出内容"
        ),
        CapabilityPlugin(
            id: "render_chart", toolset: "media", displayName: "统计图渲染", executor: .local,
            abilities: ["把已核实的数值渲染成柱状图 / 折线图 / 环形图"],
            limits: [
                "数据必须精确（来自本轮已核实来源或用户直接提供），禁止估计值",
                "最多 8 个数据点；示意性/装饰性图像改用图片生成",
            ],
            availability: nil,
            maxResultChars: 4000, executionTimeout: 15,
            retryOnTransient: false, producesArtifact: true,
            failureAdvice: "可改用 Markdown 表格呈现数据"
        ),
        CapabilityPlugin(
            id: "search_library", toolset: "knowledge", displayName: "资料库检索", executor: .local,
            abilities: ["检索用户资料库中已上传的文档与资料"],
            limits: ["只能检索用户已上传的内容，资料库里没有的不能当作有"],
            availability: nil,
            maxResultChars: 12000, executionTimeout: 30,
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "明确告知检索失败、未找到相关资料"
        ),
        CapabilityPlugin(
            id: "expert_skill", toolset: "skill", displayName: "专家技能", executor: .local,
            abilities: ["执行当前专家配置的专业方法论与交付模板"],
            limits: ["仅限当前已配置的专家技能"],
            availability: nil,
            maxResultChars: 12000, executionTimeout: 30,
            retryOnTransient: false, producesArtifact: false,
            failureAdvice: "明确告知该操作未能完成"
        ),
    ]

    static func plugin(_ id: String) -> CapabilityPlugin? {
        plugins.first { $0.id == id }
    }

    /// 可用性预过滤（对照 Hermes check_fn 语义）：不可用的能力直接从清单与 tools[] 中移除——
    /// 模型看不到就不会误调用，这是"调用顺畅且不易出错"的第一道防线。
    /// 10-22 修复：支持云端 overrides（enabled=false 关闭）。此前 availablePlugins() 不接收云端开关，
    /// 导致「系统提示说不可用、tools[] 里却还有」的不一致。现在唯一入口统一应用「本地可用性 + 云端开关」。
    static func availablePlugins(overrides: [String: Any]? = nil) -> [CapabilityPlugin] {
        plugins.filter { p in
            if let ov = overrides?[p.id] as? [String: Any], let enabled = ov["enabled"] as? Bool, enabled == false {
                return false
            }
            return p.availability?() ?? true
        }
    }

    /// ① 能力清单文本：注入系统提示——只包含【当前可用】的能力及其边界
    /// - cloudExtra：云端补充说明（管理台可改）
    /// - overrides：云端按 id 覆盖（enabled=false 关闭 / limits 追加边界）
    static func capabilityManifest(cloudExtra: String? = nil, overrides: [String: Any]? = nil) -> String {
        var lines: [String] = ["【当前对话的真实能力清单·最高优先级·必须严格遵守】"]
        for p in availablePlugins(overrides: overrides) {
            var limits = p.limits
            if let ov = overrides?[p.id] as? [String: Any] {
                if let enabled = ov["enabled"] as? Bool, enabled == false { continue }
                if let extraLimits = ov["limits"] as? [String] { limits.append(contentsOf: extraLimits) }
            }
            lines.append("- \(p.displayName)（\(p.id)）：可做「\(p.abilities.joined(separator: "、"))」；边界：\(limits.joined(separator: "；"))")
        }
        // 10-23 修复：此前这里写"当前不可用：图层拆分、组图生成"，模型会把这句话**泛化**成
        // "图片生成被禁用"，从而拒绝出图（用户实际看到的错误回答）。现在把范围钉死：
        // 只影响这两个细分场景，文生图/图片编辑明确标注为正常，禁止扩大解释。
        let unavailable = plugins.filter { p in !(p.availability?() ?? true) }
        if !unavailable.isEmpty {
            lines.append("- 仅以下**细分场景**暂未开放：" + unavailable.map { $0.displayName }.joined(separator: "、"))
            lines.append("- 除此之外，文生图（image_generate）、图片编辑（image_edit）、Word/PPT/Excel/PDF 导出**全部正常可用**。")
            lines.append("- 严禁把上面这两个细分场景说成「图片生成被禁用」或「当前专家不支持生图」——这是错误结论。")
        }
        lines.append("清单之外的能力不存在，禁止声称拥有；清单内标注的边界禁止越过（如文档工具不能插图）。")
        if let extra = cloudExtra, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("【云端补充能力说明】")
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }
}

// Old call sites share the same manifest, not a second registry.
typealias ToolRegistry = ToolManifest
