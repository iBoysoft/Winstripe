// swift-tools-version:5.8
// Tools 5.8 lets Xcode 14.3 read this manifest. Swift 5 language mode keeps strict-concurrency diagnostics minimal;
// all UI types are still annotated @MainActor so the code is ready for Swift 6 mode.
import PackageDescription

let package = Package(
    name: "Winstripe",
    defaultLocalization: "en",
    // The default build system raises this to 12.0; scripts/build-macos11.sh (used by
    // bundle.sh and the verification) builds and checks against a real 11.0 target.
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "Winstripe", targets: ["Winstripe"])
    ],
    dependencies: [
        // 5.0.1 and later need tools 5.9, which Xcode 14 cannot read.
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Legacy.git", exact: "5.0.0"),
        // Sparkle 2.9.6 still supports the macOS 11 deployment target used by Winstripe.
        // Keep this exact so a future Sparkle release cannot raise the app's minimum OS
        // without an explicit project change.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Winstripe",
            dependencies: [
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Legacy"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Winstripe",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
