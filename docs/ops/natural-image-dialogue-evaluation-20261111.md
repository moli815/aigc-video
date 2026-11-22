# 口语多轮作图验证（2026-11-11）

## 背景与范围

用户指出上次手写最终prompt过于精准，不能验证真实使用。本次改为先认识公司、分开发Logo与平台、穿插毛利和报销问题、纠正业务层级、过时活动不得沿用，最后只说“按刚才聊的做张交流会上发的海报”。参考图与事实散在历史中，不替Agent写最终标题/构图/配色。

这是线上会员接口的真实前置模型+真实图片请求，以及有明确边界的旧客户端协议适配测试，不是真机E2E。只下发从原Swift manifest解析的3种图片/召回工具，身份与能力系统块采用摘录。SwiftData与预览压缩未完整复刻；iOS准确排字及原件合成不在服务器冒充执行。

## 真实执行

- 首轮19次聊天+2次`/api/memories/extract`+2张Pro图；纠正适配轮4次聊天+2张Pro图，共23聊天/4图。2个临时会员均删除，客户数据与线上策略未改。
- 首轮漏模拟`imageReferenceCandidates`的历史承接，以及图片UUID到私有asset的同步映射，导致A前两次参数失败。该部分诊断作废，不作为产品问题。纠正轮真实`/api/sync/v2/push`3确认/0冲突，并复用已实际产生的前10轮对话，不重复付费编造历史。
- 纠正轮仍有0参考图生成：A没有source/library_refs/历史append；B同批调用先image_generate再recall_history。本测试在首图停止，不能断言旧包之后绝不补救；但首图已经先收费，不能算依赖正确。
- 最高实际prompt 17,842 tokens；消息文本最大15,808字符（脱敏图片字节后），未宣称覆盖全窗口或40轮压缩边界。
- 试验账号扣费合计¥5.2197824：图片¥4.84、聊天¥0.3797824；这是App内部计费口径，不是平台发票，2次抽取未独立核算。

## 失败、源码定位与修复方式

| 失败 | 源码/证据 | 服务端优先方案及验收 |
|---|---|---|
| 大屏原件未选进请求 | A纠正轮imageArgs及resolvedReferences为空；手机`imageReferenceCandidates`仅提供候选，不代表Agent会选；`finalizeImageCalls`不验证用户要求的素材依赖是否完整 | 准备阶段绑定明确资产，校验可用性/账号，再准许执行图片；历史召回和依赖它的生成不并发完成。按真实上游输入ID/hash验收 |
| 凭能力名扩写工程承诺 | A第7轮助手提出多协议/不改回路等细节；第11轮structured.text沿用，并不是用户确认 | 建事实来源账本，区分用户确认/建议/待核实，文案编译拒绝未确认技术承诺；不是把整篇都写成免责声明 |
| 长期记忆污染 | `handleMemoryExtract`仅说用户自身稳定事实，输入含助手全文；真实ops记住单笔报价、明日活动、助手的Logo16%与深色偏好 | 保持ops兼容，只抽用户确认稳定事实，临时项目加时效；不批量删历史、不把助手建议当用户偏好。真实多轮抽取更新前后对照 |
| 文档感与数字矛盾 | A463字，线上minChars420，实际PNG是会议图横幅+双栏长文+大量底部留白；小标题四环节却列五项。B386字原生图依然虚构屏幕 | 不以字数替代用途/风格决策；文案计数确定性校验；设计引擎须可执行风格与布局契约，同一口语需求/同文案实际成品对照后再启用 |
| Logo未完整验证 | A第12轮正确进入both+preserve_assets；`PreservedAssetWorkflow`与`BrandPlacementPlanner`在手机 | 保留原协议防双贴；本轮仅参数验证，不宣称抠图/落位像素与避让通过。必须改二进制的并入待出包 |
| 人物路径局部可用 | 首轮C两张当前附件按底图/人物顺序，真实Pro卷发/金边眼镜/开衫目视相近 | 分开验收人物、背景、文字和商业质量；不能借人物一项通过泛化所有链路 |

## 成熟参考、边界

- [agentevals](https://github.com/langchain-ai/agentevals)，已读trajectory/match.py与LICENSE：MIT，Python及TypeScript工具生态。借鉴工具/参数/顺序的轨迹评估方法；本轮未安装、未复制其代码，无新生产依赖，不能替代图片目视验收。
- [LangGraph workflow文档源码](https://github.com/langchain-ai/docs/blob/main/src/oss/langgraph/workflows-agents.mdx)：借鉴“依赖前置准备—执行—评价”划分，不把有依赖的素材召回与生成平行跑；未迁移运行时。
- 图片供应商官方契约及ComfyUI/InvokeAI研究沿用[前轮记录](commercial-benchmark-research-20261111.md)，不重复调用已完成付费基线。

## 代码、自检与状态

新增`natural-image-dialogue-contract.cjs`解析真实Swift schema、移植中文词法排序、严格解析来源；3条回归防测试脚本静默替模型补图。新增真实HTTP跑数与HTML渲染器。原两处静态测试随未发布候选源码形态变化失效，改成找到全部排字入口并执行实际任务边界表达式，保留旧路径断言，687/687通过。

未新增生产运行代码，未部署、未修改runtime、未出IPA。没有将失败图标为优化成品。首轮与纠正轮报告分开保留；没有ChatGPT新图基线（前轮内置生图网络失败）。本轮只完成测试方法重构与真实失败定位，以上修复方案尚未实施。

证据：[HTML](../../outputs/natural-image-dialogues-20261111-corrected/index.html)、[纠正轮JSON](../../outputs/natural-image-dialogues-20261111-corrected/report.json)、[首轮诊断](../../outputs/natural-image-dialogues-20261111/report.json)。后续发布必须从届时线上版本备份并校验ZIP，不能将本地未验收候选打包覆盖。
