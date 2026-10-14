// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BossAIExpertCore",
    platforms: [.macOS(.v12), .iOS(.v17)],
    products: [
        .library(name: "BossAIExpertCore", targets: ["BossAIExpertCore"]),
        .library(name: "BossAISearchCore", targets: ["BossAISearchCore"])
    ],
    targets: [
        .target(name: "BossAIExpertCore", path: "BossAI/ExpertCore", resources: [.process("Resources")]),
        // 检索质量层：WebSearchService + BoundedHTTPClient（纯 Foundation，可在 macOS/Linux 上跑单测）
        .target(name: "BossAISearchCore", path: "BossAI", sources: ["Services/WebSearchService.swift", "Services/BoundedHTTPClient.swift"], dependencies: ["BossAIExpertCore"]),
        .testTarget(name: "BossAIExpertCoreTests", dependencies: ["BossAIExpertCore"], path: "Tests/BossAIExpertCoreTests"),
        .testTarget(name: "BossAISearchCoreTests", dependencies: ["BossAISearchCore", "BossAIExpertCore"], path: "Tests/BossAISearchCoreTests")
    ]
)
