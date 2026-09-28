// swift-tools-version: 6.2
// Resources are staged into Host/Resources by `make stage`.
import PackageDescription

let package = Package(
    name: "Sidekernel",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Host",
            path: "Host",
            resources: [
                .copy("Resources/sk-agent"),
                .copy("Resources/save"),
                .copy("Resources/sk-drop"),
                .copy("Resources/sk-net"),
                .copy("Resources/ramblinwreck"),
                .copy("Resources/seed"),
                .copy("Resources/bashrc"),
                .copy("Resources/clip"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
