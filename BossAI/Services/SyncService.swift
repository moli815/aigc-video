import Foundation
import SwiftData
import BackgroundTasks

// ============================================================================
// 文件职责：P0-18 云端同步引擎。
// 在 App 中的角色：把本地对话/记忆按账号（scopeKey）双向同步到云端——
//   登录后、回前台、手动触发、每日后台任务共用 syncNow 一条路径。
// 关键设计决策见下方类注释（LWW / 墓碑 / 增量拉取 / 静默失败）。
// ============================================================================

/// P0-18 云端同步（按账号隔离）
/// ------------------------------------------------------------
/// 设计要点（沿用业界成熟做法，避免自造轮子）：
/// 1. **按条目同步 + 增量拉取**：客户端记录 lastSyncAt，拉取只取 updatedAt > since 的条目；
/// 2. **最后写入者胜（LWW）**：同 id 比 updatedAt，避免离线旧数据回滚云端新数据；
/// 3. **删除用墓碑标记**：不物理删除，避免"删了又被同步回来"；
/// 4. **每日 3 点**：注册 BGAppRefreshTask（iOS 后台刷新属机会式调度，系统会在临近时间窗口执行；
///    若设备当天没用过 App，系统可能延后——这是 iOS 的既有约束，不是实现缺陷）；
/// 5. 失败一律静默 + 保留本地数据，绝不因同步失败影响使用（安全冗余）。
@MainActor
final class SyncService {
    static let shared = SyncService()
    static let bgTaskIdentifier = "com.bossai.sync.daily"

    // 10-22 P1 隔离修复：游标此前是全局键，A 同步到较晚时间后切 B 会跳过 B 的旧数据。
    // 改为按当前账号 scopeKey 命名；切换账号即切换游标，首次同步走完整拉取。
    private var lastSyncKey: String { "bossai.sync.lastSyncAt.\(HostedAccount.scopeKey)" }
    private let autoSyncKey = "bossai.sync.autoEnabled"
    private var running = false
    // P0-46 错误可见性：同步失败不再是纯静默——记录最近错误与连续失败次数
    @Published private(set) var lastSyncError: String?
    @Published private(set) var consecutiveFailures = 0

    /// 上次同步成功时间（UI 展示用）
    var lastSyncAt: Date? {
        get { UserDefaults.standard.object(forKey: lastSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastSyncKey) }
    }
    /// 自动同步开关（默认开）
    var autoSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoSyncKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoSyncKey) }
    }

    // MARK: - 入口

    /// 全量推 + 增量拉（登录后 / 回前台 / 手动 / 后台任务 共用一条路径）
    @discardableResult
    func syncNow(context: ModelContext) async -> Bool {
        guard !running, HostedAccount.isHostedActive, HostedAccount.shared.isLoggedIn else { return false }
        running = true
        defer { running = false }
        do {
            try await push(context: context)
            try await pull(context: context)
            lastSyncAt = Date()
            // P0-46 成功即清零失败计数与错误记录
            consecutiveFailures = 0
            lastSyncError = nil
            try? UserDefaults.standard.removeObject(forKey: "bossai.sync.lastError")
            return true
        } catch {
            // P0-46 错误可见性：不再纯静默——记录最近错误与连续失败次数（供诊断与 UI 提示）。
            // 本地数据完整，下次仍会重试；连续失败是"信息可能未同步"的可观测信号。
            consecutiveFailures += 1
            lastSyncError = (error as NSError).localizedDescription
            try? UserDefaults.standard.set(lastSyncError, forKey: "bossai.sync.lastError")
            return false
        }
    }

    /// 是否需要"今日 3 点后的首次同步"：距上次同步已跨过今天的 03:00
    /// （用前台补偿替代 BGTask，避免为后台任务引入固定 Info.plist 的改动风险）
    func needsDailyCatchUp(now: Date = Date()) -> Bool {
        guard autoSyncEnabled else { return false }
        let cal = Calendar.current
        guard let today3 = cal.date(bySettingHour: 3, minute: 0, second: 0, of: now) else { return true }
        guard let last = lastSyncAt else { return true }
        return last < today3 && now >= today3
    }

    /// 前台补偿式每日同步（启动/回前台时调用；不满足条件则什么都不做）
    @discardableResult
    func dailySyncIfNeeded(context: ModelContext) async -> Bool {
        guard needsDailyCatchUp() else { return false }
        let ok = await syncNow(context: context)
        // P0-19 定时任务：同步后生成到期的早报/周报（失败静默）
        await BriefingService.shared.generateDueBriefings(context: context)
        return ok
    }

    // MARK: - 推送

    /// 推送：把本账号的对话与记忆序列化后分批上云。
    /// 只推 ownerKey == scopeKey 的条目（多账号数据隔离）；
    /// updatedAt 取 createdAt/updatedAt 的较大者（记忆条目 updatedAt 可能晚于创建）。
    private func push(context: ModelContext) async throws {
        let key = HostedAccount.scopeKey
        var items: [[String: Any]] = []

        // 10-22 P1：fetch 失败不能当成「没有数据」继续同步（会把空推送上去并推进游标）
        let convsToPush = try context.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.ownerKey == key }
        ))
        if !convsToPush.isEmpty {
            for c in convsToPush {
                items.append([
                    "kind": "conversation",
                    "refId": c.id.uuidString,
                    "updatedAt": Int(c.updatedAt.timeIntervalSince1970 * 1000),
                    "payload": Self.encodeConversation(c),
                ])
            }
        }
        let memoriesToPush = try context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.ownerKey == key }
        ))
        if !memoriesToPush.isEmpty {
            for m in memoriesToPush {
                items.append([
                    "kind": "memory",
                    "refId": m.id.uuidString,
                    "updatedAt": Int(max(m.createdAt, m.updatedAt).timeIntervalSince1970 * 1000),
                    "payload": Self.encodeMemory(m),
                ])
            }
        }
        // 分批发（服务端单次上限 200 条）：按 100 条切片，既留余量又减少请求次数
        var index = 0
        while index < items.count {
            let slice = Array(items[index..<min(index + 100, items.count)])
            let body: [String: Any] = ["items": slice]
            _ = try await HostedAccount.shared.syncPush(items: body)
            index += 100
        }
    }

    // MARK: - 拉取与合并

    /// 拉取：用 lastSyncAt（毫秒时间戳）做增量拉取，逐条按 kind 合并后统一落盘。
    /// deleted=true 的条目是墓碑，本地存在即删除。
    private func pull(context: ModelContext) async throws {
        let key = HostedAccount.scopeKey
        let since = Int((lastSyncAt?.timeIntervalSince1970 ?? 0) * 1000)
        let json = try await HostedAccount.shared.syncPull(since: since)
        let list = (json["items"] as? [[String: Any]]) ?? []
        guard !list.isEmpty else { return }

        for item in list {
            let kind = item["kind"] as? String ?? ""
            let payload = item["payload"] as? String ?? ""
            let deleted = (item["deleted"] as? Bool) ?? false
            switch kind {
            case "conversation":
                try mergeConversation(payload: payload, deleted: deleted, key: key, context: context)
            case "memory":
                try mergeMemory(payload: payload, deleted: deleted, key: key, context: context)
            default:
                break
            }
        }
        try? context.save()
    }

    /// 合并一条云端对话：墓碑→删除；已存在→LWW（远端更新才覆盖，本地为主）；
    /// 本机没有→整体新建（含全部消息，逐条还原 id/来源/附件等字段）。
    private func mergeConversation(payload: String, deleted: Bool, key: String, context: ModelContext) throws {
        guard let data = payload.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let idString = dict["id"] as? String, let uuid = UUID(uuidString: idString) else { return }

        // 10-22 P1：谓词补 ownerKey（此前只按 id 找，可能命中另一账号的同 id 记录）
        let existing = try context.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.id == uuid && $0.ownerKey == key }
        )).first
        if deleted {
            if let existing { context.delete(existing) }
            return
        }
        let remoteUpdated = Self.date(fromMilliseconds: dict["updatedAt"]) ?? Date()
        if let existing {
            // 10-22 P1 数据丢失修复：此前「已有会话」只更新元数据就 return，
            // 另一台设备后来新增的消息永远拉不下来（用户以为"同步了"，其实消息少了一半）。
            // 现在先按消息 id 做增量合并（去重），再对标题/摘要走 LWW。
            let existingIDs = Set(existing.messages.map { $0.id })
            for raw in (dict["messages"] as? [[String: Any]]) ?? [] {
                guard let mid = raw["id"] as? String,
                      let muuid = UUID(uuidString: mid),
                      !existingIDs.contains(muuid) else { continue }
                let msg = Message(role: raw["role"] as? String ?? "user", text: raw["text"] as? String ?? "")
                msg.id = muuid
                msg.sourcesJSON = raw["sourcesJSON"] as? String ?? ""
                msg.attachmentIds = raw["attachmentIds"] as? String ?? ""
                msg.createdAt = Self.date(fromMilliseconds: raw["createdAt"]) ?? remoteUpdated
                msg.conversation = existing
                msg.conversationID = existing.id
                context.insert(msg)
            }
            if remoteUpdated > existing.updatedAt {
                existing.title = dict["title"] as? String ?? existing.title
                existing.rollingSummary = dict["rollingSummary"] as? String ?? existing.rollingSummary
                existing.updatedAt = remoteUpdated
            }
            return
        }
        // 本机没有 → 新建（含消息）
        let conv = Conversation(expertId: dict["expertId"] as? String ?? "general",
                                title: dict["title"] as? String ?? "对话")
        conv.id = uuid
        conv.ownerKey = key
        conv.rollingSummary = dict["rollingSummary"] as? String ?? ""
        conv.updatedAt = remoteUpdated
        conv.createdAt = Self.date(fromMilliseconds: dict["createdAt"]) ?? remoteUpdated
        context.insert(conv)
        for raw in (dict["messages"] as? [[String: Any]]) ?? [] {
            let msg = Message(role: raw["role"] as? String ?? "user", text: raw["text"] as? String ?? "")
        msg.conversation = conv
        msg.conversationID = conv.id
            if let mid = raw["id"] as? String, let muuid = UUID(uuidString: mid) { msg.id = muuid }
            msg.sourcesJSON = raw["sourcesJSON"] as? String ?? ""
            msg.attachmentIds = raw["attachmentIds"] as? String ?? ""
            msg.createdAt = Self.date(fromMilliseconds: raw["createdAt"]) ?? remoteUpdated
            msg.conversation = conv
            context.insert(msg)
        }
    }

    /// 合并一条云端记忆：墓碑→删除；本地已有→跳过（记忆内容以本地编辑为准，
    /// 避免 LWW 覆盖用户在本地改过的记忆）；本机没有→新建。
    private func mergeMemory(payload: String, deleted: Bool, key: String, context: ModelContext) throws {
        guard let data = payload.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let idString = dict["id"] as? String, let uuid = UUID(uuidString: idString) else { return }
        let existing = try context.fetch(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == uuid })).first
        if deleted { if let existing { context.delete(existing) }; return }
        guard existing == nil else { return }
        let item = MemoryItem(content: dict["content"] as? String ?? "")
        item.id = uuid
        item.ownerKey = key
        if let created = Self.date(fromMilliseconds: dict["createdAt"]) { item.createdAt = created }
        if let updated = Self.date(fromMilliseconds: dict["updatedAt"]) { item.updatedAt = updated }
        context.insert(item)
    }

    // MARK: - 序列化

    /// 序列化一条对话为 JSON 字符串（云同步 payload）。
    /// 单字段截断（消息正文/来源 60K、摘要 20K）防单条超限；图片本体不上云。
    static func encodeConversation(_ c: Conversation) -> String {
        let messages: [[String: Any]] = c.messages.sorted { $0.createdAt < $1.createdAt }.map { m in
            var d: [String: Any] = [
                "id": m.id.uuidString,
                "role": m.role,
                "text": String(m.text.prefix(60_000)),
                "sourcesJSON": String(m.sourcesJSON.prefix(60_000)),
                "attachmentIds": m.attachmentIds,
                "createdAt": Int(m.createdAt.timeIntervalSince1970 * 1000),
            ]
            d["hasImage"] = m.imageData != nil          // 图片本体不上云（体积大，走后续对象存储）
            return d
        }
        let dict: [String: Any] = [
            "id": c.id.uuidString,
            "expertId": c.expertId,
            "title": c.title,
            "rollingSummary": String(c.rollingSummary.prefix(20_000)),
            "createdAt": Int(c.createdAt.timeIntervalSince1970 * 1000),
            "updatedAt": Int(c.updatedAt.timeIntervalSince1970 * 1000),
            "messages": messages,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 序列化一条记忆为 JSON 字符串（内容截断 10K）
    static func encodeMemory(_ m: MemoryItem) -> String {
        let dict: [String: Any] = [
            "id": m.id.uuidString,
            "content": String(m.content.prefix(10_000)),
            "createdAt": Int(m.createdAt.timeIntervalSince1970 * 1000),
            "updatedAt": Int(m.updatedAt.timeIntervalSince1970 * 1000),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 毫秒时间戳（JSON 里可能是 NSNumber）转 Date；无效/非正值返回 nil
    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    // MARK: - 后台任务（每日 3 点）

    /// 注册后台刷新任务（需在 App 启动时调用一次；identifier 必须出现在 Info.plist 白名单里）
    func registerBackgroundSync() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let ctx = SyncService.backgroundContext()
                var ok = false
                if let ctx { ok = await SyncService.shared.syncNow(context: ctx) }
                refresh.setTaskCompleted(success: ok)
                SyncService.shared.scheduleNextBackgroundSync()
            }
        }
        scheduleNextBackgroundSync()
    }

    /// 排下一次执行：目标 03:00（系统会在该时间窗内择机执行）
    func scheduleNextBackgroundSync() {
        guard autoSyncEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        var comps = DateComponents()
        comps.hour = 3
        comps.minute = 0
        let cal = Calendar.current
        var target = cal.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600 * 6)
        if target.timeIntervalSinceNow < 60 { target = target.addingTimeInterval(86400) }
        request.earliestBeginDate = target
        try? BGTaskScheduler.shared.submit(request)
    }

    /// 后台任务里没有 View 的 modelContext，这里按同一份 schema 现场建一个容器
    private static func backgroundContext() -> ModelContext? {
        let schema = Schema([Conversation.self, Message.self, MemoryItem.self, StoredFile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else { return nil }
        return ModelContext(container)
    }
}
