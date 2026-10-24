# GitHub Skill / Workflow 候选评估

> 核验日期：2026-10-24 · 数据来源：GitHub REST API（仓库元数据 + 默认分支最新 commit）。
> **本轮结论一律是「只借鉴方法，不引入代码」**：没有任何一个候选完成了"逐个目录核许可证 + 审脚本 + 断依赖"的引入级审查。
> 因此下列 `accept / adapt / reject / blocked` 中的 `adapt` 只允许用于**改写方法论与结构**，不允许复制代码或执行其安装脚本。

## 1. 评估矩阵

| # | 仓库 | 许可 | Stars | 最近提交 | 快照 commit | 结论 | 允许的用法 |
|---|---|---|---|---|---|---|---|
| 1 | [anthropics/skills](https://github.com/anthropics/skills) | **无 SPDX 标识（许可待逐目录核）** | 183.4k | 2026-10-09 | `dbd4588f9e10` | **blocked**（代码）；`adapt`（格式） | 只参考 `SKILL.md` 的组织方式：任务边界、触发条件、输入输出、示例。**不得复制任何目录内容**——仓库自述含不同许可状态的子目录 |
| 2 | [vyralcontent/content-skills](https://github.com/vyralcontent/content-skills) | MIT | 167 | 2026-06-22 | `349e495d9702` | `adapt` | 参考 hook / script / caption 的分类与自检维度，重写成本项目的中文规范（已落地到 `05-short-video-skill.md`） |
| 3 | [SinKry/viral-video-studio-skill](https://github.com/SinKry/viral-video-studio-skill) | MIT | 1 | 2026-07-06 | `e2a53c633bf2` | `blocked`（依赖） | 其描述涉及视频下载/抽帧/字幕提取/外部表格写入，本项目**没有**这些执行链，且未经安全审查；只允许参考"拆解维度"这一层方法论 |
| 4 | [ericosiu/ai-marketing-skills](https://github.com/ericosiu/ai-marketing-skills) | MIT | 3.7k | 2026-09-22 | `8088e1a16780` | `adapt`（方法论） | 参考营销流程的检查门与复盘结构；不引入其脚本（含外部 API / 自动化操作） |
| 5 | [open-agent-craft/awesome-agent-skills](https://github.com/open-agent-craft/awesome-agent-skills) | MIT | 3 | 2026-06-12 | `178e9656e4f7` | `adapt`（索引） | 仅作为继续发现候选的索引；其"推荐/成熟"标签是维护者观点，不等于本项目结论 |
| 6 | [linearclock/marketing-skills](https://github.com/linearclock/marketing-skills) | Apache-2.0 | 0 | 2026-07-09 | `1ff53d7889ae` | `adapt`（方法论） | 参考 7 个学科的覆盖面做"场景清单"查漏；Apache-2.0 若真要引代码需保留 NOTICE，本轮不引 |

> Star 数只反映关注度，**不是**质量或安全结论。`SinKry/...` 仅 1 star、`linearclock/...` 0 star，样本极小，任何"效果好"的自述都不作为依据。

## 2. 每个候选的强制度量（未完成即不可引入代码）

| 检查项 | 状态 |
|---|---|
| 固定 commit + 采用文件清单 | ✅ 已记录 commit（见上表），文件清单未列（本轮不引入） |
| LICENSE 与目录级许可 | ⚠️ 仅取到仓库级；anthropics/skills 仓库级无 SPDX 标识 → 直接阻塞 |
| 依赖 / 脚本执行行为 | ❌ 未逐行审 |
| 网络请求 / 遥测 / 凭证读取 | ❌ 未审 |
| 是否上传用户内容 | ❌ 未审 |
| 与 Swift/CloudBase 运行时兼容性 | ❌ 未验证（其载体多为 `SKILL.md` + 脚本，本项目是 Swift 客户端 + 云函数） |
| 正/负例测试与收益对比 | ❌ 未做 |

**结论：本轮不新增任何第三方依赖，不引入任何外部脚本。** 上表 `adapt` 项的实际产出全部是**用中文重写**的规范文档与本项目自有实现（见 §3）。

## 3. 实际借鉴了什么（可追溯）

| 借鉴点 | 来源 | 落地位置 |
|---|---|---|
| Skill 应写清「触发正例/反例、必需输入、输出结构、质量检查」 | anthropics/skills 的组织方式（格式层） | `03-skill-schema.md` |
| 短视频脚本的分层：钩子 / 主体 / 字幕 / 发布配套 | vyralcontent 的分类法 | `05-short-video-skill.md`、`ExpertSkills.json` 的 `short_video` 工作流 |
| 拆解对标视频的维度（钩子机制、节奏、转化设计） | SinKry 的方法描述（仅概念） | `short_video` 第三个开场白与 workflow 第 3 步 |
| 营销流程要有"检查门"而不是直接产出 | ericosiu 的流程结构 | `04-routing-policy.md` 的"质量门最多修订一次" |
| 场景清单查漏（内容/研究/销售/招聘/知识问答） | linearclock 的学科覆盖 | `04-routing-policy.md` 的场景路由表 |

## 4. 若将来要真正引入某个仓库，前置条件

1. 选定 commit，列出**实际采用的文件**（不是整仓）。
2. 逐目录核许可证，保留所需声明文件（MIT/Apache-2.0 各有要求）。
3. 在隔离环境读完全部脚本，记录网络请求、文件读写、凭证读取。
4. 写适配层（把 `SKILL.md` 的结构映射到 `ExpertSkill` + `ExpertCapability`），**不引入第二套运行时**。
5. 用 `04-routing-policy.md` 的评测集跑对照：同题、同模型、同预算，比较质量/时延/成本。
6. 功能开关 + 回滚路径，先小流量。
7. **任何一步缺失 → 结论保持 `blocked`。**
