# C1.4 通知补发与状态恢复 · 审计

基线：`saas_fix` @ `52aee5a`（本轮提交见 CHANGELOG）· 2026-10-25 02:55

## 一、真实调用顺序（handler 层）

```
POST /admin/requests/:id/approve
  handleApproveRequest
    ├─ 读请求 → matchOperation（C1.3 幂等重放判定）
    ├─ approveRequest: CAS pending→processing（失败 409 或回滚）
    ├─ doApprove: 写账号/顺延到期 + db.notifications.add(...)   ← 第二笔写
    ├─ ensureNotified（本轮新增）：回查通知是否真的存在
    └─ rememberOperation（写 lastOp）
```

`/reject` 同构：CAS → 写 rejected → `notifications.add` → ensureNotified。

## 二、副作用与失败面

| 步骤 | 失败时旧代码行为 | 后果 |
|---|---|---|
| CAS 领取 | 409，无副作用 | 正确 |
| 开通/续费 | 抛错 → 回滚 pending | 正确 |
| **通知 add** | 抛错只被外层 catch 成 `APPROVE_FAILED`，但**账号已开通** | 管理员看到"失败"，重试得 409；员工收不到通知且无任何记录 |
| 进程在 add 前后被杀 | 无痕迹 | 同上，且无人知道 |

结论：审核结果与通知投递**没有被分开建模**，通知失败会被误读成审核失败。

## 三、C1.3 幂等实现核查

| 检查项 | 结果 |
|---|---|
| 存储位置 | 请求文档 `lastOp{id,action,staffId,at,result}` —— **持久化**，不是内存 |
| 进程重启 | 记录在库，重启后仍可重放 |
| 并发 | CAS 保证只有一个请求执行副作用；重放返回 `idempotent:true` |
| 超时/写失败 | 若 CAS 已成功而响应丢失，重试命中重放分支，不会二次开通 |
| 跨操作复用 | `action` 不同 → 409 OPERATION_ID_REUSED |
| 跨账号 | 比对 `staffId`，不命中 |

## 四、本轮修改（最小方案）

1. 新增 `notify-retry.js`：纯策略（稳定通知 ID / 指数退避 / 上限 / 终态），可单测。
2. 请求文档新增字段：`notifyState`（pending|sent|failed）、`notifyAttempts`、`notifyLastError`、`notifyNextAt`、`notifyKind`。
3. `ensureNotified`：审核完成后回查通知是否落库；不在 → 标 pending 进补发队列。
4. `sweepNotifications`：补发只重建**通知**，用稳定 `_id` 幂等；失败退避，超 5 次转 `failed`。
5. 补发触发点：`GET /admin/requests`（管理员打开列表时顺带扫一轮，幂等，可重复执行）。
6. 列表接口原样返回请求文档，因此 `notifyState` 等字段已可被前端读取。

## 五、明确未做

| 项 | 原因 |
|---|---|
| 管理端 UI 展示"通知待重试/发送失败" | 待审核表只渲染 pending 行，塞徽章位置不对；留到 C2 统一做处理中/待恢复视图 |
| 独立后台 worker（bf-jobs 定时扫） | 当前用列表触发的懒扫描已满足"可重复运行、幂等"；上定时器需评估成本 |
| 通知发送方幂等键 | 通知是库内写入（自带 `_id` 幂等），没有外部推送通道 |
| 真实数据库故障注入 | 本地无 CloudBase 实例，见测试报告"未执行" |
