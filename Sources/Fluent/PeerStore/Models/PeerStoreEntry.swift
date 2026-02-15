//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//
//
//  Created by swift-libp2p
//

import FluentKit
import Foundation
import LibP2P

final class PeerStoreEntry: Model, @unchecked Sendable {
    public static let schema: String = "_fluent_peerstore"

    struct Create: Migration {
        func prepare(on database: any Database) -> EventLoopFuture<Void> {
            database.schema("_fluent_peerstore")
                .id()
                .field("peer_id", .string, .required)
                .field("key_pair", .data)
                .unique(on: "peer_id")
                .create()
        }

        func revert(on database: any Database) -> EventLoopFuture<Void> {
            database.schema("_fluent_peerstore").delete()
        }
    }

    public static var migration: any Migration {
        Create()
    }

    @ID(key: .id)
    public var id: UUID?

    @Field(key: "peer_id")
    public var peer: String

    // Marshalled keypair
    @OptionalField(key: "key_pair")
    public var keypair: Data?

    @Children(for: \.$peer)
    var multiaddrs: [PeerStoreEntry_Multiaddr]

    @Children(for: \.$peer)
    var protocols: [PeerStoreEntry_Protocol]

    @Children(for: \.$peer)
    var records: [PeerStoreEntry_Record]

    @Children(for: \.$peer)
    var metadata: [PeerStoreEntry_Metadata]

    public init() {}

    public init(id: UUID? = nil, peerID: PeerID) {
        self.id = id
        self.peer = peerID.b58String
        self.keypair = try? Data(peerID.marshalPublicKey())
    }

    public var peerID: PeerID {
        get throws {
            if let keypair = self.keypair {
                return try PeerID(marshaledPublicKey: keypair)
            } else {
                return try PeerID(fromBytesID: .init(decoding: peer, as: .base58btc))
            }
        }
    }

    public func asPeerInfo(on db: any Database) async throws -> PeerInfo {
        let mas = try await self.$multiaddrs.get(on: db)
        let addresses = mas.compactMap { try? Multiaddr($0.address) }
        return try PeerInfo(peer: peerID, addresses: addresses)
    }

    public func asComprehensivePeer(on db: any Database) async throws -> ComprehensivePeer {
        async let mas = try? self.$multiaddrs.get(on: db)
        async let protos = try? self.$protocols.get(on: db)
        async let recs = try? self.$records.get(on: db)
        async let metas = try? self.$metadata.get(on: db)

        let results = await (mas, protos, recs, metas)

        // Prep our Multiaddrs
        let addresses = Set((results.0 ?? []).compactMap { try? Multiaddr($0.address) })

        // Prep our Protocols
        let protocols = Set((results.1 ?? []).compactMap { SemVerProtocol($0.protocol) })

        // Prep our Records
        let records = Set((results.2 ?? []).compactMap { try? PeerRecord(marshaledData: Data($0.record)) })

        // Prep our Metadata
        var metadataDictionary: [String: [UInt8]] = [:]
        for meta in (results.3 ?? []) {
            metadataDictionary[meta.key] = [UInt8](meta.value)
        }

        return try .init(
            id: self.peerID,
            addresses: addresses,
            protocols: protocols,
            metadata: metadataDictionary,
            records: records
        )
    }
}
