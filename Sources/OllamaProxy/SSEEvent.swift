//
//  SSEEvent.swift
//  OllamaProxy
//
//  Created by Philipp on 07.12.2025.
//

struct SSEEvent {
    var id: String?
    var event: String?
    var data: String

    static func parseSSEEvent(from text: String) -> SSEEvent? {
        var id: String?
        var event: String?
        var dataLines: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.starts(with: "id:") {
                id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.starts(with: "event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.starts(with: "data:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataLines.append(value)
            } else {
                continue
            }
        }

        guard !dataLines.isEmpty else { return nil }

        return SSEEvent(
            id: id,
            event: event,
            data: dataLines.joined(separator: "\n")
        )
    }
}
