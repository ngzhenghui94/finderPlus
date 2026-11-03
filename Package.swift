// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderPlus",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "FinderPlus", targets: ["FinderPlus"])],
    targets: [.executableTarget(name: "FinderPlus")],
    swiftLanguageModes: [.v5]
)
