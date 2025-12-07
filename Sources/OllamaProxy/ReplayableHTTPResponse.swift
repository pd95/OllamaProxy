//
//  ReplayableHTTPResponse.swift
//  OllamaProxy
//
//  Created by Philipp on 11.04.2025.
//

import Foundation
import NIOCore
import NIOHTTP1

struct ReplayableHTTPResponse {
    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var version: HTTPVersion
    var bodyChunks: [ByteBuffer] = []

    var headerTime: ContinuousClock.Instant?
    var chunkTime: [ContinuousClock.Instant] = []
    var endTime: ContinuousClock.Instant?

    init(status: HTTPResponseStatus, headers: HTTPHeaders, version: HTTPVersion, headerTime: ContinuousClock.Instant) {
        self.status = status
        self.headers = headers
        self.version = version
        self.headerTime = headerTime
    }

    mutating func append(bodyChunk: ByteBuffer, at time: ContinuousClock.Instant) {
        self.bodyChunks.append(bodyChunk)
        self.chunkTime.append(time)
    }
}

extension ReplayableHTTPResponse: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = HTTPResponseStatus(statusCode: try container.decode(Int.self, forKey: .status))
        self.headers = try container.decode(HTTPHeaders.self, forKey: .headers)
        let responseVersion = try container.decode(String.self, forKey: .version).split(separator: ".").compactMap({ Int(String($0)) })
        self.version = HTTPVersion(major: responseVersion[0], minor: responseVersion[1])
        self.bodyChunks = try container.decode([ByteBuffer].self, forKey: .bodyChunks)
        self.headerTime = try container.decode(ContinuousClock.Instant.self, forKey: .headerTime)
        self.chunkTime = try container.decode([ContinuousClock.Instant].self, forKey: .chunkTime)
        self.endTime = try container.decodeIfPresent(ContinuousClock.Instant.self, forKey: .endTime)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status.code, forKey: .status)
        try container.encode(headers, forKey: .headers)
        try container.encode(version.description, forKey: .version)
        try container.encode(bodyChunks, forKey: .bodyChunks)
        try container.encode(headerTime, forKey: .headerTime)
        try container.encode(chunkTime, forKey: .chunkTime)
        try container.encode(endTime, forKey: .endTime)
    }

    enum CodingKeys: String, CodingKey {
        case status
        case headers
        case version
        case bodyChunks
        case startTime
        case headerTime
        case chunkTime
        case endTime
    }
}

