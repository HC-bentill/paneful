// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Paneful",
    platforms: [
        .macOS("27.2")
    ],
    products: [
        .executable(name: "Paneful", targets: ["Paneful"])
    ],
    targets: [
        .executableTarget(
            name: "Paneful",
            path: "Sources/Paneful",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "PanefulTests",
            dependencies: ["Paneful"],
            path: "Tests/PanefulTests"
        )
    ]
)
