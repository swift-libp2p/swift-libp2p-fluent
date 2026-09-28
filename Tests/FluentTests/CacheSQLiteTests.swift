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
        let config: ((Application) async throws -> Void) = { app in
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CacheEntry.migrations)
            app.caches.use(.fluent)
        }
        try await withApp(configure: config) { app in
            try await app.autoMigrate()
            try await test(app)
        }
    }
}

// MARK: - v1 -> v2 migration tests

extension CacheSQLiteTests {

    @Test func v1EntriesMigrateToExpirationSchema() async throws {
        try await withV1CacheApp { app in
            // The v2 model reads `expires_at`, so a v1 table can't be read until it's migrated.
            await #expect(throws: (any Error).self) {
                try await app.cache.get("greeting", as: String.self)
            }

            try await Self.migrateToV2(app)

            // Existing entries survive, decode as before, and never expire.
            #expect(try await CacheEntry.query(on: app.db).count() == 2)
            #expect(try await app.cache.get("greeting", as: String.self) == "hello")
            #expect(try await app.cache.get("profile", as: Profile.self) == Profile.mock)
            let entries = try await CacheEntry.query(on: app.db).all()
            #expect(entries.allSatisfy { $0.expiresAt == nil })

            // A migrated entry can be given an expiry, and is updated in place rather than duplicated.
            let greetingID = try #require(entries.first { $0.key == "greeting" }?.id)
            try await app.cache.set("greeting", to: "hi", expiresIn: .minutes(1))
            let greeting = try #require(try await CacheEntry.query(on: app.db).filter(\.$key == "greeting").first())
            #expect(greeting.id == greetingID)
            #expect(greeting.expiresAt != nil)
            #expect(try await app.cache.get("greeting", as: String.self) == "hi")

            // Once expired, a migrated entry is removed on read.
            let profile = try #require(try await CacheEntry.query(on: app.db).filter(\.$key == "profile").first())
            profile.expiresAt = Date().addingTimeInterval(-1)
            try await profile.update(on: app.db)
            #expect(try await app.cache.get("profile", as: Profile.self) == nil)
            #expect(try await CacheEntry.query(on: app.db).count() == 1)
        }
    }

    @Test func v2MigrationRevertsToV1Schema() async throws {
        try await withV1CacheApp { app in
            try await Self.migrateToV2(app)
            #expect(try await Self.cacheColumns(app).contains("expires_at"))

            // Revert only the `AddExpiration` batch.
            try await app.migrator.revertLastBatch().get()

            #expect(try await Self.cacheColumns(app) == ["id", "key", "value"])
            // The v1 rows are untouched.
            let sql = try #require(app.db as? any SQLDatabase)
            let rows = try await sql.select().column("key").from(CacheEntry.schema).orderBy("key").all()
            #expect(try rows.map { try $0.decode(column: "key", as: String.self) } == ["greeting", "profile"])
        }
    }

    // MARK: Helpers

    struct Profile: Codable, Equatable {
        var name: String
        var age: Int

        static let mock = Profile(name: "Alice", age: 42)
    }

    /// Runs `test` against an in-memory SQLite database that only has the v1 cache schema
    /// (`CacheEntry.Create`), seeded with two entries written the way v1 stored them.
    private func withV1CacheApp(_ test: (Application) async throws -> Void) async throws {
        let config: ((Application) async throws -> Void) = { app in
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(try #require(CacheEntry.migrations.first))
            app.caches.use(.fluent)
        }
        try await withApp(configure: config) { app in
            try await app.autoMigrate()
            #expect(try await Self.cacheColumns(app) == ["id", "key", "value"])

            // Insert with raw SQL, the current model would also try to write `expires_at`.
            let sql = try #require(app.db as? any SQLDatabase)
            let profile = String(decoding: try JSONEncoder().encode(Profile.mock), as: UTF8.self)
            try await sql.insert(into: CacheEntry.schema)
                .columns("id", "key", "value")
                .values(SQLBind(UUID()), SQLBind("greeting"), SQLBind(#""hello""#))
                .values(SQLBind(UUID()), SQLBind("profile"), SQLBind(profile))
                .run()

            try await test(app)
        }
    }

    /// Registers the migrations added after v1 and runs autoMigrate.
    private static func migrateToV2(_ app: Application) async throws {
        app.migrations.add(Array(CacheEntry.migrations.dropFirst()))
        try await app.autoMigrate()
    }

    /// The column names of the cache table, in schema order.
    private static func cacheColumns(_ app: Application) async throws -> [String] {
        let sql = try #require(app.db as? any SQLDatabase)
        return try await sql.raw("PRAGMA table_info(\(ident: CacheEntry.schema))").all()
            .map { try $0.decode(column: "name", as: String.self) }
    }
}

#endif
