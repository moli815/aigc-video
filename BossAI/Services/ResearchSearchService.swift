import Foundation

/// Replaceable search contract; providers and test fixtures share it, independently of the LLM.
protocol ResearchSearching: Sendable {
    func search(query: String, count: Int, recency: SearchRecency) async -> [SearchHit]
    func page(url: String, limit: Int) async -> String
}
struct DefaultResearchSearch: ResearchSearching {
    func search(query: String, count: Int, recency: SearchRecency) async -> [SearchHit] {
        await WebSearchService.search(query: query, count: count, recency: recency)
    }
    func page(url: String, limit: Int) async -> String { await WebSearchService.fetchPageText(url: url, limit: limit) }
}
