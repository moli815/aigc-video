# SideStore 中文安装与排障指南（iPad / Boss AI 专用）

> 适用：Windows 电脑 + iPad，免费 Apple ID，装 Boss AI 并实现自动续签。
> 整理时间：2026-10，基于 SideStore 官方流程 + 社区高频问题。

---

## 一、准备清单（开始前先备齐）

| 物品 | 说明 |
|---|---|
| Windows 电脑 | Win10/11 均可，全程约用 20 分钟，之后基本不再用 |
| iPad | iOS/iPadOS 16 以上（Boss AI 要求 17+），电量充足 |
| 数据线 | 能传数据的原装或 MFi 线（纯充电线不行） |
| Apple ID | 免费账号即可。**强烈建议注册一个专用小号**（见 FAQ-10），别用主力账号 |
| iTunes + iCloud | 必须是**苹果官网下载的桌面版**（不要装微软商店版！），SideStore 依赖它们的驱动 |
| BossAI-unsigned.ipa | 从 GitHub Actions 下载的编译产物（解压 zip 得到） |

下载地址：
- iTunes：https://www.apple.com/itunes/download/win64
- iCloud：https://secure-appldnld.apple.com/windows/061-91601-20200323-974a39d7-2f60-4cc4-8c54-8e21f7947d63/iCloudSetup.exe
  （如失效，搜"iCloud for Windows 7.x 官网下载"）
- iLoader（SideStore 官方安装器）：https://sidestore.io

---

## 二、安装 SideStore（电脑端，约 10 分钟）

1. 装好 iTunes 和 iCloud，**各打开一次并登录任意账号**（让驱动注册完成），然后重启电脑。
2. 下载并打开 **iLoader**（SideStore 官方 Windows 安装器，从 sidestore.io 获取）。
3. iPad 数据线连电脑 → iPad 上弹窗点**「信任此电脑」**→ 输入 iPad 锁屏密码确认。
4. iLoader 识别到设备后：
   - 输入你的 Apple ID 邮箱和密码（开双重认证的见 FAQ-2：要用 App 专用密码）
   - 点 **Install SideStore**，等待进度走完（iPad 上会出现 SideStore 图标）
5. iLoader 会同时为你的设备生成**配对文件（pairing file）**并自动导入 SideStore。
   如果它只生成了文件没自动导入：把 `.mobiledevicepairing` 文件通过
   微信文件传输助手 / 邮件 / iCloud 云盘发到 iPad，打开 SideStore 时按提示选择该文件。

---

## 三、iPad 端首次配置（约 5 分钟）

1. iPad 设置 → 通用 → **VPN与设备管理** → 点你的 Apple ID → **信任**。
2. 打开 SideStore → 按提示启用 **StosVPN**（SideStore 内置的本地 VPN）：
   - 系统会请求添加 VPN 配置，点允许
   - StosVPN 的流量只在你 iPad 本机回环，不经过任何外部服务器，不是"翻墙 VPN"
3. **开启免维护模式（两个开关，重要）：**
   - 设置 → 通用 → VPN与设备管理 → StosVPN 旁的 ⓘ → 打开**「按需连接」**
     （VPN 永久在线，重启 iPad 自动恢复）
   - 设置 → 通用 → **后台 App 刷新** → 确认 SideStore 已开启
4. 在 SideStore 的 **My Apps** 页 → 左上角 **+** → 选择 `BossAI-unsigned.ipa` →
   等待签名安装完成（首次可能需要再输一次 Apple ID / App 专用密码）。
5. 桌面打开 Boss AI → 粘贴两个 API Key（自动识别服务商）→ 开始使用。

**之后**：SideStore 会在 7 天签名到期前自动在后台续签 Boss AI，你什么都不用做。

---

## 四、社区高频问题 FAQ

### FAQ-1 「不受信任的开发者 / Untrusted Developer」
装完打不开。设置 → 通用 → VPN与设备管理 → 点开发者证书（你的邮箱）→ 信任。一次即可。

### FAQ-2 Apple ID 登录失败 / 一直要验证码
开了双重认证的账号，SideStore/iLoader 登录时要输 **App 专用密码**：
account.apple.com → 登录 → 「App 专用密码」→ 生成一个 → 用它代替账号密码。
频繁失败会被苹果限流，停手等 1 小时再试。

### FAQ-3 「Unable to Verify App」/ SideStore 自己打不开了
证书过期且没续上。SideStore 能打开：My Apps 里点 Refresh All。
SideStore 也打不开了：回电脑用 iLoader 重装一遍（数据不丢），重装后必要时重新导入配对文件。

### FAQ-4 刷新失败「Refresh failed」
按顺序排查（每步试完再下一步，别叠加着改）：
1. 确认 StosVPN 已连接（iPad 状态栏有 VPN 标）
2. **关掉其他 VPN / 广告过滤 / 去广告 DNS 类 App**（最常见元凶，会抢 VPN 通道）
3. 换 WiFi / 蜂窝网络各试一次
4. SideStore 设置里换一个 Anisette 服务器（默认服务器偶尔抽风）
5. 都不行 → 重新生成配对文件（见 FAQ-5）

### FAQ-5 配对文件报错（invalid / expired / 不是本设备）
配对文件和设备是一一绑定的，换设备、还原系统、用别人的文件都会报这个错。
解决：回电脑用 iLoader 重新生成并导入。
**社区经验：配对文件约两周~一个月可能自然失效一次，失效了重新生成即可，属正常现象。**

### FAQ-6 设备未注册 / UDID 报错 / 一直 processing
苹果第一次见这台设备，注册需要 **24~72 小时**，不是坏了。
**千万不要删了重装**——那会让等待时间重新计算。放着，过一两天自己好。

### FAQ-7 「达到 App 数量上限 / App ID 上限」
免费 Apple ID 最多同时装 **3 个**侧载 App、每周最多注册 **10 个 App ID**。
在 SideStore 里删掉不用的侧载 App 再装；App ID 配额等一周自动恢复。
（Boss AI 不带扩展组件，只占 1 个 App ID。）

### FAQ-8 电脑识别不到 iPad / iLoader 找不到设备
1. 确认装的是**官网版** iTunes/iCloud（微软商店版驱动不兼容，卸载换装）
2. 换数据线（很多廉价线只能充电）
3. iPad 上重新点「信任此电脑」
4. 换 USB 口（优先机箱后置 USB 2.0 口，避开 Hub）

### FAQ-8b iLoader 报错「Failed to enable wifi debugging: MissingValue」
社区高频错误，按顺序处理：
1. **iPad 必须已设置锁屏密码**（没密码设备会拒绝开 WiFi 调试，正是此错）
2. 操作全程 iPad 保持**解锁亮屏停在主屏幕**（临时把"自动锁定"改成"永不"）
3. 重插数据线，重新点「信任此电脑」，重启 iLoader
4. 打开官网版 iTunes → 设备 → 摘要 → 勾选**「通过 Wi-Fi 与此 iPad 同步」**→ 应用，再回 iLoader 重试
5. Win+R → `services.msc` → 重启 **Apple Mobile Device Service**，电脑和 iPad 都重启
6. 仍不行：换线/换 USB 口，确认 iTunes/iCloud 是官网桌面版

### FAQ-9 装完 Boss AI 过段时间提示"证书过期/无法验证"
说明 SideStore 这轮没自动续上（iOS 后台调度偶尔不准时）。
打开 SideStore 点一次 **Refresh All** 立刻恢复，聊天记录和记忆都在。
长期避免：确认 FAQ 第三部分的「按需连接」和「后台刷新」两个开关是开的。

### FAQ-10 会不会封 Apple ID？安全吗
侧载用的是苹果官方给开发者的免费签名通道，不越狱、不改系统，没有封号案例；
但社区共识是**用专用小号侧载**（几分钟注册一个），主力账号完全隔离风险。
SideStore 是开源软件，Apple ID 密码只发往苹果服务器。

### FAQ-11 升级 iPadOS 后 SideStore 失效
大版本系统升级可能重置配对和 VPN 配置。依次重做：开启 StosVPN → 不行就重新导入配对文件 → 还不行就 iLoader 重装 SideStore。侧载圈惯例：**大版本 iOS 更新出来后等一两周再升**，让 SideStore 先适配。

### FAQ-12 我不想装 SideStore 行不行
可以，用 **Sideloadly**（sideloadly.io）替代：每 7 天到期前连电脑重签一次，3 分钟搞定。
适合 iPad 经常能碰到电脑的人；要"装了不管"还是 SideStore。

---

## 五、一页纸速查

```
装机：iTunes/iCloud 官网版 → iLoader 连 iPad → 装 SideStore（自动配对）
配置：信任证书 → 开 StosVPN → 开「按需连接」→ 开后台刷新 → 导入 IPA
续签：自动。失效了就开 SideStore 点 Refresh All
红线：别用微软商店版 iTunes / 别用别人或旧设备的配对文件 / 设备注册等 72 小时别重装
```
