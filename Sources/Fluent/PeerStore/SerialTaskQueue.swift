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

import NIOCore

/// Runs async operations one at a time, in the order they were enqueued.
///
/// This gives a Fluent PeerStore the same ordering guarantees as the in-memory store's single lock.
///
/// - Important: An operation must never enqueue onto, and then await, the same queue. The
///   queue only starts the next operation once the current one returns.
final class SerialTaskQueue: Sendable {
    typealias Operation = @Sendable () async -> Void

    private let continuation: AsyncStream<Operation>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self)
        self.continuation = continuation
        // The consumer only holds the stream, so it doesn't keep the queue alive. It exits once
        // the queue is deallocated and the stream finishes.
        Task {
            for await operation in stream {
                await operation()
            }
        }
    }

    deinit {
        self.continuation.finish()
    }

    /// Enqueues `operation` and returns a future, on `eventLoop`, for its result.
    func enqueue<T: Sendable>(
        on eventLoop: any EventLoop,
        _ operation: @escaping @Sendable () async throws -> T
    ) -> EventLoopFuture<T> {
        let promise = eventLoop.makePromise(of: T.self)
        let result = self.continuation.yield {
            do {
                promise.succeed(try await operation())
            } catch {
                promise.fail(error)
            }
        }
        if case .terminated = result {
            promise.fail(SerialTaskQueueError.terminated)
        }
        return promise.futureResult
    }
}

enum SerialTaskQueueError: Error {
    /// The queue has been torn down and no longer accepts operations.
    case terminated
}
