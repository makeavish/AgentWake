// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentWake",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "AgentWake",
            targets: ["AgentWake"]
        ),
        .library(
            name: "AgentWakeCore",
            targets: ["AgentWakeCore"]
        ),
        .executable(
            name: "AgentWakeCoreChecks",
            targets: ["AgentWakeCoreChecks"]
        ),
        .executable(
            name: "AgentWakePowerValidation",
            targets: ["AgentWakePowerValidation"]
        ),
        .executable(
            name: "AgentWakeSafetyPolicyProof",
            targets: ["AgentWakeSafetyPolicyProof"]
        ),
        .executable(
            name: "AgentWakeCLI",
            targets: ["AgentWakeCLI"]
        ),
        .executable(
            name: "AgentWakeHookAdapter",
            targets: ["AgentWakeHookAdapter"]
        ),
        .executable(
            name: "AgentWakeHelper",
            targets: ["AgentWakeHelper"]
        )
    ],
    targets: [
        .target(
            name: "AgentWakeCore",
            dependencies: ["AgentWakeTemperatureIOReport"]
        ),
        .target(
            name: "AgentWakeTemperatureIOReport",
            cSettings: [
                .unsafeFlags(["-fblocks"])
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "AgentWake",
            dependencies: ["AgentWakeCore"]
        ),
        .executableTarget(
            name: "AgentWakeCoreChecks",
            dependencies: ["AgentWakeCore"],
            path: "Checks/AgentWakeCoreChecks"
        ),
        .executableTarget(
            name: "AgentWakePowerValidation",
            dependencies: ["AgentWakeCore"],
            path: "Checks/AgentWakePowerValidation"
        ),
        .executableTarget(
            name: "AgentWakeSafetyPolicyProof",
            dependencies: ["AgentWakeCore"],
            path: "Checks/AgentWakeSafetyPolicyProof"
        ),
        .executableTarget(
            name: "AgentWakeCLI",
            dependencies: ["AgentWakeCore"]
        ),
        .executableTarget(
            name: "AgentWakeHookAdapter",
            dependencies: ["AgentWakeCore"]
        ),
        .executableTarget(
            name: "AgentWakeHelper",
            dependencies: ["AgentWakeCore"]
        ),
        .testTarget(
            name: "AgentWakeCoreTests",
            dependencies: ["AgentWakeCore"]
        ),
        .testTarget(
            name: "AgentWakeContractTests",
            dependencies: ["AgentWakeCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
