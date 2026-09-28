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

extension Application.PeerStores {
    /// A Fluent-backed PeerStore on the default database.
    public var fluent: FluentPeerStore {
        self.fluent(nil)
    }

    /// A Fluent-backed PeerStore on the database registered as `db`.
    public func fluent(_ db: DatabaseID?, configuration: FluentPeerStore.Configuration = .init()) -> FluentPeerStore {
        FluentPeerStore(application: self.application, database: db, configuration: configuration)
    }

    /// Registers every migration the Fluent PeerStore needs. See ``FluentPeerStore/migrations``.
    public func prepareMigrations() {
        self.application.migrations.add(FluentPeerStore.migrations)
    }
}

extension Application.PeerStores.Provider {
    /// Uses a Fluent-backed PeerStore on the default database.
    ///
    ///     app.peerstore.prepareMigrations()
    ///     app.peerstore.use(.fluent)
    ///
    public static var fluent: Self {
        .fluent(nil)
    }

    /// Uses a Fluent-backed PeerStore on the database registered as `db`.
    public static func fluent(_ db: DatabaseID?, configuration: FluentPeerStore.Configuration = .init()) -> Self {
        .init {
            $0.peerstore.use { $0.peerstore.fluent(db, configuration: configuration) }
        }
    }
}

/// A persistent `PeerStore` backed by your fluent database of choice.
///
/// It behaves like swift-libp2p's in-memory store, but survives restarts and can be shared by
/// several processes using the same database.
///
/// ## Ordering
///
/// Every operation runs on a serial queue, in the order it was called. Back-to-back calls see each
/// other's writes, exactly the same as the in-memory store. This matters because Identify issues
/// `add(key:)`, `add(addresses:)`, `add(protocols:)` and the metadata writes without waiting for
/// each other.
///
/// ## Keying
///
/// Peers are looked up by their canonical (`Qm…`) id, so the `12D3Koo…` and `Qm…` versions of
/// the same peer resolve to the same entry.
///
/// ## Capacity
///
/// Once the store holds more than ``Configuration/maxPeers`` peers, the oldest are evicted,
/// `.prunable` peers first, then `.preferred` ones. Peers marked `.necessary` are never evicted.
public struct FluentPeerStore: PeerStore {

    /// Capacity limits for the store.
    public struct Configuration: Sendable {
        /// How many peers to hold before evicting the oldest prunable ones.
        public var maxPeers: Int
        /// How many signed `PeerRecord`s to keep per peer.
        public var maxRecordsPerPeer: Int
        /// The fraction of `maxPeers` to evict when the store is full.
        public var prunePercentWhenFull: Double

        public init(maxPeers: Int = 5_000, maxRecordsPerPeer: Int = 3, prunePercentWhenFull: Double = 0.05) {
            self.maxPeers = maxPeers
            self.maxRecordsPerPeer = maxRecordsPerPeer
            self.prunePercentWhenFull = prunePercentWhenFull
        }
    }

    public enum Error: Swift.Error, Hashable, Sendable, CustomStringConvertible {
        /// The peer isn't in the store.
        case peerNotFound
        /// No database is registered under this ID (configure one with `app.databases.use(_:as:)`),
        /// or Fluent/Application has already shut down.
        case databaseNotConfigured(DatabaseID?)

        public var description: String {
            switch self {
            case .peerNotFound:
                return "Peer not found"
            case .databaseNotConfigured(let id):
                return "No database is configured for \(id.map { "`\($0.string)`" } ?? "the default ID")"
            }
        }
    }

    /// Every migration the Fluent PeerStore needs.
    ///
    /// - Note: Migrating a database that has the pre-0.1.0 PeerStore tables replaces them, clearing
    ///   their contents.
    public static var migrations: [any Migration] {
        [CreateSchema()]
    }

    /// The database this store uses, or `nil` for the default database.
    public let databaseID: DatabaseID?
    public let configuration: Configuration

    let databases: Databases
    let eventLoop: any EventLoop
    private let logger: Logger
    private let queue: SerialTaskQueue

    /// Creates a store on the database registered as `id`.
    ///
    /// The database is resolved for each operation, so the store can be created before
    /// `app.databases.use(_:as:)` is called.
    public init(application: Application, database id: DatabaseID? = nil, configuration: Configuration = .init()) {
        self.databaseID = id
        self.configuration = configuration
        self.databases = application.databases
        self.eventLoop = application.eventLoopGroup.next()
        var logger = application.logger
        logger[metadataKey: "PeerStore"] = .string("Fluent")
        self.logger = logger
        self.queue = SerialTaskQueue()
    }

    /// Queues `operation` on the store's serial queue, and completes the returned future on
    /// the specified EventLoop or the store's event loop when `nil`.
    private func run<T: Sendable>(
        on: (any EventLoop)?,
        _ operation: @escaping @Sendable (any Database) async throws -> T
    ) -> EventLoopFuture<T> {
        let databases = self.databases
        let id = self.databaseID
        let logger = self.logger
        let eventLoop = self.eventLoop
        return self.queue.enqueue(on: on ?? eventLoop) {
            // `Databases.database(_:)` traps on an unknown ID, so check it's registered first. With no
            // ID, any registration will do, the first database registered becomes the default.
            let registered = databases.ids()
            guard id.map(registered.contains) ?? !registered.isEmpty,
                // `nil` once Fluent has shut down.
                let database = databases.database(id, logger: logger, on: eventLoop)
            else {
                throw Error.databaseNotConfigured(id)
            }
            return try await operation(database)
        }
    }

    private func succeed(on: (any EventLoop)?) -> EventLoopFuture<Void> {
        (on ?? self.eventLoop).makeSucceededVoidFuture()
    }

    /// Runs `body` and returns its result, or logs and returns `nil` if the entry can't be decoded.
    private func decoding<T>(_ entry: PeerStoreEntry, _ body: (PeerStoreEntry) throws -> T) -> T? {
        do {
            return try body(entry)
        } catch {
            self.logger.warning("Skipping undecodable peer entry `\(entry.peer)`: \(error)")
            return nil
        }
    }
}

// MARK: Peer Store

extension FluentPeerStore {
    /// Returns every peer, with its addresses, protocols, records and metadata.
    ///
    /// - Warning: This loads the whole store. Prefer the more specific queries.
    public func all() -> EventLoopFuture<[ComprehensivePeer]> {
        self.run(on: nil) { db in
            try await PeerStoreEntry.query(on: db)
                .with(\.$multiaddrs)
                .with(\.$protocols)
                .with(\.$records)
                .with(\.$metadata)
                .all()
                .compactMap { self.decoding($0) { try $0.makeComprehensivePeer() } }
        }
    }

    public func count() -> EventLoopFuture<Int> {
        self.run(on: nil) { db in
            try await PeerStoreEntry.query(on: db).count()
        }
    }

    public func getAllPeerIDs(on: (any EventLoop)? = nil) -> EventLoopFuture<[PeerID]> {
        self.run(on: on) { db in
            try await PeerStoreEntry.query(on: db).all()
                .compactMap { self.decoding($0) { try $0.peerID } }
        }
    }

    public func getAllPeerInfos(on: (any EventLoop)? = nil) -> EventLoopFuture<[PeerInfo]> {
        self.run(on: on) { db in
            try await PeerStoreEntry.query(on: db)
                .with(\.$multiaddrs)
                .all()
                .compactMap { self.decoding($0) { try $0.makePeerInfo() } }
        }
    }
}

// MARK: PeerID Entry Helpers

extension FluentPeerStore {
    /// The entry for `peer`, matched by canonical id.
    static func entry(for peer: PeerID, on db: any Database) async throws -> PeerStoreEntry? {
        try await PeerStoreEntry.query(on: db)
            .filter(\.$peer == PeerStoreEntry.canonicalID(for: peer))
            .first()
    }

    /// The entry for `peer`, or ``Error/peerNotFound``.
    static func requireEntry(for peer: PeerID, on db: any Database) async throws -> PeerStoreEntry {
        guard let entry = try await Self.entry(for: peer, on: db) else { throw Error.peerNotFound }
        return entry
    }

    /// The database id of `peer`'s entry, or ``Error/peerNotFound``.
    static func requireEntryID(for peer: PeerID, on db: any Database) async throws -> PeerStoreEntry.IDValue {
        try await Self.requireEntry(for: peer, on: db).requireID()
    }

    /// Returns `peer`'s entry, creating it (with a `discovered` timestamp) if it doesn't exist yet.
    ///
    /// - Returns: The entry, and whether it was created by this call.
    private func ensureEntry(for peer: PeerID, on db: any Database) async throws -> (PeerStoreEntry, created: Bool) {
        if let existing = try await Self.entry(for: peer, on: db) {
            return (existing, false)
        }
        do {
            let created = try await Self.withTransaction(db) { db in
                let entry = PeerStoreEntry(peerID: peer)
                try await entry.create(on: db)
                try await PeerStoreEntry_Metadata(
                    peerID: entry.requireID(),
                    key: MetadataBook.Keys.discovered.rawValue,
                    value: Self.encodeTimestamp(Date())
                ).create(on: db)
                return entry
            }
            return (created, true)
        } catch  where error.isConstraintFailure {
            // Another process sharing this database created the peer between our lookup and insert.
            guard let existing = try await Self.entry(for: peer, on: db) else { throw error }
            return (existing, false)
        }
    }

    /// Deletes the entries with the given ids and all of their child rows.
    static func deleteEntries(_ ids: [PeerStoreEntry.IDValue], on db: any Database) async throws {
        guard !ids.isEmpty else { return }
        // Child rows are deleted explicitly rather than relying on `ON DELETE CASCADE`, which MongoDB
        // doesn't have and SQLite only enforces when foreign keys are enabled.
        try await PeerStoreEntry_Record.query(on: db).filter(\.$peer.$id ~~ ids).delete(force: true)
        try await PeerStoreEntry_Multiaddr.query(on: db).filter(\.$peer.$id ~~ ids).delete(force: true)
        try await PeerStoreEntry_Protocol.query(on: db).filter(\.$peer.$id ~~ ids).delete(force: true)
        try await PeerStoreEntry_Metadata.query(on: db).filter(\.$peer.$id ~~ ids).delete(force: true)
        try await PeerStoreEntry.query(on: db).filter(\.$id ~~ ids).delete(force: true)
    }

    /// Runs `body` in a transaction, or directly when already in one or on MongoDB (whose
    /// transactions need a replica set).
    static func withTransaction<T: Sendable>(
        _ db: any Database,
        _ body: @escaping @Sendable (any Database) async throws -> T
    ) async throws -> T {
        if db.inTransaction || db.isMongoDB {
            return try await body(db)
        }
        return try await db.transaction(body)
    }
}

// MARK: Address Book

extension FluentPeerStore {
    /// Normalises `address` for `peer`'s address book by appending `/p2p/<peer>` if it's missing.
    ///
    /// - Returns: The qualified address, or `nil` when the address names a different peer and so
    ///   doesn't belong in this peer's address book.
    static func canonicalAddress(_ address: Multiaddr, for peer: PeerID) -> Multiaddr? {
        if let embedded = try? address.getPeerID() {
            return embedded == peer ? address : nil
        }
        return address.encapsulating(peer: peer)
    }

    public func add(address: Multiaddr, toPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.add(addresses: [address], toPeer: peer, on: on)
    }

    public func add(addresses: [Multiaddr], toPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        guard !addresses.isEmpty else { return self.succeed(on: on) }
        return self.run(on: on) { db in
            let entry = try await Self.requireEntry(for: peer, on: db)
            try await Self.insertAddresses(addresses, into: entry, on: db)
        }
    }

    /// The `PeerID` addresses are qualified with, the stored one, so the `/p2p` component always uses
    /// the same spelling of the peer's id, whichever spelling the caller passed in.
    private static func addressPeer(of entry: PeerStoreEntry, or fallback: PeerID) -> PeerID {
        (try? entry.peerID) ?? fallback
    }

    /// Adds the canonical form of each address that `entry` doesn't already have.
    private static func insertAddresses(
        _ addresses: [Multiaddr],
        into entry: PeerStoreEntry,
        on db: any Database
    ) async throws {
        guard !addresses.isEmpty, let peer = try? entry.peerID else { return }
        let entryID = try entry.requireID()
        let canonical = addresses.compactMap { Self.canonicalAddress($0, for: peer)?.description }.uniqued()
        guard !canonical.isEmpty else { return }
        let existing = Set(
            try await PeerStoreEntry_Multiaddr.query(on: db)
                .filter(\.$peer.$id == entryID)
                .filter(\.$address ~~ canonical)
                .all()
                .map(\.address)
        )
        let rows = canonical.filter { !existing.contains($0) }.map { address in
            let row = PeerStoreEntry_Multiaddr()
            row.$peer.id = entryID
            row.address = address
            return row
        }
        guard !rows.isEmpty else { return }
        try await rows.create(on: db)
    }

    /// Removes a `Multiaddr` from an existing peer, in either its bare or `/p2p` qualified form.
    public func remove(address: Multiaddr, fromPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entry = try await Self.requireEntry(for: peer, on: db)
            let stored = Self.addressPeer(of: entry, or: peer)
            let versions = [address, Self.canonicalAddress(address, for: stored)].compactMap { $0?.description }
            try await PeerStoreEntry_Multiaddr.query(on: db)
                .filter(\.$peer.$id == entry.requireID())
                .filter(\.$address ~~ versions)
                .delete(force: true)
        }
    }

    /// Removes all `Multiaddr`s from an existing peer.
    public func removeAllAddresses(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await PeerStoreEntry_Multiaddr.query(on: db)
                .filter(\.$peer.$id == entryID)
                .delete(force: true)
        }
    }

    public func getAddresses(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<[Multiaddr]> {
        self.run(on: on) { db in
            let entry = try await Self.requireEntry(for: peer, on: db)
            let stored = Self.addressPeer(of: entry, or: peer)
            return try await PeerStoreEntry_Multiaddr.query(on: db)
                .filter(\.$peer.$id == entry.requireID())
                .all()
                .compactMap { $0.multiaddr(for: stored) }
                .uniqued()
        }
    }

    /// Returns the b58 id of the peer holding `address`.
    public func getPeer(byAddress address: Multiaddr, on: (any EventLoop)? = nil) -> EventLoopFuture<String> {
        self.run(on: on) { db in
            try await Self.entry(byAddress: address, on: db).peerID.b58String
        }
    }

    /// Returns the `PeerID` of the peer holding `address`.
    public func getPeerID(byAddress address: Multiaddr, on: (any EventLoop)? = nil) -> EventLoopFuture<PeerID> {
        self.run(on: on) { db in
            try await Self.entry(byAddress: address, on: db).peerID
        }
    }

    /// Returns the `PeerInfo` of the peer holding `address`.
    public func getPeerInfo(byAddress address: Multiaddr, on: (any EventLoop)? = nil) -> EventLoopFuture<PeerInfo> {
        self.run(on: on) { db in
            let entry = try await Self.entry(byAddress: address, on: db)
            try await entry.$multiaddrs.load(on: db)
            return try entry.makePeerInfo()
        }
    }

    /// Finds the peer holding `address`.
    ///
    /// A `/p2p` qualified address is matched exactly first. Otherwise, or if that finds nothing, any
    /// peer holding the same transport address matches. Ties are broken by b58 id, like the
    /// in-memory store.
    private static func entry(byAddress address: Multiaddr, on db: any Database) async throws -> PeerStoreEntry {
        if (try? address.getPeerID()) != nil {
            let exact = try await PeerStoreEntry_Multiaddr.query(on: db)
                .filter(\.$address == address.description)
                .with(\.$peer)
                .all()
            if let match = exact.map(\.peer).min(by: { $0.peer < $1.peer }) {
                return match
            }
        }

        let bare = address.decapsulatingPeerID()
        let qualifiedPrefix = bare.description + "/p2p/"
        let candidates = try await PeerStoreEntry_Multiaddr.query(on: db)
            .group(.or) { group in
                // Legacy rows may be stored bare, current rows end in `/p2p/<peer>`.
                group.filter(\.$address == bare.description)
                    .filter(\.$address =~ qualifiedPrefix)
            }
            .with(\.$peer)
            .all()
            // The prefix match is a coarse filter (it would also match e.g. relayed addresses).
            .filter { (try? Multiaddr($0.address))?.decapsulatingPeerID() == bare }
        guard let match = candidates.map(\.peer).min(by: { $0.peer < $1.peer }) else {
            throw Error.peerNotFound
        }
        return match
    }
}

// MARK: Key Book

extension FluentPeerStore {
    /// Adds a peer, or upgrades a stored id-only peer to one with a public key.
    public func add(key: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let (entry, created) = try await self.ensureEntry(for: key, on: db)
            if created {
                try await self.pruneIfNeeded(on: db)
            } else {
                try await Self.upgrade(entry, to: key, on: db)
            }
        }
    }

    /// Stores `key`'s public key on `entry` if the entry doesn't have one yet.
    /// A stored public key is never replaced by an id-only `PeerID`.
    private static func upgrade(_ entry: PeerStoreEntry, to key: PeerID, on db: any Database) async throws {
        guard key.type != .idOnly, entry.keypair == nil || (try? entry.peerID) == nil,
            let publicKey = try? key.marshalPublicKey()
        else { return }
        entry.keypair = Data(publicKey)
        try await entry.update(on: db)
    }

    /// Removes a peer and everything stored for it.
    public func remove(key: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            guard let entryID = try await Self.entry(for: key, on: db)?.requireID() else { return }
            try await Self.withTransaction(db) { db in
                try await Self.deleteEntries([entryID], on: db)
            }
        }
    }

    /// Removes every peer.
    ///
    /// - Warning: This drops the entire peerstore
    public func removeAllKeys(on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            try await Self.withTransaction(db) { db in
                try await PeerStoreEntry_Record.query(on: db).delete(force: true)
                try await PeerStoreEntry_Multiaddr.query(on: db).delete(force: true)
                try await PeerStoreEntry_Protocol.query(on: db).delete(force: true)
                try await PeerStoreEntry_Metadata.query(on: db).delete(force: true)
                try await PeerStoreEntry.query(on: db).delete(force: true)
            }
        }
    }

    /// Returns the stored `PeerID` for a b58 or CID string. Both the `12D3Koo…` and `Qm…` versions
    /// of a peer's id resolve to it.
    public func getKey(forPeer id: String, on: (any EventLoop)? = nil) -> EventLoopFuture<PeerID> {
        self.run(on: on) { db in
            // Unparseable input can't match a canonical id, but try it anyway.
            let canonical = PeerStoreEntry.canonicalID(for: id) ?? id
            guard let entry = try await PeerStoreEntry.query(on: db).filter(\.$peer == canonical).first() else {
                throw Error.peerNotFound
            }
            return try entry.peerID
        }
    }
}

// MARK: Protocol Book

extension FluentPeerStore {
    public func add(
        protocol proto: SemVerProtocol,
        toPeer peer: PeerID,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<Void> {
        self.add(protocols: [proto], toPeer: peer, on: on)
    }

    public func add(
        protocols protos: [SemVerProtocol],
        toPeer peer: PeerID,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<Void> {
        guard !protos.isEmpty else { return self.succeed(on: on) }
        return self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            let strings = protos.map(\.stringValue).uniqued()
            let existing = Set(
                try await PeerStoreEntry_Protocol.query(on: db)
                    .filter(\.$peer.$id == entryID)
                    .filter(\.$protocol ~~ strings)
                    .all()
                    .map(\.protocol)
            )
            let rows = strings.filter { !existing.contains($0) }.map { proto in
                let row = PeerStoreEntry_Protocol()
                row.$peer.id = entryID
                row.protocol = proto
                return row
            }
            guard !rows.isEmpty else { return }
            try await rows.create(on: db)
        }
    }

    public func remove(
        protocol proto: SemVerProtocol,
        fromPeer peer: PeerID,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<Void> {
        self.remove(protocols: [proto], fromPeer: peer, on: on)
    }

    public func remove(
        protocols protos: [SemVerProtocol],
        fromPeer peer: PeerID,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            guard !protos.isEmpty else { return }
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await PeerStoreEntry_Protocol.query(on: db)
                .filter(\.$peer.$id == entryID)
                .filter(\.$protocol ~~ protos.map(\.stringValue))
                .delete(force: true)
        }
    }

    public func removeAllProtocols(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await PeerStoreEntry_Protocol.query(on: db)
                .filter(\.$peer.$id == entryID)
                .delete(force: true)
        }
    }

    public func getProtocols(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<[SemVerProtocol]> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            return try await PeerStoreEntry_Protocol.query(on: db)
                .filter(\.$peer.$id == entryID)
                .all()
                .compactMap { SemVerProtocol($0.protocol) }
        }
    }

    /// Returns the b58 ids of every peer that supports exactly `proto`.
    public func getPeers(
        supportingProtocol proto: SemVerProtocol,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<[String]> {
        self.run(on: on) { db in
            try await Self.entries(supporting: proto, on: db)
                .compactMap { self.decoding($0) { try $0.peerID.b58String } }
        }
    }

    /// Returns every peer that supports exactly `proto`.
    public func getPeerIDs(
        supportingProtocol proto: SemVerProtocol,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<[PeerID]> {
        self.run(on: on) { db in
            try await Self.entries(supporting: proto, on: db)
                .compactMap { self.decoding($0) { try $0.peerID } }
        }
    }

    /// Returns the b58 ids of every peer with a protocol that `matches` `proto`.
    public func getPeers(
        matchingProtocol proto: SemVerProtocol,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<[String]> {
        self.run(on: on) { db in
            try await Self.entries(matching: proto, on: db)
                .compactMap { self.decoding($0) { try $0.peerID.b58String } }
        }
    }

    /// Returns every peer with a protocol that `matches` `proto`.
    public func getPeerIDs(
        matchingProtocol proto: SemVerProtocol,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<[PeerID]> {
        self.run(on: on) { db in
            try await Self.entries(matching: proto, on: db)
                .compactMap { self.decoding($0) { try $0.peerID } }
        }
    }

    private static func entries(supporting proto: SemVerProtocol, on db: any Database) async throws -> [PeerStoreEntry]
    {
        try await PeerStoreEntry_Protocol.query(on: db)
            .filter(\.$protocol == proto.stringValue)
            .with(\.$peer)
            .all()
            // A version range can render to the same string as an exact version, but isn't equal to it.
            .filter { SemVerProtocol($0.protocol) == proto }
            .map(\.peer)
    }

    /// Version matching can't be expressed in SQL, so this narrows the protocol table to candidate
    /// rows in the database, runs the semver check on those, and then loads only the matching peers.
    private static func entries(matching proto: SemVerProtocol, on db: any Database) async throws -> [PeerStoreEntry] {
        let query = PeerStoreEntry_Protocol.query(on: db)
        if let version = proto.version {
            // Every `SemVersion` case requires the major versions to agree, so a match must be stored
            // as `/<proto>/<major>.…`. `LIKE` may over-match but we call matches below to make sure.
            query.filter(\.$protocol =~ "/\(proto.proto)/\(version.protocolVersion.major).")
        } else {
            // An unversioned protocol only matches other unversioned protocols.
            query.filter(\.$protocol == proto.stringValue)
        }
        let ids = try await query.all()
            .filter { SemVerProtocol($0.protocol)?.matches(proto) ?? false }
            .map { $0.$peer.id }
            .uniqued()
        guard !ids.isEmpty else { return [] }
        return try await PeerStoreEntry.query(on: db).filter(\.$id ~~ ids).all()
    }
}

// MARK: Record Book

extension FluentPeerStore {
    /// Stores a signed `PeerRecord`.
    ///
    /// Like the in-memory store, this creates the peer if it's unknown, skips a record whose
    /// sequence number is already stored, merges the record's addresses into the address book, and
    /// keeps the newest ``Configuration/maxRecordsPerPeer`` records.
    public func add(record: PeerRecord, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let peer = record.peerID
            let (entry, created) = try await self.ensureEntry(for: peer, on: db)
            let entryID = try entry.requireID()
            let limit = self.configuration.maxRecordsPerPeer
            let logger = self.logger
            try await Self.withTransaction(db) { db in
                let isDuplicate =
                    try await PeerStoreEntry_Record.query(on: db)
                    .filter(\.$peer.$id == entryID)
                    .filter(\.$sequence == Int64(bitPattern: record.sequenceNumber))
                    .count() > 0
                if isDuplicate {
                    logger.debug("Skipping duplicate PeerRecord with sequence number \(record.sequenceNumber)")
                } else {
                    try await PeerStoreEntry_Record(peerID: entryID, record: record).create(on: db)
                }
                try await Self.insertAddresses(record.multiaddrs, into: entry, on: db)
                try await Self.trimRecords(forEntry: entryID, keepingMostRecent: limit, on: db)
            }
            if created {
                try await self.pruneIfNeeded(on: db)
            }
        }
    }

    public func getRecords(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<[PeerRecord]> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            return try await PeerStoreEntry_Record.query(on: db)
                .filter(\.$peer.$id == entryID)
                .all()
                .compactMap { row in
                    do {
                        return try row.peerRecord()
                    } catch {
                        self.logger.warning("Skipping undecodable PeerRecord for \(peer): \(error)")
                        return nil
                    }
                }
        }
    }

    /// Returns the record with the highest sequence number, or `nil` if the peer has none.
    public func getMostRecentRecord(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<PeerRecord?> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            return try await PeerStoreEntry_Record.query(on: db)
                .filter(\.$peer.$id == entryID)
                .all()
                .sorted { $0.sequenceNumber > $1.sequenceNumber }
                .lazy
                .compactMap { try? $0.peerRecord() }
                .first
        }
    }

    /// Trims all but the most recent record from the peer.
    public func trimRecords(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await Self.trimRecords(forEntry: entryID, keepingMostRecent: 1, on: db)
        }
    }

    /// Trims every peer's records down to its most recent one.
    @discardableResult
    public func trimAllRecords(on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let stale = Dictionary(grouping: try await PeerStoreEntry_Record.query(on: db).all(), by: { $0.$peer.id })
                .values
                .flatMap { $0.sorted { $0.sequenceNumber > $1.sequenceNumber }.dropFirst() }
                .compactMap(\.id)
            guard !stale.isEmpty else { return }
            try await PeerStoreEntry_Record.query(on: db).filter(\.$id ~~ stale).delete(force: true)
        }
    }

    public func removeRecords(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await PeerStoreEntry_Record.query(on: db)
                .filter(\.$peer.$id == entryID)
                .delete(force: true)
        }
    }

    /// Deletes all but the `limit` highest-sequence records of `entryID`.
    private static func trimRecords(
        forEntry entryID: PeerStoreEntry.IDValue,
        keepingMostRecent limit: Int,
        on db: any Database
    ) async throws {
        let stale = try await PeerStoreEntry_Record.query(on: db)
            .filter(\.$peer.$id == entryID)
            .all()
            .sorted { $0.sequenceNumber > $1.sequenceNumber }
            .dropFirst(limit)
            .compactMap(\.id)
        guard !stale.isEmpty else { return }
        try await PeerStoreEntry_Record.query(on: db).filter(\.$id ~~ stale).delete(force: true)
    }
}

// MARK: Metadata Book

extension FluentPeerStore {
    /// Sets the metadata value for `key`, replacing any existing value.
    public func add(
        metaKey key: String,
        data: [UInt8],
        toPeer peer: PeerID,
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await Self.setMetadata(data, forKey: key, entryID: entryID, on: db)
        }
    }

    public func remove(metaKey key: String, fromPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void>
    {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await PeerStoreEntry_Metadata.query(on: db)
                .filter(\.$peer.$id == entryID)
                .filter(\.$key == key)
                .delete(force: true)
        }
    }

    public func removeAllMetadata(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Void> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            try await PeerStoreEntry_Metadata.query(on: db)
                .filter(\.$peer.$id == entryID)
                .delete(force: true)
        }
    }

    public func getMetadata(forPeer peer: PeerID, on: (any EventLoop)? = nil) -> EventLoopFuture<Metadata> {
        self.run(on: on) { db in
            let entryID = try await Self.requireEntryID(for: peer, on: db)
            var metadata: Metadata = [:]
            for row in try await PeerStoreEntry_Metadata.query(on: db).filter(\.$peer.$id == entryID).all() {
                metadata[row.key] = [UInt8](row.value)
            }
            return metadata
        }
    }

    /// Upserts the `(entryID, key)` metadata row.
    private static func setMetadata(
        _ bytes: [UInt8],
        forKey key: String,
        entryID: PeerStoreEntry.IDValue,
        on db: any Database
    ) async throws {
        func existingRow() async throws -> PeerStoreEntry_Metadata? {
            try await PeerStoreEntry_Metadata.query(on: db)
                .filter(\.$peer.$id == entryID)
                .filter(\.$key == key)
                .first()
        }

        if let row = try await existingRow() {
            row.value = Data(bytes)
            try await row.update(on: db)
            return
        }
        do {
            try await PeerStoreEntry_Metadata(peerID: entryID, key: key, value: bytes).create(on: db)
        } catch  where error.isConstraintFailure {
            // Another process sharing this database inserted the key between our lookup and insert.
            guard let row = try await existingRow() else { throw error }
            row.value = Data(bytes)
            try await row.update(on: db)
        }
    }
}

// MARK: Pruning

extension FluentPeerStore {
    /// Removes peers we haven't contacted within `expiration`, based on each peer's last handshake,
    /// or when it was discovered if there's been no handshake. `.necessary` peers are kept.
    ///
    /// - Returns: The number of peers removed.
    @discardableResult
    public func prunePeers(
        olderThan expiration: TimeAmount = .minutes(10),
        on: (any EventLoop)? = nil
    ) -> EventLoopFuture<Int> {
        self.run(on: on) { db in
            let cutoff = Date().addingTimeInterval(-Double(expiration.nanoseconds) / 1_000_000_000)
            let stale = try await self.pruneCandidates(on: db)
                .filter { candidate in
                    guard candidate.prunability != .necessary else { return false }
                    guard let lastSeen = candidate.lastHandshake ?? candidate.discovered else { return true }
                    return lastSeen < cutoff
                }
                .map(\.id)
            try await Self.withTransaction(db) { db in
                try await Self.deleteEntries(stale, on: db)
            }
            self.logger.debug("Pruned \(stale.count) stale peers")
            return stale.count
        }
    }

    /// Evicts the oldest `percent` of ``Configuration/maxPeers``, `.prunable` peers first and then
    /// `.preferred` ones. `.necessary` peers are never pruned.
    ///
    /// - Returns: The number of peers removed.
    @discardableResult
    public func prunePeers(oldestPercent percent: Double = 0.05, on: (any EventLoop)? = nil) -> EventLoopFuture<Int> {
        self.run(on: on) { db in
            try await self.pruneOldest(percent: percent, on: db)
        }
    }

    private func pruneIfNeeded(on db: any Database) async throws {
        guard try await PeerStoreEntry.query(on: db).count() > self.configuration.maxPeers else { return }
        try await self.pruneOldest(percent: self.configuration.prunePercentWhenFull, on: db)
    }

    @discardableResult
    private func pruneOldest(percent: Double, on db: any Database) async throws -> Int {
        let target = max(Int(Double(self.configuration.maxPeers) * percent), 1)
        let oldestFirst = try await self.pruneCandidates(on: db)
            .sorted { ($0.discovered ?? .distantFuture) < ($1.discovered ?? .distantFuture) }

        var prune = oldestFirst.filter { $0.prunability == .prunable }.prefix(target).map(\.id)
        if prune.count < target {
            prune += oldestFirst.filter { $0.prunability == .preferred }.prefix(target - prune.count).map(\.id)
        }
        if prune.count < target {
            self.logger.warning(
                "Not enough prunable peers to satisfy prune request of \(percent * 100)%: found \(prune.count) of desired \(target) of a total \(oldestFirst.count) peers"
            )
        }

        try await Self.withTransaction(db) { [prune] db in
            try await Self.deleteEntries(prune, on: db)
        }
        self.logger.debug("Pruned the \(prune.count) oldest peers")
        return prune.count
    }

    /// What pruning needs to know about a peer.
    private struct PruneCandidate {
        let id: PeerStoreEntry.IDValue
        let discovered: Date?
        let lastHandshake: Date?
        let prunability: MetadataBook.PrunableMetadata.Prunable
    }

    /// Every peer with the metadata pruning uses, loaded in two queries.
    private func pruneCandidates(on db: any Database) async throws -> [PruneCandidate] {
        let keys: [MetadataBook.Keys] = [.discovered, .lastHandshake, .prunable]
        var metadata: [PeerStoreEntry.IDValue: [String: [UInt8]]] = [:]
        for row in try await PeerStoreEntry_Metadata.query(on: db).filter(\.$key ~~ keys.map(\.rawValue)).all() {
            metadata[row.$peer.id, default: [:]][row.key] = [UInt8](row.value)
        }

        return try await PeerStoreEntry.query(on: db).all().compactMap { entry in
            guard let id = entry.id else { return nil }
            let values = metadata[id] ?? [:]
            let prunable = values[MetadataBook.Keys.prunable.rawValue].flatMap {
                try? JSONDecoder().decode(MetadataBook.PrunableMetadata.self, from: Data($0))
            }
            return PruneCandidate(
                id: id,
                discovered: values[MetadataBook.Keys.discovered.rawValue].flatMap(Self.decodeTimestamp),
                lastHandshake: values[MetadataBook.Keys.lastHandshake.rawValue].flatMap(Self.decodeTimestamp),
                prunability: prunable?.prunable ?? .prunable
            )
        }
    }
}

extension Database {
    fileprivate var isMongoDB: Bool {
        String(reflecting: type(of: self.configuration)).contains("FluentMongo")
    }
}

extension Swift.Error {
    /// Whether this is a database unique / foreign key constraint violation.
    fileprivate var isConstraintFailure: Bool {
        (self as? any DatabaseError)?.isConstraintFailure ?? false
    }
}
