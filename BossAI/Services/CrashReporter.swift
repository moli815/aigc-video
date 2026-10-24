import Foundation
import UIKit

//
//  CrashReporter.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：崩溃捕获与上报。运行期挂接 OC 异常处理器与常见 POSIX 信号处理器，
//  把崩溃现场（版本/系统/设备/堆栈）写成 JSON 待发文件；下次启动时批量上报。
//
//  在整个 App 中的角色：自建轻量质量监控，无第三方 SDK 依赖。启动早期 install()、
//  启动后 uploadPendingIfNeeded() 两步配合完成"崩溃→落盘→上报"闭环。
//
//  关键设计决策：
//  - 崩溃时不联网上报（进程即将终止，网络调用不可靠），只做最轻的本地写盘。
//  - 上报"成功即删、失败保留"，最多保留 3 份防止沙盒被塞满。
//  - 信号处理后恢复 SIG_DFL 并 re-raise，让系统照常记录并终止进程。
//
//  防呆/安全冗余理由：
//  - 崩溃路径里所有操作都 try? 吞错：崩溃现场绝不能因自身报错而二次崩溃。
//  - 堆栈截断到 5800 字符，防超大堆栈撑爆文件。
//  - 上传用 8 秒短超时，网络差时不长时间占用启动流程。
//
/// P0 崩溃上报（自建轻量方案，不引第三方 SDK）：
/// - 运行期挂 NSSetUncaughtExceptionHandler 与常用 signal 处理器，把现场写入沙盒待发文件；
/// - 崩溃文件不在这里上传（进程即将终止，网络不可靠），而是**下次启动**时由 uploadPendingIfNeeded() 上报；
/// - 上报失败静默保留文件，最多保留 3 个，防止无限增长。
enum CrashReporter {
    /// 待发崩溃文件的通用前缀（文件名形如 crash-<时间戳>.json）
    private static let fileName = "crash-pending.json"
    /// 最多保留的待发崩溃文件数，超出丢弃最旧
    private static let maxPending = 3

    /// 安装崩溃处理器：OC 异常走 record(kind:"exception")，
    /// 五种致命信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE）走 record(kind:"signal")。
    /// 在 App 启动最早时机调用（BossAIApp.init）
    static func install() {
        // NSException 不在 signal context 里，可以安全使用 Foundation
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.record(kind: "exception",
                                 signal: nil,
                                 stack: (exception.callStackSymbols ?? []).joined(separator: "\n")
                                    + "\n[reason] " + (exception.reason ?? "?"))
        }
        // 10-24 P1：POSIX signal handler 里禁止调用 Foundation/UIKit/JSON/FileManager
        // （非 async-signal-safe，会在崩溃现场二次崩溃或死锁）。
        // 这里预打开标记文件描述符，handler 内只做 write(2)；完整信息下次启动再组装。
        let dir = crashDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let markerPath = dir.appendingPathComponent(signalMarkerName).path
        markerFD = open(markerPath, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, { s in
                CrashReporter.writeSignalMarker(s)
                // 恢复默认处理并重新抛出，保证系统记录与后续符号化
                signal(s, SIG_DFL)
                raise(s)
            })
        }
    }

    /// 预打开的标记文件描述符（install 阶段创建，signal handler 直接用）
    private static var markerFD: Int32 = -1
    private static let signalMarkerName = "signal-marker.bin"

    /// async-signal-safe：只调用 write(2)。8 字节 = 1 字节信号 + 4 字节秒级时间戳 + 3 字节保留。
    private static func writeSignalMarker(_ sig: Int32) {
        guard markerFD >= 0 else { return }
        var payload = [UInt8](repeating: 0, count: 8)
        payload[0] = UInt8(truncatingIfNeeded: sig)
        let t = UInt32(truncatingIfNeeded: time(nil))
        payload[1] = UInt8(truncatingIfNeeded: t)
        payload[2] = UInt8(truncatingIfNeeded: t >> 8)
        payload[3] = UInt8(truncatingIfNeeded: t >> 16)
        payload[4] = UInt8(truncatingIfNeeded: t >> 24)
        _ = payload.withUnsafeBufferPointer { buf in
            write(markerFD, buf.baseAddress, 8)
        }
    }

    /// 启动时把上次的信号标记转成 crash 记录（此时已脱离 signal context，可安全用 Foundation）。
    /// 注意：不能关闭 markerFD —— 那会让后续崩溃无法再写标记；用独立读句柄 + truncate 清空。
    private static func drainSignalMarkers() {
        let path = crashDir().appendingPathComponent(signalMarkerName)
        let readFD = open(path, O_RDONLY)
        guard readFD >= 0 else { return }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 512)
        while data.count < 65536 {
            let n = read(readFD, &buf, 512)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        close(readFD)
        // 清空但保留 inode：handler 的 O_APPEND 句柄继续有效
        if markerFD >= 0 { _ = ftruncate(markerFD, 0) }
        guard data.count >= 8 else { return }
        var offset = 0
        while offset + 8 <= data.count {
            let sig = Int32(data[offset])
            let ts = UInt32(data[offset + 1])
                | (UInt32(data[offset + 2]) << 8)
                | (UInt32(data[offset + 3]) << 16)
                | (UInt32(data[offset + 4]) << 24)
            let when = ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : Date()
            record(kind: "signal",
                   signal: String(sig),
                   stack: "[signal handler] 收到致命信号 \(sig)。signal context 内无法安全采集堆栈，"
                        + "完整调用栈请用 Xcode Devices / MetricKit 导出。",
                   at: when)
            offset += 8
        }
        // 已用 ftruncate 清空，无需删除文件（删掉会让 handler 的 fd 指向已删除 inode）
    }

    /// 把崩溃现场序列化成 JSON 写入待发目录，并清理超量的旧文件。
    /// 整个过程全部容错（try?）：崩溃路径上绝不允许二次崩溃
    private static func record(kind: String, signal: String?, stack: String, at date: Date = Date()) {
        let info = UIDevice.current
        let payload: [String: Any] = [
            "appVersion": AppConfig.displayVersion,
            "osVersion": "\(info.systemName) \(info.systemVersion)",
            "device": info.model,
            "kind": kind,
            "signal": signal ?? "",
            // 堆栈截断到 5800 字符：极端递归崩溃的堆栈可能极长
            "stack": String(stack.prefix(5800)),
            "memberName": HostedAccount.cachedDisplayName,
            "ts": Int(date.timeIntervalSince1970 * 1000),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let dir = crashDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        try? data.write(to: dir.appendingPathComponent("crash-\(stamp).json"))
        // 超出上限则丢弃最旧的
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("crash-") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
           files.count > maxPending {
            for f in files.prefix(files.count - maxPending) { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// 下次启动时调用：把待发崩溃文件逐条上报，成功即删。
    /// 损坏（解析不过）的文件直接删除；HTTP 2xx 视为成功；失败静默保留待下次再试
    static func uploadPendingIfNeeded() {
        // 先把上次崩溃留下的信号标记转成正式记录（必须在扫描目录之前）
        drainSignalMarkers()
        let dir = crashDir()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "json" }),
              !files.isEmpty else { return }
        for file in files {
            // 先本地校验 JSON 合法性：写坏的文件上报也注定失败，直接清理
            guard let data = try? Data(contentsOf: file),
                  let _ = try? JSONSerialization.jsonObject(with: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let url = URL(string: AppConfig.hostedAPIBase + "/crash") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            // 10-23 P3：崩溃上报也走受限网络客户端，响应体限制 256KB；失败保留文件下次再试
            Task {
                guard let (body, resp) = try? await BoundedHTTPClient.data(for: req,
                                                                           session: BoundedHTTPClient.searchSession,
                                                                           limit: 256 * 1024),
                      (200...299).contains(resp.statusCode) else { return }
                // 10-24 P1：服务端已改为「落库成功才 2xx + ok:true」。客户端再校验一次，
                // 避免中间层缓存/旧服务端回 200 却没真正保存 —— 那会把唯一证据删掉。
                let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                guard (obj?["ok"] as? Bool) == true else { return }
                if let reportId = obj?["reportId"] as? String, !reportId.isEmpty {
                    PerformanceTrace.event("CrashReportAccepted")
                }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// 崩溃文件目录：Application Support/crashes（不可用时回退临时目录）
    private static func crashDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("crashes", isDirectory: true)
    }
}
