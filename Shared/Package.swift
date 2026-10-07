// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "RimesCore",
    platforms: [.iOS(.v17), .macOS("12.3")],
    products: [.library(name: "RimesCore", targets: ["RimesCore"])],
    targets: [
        .target(name: "RimesCore", resources: [.process("Resources/flyyao.json"), .copy("Resources/OfficialPlugins")]),
        .testTarget(name: "RimesCoreTests", dependencies: ["RimesCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
