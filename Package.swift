// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PEXEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PEXCore", targets: ["PEXCore"]),
        .library(name: "PEXAdapters", targets: ["PEXAdapters"]),
        .library(name: "PEXParsers", targets: ["PEXParsers"]),
        .library(name: "PEXPersistence", targets: ["PEXPersistence"]),
        .library(name: "PEXRuntime", targets: ["PEXRuntime"]),
        .library(name: "PEXEngine", targets: ["PEXEngine"]),
        .library(name: "PEXCLICore", targets: ["PEXCLICore"]),
        .executable(name: "pexengine", targets: ["PEXCLI"]),
    ],
    targets: [
        .target(name: "PEXCore"),
        .target(name: "PEXAdapters", dependencies: ["PEXCore"]),
        .target(name: "PEXParsers", dependencies: ["PEXCore"]),
        .target(name: "PEXPersistence", dependencies: ["PEXCore"]),
        .target(name: "PEXRuntime", dependencies: [
            "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence",
        ]),
        .target(name: "PEXEngine", dependencies: [
            "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence", "PEXRuntime",
        ]),
        .target(name: "PEXCLICore", dependencies: ["PEXEngine"]),
        .executableTarget(name: "PEXCLI", dependencies: ["PEXCLICore"], path: "Sources/PEXCLI"),

        .testTarget(name: "PEXCoreTests", dependencies: ["PEXCore"]),
        .testTarget(name: "PEXAdaptersTests", dependencies: ["PEXAdapters", "PEXCore"]),
        .testTarget(name: "PEXParsersTests", dependencies: ["PEXParsers", "PEXCore"]),
        .testTarget(name: "PEXPersistenceTests", dependencies: ["PEXPersistence", "PEXCore"]),
        .testTarget(name: "PEXRuntimeTests", dependencies: [
            "PEXRuntime", "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence",
        ]),
        .testTarget(name: "PEXCLITests", dependencies: [
            "PEXCLICore", "PEXEngine", "PEXCore",
        ]),
    ]
)
