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
//  Created by swift-libp2p
//

import FluentKit
import Foundation
import LibP2P

final class PeerStoreEntry: Model, @unchecked Sendable {
    public static let schema: String = "_fluent_peerstore"

    @ID(key: .id)
    public var id: UUID?

    /// The peer's canonical (`Qm…`) b58 id. See ``canonicalID(for:)-(PeerID)``.
    @Field(key: "peer_id")
    public var peer: String

    /// The peer's marshalled public key, or `nil` for a peer we only know by id.
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
        self.peer = Self.canonicalID(for: peerID)
        self.keypair = try? Data(peerID.marshalPublicKey())
    }

    /// The value stored in `peer_id`, the peer's SHA-256 (`Qm…`) b58 id.
    ///
    /// `PeerID` treats an embedded-key id (`12D3Koo…`) and its SHA-256 equivalent as the same peer,
    /// so keying the table on this keeps one row per peer no matter which type we encounter first.
    /// An embedded pub key id is stored in `key_pair`.
    static func canonicalID(for peer: PeerID) -> String {
        (try? peer.traditionalB58String()) ?? peer.b58String
    }

    /// Resolves a b58 or CID string to its ``canonicalID(for:)``, or `nil` if it can't be parsed.
    static func canonicalID(for string: String) -> String? {
        (try? PeerID(cid: string)).map(Self.canonicalID(for:))
    }

    /// The stored `PeerID`, rebuilt from the public key when there is one (so Ed25519 peers come
    /// back in their `12D3Koo…` form), otherwise from the canonical id.
    public var peerID: PeerID {
        get throws {
            if let keypair = self.keypair {
                return try PeerID(marshaledPublicKey: keypair)
            } else {
                return try PeerID(fromBytesID: BaseEncoding.decode(peer, as: .base58btc))
            }
        }
    }

    /// Builds a `PeerInfo` from this entry.
    ///
    /// - Important: `multiaddrs` must be eager loaded (`.with(\.$multiaddrs)`).
    func makePeerInfo() throws -> PeerInfo {
        let peerID = try self.peerID
        return PeerInfo(
            peer: peerID,
            addresses: (self.$multiaddrs.value ?? []).compactMap { $0.multiaddr(for: peerID) }.uniqued()
        )
    }

    /// Builds a `ComprehensivePeer` from this entry.
    ///
    /// - Important: Every child relation must be eager loaded. Rows that can't be decoded are skipped.
    func makeComprehensivePeer() throws -> ComprehensivePeer {
        let peerID = try self.peerID
        var metadata: Metadata = [:]
        for meta in self.$metadata.value ?? [] {
            metadata[meta.key] = [UInt8](meta.value)
        }
        return ComprehensivePeer(
            id: peerID,
            addresses: Set((self.$multiaddrs.value ?? []).compactMap { $0.multiaddr(for: peerID) }),
            protocols: Set((self.$protocols.value ?? []).compactMap { SemVerProtocol($0.protocol) }),
            metadata: metadata,
            records: Set((self.$records.value ?? []).compactMap { try? $0.peerRecord() })
        )
    }
}

extension Sequence where Element: Hashable {
    /// The elements of this sequence with duplicates removed, keeping the first occurrence.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return self.filter { seen.insert($0).inserted }
    }
}
