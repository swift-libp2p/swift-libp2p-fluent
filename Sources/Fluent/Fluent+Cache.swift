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
//
//  Created by Vapor
//  Modified by swift-libp2p
//

public import FluentKit
import Foundation
public import LibP2P

extension Application.Caches {
    public var fluent: any Cache {
        self.fluent(nil)
    }

    public func fluent(_ db: DatabaseID?) -> any Cache {
        FluentCache(id: db, database: self.application.db(db))
    }
}

extension Application.Caches.Provider {
    public static var fluent: Self {
        .fluent(nil)
    }

    public static func fluent(_ db: DatabaseID?) -> Self {
        .init {
            $0.caches.use { $0.caches.fluent(db) }
        }
    }
}

private struct FluentCache: Cache {
    let id: DatabaseID?
    let database: any Database

    init(id: DatabaseID?, database: any Database) {
        self.id = id
        self.database = database
    }

    func get<T>(_ key: String, as type: T.Type) -> EventLoopFuture<T?>
    where T: Decodable & Libp2pSendableMetatype {
        let database = self.database
        return CacheEntry.query(on: database)
            .filter(\.$key == key)
            .first()
            .flatMap { entry -> EventLoopFuture<CacheEntry?> in
                // Delete expired entries.
                guard let entry, let expiresAt = entry.expiresAt, expiresAt <= Date() else {
                    return database.eventLoop.makeSucceededFuture(entry)
                }
                return entry.delete(on: database).map { nil }
            }
            .flatMapThrowing { entry -> T? in
                try entry.map { try JSONDecoder().decode(T.self, from: Data($0.value.utf8)) }
            }
    }

    func set(_ key: String, to value: (some Encodable)?) -> EventLoopFuture<Void> {
        if let value = value {
            do {
                let data = try JSONEncoder().encode(value)
                let entry = CacheEntry(
                    key: key,
                    value: String(decoding: data, as: UTF8.self)
                )
                return entry.create(on: self.database)
            } catch {
                return self.database.eventLoop.makeFailedFuture(error)
            }
        } else {
            return CacheEntry.query(on: self.database).filter(\.$key == key).delete()
        }
    }

    func `for`(_ request: Request) -> Self {
        .init(id: self.id, database: request.db(self.id))
    }
}

public final class CacheEntry: Model, @unchecked Sendable {
    public static let schema: String = "_fluent_cache"

    struct Create: Migration {
        func prepare(on database: any Database) -> EventLoopFuture<Void> {
            database.schema("_fluent_cache")
                .id()
                .field("key", .string, .required)
                .field("value", .string, .required)
                .unique(on: "key")
                .create()
        }

        func revert(on database: any Database) -> EventLoopFuture<Void> {
            database.schema("_fluent_cache").delete()
        }
    }

    /// Adds the `expires_at` column used to honour `set(_:to:expiresIn:)`.
    struct AddExpiration: Migration {
        func prepare(on database: any Database) -> EventLoopFuture<Void> {
            database.schema("_fluent_cache")
                .field("expires_at", .datetime)
                .update()
        }

        func revert(on database: any Database) -> EventLoopFuture<Void> {
            database.schema("_fluent_cache")
                .deleteField("expires_at")
                .update()
        }
    }

    /// Every migration the Fluent cache needs, in order.
    ///
    ///     app.migrations.add(CacheEntry.migrations)
    ///
    public static var migrations: [any Migration] {
        [Create(), AddExpiration()]
    }

    @available(*, deprecated, message: "Use `CacheEntry.migrations`, which also adds the `expires_at` column.")
    public static var migration: any Migration {
        Create()
    }

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "key")
    public var key: String

    @Field(key: "value")
    public var value: String

    /// When this entry expires, or `nil` if it never does.
    @OptionalField(key: "expires_at")
    public var expiresAt: Date?

    public init() {}

    public init(id: UUID? = nil, key: String, value: String, expiresAt: Date? = nil) {
        self.id = id
        self.key = key
        self.value = value
        self.expiresAt = expiresAt
    }
}
