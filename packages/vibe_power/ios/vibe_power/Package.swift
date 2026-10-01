// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

// Plugin local de Vibe Player — intégration Swift Package Manager de
// l'implémentation iOS (mêmes sources que vibe_power.podspec pour CocoaPods).

import PackageDescription

let package = Package(
    name: "vibe_power",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "vibe-power", targets: ["vibe_power"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "vibe_power",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Manifeste de confidentialité vide (aucune "required reason
                // API" utilisée), fourni pour la conformité App Store.
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
