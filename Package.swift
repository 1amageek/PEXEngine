// swift-tools-version: 6.3

import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.812.0"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    exact: "26.812.0"
)

let package = Package(
    name: "PEXEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PEXCore", targets: ["PEXCore"]),
        .library(name: "PEXAdapters", targets: ["PEXAdapters"]),
        .library(name: "PEXNative", targets: ["PEXNative"]),
        .library(name: "PEXParsers", targets: ["PEXParsers"]),
        .library(name: "PEXPersistence", targets: ["PEXPersistence"]),
        .library(name: "PEXRuntime", targets: ["PEXRuntime"]),
        .library(name: "PEXEngine", targets: ["PEXEngine"]),
        .library(name: "PEXCLICore", targets: ["PEXCLICore"]),
        .executable(name: "pexengine", targets: ["PEXCLI"]),
    ],
    dependencies: [
        circuiteFoundationDependency,
        signoffToolSupportDependency,
        .package(url: "https://github.com/1amageek/semiconductor-layout.git",
                 revision: "23037c0b5c7cb92c671c03f9436ae3feca1321a1"),
    ],
    targets: [
        .target(
            name: "PEXCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            ],
            exclude: ["DESIGN.md", "ElectricalModel/DESIGN.md"]
        ),
        .target(
            name: "PEXAdapters",
            dependencies: [
                "PEXCore",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ]
        ),
        .target(name: "PEXParsers", dependencies: ["PEXCore"]),
        .target(name: "PEXNative", dependencies: [
            "PEXCore",
            .product(name: "LayoutCore", package: "semiconductor-layout"),
            .product(name: "LayoutVerify", package: "semiconductor-layout"),
        ], exclude: ["DESIGN.md", "SheetExtraction/DESIGN.md", "ElectrodeConstruction/DESIGN.md"]),
        .target(name: "PEXPersistence", dependencies: ["PEXCore"]),
        .target(name: "PEXRuntime", dependencies: [
            "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
        ]),
        .target(name: "PEXEngine", dependencies: [
            "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence", "PEXRuntime",
        ]),
        .target(name: "PEXCLICore", dependencies: [
            "PEXEngine",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
        ]),
        .executableTarget(name: "PEXCLI", dependencies: ["PEXCLICore"], path: "Sources/PEXCLI"),

        .testTarget(
            name: "PEXCoreTests",
            dependencies: [
                "PEXCore",
                "PEXTestSupport",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            ],
            resources: [.copy("Fixtures/pex-evidence-packet-v3.json")]
        ),
        .testTarget(name: "PEXNativeTests", dependencies: [
            "PEXNative", "PEXCore",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "LayoutIO", package: "semiconductor-layout"),
            .product(name: "LayoutCore", package: "semiconductor-layout"),
            .product(name: "LayoutTech", package: "semiconductor-layout"),
            .product(name: "LayoutVerify", package: "semiconductor-layout"),
        ]),
        .target(
            name: "PEXTestSupport",
            dependencies: [
                "PEXCore", "PEXAdapters", "PEXParsers", "PEXRuntime",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            ],
            path: "Tests/PEXTestSupport",
            resources: [.copy("../PEXParsersTests/Fixtures/OpenROAD")]
        ),
        .testTarget(
            name: "PEXAdaptersTests",
            dependencies: [
                "PEXAdapters",
                "PEXCore",
                "PEXParsers",
                "PEXTestSupport",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ],
            resources: [
                .copy("Fixtures/pex_plate.gds"),
                .copy("Fixtures/inv1.gds"),
            ]
        ),
        .testTarget(
            name: "PEXParsersTests",
            dependencies: [
                "PEXParsers",
                "PEXCore",
                "PEXTestSupport",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            ]
        ),
        .testTarget(
            name: "PEXPersistenceTests",
            dependencies: [
                "PEXPersistence",
                "PEXCore",
                "PEXTestSupport",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            ],
            resources: [.copy("Fixtures/pex-artifact-manifest-v5.json")]
        ),
        .testTarget(
            name: "PEXRuntimeTests",
            dependencies: [
                "PEXRuntime", "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence",
                "PEXTestSupport",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            ],
            resources: [
                .copy("Fixtures/ExternalExtractor"),
                .copy("Fixtures/pex_plate.gds"),
            ]
        ),
        .testTarget(name: "PEXCLITests", dependencies: [
            "PEXCLICore", "PEXEngine", "PEXCore", "PEXTestSupport",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
        ]),
    ]
)
