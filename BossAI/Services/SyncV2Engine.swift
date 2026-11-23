import Foundation
import SwiftData

/// Message-level sync, a disk-backed outbox and server-committed revision cursor.
/// Existing SwiftData models remain readable; large binary data never enters sync JSON.
@MainActor
enum SyncV2Engine {
    struct Record: Codable {
        let kind: String
        let refId: String
        let payload: String
        var baseVersion: Int
        var key: String { kind + ":" + refId }
        var fingerprint: String { CloudAssetStore.sha256(Data(payload.utf8)) }
        var json: [String: Any] { ["kind": kind, "refId": refId, "payload": payload, "baseVersion": baseVersion] }
    }
    final class Checkpoint: Codable {
        var cursor = 0
        var legacyImported = false
        var versions: [String: Int] = [:]
        var acknowledged: [String: String] = [:]
        var pending: [String: Record] = [:]
        var deletedConversationIDs: Set<String>?
    }
    private static var checkpoints: [String: Checkpoint] = [:]
    static func location(_ owner: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncV2", isDirectory: true)
            .appendingPathComponent(CloudAssetStore.sha256(Data(owner.utf8)) + ".json")
    }
    static func load(_ owner: String) throws -> Checkpoint {
        if let cached = checkpoints[owner] { return cached }
        let url = location(owner)
        let state: Checkpoint
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url))
        } else { state = Checkpoint() }
        checkpoints[owner] = state
        return state
    }
    static func save(_ state: Checkpoint, owner: String) throws {
        let url = location(owner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func needsLegacyImport(_ owner: String) throws -> Bool { try !load(owner).legacyImported }
    static func enqueueDeletion(kind: String, id: UUID, owner: String) throws {
        var state = try load(owner)
        let payload = "{\"id\":\"\(id.uuidString)\",\"isDeleted\":true}"
        let key = kind + ":" + id.uuidString
        state.pending[key] = Record(kind: kind, refId: id.uuidString, payload: payload, baseVersion: state.versions[key] ?? 0)
        try save(state, owner: owner)
    }
    static func cancelDeletion(kind: String, id: UUID, owner: String) {
        guard let state = try? load(owner) else { return }
        state.pending.removeValue(forKey: kind + ":" + id.uuidString)
        try? save(state, owner: owner)
    }
    static func isDeletedConversation(_ id: UUID, owner: String) -> Bool {
        guard let state = try? load(owner) else { return false }
        return state.deletedConversationIDs?.contains(id.uuidString) == true || hasPendingDeletion(kind: "conversation", id: id, owner: owner)
    }
    static func hasPendingDeletion(kind: String, id: UUID, owner: String) -> Bool {
        guard let state = try? load(owner), let pending = state.pending[kind + ":" + id.uuidString],
              let raw = pending.payload.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return false }
        return payload["isDeleted"] as? Bool == true
    }
    static func noteDeletedConversation(_ id: UUID, owner: String) throws {
        let state = try load(owner)
        var ids = state.deletedConversationIDs ?? []
        ids.insert(id.uuidString)
        state.deletedConversationIDs = ids
        try save(state, owner: owner)
    }

    static func synchronize(context: ModelContext, session: CloudSession) async throws {
        var state = try load(session.owner)
        try session.validate()
        if !state.legacyImported {
            try await bootstrapRemote(context: context, session: session, state: &state)
        }
        let assetsPending = try await uploadLocalAssets(context: context, session: session)
        let snapshots = try records(context: context, owner: session.owner)
        for record in snapshots where state.acknowledged[record.key] != record.fingerprint {
            var pending = record
            pending.baseVersion = state.pending[record.key]?.baseVersion ?? state.versions[record.key] ?? 0
            state.pending[record.key] = pending
        }
        state.legacyImported = true
        try save(state, owner: session.owner) // Outbox precedes every network write.

        var conflictPasses = 0
        while !state.pending.isEmpty {
            try session.validate()
            let ordered = state.pending.values.sorted {
                let a = $0.kind == "conversation" ? 0 : 1, b = $1.kind == "conversation" ? 0 : 1
                return a == b ? $0.key < $1.key : a < b
            }
            var batch: [Record] = [], bytes = 0
            for record in ordered.prefix(25) {
                let size = record.payload.utf8.count + 256
                if !batch.isEmpty && bytes + size > 512 * 1024 { break }
                guard size <= 245 * 1024 else { throw SyncError.invalidPayload("一条消息过长，原文仍保留在本机") }
                batch.append(record); bytes += size
            }
            let result = try await session.request("/sync/v2/push", method: "POST", body: ["records": batch.map(\.json)])
            guard let acks = result["acknowledged"] as? [[String: Any]] else { throw SyncError.invalidResponse("缺少同步回执") }
            for ack in acks {
                let key = (ack["kind"] as? String ?? "") + ":" + (ack["refId"] as? String ?? "")
                guard let sent = batch.first(where: { $0.key == key }) else { continue }
                state.versions[key] = (ack["version"] as? NSNumber)?.intValue ?? 0
                state.acknowledged[key] = sent.fingerprint
                if state.pending[key]?.fingerprint == sent.fingerprint { state.pending.removeValue(forKey: key) }
            }
            let conflicts = result["conflicts"] as? [[String: Any]] ?? []
            for remote in conflicts {
                let key = (remote["kind"] as? String ?? "") + ":" + (remote["refId"] as? String ?? "")
                guard var pending = state.pending[key] else { continue }
                let version = (remote["version"] as? NSNumber)?.intValue ?? 0
                if remote["deleted"] as? Bool == true {
                    try apply(remote, context: context, owner: session.owner)
                    state.pending.removeValue(forKey: key)
                    state.acknowledged.removeValue(forKey: key)
                } else if pending.kind == "message" {
                    // Keep both concurrent message revisions. Save the local copy before
                    // accepting the server version, rather than stalling the entire outbox.
                    try preserveLocalMessage(id: pending.refId, context: context, owner: session.owner)
                    try apply(remote, context: context, owner: session.owner)
                    state.pending.removeValue(forKey: key)
                    if let local = try records(context: context, owner: session.owner).first(where: { $0.key == key }) {
                        state.acknowledged[key] = local.fingerprint
                    }
                } else {
                    // Metadata edits can be rebased; the server version is now known.
                    pending.baseVersion = version
                    state.pending[key] = pending
                }
                state.versions[key] = version
            }
            if !conflicts.isEmpty {
                try context.save()
                for var local in try records(context: context, owner: session.owner)
                    where state.pending[local.key] == nil && state.acknowledged[local.key] != local.fingerprint {
                    local.baseVersion = state.versions[local.key] ?? 0
                    state.pending[local.key] = local
                }
                conflictPasses += 1
            }
            try save(state, owner: session.owner)
            guard conflictPasses < 4 else { throw SyncError.invalidPayload("多台设备正在修改，本机内容已保留，稍后再同步") }
            if acks.isEmpty && conflicts.isEmpty { throw SyncError.invalidResponse("同步未确认任何记录") }
        }

        var after = state.cursor, watermark: Int?
        for page in 0..<1000 {
            try session.validate()
            var path = "/sync/v2/pull?since=\(state.cursor)&after=\(after)&limit=50"
            if let watermark { path += "&watermark=\(watermark)" }
            let response = try await session.request(path, responseLimit: 16 * 1024 * 1024)
            guard let rows = response["items"] as? [[String: Any]],
                  let water = (response["watermark"] as? NSNumber)?.intValue,
                  let next = (response["after"] as? NSNumber)?.intValue else { throw SyncError.invalidResponse("同步分页不完整") }
            watermark = water
            // Snapshot comparison prevents incoming updates overwriting edits made while awaiting HTTP.
            let live = Dictionary(uniqueKeysWithValues: try records(context: context, owner: session.owner).map { ($0.key, $0) })
            var appliedKeys = Set<String>()
            for row in rows {
                let key = (row["kind"] as? String ?? "") + ":" + (row["refId"] as? String ?? "")
                let deleted = row["deleted"] as? Bool ?? false
                if !deleted, state.pending[key] != nil { continue }
                if !deleted, let local = live[key], let acknowledged = state.acknowledged[key], local.fingerprint != acknowledged {
                    var pending = local; pending.baseVersion = state.versions[key] ?? 0
                    state.pending[key] = pending; continue
                }
                try apply(row, context: context, owner: session.owner)
                state.versions[key] = (row["version"] as? NSNumber)?.intValue ?? 0
                if deleted { state.pending.removeValue(forKey: key); state.acknowledged.removeValue(forKey: key) }
                else { appliedKeys.insert(key) }
            }
            for local in try records(context: context, owner: session.owner) where appliedKeys.contains(local.key) {
                state.acknowledged[local.key] = local.fingerprint
            }
            try context.save()
            let hasMore = response["hasMore"] as? Bool ?? false
            if !hasMore {
                state.cursor = water
                try save(state, owner: session.owner)
                break
            }
            guard next > after, page < 999 else { throw SyncError.invalidResponse("同步游标未前进") }
            after = next
        }
        if assetsPending { throw SyncError.invalidResponse("对话已同步，部分图片或文件仍在等待上传，本机副本已保留") }
    }

    static func preserveLocalMessage(id rawID: String, context: ModelContext, owner: String) throws {
        guard let id = UUID(uuidString: rawID) else { throw SyncError.invalidPayload("无效消息编号") }
        let candidates = try context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id }))
        guard let local = candidates.first(where: { $0.conversation?.ownerKey == owner }), let conv = local.conversation else { return }
        let fingerprint = try records(context: context, owner: owner).first { $0.key == "message:" + rawID }?.fingerprint ?? local.text
        let digest = CloudAssetStore.sha256(Data((owner + rawID + fingerprint).utf8))
        let hex = Array(digest.prefix(32))
        let stable = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        guard let copyID = UUID(uuidString: stable) else { throw SyncError.invalidPayload("无法保存冲突副本") }
        if conv.messages.contains(where: { $0.id == copyID }) { return }
        let copy = Message(role: local.role, text: local.text, imageData: local.imageData)
        copy.id = copyID
        copy.conversation = conv; copy.conversationID = conv.id
        copy.sourcesJSON = local.sourcesJSON; copy.attachmentIds = local.attachmentIds
        copy.extraImagesJSON = local.extraImagesJSON; copy.imageAssetsJSON = local.imageAssetsJSON
        copy.seriesMetaJSON = local.seriesMetaJSON; copy.createdAt = local.createdAt.addingTimeInterval(0.001)
        context.insert(copy)
    }

    static func records(context: ModelContext, owner: String) throws -> [Record] {
        var output: [Record] = []
        func append(_ kind: String, _ id: UUID, _ payload: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            guard let json = String(data: data, encoding: .utf8) else { throw SyncError.invalidPayload("编码失败") }
            output.append(Record(kind: kind, refId: id.uuidString, payload: json, baseVersion: 0))
        }
        let convs = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.ownerKey == owner }))
        for conv in convs {
            try append("conversation", conv.id, ["id": conv.id.uuidString, "expertId": conv.expertId, "title": conv.title,
                "rollingSummary": conv.rollingSummary, "summarizedCount": conv.summarizedCount, "isDeleted": conv.isDeleted,
                "createdAt": milliseconds(conv.createdAt), "updatedAt": milliseconds(conv.updatedAt)])
            guard !conv.isDeleted else { continue }
            for msg in conv.messages {
                guard !msg.text.isEmpty || msg.imageData != nil || !msg.attachmentIds.isEmpty || !msg.imageAssetsJSON.isEmpty else { continue }
                let assets = CloudAssetStore.references(msg.imageAssetsJSON)
                let rawAssets = try JSONSerialization.jsonObject(with: JSONEncoder().encode(assets))
                try append("message", msg.id, ["id": msg.id.uuidString, "conversationId": conv.id.uuidString,
                    "role": msg.role, "text": msg.text, "sourcesJSON": msg.sourcesJSON, "attachmentIds": msg.attachmentIds,
                    "createdAt": milliseconds(msg.createdAt), "seriesMetaJSON": msg.seriesMetaJSON, "assets": rawAssets])
            }
        }
        for memory in try context.fetch(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.ownerKey == owner })) {
            try append("memory", memory.id, ["id": memory.id.uuidString, "content": memory.content, "source": memory.source,
                "isDeleted": memory.isDeleted, "createdAt": milliseconds(memory.createdAt), "updatedAt": milliseconds(memory.updatedAt)])
        }
        for file in try context.fetch(FetchDescriptor<StoredFile>(predicate: #Predicate { $0.ownerKey == owner })) {
            var payload: [String: Any] = ["id": file.id.uuidString, "name": file.name, "ext": file.ext,
                "kindRaw": file.kindRaw, "categoryRaw": file.categoryRaw, "byteCount": file.byteCount,
                "createdAt": milliseconds(file.createdAt), "sourceConversationId": file.sourceConversationId,
                "textContent": String(file.textContent.prefix(40000)), "isFavorite": file.isFavorite]
            if let asset = CloudAssetStore.references(file.cloudAssetJSON).first {
                payload["asset"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(asset))
            }
            try append("file", file.id, payload)
        }
        return output
    }

    private static func uploadLocalAssets(context: ModelContext, session: CloudSession) async throws -> Bool {
        let owner = session.owner
        var assetsPending = false
        let convs = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.ownerKey == owner && !$0.isDeleted }))
        for conv in convs {
            for message in conv.messages {
                do {
                let images = message.allImages
                guard !images.isEmpty else { continue }
                let existing = CloudAssetStore.references(message.imageAssetsJSON)
                if existing.map(\.sha256) == images.map(CloudAssetStore.sha256) { continue }
                var refs: [CloudAssetRef] = []
                for data in images {
                    if let old = existing.first(where: { $0.sha256 == CloudAssetStore.sha256(data) }) { refs.append(old) }
                    else { refs.append(try await CloudAssetStore.uploadImage(data, session: session)) }
                }
                try session.validate()
                guard message.modelContext != nil, conv.modelContext != nil, !conv.isDeleted else { throw CancellationError() }
                message.imageAssetsJSON = CloudAssetStore.encode(refs)
                try context.save()
                } catch {
                    try session.validate()
                    if error is CancellationError { throw error }
                    assetsPending = true
                    DiagnosticQueue.shared.record(domain: "asset", stage: "message_upload", code: "ASSET_UPLOAD_PENDING")
                }
            }
        }
        for file in try context.fetch(FetchDescriptor<StoredFile>(predicate: #Predicate { $0.ownerKey == owner })) {
            do {
            if !file.cloudAssetJSON.isEmpty { continue }
            let url = FileStore.url(for: file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue } // Legacy lost bytes cannot be recreated.
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { continue }
            let asset = try await CloudAssetStore.upload(data, mime: CloudAssetStore.contentType(data, ext: file.ext), session: session)
            try session.validate()
            guard file.modelContext != nil else { throw CancellationError() }
            file.cloudAssetJSON = CloudAssetStore.encode([asset]); file.contentHash = asset.sha256; try context.save()
            } catch {
                try session.validate()
                if error is CancellationError { throw error }
                assetsPending = true
                DiagnosticQueue.shared.record(domain: "asset", stage: "file_upload", code: "ASSET_UPLOAD_PENDING")
            }
        }
        return assetsPending
    }

    private static func bootstrapRemote(context: ModelContext, session: CloudSession, state: inout Checkpoint) async throws {
        var after = 0, watermark: Int?
        for page in 0..<1000 {
            var path = "/sync/v2/pull?since=0&after=\(after)&limit=50"
            if let watermark { path += "&watermark=\(watermark)" }
            let response = try await session.request(path, responseLimit: 16 * 1024 * 1024)
            guard let rows = response["items"] as? [[String: Any]],
                  let water = (response["watermark"] as? NSNumber)?.intValue,
                  let next = (response["after"] as? NSNumber)?.intValue else { throw SyncError.invalidResponse("首次恢复缺少游标") }
            watermark = water
            var appliedKeys = Set<String>()
            for row in rows {
                // Preserve an unversioned old client's different message as a distinct local copy.
                if row["kind"] as? String == "message", let raw = row["payload"] as? String,
                   let data = raw.data(using: .utf8), let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = UUID(uuidString: payload["id"] as? String ?? ""), let remoteText = payload["text"] as? String {
                    let owner = session.owner
                    let messages = try context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id }))
                    if let local = messages.first(where: { $0.conversation?.ownerKey == owner }),
                       !local.text.isEmpty, local.text != remoteText, let conv = local.conversation {
                        let copy = Message(role: local.role, text: local.text, imageData: local.imageData)
                        copy.conversation = conv; copy.conversationID = conv.id
                        copy.sourcesJSON = local.sourcesJSON; copy.attachmentIds = local.attachmentIds
                        copy.extraImagesJSON = local.extraImagesJSON; copy.imageAssetsJSON = local.imageAssetsJSON
                        copy.seriesMetaJSON = local.seriesMetaJSON; copy.createdAt = local.createdAt.addingTimeInterval(0.001)
                        context.insert(copy)
                    }
                }
                try apply(row, context: context, owner: session.owner)
                let key = (row["kind"] as? String ?? "") + ":" + (row["refId"] as? String ?? "")
                state.versions[key] = (row["version"] as? NSNumber)?.intValue ?? 0
                appliedKeys.insert(key)
            }
            try context.save()
            for record in try records(context: context, owner: session.owner) where appliedKeys.contains(record.key) {
                state.acknowledged[record.key] = record.fingerprint
            }
            if !(response["hasMore"] as? Bool ?? false) { state.cursor = water; return }
            guard next > after, page < 999 else { throw SyncError.invalidResponse("首次恢复游标未前进") }
            after = next
        }
    }

    static func apply(_ row: [String: Any], context: ModelContext, owner: String) throws {
        guard let kind = row["kind"] as? String, let raw = row["payload"] as? String,
              let data = raw.data(using: .utf8), let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = UUID(uuidString: payload["id"] as? String ?? "") else { throw SyncError.invalidPayload("无效同步记录") }
        let deleted = row["deleted"] as? Bool ?? false
        switch kind {
        case "conversation":
            let found = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id && $0.ownerKey == owner })).first
            if deleted {
                try noteDeletedConversation(id, owner: owner)
                if let found { context.delete(found) }
                ConversationDeletion.confirmRemoteDeleted(id)
                return
            }
            if isDeletedConversation(id, owner: owner) { return }
            if ConversationDeletion.isPendingDelete(id) { return }
            let conv = found ?? Conversation(expertId: payload["expertId"] as? String ?? "general", title: "")
            if found == nil { conv.id = id; conv.ownerKey = owner; context.insert(conv) }
            conv.title = payload["title"] as? String ?? "对话"; conv.expertId = payload["expertId"] as? String ?? "general"
            conv.rollingSummary = payload["rollingSummary"] as? String ?? ""; conv.summarizedCount = payload["summarizedCount"] as? Int ?? 0
            conv.createdAt = date(payload["createdAt"]); conv.updatedAt = date(payload["updatedAt"])
        case "message":
            guard let parent = UUID(uuidString: payload["conversationId"] as? String ?? "") else { throw SyncError.invalidPayload("消息缺少会话") }
            if ConversationDeletion.isPendingDelete(parent) || isDeletedConversation(parent, owner: owner) { return }
            var conv = try context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == parent && $0.ownerKey == owner })).first
            if conv == nil { let stub = Conversation(expertId: "general", title: "对话"); stub.id = parent; stub.ownerKey = owner; context.insert(stub); conv = stub }
            guard let conv else { return }
            let found = conv.messages.first { $0.id == id }
            if deleted { if let found { context.delete(found) }; return }
            let msg = found ?? Message(role: payload["role"] as? String ?? "assistant", text: "")
            if found == nil { msg.id = id; msg.conversation = conv; msg.conversationID = parent; context.insert(msg) }
            msg.text = payload["text"] as? String ?? ""; msg.sourcesJSON = payload["sourcesJSON"] as? String ?? ""
            msg.attachmentIds = payload["attachmentIds"] as? String ?? ""; msg.createdAt = date(payload["createdAt"])
            msg.seriesMetaJSON = payload["seriesMetaJSON"] as? String ?? ""
            if let assets = payload["assets"] as? [[String: Any]] {
                let encoded = try JSONSerialization.data(withJSONObject: assets)
                let refs = try JSONDecoder().decode([CloudAssetRef].self, from: encoded)
                if !refs.isEmpty, !msg.allImages.isEmpty, refs.map(\.sha256) != msg.allImages.map(CloudAssetStore.sha256) {
                    msg.imageData = nil; msg.extraImagesJSON = nil; msg.thumbnailData = nil
                }
                msg.imageAssetsJSON = String(data: encoded, encoding: .utf8) ?? "[]"
            }
        case "memory":
            let found = try context.fetch(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.id == id && $0.ownerKey == owner })).first
            let item = found ?? MemoryItem(content: "")
            if found == nil { item.id = id; item.ownerKey = owner; context.insert(item) }
            item.isDeleted = deleted; item.content = payload["content"] as? String ?? ""; item.source = payload["source"] as? String ?? ""
            item.createdAt = date(payload["createdAt"]); item.updatedAt = date(payload["updatedAt"])
        case "file":
            let found = try context.fetch(FetchDescriptor<StoredFile>(predicate: #Predicate { $0.id == id && $0.ownerKey == owner })).first
            if deleted { if let found { context.delete(found) }; return }
            let ext = (payload["ext"] as? String ?? "dat").filter { $0.isLetter || $0.isNumber }
            let file = found ?? StoredFile(name: "文件", ext: ext, storedName: "\(id.uuidString).\(ext)", kind: .uploaded, category: .other, byteCount: 0)
            if found == nil { file.id = id; file.ownerKey = owner; context.insert(file) }
            file.name = payload["name"] as? String ?? "文件"; file.ext = ext
            file.kindRaw = payload["kindRaw"] as? String ?? "uploaded"; file.categoryRaw = payload["categoryRaw"] as? String ?? "other"
            file.byteCount = payload["byteCount"] as? Int ?? 0; file.createdAt = date(payload["createdAt"])
            file.sourceConversationId = payload["sourceConversationId"] as? String ?? ""; file.textContent = payload["textContent"] as? String ?? ""
            file.isFavorite = payload["isFavorite"] as? Bool ?? false
            if let rawAsset = payload["asset"] as? [String: Any] {
                let asset = try CloudAssetStore.decode(rawAsset)
                file.cloudAssetJSON = CloudAssetStore.encode([asset]); file.contentHash = asset.sha256
            }
        default: throw SyncError.invalidPayload("需要更新客户端以读取此类型")
        }
    }
    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ value: Any?) -> Date { Date(timeIntervalSince1970: ((value as? NSNumber)?.doubleValue ?? 0) / 1000) }
}
