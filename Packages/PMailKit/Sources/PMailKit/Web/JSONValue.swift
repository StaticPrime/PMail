import Foundation

/// A JSON value from (or for) a web service. Reading it never crashes: asking for a key or an index that isn't there,
/// or for the wrong kind of value, gives `.null` or nil, so a malformed answer just comes out empty.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Reads JSON text. Empty (or all-whitespace) data reads as `.null`.
    static func parse(_ data: Data) throws -> JSONValue {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return .null }
        return JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Converts what `JSONSerialization` reads into a value, keeping true and false apart from 1 and 0.
    init(any value: Any) {
        switch value {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// The value as JSON text, with keys sorted so the same value always reads the same.
    func encoded() -> Data {
        let object = foundationValue
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject([object]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return Data("null".utf8) }
        return data
    }

    private var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case let .bool(value):
            return NSNumber(value: value)
        case let .number(value):
            guard value.isFinite else { return NSNull() }
            if let integer = Int(exactly: value) { return NSNumber(value: integer) }
            return NSNumber(value: value)
        case let .string(value):
            return value
        case let .array(values):
            return values.map(\.foundationValue)
        case let .object(values):
            return values.mapValues(\.foundationValue)
        }
    }

    // MARK: Reading

    /// The value for a key of an object, or `.null`.
    subscript(key: String) -> JSONValue {
        if case let .object(object) = self { return object[key] ?? .null }
        return .null
    }

    /// The value at an index of an array, or `.null`.
    subscript(index: Int) -> JSONValue {
        if case let .array(array) = self, array.indices.contains(index) { return array[index] }
        return .null
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The string, unless it's missing or only whitespace (many services send "" for "not set").
    var nonEmpty: String? {
        guard let value = string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A number, or a string holding one (some services send big numbers as strings).
    var double: Double? {
        switch self {
        case let .number(value): return value.isFinite ? value : nil
        case let .string(value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// A whole number, or a string holding one.
    var int: Int? {
        switch self {
        case let .number(value):
            guard value.isFinite, value > -9.0e18, value < 9.0e18 else { return nil }
            return Int(value)
        case let .string(value):
            return Int(value.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The elements of an array; empty for anything else.
    var array: [JSONValue] {
        if case let .array(values) = self { return values }
        return []
    }

    var object: [String: JSONValue]? {
        if case let .object(values) = self { return values }
        return nil
    }

    /// The strings in an array, skipping anything that isn't one.
    var strings: [String] { array.compactMap(\.string) }

    var isNull: Bool { self == .null }

    // MARK: Building

    /// An array of strings.
    init(_ strings: [String]) {
        self = .array(strings.map(JSONValue.string))
    }

    /// A whole number.
    init(_ number: Int) {
        self = .number(Double(number))
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .number(Double(value))
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
