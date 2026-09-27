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

final class PeerStoreEntry_Metadata: Model, @unchecked Sendable {
    public static let schema: String = "_fluent_peerstore_metadata"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "peer_id")
    public var peer: PeerStoreEntry

    @Field(key: "key")
    public var key: String

    /// The exact bytes of the metadata value.
    @Field(key: "value")
    public var value: Data

    public init() {}

    public init(id: UUID? = nil, peerID: PeerStoreEntry.IDValue, key: String, value: [UInt8]) {
        self.id = id
        self.$peer.id = peerID
        self.key = key
        self.value = Data(value)
    }
}
