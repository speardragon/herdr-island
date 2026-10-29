import Foundation

// JSON with its keys in source order (a document's `_id` comes first, as the database wrote it).
// Input cut off mid-way still yields what was complete: an array drops its unfinished element,
// so a long result cut by `Truncate` keeps its whole documents.

indirect enum JValue: Equatable {
    case string(String)
    /// Kept as written: Long values do not fit a Double.
    case number(String)
    case bool(Bool)
    case null
    case array([JValue])
    case object([JPair])
}

struct JPair: Equatable {
    let key: String
    let value: JValue
}

enum OrderedJSON {
    struct Parsed {
        let value: JValue
        /// The input ended before the value did.
        let truncated: Bool
    }

    /// Objects and arrays only; nil for other text or malformed JSON.
    static func parse(_ text: String) -> Parsed? {
        var reader = JSONReader(bytes: Array(text.utf8))
        reader.skipSpace()
        guard let first = reader.peek, first == .openBrace || first == .openBracket,
              let read = try? reader.value() else { return nil }
        reader.skipSpace()
        guard !read.1 || reader.atEnd else { return nil }
        return Parsed(value: read.0, truncated: !read.1)
    }
}

private enum JSONError: Error {
    case end, invalid
}

private extension UInt8 {
    static let openBrace = UInt8(ascii: "{"), closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "["), closeBracket = UInt8(ascii: "]")
    static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
    static let comma = UInt8(ascii: ","), colon = UInt8(ascii: ":")
}

private struct JSONReader {
    let bytes: [UInt8]
    var i = 0

    var atEnd: Bool { i >= bytes.count }
    var peek: UInt8? { atEnd ? nil : bytes[i] }

    mutating func skipSpace() {
        while let c = peek, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 }
    }

    /// A value and whether it was complete; containers return what they had when the input ran out.
    mutating func value() throws -> (JValue, Bool) {
        skipSpace()
        guard let c = peek else { throw JSONError.end }
        switch c {
        case .openBrace: return try object()
        case .openBracket: return try array()
        case .quote: return (.string(try string()), true)
        case UInt8(ascii: "t"): try literal("true"); return (.bool(true), true)
        case UInt8(ascii: "f"): try literal("false"); return (.bool(false), true)
        case UInt8(ascii: "n"): try literal("null"); return (.null, true)
        default: return (.number(try number()), true)
        }
    }

    private mutating func array() throws -> (JValue, Bool) {
        i += 1
        var items: [JValue] = []
        while true {
            skipSpace()
            guard let c = peek else { return (.array(items), false) }
            if c == .closeBracket {
                i += 1
                return (.array(items), true)
            }
            if !items.isEmpty {
                guard c == .comma else { throw JSONError.invalid }
                i += 1
            }
            guard let item = try partial({ try $0.value() }), item.1 else { return (.array(items), false) }
            items.append(item.0)
        }
    }

    private mutating func object() throws -> (JValue, Bool) {
        i += 1
        var pairs: [JPair] = []
        while true {
            skipSpace()
            guard let c = peek else { return (.object(pairs), false) }
            if c == .closeBrace {
                i += 1
                return (.object(pairs), true)
            }
            if !pairs.isEmpty {
                guard c == .comma else { throw JSONError.invalid }
                i += 1
                skipSpace()
            }
            guard let key = try partial({ try $0.string() }) else { return (.object(pairs), false) }
            skipSpace()
            guard let colon = peek else { return (.object(pairs), false) }
            guard colon == .colon else { throw JSONError.invalid }
            i += 1
            guard let read = try partial({ try $0.value() }) else { return (.object(pairs), false) }
            let (value, complete) = read
            // A nested list cut short still says something; a cut-off scalar does not.
            switch value {
            case .array, .object: pairs.append(JPair(key: key, value: value))
            default: if complete { pairs.append(JPair(key: key, value: value)) }
            }
            if !complete { return (.object(pairs), false) }
        }
    }

    /// Runs `read`, turning the end of input into nil and passing other errors on.
    private mutating func partial<T>(_ read: (inout JSONReader) throws -> T) throws -> T? {
        do {
            return try read(&self)
        } catch JSONError.end {
            return nil
        }
    }

    mutating func string() throws -> String {
        guard peek == .quote else { throw atEnd ? JSONError.end : JSONError.invalid }
        i += 1
        var out: [UInt8] = []
        while true {
            guard let c = peek else { throw JSONError.end }
            i += 1
            if c == .quote { return String(decoding: out, as: UTF8.self) }
            guard c == .backslash else {
                out.append(c)
                continue
            }
            guard let e = peek else { throw JSONError.end }
            i += 1
            switch e {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "u"): out.append(contentsOf: try unicodeEscape())
            default: out.append(e)
            }
        }
    }

    /// `\uXXXX`, joining a surrogate pair into one scalar.
    private mutating func unicodeEscape() throws -> [UInt8] {
        var code = try hex4()
        if (0xD800...0xDBFF).contains(code), bytes.count >= i + 6, bytes[i] == .backslash, bytes[i + 1] == UInt8(ascii: "u") {
            i += 2
            let low = try hex4()
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
        }
        return Array(String(Unicode.Scalar(code).map(Character.init) ?? "\u{FFFD}").utf8)
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw JSONError.end }
        guard let code = UInt32(String(decoding: bytes[i..<(i + 4)], as: UTF8.self), radix: 16) else { throw JSONError.invalid }
        i += 4
        return code
    }

    private mutating func number() throws -> String {
        let start = i
        while let c = peek, (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
            || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { i += 1 }
        guard i > start else { throw JSONError.invalid }
        // A number running into the end may have lost digits.
        if atEnd { throw JSONError.end }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func literal(_ word: String) throws {
        for expected in word.utf8 {
            guard let c = peek else { throw JSONError.end }
            guard c == expected else { throw JSONError.invalid }
            i += 1
        }
    }
}
