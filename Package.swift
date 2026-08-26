// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PyodideKit",
    platforms: [.iOS(.v16), .macCatalyst(.v16), .macOS(.v13)],
    products: [
        .library(name: "PyodideKit", targets: ["PyodideKit"]),
    ],
    targets: [
        .target(
            name: "PyodideKit",
            resources: [.copy("Resources/pyodide_host.html")]
        ),
        .testTarget(
            name: "PyodideKitTests",
            dependencies: ["PyodideKit"]
        ),
    ]
)
