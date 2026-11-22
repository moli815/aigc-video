# 2026-11-17 用户、会话与并发隔离审查

## 范围与结论

客户担心用户增长后记忆、对话及费用串账号。本轮沿真实源码核查鉴权、同步事务、历史恢复、素材归属、请求上下文、调用台账和缓存。只改兼容旧 App 的 bf-api；App、员工端、网页、bf-image 和 runtime 不动。

**候选已验证，发布状态见文末。** 没有证据证明发生过客户之间的实际泄露；发现缓存缺少强制账号命名空间、请求上下文使用 enterWith，以及会员跨周期清零的陈旧快照风险。后两者分别是并发边界加固和已可复现的费用计数问题，不能都说成已发生串号。

## 已核对的隔离边界

| 链路 | 实际实现与验证 |
| --- | --- |
| 鉴权 | requireMember 验签后读取 sub 对应账号，校验 active、pwv、sv、会员；不信任 body.accountId。 |
| 云同步 | sync-v2 的记录键为 SHA256(owner\|kind\|refId)，版本头也按 owner；同 UUID 的两账号记录不共享键。push 事务、版本冲突、删除墓碑和父会话归属均保留。 |
| 拉取 | query 绑定已鉴权账号，客户端传另一 accountId 不会改变读取归属。 |
| 历史恢复 | confirmed-image-context 的查询/每行/会话元数据都检查 owner；须两条原文锚点且唯一会话，排除未来/删除记录。两个会话命中相同锚点时不猜。 |
| 图片引用 | 私有 asset/file 的读取、签名和重试重新验证 owner；不存在通过“最近上传”借用别人的图。 |
| 计费 | model-call-ledger 捕获请求上下文，orderId 包含账号；相同客户端 requestId 的两账号订单也不同。supplier_cost 结算本身使用事务。 |
| App 源码 | MemoryService 按 ownerKey 读写，并在异步写回前检查启动账号；这是源码证据，不等于确认客户二进制与工作区逐字一致。 |

## 本轮改动及根因

1. **短问答缓存**：旧键只包括问题、档位、system 摘要，依赖“我/之前”等词过滤个性化；这不构成严格租户隔离。现在调用处显式传 auth.sub，键使用账号/问题/档位/摘要组成的 SHA256，新命名空间 ca2_；无账号不缓存，旧全局条目自然不再命中。不清客户聊天，不增加新表。
2. **异步请求上下文**：HTTP 入口由 enterWith 改为 run。账号、requestId、调用尝试 Map 被各请求异步作用域包住；注册其他同事件监听器不会继承本请求上下文。不把 Node 官方列出的潜在传播行为夸大成实际已经串号。
3. **跨会员周期计数**：旧 ensurePeriod 用入参旧快照判断后直接清零。A 请求完成重置并记入新费用后，B 持旧快照可能再清零。现在仅在疑似跨周期时进入事务，重读账号、重新检查锚点，已更新则返回实时用量；正常周期不多查数据库。事务失败不绕过为非事务写入。

## 候选验证

- Node18 全量 **950/950**；相对原941新增9项；不是950个生产用例。
- 新9项也对**从生产 ZIP 窄改后的实际候选 index.js**执行，而非仅测工作区。
- 200 个并行 HTTP 请求：真实路由包装、替代业务 handler；两账号/rid/事件监听器边界通过。鉴权 handler 是测试替身，不冒充200次真实会员模型调用。
- 200 次双账号同步写入、相同 UUID、分页/删除/版本冲突；100 次并行长期记忆筛选；100 次模拟供应商调用真实台账模块；相同 requestId 订单隔离。
- 跨周期旧快照重放、20次并发重置、正常周期零额外读取、账号B不受影响。
- 精确候选完整旧 HTTP JSON/SSE 及最新纠正透传通过；供应商/数据库为夹具，无付费模型。
- bundle --check、语法、diff --check、SEC001 人工审查通过。AUTH001 的 SDK getSession 规则不适用于本项目自建签名会员守卫，不替换既有鉴权契约。

## 容量与尚未解决的边界

**隔离正确不等于容量无限。** 云端读取到 API256MB/300秒，image1024MB/300秒；GetFunction 的 InstanceConcurrencyConfig 为空，GetReservedConcurrencyConfig 的 ReservedMem 也为空。它们不能解释成“可无限扩容”或“并发配额为0”。官方文档说未启用实例多并发通常单实例一次处理一个请求，但本次响应未提供完整有效配置，尚不能据此给出本环境承诺值。

后续容量验收必须在不影响客户的隔离环境/函数副本里，逐级测入口速率、活跃请求、p95/p99、OOM、数据库事务冲突与供应商429，结合环境/区域总并发和供应商 RPM 才能估算可服务用户。不要在现有生产上直接压200次付费出图，不直接把单实例多并发调到100。排字器是实例内串行队列，尚无整站队列/准入容量的压力验收。

**同账号多项目语义污染仍是独立待办**：account-context.selectFacts 在 business 类任务下允许较宽的账号级长期记忆；旧 App MemoryService 把近期 fallback 也注入，MemoryItem.source 是会话标题，缺少可信项目ID。长期公司身份/偏好本来允许跨会话共享；项目数据与临时电话则不能无差别套用。现在不能保证“用户随口说做海报”必定识别项目。后续应分账号长期资料/项目事实/本会话状态，用可验证来源和明确项目绑定筛选；没有唯一证据则不填无关项目资料，不用模型猜归属。客户端项目ID、memory sourceConversationId 和取消令牌统一化记到下次出包；此轮不改 Swift。

遗留非 supplier_cost 的日/周首次记账仍有先读后写分支；本轮不改费率或切换模式，不拿 supplier_cost 的事务保证覆盖所有历史模式。大面积原生文字候选也仍未全员上线，见 dense-copy-repair-20261117.md。

## 官方和成熟实现参考

- [Node AsyncLocalStorage 源码文档](https://github.com/nodejs/node/blob/main/doc/api/async_context.md)：官方建议优先 run，enterWith 会延续到后续事件处理器。运行时本项目Node18已实测该API；无新依赖。
- [LangGraph 官方 memory 文档源码](https://github.com/langchain-ai/langgraphjs/blob/main/docs/docs/concepts/memory.md)及[store 文档](https://github.com/langchain-ai/docs/blob/main/src/oss/langgraph/stores.mdx)：会话状态按 thread、长期记忆按 user namespace；仅参考分层和归属原则，不迁入 LangGraph、不把其 README 当性能证明。未复制其运行代码，无新增许可证/运行时负担。
- [腾讯云单实例并发管理](https://cloud.tencent.com/document/product/583/123892)：并发配置属于资源/性能选择，不能代替业务数据的账号隔离。不自行更改现有配置。

## 发布与回滚

备份：outputs/tenant-isolation-20261117/before-bf-api.zip，18:36:05基线 SHA df45f292087815d7a4a072911b85c8bfd689bd23b83446bacca376c7b24e65d7；image12:57:46原包亦备份。候选只更改 index.js；5633项文件，依赖0变更。不从工作区打包。

发布脚本：`node scripts/release-tenant-isolation-20261117.cjs deploy`；要求候选包测试、全量回归及产物门禁通过，比较当前线上时间+下载hash后才允许覆盖。官方 UpdateFunctionCode InstallDependency FALSE，下载逐项核对并验证 Active。`verify` 做健康及 image 未更改检查。随后 `verify-tenant-isolation-live-20261117.cjs` 用2个临时会员做有界云同步与会员门禁，清除测试账号及同步数据，不调用付费模型、不把费用记客户。

回滚：`node scripts/release-tenant-isolation-20261117.cjs rollback`，仅允许线上仍等于本次部署时间+hash时恢复新鲜before包；有后续版本则拒绝覆盖。只恢复本次 API 代码，runtime/网页/image 不回退。回滚脚本已审查，未执行生产回滚演练。

当前候选已完成本地与精确产物验证；实际部署及云端结果追加如下，不能以此行当发布凭证。

### 23:11 北京时间：已上线并完成真实云端验证

- API **2026-11-17 23:08:45** Active/InstallDependency FALSE，部署下载ZIP SHA `4fe6d30a24b4bbb21ad36c0a223533a23cf99435adffc472643c81ad4174695a`；5633文件逐项一致，仅index.js变化，依赖0变更。
- 正式健康 API/img均200；image仍12:57:46；runtime/管理网页未写入，不出IPA。
- 临时会员两账号 **22次真实HTTP请求**，最大并行2：同UUID会话/消息/记忆、伪造body/query账号、独立pull、同账号冲突一成一拒、删除A不删B通过。JSON/SSE/图片到期403、额度429通过，**供应商调用0**。
- p50 **387ms**、p95 **1562ms**、最大2117ms，只是22个有界操作样本，包含登录/不同路由，不能用来推算模型吞吐或千人容量。
- 两测试账号及12条同步记录、2个同步版本头已清理，客户账号0操作。详见outputs/tenant-isolation-20261117/live.json、verification.json、publish-exact.json。
- 真实云端未做付费模型隔离压力测试；跨周期陈旧快照回归为真实函数+本地事务夹具，正式新周期无额外读取分支通过本轮JSON/SSE。脚本未执行回滚。多项目语义分层与容量门禁仍是待办。
