// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Fairy Cursor links AUSM's Swift kits (ScreenshotMonitorKit, CursorMonitorKit) in-process; they are
// compiled into the app binary, so nothing from AUSM is needed at run time.
// Point AUSM_ROOT at an AUSM checkout (repo root); defaults to the sibling worktree.
// Once AUSM is public, this can become:
//   .package(url: "https://github.com/foundation-interface/AUSM.git", from: "0.1.0")
let ausmRoot = ProcessInfo.processInfo.environment["AUSM_ROOT"] ?? "../AUSM-releasing"

let package = Package(
    name: "FairyCursor",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(name: "AUSM", path: ausmRoot),
    ],
    targets: [
        // Pure decision logic (shake detection, the held-screenshot pile, drop/paste policies);
        // no AppKit, no live accessibility or event taps, so it is fully unit-tested.
        .target(
            name: "FairyCore",
            path: "Sources/FairyCore"
        ),
        .executableTarget(
            name: "FairyCursor",
            dependencies: [
                "FairyCore",
                .product(name: "ScreenshotMonitorKit", package: "AUSM"),
                .product(name: "CursorMonitorKit", package: "AUSM"),
            ],
            path: "Sources/FairyCursor"
        ),
        .testTarget(
            name: "FairyCoreTests",
            dependencies: ["FairyCore"],
            path: "Tests/FairyCoreTests"
        ),
    ]
)
