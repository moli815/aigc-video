import Foundation
import SwiftData

//
//  BriefingService.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：定时任务简报的自动生成。在 App 启动/回前台等"每日补偿"时机检查
//  云端下发的定时计划，为到期的任务自动生成"每日早报/每周简报"，写入专属会话。
//
//  在整个 App 中的角色：被动增值服务，不阻塞任何用户操作；生成结果随 SwiftData
//  云端同步，多设备可见。
//
//  关键设计决策：
//  - 仅托管账号（HostedAccount）登录且有效时才工作，避免无端消耗额度。
//  - 用 UserDefaults 记录"每任务每天最后运行日期"实现幂等，防止重复生成。
//  - 生成失败静默吞掉（下次补偿再试），简报是锦上添花的功能，绝不能影响正常使用。
//
//  防呆/安全冗余理由：
//  - 到期判定包含"已过计划小时 + 今天未跑 +（周报仅周一）"三重条件。
//  - 专属会话按 scopeKey 隔离，多账号间不串数据。
//
/// P0-19 定时任务简报：在「每日补偿」时机（启动/回前台，已过计划时间且今天未生成）自动生成，
/// 写入专属会话（每日早报 / 每周简报），随云端同步多设备可见。
/// 防呆：每任务每天最多生成一次（本地键记录）；生成失败静默下次再试，绝不影响正常使用。
@MainActor
final class BriefingService {
    /// 全局单例
    static let shared = BriefingService()

    /// 检查所有云端定时计划并生成到期简报（每日补偿入口）。
    /// 未登录/托管失效时直接返回；单个计划解析失败仅跳过该计划。
    func generateDueBriefings(context: ModelContext) async {
        guard HostedAccount.isHostedActive, HostedAccount.shared.isLoggedIn else { return }
        let payload = await HostedAccount.shared.fetchSchedules()
        // 云端返回结构宽松：_id/id 双兼容、hour 缺省 7 点，解析失败的计划直接跳过不中断
        let schedules = (payload["list"] as? [[String: Any]]) ?? []
        for sched in schedules {
            // 兼容 _id 与 id 两种字段名；缺类型字段的计划无法判定简报种类，跳过
            guard let id = (sched["_id"] as? String) ?? (sched["id"] as? String),
                  let type = sched["type"] as? String else { continue }
            // 计划小时缺省为 7 点（早报的合理默认时间）
            let hour = (sched["hour"] as? NSNumber)?.intValue ?? 7
            guard isDue(type: type, hour: hour, scheduleId: id) else { continue }
            let identity = sched["identity"] as? [String: Any] ?? [:]
            await generate(type: type, identity: identity, scheduleId: id, context: context)
        }
    }

    // MARK: - 到期判定

    /// 判定某定时计划今天是否到期需要生成。
    /// - Parameters:
    ///   - type: 计划类型（"morning" 每日 / "weekly" 每周）
    ///   - hour: 计划执行的小时
    ///   - scheduleId: 计划唯一 ID（用于幂等记录）
    /// - Returns: 当前时间已过计划小时、今天未生成过（周报还需是周一）时为 true
    private func isDue(type: String, hour: Int, scheduleId: String) -> Bool {
        let now = Date()
        let cal = Calendar.current
        // 已过计划小时才生成，避免清晨计划在凌晨抢跑
        guard let h = cal.dateComponents([.hour], from: now).hour, h >= hour else { return false }
        if type == "weekly", cal.component(.weekday, from: now) != 2 { return false }   // 周报：仅周一
        // 幂等防重：本地记录"该计划最后生成日期"，与今天不同才视为到期
        let key = "bossai.briefing.run." + scheduleId
        return UserDefaults.standard.string(forKey: key) != Self.dayString(now)         // 今天没跑过
    }

    // MARK: - 生成

    /// 生成一份简报并写入专属会话。
    /// - Parameters:
    ///   - type: "morning" 每日早报 / 其他值每周简报
    ///   - identity: 用户经营身份信息（name/company/industry/role），缺省字段用占位文案
    ///   - scheduleId: 用于幂等记录的计划 ID
    ///   - context: SwiftData 上下文
    /// 失败行为：静默吞错，不写幂等标记（下次补偿重试）
    private func generate(type: String, identity: [String: Any], scheduleId: String, context: ModelContext) async {
        let title = type == "morning" ? "每日早报" : "每周简报"
        let conv = Self.ensureConversation(title: title, context: context)
        // 身份字段逐个容错取值：任何一项缺失都不影响提示词生成
        let name = identity["name"] as? String ?? ""
        let company = identity["company"] as? String ?? ""
        let industry = identity["industry"] as? String ?? ""
        let role = identity["role"] as? String ?? ""
        // 职务+姓名拼接：任一为空就跳过对应部分，避免出现多余空格或孤立称谓
        let who = (role.isEmpty ? "" : role) + (name.isEmpty ? "" : name)

        let prompt: String
        if type == "morning" {
            prompt = """
            你是「\(HostedAccount.cachedAppName)」的经营顾问。请为\(who.isEmpty ? "经营者" : who)（\(company.isEmpty ? "其公司" : company)，\(industry.isEmpty ? "其所在行业" : industry)行业）生成今日经营早报，要求：
            1. 今日经营三件事：基于该行业通识给出 3 条最值得今天关注的动作方向，每条一句话+一个理由；
            2. 一个 5 分钟即可完成的复盘问题（帮经营者快速校准昨天）；
            3. 结尾一句激励。
            用简洁分节排版，总长不超过 300 字，不要编造具体新闻或数据。
            """
        } else {
            prompt = """
            你是「\(HostedAccount.cachedAppName)」的经营顾问。请为\(who.isEmpty ? "经营者" : who)（\(company.isEmpty ? "其公司" : company)，\(industry.isEmpty ? "其所在行业" : industry)行业）生成本周经营简报，要求：
            1. 本周三个重点方向（行业通识层面），每条一句话+为什么重要；
            2. 一个周复盘清单（3 个问题）；
            3. 本周一个可量化的建议目标。
            用简洁分节排版，总长不超过 400 字，不要编造具体新闻或数据。
            """
        }

        do {
            let content = try await HostedAccount.shared.chatOnce(prompt: prompt)
            let msg = Message(role: "assistant", text: content)
            msg.createdAt = Date()
            msg.conversation = conv
            msg.conversationID = conv.id   // 10-22：缺这一行会导致重进会话看不到简报
            context.insert(msg)
            conv.updatedAt = Date()
            // 10-22 P2 修复：此前 `try? save` 失败后仍然写幂等标记——
            // 表现就是"今天简报已经生成过了"，但用户第二天打开什么都没有（假成功）。
            // 现在只有持久化成功才写标记，失败留给下次补偿重试。
            do {
                try context.save()
                UserDefaults.standard.set(Self.dayString(Date()), forKey: "bossai.briefing.run." + scheduleId)
            } catch {
                // 保存失败：不写标记；内容仍在内存（本轮会话可见），下次补偿会重新生成
            }
        } catch {
            // 静默：网络/额度问题下次补偿时再试
        }
    }

    /// 找到（或创建）简报专属会话
    private static func ensureConversation(title: String, context: ModelContext) -> Conversation {
        let key = HostedAccount.scopeKey
        if let existing = try? context.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.title == title && $0.ownerKey == key }
        )).first {
            return existing
        }
        let conv = Conversation(expertId: "general", title: title)
        context.insert(conv)
        // 10-23：会话保存失败要留痕（否则简报会话没建出来，后面写消息会挂空引用）
        do { try context.save() } catch { context.delete(conv); return conv }
        return conv
    }

    /// 把日期格式化为 "yyyy-MM-dd" 字符串（幂等标记的存储格式）
    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
