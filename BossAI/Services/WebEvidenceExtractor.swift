import Foundation
import SwiftSoup

// ============================================================================
// 文件职责：搜索结果页与文章页的 HTML 解析（DOM 适配层）。
// 在 App 中的角色：研究管线的"取证据"环节——从各家搜索引擎结果页抽标题/链接/
//   摘要（links），从文章页抽正文 HTML（contentHTML），供后续引用与作证。
// 关键设计决策：
//   1. 解析器与搜索供应商、聊天模型解耦：换搜索引擎只需适配这里的 CSS 选择器；
//   2. 结构化选择器失败时走显式兜底（snippet 置空而不是把相邻文本冒充摘要）；
//   3. 任何解析异常返回空结果/原文，绝不抛出打断研究流程。
// ============================================================================

/// DOM adapter: the search pipeline is independent of this parser and of the chat model.
enum WebEvidenceExtractor {
    /// 一条搜索结果：标题 + 目标链接 + 页面摘要（snippet 可能为空）
    struct LinkRecord { let title: String; let href: String; let snippet: String }

    /// 从搜索引擎结果页 HTML 抽取结果条目。
    /// 先按各家结果容器的选择器（百度/360/必应等）结构化提取；找不到容器时
    /// 退化为全页抽 h3/h2/普通链接。返回最多数百条，解析失败返回空数组。
    static func links(html: String) -> [LinkRecord] {
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script, style, noscript, nav, footer").remove()
            let containers = try document.select("div.result, div.c-container, li.b_algo, div.vrwrap, li.res-list, div.res-list, div.resultitem").array()
            var result: [LinkRecord] = []
            // 结构化路径：每个结果容器限 4 条链接、全页限 100 容器，防异常页面爆炸
            if !containers.isEmpty {
                for container in containers.prefix(100) {
                    let links = try container.select("h3 a[href], h2 a[href]").array()
                    let candidates = links.isEmpty ? try container.select("a[href]").array() : links
                    for link in candidates.prefix(4) {
                        result.append(LinkRecord(title: try link.text(), href: try destination(link), snippet: String(try container.text().prefix(800))))
                    }
                }
            } else {
                // Explicit fallback without pretending neighboring text is an article summary.
                for link in try document.select("h3 a[href], h2 a[href], a[href]").array().prefix(200) {
                    result.append(LinkRecord(title: try link.text(), href: try destination(link), snippet: ""))
                }
            }
            return result
        } catch { return [] }
    }
    /// 提取链接真实目标地址：360 把原始 URL 放在 data-mdurl 属性（跳转链是追踪壳），
    /// 先取 data-mdurl 并校验 http(s) 合法性，否则退回 href。
    private static func destination(_ link: Element) throws -> String {
        // 360 publishes the original URL separately from its tracking redirect.
        let original = try link.attr("data-mdurl")
        if let url = URL(string: original), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { return original }
        return try link.attr("href")
    }
    /// 从文章页 HTML 抽正文 HTML：去掉脚本/导航/页眉页脚等噪声标签；
    /// 优先取 article/main/[role=main] 主容器（正文 >200 字才采信，防把导航当正文），
    /// 否则返回 body HTML，最终兜底返回原文。失败时返回原文。
    static func contentHTML(_ html: String) -> String {
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script, style, noscript, nav, header, footer, aside").remove()
            if let main = try document.select("article, main, [role=main]").first(), try main.text().count > 200 { return try main.html() }
            return try document.body()?.html() ?? html
        } catch { return html }
    }
}
