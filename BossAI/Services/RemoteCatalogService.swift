import Foundation

// ============================================================================
// 文件职责：P0-26 SaaS 化——云端专家目录拉取与注入。
// 在 App 中的角色：启动/登录后从服务端 /experts 拉取专家目录（人设/工具/开场白/侧栏文案），
//   成功后覆盖内置目录；失败时依次回退「本地缓存文件 → 内置目录」，永不空列表。
// 关键设计决策：
//   1. 目录缓存落 Documents（无网/接口异常也能用上次成功版本）；
//   2. 未知工具字符串忽略、deliverable 未知回退 word、字段缺失回退内置同 id 专家的兜底值——
//      服务端配置错误最多导致个别专家降级，绝不让 App 崩溃或白屏；
//   3. 全流程打点 PerformanceTrace 便于线上排查。
// ============================================================================

enum RemoteCatalogService {

    private static let cacheFile = "remote_catalog.json"

    struct UISectionDTO: Decodable {
        var expertsSectionTitle: String?
        var expertsSectionIcon: String?
    }

    struct ExpertDTO: Decodable {
        var id: String
        var name: String
        var subtitle: String?
        var symbol: String?
        var role: String?
        var framework: String?
        var steps: [String]?
        var deliverable: String?
        var tools: [String]?
        var checklist: [String]?
        var freshnessCue: String?
        var emoji: String?
    }

    struct StarterDTO: Decodable {
        var label: String
        var content: String
    }

    struct Payload: Decodable {
        var version: Int?
        var experts: [ExpertDTO]
        var starters: [String: [StarterDTO]]?
        var ui: UISectionDTO?
    }

    /// 启动/登录后调用（MainActor）：云端 → 缓存 → 内置（内置由 ExpertCatalog 自身兜底，无需在此处理）
    @MainActor
    static func refreshIfPossible() async {
        // 1) 先用本地缓存（秒开 + 离线可用），再尝试网络刷新
        if let cached = Self.loadCache(), apply(payload: cached) {
            PerformanceTrace.event("remote_catalog.cache_applied")
        }
        guard let token = HostedAccount.shared.token else { return }
        guard let url = URL(string: AppConfig.hostedAPIBase + "/experts") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // 10-23 P3：专家目录走受限网络客户端，响应体限制 8MB（目录 JSON 通常 <100KB，留足余量）
        do {
            let (data, resp) = try await BoundedHTTPClient.data(for: req,
                                                                session: BoundedHTTPClient.searchSession,
                                                                limit: 8 * 1024 * 1024)
            guard resp.statusCode == 200,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  !payload.experts.isEmpty else {
                PerformanceTrace.event("remote_catalog.fetch_skip")
                return
            }
            if apply(payload: payload) {
                saveCache(data)
                PerformanceTrace.event("remote_catalog.applied")
            }
        } catch {
            // 网络失败：保留缓存/内置目录，静默即可
            PerformanceTrace.event("remote_catalog.fetch_failed")
        }
    }

    // MARK: - DTO → Expert 映射（防呆：未知工具忽略、未知交付物回退 word、缺字段用内置同 id 专家兜底）

    private static func apply(payload: Payload) -> Bool {
        let mapped = mapExperts(payload.experts, bundled: ExpertCatalog.bundledAll)
        guard !mapped.isEmpty else { return false }

        var starters: [String: [ExpertCatalog.Starter]]? = nil
        if let sd = payload.starters {
            var out: [String: [ExpertCatalog.Starter]] = [:]
            for (key, arr) in sd {
                out[key] = arr.map { ExpertCatalog.Starter(label: $0.label, content: $0.content) }
            }
            starters = out
        }
        let ui = payload.ui.flatMap { u -> ExpertCatalog.UISection? in
            let title = (u.expertsSectionTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let icon = (u.expertsSectionIcon ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return ExpertCatalog.UISection(title: title, icon: icon.isEmpty ? "crown.fill" : icon)
        }
        ExpertCatalog.applyRemote(experts: mapped, starters: starters, ui: ui)
        return true
    }

    /// P0-43 DTO → Expert 映射（纯函数，供 XCTest 直接验证）。
    /// 防呆规则：id/name 为空 → 丢弃该条；工具字符串未知 → 忽略；交付物未知 → 回退 word；
    /// 任何缺省字段都从**内置同 id 专家**兜底——服务端配置出问题最多让个别专家降级，绝不让 App 崩溃。
    static func mapExperts(_ dtos: [ExpertDTO], bundled: [Expert]) -> [Expert] {
        let fallback = Dictionary(uniqueKeysWithValues: bundled.map { ($0.id, $0) })
        var mapped: [Expert] = []
        for dto in dtos {
            let base = fallback[dto.id]
            let id = dto.id
            guard !id.isEmpty, !dto.name.isEmpty else { continue }
            // 10-23 P3：区分"服务端明确传了空工具列表"与"字段缺失"。
            // 显式空数组必须保留为空（关闭所有工具），只有字段缺失时才回退默认工具。
            let providedTools = dto.tools
            let parsedTools = (providedTools ?? []).compactMap(ExpertTool.init(rawValue:))
            let resolvedTools: [ExpertTool]
            if let providedTools {
                resolvedTools = parsedTools
            } else {
                resolvedTools = base?.skill.tools ?? [.search]
            }
            let deliverable = DocumentFormat(rawValue: dto.deliverable ?? "") ?? base?.skill.deliverable ?? .word
            let skill = ExpertSkill(
                framework: dto.framework ?? base?.skill.framework ?? "结构化分析",
                steps: (dto.steps?.isEmpty == false ? dto.steps! : base?.skill.steps) ?? [],
                deliverable: deliverable,
                tools: resolvedTools,
                checklist: dto.checklist ?? base?.skill.checklist ?? [],
                freshnessCue: dto.freshnessCue ?? base?.skill.freshnessCue ?? ""
            )
            mapped.append(Expert(
                id: id,
                name: dto.name,
                subtitle: dto.subtitle ?? base?.subtitle ?? "",
                symbol: dto.symbol ?? base?.symbol ?? "bubble.left.and.bubble.right.fill",
                role: dto.role ?? base?.role ?? "",
                skill: skill,
                emoji: dto.emoji ?? base?.emoji
            ))
        }
        return mapped
    }

    // MARK: - 缓存（Documents/remote_catalog.json）

    private static func cacheURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(cacheFile)
    }

    private static func loadCache() -> Payload? {
        guard let data = try? Data(contentsOf: cacheURL()) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func saveCache(_ data: Data) {
        try? data.write(to: cacheURL(), options: .atomic)
    }
}
