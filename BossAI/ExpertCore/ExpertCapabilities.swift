import Foundation

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

struct SkillValidation: Codable {
    let structurePassed: Bool
    let missingSections: [String]
    let warnings: [String]
}

enum ExpertSkillRuntime {
    static func permits(_ name: String, profile: ExpertCapability) -> Bool {
        switch name {
        case "expert_skill", "search_library": return true
        case "web_search", "$web_search": return profile.allowSearch
        case "generate_image": return profile.allowImages
        case "create_document": return !profile.documentFormats.isEmpty
        default: return false
        }
    }

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
