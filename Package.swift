// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TVYansit",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TVYansit", path: "Sources/TVYansit")
    ]
)
