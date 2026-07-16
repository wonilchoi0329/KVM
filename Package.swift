// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HostHop",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "HostHopCore", targets: ["HostHopCore"]),
        .executable(name: "HostHop", targets: ["HostHop"]),
    ],
    targets: [
        .target(
            name: "HostHopDDC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "HostHopCore",
            dependencies: ["HostHopDDC"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "HostHop",
            dependencies: ["HostHopCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "HostHopCoreTests",
            dependencies: ["HostHopCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
