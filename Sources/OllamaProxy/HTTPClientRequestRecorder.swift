//
//  CallbackHTTPClientDelegate.swift
//  OllamaProxy
//
//  Created by Philipp on 09.04.2025.
//

import NIOCore
import NIOHTTP1

final actor HTTPClientRequestRecorder{
    var request: ReplayableHTTPRequest

    private let clock: ContinuousClock
    private let startTime: ContinuousClock.Instant
    private var logger: OllamaLogger

    init(
        url: String,
        method: HTTPMethod = .GET,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil
    ) {
        clock = ContinuousClock()
        startTime =  clock.now
        self.request = ReplayableHTTPRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            startTime: startTime
        )
        logger = OllamaLogger(method: method.rawValue, uri: url.description)
        logger.log(request: request)
    }

    func didReceive(head: HTTPResponseHead) {
        let response = ReplayableHTTPResponse(
            status: head.status,
            headers: head.headers,
            version: head.version,
            headerTime: clock.now
        )
        request.response = response
        logger.log(response: response)
    }

    func didReceive(buffer: ByteBuffer) {
        request.response?.append(bodyChunk: buffer, at: clock.now)
        logger.append(buffer: buffer)
    }

    func didFinish() {
        request.response?.endTime = clock.now
        if let response = request.response {
            logger.log(fullResponse: response)
        }
    }

    func writeRequestAndResponseData(to path: String) throws {
        try BodyWriter.write(request: request, to: path)
    }
}
