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
public import LibP2P

struct RequestQueryHistory: StorageKey {
    typealias Value = QueryHistory
}

struct FluentHistoryKey: StorageKey {
    typealias Value = FluentHistory
}

struct FluentHistory: Sendable {
    let enabled: Bool
}

extension Request {
    /// Request-scoped Fluent state.
    ///
    /// - Todo: Make sure this scope lasts for the entire streams lifecycle (not just per Request event)
    ///   This depends on how swift-libp2p constructs Requests for its Responders.
    public struct Fluent: Sendable {
        let request: Request

        public var history: History {
            .init(fluent: self)
        }

        public struct History: Sendable {
            let fluent: Fluent
        }
    }
}

extension Application.Fluent.History {
    var historyEnabled: Bool {
        storage[FluentHistoryKey.self]?.enabled ?? false
    }

    var storage: Storage {
        get {
            self.fluent.application.storage
        }
        nonmutating set {
            self.fluent.application.storage = newValue
        }
    }

    var history: QueryHistory? {
        storage[RequestQueryHistory.self]
    }

    /// The queries stored in this lifecycle history
    public var queries: [DatabaseQuery] {
        history?.queries ?? []
    }

    /// Start recording the query history
    public func start() {
        storage[FluentHistoryKey.self] = .init(enabled: true)
        storage[RequestQueryHistory.self] = .init()
    }

    /// Stop recording the query history
    public func stop() {
        storage[FluentHistoryKey.self] = .init(enabled: false)
    }

    /// Clear the stored query history
    public func clear() {
        storage[RequestQueryHistory.self] = .init()
    }
}

extension Request.Fluent.History {
    var historyEnabled: Bool {
        (storage[FluentHistoryKey.self]?.enabled) ?? false
    }

    var storage: Storage {
        get {
            self.fluent.request.storage
        }
        nonmutating set {
            self.fluent.request.storage = newValue
        }
    }

    var history: QueryHistory? {
        storage[RequestQueryHistory.self]
    }

    /// The queries stored in this lifecycle history
    public var queries: [DatabaseQuery] {
        history?.queries ?? []
    }

    /// Start recording the query history
    public func start() {
        self.fluent.request.storage[FluentHistoryKey.self] = .init(enabled: true)
        self.fluent.request.storage[RequestQueryHistory.self] = .init()
    }

    /// Stop recording the query history
    public func stop() {
        storage[FluentHistoryKey.self] = .init(enabled: false)
    }

    /// Clear the stored query history
    public func clear() {
        storage[RequestQueryHistory.self] = .init()
    }
}
