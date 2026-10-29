# 财务台账与管理员端上线记录 / DSH 接续说明

更新：2026-10-29，北京时间。仓库根目录为 `C:\Users\24072\WorkBuddy\2026-10-08-11-01-51\aigc-video`。

## 已上线范围

- 客户设备已寄走：本次没有修改 Swift、没有编译 IPA，不要求重装。员工网页 `web/staff.html` 没有修改。
- CloudBase 环境 `xmy-test-d5g8c0xcifcefcfd5`，上海。
- `bf-billing` 已部署：支持按日期分段补采、从官方日账单提取经过验证的单价、处理新计费调用的待核价记录。
- `bf-api` 已部署：供应商单价计费入口、事务防重复扣减、管理员财务接口。会员聊天与流式返回契约保持原样。
- 管理页面及独立 CSS/JS 已上传静态托管；8 个导航页面已在线检查。不是只交 HTML 草稿。
- 2026-09-30 至 2026-10-29，两平台各 30 个完整日期快照已入私有集合 `bf_vendor_bills`。首次补采 269 条；每小时补采继续更新，在线验收时为 272 条、应付金额 97.9967876 元（火山 92.51、百炼 5.4867876）。金额随迟到账单变动，不能把文档数字当固定真值。
- 既有小时任务保留：`bf-billing` 的 timer 为 `0 17 * * * * *`，常规只补最近 3 天。不要再创建重复任务。

## 钱的口径：必须保持清晰

1. **官方账单应付**：供应商对平台账号出的日账单，包含其他服务、其他项目及历史消费；不是充值，也不必然是已扣现金。
2. **调用成本估算**：本次实际返回的 Token、缓存 Token，乘以该供应商、完整模型 ID、时段对应的已核验单价。账单只核定单价，没有虚构官方逐用户账单；`supplierBilledCny` 仍为 null。
3. **用户额度扣减**：上述可核算成本乘 2。图片主链沿用已配置真实图片成本乘 2；缓存重放为 0。不是现金收款，不拿它冒充供应商成本或利润。
4. 453 条旧聊天流水混有零售计价口径，无法据此反推实际成本；保留原记录，不重写、不追扣历史用户。
5. 资源包、代金券、预付抵扣、调整、混合单价、未知模型/用量不猜分摊。符合条件的新调用进入 `pending_cost`，后续有明确单价才结算。没有新增内部辅助调用收费。

## 代码边界

| 文件 | 职责 |
|---|---|
| `cloudfunctions/shared/supplier-pricing.js` | provider:model 单价、北京时间忙闲时段、缓存折扣、8 位小数报价、旧海报接口图片成本 |
| `cloudfunctions/shared/usage-settlement.js` | 单事务更新账户/用量流水/调用收费状态；并发幂等；不扣新会员周期替旧调用买单 |
| `cloudfunctions/shared/model-call-ledger.js` | 供应商调用观察记录；不自行扣额度 |
| `cloudfunctions/bf-billing/collector.js` | 两平台官方每日账单分页读取、标准化、日期校验、分段补采 |
| `cloudfunctions/bf-billing/rate-catalog.js` | 更新单价目录、处理明确要求结算的待核价调用 |
| `cloudfunctions/bf-api/domains/finance-report.js` | 独立汇总三种金额、日期覆盖与截断标志、去除实例/API Key 标识的账单明细 |
| `web/admin.html` | 原管理功能保留，默认进入账单与成本 |
| `web/admin-readability-20261029.css` | 大字、浅底、深绿、分区留白、手机适配及减少动画 |
| `web/admin-finance-20261029.js` | 财务页面、明细翻页、CSV、逐调用台账；没有嵌入密钥 |

共享模块发布前执行 `node scripts/bundle-function-shared.js`。每个函数的 `shared/` 为生成副本且被忽略，不把它们当权威源码。

## 线上配置与权限

`bf_config/runtime.data` 只改了三个非敏感字段，其他值保留：

```json
{"USAGE_BILLING_MODE":"supplier_cost","USAGE_COST_MULTIPLIER":2,"IMAGE_PRICE_MULTIPLIER":2}
```

`bf_config/supplier_cost_catalog` 当前覆盖 `aliyun-bailian:deepseek-v4.1-flash-1017`：忙时输入/输出/缓存分别 2/8/0.2 元每百万 Token；闲时 1/4/0.1。北京时间闲时 22:00（含）至 08:00（不含）。后续以实时目录为准。

`MODEL_COST_RATES` 手工核价覆盖必须使用完整 `provider:model` 键。未知供应商同名模型不套用别家的价格。

账单密钥只在 `bf-billing` 云环境变量里；不要导出到文件、Git、网页、工具参数或交接聊天。`bf_vendor_bills` / `bf_model_calls` 为私有集合；财务接口 `GET /api/admin/finance?days=30` 必须管理员身份，普通员工及会员无权读取。不要修改环境级函数权限来修单个函数。

## 已完成验收与证据

- `node --test tests-backend/*.test.js`：443 通过，0 失败。日志 `outputs/backend-finance-tests.txt`。
- 30 天真实账单读取及实时数据库汇总成功，两平台日期覆盖各 30/30，没有缺日。`outputs/finance-report-verification.json` 是较早快照，更新值见后续线上报告。
- `outputs/admin-finance-live-verification.json`：真实管理员 200，员工 403，非法时间范围 400；临时账号已删除。
- `outputs/model-call-ledger-verification.json`：实际 JSON/SSE 对话成功，实际 Token 成本 ×2 与账户扣额度精确一致；真实 Flash 生图成本 0.12、额度 0.24；同 requestId 重放扣 0；普通会员不能读财务。临时账号已删除，审计流水保留。
- 验收脚本原先本机创建会员周期锚点与云端时钟差几秒，触发旧周期保护；**只修了测试账号锚点提前一分钟**，没有削弱生产跨周期保护。
- `outputs/admin-web-published-verification.json`：线上 HTML/CSS/JS 哈希与本地一致；8 个管理页面导航、账单翻页、逐调用表、390px 手机宽度全部通过；页面错误及 API 错误均为空。
- 员工网页线上发布前后 SHA-256 均为 `ca8700acc9b8b72073302b9436126559780324175d90d32e89de7ba55089789e`。
- 已查看桌面截图；截图在 `outputs/admin-finance-desktop-20261029.png` 和 mobile 同名文件。仅财务页截图，不公开客户列表。

## 自检 / 收尾方法

1. 先读 `git status --short` 和此文档，保留其他人的代码。不要 reset/force push。
2. 查看上述验收 JSON 的 `ok`，不要只读口头报告。用户正在使用，尽量只读验证，不再重复付费生图。
3. 财务页面入口：`https://xmy-test-d5g8c0xcifcefcfd5-1449098021.tcloudbaseapp.com/admin.html`，用现有管理员正常登录。展开账单明细可导出 CSV，和平台同日期、同币种、同“应付”口径对比。
4. 修改代码后跑相关测试；涉及所有共享计费边界时跑全量 443 条。不要新增 IPA 构建任务。
5. 管理 UI 发布顺序始终 CSS/JS 先、HTML 后；不要上传整个 web 文件夹覆盖员工端。发布后比较远端三个文件与本地 SHA，再确认 staff.html 不变。
6. 所有实现与验证完成后提交、同步 `codex/server-billing-ledger-20261029`，不触发 iOS CI。若使用 Git Data API 受限网络脚本，必须核验父树和最终树相同，`force:false`，不能覆盖别人提交。

## 排障与回滚

- 财务接口 503：查 `finance_report_failed`，页面显示读取失败，**不是显示 0 元**。检查 CloudBase 查询权限/时间范围；不要靠放开私有数据库权限修复。
- 财务金额差异：先区分应付、现金、充值、资源包、日账单出账延迟与历史缺失，不拿整个账号账单比例硬摊给用户。
- `usage_charge_pending` / `pending_cost`：核对 provider/model、供应商实际 usage、缓存数量、单价目录；未明确成本不猜扣。`closed_cycle_review` 需要人工复核，不跨续费周期追扣。
- 本地云临时凭据过期：通过现有 CloudBase 登录刷新；不新建永久密钥。只读检查一次成功再跑验收，避免重复请求。
- 回滚准备：上线前 `bf-api` 发布版本 11、`bf-billing` 版本 2；不要盲目切版本，先查当前路由/版本绑定。恢复配置需事务比较当前值，只将相关计费字段退回原口径，不覆盖其他管理员设置。
- 原管理 HTML 备份 `outputs/pre-redesign-admin.html`。紧急 UI 回退仅上传此 HTML 到 admin.html，员工页面不动；独立新 CSS/JS 可以保留，不必删资源。
- 整体回退后仍保留官方账单与调用审计记录，不删生产财务数据、不重置用户余额。

## 后续边界（不要冒充已完成）

- 官方账单是日聚合、会迟到；目前没有每请求供应商发票，不能承诺“实时逐笔官方实付”。
- 运行期间才启用的调用台账不能自动恢复此前全部用户 Token；旧口径 453 条单独标出。
- 新增模型/收费搜索/内部工具如要向用户收费，需先配置经核验的单价与明确收费边界；本轮没有自行扩大收费范围。
- 待核价批任务每轮最多 100 条；未来未知模型大量积压时需按游标分批，防止前 100 条长期未知造成后续饥饿。
- 其他币种目前不折人民币，报表为 CNY；未来出现非 CNY 应单独展示，不偷偷使用浮动汇率。
- 账单 API 不能保证很久以前的调整每小时自动回扫；需要时按 `days/offsetDays` 再补采对应日期，幂等覆盖当日快照，不叠加算两次。
- 本轮做了财务权限、真实扣费与页面只读验证，没有替用户执行真实会员审批/发放/退款等写操作。
