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

import FluentKit
import Foundation
import LibP2P
import SQLKit

extension FluentPeerStore {
    /// Creates the PeerStore tables.
    ///
    /// - Note: Any tables from the pre-0.1.0 schema are dropped along with their entries.
    struct CreateSchema: AsyncMigration {
        /// Every table, children before their parent (the order they must be dropped in).
        static let tables = [
            PeerStoreEntry_Record.schema,
            PeerStoreEntry_Multiaddr.schema,
            PeerStoreEntry_Protocol.schema,
            PeerStoreEntry_Metadata.schema,
            PeerStoreEntry.schema,
        ]

        /// Non-unique indexes for the lookups that don't start from a peer, peers by protocol and peers
        /// by address. The composite unique constraints lead with `peer_id`, so they can't serve these.
        static let indexes: [(name: String, table: String, column: String)] = [
            ("_fluent_peerstore_protocols_protocol_idx", PeerStoreEntry_Protocol.schema, "protocol"),
            ("_fluent_peerstore_multiaddr_address_idx", PeerStoreEntry_Multiaddr.schema, "address"),
        ]

        func prepare(on database: any Database) async throws {
            try await Self.dropTables(on: database)

            try await database.schema(PeerStoreEntry.schema)
                .id()
                .field("peer_id", .string, .required)
                .field("key_pair", .data)
                .unique(on: "peer_id")
                .create()

            try await database.schema(PeerStoreEntry_Multiaddr.schema)
                .id()
                .field("peer_id", .uuid, .required, Self.parentReference)
                .field("address", .string, .required)
                .unique(on: "peer_id", "address")
                .create()

            try await database.schema(PeerStoreEntry_Protocol.schema)
                .id()
                .field("peer_id", .uuid, .required, Self.parentReference)
                .field("protocol", .string, .required)
                .unique(on: "peer_id", "protocol")
                .create()

            try await database.schema(PeerStoreEntry_Record.schema)
                .id()
                .field("peer_id", .uuid, .required, Self.parentReference)
                .field("sequence", .int64, .required)
                .field("record", .data, .required)
                .unique(on: "peer_id", "sequence")
                .create()

            try await database.schema(PeerStoreEntry_Metadata.schema)
                .id()
                .field("peer_id", .uuid, .required, Self.parentReference)
                .field("key", .string, .required)
                .field("value", .data, .required)
                .unique(on: "peer_id", "key")
                .create()

            // FluentKit's schema builder can only create unique constraints, so these use SQLKit.
            // Other databases (e.g. MongoDB) go without.
            if let sql = database as? any SQLDatabase {
                for index in Self.indexes {
                    try await sql.create(index: index.name).on(index.table).column(index.column).run()
                }
            }
        }

        func revert(on database: any Database) async throws {
            try await Self.dropTables(on: database)
        }

        private static var parentReference: DatabaseSchema.FieldConstraint {
            .references(PeerStoreEntry.schema, "id", onDelete: .cascade, onUpdate: .cascade)
        }

        /// Drops every PeerStore table along with their indexes.
        private static func dropTables(on database: any Database) async throws {
            for table in Self.tables {
                if let sql = database as? any SQLDatabase {
                    try await sql.drop(table: table).ifExists().run()
                } else {
                    // No "if exists" outside SQL, and on a fresh install there's nothing to drop.
                    try? await database.schema(table).delete()
                }
            }
        }
    }
}
