import AsyncHTTPClient
import NIOHTTP1
import Vapor

struct ProxyService: LifecycleHandler {
    let httpClient: HTTPClient
    let baseURL: String
    var persistenceDirectory: String?

    init(app: Application, baseURL: String = "http://localhost:11434", writeFile: Bool = false) {
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
        self.baseURL = baseURL
        if writeFile {
            let path = app.directory.workingDirectory.appending("Data")
            do {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) == false {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                }
                persistenceDirectory = path
            } catch {
                app.logger.error("Unable to create persistence directory: \(error.localizedDescription)")
            }
        }
        app.logger.info("Persisting data to \(persistenceDirectory ?? "nil")")
    }

    func willBoot(_ app: Application) throws {
        app.logger.info("Application is about to boot")
    }

    func didBoot(_ app: Application) throws {
        app.logger.info("Application has booted")
    }

    func shutdown(_ app: Application) {
        app.logger.info("Application is shutting down")
        try? httpClient.syncShutdown()
    }

    func forwardRequest(_ req: Request) async throws -> Response {
        let httpClient = self.httpClient
        let logger = req.logger

        let recorder = HTTPClientRequestRecorder(
            url: req.url.description,
            method: req.method,
            headers: req.headers,
            body: req.body.data
        )

        // Preparing headers (without "Accept-Encoding")
        var requestHeaders: HTTPHeaders = req.headers
        requestHeaders.remove(name: .acceptEncoding)

        // 1. Build outgoing HTTPClient.Request
        let url = baseURL.appending(req.url.path)
        let request = try HTTPClient.Request(
            url: url,
            method: req.method,
            headers: requestHeaders,
            body: req.body.data.map { .byteBuffer($0) }
        )

        // 2. Create the delegate to stream the response
        let delegate = HTTPStreamingResponseDelegate()

        // 3. Send the request
        logger.trace("Sending Request \(request.method) \(request.url) with \(requestHeaders)")
        logger.trace("Body: \(req.body.description)")
        let executionTask = httpClient.execute(request: request, delegate: delegate)
        Task {
            do {
                try await executionTask.futureResult.get()
                try Task.checkCancellation()    // Check for task cancellation, because .get() does not!

                // Sleep a very short time to ensure recorder has been updated
                try await Task.sleep(for: .milliseconds(10))
                let replayableRequest = await recorder.request

                if let response = replayableRequest.response {
                    let endTime = response.endTime ?? replayableRequest.startTime
                    let duration = endTime - replayableRequest.startTime
                    logger.trace("Request successfully processed. Response returned \(response.bodyChunks.count) chunks in \(duration)")
                } else {
                    logger.warning("Request successfully processed, but no response recorded!")
                }


                if let persistenceDirectory {
                    do {
                        let data = try JSONEncoder().encode(replayableRequest)

                        let targetFolder = URL(filePath: persistenceDirectory)
                        let timestamp = Date.now.formatted(.iso8601.timeZoneSeparator(.omitted).dateTimeSeparator(.standard).timeSeparator(.omitted))
                        let fileName = "ReplayableRequest-\(timestamp).json"
                        let fileURL = targetFolder.appendingPathComponent(fileName)

                        // Write data to the file at the specified URL
                        try data.write(to: fileURL)

                        logger.info("replayable request written to \(fileURL.path(percentEncoded: false))")
                    } catch {
                        logger.error("Failed to write file: \(error.localizedDescription)")
                    }

                    try await recorder.writeRequestAndResponseData(to: persistenceDirectory)

                }
            } catch {
                logger.error("Request failed: \(error)")
            }
        }

        // 4. Wait for the head
        var responseStreamIterator = delegate.stream.makeAsyncIterator()
        guard case .head(let responseHead) = try await responseStreamIterator.next() else {
            throw Abort(.badGateway, reason: "Expected HTTP response head but didn't receive it.")
        }
        await recorder.didReceive(head: responseHead)


        // 5. Build the Response
        var headers = HTTPHeaders()
        var isChunked = false
        for (name, value) in responseHead.headers {
            headers.replaceOrAdd(name: name, value: value)
            if name.lowercased() == "transfer-encoding",
               value.lowercased().contains("chunked") {
                isChunked = true
            }
        }

        let response = Response(status: responseHead.status, headers: headers)

        // If the transmission is chunked, we have to gather all parts as an async body stream
        if isChunked {
            response.body = .init(asyncStream: { [delegateStream = delegate.stream] writer in
                do {
                    for try await event in delegateStream {
                        if case .bodyPart(let buffer) = event {
                            logger.trace("Writing Body Part: \(String(buffer: buffer))")
                            await recorder.didReceive(buffer: buffer)
                            try await writer.write(.buffer(buffer))
                        } else {
                            logger.error("An unexpected event was received: \(event)")
                        }
                    }
                    try await writer.write(.end)
                    await recorder.didFinish()
                } catch {
                    try? await writer.write(.error(error))
                    logger.error("Error reading from stream: \(error)")
                    executionTask.cancel()
                    throw error
                }
            })

        } else {
            // If it is following directly the header: gather the data and create a full response body
            var fullBody = ByteBufferAllocator().buffer(capacity: 0)
            while case .bodyPart(var buffer) = try await responseStreamIterator.next() {
                await recorder.didReceive(buffer: buffer)
                fullBody.writeBuffer(&buffer)
            }
            await recorder.didFinish()

            response.body = .init(buffer: fullBody)
        }

        return response
    }
}

// Store ProxyService  globally in app
extension Application {
    private struct ProxyServiceKey: StorageKey {
        typealias Value = ProxyService
    }

    var proxyService: ProxyService {
        if let existing = self.storage[ProxyServiceKey.self] {
            return existing
        }
        let new = ProxyService(app: self)
        self.storage[ProxyServiceKey.self] = new
        return new
    }
}

