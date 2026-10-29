# 逐笔调用台账与供应商账单接入

日期：2026-10-29。全部为服务端改动，兼容现有 App，无需 IPA。

## 已上线：逐笔模型调用

私有集合 `bf_model_calls` 记录：

| 字段 | 含义 |
| --- | --- |
| `orderId` | 业务订单号：账号＋业务请求 ID 的稳定摘要，缓存重放仍归同一订单 |
| `_id` | 单次上游调用编号，重试分开记录，避免掩盖多次上游消耗 |
| `accountId` | 通过现有会员鉴权后的真实账号 ID |
| `requestId` / `clientRequestId` | 服务端排障编号／原客户端业务编号 |
| `provider` / `model` | 实际供应商／实际返回模型，不使用对外展示别名 |
| `endpoint` / `kind` / `taskKind` | 触发入口、对话／图片／工具、图片任务类型 |
| `startedAt` / `endedAt` / `durationMs` | 调用时间与耗时，数据库使用 Date |
| `vendorRequestId` / `providerResponseId` | 平台请求号与返回结果 ID，分别保存 |
| `inputTokens` / `outputTokens` / `cachedInputTokens` / `reasoningTokens` | 平台返回的实际用量；未提供为 null，不伪造为 0 |
| `inputImages` / `outputImages` / `requestedSize` | 图片输入输出数量、请求尺寸 |
| `supplierCostEstimateCny` | 依据显式供应商单价计算的成本估算 |
| `supplierBilledCny` | 官方账单确认成本，尚不能匹配到单次请求时保持 null |
| `priceCny` / `chargeState` / `billingEventId` | 本系统计入用户额度的金额与原记账事件关联 |
| `status` | pending / succeeded / rejected / outcome_unknown / partial / cached |

主回复、分类、压缩、记忆提取、提示词增强、视觉分析等只要经过模型调用边界都会登记。内部成本不等于向用户收费；`chargeState=not_recorded` 表示未从现有扣费事件取得确认。

不保存 prompt、聊天正文、图片内容或完整密钥。用于区分共享上游凭据的 fingerprint 仅为不可逆摘要，不是官方 API Key ID。

上游超时、断流、5xx 的最终成本未知，标记 outcome_unknown 等待核对。账本写入短暂失败重试一次；仍失败写结构化告警，保留 pending 行或完整白名单元数据日志，不阻断用户本次模型结果。极端数据库故障需要据日志补账，不能承诺数据库故障时无条件完整写入。

台账自身不扣费；图片沿用原幂等账务事件和 outbox。聊天的原额度计价不变。成本看板补修了“每行先按分舍入”问题，内部保留 1e-8 元，再汇总显示，避免小额 Token 费用消失。

管理员查询：`GET /api/admin/model-calls?accountId=...&start=ISO&end=ISO&limit=50&page=0`，支持 `orderId`。仅现有 admin 身份允许；查询范围最多31天，每页最多100条。现有管理台无需更新即可继续工作，新增明细也可在 CloudBase 私有集合查询。

## 等待用户配置：财务只读凭据

财务账单不能使用普通模型 sk Key。用户已选择亲自登录并配置两平台财务只读身份；代理没有创建永久 AccessKey，也没有授予付款、充值、购买、删除等权限。

腾讯云 CloudBase → 云函数 → **bf-billing** → 配置 → 环境变量，保留 `TCB_ENV` 并新增：

| 平台 | 必需变量 | 可选变量 |
| --- | --- | --- |
| 火山 | `VOLC_BILLING_ACCESS_KEY_ID`、`VOLC_BILLING_ACCESS_KEY_SECRET` | 临时凭据需 `VOLC_BILLING_SECURITY_TOKEN` |
| 阿里云百炼 | `ALIYUN_BILLING_ACCESS_KEY_ID`、`ALIYUN_BILLING_ACCESS_KEY_SECRET` | `ALIYUN_BILLING_SECURITY_TOKEN`；确认产品代码后可设 `ALIYUN_BILLING_PRODUCT_CODE` |

不要将密钥写入 Git、输出文件或聊天。推荐已有只读身份；确需新身份时由用户在各平台完成。临时凭据会过期，未接入自动换取 STS 时需由用户更新。

阿里云最小查询策略（在 RAM 授权给用户选择的身份）：

```json
{"Version":"1","Statement":[{"Effect":"Allow","Action":["bssapi:DescribeInstanceBill"],"Resource":"*"}]}
```

火山在 IAM 控制台选择费用中心的只读账单明细 API `ListBillDetail`，按控制台实际生成的 Action 授权；不猜测未经平台校验的 IAM Action 前缀。若用系统策略，确认仅账单读取，禁止授予财务全权限。

- 火山接口：[ListBillDetail](https://docs.volcengine.com/docs/billing-center/list-bill-detail-page-query-bill-details?lang=zh)
- 阿里云接口：[DescribeInstanceBill 与 RAM 权限](https://help.aliyun.com/zh/user-center/developer-reference/api-bssopenapi-2017-12-14-describeinstancebill)
- 百炼出账：[通常2–10分钟，区别于通用API延迟](https://help.aliyun.com/zh/model-studio/bill-query-and-cost-management)

## 已部署：独立账单读取任务

`bf-billing` 是 Event 云函数，没有 HTTP 网关入口；每小时触发一次，回查北京时间今天及前两天，补收延迟出账。使用两家官方 SDK；只调用账单查询 API。未配置凭据时不请求平台、不报零消费。

`bf_vendor_bills` 为管理端私有集合，每个平台每天一份完整快照，重复读取更新当日暂计数据。分页读不全、超限、鉴权失败时保留此前完整快照并记录错误。每次读取最多10页／1000行，单次执行有150秒预算，超限需要运维分区查询，不能把截断结果当完整账单。

状态保存在 `bf_config/billing_import_status`：

- `awaiting_credentials`：缺少凭据，不等于无消费。
- `read_failed`：填写后权限、身份、接口或网络验证失败；按 code 排查。
- `read_verified`：该平台真实接口读取成功，包含空账单但需考虑平台出账延迟。

配置后在云函数控制台手动执行 `bf-billing`，参数 `{}`，确认两个平台均为 read_verified，并检查私有表实际入库内容。当前尚未取得财务凭据，因此**还未验证真实账单读取**。

平台账单往往按模型、API Key、计费项和时间汇总，不能自动凭空拆成 App 每用户每请求的真实扣款。初版仅保存官方汇总凭证，**未实现账单到逐笔调用的自动匹配和差异结算**；因此不会把汇总账单硬摊给个人，也不会修改用户额度。后续需根据真实返回的标识建立映射，并区分免费额度、缓存、资源包、折扣和退款。

CloudBase 工具的函数调用权限实际是环境级规则；已恢复本次最早读到的登录调用规则，没有扩大客户 App 权限。新增两张数据库集合均单独为 ADMINONLY；账单函数没有新增公开路由。

## 验证与回滚

- `node --test tests-backend/*.test.js`
- `node scripts/verify-model-call-ledger.cjs`：隔离临时账号，真实 JSON、SSE、生图、同 requestId 重放、会员拒绝读取财务接口；验证后删除临时账号，保留审计流水。
- 实测报告：`outputs/model-call-ledger-verification.json`。
- 主 API 部署前保存版本10，图片函数保存版本9。需要回滚时恢复对应代码；不要删除已产生的台账或账单数据。
- 仅暂停财务同步可禁用 `bf-billing` 的 `supplier-bill-hourly` 触发器，不影响客户聊天、生图或会员扣费。
- 财务读取 SDK 尚需以用户真实只读凭据做平台端验收；离线测试覆盖了分页、缺凭据、权限错误、负数调账及失败快照保护。
