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

final class PeerStoreEntry_Record: Model, @unchecked Sendable {
    public static let schema: String = "_fluent_peerstore_records"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "peer_id")
    public var peer: PeerStoreEntry

    @Field(key: "sequence")
    public var sequence: Int64

    /// The marshalled, signed `PeerRecord` envelope.
    @Field(key: "record")
    public var record: Data

    public init() {}

    public init(id: UUID? = nil, peerID: PeerStoreEntry.IDValue, record: PeerRecord) throws {
        self.id = id
        self.$peer.id = peerID
        self.sequence = Int64(bitPattern: record.sequenceNumber)
        self.record = Data(try record.marshal())
    }

    /// The record's sequence number. It's stored as the `Int64` bit pattern of the `UInt64` value, so
    /// sort on this rather than the raw column.
    var sequenceNumber: UInt64 {
        UInt64(bitPattern: self.sequence)
    }

    /// Decodes the stored, signed `PeerRecord`.
    func peerRecord() throws -> PeerRecord {
        try PeerRecord(marshaledData: self.record)
    }
}
