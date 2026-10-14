//
//  BoundedHTTPClient.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：提供一个"带上限、可取消"的 HTTP 下载工具。所有网络响应体都必须
//  经过这里读取，保证任何服务器返回的数据都不会超出预设字节上限。
//
//  在整个 App 中的角色：搜索、聊天、作图等联网模块统一走这里的预置 Session，
//  防止恶意/异常服务器返回超大响应拖垮内存。
//
//  关键设计决策：
//  - 每类业务用独立的 ephemeral Session（不共享 Cookie/缓存），并按业务设置资源总超时：
//    搜索 10 秒（要求快），聊天/作图 180 秒（生成耗时长）。
//  - 请求级超时 min(resourceTimeout, 30)：单次请求卡住时 30 秒内先行失败，不等总超时。
//  - 用 bytes 流式读取而非 Data(contentsOf:)，边收边检查总量，超限立即抛错并断开。
//
//  防呆/安全冗余理由：
//  - 响应头 expectedContentLength 与逐字节计数双重校验，防"声明小、实际大"的恶意响应。
//  - 每收到一段数据就 Task.checkCancellation()，用户取消操作能立刻生效。
//
import Foundation

/// 带字节上限与超时约束的 HTTP 客户端工具集
enum BoundedHTTPClient {
    /// 构造一个按业务定制的 URLSession。
    /// - Parameter resourceTimeout: 整个资源下载允许的总时长（秒）
    /// - Returns: 配置好的 ephemeral Session（无缓存、无 Cookie 共享）
    static func session(resourceTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = resourceTimeout
        // 单请求超时取 min(总超时, 30)：长下载也能在请求级 30 秒无响应时提前止损
        configuration.timeoutIntervalForRequest = min(resourceTimeout, 30)
        return URLSession(configuration: configuration)
    }
    /// 搜索专用会话：短超时，快速失败
    static let searchSession = session(resourceTimeout: 10)
    /// 作图专用会话：图片生成慢，给足 180 秒
    static let imageSession = session(resourceTimeout: 180)
    /// 聊天/补全专用会话：同样给足 180 秒
    static let chatSession = session(resourceTimeout: 180)

    /// 流式下载响应体，严格限制最大字节数。
    /// - Parameters:
    ///   - request: 要发起的请求
    ///   - session: 使用的 URLSession
    ///   - limit: 响应体最大字节数（超出即抛错）
    /// - Returns: (响应数据, HTTP 响应)
    /// - Throws: 响应非 HTTP、响应体超过上限（dataLengthExceedsMaximum）或任务被取消
    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        // 第一道闸：信任但验证响应头声明的大小；非 HTTP 响应或声明超限直接失败
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        var result = Data(); result.reserveCapacity(min(limit, 65536))
        // 批量缓冲：逐字节 append 会在大页面上造成数十万次 Data 扩容拷贝，
        // 攒满 16KB 再一次性 memcpy 进结果，取消与上限语义保持不变。
        var pending = [UInt8](); pending.reserveCapacity(16384)
        for try await byte in bytes {
            // 每轮检查取消：保证用户取消后立刻停止拉流，不浪费流量与内存
            try Task.checkCancellation()
            // 第二道闸：逐字节累计校验，防响应头声明值与实际不符的恶意服务器
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
