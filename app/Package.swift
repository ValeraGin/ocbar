// swift-tools-version:5.9
import PackageDescription

// Приложение меню-бара. Собирается тем же SwiftPM, что и auth/, тем же
// `swift build -c release`. Привилегий не требует: читает `ocbar status
// --short` и зовёт `ocbar` для действий — вся работа с root уже заперта
// в libexec/ocbar-helper.
let package = Package(
    name: "ocbar-app",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ocbar-app",
            path: "Sources/ocbar-app",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)
