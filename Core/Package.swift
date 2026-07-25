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
            dependencies: ["iShrinkCore"],
            // U6 "Non-destructive HEIC compression engine": committed
            // fixture images (real GPS/EXIF/orientation/P3 metadata) plus
            // the generator script that produced them. `.copy` (not
            // `.process`) so the files land byte-for-byte in the test
            // bundle's resource directory — these are test inputs, not
            // assets to be optimized/recompressed by SPM's resource
            // pipeline.
            resources: [.copy("Fixtures")]
        )
    ]
)
