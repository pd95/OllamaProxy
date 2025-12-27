//
//  HTTPClientRequestRecorder 2.swift
//  OllamaProxy
//
//  Created by Philipp on 27.12.2025.
//

import Foundation
import Logging
import NIOCore

struct BodyWriter {
    enum Error: Swift.Error {
        case writeFailure(String, any Swift.Error)
    }

    static func write(request: ReplayableHTTPRequest) throws {
        let logger = Logger(label: "BodyWriter")
        let timestamp = Date.now.formatted(.iso8601.timeZoneSeparator(.omitted).dateTimeSeparator(.space).dateSeparator(.omitted).timeSeparator(.omitted))
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "Z", with: "")
        let cleanURL = request.url.dropFirst().replacing("/", with: "_")
        let reqFileName = "OllamaProxy-\(cleanURL)-req-\(timestamp).json"
        let tempDirectoryURL = URL.currentDirectory()

        // Write request body data to a file
        if let body = request.body {
            let fileURL = tempDirectoryURL.appendingPathComponent(reqFileName)
            let data = Data(buffer: body)
            do {
                try data.write(to: fileURL)
                logger.info("request body written to \(fileURL.path(percentEncoded: false))")
            } catch {
                throw Error.writeFailure(reqFileName, error)
            }
        }

        // Write response body chunks to individual files
        if let response = request.response {
            let buffer = response.bodyChunks.reduce(into: ByteBuffer()) { writeBuf, chunk in
                writeBuf.writeImmutableBuffer(chunk)
            }

            let responseFileName = "OllamaProxy-\(cleanURL)-rsp-\(timestamp).json"
            let fileURL = tempDirectoryURL.appendingPathComponent(responseFileName)
            let data = Data(buffer: buffer)
            do {
                try data.write(to: fileURL)
                logger.info("response chunk written to \(fileURL.path(percentEncoded: false))")
            } catch {
                throw Error.writeFailure(responseFileName, error)
            }
        }
    }
}
