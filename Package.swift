// swift-tools-version: 5.9
import Foundation
import PackageDescription

// fairy cursor compiles ausm's screenshot and cursor kits into the app, so nothing from ausm is
// needed at run time. they come from the published package; to build against a local ausm
// checkout instead, run with AUSM_ROOT=/path/to/ausm.
let localAUSM = ProcessInfo.processInfo.environment["AUSM_ROOT"]
let ausm: Package.Dependency = localAUSM.map { .package(name: "AUSM", path: $0) }
    ?? .package(url: "https://github.com/foundation-interface/ausm.git", from: "0.1.0")

let package = Package(
    name: "FairyCursor",
    platforms: [.macOS("26.0")],
    dependencies: [ausm],
    targets: [
        // pure decision logic (shake detection, the held pile, drop and paste policies):
        // no appkit, no live accessibility or event taps, fully unit-tested.
        .target(name: "FairyCore", path: "sources/core"),
        .executableTarget(
            name: "FairyCursor",
            dependencies: [
                "FairyCore",
                .product(name: "ScreenshotMonitorKit", package: "AUSM"),
                .product(name: "CursorMonitorKit", package: "AUSM"),
            ],
            path: "sources/app"
        ),
        .testTarget(name: "FairyCoreTests", dependencies: ["FairyCore"], path: "tests/core"),
    ]
)
