# 真实大屏截图 → 海报「不真实」事故：诊断与优化台账

> **2026-11-11后续核验纠正**：此稿部分配置、版本、素材来源及“无日志”判断已过时或证据不足，保留原文供追溯，不作为当前实施依据。请优先读 [基于真实线上ZIP、客户账本/资产及CLS日志的核验报告](image-fidelity-investigation-20261111.md)，特别是第2、3、8节。当前确有Pro带图调用、文案审查/排版已启用；测试fixture重复电话不构成生产泄漏证据。尚未进行本次图片修复或配置切换。

> 北京时间 2026-11-11 10:0x · 基线 `e73d5e2` + 11-10 本地候选（**21:52 线上版本未变**）
> **本轮状态：只读诊断 + 方案，未改产品代码、未部署、未出包、未调用付费模型/生图。**
> 按用户长期要求：先出详细文档（位置 / 影响 / 原因 / 建议 / 优先级 / 验证方式 / 是否需 IPA），确认后再逐条实施并回填第 9 节；必须出包项只登记不实施。

---

## 0. 问题复现（两张图逐项对比）

| | 用户提供的图 1 | App 生成的图 2 |
|---|---|---|
| 性质 | **真实软件界面截图**，横屏约 1080×608 | AI 渲染的**竖版海报**，虚构场景 |
| 主体 | 深蓝科技风「智慧消安一体化平台」数据大屏：中国地图、省份浮层、左右数据面板、近一年新增设备柱状图、报警统计、隐患趋势曲线 | 一个**不存在的指挥中心房间**：曲面大屏、城市天际线、山峦、灯带、约 10 个剪影人员与工位 |
| 精确内容 | 顶部导航、设备数 1030945、报警数 323155、场所覆盖率 31.35%、各省份数字等真实 UI 元素 | 大屏内只有模糊的发光连线和假图表，**原界面一个像素都没保留** |
| 文案 | 界面内既有标签 | **模型编造**：「中防保全（苏州）科技有限公司」「城市综合安全 远程监控指挥中心」「立冬守护·全年无休」「智慧安消云平台｜消防物联监测…」「终端用户专属保险兜底：财产险…」「全国服务热线 400-7758-119」「江苏省太仓市上海东路168号17层」 |

用户只说「根据这个大屏的图生成海报」，**没有提供公司名、标题、电话、地址**。这些内容全部由模型凭空生成，属于事实编造，不只是「画得假」。

**诚实边界**：目前没有这次请求的线上日志（`hadImage` / `task_kind` / `tool_calls`），无法 100% 判定走的是「带图重设计」还是「图片根本没上传」。两条路径都会产生图 2，见第 2 节。

---

## 1. 证据、官方资料与成熟方案溯源

| 来源 | 结论 |
|---|---|
| 火山方舟官方《图片生成 API》(`https://www.volcengine.com/docs/82379/1541523`，2026-11-11 复核) | 5.0 pro/flash：单图生图、多图生图（2–10 张）、交互编辑（坐标/框选/箭头）、图层拆分；lite/4.5/4.0 支持组图。参数只有 `prompt`、`image`、`size`、`optimize_prompt_options`、`output_format`、`background`、`response_format`、`sequential_image_generation` 等。**没有任何 strength / similarity / fidelity / 保真度旋钮，官方也不承诺「保留原图像素」**。→ 不能靠调参数根治。 |
| 官方价格页（11-10 已核） | 5.0 pro 单图 ≤261 万像素 ¥0.30 / >261 万 ¥0.60；图层拆分另计。当前代码分界正确。 |
| GitHub `jiangge0804-crypto/image-style-transfer` | 把 `input_fidelity` 做成**显式一等参数**：`high`=在原图上做加法、最大保留原图；`medium`=保留构图重绘画风（默认）；`low`=允许重构画面。并用 `no text, no letters` 规避假字。→ 我们缺的正是这个意图档位。 |
| 工业级文字方案（CSDN 综述、dev.to 混合管线、skills.rest `text-in-image`、RottenWiFi） | 共识：**不要让图像模型负责「写字」**。可靠做法是「生成无字背景 → 用 SVG/Canvas/字体确定性叠字 → OCR 校验」，文案作为独立结构化字段、禁止 LLM 改写；`reserve-and-overlay` 与 hybrid pipeline（LLM 只出结构化元数据，代码负责网格与字形）。`content` 不允许被 LLM 改写或翻译。 |
| 同类产品 | Canva / Figma 类工具处理「上传截图做海报」时走模板排版，从不重绘截图；Ideogram / P-Image 等主打文字准确的模型也仍需人工复核，且属额外供应商。 |

---

## 2. 根因链（为什么「保真」这件事根本没有发生）

```
用户上传真实 UI 截图 +「根据这个大屏的图生成海报」
   │
   ├─(路径 A，主要)─────────────────────────────────────────┐
   │ 意图被判为「基于上传图重新设计整张作品」                  │
   │ → image_generate + source=attached                       │
   │ → ImageTaskPlanner.classify ⇒ task_kind = reference      │
   │ → bf-image REFERENCE_CONSTRAINTS 硬性「必须重新设计整张   │
   │   作品 / 不复刻布局 / 不套用像素保持」                    │
   │ → commercial-artwork 禁令「不得绘制表格、看板界面」        │
   │ → artwork_prompt 被 schema 设为必填且要求「人物、环境、    │
   │   材质、光线」的独立摄影场景                              │
   │ ⇒ 原截图被语义丢弃，模型另画一个指挥中心                   │
   └──────────────────────────────────────────────────────────┘
   │
   ├─(路径 B，同样致命)───────────────────────────────────────┐
   │ ImageReferenceResolver 短语表只认「根据图片/根据这张/基于  │
   │ 这张…」，**不认「根据这个大屏的图」** → source=none       │
   │ → 截图根本没上传 → 纯文生图                               │
   │ ⇒ 可解释结果为什么是竖版、且全盘虚构                      │
   └──────────────────────────────────────────────────────────┘
   │
   └─ 文案：structured.text 被 schema 设为必填，用户没给 → 模型自造；
      TextIntentDecider.needsOverlay 默认 false → 不走精确叠字；
      IMAGE_COPY_REVIEW / CHAT_GROUNDED_REVIEW 默认关闭 → 无事实审查
      ⇒ 公司名、标题、400 电话、地址全部编造
```

**五条互相叠加的直接原因**：

1. **系统里没有「截图即主视觉、只做加法」这条路径**。`TextOverlayRenderer.render` 的 base 是新生成图；`PreservedAssetWorkflow` 只服务 Logo/二维码且要求 `taskKind==edit`；`commercial-composer.finish` 的 background 也是新生成图。
2. **约束方向是反的**：`REFERENCE_CONSTRAINTS`（bf-image/index.js:1232-1237）明令「必须重新设计整张作品…不复刻参考图的布局」，只有 `image_edit` 才享有 `EDIT_CONSTRAINTS` 的保持语义。
3. **商业引导主动排斥 UI 截图**：`commercial-image-guidance.js:19` 写「而不是一张带乱码的风险矩阵或软件截图」；`commercial-artwork.js:12` 写「不得绘制表格、看板界面、文档页面」。
4. **`artwork_prompt` 被强制**：`image-tool-schema.js` 在 `commercial:true` 时把 `structured.text`、`design_brief`、`artwork_prompt` 设为 required，描述要求「物理主体、人物、环境」→ 逼模型另写摄影场景。
5. **文案没有事实门禁**：`commercial-copy-review` 只在 `structured.text` ≥420 字时审、默认 `IMAGE_COPY_REVIEW=0`、`CHAT_GROUNDED_REVIEW` 关闭、且审查器「不看参考图」。

### ⚠️ 必须如实说明：11-10 的 S0-1 改动让这个 bug 更糟

`docs/ops/expert-skill-audit-20261110.md` 的 S0-1 把「海报/配图/概念示意」统一改指 `image_generate`，并把 `both` 语义改为 `source=attached + source_indexes` 后禁用 `both`。其出发点是消除「提示词点名不可用工具」，但**副作用是把「基于上传图做海报」钉死在 `.reference` 重设计路径，取消了唯一带 `EDIT_CONSTRAINTS` 保持语义的 `image_edit` 可能性**。该改动目前**只在本地候选、未部署**，线上 21:52 版本不受影响；但必须在实施本轮修复时一并修正，不能带着它上线。

### 另一个讽刺的发现

图 2 里的 `400-7758-119` 恰好是本仓**评测 fixture**（`tests-backend/poster-incident-20261103.test.js:36`、`scripts/verify-image-design-policy-20261103.cjs:12,31`、`scripts/verify-poster-incident-20261103.cjs:17` 均断言「必须保留」）。更严重的是 `tests-backend/image-pipeline-architecture.test.js:104-134` **把「必须重新设计整张作品 / 不复刻布局」当作正向门禁固化下来**——现有测试不但没防住本 bug，反而在保护它。改动时这两处必须同步重写。

---

## 3. 按模块的问题清单

| ID | 位置（精确） | 影响 | 原因 | 优化建议 | 优先级 | 验证方式 | IPA |
|---|---|---|---|---|---|---|---|
| F-01 | `cloudfunctions/bf-image/index.js:1232-1237` `REFERENCE_CONSTRAINTS` | 直接命令丢弃原截图 | 把「带参考图」一律等同「重新设计」 | 新增 `task_kind=poster_from_screenshot`（或 `preserve_canvas`），此类跳过该约束，改用 `PRESERVE_CONSTRAINTS`（输入图即主视觉、保留界面/地图/数字/文字、不得替换为摄影场景、不得新增人物与房间） | **P0** | 离线断言新 task_kind 不拼接 REFERENCE_CONSTRAINTS；payload 契约测试 | 否 |
| F-02 | `cloudfunctions/bf-api/image-tool-schema.js:11-28` | 逼模型另写摄影场景、自造文案 | `commercial:true` 时 `structured.text`/`design_brief`/`artwork_prompt` 全 required | 对截图保真任务：把 `artwork_prompt` 降为可选、`structured.text` 改为「仅用户提供的文案，缺失则留空」，并禁止模型补写公司名/电话/地址 | **P0** | schema 契约测试 + 工具调用 fixture | 否 |
| F-03 | `cloudfunctions/bf-api/commercial-image-guidance.js:9,19`、`cloudfunctions/bf-api/image-design-policy.js:34,37,39` | 明确排斥软件截图、要求真实业务场景 | 为「避免乱码截图」写死的反向规则 | 增加例外：当用户上传的是**真实 UI 截图**时，界面本身即主视觉，禁止换成摄影/指挥中心场景 | **P0** | 注入文本断言含例外句；不误伤普通海报 | 否 |
| F-04 | `cloudfunctions/bf-image/commercial-artwork.js:12` | 禁令「不得绘制看板界面」与保真目标直接冲突 | 为「只画素材层、文字另行排版」设计 | 截图保真任务跳过 `compileCommercialArtwork`；其余任务保持原样 | **P0** | 分支契约测试 | 否 |
| F-05 | `cloudfunctions/bf-api/index.js` CHAT_RULES 16④/17、META_RULE_BUILTIN；`cloudfunctions/shared/image-delivery.js` DELIVERY_RULE | 把海报一律导向 `image_generate`（含 S0-1 回归） | 只按「是不是海报」分类，不看「输入是不是截图」 | 恢复「真实截图 + 要求保留 → `image_edit` / 保真合成」分支；海报不再一律 `image_generate` | **P0** | 提示词切片断言 + 对账测试同步更新 | 否 |
| F-06 | `BossAI/Services/ImageReferenceResolver.swift:20-26,35-36` | 「根据这个大屏的图」不认 → `source=none`，截图没上传 | 短语白名单过窄 | 改为意图识别而非穷举短语；**兜底规则应为「本轮有附件就默认 attached」**，而不是默认 none | **P0** | source 解析矩阵（含本例原句） | **是** |
| F-07 | `BossAI/Services/TextOverlayRenderer.swift:130-144` `TextIntentDecider.needsOverlay` 默认 false | 文字由模型画 → 编造与错字 | 只在「逐字/必须准确」才叠字 | 截图保真任务默认 `text_mode=overlay` + `NO_TEXT_CONSTRAINTS`；文案走确定性排字 | **P1** | 客户端单测 + 服务端强制兜底 | **是**（服务端可先兜底） |
| F-08 | `BossAI/Services/ImageTaskPlanner.swift:181-194`、`:112-141`、`ChatViewModel+Streaming.swift:563-571` | 带图 `image_generate` 恒判 `.reference`；仅 refs>0 才锁原图比例 | 无保真意图档位 | 引入 `input_fidelity: high/medium/low`（参考成熟方案），默认对「截图+海报」给 high | **P1** | 意图矩阵单测 | **是** |
| F-09 | `cloudfunctions/bf-api/commercial-copy-review.js:34-41`；`IMAGE_COPY_REVIEW=0`、`CHAT_GROUNDED_REVIEW=false` | 编造的电话/地址无人拦截 | 审查默认关、阈值 ≥420 字、不看参考图、不查 `prompt` 全文 | 灰度开启；把虚构联系方式检测扩展到 `prompt`/`artwork_prompt`/`structured.text` 全文；无用户来源的联系方式一律拒绝 | **P1** | 故障注入：只给截图不给文案时不得出现 400/地址 | 否 |
| F-10 | `cloudfunctions/bf-image/commercial-composition-runtime.js:37-55`、`commercial-composer.js:15-23,61-70`；`IMAGE_COMPOSITION_POLICY={}` | 已有服务端排版能力却以「新生成图」为底 | 设计目标是「模型画素材 + 服务端排字」 | 增加「以上传截图为底图」的 `preserve` 模式：不调生图模型或只做边缘扩展，直接确定性叠标题/品牌条/边框 → **像素级保真 + 文字零幻觉** | **P1（根治）** | 固定截图做像素/感知哈希比对；文案逐字校验 | 否（服务端） |
| F-11 | `tests-backend/image-pipeline-architecture.test.js:104-134`、`poster-incident-20261103.test.js:36` 等 | 测试在保护 bug、把编造电话当 fixture | 旧事故（截图被当成乱码）修复时把「必须重做」写成正向断言 | 同步重写：拆成「模糊/低质截图 → 允许重做」与「真实 UI 截图 → 必须保真」两套；`400-7758-119` 不再作为「必须保留」断言 | **P0** | 新增保真场景用例必须能检出图 2 这类失败 | 否 |
| F-12 | 全链路日志 | 无法定位本次到底走 A 还是 B | 缺 `hadImage`/`task_kind` 诊断 | 在 bf-image 记录非敏感 `hadImage / taskKind / source / textMode / fidelity`；App toast 显示真实错误码 | **P1** | 构造两条路径各跑一次，日志可区分 | 否（服务端）/ 是（toast） |

**共同缺口**：没有任何一条测试断言「上传的 UI 截图必须保留在成品中」；几何校验只比宽高比（`BossAI/ARCHITECTURE-REFACTOR-PLAN.md:73` 已承认「比例相同不等于内容完整」）；`edit_similarity_observed`（bf-image/index.js:2144-2151）只在 `edit` 且 `diagnostic_only`，不做拦截。

---

## 4. 优化方案（供选择，均未执行）

### 方案 A：服务端止血（免出包、可当天上线，改善但不保证像素保真）
- 实施 F-01～F-05、F-09、F-11、F-12（服务端日志）：新增截图保真意图与 `PRESERVE_CONSTRAINTS`，放宽 schema 强制字段，修商业引导例外，修 S0-1 回归，开启文案审查灰度，重写保护 bug 的旧测试，补保真对账测试。
- **成本**：一次服务端发布；无模型切换、无额外调用（审查灰度会产生少量额外对话调用）。
- **风险**：Seedream 是生成式模型，官方**没有保真度参数**，即使加了「必须保留」的提示词也只能降低重绘概率，**无法保证原图像素不变**。必须如实告知用户「改善，不保证」。
- **回滚**：新 task_kind 走独立开关，关闭即回旧路径；S0-1 回滚为 11-10 21:52 线上提示词。

### 方案 B：确定性保真合成（根治，服务端为主，长期最优）
- 在方案 A 基础上实施 F-10：`IMAGE_COMPOSITION_POLICY` 增加 `preserve` 模式，以**用户上传截图为底图**，服务端用字体/SVG 叠标题、品牌条、边框与留白；模型不再重绘主体，文字由代码渲染。
- 横屏截图 → 竖版海报用「扩展画布 + 上下留白」而非裁剪或重绘；文案只取用户提供的结构化字段，缺失就留空并追问，绝不自动补公司名/电话/地址。
- **成本**：服务端排版开发 + 字体资源与授权核对 + 计费口径（不调生图模型时如何计费）；可能需少量客户端适配（成品返回与预览），但主体可在服务端完成。
- **风险**：字体在云函数环境的可用性、中文字形版权、画布扩展的视觉品质；需要固定素材视觉回归。
- **收益**：**100% 保留原截图、文字零幻觉、结果可复现**，符合工业共识（`reserve-and-overlay` / hybrid pipeline）。

### 方案 C：换模型或加能力（不推荐作为首选）
- 评估 Seedream 5.0 pro 的「交互编辑 / 图层拆分」或 Ideogram 类主打文字准确的供应商；或加 `input_fidelity` 档位（F-08）。
- **成本/风险**：需真实 A/B 与成本测算、可能需出包、供应商切换影响计费与稳定性；且仍不解决「不该重绘」的意图错误。仅作为 B 的后续增强。

**建议顺序**：A 先止血并修掉我自己引入的回归 → B 根治 → C 视成本再评估。**A+B 都优先服务端，不为出包单独动作。**

---

## 5. 必须出包事项（集中登记，本轮不实施）

| ID | 模块 | 修改内容 | 依赖 | 风险 | 溯源 |
|---|---|---|---|---|---|
| C-10 | `BossAI/Services/ImageReferenceResolver.swift` | 短语白名单改意图识别；有附件默认 `source=attached`；补「根据这个大屏的图」等矩阵 | 与服务端 F-05 提示词配套 | 误把无关附件当参考图 → 需 fail-closed 校验 | 本文件 F-06 / 路径 B |
| C-11 | `BossAI/Services/ImageTaskPlanner.swift`、`ChatViewModel+Streaming.swift` | 引入 `input_fidelity` 档位，`.reference` 不再硬编码 | 依赖 C-10 | 影响所有带图生图意图 | GitHub `image-style-transfer` 的 high/medium/low |
| C-12 | `BossAI/Services/TextOverlayRenderer.swift`、工具 schema | 截图保真任务默认 `text_mode=overlay`，`preserve_ui` 参数，以 `refs.first` 为 base | 依赖 F-10 服务端排版 | 与旧包 `needsOverlay=false` 行为冲突，需版本门控 | 工业 `reserve-and-overlay` |
| C-13 | `BossAI/Services/PreservedAssetWorkflow.swift` | 扩展 `preserve_canvas` 任务类型 | 依赖 C-11/C-12 | 与 Logo 合成路径共用，需隔离 | 本文件 F-01 |
| C-14 | `BossAI/Services/APIError.swift` 等（11-03 已有未提交代码） | 断流中文错误解析出包 | 与 ChatGPT 另一路改动需定「一起提交还是等对方先落」 | 低 | `docs/RELEASE-BACKLOG.md` B-01～B-16 |

以上与既有 B-01～B-16、S1-1～S1-7 合并，等用户明确批准一次 IPA 构建时统一执行、核查与追溯。

---

## 6. 验证方式（离线优先；真实视觉回归需另行批准额度）

```
# 契约/故障注入（无付费调用）
node --test tests-backend/*.test.js
node --test tests-backend/screenshot-fidelity-contract.test.js   # 待新增
node --test tests-backend/tool-prompt-alignment.test.js          # 同步更新 S0-1 断言
node --check cloudfunctions/bf-{api,image}/index.js && git diff --check
```
- **新增必测**：① 只给真实 UI 截图、不给任何文案时，`structured.text`/`prompt`/`artwork_prompt` 不得出现电话号码、地址、公司名；② `task_kind=poster_from_screenshot` 的 provider prompt 必须含「保留原界面」且不含「必须重新设计整张作品」；③ `source` 解析矩阵包含「根据这个大屏的图生成海报」；④ 固定截图像素/感知哈希比对（方案 B）；⑤ 旧测试 `image-pipeline-architecture.test.js` 的正向断言已拆分。
- **仍需但尚未做**：真实模型 A/B、固定素材视觉回归、真实 CloudBase 并发、真实 HTTP/SSE、浏览器端到端、Xcode/真机、生产发布与回滚演练。
- **禁止声称**：与 ChatGPT 6 对齐、画质提升、「已保证保真」。

---

## 7. 本轮如实清单

- 已做：两张图逐项核对、全链路只读审计、官方 API 能力复核、GitHub/社区成熟方案检索、关键代码 Grep 复核、本文交付。
- 未做：**没有改任何产品代码**、没有新增测试、没有部署、没有出包、没有触发 CI、没有调用付费模型或生图、没有改动客户额度。
- 已知但未定位：本次请求究竟走路径 A 还是路径 B，缺线上日志，见第 0 节诚实边界。
- 主动承认：11-10 S0-1（本地候选，未部署）对本 bug 有负面影响，实施时必须一并修正。

---

## 8. 待用户拍板的历史未决项（不擅自决定）
海报是否允许模型自写整套中文文案（10-27）、`reference` 重设计是否强制无字（10-27）、11-03 两路改动提交顺序、C1/C2 与 D1/D2 路线、是否批准一次 IPA 构建。

---

## 9. 逐条实施结果

| ID | 状态 | 说明 | 上线 / 出包 |
|---|---|---|---|
| 只读诊断（第 0～8 节） | **已完成** | 两张图逐项核对、全链路审计、官方 API 复核、GitHub/社区成熟方案检索、关键代码 Grep 复核、本台账交付 | 否 / 否 |
| **HTML 视觉方向预览** | **已交付（用户本轮选择）** | 用户选定「先出 HTML 排版预览」；产出 `docs/ops/screenshot-poster-fidelity-preview.html`（自包含单文件，原图以 303,284 字节原始 JPEG base64 内嵌，不调用模型）。提供方案 A 品牌加框 / B 沉浸式满幅 / C 仪表框科技风三个方向，可点击选中。三条硬规则：原图 100% 保留不重绘、文案只取原图或用户且缺失留空、文字由排版引擎输出。模板 `outputs/poster-fidelity-preview.template.html` 可替换素材重生成 | 否 / 否 |
| F-01 ~ F-12 | **待用户选定方向后实施** | 产品代码零改动；预览不等于功能落地 | — |
| 方案 A / B / C | 待选择 | 建议 A 先止血 + B 根治，均为服务端优先 | — |
| C-10 ~ C-14 | 登记待出包 | 与 B-01～B-16、S1-1～S1-7 合并，等一次统一 IPA | 需 IPA |

**本轮验证**：预览页生成后校验 `placeholderLeft=false`、`hasDataUri=true`、3 张海报卡片齐全，文件 418,172 字节。未运行产品测试（未改产品代码）；未部署、未出包、未触发 CI、未调用付费模型或生图、未改动客户额度。
