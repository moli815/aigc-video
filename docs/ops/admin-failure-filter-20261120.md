# 管理端「失败/被拒」筛选（2026-11-20 20:20）

## 一、先纠正一个判断错误

之前我写过「管理端后端不在 bf-api 里、`/admin/requests`、`/admin/cost*` 找不到」。

**这是我搜错了。** 我用的是 `/api/admin/...` 前缀，而代码里的匹配是从 `/api/admin` 剥掉前缀后按 `sub[0]` 分发的，所以字面量只出现 `/admin/requests` 这种形式。

实际后端全都在 **bf-api** 里：

| 前端调用 | 后端路由 | 实现位置 |
|---|---|---|
| `/admin/finance?days=n` | `sub[0]==="finance"` | `domains/finance-report.js` |
| `/admin/cost-report` | `sub[0]==="cost-report"` | `handleCostReport` |
| `/admin/model-calls` | `sub[0]==="model-calls"` | `domains/model-call-report.js` |
| `/admin/requests` | `sub[0]==="requests"` | `handleListRequests` |

前端也不在 `admin.html` 里：`loadCostReport`、`loadFinanceCalls` 定义在 `web/admin-finance-console-20261029.js`，由 `admin.html:257` 引入。

## 二、台账真实状态枚举（不是猜的）

近 14 天 905 笔：

| status | 笔数 |
|---|---|
| succeeded | 830 |
| rejected | 28 |
| partial | 16 |
| not_dispatched | 11 |
| outcome_unknown | 8 |
| cached | 8 |
| pending | 4 |

**没有 `failed` 这个值。**「失败」是 `rejected + partial + not_dispatched + outcome_unknown` 的集合，所以筛选必须按集合查，不能写 `status="failed"`。

失败组合明细：

| 组合 | 笔数 |
|---|---|
| rejected · HTTP 400 | 18 |
| partial · HTTP 200 | 16 |
| not_dispatched · BILLING_UNAVAILABLE | 11 |
| rejected · HTTP 404 | 10 |
| outcome_unknown · CONSUMER_CANCELLED · HTTP 200 | 7 |
| outcome_unknown · HTTP 503 | 1 |

## 三、改动

### 后端 `cloudfunctions/bf-api/domains/model-call-report.js`

1. 新增 `STATUS_FILTERS` 白名单：`failed / rejected / partial / not_dispatched / outcome_unknown / succeeded / cached / pending`
2. `parseQuery` 增加 `status` 参数，非法值直接 `BAD_QUERY`（不静默忽略，避免"筛了但没筛"）
3. `queryCalls` 按集合构造条件：多值用 `db.command.in`，单值用标量
4. 返回值增加 `status` 字段，前端可回显当前筛选

### 前端 `web/admin-finance-console-20261029.js`

1. 工具栏新增「状态」下拉（全部 / 仅失败 / 上游拒收 / 部分成功 / 未派发 / 结果未知 / 处理中 / 成功）
2. `loadFinanceCalls` 拼接 `&status=`，`all` 时不传
3. 状态列改为真实语义 + 原因：`上游拒收 · HTTP 400`、`未派发（计费拦截） · BILLING_UNAVAILABLE`、`部分成功 · HTTP 200`
4. 失败行标红；空结果给出「该条件下没有记录」
5. 分页显示「本页 N 条」

### `web/admin.html`

脚本引用版本号 `?v=20261106` → `?v=20261120`，否则浏览器继续用旧 JS，下拉不会出现。

## 四、测试

### 后端单测（mock db）10/10

| 用例 | 结果 |
|---|---|
| all 不加 status 条件 | ✓ |
| all 回传 statusKey | ✓ |
| failed 用 in 四种 | ✓ |
| failed 集合正确 | ✓ |
| rejected 收敛为标量 | ✓ |
| 非法 status → BAD_QUERY | ✓ |
| 与 accountId 组合 | ✓ |
| 大小写容错（FAILED） | ✓ |
| hasMore 分页正确 | ✓ |
| limit 越界拒绝 | ✓ |

### 真实台账验证（30 天，直连数据库，零成本）

| 筛选 | 本页 | hasMore | 实际状态分布 |
|---|---|---|---|
| all | 20 | Y | succeeded 18 + cached 2 |
| failed | 20 | Y | partial 5 + outcome_unknown 4 + not_dispatched 11 |
| rejected | 20 | Y | **rejected 20/20** |
| partial | 20 | Y | **partial 20/20** |
| not_dispatched | 11 | N | not_dispatched 11 |
| outcome_unknown | 15 | N | outcome_unknown 15 |
| succeeded | 20 | Y | **succeeded 20/20** |
| 非法 status | — | — | BAD_QUERY 正确拒绝 |

### 前端文案（10/10）

`succeeded→成功`、`cached→缓存免扣`、`pending→处理中`、`rejected→上游拒收`、
`rejected+400→上游拒收 · HTTP 400`、`partial+200→部分成功 · HTTP 200`、
`not_dispatched→未派发（计费拦截） · BILLING_UNAVAILABLE`、
`outcome_unknown→结果未知（断连） · CONSUMER_CANCELLED · HTTP 200`、
未知状态原样透出、空状态→`—`。

## 五、部署（2026-11-20 20:34–20:41 已执行）

```bash
# 1) 后端
node scripts/deploy-function-zip.cjs --fn bf-api \
  --zip outputs/admin-filter-20261120/candidate-bf-api.zip \
  --out outputs/admin-filter-20261120

# 2) 前端：新文件名（绕 CDN 缓存）
tcb hosting deploy web/admin-finance-console-20261120.js admin-finance-console-20261120.js -e xmy-test-d5g8c0xcifcefcfd5

# 3) 最后上传入口页
tcb hosting deploy web/admin.html admin.html -e xmy-test-d5g8c0xcifcefcfd5
```

### 踩到的坑：静态托管按路径缓存

第一次按原文件名覆盖上传 `admin-finance-console-20261029.js`（11948 字节），
线上 `curl` 拿到的仍是旧内容（10715 字节，无 `financeStatusFilter`）。`tcb hosting` 没有 purge 命令。

**解决**：换新文件名 `admin-finance-console-20261120.js`（全新路径必然命中新内容），
`admin.html` 引用改为该文件名 + `?v=202611201`。旧文件名保留且内容同步更新。

**为什么这样安全**：缓存未刷新期间，旧页面引用旧 JS，功能完整只是没有新筛选 —— 不会出现
"新 HTML 配旧 JS"导致的白屏或报错。新页面一旦生效，引用的是全新 JS 路径，必然是完整新版。

### 部署后验证

| 项 | 结果 |
|---|---|
| 后端包内含 `STATUS_FILTERS` | ✓（`after-bf-api.zip` 实测 4 处） |
| 真实接口 `status=failed` | ✓ 20 条混排（partial 5 + outcome_unknown 4 + not_dispatched 11）|
| 真实接口 `status=rejected` | ✓ 20/20 全 rejected |
| 真实接口 `status=no_such` | ✓ HTTP 400 |
| 无 token 访问 | ✓ HTTP 401 |
| 正式地址 admin.html | ✓ 77338 字节，引用 `admin-finance-console-20261120.js?v=202611201` |
| 正式地址新 JS | ✓ 11948 字节，含 `financeStatusFilter` 2 处 |
| 真实浏览器渲染（Chrome headless + CDP） | ✓ 8 个状态选项、20 行数据、状态列「部分成功 · HTTP 200」、失败标红 |

浏览器验证脚本：`scripts/verify-admin-ui-20261120.cjs`（建临时 admin → 注入 token → 切 tab7 →
展开明细 → 选「仅失败」→ 断言行数 → 截图 → 删账号）。截图 `outputs/admin-filter-20261120/admin-failure-filter-live.png`。

## 六、回滚

| 对象 | 回滚方式 |
|---|---|
| bf-api | `node scripts/deploy-function-zip.cjs --fn bf-api --zip outputs/admin-filter-20261120/before-bf-api.zip` |
| admin.html | 用 `outputs/admin-filter-20261120/static-before/admin.html` 重新上传（它引用 `?v=20261106`） |
| 前端 JS | `outputs/admin-filter-20261120/static-before/admin-finance-console-20261029.js` 是部署前的线上原件；如需彻底回退，把它传回 `admin-finance-console-20261029.js` 并回滚 admin.html |

> 回滚注意：静态托管有路径缓存，回滚也要换文件名或等 CDN 过期，否则同样会看到旧内容。

## 七、注意事项

1. `failed` 的 `in` 查询目前未建复合索引。台账 900+ 条无感；数据量上万后若变慢，需给 `bf_model_calls` 建 `(status, startedAt)` 复合索引。
2. 只读接口，不改任何账务数据，不产生模型调用，**零成本**。
3. 旧文件 `admin-finance-console-20261029.js` 已同步为新内容但被 CDN 缓存；新 HTML 不再引用它，
   没有页面依赖，可择期删除。
