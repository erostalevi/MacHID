// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacHID",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacHIDDomain", targets: ["MacHIDDomain"]),
        .library(name: "MacHIDApplication", targets: ["MacHIDApplication"]),
        .executable(name: "machid", targets: ["machid"]),
        .executable(name: "MacHIDApp", targets: ["MacHIDApp"]),
        .executable(name: "machid-validate", targets: ["machid-validate"]),
    ],
    targets: [
        // Pure domain: no IOKit/AppKit/SwiftUI. Hardware sits behind ports.
        .target(name: "MacHIDDomain"),
        // Use cases: depend on domain ports only.
        .target(name: "MacHIDApplication", dependencies: ["MacHIDDomain"]),
        // Protocol-family driver: Razer 90-byte report protocol. Pure logic, hardware via Transport.
        .target(name: "MacHIDRazer", dependencies: ["MacHIDDomain"]),
        // Protocol-family driver: Logitech HID++ 2.0 (read-only for now).
        .target(name: "MacHIDLogitech", dependencies: ["MacHIDDomain"]),
        // Generic USB Video Class driver: camera controls via class requests.
        .target(name: "MacHIDUVC", dependencies: ["MacHIDDomain"]),
        // Adapter: IOKit enumeration. The only place that imports IOKit.
        .target(name: "MacHIDIOKit", dependencies: ["MacHIDDomain"], linkerSettings: [.linkedFramework("IOUSBHost")]),
        // Composition: picks the driver family and transport for a device. Shared by the CLI and the app.
        .target(name: "MacHIDSystem", dependencies: ["MacHIDDomain", "MacHIDApplication", "MacHIDIOKit", "MacHIDRazer", "MacHIDLogitech", "MacHIDUVC"]),
        // SwiftUI models and views (menu bar panel and main window). Logic lives here so it can be tested.
        .target(name: "MacHIDUI", dependencies: ["MacHIDDomain", "MacHIDApplication", "MacHIDIOKit", "MacHIDSystem"]),
        .executableTarget(name: "MacHIDApp", dependencies: ["MacHIDUI"]),
        // Design review tool: renders the views to PNG files offscreen.
        .executableTarget(name: "MacHIDSnapshots", dependencies: ["MacHIDUI", "MacHIDDomain"]),
        .executableTarget(name: "machid", dependencies: ["MacHIDDomain", "MacHIDApplication", "MacHIDIOKit", "MacHIDSystem"]),
        .executableTarget(name: "machid-validate", dependencies: ["MacHIDDomain"]),
        .testTarget(name: "MacHIDDomainTests", dependencies: ["MacHIDDomain"]),
        .testTarget(name: "MacHIDRazerTests", dependencies: ["MacHIDRazer", "MacHIDDomain"]),
        .testTarget(name: "MacHIDLogitechTests", dependencies: ["MacHIDLogitech", "MacHIDDomain"]),
        .testTarget(name: "MacHIDUVCTests", dependencies: ["MacHIDUVC", "MacHIDDomain"]),
        .testTarget(name: "MacHIDUITests", dependencies: ["MacHIDUI", "MacHIDDomain", "MacHIDApplication"]),
        .testTarget(name: "MacHIDApplicationTests", dependencies: ["MacHIDApplication", "MacHIDDomain"]),
    ]
)
