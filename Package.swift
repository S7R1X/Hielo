// swift-tools-version:6.0
import PackageDescription

// Test-only package. It compiles Hielo's pure macOS 27 logic so that logic can be
// unit tested with `swift test`. The same files are compiled into the Hielo app
// through the synchronized `Hielo` folder group.
let package = Package(
    name: "HieloMacOS27Core",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HieloMacOS27Core",
            path: "Hielo/MenuBar/MacOS27/Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HieloMacOS27CoreTests",
            dependencies: ["HieloMacOS27Core"],
            path: "Tests/HieloMacOS27CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
