// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCPodMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CCPodMenuBar", targets: ["CCPodMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "CCPodMenuBar",
            path: "Sources/CCPodMenuBar"
        ),
    ]
)
