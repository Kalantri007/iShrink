// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoKitReplaceSpike",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "PhotoKitReplaceSpike",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embeds Info.plist into the built binary so macOS shows the correct
                // TCC (Photos access) prompt for a plain SPM executable — Info.plist
                // isn't picked up automatically the way it is for an Xcode app target.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/PhotoKitReplaceSpike/Info.plist"
                ])
            ]
        )
    ]
)
