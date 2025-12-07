//
//  HTTPStreamingResponseDelegate.swift
//  OllamaProxy
//
//  Created by Philipp on 20.04.2025.
//

import NIOCore
import NIOHTTP1
import AsyncHTTPClient

final class HTTPStreamingResponseDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    enum ResponseEvent {
        case head(HTTPResponseHead)
        case bodyPart(ByteBuffer)
    }

    let stream: AsyncThrowingStream<ResponseEvent, any Error>

    private var continuation: AsyncThrowingStream<ResponseEvent, any Error>.Continuation

    init() {
        let (stream, continuation) = AsyncThrowingStream<ResponseEvent, any Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        task.logger.trace("HTTP Header: \(head.description)")
        continuation.onTermination = { reason in
            if case .cancelled = reason {
                task.cancel()
            }
        }

        continuation.yield(.head(head))
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        task.logger.trace("Body Part: \(String(buffer: buffer))")
        continuation.yield(.bodyPart(buffer))
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: any Error) {
        task.logger.error("Request Received error: \(error)")
        continuation.finish(throwing: error)
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        task.logger.trace("Request Finished")
        continuation.finish()
    }
}
