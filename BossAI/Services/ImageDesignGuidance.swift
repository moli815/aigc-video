import Foundation

/// A compact planning skill, applied once before tool selection. Research and provenance:
/// BossAI/IMAGE-DESIGN-REVIEW-20261026.md. User requirements always outrank defaults.
enum ImageDesignGuidance {
    struct Reference: Decodable {
        let id: String
        let name: String
        let principles: String
        let layout: String
        let font: String
        let tags: [String]?
    }
    private struct Library: Decodable { let patterns: [Reference] }
    static let references: [Reference] = {
        guard let url = Bundle.main.url(forResource: "ImageDesignReferences", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(Library.self, from: data) else { return [] }
        return library.patterns
    }()

    static var instructions: String {
        instructions(for: "")
    }
    static func suggestions(for request: String) -> [Reference] {
        let text = request.lowercased()
        let matched = references.filter { reference in
            (reference.tags ?? []).contains { tag in
                let tag = tag.lowercased()
                return text.contains(tag) && !["不要", "不想要", "别用", "不要再"].contains { text.contains($0+tag) }
            }
        }
        if !matched.isEmpty { return Array(matched.prefix(4)) }
        let diverseDefaults = ["swiss", "flat-illustration", "art-deco", "anime-story", "editorial-photo", "printmaking"]
        return diverseDefaults.compactMap { id in references.first { $0.id == id } }
    }
    static func instructions(for request: String) -> String {
        let examples = suggestions(for: request).map { reference in
            "\(reference.name)：\(reference.principles) 可参考 layout=\(reference.layout)、fontStyle=\(reference.font)。"
        }.joined(separator: "\n")
        return baseInstructions + "\n【设计参考词典】只选择与任务匹配的一个主方向，不把所有风格混用；版式、色板与表现手法可以独立组合，用户新要求始终优先。\n" + examples
    }

    private static let baseInstructions = """
    图片设计方法：调用工具前在内部完成简短设计判断，不把过程写成一大段让用户反复选方案。
    1. 先确定用途、受众、用户指定风格及禁止项，选一个清晰视觉方向。用户说动漫就明确线稿、色块、角色/场景表现；不要自动套蓝色霓虹城市、发光图标或玻璃科技风。
    2. 画面只有一个主视觉焦点，主次通过大小、位置、明暗形成。使用连贯配色与有意的留白；视觉元素服务主题，不为显得丰富而堆装饰。
    3. 有文字时先规划标题、副标题、正文、联系方式的阅读顺序和对齐关系。标题应明显大于正文，重要信息不能塞成左上角小字。图像主体与文字区域错开，避免压住人脸或关键信息。
    4. structured.text 按语义逐项保存精确原文，key 唯一稳定；不能把构图指令、负面约束或内部分析当正文。信息必须完整，不编造姓名、电话或宣传事实。
    5. structured.layout 可选 editorial/centered/split 构图；需要自由排布时为每个 key 给出归一化 blocks（0到1），完整覆盖所有文字、留足边距、不重叠。不要给每项都相同坐标。
    6. prompt 用具体主体、构图、风格表现、材质和光线描述画面，明确用户要求改变什么、保留什么；少用空泛的高级/震撼/精美形容词。文字原文放 structured.text。新风格优先于参考图旧风格，用户明确否定的风格不能继续沿用。
    7. 将版式骨架（例如非对称编排/主视觉跨栏/上下信息带/信息图结构）、色板、表现手法、文字密度分开判断，不把行业等同于固定审美。信息多时优先完整性与可读性，不能为艺术化删掉用户文案。写给Seedream的视觉描述尽量简洁连贯，中文约300字以内为目标；用户必需原文不能为凑长度被截断，不另加一次LLM提示词改写。
    8. 原样替换上传Logo/二维码时，image_edit必须source=both（图1海报底图，图2上传原素材），structured.preserve_assets指定reference_index=2和归一化替换区域，默认preserve_outside=true。模型只清理旧区域，程序合成原素材；不能把品牌重画成相似图，也不凭文字臆造Logo。替换区域必须有依据，位置不清楚时只确认该位置。
    9. 为图片工具选择quality_tier和quality_reason：草稿、简单插画/图标、简单背景改色可fast；信息密集布局、人物保真、品牌精确、复杂编辑、正式终稿选high。不按“海报/名片”类别一刀切，不因故障静默降档。保留用户明确要求的高质量；不确定时选high。该选择只影响图片模型，不改变聊天模型。
    """
}
