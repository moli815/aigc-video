# C2.2-FIX：账号与会员履约幂等修复

起点 `8f70bee` · 2026-10-25 03:35 · 只改 `bf-api` 履约路径，未动通知/成本/iOS

## 一、修复内容

### R1 续费重复顺延（P0）
`doApprove` 续费分支不再"先读到期日、再无条件 update"。改为**单次条件更新**同时完成三件事：

```js
db.collection(C.accounts).where({
  _id: reqDoc.accountId,
  expiresAt: acc2.expiresAt,              // 到期日版本（R3 的乐观锁）
  renewedRequestIds: _.nin([reqDoc._id])  // 幂等键：这条申请没生效过
}).update({ ...renewPatch, expiresAt: computed, renewedRequestIds: _.push(reqDoc._id) })
```

- 条件检查、到期日写入、申请 ID 记录在**同一条**更新里，没有"改了期限但没标记"的中间窗口。
- `updated === 0` 且账号里已有该申请 ID → 直接返回 `{idempotent:true}`，不再顺延。
- 若账号里没有该 ID → 说明是并发被抢，重读最新到期日重算，最多 3 轮，仍失败抛 `RENEW_CONFLICT_RETRY`（不静默成功）。

### R3 不同申请并发覆盖（P1）
同一账号两条续费申请：CAS 保护不了它们（不同文档），靠上面的 `expiresAt` 版本条件。
后到者条件不命中 → 重读新到期日 → 在已延期的基础上再顺延 → **两次都累计**，不丢。

### R2 重复开通（P0）
- 账号 `_id = "acct_" + reqDoc._id`：一条申请恒定对应一个账号文档。
- 重试时 `add` 撞主键 → `isDuplicateKeyError` → 读回原账号复用（`accountReused`），**不会生成第二个用户名**。
- 发放记录同样 `_id = "dlv_" + reqDoc._id`，重试不写第二条。
- 账号复用后仍会补发发放记录（若上次失败），这属于"补齐缺失步骤"而非重做。

### 履约状态
续费成功写 `fulfillmentState: "done"`，供管理端区分"审核通过"与"履约完成"。

## 二、对用户两点补强的回应

**1）原子性**：确认 CloudBase 支持 `where + update` 的单文档条件更新，因此条件检查、期限变更、申请 ID 记录放在**同一次**调用里，没有拆成两次写。
`renewedRequestIds` 会随续费次数增长（每账号 ≈ 续费次数个短字符串），当前量级可接受；若将来单账号续费超数百次，应迁移为独立 `bf_fulfillments{_id:req_xxx}` 集合。**本轮未做迁移。**

**2）"重做"语义**：因为续费与开通都变成幂等的，`doApprove` 可以安全重跑——重复步骤会被跳过（申请 ID 已在列表 / 账号已存在）。所以本轮**保留**失败回滚到 pending 的行为，靠"可重跑安全"而不是"禁止重跑"来解决。管理端"只补缺失步骤"的独立按钮仍未做。

## 三、未验证 / 未做（不得当作通过）

| 项 | 状态 |
|---|---|
| 真实 CloudBase 条件更新（Date 字段等值匹配） | **未验证** — 需在测试环境实测；若 Date 精度导致条件永不命中，会表现为 `RENEW_CONFLICT_RETRY` |
| `_.nin` / `_.push` 在 CloudBase node-sdk 的行为 | **未实测** — 语法按 Mongo 语义使用，需真机验证 |
| 并发 10 次重复执行、两申请并发累计 | **未执行**（无真实库） |
| 存量账号是否需要补 `renewedRequestIds` | **未迁移**：缺字段时 `_.nin` 仍匹配（Mongo 语义），但需实测确认 |
| 管理端"履约状态"展示与"补做"入口 | **未做**，留 C2.3 之后 |
| 账号 `_id` 格式变更对历史数据的兼容 | 只影响**新**账号；旧账号 `_id` 仍是原格式，登录/查询均按 `_id` 走，不受影响（已检查调用点） |

## 四、回滚

1. `git revert <commit>` → 重新部署 `bf-api`。
2. 数据：`renewedRequestIds` 字段旧代码不读，可保留；新账号 `_id` 前缀不影响旧逻辑。
3. 风险：回滚即恢复"重复顺延/重复建号"窗口。
