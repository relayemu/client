// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Foundation's JSON decoder accepts duplicate object keys. Reject them, deep
/// nesting, and noninteger numbers before decoding this small wire protocol.
enum TransferJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard String(data: data, encoding: .utf8) != nil else { throw TransferError.invalidMessage }
        var parser = Parser(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TransferError.invalidMessage }
        return object
    }
    private struct Parser {
        let bytes: [UInt8]; var index = 0, nodes = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) throws { space(); guard index < bytes.count, bytes[index] == byte else { throw TransferError.invalidMessage }; index += 1 }
        mutating func string() throws -> String {
            space(); let start = index; try consume(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { guard index < bytes.count else { throw TransferError.invalidMessage }; index += 1 }
                else if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                }
            }
            throw TransferError.invalidMessage
        }
        mutating func value(depth: Int) throws {
            nodes += 1; space()
            guard depth <= 16, nodes <= 2048, index < bytes.count else { throw TransferError.invalidMessage }
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw TransferError.invalidMessage }
                    try consume(58); try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw TransferError.invalidMessage }
                    if bytes[index] == 125 { index += 1; return }; try consume(44)
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space(); guard index < bytes.count else { throw TransferError.invalidMessage }
                    if bytes[index] == 93 { index += 1; return }; try consume(44)
                }
            case 34: _ = try string()
            case 116, 102, 110:
                let literal = bytes[index] == 116 ? "true" : bytes[index] == 102 ? "false" : "null"
                for byte in literal.utf8 { try consume(byte) }
            default:
                let start = index
                if bytes[index] == 45 { index += 1 }
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > start, Int64(String(decoding: bytes[start..<index], as: UTF8.self)) != nil else { throw TransferError.invalidMessage }
            }
        }
    }
}
