# C2.1 变更说明

| 文件 | 变更 | 兼容性 |
|---|---|---|
| `cloudfunctions/bf-api/index.js` | 补发查询加 `nextAt` 过滤；重复键视为已投递；新增 `handleRetryNotify` + 路由 | 接口兼容；新接口需管理员 |
| `web/admin.html` | 新增「已处理与恢复」区块 + 通知状态徽章 + 补发按钮 | 纯前端新增，旧数据（无 notifyState）显示"旧数据无记录" |
| `tests/notify-retry.test.js` | +5 条边界用例 | — |

## 回滚
`git revert <commit>` → 重新部署 bf-api → 静态页回滚到上一版 admin.html。无数据迁移。
