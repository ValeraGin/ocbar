// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ocbar-auth",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ocbar-auth",
            path: "Sources/ocbar-auth",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        )
    ]
)
