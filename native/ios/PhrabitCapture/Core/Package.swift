// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PhrabitCaptureCore",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [
        .library(name: "PhrabitCaptureCore", targets: ["PhrabitCaptureCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.7")
    ],
    targets: [
        .target(name: "PhrabitCaptureCore", dependencies: [.product(name: "Auth", package: "supabase-swift")]),
        .testTarget(name: "PhrabitCaptureCoreTests", dependencies: ["PhrabitCaptureCore"])
    ]
)

