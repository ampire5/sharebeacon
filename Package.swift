// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ShareBeaconCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ShareBeaconCore", targets: ["ShareBeaconCore"])
    ],
    targets: [
        .target(
            name: "ShareBeaconCore",
            path: "ShareBeacon",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "AppMetadata.swift",
                "Preview Content",
                "SettingsView.swift",
                "LogsView.swift",
                "MenuPanelView.swift",
                "sharebeacon.entitlements",
                "ShareBeaconApp.swift"
            ],
            sources: [
                "MountCore.swift", "NetworkLink.swift", "ShareStatus.swift", "ReconnectPolicy.swift",
                "SMBShareManager.swift", "FinderSidebarRepairer.swift", "Logger.swift"
            ]
        ),
        .testTarget(
            name: "ShareBeaconCoreTests",
            dependencies: ["ShareBeaconCore"],
            path: "Tests/ShareBeaconCoreTests"
        )
    ]
)
