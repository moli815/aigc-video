# BossAI 本轮修复源码（待 iOS 验收）

基于用户2026-10-05提供的重构源码。专家技能、经营计算工作台、本机专业资料检索、联网时效/引用、流式可靠性、备份恢复、文件导入、语音、六主题与聊天表格已改造。

已执行：53项桌面源码/逻辑检查，11专家真实API工具路由测试，4搜索端点真实探测。
未执行：Swift编译、65个原生测试、iPad模拟器/真机、Instruments。此包不能称为已验收成品或性能达标版。

完整改动、文件行号、证据与剩余工作：`docs/本轮改动与验证.md`。

macOS安装Xcode/XcodeGen后执行：

```bash
bash scripts/run-quality.sh
```

桌面复现检查：Python环境安装`scripts/requirements-desktop.txt`后执行`python scripts/verify-desktop.py`。

本轮没有上传源码或触发GitHub工作流。内置测试凭证按用户要求保留；离线测试入口使用内存数据库并跳过凭证种子。
