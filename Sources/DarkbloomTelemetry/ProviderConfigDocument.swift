import CryptoKit
import Foundation

public enum ProviderConfigError: Error, Equatable, Sendable {
    case invalidUTF8
    case missingArray(String)
    case duplicateArray(String)
    case malformedArray(String)
    case nonStringValue(String)
    case duplicateModel(String)
    case preloadRequiresEnabled(String)
    case changedExternally
    case validationFailed(String)
}

public struct ProviderConfigDocument: Equatable, Sendable {
    public let data: Data
    public let selection: ProviderModelSelection
    public let revision: String

    private let enabledRange: Range<Int>
    private let preloadRange: Range<Int>
    private let lineEnding: String

    public init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else {
            throw ProviderConfigError.invalidUTF8
        }

        var scanner = ProviderConfigScanner(data: data)
        let arrays = try scanner.scan()
        let enabled = try Self.require("enabled_models", in: arrays)
        let preloaded = try Self.require("preload_models", in: arrays)
        let selection = ProviderModelSelection(enabled: enabled.values, preloaded: preloaded.values)
        try Self.validate(selection)

        self.data = data
        self.selection = selection
        self.revision = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        self.enabledRange = enabled.range
        self.preloadRange = preloaded.range
        self.lineEnding = Self.detectLineEnding(in: data)
    }

    public func rendering(_ selection: ProviderModelSelection) throws -> Data {
        try Self.validate(selection)

        let replacements = [
            (range: enabledRange, value: Self.renderArray(selection.enabled, lineEnding: lineEnding)),
            (range: preloadRange, value: Self.renderArray(selection.preloaded, lineEnding: lineEnding)),
        ].sorted { $0.range.lowerBound > $1.range.lowerBound }

        var rendered = data
        for replacement in replacements {
            rendered.replaceSubrange(replacement.range, with: replacement.value)
        }
        return rendered
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.data == rhs.data && lhs.selection == rhs.selection && lhs.revision == rhs.revision
    }

    private static func require(
        _ key: String,
        in arrays: [String: ProviderConfigArray]
    ) throws -> ProviderConfigArray {
        guard let array = arrays[key] else {
            throw ProviderConfigError.missingArray(key)
        }
        return array
    }

    private static func validate(_ selection: ProviderModelSelection) throws {
        try validateUnique(selection.enabled)
        try validateUnique(selection.preloaded)

        let enabled = Set(selection.enabled)
        if let model = selection.preloaded.first(where: { !enabled.contains($0) }) {
            throw ProviderConfigError.preloadRequiresEnabled(model)
        }
    }

    private static func validateUnique(_ models: [String]) throws {
        var seen = Set<String>()
        for model in models where !seen.insert(model).inserted {
            throw ProviderConfigError.duplicateModel(model)
        }
    }

    private static func detectLineEnding(in data: Data) -> String {
        let bytes = [UInt8](data)
        guard let lineFeed = bytes.firstIndex(of: 0x0A) else { return "\n" }
        return lineFeed > 0 && bytes[lineFeed - 1] == 0x0D ? "\r\n" : "\n"
    }

    private static func renderArray(_ models: [String], lineEnding: String) -> Data {
        var result = "[" + lineEnding
        for model in models {
            result += "    \"" + escape(model) + "\"," + lineEnding
        }
        result += "]"
        return Data(result.utf8)
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0A: result += "\\n"
            case 0x0C: result += "\\f"
            case 0x0D: result += "\\r"
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x00...0x1F, 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

private struct ProviderConfigArray: Equatable {
    let range: Range<Int>
    let values: [String]
}

private struct ProviderConfigScanner {
    private enum QuoteState {
        case none
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    mutating func scan() throws -> [String: ProviderConfigArray] {
        var arrays: [String: ProviderConfigArray] = [:]

        while true {
            skipStatementTrivia()
            guard index < bytes.count else { break }

            // A TOML table header changes the scope for every following key/value
            // pair. Root keys cannot resume after it, so the narrow scan is done.
            if bytes[index] == Self.openBracket { break }

            let statementStart = index
            guard let key = parseBareKey() else {
                index = skipStatement(from: statementStart)
                continue
            }
            skipHorizontalWhitespace()
            guard index < bytes.count, bytes[index] == Self.equals else {
                index = skipStatement(from: statementStart)
                continue
            }
            index += 1

            guard key == "enabled_models" || key == "preload_models" else {
                index = skipStatement(from: index)
                continue
            }
            guard arrays[key] == nil else {
                throw ProviderConfigError.duplicateArray(key)
            }

            skipHorizontalWhitespace()
            guard index < bytes.count, bytes[index] == Self.openBracket else {
                throw ProviderConfigError.nonStringValue(key)
            }
            let array = try parseStringArray(key: key)
            arrays[key] = array
            try consumeTargetStatementRemainder(key: key)
        }

        return arrays
    }

    private mutating func parseStringArray(key: String) throws -> ProviderConfigArray {
        let start = index
        index += 1
        var values: [String] = []
        var expectsValue = true

        while true {
            skipArrayTrivia()
            guard index < bytes.count else {
                throw ProviderConfigError.malformedArray(key)
            }

            if bytes[index] == Self.closeBracket {
                index += 1
                return ProviderConfigArray(range: start..<index, values: values)
            }

            if expectsValue {
                if bytes[index] == Self.comma {
                    throw ProviderConfigError.malformedArray(key)
                }
                guard bytes[index] == Self.doubleQuote || bytes[index] == Self.singleQuote else {
                    throw ProviderConfigError.nonStringValue(key)
                }
                values.append(try parseString(key: key))
                expectsValue = false
            } else if bytes[index] == Self.comma {
                index += 1
                expectsValue = true
            } else {
                throw ProviderConfigError.malformedArray(key)
            }
        }
    }

    private mutating func parseString(key: String) throws -> String {
        let quote = bytes[index]
        let multiline = hasRun(of: quote, count: 3, at: index)
        index += multiline ? 3 : 1
        if multiline { consumeImmediateNewline() }

        var decoded: [UInt8] = []
        while index < bytes.count {
            if multiline && hasRun(of: quote, count: 3, at: index) {
                index += 3
                return String(decoding: decoded, as: UTF8.self)
            }
            if !multiline && bytes[index] == quote {
                index += 1
                return String(decoding: decoded, as: UTF8.self)
            }

            let byte = bytes[index]
            if !multiline && (byte == Self.lineFeed || byte == Self.carriageReturn) {
                throw ProviderConfigError.malformedArray(key)
            }

            if quote == Self.doubleQuote, byte == Self.backslash {
                index += 1
                if multiline, consumeEscapedNewlineAndWhitespace() { continue }
                try appendEscape(to: &decoded, key: key)
                continue
            }

            if byte < 0x20 && byte != Self.tab && !(multiline && (byte == Self.lineFeed || byte == Self.carriageReturn)) {
                throw ProviderConfigError.malformedArray(key)
            }
            decoded.append(byte)
            index += 1
        }

        throw ProviderConfigError.malformedArray(key)
    }

    private mutating func appendEscape(to decoded: inout [UInt8], key: String) throws {
        guard index < bytes.count else { throw ProviderConfigError.malformedArray(key) }
        switch bytes[index] {
        case 0x62: decoded.append(0x08); index += 1
        case 0x74: decoded.append(0x09); index += 1
        case 0x6E: decoded.append(0x0A); index += 1
        case 0x66: decoded.append(0x0C); index += 1
        case 0x72: decoded.append(0x0D); index += 1
        case Self.doubleQuote: decoded.append(Self.doubleQuote); index += 1
        case Self.backslash: decoded.append(Self.backslash); index += 1
        case 0x75: try appendUnicodeEscape(digits: 4, to: &decoded, key: key)
        case 0x55: try appendUnicodeEscape(digits: 8, to: &decoded, key: key)
        default: throw ProviderConfigError.malformedArray(key)
        }
    }

    private mutating func appendUnicodeEscape(
        digits: Int,
        to decoded: inout [UInt8],
        key: String
    ) throws {
        index += 1
        guard index + digits <= bytes.count else {
            throw ProviderConfigError.malformedArray(key)
        }
        var value: UInt32 = 0
        for byte in bytes[index..<(index + digits)] {
            guard let digit = Self.hexValue(byte) else {
                throw ProviderConfigError.malformedArray(key)
            }
            value = value * 16 + digit
        }
        guard let scalar = UnicodeScalar(value) else {
            throw ProviderConfigError.malformedArray(key)
        }
        decoded.append(contentsOf: String(scalar).utf8)
        index += digits
    }

    private mutating func consumeTargetStatementRemainder(key: String) throws {
        skipHorizontalWhitespace()
        if index < bytes.count, bytes[index] == Self.comment {
            skipComment()
        }
        guard index == bytes.count || isNewline(at: index) else {
            throw ProviderConfigError.malformedArray(key)
        }
        consumeNewline()
    }

    private mutating func skipStatementTrivia() {
        while index < bytes.count {
            if isHorizontalWhitespace(bytes[index]) || isNewline(at: index) {
                if isNewline(at: index) { consumeNewline() } else { index += 1 }
            } else if bytes[index] == Self.comment {
                skipComment()
            } else {
                return
            }
        }
    }

    private mutating func skipArrayTrivia() {
        while index < bytes.count {
            if isHorizontalWhitespace(bytes[index]) {
                index += 1
            } else if isNewline(at: index) {
                consumeNewline()
            } else if bytes[index] == Self.comment {
                skipComment()
            } else {
                return
            }
        }
    }

    private mutating func skipHorizontalWhitespace() {
        while index < bytes.count, isHorizontalWhitespace(bytes[index]) { index += 1 }
    }

    private mutating func skipComment() {
        while index < bytes.count, !isNewline(at: index) { index += 1 }
    }

    private mutating func consumeImmediateNewline() {
        if isNewline(at: index) { consumeNewline() }
    }

    private mutating func consumeNewline() {
        guard index < bytes.count else { return }
        if bytes[index] == Self.carriageReturn {
            index += 1
            if index < bytes.count, bytes[index] == Self.lineFeed { index += 1 }
        } else if bytes[index] == Self.lineFeed {
            index += 1
        }
    }

    private mutating func consumeEscapedNewlineAndWhitespace() -> Bool {
        guard isNewline(at: index) else { return false }
        consumeNewline()
        while index < bytes.count {
            if isHorizontalWhitespace(bytes[index]) {
                index += 1
            } else if isNewline(at: index) {
                consumeNewline()
            } else {
                break
            }
        }
        return true
    }

    private mutating func parseBareKey() -> String? {
        let start = index
        while index < bytes.count, Self.isBareKeyByte(bytes[index]) { index += 1 }
        guard index > start else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private func skipStatement(from start: Int) -> Int {
        var cursor = start
        var quote: QuoteState = .none
        var bracketDepth = 0
        var braceDepth = 0

        while cursor < bytes.count {
            let byte = bytes[cursor]
            switch quote {
            case .basic:
                if byte == Self.backslash {
                    cursor = min(cursor + 2, bytes.count)
                } else {
                    cursor += 1
                    if byte == Self.doubleQuote { quote = .none }
                }
            case .literal:
                cursor += 1
                if byte == Self.singleQuote { quote = .none }
            case .multilineBasic:
                if hasRun(of: Self.doubleQuote, count: 3, at: cursor) {
                    cursor += 3
                    quote = .none
                } else if byte == Self.backslash {
                    cursor = min(cursor + 2, bytes.count)
                } else {
                    cursor += 1
                }
            case .multilineLiteral:
                if hasRun(of: Self.singleQuote, count: 3, at: cursor) {
                    cursor += 3
                    quote = .none
                } else {
                    cursor += 1
                }
            case .none:
                if hasRun(of: Self.doubleQuote, count: 3, at: cursor) {
                    cursor += 3
                    quote = .multilineBasic
                } else if hasRun(of: Self.singleQuote, count: 3, at: cursor) {
                    cursor += 3
                    quote = .multilineLiteral
                } else if byte == Self.doubleQuote {
                    cursor += 1
                    quote = .basic
                } else if byte == Self.singleQuote {
                    cursor += 1
                    quote = .literal
                } else if byte == Self.comment {
                    while cursor < bytes.count, !isNewline(at: cursor) { cursor += 1 }
                    if bracketDepth == 0 && braceDepth == 0 { return advancedPastNewline(from: cursor) }
                } else if byte == Self.openBracket {
                    bracketDepth += 1
                    cursor += 1
                } else if byte == Self.closeBracket {
                    bracketDepth = max(0, bracketDepth - 1)
                    cursor += 1
                } else if byte == Self.openBrace {
                    braceDepth += 1
                    cursor += 1
                } else if byte == Self.closeBrace {
                    braceDepth = max(0, braceDepth - 1)
                    cursor += 1
                } else if isNewline(at: cursor), bracketDepth == 0, braceDepth == 0 {
                    return advancedPastNewline(from: cursor)
                } else {
                    cursor += 1
                }
            }
        }
        return cursor
    }

    private func advancedPastNewline(from position: Int) -> Int {
        guard position < bytes.count else { return position }
        if bytes[position] == Self.carriageReturn,
           position + 1 < bytes.count,
           bytes[position + 1] == Self.lineFeed {
            return position + 2
        }
        return position + 1
    }

    private func hasRun(of byte: UInt8, count: Int, at position: Int) -> Bool {
        guard position + count <= bytes.count else { return false }
        return bytes[position..<(position + count)].allSatisfy { $0 == byte }
    }

    private func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == Self.space || byte == Self.tab
    }

    private func isNewline(at position: Int) -> Bool {
        position < bytes.count && (bytes[position] == Self.lineFeed || bytes[position] == Self.carriageReturn)
    }

    private static func isBareKeyByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x5F
            || byte == 0x2D
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: UInt32(byte - 0x30)
        case 0x41...0x46: UInt32(byte - 0x41 + 10)
        case 0x61...0x66: UInt32(byte - 0x61 + 10)
        default: nil
        }
    }

    private static let tab: UInt8 = 0x09
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let space: UInt8 = 0x20
    private static let comment: UInt8 = 0x23
    private static let doubleQuote: UInt8 = 0x22
    private static let singleQuote: UInt8 = 0x27
    private static let comma: UInt8 = 0x2C
    private static let equals: UInt8 = 0x3D
    private static let openBracket: UInt8 = 0x5B
    private static let backslash: UInt8 = 0x5C
    private static let closeBracket: UInt8 = 0x5D
    private static let openBrace: UInt8 = 0x7B
    private static let closeBrace: UInt8 = 0x7D
}
