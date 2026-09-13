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
            dependencies: ["AppCore", "AIDomain", "AIInterfaces", "AIServices"]
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
        .testTarget(
            name: "AILanguageCoachTests",
            dependencies: [
                "AppCore", "AIDomain", "AIInterfaces",
                "AIInfrastructure", "AIProviders", "AIServices", "AppUI",
            ]
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
