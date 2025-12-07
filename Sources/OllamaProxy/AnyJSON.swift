//
//  AnyJSON.swift
//  OllamaProxy
//
//  Created by Philipp on 07.12.2025.
//

import Vapor

extension Dictionary where Key == String {
    func bool(for key: String) -> Bool? {
        self[key] as? Bool
    }

    func double(for key: String) -> Double? {
        self[key] as? Double
    }

    func int(for key: String) -> Int? {
        self[key] as? Int
    }

    func string(for key: String) -> String? {
        self[key] as? String
    }
}


@dynamicMemberLookup
struct AnyJSON: RandomAccessCollection {
    var value: Any?
    var startIndex: Int { array.startIndex }
    var endIndex: Int { array.endIndex }

    init(string: String) throws {
        let data = Data(string.utf8)
        value = try JSONSerialization.jsonObject(with: data)
    }

    init(buffer: ByteBuffer) throws {
        value = try JSONSerialization.jsonObject(with: buffer)
    }

    init(value: Any?) {
        self.value = value
    }

    var optionalBool: Bool? {
        value as? Bool
    }

    var optionalDouble: Double? {
        value as? Double
    }

    var optionalInt: Int? {
        value as? Int
    }

    var optionalString: String? {
        value as? String
    }

    var bool: Bool {
        optionalBool ?? false
    }

    var double: Double {
        optionalDouble ?? 0
    }

    var int: Int {
        optionalInt ?? 0
    }

    var string: String {
        optionalString ?? ""
    }

    var optionalArray: [AnyJSON]? {
        let converted = value as? [Any]
        return converted?.map { AnyJSON(value: $0) }
    }

    var optionalDictionary: [String: AnyJSON]? {
        let converted = value as? [String: Any]
        return converted?.mapValues { AnyJSON(value: $0) }
    }

    var array: [AnyJSON] {
        optionalArray ?? []
    }

    var dictionary: [String: AnyJSON] {
        optionalDictionary ?? [:]
    }

    subscript(index: Int) -> AnyJSON {
        optionalArray?[index] ?? AnyJSON(value: nil)
    }

    subscript(key: String) -> AnyJSON {
        optionalDictionary?[key] ?? AnyJSON(value: nil)
    }

    subscript(dynamicMember key: String) -> AnyJSON {
        optionalDictionary?[key] ?? AnyJSON(value: nil)
    }
}
