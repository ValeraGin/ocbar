// swift-tools-version:5.9
import PackageDescription

// Приложение меню-бара. Собирается тем же SwiftPM, что и auth/, тем же
// `swift build -c release`. Привилегий не требует: читает `ocmac status
// --short` и зовёт `ocmac` для действий — вся работа с root уже заперта
// в libexec/ocmac-helper.
let package = Package(
    name: "ocmac-app",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "ocmac-app",
            path: "Sources/ocmac-app",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        )
    ]
)
