// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClawShell",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ClawShell",
            targets: ["ClawShell"]
        ),
        .library(
            name: "ClawShellCore",
            targets: ["ClawShellCore"]
        ),
        .executable(
            name: "ClawShellCoreChecks",
            targets: ["ClawShellCoreChecks"]
        )
    ],
    targets: [
        .target(
            name: "ClawShellCore"
        ),
        .executableTarget(
            name: "ClawShell",
            dependencies: ["ClawShellCore"]
        ),
        .executableTarget(
            name: "ClawShellCoreChecks",
            dependencies: ["ClawShellCore"],
            path: "Checks/ClawShellCoreChecks"
        ),
        .testTarget(
            name: "ClawShellCoreTests",
            dependencies: ["ClawShellCore"]
        )
    ]
)
