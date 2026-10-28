import Foundation

/// Model-visible contracts and execution metadata belong to the same manifest.
extension ToolManifest {
    static let recallHistoryFunction: [String: Any] = [
        "name": "recall_history",
        "description": "用户提及以前的项目、人员、决定、联系方式、偏好或图片素材时，先查历史再回答。改写为最多3组实体/同义关键词；例如平台界面→平台首页/大屏、品牌配色→Logo颜色。可返回账号图片记忆ID供作图工具library_refs选取原图；需要重新看图时include_images=true，只读取最相关的两张预览。描述并非当前经营数据；不宣称找到未返回的信息。",
        "parameters": ["type": "object", "properties": [
            "queries": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 3,
                        "description": "人物/项目名+待查字段，可用不同同义说法；不要复制整段用户指令"],
            "include_images": ["type": "boolean", "description": "需要分析以前上传图片或用其做设计时设true，最多读两张相关预览；仅回忆文字事实时省略"]
        ], "required": ["queries"]]
    ]
    /// 构造 expert_skill 工具定义：operation 枚举按专家是否带计算器动态收窄，
    /// calculator 参数仅在有可用计算器时暴露，防模型调用不存在的计算器
    static func expertSkillFunction(_ capability: ExpertCapability) -> [String: Any] {
        var properties: [String: Any] = [
            "operation": ["type": "string", "enum": capability.calculators.isEmpty ? ["plan", "validate"] : ["plan", "calculate", "validate"]],
            "inputs_json": ["type": "string", "description": BusinessCalculators.inputGuide],
            "content": ["type": "string", "description": "待结构校验的Markdown正文"],
            "format": ["type": "string", "enum": capability.documentFormats],
        ]
        if !capability.calculators.isEmpty {
            properties["calculator"] = ["type": "string", "enum": capability.calculators]
        }
        return ["name": "expert_skill", "description": "读取本专家技能契约、执行本地确定性经营计算、检查交付章节。权限由App固定专家控制，不接受模型指定专家ID；校验只保证结构，不保证事实正确。",
                "parameters": ["type": "object", "properties": properties, "required": ["operation"]]]
    }

    /// 自定义联网搜索工具（App 本地执行，与模型厂商无关）
    ///
    /// 描述里写死「多实体逐个搜 + 宁缺毋滥」两条硬规则，
    /// 这是「收集 6 款机型参数」这类任务做不准的主要纠正点：
    /// 模型原本只用一句笼统关键词搜一次，然后靠记忆把空格填满。
    static let webSearchFunction: [String: Any] = [
        "name": "web_search",
        "description": """
        联网检索可变事实。搜索词写主体全名和待核实字段，多实体分开检索，优先补缺失字段，避免重复查询；App 有限并行执行并复用本轮证据。
        价格、规格、政策、新闻等时效信息必须核实。最新在售产品可早于近30天发布；仅当用户明确要求今天、本周、本月时限制发布时间。
        搜索摘要仅是线索。正文与对象、地区、版本和时间必须对应；不能用记忆或其他型号填空。字段证据不足写未核实，传闻单独标注，来源冲突保留。
        每个具体结论旁写（来源 N），表格来源列填 N。只引用真正支持结论的来源。App 显示标题与链接，不另写全量检索清单或重复来源表。
        """,
        "parameters": [
            "type": "object",
            "properties": [
                "recency": ["type": "string", "enum": ["any", "day", "week", "month", "year"], "description": "发布时间窗口：今天day、本周week、本月month；最新在售或无明确窗口any。日期未知必须注明未核实。"],
                "query": [
                    "type": "string",
                    "description": "具体搜索关键词：主体全名 + 要查的字段 + 年份（如「完整产品名 官方规格 电池」）",
                ],
            ],
            "required": ["query"],
        ],
    ]

    /// 本地统计图表工具：模型输出结构化数据，App 用 Swift Charts 渲染（数字准确，可放大保存）
    static let renderChartFunction: [String: Any] = [
        "name": "render_chart",
        "description": "把已核实的数值数据渲染成统计图（柱状图/折线图/环形图）。仅在数据全部来自本轮已核实来源或用户提供时调用；数字必须精确，禁止估计值。示意性/装饰性图像请改用 generate_image。",
        "parameters": [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": ["bar", "line", "pie"], "description": "图表类型：对比用 bar、趋势用 line、占比用 pie"],
                "title": ["type": "string", "description": "图表标题：对象 + 口径（如「各机型官方起售价（元）」）"],
                "labels": ["type": "array", "items": ["type": "string"], "description": "每个数据点的名称（最多 8 个）"],
                "values": ["type": "array", "items": ["type": "number"], "description": "与 labels 一一对应的数值（最多 8 个）"],
                "unit": ["type": "string", "description": "数值单位（元 / mAh / % 等），无单位可省略"],
                "source_note": ["type": "string", "description": "数据来源说明（如「来源 1、3」或「用户提供」）"],
            ],
            "required": ["type", "title", "labels", "values"],
        ],
    ]

    /// 自定义生图工具定义
    static let generateImageFunction: [String: Any] = {
        let generateImageParameters: [String: Any] = [
            "type": "object",
            "properties": [
                "prompt": [
                    "type": "string",
                    "description": "详细的图像描述（中文），包含主体、风格、构图、文字内容等",
                ],
                "edit_last_image": [
                    "type": "boolean",
                    "description": "是否以对话中最近一张生成的图片为底图（如「把这张海报改一改」）。若同时要把用户上传的图（Logo/素材）叠加到底图上，edit_last_image 与 use_attached_image 同时设为 true",
                ],
                "use_attached_image": [
                    "type": "boolean",
                    "description": "是否使用用户本轮上传的图片：①单独 true = 编辑上传的图；②与 edit_last_image 同时 true = 双图融合（把上传的 Logo/素材叠加到最近生成的图上，提示词里说明叠加位置），如「把 Logo 加到刚才的海报上」「在图片二上面加我们的 logo」等场景",
                ],
            ],
            "required": ["prompt"],
        ]
        let functionDefinition: [String: Any] = [
            "name": "generate_image",
            "description": "生成或编辑图片（兼容旧名；新代码请用 image_generate / image_edit）。",
            "parameters": generateImageParameters,
        ]
        return functionDefinition
    }()

    // ── 10-19 拆 4 工具（仿 Harness"工具即契约"）：职责隔离，消除"忘带图→退化成文生图" ──

    /// 图片任务结构化的唯一用途：精确可见文案和可选版式元数据。
    private static let imageStructuredSchema: [String: Any] = [
        "type": "object",
        "description": "承载程序精确处理的文字、版式和原样保留素材元数据。视觉构思只写在 prompt，避免冲突。text 按语义分条逐字保留；无可见文字时填空数组。preserve_assets 仅用于原素材合成。",
        "properties": [
            "preserve_outside": ["type":"boolean", "description":"搭配 preserve_assets 使用，默认true：除替换区域外恢复原图像素。只有用户明确要求同时修改其他区域时才false。"],
            "preserve_assets": [
                "type":"array", "maxItems":4,
                "description":"仅image_edit：用户要求原样替换Logo/二维码等素材时使用，禁止让模型重画相似标识。必须source=both；reference_index=2对应上传原素材，1为海报底图。box是需要清理旧标识并放置原素材的区域，按画布0..1归一化；不明确时先确认位置，不能虚构覆盖大范围。",
                "items":["type":"object", "properties":[
                    "reference_index":["type":"integer","minimum":2,"maximum":6],
                    "kind":["type":"string","enum":["logo","qr","image"],"description":"原素材类型；二维码必须qr以保护扫码留白。"],
                    "background":["type":"string","enum":["auto","keep","remove"],"description":"logo默认auto：先本机去除纯色背景，复杂底色用系统抠图并自动采用可用的最佳结果，不因背景复杂反复确认。保留底色用keep，明确抠透明用remove。二维码保留留白，不去底。只有技术失败才报处理未完成。"],
                    "box":["type":"object","properties":[
                        "x":["type":"number","minimum":0,"maximum":1],
                        "y":["type":"number","minimum":0,"maximum":1],
                        "width":["type":"number","exclusiveMinimum":0,"maximum":1],
                        "height":["type":"number","exclusiveMinimum":0,"maximum":1]
                    ],"required":["x","y","width","height"]]
                ],"required":["reference_index","box"]]
            ],
            "text": [
                "type": "array",
                "description": "最终画面里必须出现的精确文案。按标题/副标题/正文/标签/联系方式/页脚拆成多项，逐字照录，不要把整段合并成一个 body；不需要文字时填空数组。",
                "items": [
                    "type": "object",
                    "properties": [
                        "role": ["type": "string", "enum": ["title", "subtitle", "body", "label", "contact", "footer"]],
                        "key": ["type": "string", "description": "稳定的字段名，仅用于布局与错误定位，例如 company/phone/address。"],
                        "text": ["type": "string", "description": "要显示的精确文字，必须逐字保留用户提供内容。"],
                    ],
                    "required": ["role", "key", "text"],
                ],
            ],
            "layout": [
                "type": "object",
                "description": "可选文字排版意图，只决定文字布局，不属于画面文案。",
                "properties": [
                    "preset": ["type": "string", "enum": ["editorial", "centered", "split"], "description": "构图骨架：标题/主视觉/信息带；居中；左右错位分栏。按内容选择。"],
                    "fontStyle": ["type": "string", "enum": ["sans", "serif", "rounded"], "description": "无衬线/衬线/圆体。按用户风格选择，避免所有作品都套同一字体。"],
                    "blocks": [
                        "type": "array", "description": "可选自由布局，必须覆盖 text 中每个唯一 key。坐标为画布比例，不是像素，区域不得重叠。",
                        "items": ["type": "object", "properties": [
                            "key": ["type": "string"],
                            "x": ["type": "number", "minimum": 0.02, "maximum": 0.94],
                            "y": ["type": "number", "minimum": 0.02, "maximum": 0.95],
                            "width": ["type": "number", "minimum": 0.04, "maximum": 0.96],
                            "height": ["type": "number", "minimum": 0.025, "maximum": 0.96],
                            "align": ["type": "string", "enum": ["left", "center", "right"]],
                            "color": ["type": "string", "description": "文字色 #RRGGBB，必须与底图有足够对比。"],
                            "fontScale": ["type": "number", "minimum": 0.75, "maximum": 1.5],
                            "fontStyle": ["type": "string", "enum": ["sans", "serif", "rounded"]],
                            "backdrop": ["type": "boolean", "description": "默认 true，仅在文字与底图对比不足时自动启用轻量底层。"],
                        ], "required": ["key", "x", "y", "width", "height"]],
                    ],
                    "columns": ["type": "integer", "enum": [1, 2]],
                    "marginRatio": ["type": "number", "minimum": 0.02, "maximum": 0.2],
                    "gutterRatio": ["type": "number", "minimum": 0.01, "maximum": 0.15],
                    "primaryRoles": ["type": "array", "items": ["type": "string", "enum": ["title", "subtitle", "body", "label", "contact", "footer"]]],
                ],
            ],
        ],
        "required": ["text"],
    ]

    /// ① 新作品生成：支持纯文生图，也支持把用户上传图作为参考重新设计；局部编辑走 image_edit。
    /// structured 为可选的精确文字元数据；普通自然语言生成不需要补空结构。
    static let imageGenerateFunction: [String: Any] = [
        "name": "image_generate",
        "description": "生成新图；可纯文生图或基于上传图重新设计。prompt 是唯一完整的视觉指令，包含主体/场景/构图/光影/风格/约束；App 只归一任务参数，服务端只应用对应任务边界，不再二次改写视觉指令。把需准确呈现的原文单独放入 structured.text。明确只修改原图局部时用 image_edit；整图重新设计时用本工具并选择 source=attached。source_index 从 1 开始。",
        "parameters": [
            "type": "object",
            "properties": [
                "library_refs": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 4, "description": "使用recall_history返回的历史图片ID，按输入顺序提供原图；仅在明确要使用历史素材时填写。填写后取代source/source_index，不得编造ID。第一张是重设计参考，后续为辅助素材。"],
                "prompt": ["type": "string", "description": "唯一完整的视觉指令：主体、场景、构图、光影、风格和用户要求；不要把精确可见文字混入此字段，原文放 structured.text。"],
                "render_intent": [
                    "type": "string",
                    "enum": ["flat_artwork", "mockup"],
                    "description": "按用户实际交付目标选择输出形态。flat_artwork=独立平面设计稿；mockup=置于真实环境中的展示效果。用户未要求展示场景时不要擅自添加外部样机。",
                ],
                "aspect_ratio": [
                    "type": "string",
                    "description": "输出画布比例。用户未指定时，根据作品用途与构图自主选择合适的横/竖/方比例并明确填写，不要把所有任务默认为同一比例；有参考图时按用户意图区分沿用原画布还是重新设计。用户明确指定方向时必须优先遵守。",
                ],
                "source": [
                    "type": "string",
                    "enum": ["none", "attached"],
                    "description": "none=纯文生图；attached=将用户上传图作为参考输入。用户要求基于、参考或重新设计上传图片时选 attached。",
                ],
                "source_index": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 6,
                    "description": "source=attached 时选择本轮第几张图片，按用户附件显示顺序从 1 开始；只有一张图时填 1。",
                ],
                "quality_reason": ["type":"string", "enum":["draft","simple_visual","simple_edit","detailed_layout","identity_sensitive","brand_accuracy","complex_edit","final_delivery"], "description":"内部路由理由：草稿/简单视觉/简单改色可配fast；复杂版式、身份保持、品牌精确、复杂编辑或终稿配high。不得只按海报/名片类别选档。"],
                "quality_tier": [
                    "type": "string",
                    "enum": ["fast", "high"],
                    "description": "仅在用户明确指定速度/精度，或任务本身对细节精度有明确要求时选择；不要根据固定素材类别套用档位。未指定时省略，由当前服务端路由策略决定。",
                ],
                "structured": imageStructuredSchema,
            ],
            "required": ["prompt"],
        ],
    ]

    /// ② 图生图编辑：source 必须明确指定底图（enum 强制，不再靠两个 boolean 猜）
    static let imageEditFunction: [String: Any] = [
        "name": "image_edit",
        "description": "对已有图片做局部编辑（换背景、增删元素、修图），并尽量保持未提及区域、主体位置与原图画布。source 必填：last=最近生成图，attached=用户上传图，both=生成图底图+上传素材。source_index 从 1 开始选择本轮附件。若用户想基于原图重新设计一张全新作品，使用 image_generate + source=attached，避免局部编辑的像素保留约束。",
        "parameters": [
            "type": "object",
            "properties": [
                "library_refs": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 4, "description": "recall_history返回的历史图片ID，按顺序取原图，第一张为编辑底图、后续为原样合成素材。填写后取代source/source_index；禁止编造ID。"],
                "prompt": ["type": "string", "description": "唯一完整的局部编辑指令：说明改什么、哪里改、哪些内容保持；服务端只追加不与修改要求冲突的编辑边界。"],
                "render_intent": [
                    "type": "string",
                    "enum": ["flat_artwork", "mockup"],
                    "description": "按用户实际目标选择。flat_artwork=将作品整理为独立平面设计稿；mockup=保留原图中的展示环境，只改用户指定内容。未要求改变原图展示形态时，不要擅自移除场景。",
                ],
                "aspect_ratio": [
                    "type": "string",
                    "description": "目标画布比例。仅用户明确要求改比例时填写；未要求改变时沿用原图比例。可填写常用比例或等价比例。",
                ],
                "quality_reason": ["type":"string", "enum":["draft","simple_visual","simple_edit","detailed_layout","identity_sensitive","brand_accuracy","complex_edit","final_delivery"], "description":"内部路由理由：草稿/简单视觉/简单改色可配fast；复杂版式、身份保持、品牌精确、复杂编辑或终稿配high。不得只按海报/名片类别选档。"],
                "quality_tier": [
                    "type": "string",
                    "enum": ["fast", "high"],
                    "description": "仅在用户明确指定速度/精度，或任务本身对细节精度有明确要求时选择；不要根据固定素材类别套用档位。未指定时省略，由当前服务端路由策略决定。",
                ],
                "source": [
                    "type": "string",
                    "enum": ["last", "attached", "both"],
                    "description": "底图来源：last=最近生成 | attached=用户上传 | both=双图融合（第一张为底图，第二张为叠加素材）",
                ],
                "source_index": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 6,
                    "description": "source=attached/both 时选择本轮第几张图片，按附件显示顺序从 1 开始。",
                ],
                "structured": imageStructuredSchema,
            ],
            "required": ["prompt", "source"],
        ],
    ]

    /// ③ 图层拆分：把图片拆成底图 + 可独立编辑的图层（Seedream Pro/Flash 能力）
    static let imageDecomposeFunction: [String: Any] = [
        "name": "image_decompose",
        "description": "图层拆分：把一张图拆成 1 张底图 + 若干独立图层（便于后续单独替换/移动元素）。用户说「拆图层/分层/把元素分开」时使用。仅支持已有图片（最近生成的图或用户上传的图）。",
        "parameters": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "说明要拆哪些元素（可选；不填则整体拆分）"],
                "source": ["type": "string", "enum": ["last", "attached"], "description": "拆分哪张图：last=最近生成 | attached=用户上传"],
                "source_index": ["type": "integer", "minimum": 1, "maximum": 6, "description": "source=attached 时的附件序号，从 1 开始。"],
            ],
            "required": ["source"],
        ],
    ]

    /// ④ 组图（多张关联图）：服务端编排器拆成 N 个单图子任务（10-24）
    static let imageSeriesFunction: [String: Any] = [
        "name": "image_series",
        "description": "组图生成：一次生成多张内容关联的图片（漫画分镜、品牌视觉系列、一套物料）。用户说「生成一组/一套/N张/分镜」时使用。服务端会拆成 N 张单图依次生成，**可能出现部分失败**，返回已成功的张数与失败张数；失败的那几张可以单独重试。一次最多 4 张。",
        "parameters": [
            "type": "object",
            "properties": [
                "prompt": ["type": "string", "description": "整组图的统一描述（各图差异点写清楚）"],
                "count": ["type": "integer", "description": "生成张数（2-4）"],
                "quality_reason": ["type":"string", "enum":["draft","simple_visual","simple_edit","detailed_layout","identity_sensitive","brand_accuracy","complex_edit","final_delivery"], "description":"内部路由理由：草稿/简单视觉/简单改色可配fast；复杂版式、身份保持、品牌精确、复杂编辑或终稿配high。不得只按海报/名片类别选档。"],
                "quality_tier": [
                    "type": "string",
                    "enum": ["fast", "high"],
                    "description": "画质档位。组图默认 fast（更快更省）；整套是印刷级物料时才用 high。",
                ],
            ],
            "required": ["prompt"],
        ],
    ]

    /// 4 工具注册表（仿 Harness 的插件契约表：新增能力只加一项）
    static let imageToolPlugins: [(name: String, definition: [String: Any])] = [
        ("image_generate", imageGenerateFunction),
        ("image_edit", imageEditFunction),
        ("image_decompose", imageDecomposeFunction),
        ("image_series", imageSeriesFunction),
    ]

    /// 自定义文档生成工具定义：让 AI 直接产出可下载的 Word/PPT/Excel/PDF
    static let createDocumentFunction: [String: Any] = {
        let parameters: [String: Any] = [
            "type": "object",
            "properties": [
                "format": [
                    "type": "string",
                    "enum": ["word", "ppt", "excel", "pdf"],
                    "description": "要生成的文件类型：word=Word 文档，ppt=PPT 演示，excel=Excel 表格，pdf=PDF",
                ],
                "filename": [
                    "type": "string",
                    "description": "文件名（含中文，不含扩展名），如「2026年经营计划」",
                ],
                "title": [
                    "type": "string",
                    "description": "文档标题",
                ],
                "theme": [
                    "type": "string",
                    "enum": ["business", "vivid", "formal", "academic"],
                    "description": "视觉主题：business=商务深蓝（默认）、vivid=彩色活泼（营销/活动）、formal=公文红头（法务/通知）、academic=学术严谨（报告/白皮书）",
                ],
                "content": [
                    "type": "string",
                    "description": "正文，使用 Markdown：# 一级标题、## 二级标题、- 列表项。PPT 用 --- 分页，每页第一行是标题；Excel 用 Markdown 表格。",
                ],
            ],
            "required": ["format", "filename", "content"],
        ]
        return [
            "name": "create_document",
            "description": "生成可下载的办公文件（Word / PPT / Excel / PDF）并存入资料库。当用户要求「整理成文档」「做成 PPT」「导出成 Word/Excel」「生成报告」时调用。调用后不要再重复输出正文，只做简短说明。",
            "parameters": parameters,
        ]
    }()

    static let searchLibraryFunction: [String: Any] = [
        "name": "search_library",
        "description": "检索用户上传的本机专业资料，未命中时明确说明。",
        "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]
    ]

    static func definitions(policy: EffectiveToolPolicy, capability: ExpertCapability, includeSearch: Bool) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for plugin in plugins where plugin.id != "generate_image" && policy.permits(plugin.id) {
            var schema: [String: Any]
            switch plugin.id {
            case "recall_history": schema = recallHistoryFunction
            case "web_search": guard includeSearch else { continue }; schema = webSearchFunction
            case "render_chart": schema = renderChartFunction
            case "image_generate": schema = imageGenerateFunction
            case "image_edit": schema = imageEditFunction
            case "image_decompose": schema = imageDecomposeFunction
            case "image_series": schema = imageSeriesFunction
            case "search_library": schema = searchLibraryFunction
            case "expert_skill": schema = expertSkillFunction(capability)
            case "create_document":
                schema = createDocumentFunction
                var parameters = schema["parameters"] as? [String: Any] ?? [:]
                var properties = parameters["properties"] as? [String: Any] ?? [:]
                properties["format"] = ["type": "string", "enum": policy.docFormats]
                parameters["properties"] = properties; schema["parameters"] = parameters
            default: continue
            }
            result.append(["type": "function", "function": schema])
        }
        return result
    }
}
