import Foundation
import CryptoKit
import ImageIO
import UIKit

struct CloudAssetRef: Codable, Equatable, Sendable {
    let id: String
    let sha256: String
    let mime: String
    let byteCount: Int
    var width: Int?
    var height: Int?
    var variants: [String: CloudAssetRef]?
}

/// The database stores references; bytes live once in private object storage.
/// Signed URLs are deliberately never persisted.
enum CloudAssetStore {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func contentType(_ data: Data, ext: String = "") -> String {
        if data.starts(with: [137, 80, 78, 71]) { return "image/png" }
        if data.starts(with: [255, 216]) { return "image/jpeg" }
        if data.starts(with: [71, 73, 70]) { return "image/gif" }
        if data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
           String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP" { return "image/webp" }
        let types = ["pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown",
            "csv": "text/csv", "json": "application/json", "zip": "application/zip",
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"]
        return types[ext.lowercased()] ?? "application/octet-stream"
    }
    static func decode(_ json: [String: Any]) throws -> CloudAssetRef {
        try JSONDecoder().decode(CloudAssetRef.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func upload(_ data: Data, mime: String, session: CloudSession) async throws -> CloudAssetRef {
        let spec: [String: Any] = ["sha256": sha256(data), "byteCount": data.count, "mime": mime]
        let prepared = try await session.request("/assets/prepare", method: "POST", body: spec)
        if let raw = prepared["asset"] as? [String: Any] { return try decode(raw) }
        guard let id = prepared["assetId"] as? String, let upload = prepared["upload"] as? [String: Any],
              let rawURL = upload["url"] as? String, let url = URL(string: rawURL), allowed(url) else {
            throw HostedError.network("暂时无法准备云端保存，图片仍保留在本机。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"; request.timeoutInterval = 90; request.httpBody = data
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue("private", forHTTPHeaderField: "x-cos-acl")
        if let auth = upload["authorization"] as? String { request.setValue(auth, forHTTPHeaderField: "Authorization") }
        if let auth = upload["authorization"] as? String { request.setValue(auth, forHTTPHeaderField: "Signature") }
        if let path = upload["cloudPath"] as? String { request.setValue(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), forHTTPHeaderField: "key") }
        if let fileId = upload["cosFileId"] as? String { request.setValue(fileId, forHTTPHeaderField: "x-cos-meta-fileid") }
        if let token = upload["token"] as? String, !token.isEmpty { request.setValue(token, forHTTPHeaderField: "x-cos-security-token") }
        let (_, response) = try await BoundedHTTPClient.data(for: request, session: BoundedHTTPClient.imageSession, limit: 128 * 1024)
        try await session.validate()
        guard (200..<300).contains(response.statusCode) else { throw HostedError.network("云端保存暂未完成，稍后会重试。") }
        let committed = try await session.request("/assets/commit", method: "POST", body: ["id": id])
        guard let raw = committed["asset"] as? [String: Any] else { throw SyncError.invalidResponse("缺少资产确认") }
        return try decode(raw)
    }
    static func download(_ asset: CloudAssetRef, session: CloudSession) async throws -> Data {
        let cache = cacheURL(asset, owner: session.owner)
        if let data = try? Data(contentsOf: cache), data.count == asset.byteCount, sha256(data) == asset.sha256 {
            try await session.validate()
            return data
        }
        let json = try await session.request("/assets/urls", method: "POST", body: ["ids": [asset.id]])
        guard let items = json["items"] as? [[String: Any]],
              let raw = items.first?["url"] as? String, let url = URL(string: raw), allowed(url) else {
            throw HostedError.network("暂时无法读取这份文件，请稍后重试。")
        }
        let (data, response) = try await BoundedHTTPClient.data(for: URLRequest(url: url),
            session: BoundedHTTPClient.imageSession, limit: 24 * 1024 * 1024)
        try await session.validate()
        guard response.statusCode == 200, data.count == asset.byteCount, sha256(data) == asset.sha256 else {
            throw HostedError.network("文件下载尚未完整，将保留记录供稍后重试。")
        }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        trimCache(cache.deletingLastPathComponent())
        return data
    }
    static func cacheURL(_ asset: CloudAssetRef, owner: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudAssets", isDirectory: true)
            .appendingPathComponent(sha256(Data(owner.utf8)), isDirectory: true)
            .appendingPathComponent(asset.sha256)
    }
    private static func trimCache(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let rows = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = rows.reduce(0) { $0 + $1.1 }
        for row in rows where total > 128 * 1024 * 1024 {
            if (try? FileManager.default.removeItem(at: row.0)) != nil { total -= row.1 }
        }
    }
    static func uploadImage(_ data: Data, session: CloudSession) async throws -> CloudAssetRef {
        var original = try await upload(data, mime: contentType(data), session: session)
        if let thumb = thumbnail(data, maxPixel: 480) {
            let variant = try await upload(thumb, mime: contentType(thumb), session: session)
            original.variants = ["thumbnail": variant]
        }
        return original
    }
    static func thumbnail(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.78)
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return [".myqcloud.com", ".tcloudbase.com", ".tcloudbaseapp.com", ".tencentcloudapi.com"].contains { host.hasSuffix($0) }
    }
    static func encode(_ refs: [CloudAssetRef]) -> String {
        guard let data = try? JSONEncoder().encode(refs) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
    static func references(_ raw: String) -> [CloudAssetRef] {
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CloudAssetRef].self, from: data)) ?? []
    }
}
