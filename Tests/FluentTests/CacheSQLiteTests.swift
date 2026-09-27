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

#if SQLiteTests
import Fluent
import FluentSQLiteDriver
import Foundation
import LibP2P
import LibP2PTesting
import Testing

/// Fluent cache tests against an in-memory SQLite database.
///
/// Run with `swift test --traits SQLiteTests`.
@Suite("Cache SQLite Tests")
struct CacheSQLiteTests {
    @Test func setReplacesExistingValue() async throws {
        try await withCacheApp { app in
            try await app.cache.set("foo", to: "bar")
            try await app.cache.set("foo", to: "baz")

            #expect(try await app.cache.get("foo", as: String.self) == "baz")
            #expect(try await CacheEntry.query(on: app.db).count() == 1)
        }
    }

    @Test func setNilRemovesValue() async throws {
        try await withCacheApp { app in
            try await app.cache.set("foo", to: "bar")
            try await app.cache.set("foo", to: String?.none)

            #expect(try await app.cache.get("foo", as: String.self) == nil)
            #expect(try await CacheEntry.query(on: app.db).count() == 0)
        }
    }

    @Test func setStoresExpiration() async throws {
        try await withCacheApp { app in
            let before = Date()
            try await app.cache.set("foo", to: "bar", expiresIn: .minutes(5))

            let entry = try #require(try await CacheEntry.query(on: app.db).filter(\.$key == "foo").first())
            let expiresAt = try #require(entry.expiresAt)
            #expect(expiresAt.timeIntervalSince(before) >= 299)
            #expect(expiresAt.timeIntervalSince(before) <= 301)
            #expect(try await app.cache.get("foo", as: String.self) == "bar")

            // Replacing without an expiry clears the previous one.
            try await app.cache.set("foo", to: "baz")
            let replaced = try #require(try await CacheEntry.query(on: app.db).filter(\.$key == "foo").first())
            #expect(replaced.expiresAt == nil)
        }
    }

    @Test func expiredValueIsRemovedOnRead() async throws {
        try await withCacheApp { app in
            try await CacheEntry(key: "foo", value: #""bar""#, expiresAt: Date().addingTimeInterval(-1))
                .create(on: app.db)

            #expect(try await app.cache.get("foo", as: String.self) == nil)
            #expect(try await CacheEntry.query(on: app.db).count() == 0)
        }
    }

    @Test func initKeepsProvidedID() {
        let id = UUID()
        #expect(CacheEntry(id: id, key: "foo", value: "bar").id == id)
    }

    @Test func concurrentSetsOfTheSameKeySucceed() async throws {
        try await withCacheApp { app in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<10 {
                    group.addTask { try await app.cache.set("foo", to: i) }
                }
                try await group.waitForAll()
            }

            #expect(try await CacheEntry.query(on: app.db).count() == 1)
            #expect(try await app.cache.get("foo", as: Int.self) != nil)
        }
    }

    /// Runs `test` against an app whose cache is backed by a freshly migrated in-memory SQLite database.
    private func withCacheApp(_ test: (Application) async throws -> Void) async throws {
        try await withApp(configure: { app in
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CacheEntry.migrations)
            app.caches.use(.fluent)
        }) { app in
            try await app.autoMigrate()
            try await test(app)
        }
    }
}
#endif
