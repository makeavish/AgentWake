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
        ),
        .executable(
            name: "ClawShellPowerValidation",
            targets: ["ClawShellPowerValidation"]
        ),
        .executable(
            name: "ClawShellCLI",
            targets: ["ClawShellCLI"]
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
        .executableTarget(
            name: "ClawShellPowerValidation",
            dependencies: ["ClawShellCore"],
            path: "Checks/ClawShellPowerValidation"
        ),
        .executableTarget(
            name: "ClawShellCLI",
            dependencies: ["ClawShellCore"]
        ),
        .testTarget(
            name: "ClawShellCoreTests",
            dependencies: ["ClawShellCore"]
        ),
        .testTarget(
            name: "ClawShellContractTests",
            dependencies: ["ClawShellCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
