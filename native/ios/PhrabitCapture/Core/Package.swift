// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhrabitCaptureCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [
        .library(name: "PhrabitCaptureCore", targets: ["PhrabitCaptureCore"])
    ],
    targets: [
        .target(name: "PhrabitCaptureCore"),
        .testTarget(name: "PhrabitCaptureCoreTests", dependencies: ["PhrabitCaptureCore"])
    ]
)

