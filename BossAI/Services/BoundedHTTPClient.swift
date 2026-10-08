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
        // 批量缓冲：逐字节 append 会在大页面上造成数十万次 Data 扩容拷贝，
        // 攒满 16KB 再一次性 memcpy 进结果，取消与上限语义保持不变。
        var pending = [UInt8](); pending.reserveCapacity(16384)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard result.count + pending.count < limit else { throw URLError(.dataLengthExceedsMaximum) }
            pending.append(byte)
            if pending.count >= 16384 {
                result.append(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
        result.append(contentsOf: pending)
        return (result, http)
    }
}
