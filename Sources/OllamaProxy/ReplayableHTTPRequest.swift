//
//  ReplayableHTTPRequest.swift
//  OllamaProxy
//
//  Created by Philipp on 11.04.2025.
//
import Foundation
import NIOCore
import NIOHTTP1

struct ReplayableHTTPRequest {
    var url: String
    var method: HTTPMethod
    var headers: HTTPHeaders
    var body: ByteBuffer?

    var startTime: ContinuousClock.Instant
    var response: ReplayableHTTPResponse?

    init(
        url: String,
        method: HTTPMethod = .GET,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        startTime: ContinuousClock.Instant
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.startTime = startTime
    }
}

extension ReplayableHTTPRequest: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.method = HTTPMethod(rawValue: try container.decode(String.self, forKey: .method))
        self.url = try container.decode(String.self, forKey: .url)
        self.headers = try container.decode(HTTPHeaders.self, forKey: .requestHeaders)
        if let requestBody = try container.decodeIfPresent(ByteBuffer?.self, forKey: .requestBody) {
            self.body = requestBody
        }

        self.startTime = try container.decode(ContinuousClock.Instant.self, forKey: .startTime)
        self.response = try container.decodeIfPresent(ReplayableHTTPResponse.self, forKey: .response)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method.rawValue, forKey: .method)
        try container.encode(url, forKey: .url)
        try container.encode(headers, forKey: .requestHeaders)
        try container.encodeIfPresent(body, forKey: .requestBody)

        try container.encode(startTime, forKey: .startTime)
        try container.encodeIfPresent(response, forKey: .response)
    }

    enum CodingKeys: String, CodingKey {
        case method
        case url
        case requestHeaders
        case requestBody
        case response
        case startTime
    }
}



import AsyncHTTPClient

extension ReplayableHTTPRequest {

    func httpRequest() throws -> HTTPClientRequest {
        var request = HTTPClientRequest(url: url.description)
        request.headers = headers
        request.method = method
        request.body = body.map({ .bytes($0) })
        return request
    }

    func httpResponse(speedFactor: Double = 1) -> HTTPClientResponse? {
        guard let response else { return nil }

        var currentTime = startTime
        var array = [RequestReplayState]()
        for (instant, chunk) in zip(response.chunkTime, response.bodyChunks) {
            let duration = instant - currentTime
            array.append(RequestReplayState(delay: duration/speedFactor, buffer: chunk))

            currentTime = instant
        }
        let bufferSequence = ByteBuffersAsyncSequence(buffers: array)
        return HTTPClientResponse(
            version: response.version,
            status: response.status,
            headers: response.headers,
            body: .stream(bufferSequence)
        )
    }
}

struct RequestReplayState {
    let delay: ContinuousClock.Instant.Duration
    let buffer: ByteBuffer
}


// Implement the custom AsyncSequence
struct ByteBuffersAsyncSequence: AsyncSequence {

    // The internal buffer array
    private let buffers: [RequestReplayState]

    init(buffers: [RequestReplayState]) {
        self.buffers = buffers
    }

    // Conform to AsyncSequence by implementing an asynchronous iterator
    struct Iterator: AsyncIteratorProtocol, Sendable {
        private var index: Int
        private let buffers: [RequestReplayState]
        private let clock: ContinuousClock


        init(buffers: [RequestReplayState]) {
            self.buffers = buffers
            self.index = 0
            self.clock = ContinuousClock()
        }

        mutating func next() async -> ByteBuffer? {
            guard index < buffers.count else { return nil }
            defer { index += 1 }

            let delayedBuffer = buffers[index]

            try? await clock.sleep(for: delayedBuffer.delay)

            return delayedBuffer.buffer
        }
    }

    // Conform to AsyncSequence by providing the makeAsyncIterator method
    func makeAsyncIterator() -> Iterator {
        return Iterator(buffers: buffers)
    }
}
