// swift-tools-version: 6.3

import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.1021.0"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    revision: "e15ea6cd60ca1957297aafbba839e51a478d735e"
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
        .package(url: "https://github.com/1amageek/LogicDesign.git",
                 revision: "e788e555569862a9ed37d34ba3b686bd516cb5cd"),
        .package(url: "https://github.com/1amageek/swift-mask-data.git",
                 revision: "d23f9afd9c049cf06a12e307e4c26b4dd3ad216d"),
        .package(url: "https://github.com/1amageek/semiconductor-layout.git",
                 revision: "11f1b45af482fc391adf7f3d3e81b58c8d3d8c3f"),
    ],
    targets: [
        .target(
            name: "PEXCore",
            dependencies: [
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            ],
            exclude: ["DESIGN.md", "ElectricalModel/DESIGN.md", "BackendExecution/DESIGN.md", "NativeInput/DESIGN.md"]
        ),
        .target(
            name: "PEXAdapters",
            dependencies: [
                "PEXCore", "PEXNative", "PEXPersistence", "PEXParsers",
                .product(name: "LogicDesignSerialization", package: "LogicDesign"),
                .product(name: "LogicKernelCore", package: "LogicDesign"),
                .product(name: "DEF", package: "swift-mask-data"),
                .product(name: "LEF", package: "swift-mask-data"),
                .product(name: "LayoutIO", package: "semiconductor-layout"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ], exclude: ["DESIGN.md", "NativeBackend/DESIGN.md", "NativeBackend/RoutedInputPreparation/DESIGN.md", "ProcessExecution/DESIGN.md"]
        ),
        .target(name: "PEXParsers", dependencies: ["PEXCore"], exclude: ["DESIGN.md", "OpenRCXRules/DESIGN.md"]),
        .target(name: "PEXNative", dependencies: [
            "PEXCore",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            .product(name: "LayoutCore", package: "semiconductor-layout"),
            .product(name: "LayoutVerify", package: "semiconductor-layout"),
            .product(name: "MaskGeometry", package: "swift-mask-data"),
            .product(name: "LayoutIR", package: "swift-mask-data"),
        ], exclude: ["DESIGN.md", "SheetExtraction/DESIGN.md", "ElectrodeConstruction/DESIGN.md", "CanonicalProjection/DESIGN.md", "InputPreparation/DESIGN.md", "CodeImage/DESIGN.md", "RoutedRuleExtraction/DESIGN.md", "ConductorUnion/DESIGN.md", "RectilinearSheetNetwork/DESIGN.md", "GroundCapacitance/DESIGN.md"]),
        .target(name: "PEXPersistence", dependencies: ["PEXCore"], exclude: ["DESIGN.md", "NativeInputCapture/DESIGN.md"]),
        .target(name: "PEXRuntime", dependencies: [
            "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
        ], exclude: ["DESIGN.md", "NativeInputLoading/DESIGN.md"]),
        .target(name: "PEXEngine", dependencies: [
            "PEXCore", "PEXAdapters", "PEXParsers", "PEXPersistence", "PEXRuntime",
        ]),
        .target(name: "PEXCLICore", dependencies: [
            "PEXEngine",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
        ], exclude: ["DESIGN.md"]),
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
            "PEXNative", "PEXCore", "PEXParsers",
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
                "PEXTestSupport", "PEXNative", "PEXPersistence", "PEXRuntime",
                .product(name: "LayoutIO", package: "semiconductor-layout"),
                .product(name: "LayoutCore", package: "semiconductor-layout"),
                .product(name: "LayoutTech", package: "semiconductor-layout"),
                .product(name: "LayoutVerify", package: "semiconductor-layout"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            ],
            resources: [
                .copy("Fixtures/pex_plate.gds"),
                .copy("Fixtures/inv1.gds"),
                .copy("../PEXParsersTests/Fixtures/OpenRCXRules"),
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
            "PEXCLICore", "PEXEngine", "PEXRuntime", "PEXCore", "PEXTestSupport",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
        ]),
    ]
)
