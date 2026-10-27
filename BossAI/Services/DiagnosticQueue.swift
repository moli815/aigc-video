import Foundation
import CryptoKit

/// Bounded, durable, account-scoped delivery. Failed reports never report themselves.
@MainActor
final class DiagnosticQueue {
    static let shared = DiagnosticQueue()
    struct Event: Codable, Equatable {
        let eventId: String
        let createdAt: Date
        let fields: [String: String]
    }
    private var flushing = false
    private let allowed = Set(["traceId", "requestId", "jobId", "turnId", "appBuild", "domain",
                               "stage", "errorCode", "model", "ratio", "billingState", "archiveState", "platform", "durationMs"])
    private func location(_ owner: String) -> URL {
        let scope = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent(scope + ".json")
    }
    private func load(_ owner: String) -> [Event] {
        guard let data = try? Data(contentsOf: location(owner)),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        return events.filter { Date().timeIntervalSince($0.createdAt) < 7 * 86400 }
    }
    private func save(_ events: [Event], owner: String) throws {
        let url = location(owner)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(events.suffix(200))).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func record(domain: String, stage: String, code: String = "", requestId: String = "",
                fields: [String: String] = [:]) {
        guard let session = CloudSession.capture() else { return }
        var safe = fields.filter { allowed.contains($0.key) }.mapValues { String($0.prefix(100)) }
        safe["domain"] = String(domain.prefix(40)); safe["stage"] = String(stage.prefix(60))
        safe["errorCode"] = String(code.prefix(80)); safe["requestId"] = String(requestId.prefix(100))
        safe["platform"] = "ios"
        safe["appBuild"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var events = load(session.owner)
        events.append(Event(eventId: UUID().uuidString, createdAt: Date(), fields: safe))
        do { try save(events, owner: session.owner) }
        catch { PerformanceTrace.event("diagnostic_queue_write_failed"); return }
        Task { await flush() }
    }
    func flush() async {
        guard !flushing, let session = CloudSession.capture() else { return }
        flushing = true
        defer { flushing = false }
        do {
            for _ in 0..<8 {
                try session.validate()
                let pending = Array(load(session.owner).prefix(25))
                if pending.isEmpty { return }
                let batch: [[String: Any]] = pending.map { event in
                    var item: [String: Any] = event.fields
                    item["eventId"] = event.eventId
                    return item
                }
                let result = try await session.request("/events", method: "POST", body: ["events": batch])
                guard let ids = result["acceptedIds"] as? [String], !ids.isEmpty else { return }
                let accepted = Set(ids)
                try session.validate()
                try save(load(session.owner).filter { !accepted.contains($0.eventId) }, owner: session.owner)
            }
        } catch { /* The durable queue is retried on the next activation. */ }
    }
}
