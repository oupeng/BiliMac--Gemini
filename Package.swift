// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BiliMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BiliMac", targets: ["BiliMac"])
    ],
    targets: [
        .executableTarget(
            name: "BiliMac",
            path: "Sources"
        )
    ]
)
