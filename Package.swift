// swift-tools-version:6.1
//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-libp2p-fluent",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "Fluent", targets: ["Fluent"])
    ],
    traits: [
        .trait(
            name: "SQLiteTests",
            description:
                "Runs additional tests against an in-memory SQLite database. Intended for local development and CI (`swift test --traits SQLiteTests`)."
        ),
        // The SQLite packages are disabled by default
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/fluent-kit.git", .upToNextMajor(from: "1.52.2")),
        .package(url: "https://github.com/swift-libp2p/swift-libp2p.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/vapor/console-kit.git", .upToNextMajor(from: "4.15.0")),
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.87.0")),
        .package(url: "https://github.com/vapor/routing-kit.git", .upToNextMajor(from: "4.0.0")),
        // Test only dependencies, gated behind the `SQLiteTests` trait
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", .upToNextMajor(from: "4.8.0")),
    ],
    targets: [
        .target(
            name: "Fluent",
            dependencies: [
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "LibP2P", package: "swift-libp2p"),
                .product(name: "ConsoleKit", package: "console-kit"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "FluentTests",
            dependencies: [
                .target(name: "Fluent"),
                .product(name: "XCTFluent", package: "fluent-kit"),
                .product(name: "LibP2PTesting", package: "swift-libp2p"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(
                    name: "FluentSQLiteDriver",
                    package: "fluent-sqlite-driver",
                    condition: .when(traits: ["SQLiteTests"])
                ),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] {
    [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
    ]
}
