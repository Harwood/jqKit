// swift-tools-version: 6.0
import PackageDescription

// ─────────────────────────────────────────────────────────────────────────────
// DEVELOPMENT vs. RELEASE binary targets
//
// During development:
// 1. Run `swift package plugin --allow-writing-to-package-directory build-xcframeworks`
//    or `./scripts/build-xcframeworks.sh` to populate Frameworks/
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
    // Swift API layer imports Cjq; Coniguruma is linked for jq regex support.
    .target(
      name: "jqKit",
      dependencies: ["Cjq", "Coniguruma"],
      path: "Sources/jqKit",
      swiftSettings: [
        .unsafeFlags(["-Osize"], .when(configuration: .release)),
      ],
      linkerSettings: [
        .unsafeFlags(["-dead_strip"], .when(configuration: .release)),
      ]
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
    .plugin(
      name: "BuildXCFrameworksPlugin",
      capability: .command(
        intent: .custom(
          verb: "build-xcframeworks",
          description: "Build jq and oniguruma XCFrameworks into Frameworks/"
        ),
        permissions: [
          .writeToPackageDirectory(
            reason: "The build script writes Cjq.xcframework and Coniguruma.xcframework into Frameworks/."
          ),
        ]
      )
    ),
  ],
  swiftLanguageModes: [.v6]
)
