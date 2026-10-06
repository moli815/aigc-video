# BossAI：iPad 经营任务工作台

面向经营者的 SwiftUI / SwiftData App，最低 iOS 17。提供任务草稿、专家技能与可靠计算、联网证据、本地资料检索、对话和 Word / Excel / PPT / PDF 交付。

当前 build：**2026100604**；源码提交：`816d2f9efccf9ffc95c872f2324cf4bd2c551cf9`。
实际原生测试、截图、搜索诊断和性能测量见 [本版交付说明](docs/BossAI-工作台与搜索升级说明-20261006.md)。[当前产品说明](docs/BossAI-产品说明.md)描述现在的行为；历史报告仅作追溯。

## 这次可以直接看到的变化

- 首页三类任务卡，填写背景后再发送；专家入口可直接打开技能与计算工作台。
- 对话可选“自动核实 / 联网研究 / 仅用现有资料”和“清晰简答 / 详细分析”。
- 最终只保留一份答案，正文默认完整展开，用户手动折叠；有独立复制按钮及引用来源。
- 六主题改变字体、底色、卡片、间距和阅读宽度；联网解析接入 SwiftSoup 2.13.9。

任务流程、搜索与计算和模型解耦。厂商协议参数放在 ModelRequestAdapter；Chat Completions 兼容接口使用同一业务流程，其他协议需新增传输适配。

“仅用现有资料”关闭网页工具，仍可能把资料发送至所选模型 API，不表示完全离线。测试凭证按用户要求保留；生产网络请求实际流向由所选服务商决定。

## 原生开发与验收

macOS、Xcode 16.4、XcodeGen：

```bash
bash scripts/run-quality.sh
```

[GitHub原生测试](https://github.com/moli815/aigc-video/actions/runs/37465045756)及[未签名IPA构建](https://github.com/moli815/aigc-video/actions/runs/37465045960)来自同一提交。IPA需签名后安装；模拟器测试不代表真机帧率、发热、电量或复杂任务准确率。

第三方依赖及许可证见 BossAI/Resources/ThirdPartyNotices.txt。专业资料分块/FTS索引、记忆确认机制、字段级证据和全上下文预算仍是待做项，具体方案在交付说明中。
