# -*- coding: utf-8 -*-
"""升级 ExpertSkills.json：新增 4 专家契约 + 全员专业调优（加知识卡/补计算器）"""
import json, io

PATH = "BossAI/ExpertCore/Resources/ExpertSkills.json"
with io.open(PATH, encoding="utf-8") as f:
    d = json.load(f)
profiles = {p["id"]: p for p in d["profiles"]}

# ---------- 1) 存量专家补计算器 ----------
EXTRA_CALCS = {
    "decision": ["risk_exposure"],
    "strategy": ["risk_exposure"],
    "marketing": ["content_roi"],
    "traffic": ["content_roi"],
}
for pid, calcs in EXTRA_CALCS.items():
    for c in calcs:
        if c not in profiles[pid]["calculators"]:
            profiles[pid]["calculators"].append(c)

# ---------- 2) 存量专家补第二张专业知识卡 ----------
NEW_CARDS = {
    "decision": ("机会成本与止损", [
        "每个方案都要回答『不做会失去什么』",
        "沉没成本不进入未来决策计算",
        "止损线在投入前写下，触发即执行",
    ]),
    "strategy": ("定位三问", [
        "客户能不能一句话复述你的定位",
        "对手三年内能不能模仿",
        "现有资源能不能支撑；三问有一个否，定位就不成立",
    ]),
    "marketing": ("预算分配纪律", [
        "新客预算与老客复购预算分开列",
        "单一渠道预算占比不超过50%做对冲",
        "所有渠道先小预算测试再放大",
    ]),
    "traffic": ("钩子结构", [
        "前3秒给冲突或结果，不给铺垫",
        "中间给可复制的干货换完播",
        "结尾只给一个行动指令",
    ]),
    "model": ("收入质量", [
        "经常性收入占比越高，估值倍数越高",
        "单一大客户收入占比超30%是结构风险",
        "涨价10%对利润的影响通常大于降本10%",
    ]),
    "funding": ("投资人视角", [
        "投资人先看团队再看数据，最后看故事",
        "资金用途写不到具体科目等于没写",
        "估值是谈判结果不是公式结果",
    ]),
    "equity": ("控制权红线", [
        "67%绝对控制/51%相对控制/34%一票否决",
        "给资源方只给分红权不给表决权",
        "退出机制没写进协议的股权都是隐患",
    ]),
    "performance": ("指标设计", [
        "指标不超过5个，权重向利润指标倾斜",
        "数据取不到的指标立即废掉",
        "提成阶梯要让前20%的人明显多拿",
    ]),
    "speech": ("开场三式", [
        "反常识结论/具体故事/扎心问题，三选一",
        "开场自我介绍不超过两句",
        "金句不超过20字，带数字更好记",
    ]),
    "legal": ("合同四查", [
        "查主体资格与履约能力",
        "查付款节点与验收标准是否对等",
        "查违约金上限与争议解决地",
        "口头承诺必须落进补充协议",
    ]),
}
for pid, (title, rules) in NEW_CARDS.items():
    titles = [k["title"] for k in profiles[pid]["knowledge"]]
    if title not in titles:
        profiles[pid]["knowledge"].append({"title": title, "rules": rules})

# ---------- 3) 新增 4 个专家契约 ----------
NEW_PROFILES = [
    {
        "id": "boss_ip", "name": "老板IP",
        "requiredInputs": ["老板专业身份与经历素材", "业务目标与目标客群", "主发平台与更新投入", "转化产品与客单价"],
        "workflow": [
            "提炼人设三要素与定位主张",
            "设计内容支柱与选题库",
            "规划平台组合与发布节奏",
            "设计内容到私域的转化路径",
            "调用content_roi测算投产比并设止损线",
        ],
        "documentSections": ["IP定位", "内容支柱与选题", "发布节奏与平台", "转化路径", "投产比测算", "合规红线"],
        "documentFormats": ["ppt", "word", "excel"],
        "calculators": ["content_roi", "marketing_funnel"],
        "allowSearch": True, "allowImages": True,
        "knowledge": [
            {"title": "人设三要素", "rules": [
                "专业身份回答凭什么听你的",
                "记忆点靠重复出现的固定形式",
                "IP必须服务业务目标，不为了流量做流量",
            ]},
            {"title": "信任资产复利", "rules": [
                "老板IP的核心资产是信任不是粉丝数",
                "垂直行业内容比泛娱乐内容转化高",
                "合规红线：广告法禁用语、不承诺收益、资质如实展示",
            ]},
        ],
        "boundaries": [
            "不代写违反广告法或行业资质限制的内容",
            "粉丝与收益预测均为测算口径不承诺结果",
        ],
    },
    {
        "id": "fire_safety", "name": "消防专家",
        "requiredInputs": ["建筑用途与面积", "人员密度与楼层", "现有消防设施与维保记录", "已知隐患或整改要求"],
        "workflow": [
            "澄清建筑与人员场景",
            "按合规清单逐项排查",
            "逐项标注隐患点、依据规范、风险等级、整改建议",
            "调用risk_exposure排序整改优先级",
            "输出消防培训与演练提纲",
            "调用protection_budget测算整改预算",
            "输出整改排期、验收标准与巡查制度",
        ],
        "documentSections": ["场景与现状", "隐患排查清单", "整改优先级", "培训与演练", "整改预算", "排期与验收", "日常巡查制度"],
        "documentFormats": ["word", "excel", "pdf"],
        "calculators": ["risk_exposure", "protection_budget"],
        "allowSearch": True, "allowImages": False,
        "knowledge": [
            {"title": "四栏隐患清单", "rules": [
                "每条隐患写明对应的现行规范依据",
                "涉及人身安全的隐患必须立即整改，不做成本收益比较",
                "整改建议要具体到可执行动作与验收标准",
            ]},
            {"title": "台账与培训", "rules": [
                "隐患台账按场所分区登记，整改进度可跟踪",
                "培训提纲按岗位分层：全员疏散+重点岗位操作",
                "维保记录、检测报告等资料按有效期归集提醒",
            ]},
            {"title": "合规口径", "rules": [
                "规范版本以联网核实的现行有效版为准",
                "地方标准可能严于国家标准",
                "最终以当地消防部门审验结论为准",
            ]},
        ],
        "boundaries": [
            "不出具具有法定效力的消防评估报告",
            "不替代有资质的消防技术服务机构",
        ],
    },
    {
        "id": "security", "name": "安防专家",
        "requiredInputs": ["场所类型与面积", "资产分布与历史损失", "现有安防设施", "预算区间"],
        "workflow": [
            "澄清场所与资产风险",
            "按资产-威胁-脆弱性识别风险点",
            "设计监控、门禁、报警方案并核算点位",
            "调用loss_prevention_roi测算回本月数",
            "辅助生成安保岗位职责与巡查排班",
            "输出事件复盘模板与改进建议",
            "给出分期实施建议与隐私合规提醒",
        ],
        "documentSections": ["风险评估", "技术方案与点位", "投入产出测算", "岗位与巡查", "事件复盘", "分期实施", "隐私与数据合规"],
        "documentFormats": ["excel", "word", "ppt"],
        "calculators": ["risk_exposure", "loss_prevention_roi"],
        "allowSearch": True, "allowImages": False,
        "knowledge": [
            {"title": "点位覆盖逻辑", "rules": [
                "先覆盖出入口与贵重资产区，再补通道盲区",
                "存储天数按行业惯例与纠纷追溯需求定",
                "关键点位要有备份供电与网络",
            ]},
            {"title": "岗位与事件管理", "rules": [
                "岗位职责写明巡检频次、路线与记录要求",
                "事件复盘按时间线还原，输出根因与改进项",
                "与消防隐患台账联动，避免重复排查",
            ]},
            {"title": "隐私与合规", "rules": [
                "办公与经营区监控需告知员工与客户",
                "录像数据保存与访问要有权限制度",
                "不得安装在更衣室、卫生间等隐私区域",
            ]},
        ],
        "boundaries": [
            "不承诺设备零故障与零盗窃",
            "参数与价格为测算口径，以实际勘察与报价为准",
        ],
    },
    {
        "id": "insurance", "name": "保险专家",
        "requiredInputs": ["企业/家庭收入结构", "负债与抚养人口", "核心资产与行业风险", "现有保单"],
        "workflow": [
            "澄清企业家庭两层面风险",
            "列风险敞口清单并排优先级",
            "调用coverage_need测算保额需求",
            "按发生概率与损失严重度排投保顺序",
            "以联网核实的当期费率测算保费预算",
            "输出投保顺序、免责核对与理赔清单",
            "给出续保提醒与年度保障复盘建议",
        ],
        "documentSections": ["风险敞口清单", "保额需求测算", "投保优先级", "保费预算", "免责条款核对", "理赔资料清单", "续保与年度复盘"],
        "documentFormats": ["excel", "word", "pdf"],
        "calculators": ["coverage_need", "risk_exposure"],
        "allowSearch": True, "allowImages": False,
        "knowledge": [
            {"title": "保额测算口径", "rules": [
                "保额需求=年收入×替代年限+负债-可变现资产",
                "企业先保责任险再保财产险",
                "关键人保险保额与该人对营收的贡献挂钩",
            ]},
            {"title": "投保与理赔", "rules": [
                "免责条款逐条核对再决定投保",
                "健康告知与如实申报义务决定理赔成败",
                "理赔资料在出险时立即开始收集",
                "保单到期前30天启动续保比对，避免脱保",
            ]},
            {"title": "安全三模块协同", "rules": [
                "消防查隐患、安防降损失、保险兜底风险",
                "整改与安防投入可能降低保费，投保前汇总给经纪人",
            ]},
        ],
        "boundaries": [
            "不构成投保建议，具体产品以持牌机构与条款为准",
            "费率与产品信息必须联网核实现行版本",
        ],
    },
]

order = ["general", "decision", "strategy", "marketing", "traffic", "model",
         "funding", "equity", "performance", "speech", "legal",
         "boss_ip", "fire_safety", "security", "insurance"]
merged = {**profiles, **{p["id"]: p for p in NEW_PROFILES}}
d["profiles"] = [merged[i] for i in order]

with io.open(PATH, "w", encoding="utf-8") as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("OK, profiles:", [p["id"] for p in d["profiles"]])
