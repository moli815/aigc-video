# Boss AI — 企业经营者的 AI 顾问矩阵（iOS）

自用 iOS 应用：1 个普通对话 + 10 个经营专家对话框，ChatGPT 风格界面，
支持语音输入、联网搜索、自动生图、跨会话长期记忆、身份设置。
**无需 Mac、无需付费开发者账号**：GitHub 云端自动编译 + Windows 侧载安装。

## 装机流程（只做一次，约 20 分钟）

### 第 1 步：申请两个 API Key（约 10 分钟）

| Key | 申请地址 | 说明 |
|---|---|---|
| 对话 Key | https://platform.moonshot.cn （Moonshot 开放平台） | 注册 → 实名 → 「API Key 管理」→ 新建 |
| 作图 Key | https://console.volcengine.com/ark （火山引擎方舟） | 注册 → 开通「模型服务」→ 创建 API Key，确认 Seedream 4.0 已开通 |

两个平台都需充值少量金额（各充 10~20 元够用很久）。

### 第 2 步：下载编译好的安装包（IPA）

1. 打开本仓库的 **Actions** 标签页
2. 点最新一次绿色✓的运行记录 → 页面底部 **Artifacts** → 下载 `BossAI-unsigned-ipa`
3. 解压得到 `BossAI-unsigned.ipa`

> 每次代码更新（push）都会自动重新编译，随时可以下载最新版。

### 第 3 步：Windows 上安装 Sideloadly 并装机（约 10 分钟）

1. 电脑安装 iTunes + iCloud（苹果官网版，非微软商店版）：Sideloadly 依赖它们的驱动
2. 下载安装 **Sideloadly**：https://sideloadly.io
3. iPhone 数据线连电脑 → 手机上点「信任此电脑」
4. 打开 Sideloadly：
   - 把 `BossAI-unsigned.ipa` 拖进去
   - Apple ID 填你的苹果账号（免费账号即可）
   - 点 **Start**，期间可能要输入 Apple ID 密码和短信验证码
5. 装完后 iPhone 上：**设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → 信任**
6. 桌面出现 Boss AI 图标，打开 → 输入第 1 步的两个 Key → 开始使用

### 关于 7 天到期自动续签（iPad 免电脑方案）

免费 Apple ID 签名 7 天到期。iOS 系统禁止 App 给自己续签（平台安全限制，无法绕过），
但 **SideStore** 可以在 iPad 上自动完成续签——装好后不再需要电脑。

**一次性设置（约 15 分钟，之后永久自动续签）：**

1. 电脑下载 SideStore 安装器：https://sidestore.io （支持 Windows）
2. iPad 数据线连电脑，按安装器引导把 SideStore 装进 iPad（需输一次免费 Apple ID）
3. iPad 上打开 SideStore → 按提示安装并启用 **StosVPN**（一个本地 VPN 配置，
   这是 SideStore 实现"自己给自己续签"的原理，流量只在本机回环，不经过任何外部服务器）
4. 在 SideStore 里导入从本仓库 Actions 下载的 `BossAI-unsigned.ipa` 完成安装
5. **让它彻底免维护（两个开关）：**
   - iPad 设置 → 通用 → VPN与设备管理 → StosVPN 旁边的 ⓘ → 打开「按需连接」
     （VPN 永久在线，重启 iPad 后自动恢复）
   - iPad 设置 → 通用 → 后台 App 刷新 → 打开 SideStore
6. 完成。之后 SideStore 会在签名到期前**自动在后台刷新** Boss AI，日常无需打开。
   极端情况下若超过一周完全没被系统调度到，Boss AI 会提示证书过期——
   打开 SideStore 点一次 Refresh 即可恢复，聊天记录和记忆不会丢。

> 备选：不装 SideStore 也行——每次到期前用 Sideloadly 重跑一次装机流程（约 3 分钟），
> App 内的聊天记录和记忆不会丢。

## 功能说明

- **11 个对话框**：侧栏切换。普通对话 + 商业决策 / 战略定位 / 营销策划 / 流量策划 / 商业模式 / 融资招商 / 股权结构 / 薪酬绩效 / 顶级演讲 / 法务风控，各自独立记忆上下文。
- **智能联网搜索**：模型自己判断何时搜索（界面显示"正在联网搜索…"），带引用来源。
- **智能生图**：对话中说"帮我做一张 XX 海报"即自动生成（Seedream 4.0），支持多轮改图（"把背景换成蓝色"），长按图片可保存相册。
- **长期记忆**：自动记住你的公司、项目、偏好，所有对话框共享；右上角「身份设置」里可查看/删除/清空。
- **身份设置**：设置姓名/公司/行业/身份/当前诉求，所有回答自动贴合你的经营场景。
- **语音输入**：点输入框左侧麦克风说话，文字实时出现在输入框，可编辑后发送。
- **换 Key 隐藏入口**：侧栏长按 Boss AI 图标 5 秒。

## 技术说明

| 模块 | 实现 |
|---|---|
| 对话模型 | Kimi K2（Moonshot，内置 `$web_search` 联网搜索），OpenAI 兼容协议，国内直连 |
| 图像生成 | 字节 Seedream 4.0（火山引擎），自定义 `generate_image` function calling 智能调用 |
| 语音输入 | Apple Speech 框架（zh-CN） |
| 记忆 | SwiftData 本地存储 + 后台自动抽取（每 3 轮对话） |
| 界面 | SwiftUI，iOS 17+ |
| 编译 | GitHub Actions（macos-14）→ XcodeGen → xcodebuild 未签名 IPA |

切换对话模型：编辑 `BossAI/Config/AppConfig.swift`（如改 DeepSeek：`https://api.deepseek.cn/v1`，
注意 DeepSeek 官方 API 无内置联网搜索，搜索功能将不可用）。

## 目录结构

```
├── .github/workflows/build-ipa.yml   # 云端自动编译
├── project.yml                       # XcodeGen 工程定义
└── BossAI/
    ├── BossAIApp.swift               # 入口 + 双 Key 配置门
    ├── Config/                       # 端点常量 / Keychain / 凭证管理
    ├── Models/                       # 会话/消息/记忆/身份 + 11 套专家 prompt
    ├── Services/                     # 流式聊天+工具循环 / Seedream / 语音识别 / 记忆抽取
    ├── ViewModels/                   # 会话逻辑（流式+搜索+生图+记忆触发）
    └── Views/                        # 配置页 / 侧栏 / 对话页 / 消息气泡 / 输入条 / 身份设置
```
