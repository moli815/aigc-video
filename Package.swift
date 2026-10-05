// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BossAIExpertCore",
    platforms: [.macOS(.v12), .iOS(.v17)],
    products: [.library(name: "BossAIExpertCore", targets: ["BossAIExpertCore"])],
    targets: [
        .target(name: "BossAIExpertCore", path: "BossAI/ExpertCore", resources: [.process("Resources")]),
        .testTarget(name: "BossAIExpertCoreTests", dependencies: ["BossAIExpertCore"], path: "Tests/BossAIExpertCoreTests")
    ]
)
