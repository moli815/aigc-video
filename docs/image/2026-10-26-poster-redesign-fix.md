# 图片链路修复记录（2026-10-26）

> 关联设计：`BossAI/ARCHITECTURE-REFACTOR-PLAN.md`（A 阶段：图片请求契约）
> 本文记录**这一次**修了什么、为什么这么修、改在链路的哪一层，以及验证到哪一步。
> 原则：每项能力一条链路，改动只落在该链路的**契约层**，不在执行器里加分支、不加防御性 try/catch。

## 1. 现象（真机截图）

用户对一张"城市安全解决方案"海报说：「重新设计一下这张海报，不要蓝色科技风了，要动漫风格」。

结果：产出与输入**几乎同版式**（同样的穹顶、同一排图标、同样的城市天际线），只换了天空色调；
标题区出现**模型画的乱码小字**。

两件事都不是"模型不够强"，是请求契约没把话说到位。

## 2. 根因

### 2.1 重设计约束只说"允许"，没说"必须、且不许复刻"

`bf-image` 的 `REFERENCE_CONSTRAINTS` 原文：

> 把输入图作为主题、主体和关键信息参考，按用户要求重新设计整张作品；允许重新安排构图、版式、颜色和风格……

对模型来说这是**许可**，不是**要求**。最省力的解就是"照着参考图重画一遍、把配色动一动"——
这正是截图里的结果。缺的是三句硬话：不许复刻版式、用户新风格优先、用户明确否定的风格不得出现。

### 2.2 精确文案被服务端塞回底图 prompt

`bf-image` 里有一段 `missingCopy` 逻辑：把 `structured.text` 里 prompt 未包含的文案
**追加进底图 prompt**（`【需准确呈现的原文】`）。

而客户端在"文字密集"路径上要求**底图无字**（文字由 `TextOverlayRenderer` 画一次）。
两边同时生效的结果：底图被模型画一遍字（小、糊、乱码），排版层再叠一遍。
截图标题区的乱码就是这个。

### 2.3 附带：reference 走了低质量档

`resolveTier` 对 `.reference` 返回 `auto`，重设计成品直接吃默认档，细节明显掉。

## 3. 修法（改在哪一层）

不改执行器、不加分支，只动两处契约：

| 层 | 文件 | 改动 |
|---|---|---|
| 服务端任务边界 | `cloudfunctions/bf-image/index.js` | `REFERENCE_CONSTRAINTS` 改为硬约束（重做版式/新风格优先/禁止复刻/否定项不得出现）；新增 `NO_TEXT_CONSTRAINTS`；新增 `overlayMode`（`text_mode=overlay` 时**不再**追加 `missingCopy`，并强制无字）；`flat_artwork` 且无任何精确文案时同样强制无字 |
| 客户端请求契约 | `ImageProviderRequestCompiler.swift` → `ImageService.swift` → `ChatViewModel.performImageGeneration` | 新增 `textMode` 透传：`context.needsTextOverlay == true` 时置 `overlay`，写进 hosted envelope 的 `text_mode` |
| 客户端档位 | `ImageTaskPlanner.resolveTier` | `.reference` → `high`（重设计是成品，低档掉细节） |

**为什么放在这三层，而不是在 `runLoop` 里判断**：
`runLoop` 只该负责"这一轮的编排"；"底图必须无字"是图片任务的**边界语义**，
和 `EDIT_CONSTRAINTS` / `REFERENCE_CONSTRAINTS` 是同一类东西，必须由服务端的任务策略统一表达。
一旦把它写进执行器，就会变成第二个事实源——正是上一轮花了 3 小时才收敛掉的那种结构。

## 4. 验证

- `tests-backend/image-pipeline-architecture.test.js` 新增 4 条契约：
  1. reference 重设计必须含"必须重新设计整张作品 / 不复刻布局 / 新风格优先 / 否定项不得出现"；
  2. `text_mode=overlay` 时不得追加 `missingCopy`，且必须拼入 `NO_TEXT_CONSTRAINTS`；
  3. 客户端三跳（compiler → service → viewModel）必须把 `text_mode` 透传；
  4. `.reference` 必须走 `high`。
- `ImageProviderRequestCompilerTests` 新增 `testHostedEnvelopeCarriesTextModeForOverlay`。
- 后端全量：**275 条通过**。
- `bf-image` 已部署到测试环境 `xmy-test-d5g8c0xcifcefcfd5`
  （部署前补了 `scf_bootstrap`，缺它会让 CLI 卡在交互提问）。

## 5. 仍然不能保证的

- **"不复刻"是约束，不是保证**。模型仍可能画出高度相似的构图；要判定只能用固定素材做视觉回归。
- 同宽高比内移动/裁掉主体，几何校验看不出来（`isAspectBroken` 只比画布比例）。
- 海报的"好看"是审美问题，代码只能保证：版式重做、无字底图、成品文字由排版层绘制、走高质量档。
