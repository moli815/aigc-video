import Foundation

// ============================================================================
// 文件职责：深度研究的搜索抽象层。
// 在 App 中的角色：ResearchCore 只依赖 ResearchSearching 协议，不关心底层用哪家
//   搜索实现；生产环境走 DefaultResearchSearch（内部调 WebSearchService），
//   测试用 fixture 实现同一协议注入，保证研究管线与搜索引擎、聊天模型完全解耦。
// ============================================================================

/// Replaceable search contract; providers and test fixtures share it, independently of the LLM.
protocol ResearchSearching: Sendable {
    /// 搜索：query=检索词；count=期望条数；recency=时间范围过滤。
    /// 返回命中列表（可能为空，表示无结果或网络失败——调用方按空结果处理）。
    func search(query: String, count: Int, recency: SearchRecency) async -> [SearchHit]
    /// 抓取网页正文：url=目标页；limit=正文最大字符数（截断控制上下文预算）。
    /// 失败返回空串。
    func page(url: String, limit: Int) async -> String
}

/// 默认实现：全部转发到全局 WebSearchService（真实网络搜索 + 正文抓取）
struct DefaultResearchSearch: ResearchSearching {
    func search(query: String, count: Int, recency: SearchRecency) async -> [SearchHit] {
        await WebSearchService.search(query: query, count: count, recency: recency)
    }
    func page(url: String, limit: Int) async -> String { await WebSearchService.fetchPageText(url: url, limit: limit) }
}
