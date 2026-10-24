import Foundation

// ImageTaskPlanner.swift —— 图片任务规划器（第一阶段：规则版，不调模型）
//
// 为什么要有它：现在"用户说什么就原样丢给生图模型"，于是出现三类问题——
//   ① 该走排版的海报被交给模型画字（名片小字必错）；
//   ② 该保留原图的编辑没有"必须保留"的约束（P 完人都变了）；
//   ③ 组图数量/比例全靠模型猜，四张变一张也说不清是谁的错。
//
// 设计边界（重要，别把它当成万能理解器）：
//   · 这是**规则版**：纯确定性函数，不联网、不调模型、不猜画面内容；
//     它只做三件事——判类型、补参数、加约束。
//   · 不编造主体细节。用户没说"穿蓝衬衫"，这里就不会替他加。
//   · 判断不确定时不硬猜：`needsClarification` 交给上层决定是否追问一句。
//
// 字段对齐《图片生成能力优化方案》§3.2 的内部协议，但**不假设模型支持这些字段**：
// 由调用方（ImageService / bf-image）转换成真实请求参数。

/// 图片任务类型（对应方案里的五类）
enum ImageTaskType: String, Equatable, CaseIterable {
    case generate   // 普通文生图
    case edit       // 已有图片编辑
    case reference  // 参考图生成（借风格不借内容）
    case poster     // 专业海报 / 名片 / 封面：必须程序排版
    case series     // 系列组图

    var displayName: String {
        switch self {
        case .generate: return "文生图"
        case .edit: return "图片编辑"
        case .reference: return "参考图生成"
        case .poster: return "海报排版"
        case .series: return "系列组图"
        }
    }
}

/// 文字处理策略：决定"文字交给谁画"
enum ImageTextPolicy: String, Equatable {
    case none         // 画面里不需要文字
    case avoid        // 尽量别在画面里画字（字由 UI 层承担）
    case programmatic // 必须由程序排版绘制（海报/名片/价格/电话）
}

/// 规划器的输出：一份结构化执行计划
struct ImageTaskPlan: Equatable {
    let taskType: ImageTaskType
    /// 用户想做什么（一句话，给日志与提示用，不发给模型）
    let intent: String
    /// 真正发给模型的提示词（原话 + 必要的结构化约束）
    let prompt: String
    /// 需要避免的变化/内容
    let negativeConstraints: [String]
    /// 参考图数量（0 表示纯文生图）
    let referenceCount: Int
    /// 目标比例，如 "1:1" / "3:4" / "16:9"
    let aspectRatio: String
    /// 质量档位："auto"（交给服务端推断）/ "fast" / "pro"
    let qualityTier: String
    /// 目标张数（1...4）
    let outputCount: Int
    /// 文字策略
    let textPolicy: ImageTextPolicy
    /// 是否必须保留原图内容（编辑类任务）
    let preserveOriginal: Bool
    /// 是否需要先向用户追问一句
    let needsClarification: Bool
    /// 追问内容（needsClarification 为 true 时非空）
    let clarification: String?
}

enum ImageTaskPlanner {

    // MARK: - 关键词表（中文为主）

    private static let seriesWords = ["组图", "系列套图", "一套图", "同一套", "多张", "几张", "分镜", "连续画面"]
    private static let posterWords = ["海报", "封面图", "名片", "宣传图", "易拉宝", "banner", "横幅", "证书", "头图", "主图", "kv图", "价目表"]
    private static let editWords = ["改成", "换掉", "换成", "替换", "去掉", "删掉", "加上", "添加", "p掉", "修掉", "调亮", "调暗", "变亮", "变暗", "换背景", "改背景", "改成海边", "合成"]
    private static let referenceWords = ["参考这张", "参照这张", "参考图", "同款风格", "类似的风格", "这种配色", "这个配色"]
    private static let textHeavyWords = ["价格", "￥", "¥", "元", "电话", "手机", "地址", "网址", "二维码", "报名", "时间", "日期", "logo", "LOGO"]

    // MARK: - 对外入口

    /// 生成执行计划。
    /// - Parameters:
    ///   - userText: 用户原话（也允许传模型生成的 prompt）
    ///   - referenceCount: 附带参考图数量（0 = 纯文字）
    ///   - requestedCount: 调用方已指定的张数（nil 表示未指定，由规划器推断）
    ///   - aspectRatio: 调用方已指定比例（nil 表示未指定）
    ///   - qualityTier: 调用方已指定档位（"auto"/"fast"/"pro"）
    static func plan(userText: String,
                     referenceCount: Int = 0,
                     requestedCount: Int? = nil,
                     aspectRatio: String? = nil,
                     qualityTier: String? = nil) -> ImageTaskPlan {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()

        let type = classify(text: lowered, referenceCount: referenceCount, requestedCount: requestedCount)
        let count = resolveCount(text: lowered, type: type, requested: requestedCount)
        let ratio = normalizeAspect(aspectRatio) ?? inferAspect(text: lowered, type: type)
        let tier = resolveTier(explicit: qualityTier, type: type)
        let textPolicy = resolveTextPolicy(text: lowered, type: type)
        let preserve = (type == .edit)
        let constraints = buildConstraints(type: type, preserveOriginal: preserve, textPolicy: textPolicy)

        // 追问：只在"问了才能做对"时问，且只问一句
        var ask: String? = nil
        if text.count < 3 {
            ask = "想画什么？给一句主题就行（例如：赛博朋克城市夜景）。"
        } else if referenceCount == 0 && contains(lowered, any: editWords) {
            // 说的是"改/换/去掉"但没带图：不问一句就只能瞎生成一张全新的图
            ask = "要改哪张图？先把图片发我，我再按你的描述改。"
        }

        let prompt = buildPrompt(text: text, type: type, ratio: ratio,
                                 count: count, textPolicy: textPolicy, preserveOriginal: preserve)

        return ImageTaskPlan(taskType: type,
                             intent: intentText(type: type, count: count),
                             prompt: prompt,
                             negativeConstraints: constraints,
                             referenceCount: referenceCount,
                             aspectRatio: ratio,
                             qualityTier: tier,
                             outputCount: count,
                             textPolicy: textPolicy,
                             preserveOriginal: preserve,
                             needsClarification: ask != nil,
                             clarification: ask)
    }

    // MARK: - 分类

    private static func classify(text: String, referenceCount: Int, requestedCount: Int?) -> ImageTaskType {
        let hasSeriesWord = contains(text, any: seriesWords)
        let wantsMany = (requestedCount ?? 0) >= 2 || parseCount(text) >= 2
        if hasSeriesWord || (wantsMany && contains(text, any: ["张", "幅", "组"])) {
            return .series
        }
        if contains(text, any: posterWords) {
            return .poster
        }
        if referenceCount > 0 {
            // 有参考图：先看是不是"借风格"，再看是不是"改这张"
            if contains(text, any: referenceWords) && !contains(text, any: editWords) {
                return .reference
            }
            return .edit
        }
        return .generate
    }

    // MARK: - 参数推断

    /// 解析中文/阿拉伯数字张数，1...4；没提数量返回 1
    static func parseCount(_ text: String) -> Int {
        let map: [(String, Int)] = [("四", 4), ("4", 4), ("三", 3), ("3", 3), ("两", 2), ("二", 2), ("2", 2)]
        for (token, value) in map where text.contains(token) {
            // 必须与"张/幅/组/个"相邻，否则"3 秒"会被误判成张数
            if let range = text.range(of: token) {
                let tail = text[range.upperBound...].prefix(3)
                if tail.contains("张") || tail.contains("幅") || tail.contains("组") || tail.contains("个") {
                    return min(4, max(1, value))
                }
            }
        }
        return 1
    }

    private static func resolveCount(text: String, type: ImageTaskType, requested: Int?) -> Int {
        if let requested, requested > 0 { return min(4, max(1, requested)) }
        let parsed = parseCount(text)
        if type == .series { return max(2, min(4, parsed == 1 ? 2 : parsed)) }
        return min(4, max(1, parsed))
    }

    /// 归一化调用方传入的比例："3:4" / "3x4" / "3：4" 都接受
    static func normalizeAspect(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "x", with: ":")
            .replacingOccurrences(of: "X", with: ":")
            .replacingOccurrences(of: "*", with: ":")
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2,
              let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0 else { return nil }
        return "\(format(w)):\(format(h))"
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private static func inferAspect(text: String, type: ImageTaskType) -> String {
        if let explicit = firstAspectToken(in: text) { return explicit }
        if contains(text, any: ["横版", "横幅", "宽屏", "banner", "易拉宝横幅"]) { return "16:9" }
        if contains(text, any: ["竖版", "手机壁纸", "朋友圈", "长图"]) { return "9:16" }
        if contains(text, any: ["方形", "方图", "头像", "logo", "icon"]) { return "1:1" }
        switch type {
        case .poster: return "3:4"      // 海报/名片最常见竖版
        case .series: return "3:4"
        default: return "1:1"
        }
    }

    /// 从文字里找 "3:4" 这类显式比例
    private static func firstAspectToken(in text: String) -> String? {
        let pattern = #"([0-9]{1,2})\s*[:：xX*]\s*([0-9]{1,2})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges == 3,
              let r1 = Range(m.range(at: 1), in: text),
              let r2 = Range(m.range(at: 2), in: text) else { return nil }
        let w = String(text[r1]), h = String(text[r2])
        // 只接受像"比例"的数值，避免把"10:30 开会"当比例
        guard let wi = Int(w), let hi = Int(h), wi <= 21, hi <= 21, wi > 0, hi > 0 else { return nil }
        return "\(wi):\(hi)"
    }

    private static func resolveTier(explicit: String?, type: ImageTaskType) -> String {
        if let explicit, explicit != "auto", !explicit.isEmpty { return explicit }
        switch type {
        case .poster: return "pro"       // 商业物料，视觉质量优先
        case .edit: return "pro"         // 编辑要尽量保真，走高质量档
        case .series: return "auto"      // 组图由服务端的 series 模型决定
        default: return "auto"
        }
    }

    private static func resolveTextPolicy(text: String, type: ImageTaskType) -> ImageTextPolicy {
        if type == .poster { return .programmatic }
        if contains(text, any: textHeavyWords) { return .programmatic }
        return .avoid
    }

    private static func buildConstraints(type: ImageTaskType, preserveOriginal: Bool, textPolicy: ImageTextPolicy) -> [String] {
        var out = ["画面内不要出现乱码文字或水印"]
        if textPolicy == .programmatic {
            out.append("不要把价格/电话/地址/标题交给模型绘制，这些字符由排版层生成")
        }
        if preserveOriginal {
            out.append("不要改变人物面部特征、服装与姿势")
            out.append("不要改动用户未要求修改的区域")
        }
        if type == .series {
            out.append("同一组图必须保持统一配色与视觉语言")
        }
        return out
    }

    // MARK: - 提示词拼装（只加必要约束，不编造画面内容）

    private static func buildPrompt(text: String,
                                    type: ImageTaskType,
                                    ratio: String,
                                    count: Int,
                                    textPolicy: ImageTextPolicy,
                                    preserveOriginal: Bool) -> String {
        var parts: [String] = [text]
        var directives: [String] = ["画面比例 \(ratio)"]
        if count > 1 { directives.append("共 \(count) 张，风格统一、内容各异") }
        switch textPolicy {
        case .programmatic:
            directives.append("画面内不要绘制任何文字、数字、价格或二维码，相关区域留白即可")
        case .avoid:
            directives.append("画面内尽量不要出现文字或水印")
        case .none:
            break
        }
        if preserveOriginal {
            directives.append("保留原图的人物面貌、服装、姿势与整体构图，只修改用户指定的部分")
        }
        parts.append("【画面要求】" + directives.joined(separator: "；") + "。")
        return parts.joined(separator: "\n")
    }

    private static func intentText(type: ImageTaskType, count: Int) -> String {
        switch type {
        case .generate: return "生成一张图"
        case .edit: return "按描述修改已有图片并另存新版本"
        case .reference: return "借鉴参考图的风格生成新图"
        case .poster: return "生成海报底图并由程序完成文字排版"
        case .series: return "生成 \(count) 张风格统一的系列图"
        }
    }

    // MARK: - 小工具

    private static func contains(_ text: String, any words: [String]) -> Bool {
        for w in words where text.contains(w) { return true }
        return false
    }
}
