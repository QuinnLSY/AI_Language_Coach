// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AILanguageCoach",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AILanguageCoach", targets: ["AppMain"])
    ],
    targets: [
        .target(name: "AppCore"),
        .target(name: "AIDomain", dependencies: ["AppCore"]),
        .target(name: "AIInterfaces", dependencies: ["AppCore", "AIDomain"]),
        .target(
            name: "AIInfrastructure",
            dependencies: ["AppCore", "AIDomain", "AIInterfaces"],
            resources: [.copy("Resources")]
        ),
        .target(
            name: "AIProviders",
            dependencies: ["AppCore", "AIDomain", "AIInterfaces", "AIInfrastructure"]
        ),
        .target(
            name: "AIServices",
            dependencies: ["AppCore", "AIDomain", "AIInterfaces", "AIInfrastructure", "AIProviders"]
        ),
        .target(
            name: "AppUI",
            dependencies: ["AppCore", "AIDomain", "AIInterfaces", "AIServices"],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "AppMain",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices", "AppUI",
            ]
        ),
        .executableTarget(
            name: "alc-bench",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices",
            ],
            path: "Sources/ALCBench"
        ),
        .executableTarget(
            name: "alc-release-check",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices",
            ],
            path: "Sources/ALCReleaseCheck"
        ),
        .testTarget(
            name: "AILanguageCoachTests",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices", "AppUI",
            ]
        ),
        // 离屏渲染用例单列一个 target（Tests/RenderTests）。
        //
        // 它们靠 `NSHostingView` + 位图差分断言「用户真能看见」，构造窗口、跑动画、
        // 逐像素比对，比纯函数用例慢一到两个数量级。日常改逻辑时只跑
        // `swift test --filter AILanguageCoachTests`（或 `--skip RenderTests`）就能拿到快速反馈，
        // CI 仍然两个 target 都跑。
        //
        // ⚠️ 两个 target 是**两个模块**：公共夹具不能跨 target 共享，
        // 各用例的辅助方法写在自己的文件里（`private`），别指望从另一个包里 import。
        .testTarget(
            name: "RenderTests",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices", "AppUI",
            ],
            path: "Tests/RenderTests"
        ),
        .testTarget(
            name: "BenchmarkTests",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices",
            ],
            path: "Tests/Benchmark"
        ),
    ],
    swiftLanguageModes: [.v6]
)
