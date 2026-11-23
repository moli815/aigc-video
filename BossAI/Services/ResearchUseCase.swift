import Foundation

/// Search evidence acquisition, independent of chat UI and persistence.
enum ResearchUseCase {
    nonisolated static func currentYearMonth() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: Date())
    }

    nonisolated static func searchQuery(_ call: ChatService.ToolCall, fallback: String) -> (String, SearchRecency) {        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        let query = (args?["query"] as? String) ?? fallback
        return (query, (args?["recency"] as? String).flatMap(SearchRecency.init(rawValue:)) ?? SearchRecency.inferred(from: query))
    }
    nonisolated static func runWebSearch(call: ChatService.ToolCall, order: Int, fallback: String, provider: any ResearchSearching) async -> SearchOutcome {
        let span = PerformanceTrace.begin("WebSearch")
        defer { PerformanceTrace.end("WebSearch", span) }
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
        let rawQuery = (args?["query"] as? String) ?? fallback
        // P0-50 搜索时效性增强：行情/价格/新闻类查询且未含年份时，自动附加当前年月——
        // 实测搜索引擎对无时间词的查询倾向返回旧页面快照（用户实机曾搜到一年前的金价数据）。
        let timewords = ["行情", "价格", "多少钱", "最新", "今天", "今日", "新闻", "汇率", "金价", "股价", "报价", "走势", "天气"]
        let hasYear = rawQuery.range(of: #"20\d{2}"#, options: .regularExpression) != nil
        let needsFresh = timewords.contains { rawQuery.contains($0) }
        let query = (needsFresh && !hasYear) ? rawQuery + " " + Self.currentYearMonth() : rawQuery
        let recency = (args?["recency"] as? String).flatMap(SearchRecency.init(rawValue:)) ?? SearchRecency.inferred(from: query)
        let hits = await provider.search(query: query, count: 6, recency: recency)

        if hits.isEmpty {
            return SearchOutcome(
                order: order,
                callId: call.id,
                hits: [], pages: [], emptyMessage: """
                搜索「\(query)」无结果或网络不可用。
                请在最终答案里把对应字段明确标注为「未核实」，\
                不要用记忆中的数字、其他型号的数字或拼凑的数字填空 —— 留空不算错，填错才算错。
                """
            )
        }

        // 并行抓取正文，多给 3 个候选。
        // 部分站点会反爬返回空，只抓前 N 个会因为个别失败而白白少拿一份资料 —— 这里凑够为止。
        let fetchCount = min(AppConfig.searchPageFetchCount, hits.count)
        guard fetchCount > 0 else {
            return SearchOutcome(order: order, callId: call.id,
                                 hits: hits, pages: [], emptyMessage: nil)
        }
        let candidates = Array(hits.prefix(fetchCount + 3))
        var pages: [(title: String, url: String, text: String)] = []
        // Priority batches retain slow authoritative pages; nonempty text alone is insufficient.
        for start in stride(from: 0, to: candidates.count, by: 3) {
            if Task.isCancelled || pages.count >= fetchCount { break }
            let batch = Array(candidates[start..<min(start + 3, candidates.count)])
            let raw = await withTaskGroup(of: (Int, String, String, String).self) { group in
                for (i, hit) in batch.enumerated() {
                    group.addTask { (i, hit.title, hit.url, await provider.page(url: hit.url, limit: 3500)) }
                }
                var collected: [(Int, String, String, String)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }
            }
            for item in raw where item.3.count > 80 && ResearchIntent.relevance(query: query, text: item.3) > 0 {
                if pages.count < fetchCount { pages.append((item.1, item.2, item.3)) }
            }
        }

        return SearchOutcome(order: order,
                             callId: call.id,
                             hits: hits, pages: pages, emptyMessage: nil)
    }

    // MARK: - 上下文组装：专家 prompt + 身份 + 记忆 + 附件正文

    /// 组装发送给模型的完整消息数组：
    /// 两条 system（稳定块+易变块，P0-2 缓存稳定化）→ 最近 40 条消息（含附件
    /// 注入与多模态图片）→ 尾部按 48K 字符预算裁剪。稳定块永不变化保证前缀缓存命中。
    /// 统一的关键保存入口：失败不静默，写入 persistenceWarning 供 UI 展示。
    /// 说明：这里不抛错（调用点多为收尾路径，抛错会打断流式收尾）；但失败一定可观测。
}
