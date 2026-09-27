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

final class PeerStoreEntry_Multiaddr: Model, @unchecked Sendable {
    public static let schema: String = "_fluent_peerstore_multiaddr"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "peer_id")
    public var peer: PeerStoreEntry

    @Field(key: "address")
    public var address: String

    public init() {}

    public init(id: UUID? = nil, peerID: PeerStoreEntry.IDValue, address: Multiaddr) {
        self.id = id
        self.$peer.id = peerID
        self.address = address.description
    }

    /// The stored address in canonical `/p2p/<peer>` form.
    ///
    /// Rows written before addresses were canonicalised may be missing the `/p2p` component.
    /// Returns `nil` if the stored string isn't a valid `Multiaddr`.
    func multiaddr(for peer: PeerID) -> Multiaddr? {
        guard let address = try? Multiaddr(self.address) else { return nil }
        return FluentPeerStore.canonicalAddress(address, for: peer) ?? address
    }
}
