// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHID",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacHIDDomain", targets: ["MacHIDDomain"]),
        .executable(name: "machid", targets: ["machid"]),
        .executable(name: "machid-validate", targets: ["machid-validate"]),
    ],
    targets: [
        // Pure domain: no IOKit/AppKit/SwiftUI. Hardware sits behind ports.
        .target(name: "MacHIDDomain"),
        .executableTarget(name: "machid", dependencies: ["MacHIDDomain"]),
        .executableTarget(name: "machid-validate", dependencies: ["MacHIDDomain"]),
        .testTarget(name: "MacHIDDomainTests", dependencies: ["MacHIDDomain"]),
    ]
)
