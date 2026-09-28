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
import FluentSQLiteDriver
import Foundation
import LibP2P
import LibP2PCrypto
import LibP2PTesting
import Testing

@testable import Fluent

/// Fluent PeerStore tests against an in-memory SQLite database.
///
/// The first sections mirror swift-libp2p's `BasicInMemoryPeerStore` tests.
/// The later sections cover database specific tests.
///
/// Run with `swift test --traits SQLiteTests`.
@Suite("PeerStore SQLite Tests")
struct PeerStoreSQLiteTests {

    // MARK: - Address Book

    @Test("A mismatched address doesn't drop the rest of the batch")
    func mismatchedAddressSkipsOnlyItself() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            let other = try Self.randomPeer()
            try await store.add(key: peer)

            try await store.add(
                addresses: [
                    Multiaddr("/ip4/127.0.0.1/tcp/4001"),
                    Multiaddr("/ip4/127.0.0.1/tcp/4002/p2p/\(other.b58String)"),
                    Multiaddr("/ip4/127.0.0.1/tcp/4003"),
                ],
                toPeer: peer
            )

            let addresses = try await store.getAddresses(forPeer: peer)
            #expect(addresses.count == 2)
            #expect(addresses.allSatisfy { (try? $0.getPeerID()) == peer })
        }
    }

    @Test("Bare and /p2p-qualified versions of the same address collapse")
    func addressesAreCanonicalised() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)

            let bare = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
            let qualified = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peer.b58String)")

            try await store.add(address: bare, toPeer: peer)
            try await store.add(address: qualified, toPeer: peer)

            let addresses = try await store.getAddresses(forPeer: peer)
            #expect(addresses.count == 1)
            #expect(addresses.first == qualified)
        }
    }

    @Test("Removing either spelling of an address removes it")
    func removeAddressAcceptsEitherSpelling() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(
                addresses: [Multiaddr("/ip4/127.0.0.1/tcp/4001"), Multiaddr("/ip4/127.0.0.1/tcp/4002")],
                toPeer: peer
            )

            try await store.remove(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), fromPeer: peer)
            try await store.remove(address: Multiaddr("/ip4/127.0.0.1/tcp/4002/p2p/\(peer.b58String)"), fromPeer: peer)

            #expect(try await store.getAddresses(forPeer: peer).isEmpty)
        }
    }

    @Test("byAddress lookups match both the bare and the qualified form")
    func byAddressLookupMatchesEitherSpelling() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: peer)

            let bare = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
            let qualified = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peer.b58String)")

            #expect(try await store.getPeerID(byAddress: bare) == peer)
            #expect(try await store.getPeerID(byAddress: qualified) == peer)
            #expect(try await store.getPeer(byAddress: bare) == peer.b58String)
            #expect(try await store.getPeerInfo(byAddress: qualified).peer == peer)
        }
    }

    @Test("A byAddress lookup doesn't match a longer port with the same prefix")
    func byAddressLookupIsExact() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/40010"), toPeer: peer)

            await #expect(throws: FluentPeerStore.Error.peerNotFound) {
                _ = try await store.getPeerID(byAddress: Multiaddr("/ip4/127.0.0.1/tcp/4001"))
            }
        }
    }

    @Test("An unknown address reports peerNotFound")
    func unknownAddressThrows() async throws {
        try await Self.withStore { store in
            await #expect(throws: FluentPeerStore.Error.peerNotFound) {
                _ = try await store.getPeerID(byAddress: Multiaddr("/ip4/10.0.0.1/tcp/9999"))
            }
            // An embedded peer id isn't enough, the peer has to be stored.
            let unknown = try Self.randomPeer()
            await #expect(throws: FluentPeerStore.Error.peerNotFound) {
                _ = try await store.getPeer(byAddress: Multiaddr("/ip4/10.0.0.1/tcp/9999/p2p/\(unknown.b58String)"))
            }
        }
    }

    // MARK: - Key Book

    @Test("Embedded-key and SHA-256 spellings resolve to one entry")
    func canonicalPeerIDKeying() async throws {
        try await Self.withStore { store in
            let embedded = try Self.randomPeer()
            let traditional = try PeerID(cid: try embedded.traditionalB58String())
            try #require(embedded == traditional)
            try #require(embedded.b58String != traditional.b58String)

            try await store.add(key: embedded)
            try await store.add(key: traditional)
            #expect(try await store.count() == 1)

            try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: traditional)
            try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: embedded)
            #expect(try await store.getAddresses(forPeer: embedded).count == 1)

            // Both spellings resolve through the string-keyed lookup too.
            #expect(try await store.getKey(forPeer: embedded.b58String) == embedded)
            #expect(try await store.getKey(forPeer: traditional.b58String) == embedded)
        }
    }

    @Test("add(key:) upgrades to the richer PeerID and never downgrades")
    func keyUpgradesOnly() async throws {
        try await Self.withStore { store in
            let full = try Self.randomPeer()
            let idOnly = try PeerID(cid: try full.traditionalB58String())
            try #require(idOnly.type == .idOnly)

            // ID Only first, then Public Key -> upgrade.
            try await store.add(key: idOnly)
            try await store.add(key: full)
            #expect(try await store.getKey(forPeer: full.b58String).type == .isPublic)
            #expect(try await store.count() == 1)

            // Public Key first, then ID Only -> no downgrade.
            try await store.removeAllKeys()
            try await store.add(key: full)
            try await store.add(key: idOnly)
            #expect(try await store.getKey(forPeer: full.b58String).type == .isPublic)
        }
    }

    @Test("Re-adding a key preserves the peer's existing state")
    func reAddingKeyPreservesState() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(protocol: Self.echo, toPeer: peer)
            try await store.add(key: peer)

            #expect(try await store.getProtocols(forPeer: peer) == [Self.echo])
            #expect(try await store.count() == 1)
        }
    }

    @Test("Removing a key removes everything stored for the peer")
    func removeKeyRemovesChildren() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: peer)
            try await store.add(protocol: Self.echo, toPeer: peer)
            try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 1))

            try await store.remove(key: peer)

            #expect(try await store.count() == 0)
            #expect(try await PeerStoreEntry_Multiaddr.query(on: store.testDatabase).count() == 0)
            #expect(try await PeerStoreEntry_Protocol.query(on: store.testDatabase).count() == 0)
            #expect(try await PeerStoreEntry_Record.query(on: store.testDatabase).count() == 0)
            #expect(try await PeerStoreEntry_Metadata.query(on: store.testDatabase).count() == 0)
        }
    }

    @Test("Operations on an unknown peer report peerNotFound")
    func unknownPeerThrows() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            await #expect(throws: FluentPeerStore.Error.peerNotFound) {
                try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: peer)
            }
            await #expect(throws: FluentPeerStore.Error.peerNotFound) {
                try await store.add(metaKey: "k", data: [1], toPeer: peer)
            }
            await #expect(throws: FluentPeerStore.Error.peerNotFound) {
                _ = try await store.getKey(forPeer: peer.b58String)
            }
            // Removing an unknown peer is fine.
            try await store.remove(key: peer)
        }
    }

    // MARK: - Protocol Book

    @Test("getPeers(matchingProtocol:) honours SemVer ranges, exact matching does not")
    func protocolMatchingSemantics() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(protocol: Self.echo, toPeer: peer)

            let ranged = SemVerProtocol(proto: "echo", version: .upToNextMinor(.init(major: 1, minor: 0, patch: 0)))

            // Exact set membership can't see the range query...
            #expect(try await store.getPeers(supportingProtocol: ranged).isEmpty)
            // ...but `matches` semantics can.
            #expect(try await store.getPeers(matchingProtocol: ranged) == [peer.b58String])
            #expect(try await store.getPeerIDs(matchingProtocol: ranged) == [peer])

            // And the PeerID-typed exact query is reachable.
            #expect(try await store.getPeerIDs(supportingProtocol: Self.echo) == [peer])
        }
    }

    @Test("getPeers(matchingProtocol:) ignores near-miss protocols that share a prefix")
    func protocolMatchingNearMisses() async throws {
        try await Self.withStore { store in
            let match = try Self.randomPeer()
            let unversioned = try Self.randomPeer()
            let nearMisses = try (0..<5).map { _ in try Self.randomPeer() }
            for peer in [match, unversioned] + nearMisses {
                try await store.add(key: peer)
            }

            try await store.add(protocol: SemVerProtocol("/echo/1.4.2")!, toPeer: match)
            try await store.add(protocol: SemVerProtocol("/echo")!, toPeer: unversioned)
            for (peer, proto) in zip(nearMisses, ["/echo/10.0.0", "/echo/2.0.0", "/echo/sub/1.0.0", "/echoes/1.0.0", "/ECHO/1.0.0"]) {
                try await store.add(protocol: SemVerProtocol(proto)!, toPeer: peer)
            }

            let ranged = SemVerProtocol(proto: "echo", version: .upToNextMajor(.init(major: 1, minor: 0, patch: 0)))
            #expect(try await store.getPeerIDs(matchingProtocol: ranged) == [match])
            #expect(try await store.getPeerIDs(matchingProtocol: SemVerProtocol("/echo")!) == [unversioned])
        }
    }

    @Test("Protocols are de-duplicated and can be removed in bulk")
    func protocolsDeduplicateAndRemove() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            let ping = try #require(SemVerProtocol("/ipfs/ping/1.0.0"))
            try await store.add(key: peer)
            try await store.add(protocols: [Self.echo, ping, Self.echo], toPeer: peer)
            try await store.add(protocols: [Self.echo], toPeer: peer)
            #expect(Set(try await store.getProtocols(forPeer: peer)) == [Self.echo, ping])

            try await store.remove(protocols: [], fromPeer: peer)
            try await store.remove(protocols: [Self.echo, ping], fromPeer: peer)
            #expect(try await store.getProtocols(forPeer: peer).isEmpty)
        }
    }

    // MARK: - Record Book

    @Test("add(record:) upserts the peer and merges its addresses")
    func recordUpsertsPeerAndMergesAddresses() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            let record = PeerRecord(
                peerID: peer,
                multiaddrs: [try Multiaddr("/ip4/127.0.0.1/tcp/4001")],
                sequenceNumber: 1
            )

            try await store.add(record: record)

            #expect(try await store.count() == 1)
            #expect(try await store.getRecords(forPeer: peer).count == 1)
            #expect(try await store.getDiscovered(forPeer: peer) != nil)
            let addresses = try await store.getAddresses(forPeer: peer)
            #expect(addresses.count == 1)
            #expect((try? addresses.first?.getPeerID()) == peer)
        }
    }

    @Test("Records are capped at maxRecordsPerPeer, keeping the most recent")
    func recordsAreCapped() async throws {
        try await Self.withStore(configuration: .init(maxRecordsPerPeer: 2)) { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)

            for seq in UInt64(1)...5 {
                try await store.add(
                    record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: seq)
                )
            }

            let records = try await store.getRecords(forPeer: peer)
            #expect(records.count == 2)
            #expect(Set(records.map(\.sequenceNumber)) == [4, 5])
            #expect(try await store.getMostRecentRecord(forPeer: peer)?.sequenceNumber == 5)
        }
    }

    @Test("Sequence numbers above Int64.max sort as the most recent")
    func largeSequenceNumbersSortCorrectly() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 1))
            try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: .max))

            #expect(try await store.getMostRecentRecord(forPeer: peer)?.sequenceNumber == .max)
            try await store.trimRecords(forPeer: peer)
            #expect(try await store.getRecords(forPeer: peer).map(\.sequenceNumber) == [.max])
        }
    }

    @Test("Duplicate sequence numbers are ignored")
    func duplicateRecordsIgnored() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            let record = PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 7)
            try await store.add(record: record)
            try await store.add(record: record)
            #expect(try await store.getRecords(forPeer: peer).count == 1)
        }
    }

    @Test("trimAllRecords applies to every peer")
    func trimAllRecordsVisitsEveryPeer() async throws {
        try await Self.withStore { store in
            var withRecords: [PeerID] = []
            for _ in 0..<4 {
                let bare = try Self.randomPeer()
                try await store.add(key: bare)

                let holder = try Self.randomPeer()
                try await store.add(key: holder)
                for seq in UInt64(1)...3 {
                    try await store.add(
                        record: PeerRecord(peerID: holder, multiaddrs: [], sequenceNumber: seq)
                    )
                }
                withRecords.append(holder)
            }

            _ = try await store.trimAllRecords().get()

            for peer in withRecords {
                let records = try await store.getRecords(forPeer: peer)
                #expect(records.count == 1, "records were not trimmed for \(peer.b58String)")
                #expect(records.first?.sequenceNumber == 3)
            }
        }
    }

    // MARK: - Metadata

    @Test("Typed metadata accessors round-trip through the byte API")
    func typedMetadataRoundTrips() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)

            let handshake = Date(timeIntervalSince1970: 1_700_000_000)
            try await store.setLastHandshake(handshake, forPeer: peer)
            let readBack = try await store.getLastHandshake(forPeer: peer)
            #expect(readBack?.timeIntervalSince1970 == handshake.timeIntervalSince1970)

            let raw = try await store.getMetadata(forPeer: peer)
            #expect(raw[MetadataBook.Keys.lastHandshake.rawValue] != nil)

            var latency = MetadataBook.LatencyMetadata()
            latency.newStreamLatencyValue(2_000)
            try await store.setLatency(latency, forPeer: peer)
            #expect(try await store.getLatency(forPeer: peer)?.streamLatency == 2_000)

            #expect(try await store.getPrunability(forPeer: peer) == .prunable)
            try await store.setPrunability(.necessary, forPeer: peer)
            #expect(try await store.getPrunability(forPeer: peer) == .necessary)

            let observedAddress = try Multiaddr("/ip4/1.1.1.1/tcp/4001")
            try await store.setObservedAddress(observedAddress, forPeer: peer)
            #expect(try await store.getObservedAddress(forPeer: peer) == observedAddress)

            let agentVersion = "swift-libp2p/0.4.0"
            try await store.setAgentVersion(agentVersion, forPeer: peer)
            #expect(try await store.getAgentVersion(forPeer: peer) == agentVersion)
        }
    }

    /// v1 stored metadata with a plain `create` on a `unique(peer_id, key)` table, so every write after
    /// the first (the last handshake on every Identify, the latency on every ping) failed.
    @Test("Metadata keys can be written repeatedly")
    func metadataWritesAreUpserts() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)

            // `add(key:)` already wrote `discovered`, so this is a second write too.
            try await store.setDiscovered(Date(timeIntervalSince1970: 1), forPeer: peer)
            for seconds in [10.0, 20.0, 30.0] {
                try await store.setLastHandshake(Date(timeIntervalSince1970: seconds), forPeer: peer)
            }
            var latency = MetadataBook.LatencyMetadata()
            let pings: [UInt64] = [100, 200]
            for ping in pings {
                latency.newStreamLatencyValue(ping)
                try await store.setLatency(latency, forPeer: peer)
            }

            #expect(try await store.getDiscovered(forPeer: peer) == Date(timeIntervalSince1970: 1))
            #expect(try await store.getLastHandshake(forPeer: peer) == Date(timeIntervalSince1970: 30))
            #expect(try await store.getLatency(forPeer: peer)?.streamLatency == latency.streamLatency)
            #expect(try await PeerStoreEntry_Metadata.query(on: store.testDatabase).count() == 3)
        }
    }

    @Test("Binary metadata round-trips losslessly")
    func binaryMetadataRoundTrips() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)

            let bytes: [UInt8] = [0xFF, 0x00, 0xFE, 0x80, 0xC3]
            try await store.add(metaKey: "binary", data: bytes, toPeer: peer)
            #expect(try await store.getMetadata(forPeer: peer)["binary"] == bytes)

            try await store.remove(metaKey: "binary", fromPeer: peer)
            #expect(try await store.getMetadata(forPeer: peer)["binary"] == nil)
        }
    }

    // MARK: - Ordering

    /// Identify issues its writes without waiting for each other. The store has to apply them in call
    /// order, so the key lands before the writes that depend on it.
    @Test("Back-to-back writes issued without awaiting all apply, in order")
    func identifyStyleWritesAreOrdered() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
            let record = PeerRecord(peerID: peer, multiaddrs: [try Multiaddr("/ip4/127.0.0.1/tcp/4002")], sequenceNumber: 1)

            let writes: [EventLoopFuture<Void>] = [
                store.add(key: peer, on: nil),
                store.add(addresses: [address], toPeer: peer, on: nil),
                store.add(protocols: [Self.echo], toPeer: peer, on: nil),
                store.add(record: record, on: nil),
                store.setAgentVersion("swift-libp2p/0.4.0", forPeer: peer, on: nil),
                store.setLastHandshake(Date(), forPeer: peer, on: nil),
                store.setLastHandshake(Date(), forPeer: peer, on: nil),
            ]
            for write in writes { try await write.get() }

            #expect(try await store.count() == 1)
            #expect(try await store.getAddresses(forPeer: peer).count == 2)
            #expect(try await store.getProtocols(forPeer: peer) == [Self.echo])
            #expect(try await store.getRecords(forPeer: peer).count == 1)
            #expect(try await store.getAgentVersion(forPeer: peer) == "swift-libp2p/0.4.0")
            #expect(try await store.getLastHandshake(forPeer: peer) != nil)
        }
    }

    @Test("Futures complete on the requested event loop")
    func futuresCompleteOnRequestedLoop() async throws {
        try await Self.withStore { store in
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let peer = try Self.randomPeer()
            let key = try await store.add(key: peer, on: loop)
                .flatMap { store.getKey(forPeer: peer.b58String, on: loop) }
                .always { _ in #expect(loop.inEventLoop) }
                .get()
            #expect(key == peer)
        }
    }

    // MARK: - Pruning

    @Test("Stale pruning falls back to the discovery timestamp")
    func stalePruningUsesDiscoveryFallback() async throws {
        try await Self.withStore { store in
            let fresh = try Self.randomPeer()
            let stale = try Self.randomPeer()
            try await store.add(key: fresh)
            try await store.add(key: stale)
            try await store.setLastHandshake(Date(timeIntervalSince1970: 0), forPeer: stale)

            #expect(try await store.prunePeers(olderThan: .seconds(30)).get() == 1)

            #expect(try await store.count() == 1)
            #expect(try await store.getKey(forPeer: fresh.b58String) == fresh)
        }
    }

    @Test("Necessary peers are never pruned")
    func necessaryPeersSurvivePruning() async throws {
        try await Self.withStore { store in
            let keep = try Self.randomPeer()
            let drop = try Self.randomPeer()
            for peer in [keep, drop] {
                try await store.add(key: peer)
                try await store.setLastHandshake(Date(timeIntervalSince1970: 0), forPeer: peer)
            }
            try await store.setPrunability(.necessary, forPeer: keep)

            _ = try await store.prunePeers(olderThan: .seconds(30)).get()

            #expect(try await store.count() == 1)
            #expect(try await store.getKey(forPeer: keep.b58String) == keep)
        }
    }

    @Test("Capacity pruning evicts the oldest prunable peers first")
    func capacityPruningEvictsOldestPrunable() async throws {
        try await Self.withStore(configuration: .init(maxPeers: 4, prunePercentWhenFull: 0.5)) { store in
            var peers: [PeerID] = []
            for index in 0..<4 {
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                try await store.setDiscovered(Date(timeIntervalSince1970: Double(index + 1)), forPeer: peer)
                peers.append(peer)
            }
            // The oldest peer is necessary, so the next two oldest go instead.
            try await store.setPrunability(.necessary, forPeer: peers[0])

            // 5 peers, capacity 4, prune 50% of capacity => 2 evicted.
            try await store.add(key: try Self.randomPeer())

            #expect(try await store.count() == 3)
            let remaining = Set(try await store.getAllPeerIDs())
            #expect(remaining.contains(peers[0]))
            #expect(!remaining.contains(peers[1]))
            #expect(!remaining.contains(peers[2]))
            #expect(remaining.contains(peers[3]))
        }
    }

    @Test("Capacity pruning handles peers with unknown discovery dates")
    func capacityPruningWithUnknownDiscoveryDates() async throws {
        try await Self.withStore(configuration: .init(maxPeers: 4, prunePercentWhenFull: 0.5)) { store in
            for index in 0..<5 {
                let peer = try Self.randomPeer()
                try await store.add(key: peer)
                // Half the peers lose their discovery timestamp entirely.
                if index.isMultiple(of: 2) {
                    try await store.remove(metaKey: MetadataBook.Keys.discovered, fromPeer: peer)
                }
            }
            #expect(try await store.count() == 3)
        }
    }

    @Test("Capacity pruning leaves record history alone")
    func capacityPruningPreservesRecords() async throws {
        try await Self.withStore(configuration: .init(maxPeers: 3, maxRecordsPerPeer: 3)) { store in
            let keeper = try Self.randomPeer()
            try await store.add(key: keeper)
            try await store.setPrunability(.necessary, forPeer: keeper)
            for seq in UInt64(1)...3 {
                try await store.add(
                    record: PeerRecord(peerID: keeper, multiaddrs: [], sequenceNumber: seq)
                )
            }

            for _ in 0..<5 { try await store.add(key: try Self.randomPeer()) }

            #expect(try await store.getRecords(forPeer: keeper).count == 3)
        }
    }

    // MARK: - Snapshots

    @Test("all() returns every peer with its state, as detached copies")
    func allReturnsSnapshots() async throws {
        try await Self.withStore { store in
            let peer = try Self.randomPeer()
            try await store.add(key: peer)
            try await store.add(address: Multiaddr("/ip4/127.0.0.1/tcp/4001"), toPeer: peer)
            try await store.add(protocol: Self.echo, toPeer: peer)
            try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 1))

            let snapshots = try await store.all()
            let snapshot = try #require(snapshots.first)
            #expect(snapshots.count == 1)
            #expect(snapshot.id == peer)
            #expect(snapshot.addresses.count == 1)
            #expect(snapshot.protocols == [Self.echo])
            #expect(snapshot.records.count == 1)
            #expect(snapshot.metadata[MetadataBook.Keys.discovered.rawValue] != nil)

            snapshot.insert(address: try Multiaddr("/ip4/10.0.0.1/tcp/9999"))
            #expect(try await store.getAddresses(forPeer: peer).count == 1)
        }
    }

    // MARK: - Protocol Conformance

    /// A conformer that fails to implement a requirement silently adopts `LibP2PCore`'s
    /// `on: EventLoop? = nil` shim as its witness, and the forwarding call recurses forever.
    @Test("Every PeerStore member is reachable through the protocol", .timeLimit(.minutes(1)))
    func everyMemberIsReachable() async throws {
        try await Self.withStore { concrete in
            let store: any PeerStore = concrete
            let peer = try Self.randomPeer()
            let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

            try await store.add(key: peer)
            try await store.add(peerInfo: PeerInfo(peer: peer, addresses: [address]))
            try await store.add(address: address, toPeer: peer)
            try await store.add(addresses: [address], toPeer: peer)
            try await store.add(protocol: Self.echo, toPeer: peer)
            try await store.add(protocols: [Self.echo], toPeer: peer)
            try await store.add(metaKey: "k", data: [1], toPeer: peer)
            try await store.add(metaKey: .agentVersion, data: [1], toPeer: peer)
            try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 1))

            _ = try await store.all()
            _ = try await store.count()
            _ = try await store.getAllPeerIDs()
            _ = try await store.getAllPeerInfos()
            _ = try await store.getKey(forPeer: peer.b58String)
            _ = try await store.getAddresses(forPeer: peer)
            _ = try await store.getPeer(byAddress: address)
            _ = try await store.getPeerID(byAddress: address)
            _ = try await store.getPeerInfo(byAddress: address)
            _ = try await store.getPeerInfo(byID: peer.b58String)
            _ = try await store.getProtocols(forPeer: peer)
            _ = try await store.getPeers(supportingProtocol: Self.echo)
            _ = try await store.getPeerIDs(supportingProtocol: Self.echo)
            _ = try await store.getPeers(matchingProtocol: Self.echo)
            _ = try await store.getPeerIDs(matchingProtocol: Self.echo)
            _ = try await store.getMetadata(forPeer: peer)
            _ = try await store.getRecords(forPeer: peer)
            _ = try await store.getMostRecentRecord(forPeer: peer)
            store.dump(peer: peer)
            store.dumpAll()

            try await store.trimRecords(forPeer: peer)
            try await store.removeRecords(forPeer: peer)
            try await store.remove(metaKey: "k", fromPeer: peer)
            try await store.removeAllMetadata(forPeer: peer)
            try await store.remove(protocol: Self.echo, fromPeer: peer)
            try await store.remove(protocols: [Self.echo], fromPeer: peer)
            try await store.removeAllProtocols(forPeer: peer)
            try await store.remove(address: address, fromPeer: peer)
            try await store.removeAllAddresses(forPeer: peer)
            try await store.remove(key: peer)
            try await store.removeAllKeys()

            #expect(try await store.count() == 0)
        }
    }

    // MARK: - Setup

    @Test("The store can be registered before the database is configured")
    func useBeforeDatabasesAreConfigured() async throws {
        try await withApp(
            autoStart: false,
            configure: { app in
                app.peerstore.use(.fluent)
                app.databases.use(.sqlite(.memory), as: .sqlite)
                app.peerstore.prepareMigrations()
            }
        ) { app in
            try await app.autoMigrate()
            #expect(app.peers is FluentPeerStore)

            let peer = try Self.randomPeer()
            try await app.peers.add(key: peer)
            #expect(try await app.peers.count() == 1)
        }
    }

    @Test("A store on an unconfigured database reports databaseNotConfigured")
    func unconfiguredDatabaseThrows() async throws {
        try await withApp(autoStart: false) { app in
            let store = app.peerstore.fluent(.init(string: "missing"))
            await #expect(throws: FluentPeerStore.Error.databaseNotConfigured(.init(string: "missing"))) {
                _ = try await store.count()
            }
        }
    }

    // MARK: - Schema

    @Test("A fresh install gets the binary, canonically keyed schema")
    func freshInstallCreatesSchema() async throws {
        try await Self.withSQLApp { app, sql in
            try await app.autoMigrate()

            let entryColumns = try await Self.columnTypes(of: PeerStoreEntry.schema, on: sql)
            #expect(Set(entryColumns.keys) == ["id", "peer_id", "key_pair"])
            #expect(entryColumns["peer_id"] == "TEXT")
            #expect(entryColumns["key_pair"] == "BLOB")
            #expect(try await Self.columnTypes(of: PeerStoreEntry_Metadata.schema, on: sql)["value"] == "BLOB")
            #expect(try await Self.columnTypes(of: PeerStoreEntry_Record.schema, on: sql)["record"] == "BLOB")
            #expect(try await Self.indexNames(of: PeerStoreEntry_Protocol.schema, on: sql).contains("_fluent_peerstore_protocols_protocol_idx"))
            #expect(try await Self.indexNames(of: PeerStoreEntry_Multiaddr.schema, on: sql).contains("_fluent_peerstore_multiaddr_address_idx"))

            // `peer_id` is the canonical id, so one peer can only be stored once, whichever spelling it's
            // created from.
            let peer = try Self.randomPeer()
            try await PeerStoreEntry(peerID: peer).create(on: app.db)
            await #expect(throws: (any Error).self) {
                try await PeerStoreEntry(peerID: PeerID(cid: peer.traditionalB58String())).create(on: app.db)
            }
            let stored = try #require(try await PeerStoreEntry.query(on: app.db).first())
            #expect(stored.peer == (try peer.traditionalB58String()))
            #expect(try stored.peerID.b58String == peer.b58String)
        }
    }

    @Test("Pre-0.1.0 tables are replaced by the new schema")
    func legacyTablesAreReplaced() async throws {
        try await Self.withSQLApp { app, sql in
            // Recreate the old (string valued) tables, with a row in each. The protocol table is left out,
            // to check a table that was never created doesn't trip up the drop.
            let peer = try Self.randomPeer()
            let entryID = UUID()
            try await sql.raw(
                """
                CREATE TABLE "_fluent_peerstore" ("id" BLOB PRIMARY KEY, "peer_id" TEXT NOT NULL, "key_pair" BLOB, UNIQUE ("peer_id"))
                """
            ).run()
            for (table, columns) in [
                ("_fluent_peerstore_multiaddr", #""address" TEXT NOT NULL"#),
                ("_fluent_peerstore_records", #""sequence" INTEGER NOT NULL, "record" TEXT NOT NULL"#),
                ("_fluent_peerstore_metadata", #""key" TEXT NOT NULL, "value" TEXT NOT NULL"#),
            ] {
                try await sql.raw(
                    """
                    CREATE TABLE \(ident: table) ("id" BLOB PRIMARY KEY, "peer_id" BLOB NOT NULL REFERENCES "_fluent_peerstore" ("id") ON DELETE CASCADE, \(unsafeRaw: columns))
                    """
                ).run()
            }
            try await sql.insert(into: PeerStoreEntry.schema)
                .columns("id", "peer_id")
                .values(SQLBind(entryID), SQLBind(peer.b58String))
                .run()
            try await sql.insert(into: PeerStoreEntry_Metadata.schema)
                .columns("id", "peer_id", "key", "value")
                .values(SQLBind(UUID()), SQLBind(entryID), SQLBind("agentVersion"), SQLBind("go-libp2p"))
                .run()

            try await app.autoMigrate()

            // The old rows are gone and the tables have the new column types.
            let store = FluentPeerStore(application: app)
            #expect(try await store.count() == 0)
            #expect(try await PeerStoreEntry_Metadata.query(on: app.db).count() == 0)
            #expect(try await Self.columnTypes(of: PeerStoreEntry_Metadata.schema, on: sql)["value"] == "BLOB")
            #expect(try await Self.columnTypes(of: PeerStoreEntry_Record.schema, on: sql)["record"] == "BLOB")

            // And the store works on them.
            try await store.add(key: peer)
            try await store.add(metaKey: "binary", data: [0xFF, 0x00], toPeer: peer)
            try await store.add(record: PeerRecord(peerID: peer, multiaddrs: [], sequenceNumber: 1))
            #expect(try await store.getMetadata(forPeer: peer)["binary"] == [0xFF, 0x00])
            #expect(try await store.getMostRecentRecord(forPeer: peer)?.sequenceNumber == 1)
        }
    }

    @Test("Reverting drops the tables and ignores pre-0.1.0 migration log entries")
    func revertIgnoresLegacyMigrationLogs() async throws {
        try await Self.withSQLApp { app, sql in
            // A database that ran the old per-table `Create` migrations has their names in its migration
            // log. Those migrations no longer exist, so a full revert has to skip them.
            try await app.migrator.setupIfNeeded().get()
            for name in ["PeerStoreEntry", "PeerStoreEntry_Multiaddr", "PeerStoreEntry_Metadata"] {
                try await MigrationLog(name: "Fluent.\(name).Create", batch: 1).create(on: app.db)
            }
            try await app.autoMigrate()

            try await app.autoRevert()

            let tables = try await sql.raw("SELECT name FROM sqlite_master WHERE type = 'table'").all()
                .map { try $0.decode(column: "name", as: String.self) }
            #expect(!tables.contains { $0.hasPrefix("_fluent_peerstore") })
        }
    }

    // MARK: - Helpers

    /// Runs `body` against a `FluentPeerStore` on a freshly migrated in-memory SQLite database.
    ///
    /// The app isn't started, so libp2p's own traffic doesn't touch the store.
    private static func withStore(
        configuration: FluentPeerStore.Configuration = .init(),
        _ body: (FluentPeerStore) async throws -> Void
    ) async throws {
        try await withApp(
            autoStart: false,
            configure: { app in
                app.databases.use(.sqlite(.memory), as: .sqlite)
                app.peerstore.prepareMigrations()
            }
        ) { app in
            try await app.autoMigrate()
            try await body(FluentPeerStore(application: app, configuration: configuration))
        }
    }

    /// Runs `body` against an app with an in-memory SQLite database and the PeerStore migrations
    /// registered, but not yet run.
    private static func withSQLApp(_ body: (Application, any SQLDatabase) async throws -> Void) async throws {
        try await withApp(
            autoStart: false,
            configure: { app in
                app.databases.use(.sqlite(.memory), as: .sqlite)
                app.peerstore.prepareMigrations()
            }
        ) { app in
            try await body(app, try #require(app.db as? any SQLDatabase))
        }
    }

    /// Each column of `table` and its declared SQLite type.
    private static func columnTypes(of table: String, on sql: any SQLDatabase) async throws -> [String: String] {
        var types: [String: String] = [:]
        for row in try await sql.raw("PRAGMA table_info(\(ident: table))").all() {
            types[try row.decode(column: "name", as: String.self)] = try row.decode(column: "type", as: String.self)
        }
        return types
    }

    private static func indexNames(of table: String, on sql: any SQLDatabase) async throws -> [String] {
        try await sql.raw("PRAGMA index_list(\(ident: table))").all()
            .map { try $0.decode(column: "name", as: String.self) }
    }

    private static func randomPeer() throws -> PeerID { try PeerID(.Ed25519) }

    private static let echo = SemVerProtocol("/echo/1.0.0")!
}

extension FluentPeerStore {
    /// The store's database, for asserting on rows directly.
    fileprivate var testDatabase: any Database {
        get throws {
            guard let database = self.databases.database(self.databaseID, logger: .init(label: "test"), on: self.eventLoop)
            else { throw Error.databaseNotConfigured(self.databaseID) }
            return database
        }
    }
}
#endif
