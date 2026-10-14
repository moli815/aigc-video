// swift-tools-version: 5.9
import PackageDescription

// 注意：ResearchCore(EvidenceRanking) 与 WebSearchService 相互调用，
// 必须在同一 target 内，否则循环依赖无法通过 SPM 编译。
// 因此 ExpertCore 与两个纯 Foundation 服务文件合并为单一 target。
let package = Package(
    name: "BossAIExpertCore",
    platforms: [.macOS(.v12), .iOS(.v17)],
    products: [.library(name: "BossAIExpertCore", targets: ["BossAIExpertCore"])],
    dependencies: [
        // WebEvidenceExtractor 的 HTML/DOM 解析依赖（纯 Swift，跨平台）；与 project.yml 锁同版本
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exactVersion: "2.13.9")
    ],
    targets: [
        .target(
            name: "BossAIExpertCore",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")],
            path: "BossAI",
            sources: [
                "ExpertCore/BusinessCalculators.swift",
                "ExpertCore/ExpertCapabilities.swift",
                "ExpertCore/ReliabilityCore.swift",
                "ExpertCore/ResearchCore.swift",
                "ExpertCore/SpreadsheetXMLCore.swift",
                "Services/WebSearchService.swift",
                "Services/BoundedHTTPClient.swift",
                "Services/WebEvidenceExtractor.swift",
            ],
            resources: [.process("ExpertCore/Resources")]
        ),
        .testTarget(name: "BossAIExpertCoreTests", dependencies: ["BossAIExpertCore"], path: "Tests/BossAIExpertCoreTests"),
        .testTarget(name: "BossAISearchCoreTests", dependencies: ["BossAIExpertCore"], path: "Tests/BossAISearchCoreTests")
    ]
)
