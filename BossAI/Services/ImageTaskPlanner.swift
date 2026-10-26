import Foundation

// ImageTaskPlanner.swift —— 图片任务规划器（第一阶段：规则版，不调模型）
//
// 职责边界：它不是提示词生成器，只做任务分类、数量/档位归一和源图画布参数计算；
// Agent 输出的 prompt 原样传递，精确可见文案由 structured.text 单独承载。
//
// 设计边界（重要，别把它当成万能理解器）：
//   · 这是**规则版**：纯确定性函数，不联网、不调模型、不猜画面内容；
//     它只判类型并补结构化参数，不向 prompt 追加第二套约束。
//   · 不编造主体细节。用户没说"穿蓝衬衫"，这里就不会替他加。
//   · 判断不确定时不硬猜：`needsClarification` 交给上层决定是否追问一句。
//
// 字段对齐《图片生成能力优化方案》§3.2 的内部协议，但**不假设模型支持这些字段**：
// 由调用方（ImageService / bf-image）转换成真实请求参数。

/// 图片任务类型：只描述执行语义，不按成品类别创建分支。
enum ImageTaskType: String, Equatable, CaseIterable {
    case generate   // 普通文生图
    case edit       // 已有图片编辑
    case reference  // 参考图重设计：保留主体/主题语义，但允许重构风格与构图
    case series     // 系列组图

    var displayName: String {
        switch self {
        case .generate: return "文生图"
        case .edit: return "图片编辑"
        case .reference: return "参考图生成"
        case .series: return "系列组图"
        }
    }
}

/// 规划器的输出：一份结构化执行计划
struct ImageTaskPlan: Equatable {
    let taskType: ImageTaskType
    /// Agent 整理后的唯一视觉提示词；规划器只归一参数，不再二次改写提示词。
    let prompt: String
    /// 参考图数量（0 表示纯文生图）
    let referenceCount: Int
    /// 目标比例，如 "1:1" / "3:4" / "16:9"
    let aspectRatio: String
    /// 质量档位："auto"（交给服务端推断）/ "fast" / "high"（历史别名 pro 会归一为 high）
    let qualityTier: String
    /// 目标张数（1...4）
    let outputCount: Int
    /// 是否需要先向用户追问一句
    let needsClarification: Bool
    /// 追问内容（needsClarification 为 true 时非空）
    let clarification: String?

    // ── 10-25 画布几何约束（只能约束输出比例，不能证明内容没有被模型裁切/重构）──
    /// 显式像素尺寸（"1200x800"）；Provider adapter 将它编译为各自原生尺寸参数。
    let targetSize: String?
    /// 请求与输出校验是否要求沿用源图画布比例；不代表对主体/边缘内容做了像素级保真验证。
    let preserveSourceAspect: Bool
    /// 用户是否明确要求改比例/裁切（没明确要求就一律不允许裁）
    let allowCrop: Bool
    /// 原图真实像素（nil = 读不到，此时不承诺保留比例）
    let sourceWidth: Int?
    let sourceHeight: Int?
}

enum ImageTaskPlanner {

    // MARK: - 关键词表（中文为主）

    private static let seriesWords = ["组图", "系列套图", "一套图", "同一套", "多张", "几张", "分镜", "连续画面"]
    private static let editWords = ["改成", "换掉", "换成", "替换", "去掉", "删掉", "加上", "添加", "p掉", "修掉", "调亮", "调暗", "变亮", "变暗", "换背景", "改背景", "改成海边", "合成"]
    private static let referenceWords = ["参考这张", "参照这张", "参考图", "根据这张图", "基于这张图", "以这张图为基础", "重新设计", "重新做一版", "改版", "换一种风格", "换个风格", "调整风格", "同款风格", "类似的风格", "这种配色", "这个配色"]
    private static let fullRedesignWords = ["重新设计", "重新做一版", "整体重做", "整体改版", "重新排版", "做成新的海报", "做一张新的海报"]
    private static let localOnlyWords = ["只改", "仅改", "只修改", "仅修改", "局部修改", "只替换", "只去掉", "只添加", "其他部分不变", "其余不变", "其余部分保持原样"]

    // MARK: - 对外入口

    /// 生成执行计划。
    /// - Parameters:
    ///   - userText: 用户原话（也允许传模型生成的 prompt）
    ///   - referenceCount: 附带参考图数量（0 = 纯文字）
    ///   - requestedCount: 调用方已指定的张数（nil 表示未指定，由规划器推断）
    ///   - aspectRatio: 调用方已指定比例（nil 表示未指定）
    ///   - qualityTier: 调用方已指定档位（"auto"/"fast"/"high"，pro/hd 会归一化）
    static func plan(userText: String,
                     referenceCount: Int = 0,
                     requestedCount: Int? = nil,
                     aspectRatio: String? = nil,
                     qualityTier: String? = nil,
                     sourceSize: (width: Int, height: Int)? = nil,
                     userSaid: String? = nil,
                     preferReferenceRedesign: Bool = false) -> ImageTaskPlan {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        // 用户自己的原话（区别于模型改写后的 prompt）：
        // 判断"用户是否真的要改比例"只能看用户原话，模型随口带个 aspect_ratio 不算授权。
        let userLowered = (userSaid ?? text).lowercased()

        // Task semantics must retain the user's original wording even when the Agent rewrote prompt.
        let type = classify(text: userLowered + "\n" + lowered,
                            referenceCount: referenceCount,
                            requestedCount: requestedCount,
                            preferReferenceRedesign: preferReferenceRedesign)
        let count = resolveCount(text: lowered, type: type, requested: requestedCount)
        let modelRatio = normalizeAspect(aspectRatio)
        let userAspect = explicitUserAspect(in: userLowered)
        // The user's explicit canvas intent wins over a contradictory Agent suggestion.
        let explicitRatio = userAspect ?? modelRatio
        let tier = resolveTier(explicit: qualityTier, type: type)
        // ── 10-25 比例决策（P 图被裁切的根因修复）──
        // 规则只有一条：**有参考图且要保留原图内容的任务，默认锁死原图比例**。
        // 旧实现让 edit 落到 inferAspect 的 default = "1:1"，于是横版照片被要求
        // "画面比例 1:1"，模型只能中心裁切 —— 左右边缘和主体就没了。
        let editLike = (type == .edit || type == .reference) && referenceCount > 0
        var ratio: String = "1:1"
        var targetSize: String? = nil
        var preserveAspect = false
        var allowCrop = false
        var ask: String? = nil
        if editLike {
            if let userAspect {
                // 只有**用户原话里**明确指定了比例/方向（含“横版/竖版/方图”）才授权改画布。
                // 模型自己带的 aspect_ratio 一律忽略——它经常顺手填 1:1，那正是裁切的来源。
                ratio = userAspect
                allowCrop = true
            } else if let source = sourceSize {
                ratio = "\(source.width):\(source.height)"
                preserveAspect = true
                if let clamped = ImageGeometry.clampedSize(width: source.width, height: source.height,
                    targetPixels: tier == "high" ? 4_194_304 : nil) {
                    // 没要求改比例 → 按原图真实像素要尺寸，比例天然一致
                    targetSize = clamped
                } else {
                    // 不把不可表达的原图比例偷偷改成默认方图，也不再“补边后裁回”。
                    ask = "这张原图的极端比例超出当前模型可安全生成的画布范围。为避免自动裁边，请换一张比例更常见的图片，或明确回复“允许改变比例/允许裁切”后再生成。"
                }
            } else {
                // 读不到原图尺寸时不猜默认方图；调用方会 fail closed。
                ratio = ""
            }
        } else {
            ratio = explicitRatio ?? inferAspect(text: lowered, type: type)
        }

        // 追问：只在"问了才能做对"时问，且只问一句
        if ask == nil, text.count < 3 {
            ask = "想画什么？给一句主题就行（例如：赛博朋克城市夜景）。"
        } else if ask == nil, referenceCount == 0 && contains(lowered, any: editWords) {
            // 说的是"改/换/去掉"但没带图：不问一句就只能瞎生成一张全新的图
            ask = "要改哪张图？先把图片发我，我再按你的描述改。"
        }

        return ImageTaskPlan(taskType: type,
                             prompt: text,
                             referenceCount: referenceCount,
                             aspectRatio: ratio,
                             qualityTier: tier,
                             outputCount: count,
                             needsClarification: ask != nil,
                             clarification: ask,
                             targetSize: targetSize,
                             preserveSourceAspect: preserveAspect,
                             allowCrop: allowCrop,
                             sourceWidth: sourceSize?.width,
                             sourceHeight: sourceSize?.height)
    }

    // MARK: - 分类

    private static func classify(text: String,
                                 referenceCount: Int,
                                 requestedCount: Int?,
                                 preferReferenceRedesign: Bool) -> ImageTaskType {
        let hasSeriesWord = contains(text, any: seriesWords)
        // 10-26：只认"3 张 / 四幅 / 两组"这类真数量。
        // 旧实现是 `parseCount>=2 && contains("张")`，于是
        // 「把这张照片里的女士旁边加一个人」会因"这张"+"两个人"被判成组图，
        // 单图局部编辑被扩成多张生成（多扣费、还丢掉原图画布约束）。
        let wantsMany = (requestedCount ?? 0) >= 2 || imageCountHint(text) >= 2
        if hasSeriesWord || wantsMany {
            return .series
        }
        if referenceCount > 0 {
            // “只改局部”优先走 edit；“重新设计整张”即使同时说“改成某风格”，
            // 仍是 reference redesign，不能被普通“改成”关键词误判成像素保留编辑。
            if contains(text, any: localOnlyWords) && contains(text, any: editWords) {
                return .edit
            }
            if preferReferenceRedesign || contains(text, any: fullRedesignWords) {
                return .reference
            }
            // 成品名称不能覆盖参考图语义，也不能强加固定版式。
            if contains(text, any: referenceWords) && !contains(text, any: editWords) {
                return .reference
            }
            return .edit
        }
        return .generate
    }

    // MARK: - 参数推断

    /// 真·数量提示：只认「数词 + 张/幅/组」，并排除「这张/那张/几张」这种量词用法。
    /// 用途只有一处——判断是否是组图；单图任务的数量推断仍走 parseCount。
    static func imageCountHint(_ text: String) -> Int {
        let numerals: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                          "1": 1, "2": 2, "3": 3, "4": 4]
        let chars = Array(text)
        var best = 1
        for (i, c) in chars.enumerated() where c == "张" || c == "幅" || c == "组" {
            var j = i - 1
            while j >= 0, chars[j] == " " || chars[j] == "\n" { j -= 1 }
            guard j >= 0, let value = numerals[chars[j]] else { continue }
            let before = j - 1
            // 「这张照片」「那两张图」「几张」是量词，不是数量
            if before >= 0, chars[before] == "这" || chars[before] == "那" || chars[before] == "几" {
                continue
            }
            best = max(best, value)
        }
        return min(4, max(1, best))
    }

    /// 解析中文/阿拉伯数字张数，1...4；没提数量返回 1
    static func parseCount(_ text: String) -> Int {
        imageCountHint(text)
    }

    private static func resolveCount(text: String, type: ImageTaskType, requested: Int?) -> Int {
        if let requested, requested > 0 { return min(4, max(1, requested)) }
        let parsed = parseCount(text)
        if type == .series { return max(2, min(4, parsed == 1 ? 2 : parsed)) }
        // 10-26：非组图任务的张数**只**由 Agent 显式指定。
        // 文案里的"两个人/三个元素"是画面元素，不是要生成几张图；
        // 旧实现会把「加两个人」当成 2 张来生成（多扣费 + 打乱画布约束）。
        return 1
    }

    /// 质量档位归一化（10-25 契约修复）。
    ///
    /// 服务端只认 auto / fast / high；客户端历史上发的是 "pro"，导致"指定了高质量、
    /// 服务端却按 auto 推断成 Flash"的静默降级——海报变糊就是这么来的。
    /// 合法输出只有三个值，未知值一律回 auto（交回服务端判断），不硬猜。
    static func normalizeQualityTier(_ raw: String?) -> String {
        guard let raw else { return "auto" }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "pro", "quality", "best", "hd", "2k": return "high"
        case "fast", "flash", "draft", "quick", "low": return "fast"
        default: return "auto"
        }
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
              w.isFinite, h.isFinite, w > 0, h > 0, (w / h).isFinite else { return nil }
        return "\(format(w)):\(format(h))"
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() && v < Double(Int.max) ? String(Int(v)) : String(v)
    }

    private static func inferAspect(text: String, type: ImageTaskType) -> String {
        if let explicit = firstAspectToken(in: text) { return explicit }
        if contains(text, any: ["横版", "横幅", "宽屏", "banner", "易拉宝横幅"]) { return "16:9" }
        if contains(text, any: ["竖版", "手机壁纸", "朋友圈", "长图"]) { return "9:16" }
        if contains(text, any: ["方形", "方图", "头像", "logo", "icon"]) { return "1:1" }
        switch type {
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

    /// Explicit canvas choices from the user's own words. Agent-supplied ratio is not
    /// authorization to crop an existing image; only these user-originated signals are.
    private static func explicitUserAspect(in text: String) -> String? {
        if let ratio = firstAspectToken(in: text) { return ratio }
        if contains(text, any: ["横版", "横向", "横屏", "横幅", "宽屏"]) { return "16:9" }
        if contains(text, any: ["竖版", "竖向", "竖屏", "长图", "手机壁纸"]) { return "9:16" }
        if contains(text, any: ["方形", "方图", "正方形"]) { return "1:1" }
        return nil
    }

    private static func resolveTier(explicit: String?, type: ImageTaskType) -> String {
        if let normalized = explicit.map(normalizeQualityTier), normalized != "auto" {
            return normalized
        }
        switch type {
        case .edit: return "high"        // 编辑要尽量保真，走高质量档
        case .reference: return "high"   // 基于参考图重新设计成品，质量优先（低档会明显掉细节）
        case .series: return "auto"      // 组图由服务端的 series 模型决定
        default: return "auto"
        }
    }

    // MARK: - 小工具

    private static func contains(_ text: String, any words: [String]) -> Bool {
        for w in words where text.contains(w) { return true }
        return false
    }
}
