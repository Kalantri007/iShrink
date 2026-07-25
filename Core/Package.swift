// swift-tools-version:5.9
import PackageDescription

// Version pins matched to spikes/photokit-replace-spike/Package.swift so the
// engine package and the earlier spike stay on the same Swift tools / macOS
// baseline (plan: U1 "Pin versions to match the spike").
let package = Package(
    name: "iShrinkCore",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "iShrinkCore",
            targets: ["iShrinkCore"]
        )
    ],
    targets: [
        .target(
            name: "iShrinkCore"
        ),
        .testTarget(
            name: "iShrinkCoreTests",
            dependencies: ["iShrinkCore"]
        )
    ]
)
