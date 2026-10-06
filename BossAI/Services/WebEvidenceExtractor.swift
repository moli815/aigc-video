import Foundation
import SwiftSoup

/// DOM adapter: the search pipeline is independent of this parser and of the chat model.
enum WebEvidenceExtractor {
    struct LinkRecord { let title: String; let href: String; let snippet: String }
    static func links(html: String) -> [LinkRecord] {
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script, style, noscript, nav, footer").remove()
            let containers = try document.select("div.result, div.c-container, li.b_algo, div.vrwrap, div.res-list, div.resultitem").array()
            var result: [LinkRecord] = []
            if !containers.isEmpty {
                for container in containers.prefix(100) {
                    let links = try container.select("h3 a[href], h2 a[href]").array()
                    let candidates = links.isEmpty ? try container.select("a[href]").array() : links
                    for link in candidates.prefix(4) {
                        result.append(LinkRecord(title: try link.text(), href: try link.attr("href"), snippet: String(try container.text().prefix(800))))
                    }
                }
            } else {
                // Explicit fallback without pretending neighboring text is an article summary.
                for link in try document.select("h3 a[href], h2 a[href], a[href]").array().prefix(200) {
                    result.append(LinkRecord(title: try link.text(), href: try link.attr("href"), snippet: ""))
                }
            }
            return result
        } catch { return [] }
    }
    static func contentHTML(_ html: String) -> String {
        do {
            let document = try SwiftSoup.parse(html)
            try document.select("script, style, noscript, nav, header, footer, aside").remove()
            if let main = try document.select("article, main, [role=main]").first(), try main.text().count > 200 { return try main.html() }
            return try document.body()?.html() ?? html
        } catch { return html }
    }
}
