// swift-tools-version: 6.3

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
    dependencies: [
        .package(url: "https://github.com/apple/swift-configuration", .upToNextMinor(from: "0.1.0")),
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
        .target(name: "PEXCLICore", dependencies: [
            "PEXEngine",
            .product(name: "Configuration", package: "swift-configuration"),
        ]),
        .executableTarget(name: "PEXCLI", dependencies: ["PEXCLICore"], path: "Sources/PEXCLI"),

        .testTarget(name: "PEXCoreTests", dependencies: ["PEXCore"]),
        .testTarget(
            name: "PEXAdaptersTests",
            dependencies: ["PEXAdapters", "PEXCore", "PEXParsers"],
            resources: [
                .copy("Fixtures/pex_plate.gds"),
                .copy("Fixtures/inv1.gds"),
            ]
        ),
        .testTarget(
            name: "PEXParsersTests",
            dependencies: ["PEXParsers", "PEXCore"],
            resources: [.copy("Fixtures/OpenROAD")]
        ),
        .testTarget(name: "PEXPersistenceTests", dependencies: ["PEXPersistence", "PEXCore"]),
        .testTarget(
            name: "PEXRuntimeTests",
            dependencies: [
                "PEXRuntime", "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence",
            ],
            resources: [.copy("Fixtures/pex_plate.gds")]
        ),
        .testTarget(name: "PEXCLITests", dependencies: [
            "PEXCLICore", "PEXEngine", "PEXCore",
        ]),
    ]
)
