// swift-tools-version: 6.0
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────────
// DEVELOPMENT vs. RELEASE binary targets
//
// During development, run `./scripts/build-xcframeworks.sh` first to
// populate the Frameworks/ directory, then build normally.
//
// For a published release, replace the .binaryTarget entries below with
// the URL+checksum form produced by the GitHub Actions build workflow:
//
//   .binaryTarget(
//       name: "Cjq",
//       url: "https://github.com/Harwood/jqKit/releases/download/<tag>/Cjq.xcframework.zip",
//       checksum: "<sha256>"),
//   .binaryTarget(
//       name: "Coniguruma",
//       url: "https://github.com/Harwood/jqKit/releases/download/<tag>/Coniguruma.xcframework.zip",
//       checksum: "<sha256>"),
// ─────────────────────────────────────────────────────────────────────────────

let package = Package(
    name: "jqKit",
    // Intentionally broader than UtilitiesKit so jqKit is independently reusable.
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .visionOS(.v1),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "jqKit", targets: ["jqKit"]),
    ],
    targets: [
        // Swift API layer — depends on the two C XCFrameworks.
        .target(
            name: "jqKit",
            dependencies: ["Cjq", "Coniguruma"],
            path: "Sources/jqKit"
        ),
        // libjq 1.8.x static library, packaged as XCFramework.
        // Build with: ./scripts/build-xcframeworks.sh
        .binaryTarget(
            name: "Cjq",
            path: "Frameworks/Cjq.xcframework"
        ),
        // linoniguruma (jq's regex engine), packaged as XCFramework.
        .binaryTarget(
            name: "Coniguruma",
            path: "Frameworks/Coniguruma.xcframework"
        ),
        .testTarget(
            name: "jqKitTests",
            dependencies: ["jqKit"],
            path: "Tests/jqKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
