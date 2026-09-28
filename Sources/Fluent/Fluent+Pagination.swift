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

import FluentKit
public import LibP2P

struct RequestPaginationKey: StorageKey {
    typealias Value = RequestPagination
}

struct RequestPagination: Sendable {
    let pageSizeLimit: PageLimit?
}

struct AppPaginationKey: StorageKey {
    typealias Value = AppPagination
}

struct AppPagination: Sendable {
    let pageSizeLimit: Int?
}

extension Request.Fluent {
    /// Request-scoped pagination settings.
    ///
    /// - Todo: Ensure this state persists for the lifetime of the stream (not just individual Request events).
    ///   This is dependent on swift-libp2p and how it constructs Requests for its Responders.
    public var pagination: Pagination {
        .init(fluent: self)
    }

    public struct Pagination: Sendable {
        let fluent: Request.Fluent
    }
}

extension Request.Fluent.Pagination {
    /// The maximum amount of elements per page. The default is `nil`.
    public var pageSizeLimit: PageLimit? {
        get {
            storage[RequestPaginationKey.self]?.pageSizeLimit
        }
        nonmutating set {
            storage[RequestPaginationKey.self] = .init(pageSizeLimit: newValue)
        }
    }

    var storage: Storage {
        get {
            self.fluent.request.storage
        }
        nonmutating set {
            self.fluent.request.storage = newValue
        }
    }
}

extension Application.Fluent.Pagination {
    /// The maximum amount of elements per page. The default is `nil`.
    public var pageSizeLimit: Int? {
        get {
            storage[AppPaginationKey.self]?.pageSizeLimit
        }
        nonmutating set {
            storage[AppPaginationKey.self] = .init(pageSizeLimit: newValue)
        }
    }

    var storage: Storage {
        get {
            self.fluent.application.storage
        }
        nonmutating set {
            self.fluent.application.storage = newValue
        }
    }
}
