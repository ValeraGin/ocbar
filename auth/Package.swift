// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ocmac-auth",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ocmac-auth",
            path: "Sources/ocmac-auth",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        )
    ]
)
