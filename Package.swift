// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Conductor",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ConductorCore", targets: ["ConductorCore"]),
        .executable(name: "ConductorApp", targets: ["ConductorApp"]),
        .executable(name: "ConductorUpdater", targets: ["ConductorUpdater"]),
        .executable(name: "conductorctl", targets: ["ConductorCLI"]),
    ],
    dependencies: [
        // YAML 解析（用户配置 config.yaml）。Swift 事实标准，支持 Codable。仅 App 层用。
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // 浏览器 cookie 抽取（Chrome/Safari/Firefox），源码自 steipete/SweetCookieKit 整目录拿入（非依赖）。
        // 供 cookie 类用量 provider（cursor/grok/copilot…）读登录态。仅链 sqlite3 系统库。
        .target(
            name: "SweetCookieKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "ConductorCore",
            dependencies: ["SweetCookieKit"],
            resources: [
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ]
        ),
        .testTarget(name: "ConductorCoreTests", dependencies: ["ConductorCore"]),
        .testTarget(name: "ConductorAppTests", dependencies: ["ConductorApp", "GhosttyKit"]),
        .executableTarget(
            name: "ConductorCLI",
            dependencies: [
                "ConductorCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "ConductorUpdater",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),

        // 预编译的 libghostty（来自 manaflow-ai/ghostty release，与 Conductor 同款）。
        .binaryTarget(
            name: "GhosttyKit",
            path: "Vendor/GhosttyKit.xcframework"
        ),
        // conductor 主应用：工作区 / Tab / 自由分屏 + 真 libghostty 终端。
        .executableTarget(
            name: "ConductorApp",
            dependencies: ["ConductorCore", "GhosttyKit", .product(name: "Yams", package: "Yams")],
            resources: [
                .copy("Resources/Logos"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
