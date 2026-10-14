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

    /// 标记一段区间的开始。返回配对的 signpostID，必须传给 end() 成对使用。
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }
    /// 标记区间结束（与 begin 用同一 id 配对，Instruments 据此计算区间耗时）
    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
    /// 标记单个瞬时事件（无区间，如"命中缓存"）；默认 exclusive id 表示独立事件
    static func event(_ name: StaticString, _ id: OSSignpostID = .exclusive) {
        os_signpost(.event, log: log, name: name, signpostID: id)
    }
}
