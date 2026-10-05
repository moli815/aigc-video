import Foundation
import os

/// No prompts, keys, file names or user data are written to performance traces.
enum PerformanceTrace {
    static let log = OSLog(subsystem: "com.bossai.performance", category: .pointsOfInterest)
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }
    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
    static func event(_ name: StaticString, _ id: OSSignpostID = .exclusive) {
        os_signpost(.event, log: log, name: name, signpostID: id)
    }
}
