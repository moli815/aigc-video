import Foundation
import SwiftData

/// Builds and stores a document independently of the tool/streaming protocol.
@MainActor
enum DocumentUseCase {
    nonisolated static func format(_ raw: String) -> DocumentFormat? {
        ["word": DocumentFormat.word, "docx": .word, "ppt": .ppt, "pptx": .ppt,
         "powerpoint": .ppt, "slide": .ppt, "excel": .excel, "xlsx": .excel,
         "sheet": .excel, "table": .excel, "pdf": .pdf][raw.lowercased()]
    }
    static func create(arguments: String, expertID: String, capability: ExpertCapability,
                       conversation: Conversation, context: ModelContext) async throws -> String {
        guard let args = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else {
            throw ExpertSkillError.invalidInput("文档输入未解析完整")
        }
        let rawFormat = (args["format"] as? String ?? "word").lowercased()
        guard let format = Self.format(rawFormat) else { throw ExpertSkillError.invalidInput("仅支持 Word、PPT、Excel 和 PDF") }
        let filename = args["filename"] as? String ?? "文档"
        let title = args["title"] as? String ?? filename
        let content = args["content"] as? String ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExpertSkillError.invalidInput("文档正文为空") }
        let validation = try ExpertSkillRuntime.validateDocument(content, format: format.rawValue, profile: capability)
        guard validation.structurePassed else {
            throw ExpertSkillError.invalidInput("交付结构未通过；缺少：" + validation.missingSections.joined(separator: "、"))
        }
        let owner = conversation.ownerKey
        guard owner == HostedAccount.scopeKey else { throw CancellationError() }
        let theme = (args["theme"] as? String).flatMap { $0.isEmpty ? nil : DocTheme.named($0) } ?? DocTheme.forExpert(expertID)
        let span = PerformanceTrace.begin("DocumentBuild")
        defer { PerformanceTrace.end("DocumentBuild", span) }
        let data = try await DocumentBuilder.buildAsync(format: format, title: title, content: content, theme: theme)
        try Task.checkCancellation()
        guard owner == HostedAccount.scopeKey, conversation.modelContext != nil else { throw CancellationError() }
        let safe = DocumentBuilder.safeFilename(filename, fallback: title)
        let finalName = safe.hasSuffix("." + format.ext) ? safe : safe + "." + format.ext
        let record = try await FileStore.storeAsync(data: data, filename: finalName, kind: .generated,
            sourceConversationId: conversation.id.uuidString, textContent: content, context: context)
        try Task.checkCancellation()
        guard owner == HostedAccount.scopeKey, conversation.modelContext != nil else { throw CancellationError() }
        try ToolPipeline.persistArtifact(conversation: conversation, attachmentIDs: record.id.uuidString, context: context)
        return finalName
    }
}
