// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Tessera", targets: ["Tessera"]),
        .library(name: "TesseraCore", targets: ["TesseraCore"]),
    ],
    targets: [
        .target(name: "TesseraCore"),
        .executableTarget(
            name: "Tessera",
            dependencies: ["TesseraCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .testTarget(name: "TesseraCoreTests", dependencies: ["TesseraCore"]),
    ]
)
