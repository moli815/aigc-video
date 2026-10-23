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
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.record(kind: "exception",
                                 signal: nil,
                                 stack: (exception.callStackSymbols ?? []).joined(separator: "\n")
                                    + "\n[reason] " + (exception.reason ?? "?"))
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, { s in
                CrashReporter.record(kind: "signal", signal: String(s),
                                     stack: Thread.callStackSymbols.joined(separator: "\n"))
                // 恢复默认处理并重新抛出，保证系统记录与后续符号化
                signal(s, SIG_DFL)
                raise(s)
            })
        }
    }

    /// 把崩溃现场序列化成 JSON 写入待发目录，并清理超量的旧文件。
    /// 整个过程全部容错（try?）：崩溃路径上绝不允许二次崩溃
    private static func record(kind: String, signal: String?, stack: String) {
        let info = UIDevice.current
        let payload: [String: Any] = [
            "appVersion": AppConfig.appVersion,
            "osVersion": "\(info.systemName) \(info.systemVersion)",
            "device": info.model,
            "kind": kind,
            "signal": signal ?? "",
            // 堆栈截断到 5800 字符：极端递归崩溃的堆栈可能极长
            "stack": String(stack.prefix(5800)),
            "memberName": HostedAccount.cachedDisplayName,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
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
            // 短超时：上报不能拖慢启动；失败保留文件下次再试
            req.timeoutInterval = 8
            URLSession.shared.dataTask(with: req) { _, response, _ in
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: file)
                }
            }.resume()
        }
    }

    /// 崩溃文件目录：Application Support/crashes（不可用时回退临时目录）
    private static func crashDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("crashes", isDirectory: true)
    }
}
