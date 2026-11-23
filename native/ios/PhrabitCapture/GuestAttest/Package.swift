// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhrabitGuestAttest",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [.library(name: "PhrabitGuestAttest", targets: ["PhrabitGuestAttest"])],
    targets: [
        .target(name: "PhrabitGuestAttest"),
        .testTarget(name: "PhrabitGuestAttestTests", dependencies: ["PhrabitGuestAttest"])
    ]
)
