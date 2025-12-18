//
//  OllamaLogger.swift
//  OllamaProxy
//
//  Created by Philipp on 06.12.2025.
//

import Logging
import Vapor

extension HTTPMediaType {
    static let eventStream = HTTPMediaType(type: "text", subType: "event-stream", parameters: ["charset": "utf-8"])
    static let ndjson = HTTPMediaType(type: "application", subType: "x-ndjson", parameters: ["charset": "utf-8"])
}

enum StreamOutputMode: CustomStringConvertible {
    case none, reasoning, response

    var description: String {
        switch self {
        case .none: return "None"
        case .reasoning: return "Reasoning"
        case .response: return "Response"
        }
    }
}

class OllamaLogger {

    static let logger = {
        var logger = Logger(label: "OllamaAPI")
        logger.logLevel = .debug
        return logger
    }()

    let method: String
    let url: String

    private let isOpenAICompatibility: Bool
    private var contentType: HTTPMediaType = .plainText
    private var partialBuffer = ByteBuffer()
    private var needsNewline: Bool = false
    private var isStreaming: Bool = false
    private var streamMode: StreamOutputMode = .none

    init(method: String, uri: String) {
        self.method = method
        self.url = uri
        self.isOpenAICompatibility = uri.prefix(3) == "/v1"
    }

    // Private "print-helper"
    private func print(_ string: String, terminator: String = "\n") {
        if terminator != "\n" {
            needsNewline = true
        } else {
            if needsNewline {
                Swift.print("")
                needsNewline = false
            }
        }
        Swift.print(string, terminator: terminator)
    }

    private func setOutputMode(_ mode: StreamOutputMode) {
        guard streamMode != mode else { return }
        streamMode = mode
        print("")
        print("--- \(mode.description): ")
    }

    func log(request: ReplayableHTTPRequest) {
        contentType = request.headers.contentType ?? .plainText
        Self.logger.info("REQ: \(method) \(url) \(contentType.description)")
        if let data = request.body, contentType == .json {
            log(buffer: data, isRequest: true)
        }
    }

    func log(response: ReplayableHTTPResponse) {
        contentType = response.headers.contentType ?? .plainText
        Self.logger.info("RSP starting: \(response.status.description) \(contentType.description)")
    }


    func append(buffer chunk: ByteBuffer) {
        var chunk = chunk
        partialBuffer.writeBuffer(&chunk)

        // handle content type specific logging
        switch contentType {
        case .eventStream:

            // Search for event boundary, returning offset and boundary length
            while let (offset, sepLen) = findEventBoundary(in: partialBuffer) {
                // consume bytes by reading slice up to boundary
                guard let eventSlice = partialBuffer.readSlice(length: offset) else {
                    break
                }
                // Skip separator length
                _ = partialBuffer.readSlice(length: sepLen)

                log(event: eventSlice)
            }
        case .ndjson:

            while let offset = findNewline(in: partialBuffer) {
                guard let slice = partialBuffer.readSlice(length: offset) else {
                    break
                }
                _ = partialBuffer.readSlice(length: 1)

                log(buffer: slice)
            }
        default:
            break
        }

        // Optional: protect against puffer bloat
        let maxBufferBytes = 10 * 1024 * 1024
        if partialBuffer.readableBytes > maxBufferBytes {
            Self.logger.warning("Warning: event buffer exceeded \(maxBufferBytes) bytes — dropping buffer to avoid OOM")
            partialBuffer.clear()
        }
    }

    private func findNewline(in buffer: ByteBuffer) -> Int? {
        let view = buffer.readableBytesView
        let count = view.count
        if count == 0 { return nil }

        for i in 0...count - 1 {
            let d = view[view.index(view.startIndex, offsetBy: i)]
            if d == 0x0A {
                return i
            }
        }

        return nil
    }

    private func findEventBoundary(in buffer: ByteBuffer) -> (offset: Int, length: Int)? {
        let view = buffer.readableBytesView
        let count = view.count
        if count == 0 { return nil }

        // Für Performance: wir indexieren über die Collection-Offsets
        // Prüfen auf CRLFCRLF (\r\n\r\n) zuerst (4 Bytes)
        if count >= 4 {
            for i in 0...count - 4 {
                let a = view[view.index(view.startIndex, offsetBy: i)]
                let b = view[view.index(view.startIndex, offsetBy: i+1)]
                let c = view[view.index(view.startIndex, offsetBy: i+2)]
                let d = view[view.index(view.startIndex, offsetBy: i+3)]
                if a == 0x0D && b == 0x0A && c == 0x0D && d == 0x0A {
                    return (i, 4)
                }
            }
        }

        // Prüfen auf LF LF (\n\n) (2 Bytes)
        if count >= 2 {
            for i in 0...count - 2 {
                let a = view[view.index(view.startIndex, offsetBy: i)]
                let b = view[view.index(view.startIndex, offsetBy: i+1)]
                if a == 0x0A && b == 0x0A || a == 0x0D && b == 0x0D {
                    return (i, 2)
                }
            }
        }

        return nil
    }

    private func log(event buffer: ByteBuffer, isRequest: Bool = false) {
        guard let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes),
              let event = SSEEvent.parseSSEEvent(from: string)
        else {
            print("Could not extract SSEvent from buffer")
            print(buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? "")
            return
        }

        guard event.data != "[DONE]" else { return }
        if let jsonObject = try? AnyJSON(string: event.data) {
            log(json: jsonObject, underLyingBuffer: buffer, isRequest: isRequest)
        } else {
            Self.logger.error("Invalid JSON object: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "n/a")")
        }
    }

    private func log(buffer: ByteBuffer, isRequest: Bool = false) {
        guard let jsonObject = try? AnyJSON(buffer: buffer) else {
            Self.logger.error("Invalid JSON object: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "n/a")")
            return
        }

        log(json: jsonObject, underLyingBuffer: buffer, isRequest: isRequest)
    }

    private func log(json jsonObject: AnyJSON, underLyingBuffer buffer: ByteBuffer, isRequest: Bool = false) {

        if isOpenAICompatibility {
            if isRequest {
                let model = jsonObject.model.optionalString.map({ " model: \($0)" }) ?? ""
                isStreaming = jsonObject.stream.bool
                print("--- 📩 \(url)\(model)\(isStreaming ? " (streaming)" : "") ---")
                if let prompt = jsonObject.prompt.optionalString {
                    print(prompt)

                } else if let messages: [AnyJSON] = jsonObject.messages.optionalArray {
                    // process all messages
                    for (index, message) in messages.enumerated() {
                        let role = message.role.optionalString ?? "(no role)"
                        print("--- Message \(index + 1): \(role) ---")
                        if role == "tool" {
                            let content = message.content.string
                            print("🛠️ tool call output (\(message.tool_call_id.string)) -------------------- 8< --------------------")
                            let dict = (try? AnyJSON(string: content))?.dictionary ?? [:]
                            for (key, value) in dict {
                                print("  \(key): \(value.optionalString ?? "n/a")")
                            }
                            print("🛠️ (\(message.tool_call_id.string)) --------------------8<--------------------")
                        } else {
                            if let content = message.content.optionalArray {
                                for entry in content {
                                    let type = entry.type.string
                                    if type == "text" {
                                        print(entry.text.string)
                                    } else {
                                        Self.logger.warning("unknown content type: \(type)")
                                    }
                                    print("")
                                }
                            } else if let content = message.content.optionalString {
                                print(content)
                                print("")
                            } else if let toolCalls = message.tool_calls.optionalArray {
                                for toolCall in toolCalls {
                                    let type = toolCall.function.name.string
                                    var arguments = toolCall.function.arguments.string
                                    if type == "shell" {
                                        if let parsedArguments = (try? AnyJSON(string: arguments))?.command.array.map(\.string) {
                                            arguments = "\"\(parsedArguments.joined(separator: " "))\""
                                        }
                                    } else {
                                        // try to parse the arguments as JSON
                                        if let parsedArguments = try? AnyJSON(string: arguments) {
                                            if let input = parsedArguments.input.optionalString {
                                                arguments = "\n\(input)\n"
                                            } else {
                                                arguments = "\"\(parsedArguments)\""
                                            }
                                        }
                                    }
                                    print("--- 🛠️ tool call \(toolCall.id.string) (\(type)) start")
                                    print(arguments)
                                    print("--- 🛠️ tool call \(toolCall.id.string) (\(type)) end")
                                }
                            } else {
                                print("🔴 JSON: \(message)\n")
                            }
                        }
                    }
                } else {
                    Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                }
            } else {
                let object = jsonObject.object.string

                if object == "list", let models = jsonObject.data.optionalArray {
                    print("\(models.count) models returned")

                } else if object == "chat.completion.chunk" {
                    if let toolCalls = jsonObject.choices.first?.delta.tool_calls.optionalArray {
                        print("Tool calls")
                        for toolCall in toolCalls {
                            let type = toolCall.function.name.string
                            var arguments = toolCall.function.arguments.string
                            if type == "shell" {
                                if let parsedArguments = (try? AnyJSON(string: arguments))?.command.array.map(\.string) {
                                    arguments = "\"\(parsedArguments.joined(separator: " "))\""
                                }
                            } else {
                                // try to parse the arguments as JSON
                                if let parsedArguments = try? AnyJSON(string: arguments) {
                                    if let input = parsedArguments.input.optionalString {
                                        arguments = "\n\(input)\n"
                                    } else {
                                        arguments = "\"\(parsedArguments)\""
                                    }
                                }
                            }
                            print("--- 🛠️ tool call \(toolCall.id.string) (\(type)) start")
                            print(arguments)
                            print("--- 🛠️ tool call \(toolCall.id.string) (\(type)) end")
                        }
                    } else if let reasoning = jsonObject.choices.first?.delta.reasoning.optionalString {
                        setOutputMode(.reasoning)
                        print(reasoning, terminator: "")
                    } else if let content = jsonObject.choices.first?.delta.content.optionalString {
                        setOutputMode(.response)
                        print(content, terminator: "")
                    } else {
                        Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                    }
                } else if object == "chat.completion" {
                    if let text = jsonObject.choices.first?.message.content.string {
                        print(text)
                    } else {
                        Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                    }
                } else if object == "text_completion" {
                    if let text = jsonObject.choices.first?.text.string {
                        print(text)
                    } else {
                        Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                    }
                } else {
                    Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                }
            }
        } else {
            if isRequest {
                let model = jsonObject.model.optionalString.map({ " model: \($0)" }) ?? ""
                isStreaming = jsonObject.stream.bool
                print("--- 📩 \(url)\(model)\(isStreaming ? " (streaming)" : "") ---")
                if let messages: [AnyJSON] = jsonObject.messages.optionalArray {
                    for (index, message) in messages.enumerated() {
                        let role = message.role.optionalString ?? "(no role)"
                        print("--- Message \(index + 1): \(role) ---")
                        let content = message.content.optionalString ?? ""
                        print("\(content)\n")
                    }
                } else {
                    Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                }
            } else {
                if url == "/api/version" {
                    if let version = jsonObject.version.optionalString {
                        print(version)
                    }
                } else if url == "/api/tags" {
                    if let models = jsonObject.models.optionalArray {
                        print("\(models.count) models returned")
                    }
                } else if url == "/api/generate" {
                    if let content = jsonObject.thinking.optionalString {
                        setOutputMode(.reasoning)
                        print(content, terminator: "")
                    }
                    if let content = jsonObject.response.optionalString, content.isEmpty == false  {
                        setOutputMode(.response)
                        print(content, terminator: "")
                    }
                } else if url == "/api/chat" {
                    let message = jsonObject.message
                    if let content = message.thinking.optionalString {
                        setOutputMode(.reasoning)
                        print(content, terminator: "")
                    }
                    if let content = message.content.optionalString, content.isEmpty == false {
                        setOutputMode(.response)
                        print(content, terminator: "")
                    }
                } else {
                    Self.logger.debug("unknown json: \(buffer.getString(at: 0, length: buffer.readableBytes) ?? "")")
                }
            }
        }
    }

    private func log(text buffer: ByteBuffer, isRequest: Bool = false) {
        let string = buffer.getString(at: 0, length: buffer.readableBytes)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if string.isEmpty == false {
            print(string)
        }
    }

    func log(fullResponse response: ReplayableHTTPResponse) {
        switch contentType {
        case .eventStream, .ndjson:
            print("")  // add terminator
        case .json:
            log(buffer: partialBuffer)
        case .plainText:
            log(text: partialBuffer)
        default:
            Self.logger.warning("Unknown content-type: \(contentType.description)")
        }
        Self.logger.info("RSP completed: \(response.status.description)")
    }
}
