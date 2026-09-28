# Swift LibP2P Fluent

[![](https://img.shields.io/badge/made%20by-Breth-blue.svg?style=flat-square)](https://breth.app)
[![](https://img.shields.io/badge/project-libp2p-yellow.svg?style=flat-square)](http://libp2p.io/)
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-blue.svg?style=flat-square)](https://github.com/apple/swift-package-manager)
![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/build+test.yml/badge.svg)

> Fluent is a database abstraction layer that makes interacting with databases within swift-libp2p ezpz!

## Table of Contents

- [Overview](#overview)
- [Install](#install)
- [Usage](#usage)
  - [Example](#example)
- [Drivers](#drivers)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

## Overview

Fluent is an ORM framework for Swift. It takes advantage of Swift's strong type system to provide an easy-to-use interface for your database. 
Using Fluent centers around the creation of model types which represent data structures in your database. These models are then used to perform create, read, update, and delete operations instead of writing raw queries.

### Docs & Examples
- [**Vapor's Fluent Documentation**](https://docs.vapor.codes/fluent/overview/)

## Install

Include the following dependency in your Package.swift file
``` swift
let package = Package(
    ...
    dependencies: [
        ...
        .package(url: "https://github.com/swift-libp2p/swift-libp2p-fluent.git", .upToNextMinor(from: "0.1.0"))
    ],
        ...
        .target(
            ...
            dependencies: [
                ...
                .product(name: "Fluent", package: "swift-libp2p-fluent"),
            ]),
    ...
)
```

## Usage

### Example 
``` swift
import LibP2P
import Fluent
// import <Your Fluent Driver>

/// Configure your Libp2p networking stack...
let app = try await Application.make(.detect(), peerID: .ephemeral(.Ed25519))

// To use the database throughout your app
app.databases.use( /*Your database driver*/ )

// To use the configured database for the peerstore
app.peerstore.prepareMigrations()
app.peerstore.use(.fluent)

// To use the configured database for cache
app.migrations.add(CacheEntry.migrations)
app.caches.use(.fluent)

// Run any pending migrations (or launch with the `--auto-migrate` flag)
try await app.autoMigrate()
```

> [!IMPORTANT]
> In v0.1.0, cache now supports expiration, register `CacheEntry.migrations` and re-run your migrations to update your existing table.

### PeerStore

`FluentPeerStore` behaves like swift-libp2p's in-memory peerstore, but persists across restarts:
- Operations run in the order they're called.
- Both versions of a peer's id (`12D3Koo…` and `Qm…`) resolve to the same peer.
- Addresses are stored in their `/p2p/<peer>` form.
- The store is capped at a maximum number of peers.

``` swift
// Capacity limits (these are the defaults)
app.peerstore.use(.fluent(nil, configuration: .init(maxPeers: 5_000, maxRecordsPerPeer: 3)))

// Maintenance helpers that aren't part of the `PeerStore` protocol
if let store = app.peers as? FluentPeerStore {
    try await store.prunePeers(olderThan: .minutes(10)).get()
    try await store.trimAllRecords().get()
}
```

> [!IMPORTANT]
> In v0.1.0, the peerstore has a new schema. Peers are keyed by their canonical id, and metadata and records are stored as binary data. `app.peerstore.prepareMigrations()` registers a single migration that replaces the old peerstore tables. Migrating drops all existing data.

## Drivers

| Name | Description | Build (macOS & Linux) |
| --------- | --------- | --------- |
| **Supported** |
| [`SQLite`](//github.com/vapor/fluent-sqlite-driver) | Fluent driver for SQLite | [![Build & Test Drivers](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml/badge.svg)](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml) |
| [`PostgreSQL`](//github.com/vapor/fluent-postgres-driver) | Fluent driver for PostgreSQL | [![Build & Test Drivers](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml/badge.svg)](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml) |
| [`MySQL`](//github.com/vapor/fluent-mysql-driver) | Fluent driver for MySQL / MariaDB | [![Build & Test Drivers](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml/badge.svg)](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml) |
| [`MongoDB`](//github.com/vapor/fluent-mongo-driver) | Fluent driver for MongoDB | [![Build & Test Drivers](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml/badge.svg)](https://github.com/swift-libp2p/swift-libp2p-fluent/actions/workflows/drivers.yml) |
| **Community Drivers** |
| [`Github Tag`](//github.com/topics/fluent-driver) | A list of all fluent drivers | N/A |


## Running the tests

`swift test` runs the unit tests against a mock database. To run additional tests against an in-memory SQLite database enable the SQLiteTests trait (which will pull in the appropriate dependencies).

```sh
swift test --traits SQLiteTests
```


## Contributing

Contributions are welcomed! This code is very much a proof of concept. I can guarantee you there's a better / safer way to accomplish the same results. Any suggestions, improvements, or even just critiques, are welcome! 

Let's make this code better together! 🤝

## Credits

- [vapor](https://github.com/vapor/vapor) 
- [fluent](https://github.com/vapor/fluent)

## License

[MIT](LICENSE.md) © 2026 Breth Inc.

