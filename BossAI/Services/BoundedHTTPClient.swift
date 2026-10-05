import Foundation

enum BoundedHTTPClient {
    static func session(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.timeoutIntervalForRequest = min(resourceTimeout, 30)
        return URLSession(configuration: configuration)
    }
    static let searchSession = session(resourceTimeout: 10)
    static let imageSession = session(resourceTimeout: 180)
    static let chatSession = session(resourceTimeout: 180)
    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var result = Data(); result.reserveCapacity(min(limit, 65536))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard result.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            result.append(byte)
        }
        return (result, http)
    }
}
