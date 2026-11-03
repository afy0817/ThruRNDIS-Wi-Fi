// swift-tools-version:5.10
// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
    name: "ThruRNDISWiFi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ThruRNDISWiFi",
            path: "Sources/ThruRNDISWiFi",
            linkerSettings: [.linkedFramework("Security")]
        )
    ]
)
