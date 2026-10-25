import Foundation
import os

// ============================================================================
// 文件职责：性能打点（os_signpost 薄封装）。
// 在 App 中的角色：给 Instruments 的 Points of Interest 轨道提供 begin/end/event
//   三个打点原语，用于测量启动、首条回复、渲染等关键路径耗时。
// 关键设计决策：**只打 StaticString 名称与 ID，绝不写入 prompt、key、文件名或
//   任何用户数据**——日志可能被系统采集/导出，这是隐私红线。
// ============================================================================

/// No prompts, keys, file names or user data are written to performance traces.
enum PerformanceTrace {
    /// 固定 subsystem/category：Instruments 里按此过滤 Points of Interest 轨道
    static let log = OSLog(subsystem: "com.bossai.performance", category: .pointsOfInterest)

    private static let lock = NSLock()
    private static var startTimes: [String: Date] = [:]

    /// 标记一段区间的开始。返回配对的 signpostID，必须传给 end() 成对使用。
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        lock.lock(); startTimes["\(name)"] = Date(); lock.unlock()
        return id
    }
    /// 标记区间结束（与 begin 用同一 id 配对，Instruments 据此计算区间耗时）。
    /// P0-68 附加：慢链路（>8 秒）自动上报云端——管理台可见"哪里在变慢"，不再只靠用户反馈。
    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
        let key = "\(name)"
        lock.lock(); let t = startTimes.removeValue(forKey: key); lock.unlock()
        guard let t else { return }
        let ms = Date().timeIntervalSince(t) * 1000
        if ms > 8000 { reportSlow(name: key, ms: ms) }
    }
    /// 标记单个瞬时事件（无区间，如"命中缓存"）；默认 exclusive id 表示独立事件
    static func event(_ name: StaticString, _ id: OSSignpostID = .exclusive) {
        os_signpost(.event, log: log, name: name, signpostID: id)
    }

    private static let metaLogger = Logger(subsystem: "com.bossai.performance", category: "image")

    /// 动态字段事件（10-25）：用于记录**结构化元数据**（模型名、耗时、数量、状态码）。
    /// 红线：只允许这些技术字段，禁止写入 prompt 正文、Token、Authorization、图片内容。
    static func event(_ name: StaticString, fields: [String: String]) {
        let text = fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        metaLogger.info("\(name, privacy: .public) \(text, privacy: .public)")
    }

    /// P0-68 慢链路上报（fire-and-forget）：只上报"链路名称 + 耗时"，无任何用户数据/内容。
    static func reportSlow(name: String, ms: Double) {
        Task { @MainActor in
            guard HostedAccount.isHostedActive, let token = HostedAccount.shared.token,
                  let url = URL(string: AppConfig.hostedAPIBase + "/tool-event") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "tool": "perf:\\(name)", "reason": "slow \\(Int(ms))ms",
            ])
            // 10-23 P3：性能事件上报走受限网络客户端，响应体限制 128KB
            _ = try? await BoundedHTTPClient.data(for: req,
                                                  session: BoundedHTTPClient.searchSession,
                                                  limit: 128 * 1024)
        }
    }
}
