import Foundation

/// A single parameter value. Encodes as a bare JSON number, string or bool.
public enum ParamValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case number(Double)
    case string(String)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Parameter values must be a number, string or bool")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        }
    }

    public var number: Double? { if case .number(let d) = self { return d }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }

    public var description: String {
        switch self {
        case .number(let d): return fmt(d)
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

extension ParamValue: ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// The value type of a parameter or command field, with its unit.
/// This is what the machine-readable catalog exposes, so it carries units explicitly.
public enum ValueType: Hashable, Sendable {
    case length          // metres
    case angle           // degrees
    case count           // integer
    case number          // unitless number (e.g. opacity 0...1)
    case choice([String])
    case text
    case bool
    case vector          // {x,y,z} in metres
    case id              // object id
    case idList          // [object id]
    case object          // free-form JSON object (documented in description)
    case commandList     // nested array of commands

    public var typeName: String {
        switch self {
        case .length, .angle, .number: return "number"
        case .count: return "integer"
        case .choice, .text, .id: return "string"
        case .bool: return "boolean"
        case .vector, .object: return "object"
        case .idList, .commandList: return "array"
        }
    }

    public var unit: String? {
        switch self {
        case .length, .vector: return "m"
        case .angle: return "deg"
        default: return nil
        }
    }

    public var choices: [String]? { if case .choice(let c) = self { return c }; return nil }
}

/// Specification of one parametric dimension/option of an object kind.
public struct ParamSpec: Hashable, Sendable {
    public let key: String
    public let type: ValueType
    public let defaultValue: ParamValue
    public let min: Double?
    public let max: Double?
    public let help: String

    public init(_ key: String, _ type: ValueType, _ defaultValue: ParamValue, min: Double? = nil, max: Double? = nil, _ help: String) {
        self.key = key; self.type = type; self.defaultValue = defaultValue
        self.min = min; self.max = max; self.help = help
    }

    /// Validates and normalises a value for this parameter. Returns a human-readable error message on failure.
    public func validate(_ value: ParamValue) -> Result<ParamValue, CommandError> {
        switch type {
        case .length, .angle, .number, .count:
            guard case .number(var d) = value else {
                return .failure(.invalidParameter("'\(key)' must be a number\(type.unit.map { " in \($0)" } ?? "")"))
            }
            guard d.isFinite else { return .failure(.invalidParameter("'\(key)' must be finite")) }
            if case .count = type { d = d.rounded() }
            if let lo = min, d < lo - 1e-9 {
                return .failure(.invalidParameter("'\(key)' = \(fmt(d)) is below the minimum \(fmt(lo))\(type.unit.map { " \($0)" } ?? "")"))
            }
            if let hi = max, d > hi + 1e-9 {
                return .failure(.invalidParameter("'\(key)' = \(fmt(d)) is above the maximum \(fmt(hi))\(type.unit.map { " \($0)" } ?? "")"))
            }
            return .success(.number(d))
        case .choice(let options):
            guard case .string(let s) = value, options.contains(s) else {
                return .failure(.invalidParameter("'\(key)' must be one of: \(options.joined(separator: ", "))"))
            }
            return .success(value)
        case .text:
            guard case .string = value else { return .failure(.invalidParameter("'\(key)' must be a string")) }
            return .success(value)
        case .bool:
            guard case .bool = value else { return .failure(.invalidParameter("'\(key)' must be true or false")) }
            return .success(value)
        default:
            return .success(value)
        }
    }
}
