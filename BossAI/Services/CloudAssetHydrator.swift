import Foundation
import SwiftData

/// Materializes a selected reference, never the whole cloud history.
@MainActor
enum CloudAssetHydrator {
    static func file(_ file: StoredFile, session: CloudSession) async throws {
        let url = FileStore.url(for: file)
        if FileManager.default.fileExists(atPath: url.path) { return }
        guard file.ownerKey == session.owner,
              let asset = CloudAssetStore.references(file.cloudAssetJSON).first else {
            throw HostedError.input("这张参考图在本机没有副本，请重新上传。")
        }
        let bytes = try await CloudAssetStore.download(asset, session: session)
        try session.validate()
        guard file.modelContext != nil, file.ownerKey == session.owner else { throw CancellationError() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func image(_ message: Message, session: CloudSession) async throws -> Data {
        if let bytes = message.imageData { return bytes }
        guard message.conversation?.ownerKey == session.owner,
              let asset = CloudAssetStore.references(message.imageAssetsJSON).first else {
            throw HostedError.input("找不到要编辑的图片，请重新选择或上传。")
        }
        let bytes = try await CloudAssetStore.download(asset, session: session)
        try session.validate()
        guard message.modelContext != nil, message.conversation?.ownerKey == session.owner else { throw CancellationError() }
        // The cache owns downloaded bytes. Restoring a reference does not rewrite sync metadata.
        return bytes
    }
}
