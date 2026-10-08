// swift-tools-version:6.0
import PackageDescription

// Library-only package: no executable or app target lives here.
// The runnable demo is a separate Xcode project in its own repository
// (feature-contract-kit-demo-app) that consumes this package by release tag.
let package = Package(
    name: "FeatureContracts",
    // Only platforms that CI actually builds are declared. Linux builds the
    // core module (the server side of "one contract, two runtimes").
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FeatureContracts", targets: ["FeatureContracts"]),
        .library(name: "FeatureContractsUI", targets: ["FeatureContractsUI"]),
    ],
    targets: [
        .target(name: "FeatureContracts"),
        .target(name: "FeatureContractsUI", dependencies: ["FeatureContracts"]),
        .testTarget(name: "FeatureContractsTests", dependencies: ["FeatureContracts"]),
    ]
)
