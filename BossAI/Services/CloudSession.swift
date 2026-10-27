import Foundation

/// Pins credentials and owner across awaits; never borrows a new account's token.
struct CloudSession: Sendable {
    let owner: String
    let token: String

    @MainActor static func capture() -> CloudSession? {
        guard HostedAccount.isHostedActive, HostedAccount.shared.isLoggedIn,
              let token = HostedAccount.shared.token, !token.isEmpty else { return nil }
        return CloudSession(owner: HostedAccount.scopeKey, token: token)
    }

    @MainActor func validate() throws {
        guard HostedAccount.scopeKey == owner, HostedAccount.shared.token == token else {
            throw CancellationError()
        }
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                 responseLimit: Int = 2 * 1024 * 1024) async throws -> [String: Any] {
        try Task.checkCancellation()
        try await validate()
        guard path.hasPrefix("/"), let url = URL(string: AppConfig.hostedAPIBase + path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-Id")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        let (data, response) = try await BoundedHTTPClient.data(for: request,
            session: BoundedHTTPClient.chatSession, limit: responseLimit)
        try await validate()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode) else {
            throw HostedError.server(code: json["error"] as? String ?? "CLOUD_REQUEST_FAILED",
                status: response.statusCode,
                message: FriendlyError.serverMessage(from: json) ?? "云端暂时没有完成这次操作，请稍后重试。")
        }
        return json
    }
}
