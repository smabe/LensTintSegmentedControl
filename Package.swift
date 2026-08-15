// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LensTintSegmentedControl",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(name: "LensTintSegmentedControl", targets: ["LensTintSegmentedControl"])
    ],
    targets: [
        .target(name: "LensTintSegmentedControl")
    ],
    swiftLanguageModes: [.v6]
)
