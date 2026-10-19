// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHID",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacHIDDomain", targets: ["MacHIDDomain"]),
        .library(name: "MacHIDApplication", targets: ["MacHIDApplication"]),
        .executable(name: "machid", targets: ["machid"]),
        .executable(name: "machid-validate", targets: ["machid-validate"]),
    ],
    targets: [
        // Pure domain: no IOKit/AppKit/SwiftUI. Hardware sits behind ports.
        .target(name: "MacHIDDomain"),
        // Use cases: depend on domain ports only.
        .target(name: "MacHIDApplication", dependencies: ["MacHIDDomain"]),
        // Adapter: IOKit enumeration. The only place that imports IOKit.
        .target(name: "MacHIDIOKit", dependencies: ["MacHIDDomain"]),
        .executableTarget(name: "machid", dependencies: ["MacHIDDomain", "MacHIDApplication", "MacHIDIOKit"]),
        .executableTarget(name: "machid-validate", dependencies: ["MacHIDDomain"]),
        .testTarget(name: "MacHIDDomainTests", dependencies: ["MacHIDDomain"]),
        .testTarget(name: "MacHIDApplicationTests", dependencies: ["MacHIDApplication", "MacHIDDomain"]),
    ]
)
