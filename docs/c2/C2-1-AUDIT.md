# C2.1 审核与恢复状态可视化 · 审计与实施

基线 03:10 · 起点 commit `af1d991`（C1.4 完成）

## 一、用户点名的 4 个边界：实测结论

| 检查项 | 结论 | 证据 |
|---|---|---|
| 通知 `_id` 是否稳定唯一 | **稳定**，但有隐患已修 | `notificationId(requestId, kind)` 用哈希生成，同申请同类型恒定；但旧 `deliver` 把"重复键"当失败 → 会白烧 5 次后标 failed。现改为**重复键 = 已投递**（`isDuplicateKeyError`） |
| `attempts` 何时增加 | 只在真实投递尝试时 +1 | `sweep()` 里 `skipped` 分支先 return，递增在其后；退避跳过不消耗额度（BND-03 锁定） |
| `sent` 判定依据 | 以**通知记录已写入**为准 | `add` 成功或撞唯一键都算 sent；`ensureNotified` 还会回查 `refNotifications` 数量兜底 |
| `nextAt` 是否参与筛选 | **原来没有，已修** | 旧查询只按 state 过滤，退避中的文档会占满 `limit` 窗口 → 已加 `notifyNextAt: db.command.lte(Date.now())` |

> 关于"sent"的语义边界：当前通知只是**站内通知箱**，`sent` = 已入箱，不等于员工已读。
> 将来接短信/邮件，需要新增 `deliveryChannel` 与独立的 `deliveredAt`，不能复用这个 sent。

## 二、本轮改动（只动管理端 + 必要接口）

1. `notify-retry` 查询加 `nextAt` 过滤（BND-01）
2. 补发投递把"唯一键冲突"视为成功（BND-02）
3. 新增 `POST /admin/requests/:id/retry-notify`（仅管理员 + 审计 `request.notify.retry`），
   只重置退避、放宽一次额度，**不重跑审核/开通**；已 sent 直接返回 `alreadySent`
4. 管理端新增「已处理与恢复」区块：
   - 与待审核列表分离（只展示 `status !== pending`）
   - 三列状态：审核结果 / 通知投递 / 处理时间
   - 通知状态：`通知已送达` / `通知待重试 · 第 N 次` / `通知发送失败 · 第 N 次` / 旧数据无记录
   - 只有 pending/failed 才显示「补发通知」按钮

## 三、仍然依赖"列表访问触发"补发

**这是阶段性方案，不是最终形态。** 管理员不打开列表就不会自动补发。
建议 C2 收尾时把 `sweepNotifications` 挂到 `bf-jobs` 定时任务（5 分钟一次），
本轮的 `sweep` 已做到幂等 + 退避 + 上限，直接搬过去即可，不需要改逻辑。

## 四、未执行

- 浏览器端到端（补发按钮点击 → 真实写入 → 刷新状态）
- 真实数据库重复键冲突注入（本地无 CloudBase 实例）
- `bf-jobs` 定时补发（未做）
