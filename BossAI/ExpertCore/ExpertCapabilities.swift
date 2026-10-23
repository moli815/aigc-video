import Foundation

// ExpertCapabilities.swift —— 专家技能契约层（配置驱动的专家系统）。
// 职责：定义专家能力档案（ExpertCapability）、从 ExpertSkills.json 加载并校验目录、
//       提供技能运行时（plan / calculate / validate 三个操作）。
// 在整个 App 中的角色：专家模式的"宪法"——模型能做什么、不能做什么都由此裁决。
// 关键设计决策与防呆冗余：
// 1) 配置驱动而非硬编码：专家定义在 JSON 资源里，改专家不改代码；加载一次性完成，
//    结果固化在常量 Result 中，后续读取零开销且天然线程安全。
// 2) 加载期强校验：ID 非空且唯一、计算器必须真实存在、文件格式必须属于白名单，
//    坏配置直接失败（fail-fast），不让半残专家流入运行时。
// 3) 工具许可白名单（permits）：专家只能使用档案允许的工具，默认拒绝未知工具。
// 4) validate 只做结构校验（Markdown 标题 + 字数下限），并在警告中明确
//    "不证明事实与法律效力正确"——能力边界必须写进输出。

/// 知识卡：给模型注入的领域要点（标题 + 规则列表）。
struct ExpertKnowledgeCard: Codable, Hashable {
    let title: String
    let rules: [String]
}

/// Versioned, local skill contracts. This configuration is not a trained model or legal authority.
struct ExpertCapability: Codable, Hashable {
    let id: String
    let name: String
    let requiredInputs: [String]
    let workflow: [String]
    let documentSections: [String]
    let documentFormats: [String]
    let calculators: [String]
    let allowSearch: Bool
    let allowImages: Bool
    let knowledge: [ExpertKnowledgeCard]
    let boundaries: [String]

    /// 把契约渲染成注入 system prompt 的指令文本（约束输入缺失、来源标注、边界声明）。
    var instruction: String {
        """
        【可执行技能契约 v1：\(name)】
        必要输入：\(requiredInputs.joined(separator: "；"))。缺失项列为待补充；先提供分析框架，不编造输入。
        执行步骤：\(workflow.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        可用本地计算器：\(calculators.joined(separator: ", "))。
        先调用 expert_skill(operation: plan) 获取本专家当前契约。数字计算调用 calculate，展示输入、单位、公式及假设；不把估计当事实。
        交付章节：\(documentSections.joined(separator: "；"))。
        知识卡：\(knowledge.map { $0.title + "：" + $0.rules.joined(separator: "；") }.joined(separator: "\n"))
        边界：\(boundaries.joined(separator: "；"))。
        实时外部事实使用搜索证据；用户提供数据明确标“用户提供”；工具计算标“计算结果”；假设标“假设”。
        交付前可调用 expert_skill(operation: validate) 检查结构；此检查不证明事实、专业结论或法律效力正确。
        """
    }
}

/// 技能层错误分类：配置错误 / 输入错误 / 权限拒绝，供工具调用结果回传模型。
enum ExpertSkillError: LocalizedError {
    case configuration(String), invalidInput(String), denied(String)
    var errorDescription: String? {
        switch self {
        case .configuration(let message): return "技能配置错误：\(message)"
        case .invalidInput(let message): return "技能输入错误：\(message)"
        case .denied(let message): return "当前专家不允许：\(message)"
        }
    }
}

/// 专家目录：从 ExpertSkills.json 一次性加载、校验并索引。
enum ExpertCapabilityCatalog {
    private struct Configuration: Decodable { let version: Int; let profiles: [ExpertCapability] }
    static let configuration: Result<[String: ExpertCapability], Error> = Result {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "ExpertSkills", withExtension: "json") else {
            throw ExpertSkillError.configuration("未找到 ExpertSkills.json")
        }
        return try decode(Data(contentsOf: url))
    }

    /// 解码并校验配置：版本号必须为 1；ID 唯一；计算器与文件格式都必须是已知集合的子集。
    static func decode(_ data: Data) throws -> [String: ExpertCapability] {
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard config.version == 1 else { throw ExpertSkillError.configuration("不支持的版本") }
        var profiles: [String: ExpertCapability] = [:]
        for profile in config.profiles {
            guard !profile.id.isEmpty, profiles[profile.id] == nil else {
                throw ExpertSkillError.configuration("专家 ID 为空或重复")
            }
            guard Set(profile.calculators).isSubset(of: Set(BusinessCalculators.names)),
                  Set(profile.documentFormats).isSubset(of: Set(["word", "ppt", "excel", "pdf"])) else {
                throw ExpertSkillError.configuration("未知计算器或文件格式：\(profile.id)")
            }
            profiles[profile.id] = profile
        }
        return profiles
    }

    static func profile(_ id: String) throws -> ExpertCapability {
        guard let value = try configuration.get()[id] else {
            throw ExpertSkillError.configuration("未知专家：\(id)")
        }
        return value
    }
}

/// 文档结构校验结果：是否通过、缺失章节与警告。
struct SkillValidation: Codable {
    let structurePassed: Bool
    let missingSections: [String]
    let warnings: [String]
}

/// 技能运行时：工具许可裁决与 expert_skill 工具的实际执行。
enum ExpertSkillRuntime {
    /// 工具许可白名单：基础技能人人可用；搜索/作图/出文档看**有效工具列表**，默认拒绝。
    ///
    /// 10-23 关键修复（用户实测"模型调 image_generate 被拒"的根因）：
    /// ① 此前只认旧名 `generate_image`，拆分后的 `image_generate` / `image_edit` /
    ///    `image_decompose` / `image_series` 全部落到 `default: return false`，
    ///    模型一调用就被拒，回给模型的文案是「当前专家禁止该工具」——再被转述成"权限限制"。
    /// ② 权限来源与 `ChatService.resolveToolPermissions` 不一致：那边云端 `expertTools` 优先，
    ///    这里却只用本地档案，于是"云端开了生图、本地档案没开"时运行时仍拒绝。
    /// 现在两处统一：`expertTools`（云端下发）优先，本地 `profile` 只做兜底。
    /// - disabledTools：云端显式关闭的工具 ID 集合。**隐藏 ≠ 禁止执行**——
    ///   工具从 tools[] 移除只是让模型看不见；若模型残留/伪造调用，执行器必须在这里拒绝。
    static func permits(_ name: String, profile: ExpertCapability,
                        allowedTools: [String]? = nil,
                        disabledTools: Set<String> = []) -> Bool {
        if disabledTools.contains(name) { return false }

        // 注意：本文件属于 BossAIExpertCore（SPM target），看不到 App 层的 ExpertTool 枚举，
        // 因此这里用工具名字符串（与 ChatService 传给 tools[] 的 name 同源）。
        let canSearch = allowedTools.map { $0.contains("search") } ?? profile.allowSearch
        let canImage = allowedTools.map { $0.contains("image") } ?? profile.allowImages

        switch name {
        case "expert_skill", "search_library", "render_chart":
            return true
        case "web_search", "$web_search":
            return canSearch
        case "image_generate", "image_edit", "image_decompose", "image_series", "generate_image":
            return canImage
        case "create_document":
            if let at = allowedTools {
                return !at.filter { ["word", "ppt", "excel", "pdf"].contains($0) }.isEmpty
            }
            return !profile.documentFormats.isEmpty
        default:
            return false
        }
    }

    /// 校验交付文档结构：格式必须在专家档案允许范围内；只看 Markdown 标题行，
    /// 不做正文关键词匹配（结构检查，不判断内容对错）；正文至少 40 字符。
    static func validateDocument(_ content: String, format: String, profile: ExpertCapability) throws -> SkillValidation {
        guard profile.documentFormats.contains(format) else { throw ExpertSkillError.denied("文件格式 \(format)") }
        // Inspect headings, not arbitrary matching words in body text. Structural check only.
        let headings = content.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            return trimmed.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
        }
        let missing = profile.documentSections.filter { required in !headings.contains(where: { $0.contains(required) }) }
        let sufficient = content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40
        return SkillValidation(structurePassed: missing.isEmpty && sufficient,
                               missingSections: missing,
                               warnings: ["仅验证交付结构，事实与引用需核实"] + (sufficient ? [] : ["正文不足40字符"]))
    }

    /// expert_skill 工具入口：plan 返回契约 JSON，calculate 受档案白名单约束，
    /// validate 做结构检查；未知 operation 明确报错。
    static func execute(arguments: String, expertID: String) throws -> String {
        struct Arguments: Decodable {
            let operation: String
            let calculator: String?
            let inputs_json: String?
            let content: String?
            let format: String?
        }
        let args = try JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8))
        let profile = try ExpertCapabilityCatalog.profile(expertID)
        switch args.operation {
        case "plan":
            return String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        case "calculate":
            guard let name = args.calculator, profile.calculators.contains(name) else {
                throw ExpertSkillError.denied("该计算器；允许：\(profile.calculators.joined(separator: ", "))")
            }
            return String(decoding: try JSONEncoder().encode(
                BusinessCalculators.calculate(name: name, json: args.inputs_json ?? "{}")), as: UTF8.self)
        case "validate":
            let result = try validateDocument(args.content ?? "", format: args.format ?? "word", profile: profile)
            return String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        default:
            throw ExpertSkillError.invalidInput("operation 必须为 plan / calculate / validate")
        }
    }
}
