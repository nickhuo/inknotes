// swift-tools-version: 6.0
import Foundation
import PackageDescription

// PencilKit keeps per-app state under the bundle identifier and crashes in a process
// without one, so the command-line binary embeds an Info.plist (__TEXT,__info_plist).
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Sources/nnote/Info.plist").path

let package = Package(
    name: "nnote",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "nnote",
            path: "Sources/nnote",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreData"), .linkedFramework("PencilKit"), .linkedFramework("AppKit"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
