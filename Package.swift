// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiwiKInsightKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HiwiKInsightKit", targets: ["HiwiKInsightKit"]),
    ],
    targets: [
        .target(name: "HiwiKInsightKit"),
        .testTarget(name: "HiwiKInsightKitTests", dependencies: ["HiwiKInsightKit"]),
    ]
)
