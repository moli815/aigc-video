# 商业海报版式改造（2026-11-04）

当前状态（21:17最终启用）：API20:44:20、image21:15:32均Active、InstallDependency FALSE。下载源码ZIP与候选逐文件SHA256一致、依赖零变更。538项后端回归通过。IMAGE_COMPOSITION_POLICY已全员启用designEngine=poster，无designAccountIds/accountIds；原enabled/minChars420/fonts/其余属性保留。保留DSH App、员工/审批相关改动。

依据：先读AGENTS与design-composition-research；固定MIT海报Skill fa2a40bf参考构图/风格分离，许可证已保留在bf-image/design/REFERENCE-LICENSE.txt。不是安装新图片模型，也没把上游指令直接当系统规则。

新模块 commercial-design-plan 生成可验证的用途/构图/风格/栏目语义；commercial-poster-scene 执行。设计库在design/library.json，先适配3风格、6结构，不能宣传20风格均已适配。字体、私有保存、来源、计费和鉴权复用原边界。新design_plan可选，不要求旧包新字段。

IMAGE_COMPOSITION_POLICY新增designEngine=poster与可选designAccountIds，默认legacy，现有enabled/accountIds/fonts/minChars不变。上线先只让临时账号进入新排版，其余客户保留准确字体版；不替换全员enabled/accountIds。新图形排版放不下时只因COMPOSITION_CONTENT_OVERFLOW回退旧准确排版，并记录design_fallback，不偷偷删内容。合法性/字体缺失错误不放行。

素材比例跟随预检出的manifest.artwork.aspectRatio；旧引擎仍3:1。新模板用5:2或4:3。只改变素材帧，最终用户画布比例不变；Provider的文字模式/层级/引用与真实素材保护仍沿用原契约。

离线7组：展会1178字量级、产品3:4、六服务、采购16:9、六周实施3:4、三联3:1、原图重设计9:16。所有定稿copyHash和条目数量与旧版相同、无溢出、约1~3秒/组，7组进程内存峰值约532MB；不等同线上延迟或商业验收。当前534后端回归通过。图片在outputs/poster-design-20261104，offline-results.json有原字号/新字号、manifest与角色。

首轮真实联调：outputs/poster-design-20261104/live-1793796794984，三组前置设计+Pro真图，分别1161/616/1193字符；单图约69/79/68秒。素材按5:2/4:3真实生成并归档，不再复用不匹配的3:1横条。三组重试cached=true、cost=0；到期me200/chat403/image403，额度耗尽chat429/image429，拦截未增加供应商调用；临时账号和资产已删除，设计白名单已恢复。所有公司/人物/产品为合成资料。

验收范围：定稿文案被固定为夹具，前置模型真实负责设计/素材简报与元数据；不能将此说成自由文案、客户端长期记忆/工具执行完整验收。三组均同文案、同素材本地对照，copyHash/条目一致。首版仍偏文档、主视觉过暗，因此没有全员开放；第二版补充语义图形、目标数值深色强调、馆号/日期层级、提亮出血配图、品牌归位。固定Lucide源1980e3d59b0fa1a2aeb566d5902b25ee98204001的6个图标与原ISC/MIT许可证，没有引入依赖或执行外部指令。浅色accent在浅背景/深色数字块的对比另有回归。

当前最后单例在线验收正在跑，见本轮latest-run.json；不得重复付费。最终视觉记录/开关状态完成后追加。待三组本地最终版与一组在线最终版通过再开放。不能凭测试数声称ChatGPT同等美感；依然有中性正文分区与单字体局限，并非任意自由画布。

回滚：仅从当前IMAGE_COMPOSITION_POLICY去掉designEngine/designAccountIds或将designEngine设legacy，保留enabled/minChars/fonts/accountIds其他属性。最多等待配置缓存刷新（32秒）。这会回到准确文字版，不能关闭整体enabled变回原生长文字。源码回滚用outputs/poster-design-20261104/rollback的17:04包；若只撤本轮视觉细化，可用bf-image-deployed.zip（20:44首版），先精确核验，官方SCF InstallDependency FALSE。不以任何更早晨间包覆盖11月3日晚补丁。

兼容与安全复查：未改App/员工端/登录、会员、账单、输入资产归属和输出URL结构。旧structured没有design_plan可按内容选择；新增字段可选。图标只读本地固定白名单SVG，颜色限六位hex；无自定义路径、URL、HTML或脚本执行。私有素材/字体沿用账号验证与摘要校验，不持久化签名URL/base64，不新增表/权限/密钥，不回显环境/上下文/完整请求头。source=both的历史/当前图混合追加仍为独立未完成项，不借本轮宣称已修复。


## 最终验收与上线
- 最终结构在线单例：live-1793797806041，1161字展会攻略，真实规划19秒、Pro图82秒；幂等/会员门禁再次通过，临时账号/资产已删，隔离设置恢复。最终高亮对比度仅在此后做了保留色相的纯渲染修正；三组同文案同素材本地重放全部通过，不能说这三张均为最终线上直接下载。
- 第一轮三组最终重放正文27.25/35.33/25.35px，旧版27.25/32.86/25.35；本轮三组未靠缩字删字获得布局。更宽的7组中F原图重设计字号仍低于旧版，但高于可读性下限，尚不能说全场景都改善。
- 目视确认：主视觉与标题、目标数值、馆号/日期层级、产品品牌与主体、六服务和六步骤均存在且无遮挡；已保留公司/电话/240kWh/授权码。依然是受约束的说明型海报，单字体和自由图文融合仍有提升空间，不宣称达到ChatGPT同等审美。
- 上线时间21:17:35，最终image21:15:32。新包下载5907文件逐文件一致，API5610文件也一致，依赖安装始终关闭。bf-image-artifact-gate-final.json记录精确变更，rollback目录保留本次前准确排字版。
- 新输出报告 outputs/BossAI-商业海报审美改造验收-20261104.html：三种风格、同文案同素材前后图、真实/本地重放边界、耗时与会员检查。
- 样例脚本不会自行全员开放；只修改临时账号设计白名单并按持有者恢复，绝不改全员composition.accountIds，也不替换整个runtime。生产全员打开需单独授权操作，本次沿用用户已有部署授权完成。
