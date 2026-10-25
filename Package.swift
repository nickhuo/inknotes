// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "nnote",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "nnote",
            path: "Sources/nnote",
            linkerSettings: [.linkedFramework("CoreData"), .linkedFramework("PencilKit"), .linkedFramework("AppKit")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
