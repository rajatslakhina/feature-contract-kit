import Foundation

/// A JSON-shaped value that both runtimes exchange: the iOS app (whose
/// on-device model emits it) and the Swift server (whose hosted model emits it).
///
/// Integers and doubles are kept distinct so that a schema can say "integer"
/// and mean it. A JSON number with no fractional part decodes as `.int`.
public enum ContractValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ContractValue])
    case object([String: ContractValue])

    /// Deepest nesting `ContractValue` will decode. Model output is untrusted
    /// input: an adversarial or degenerate generation must not be able to
    /// exhaust the stack in the decoder or in any recursive walk.
    public static let maximumDepth = 32

    public var objectValue: [String: ContractValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    /// Nesting depth (a scalar is 1). Computed iteratively-bounded: stops
    /// counting once `limit` is exceeded, so it is cheap on hostile input.
    public func depth(limit: Int = ContractValue.maximumDepth) -> Int {
        func walk(_ value: ContractValue, _ level: Int) -> Int {
            if level > limit { return level }
            switch value {
            case .array(let items):
                return items.reduce(level) { max($0, walk($1, level + 1)) }
            case .object(let fields):
                return fields.values.reduce(level) { max($0, walk($1, level + 1)) }
            default:
                return level
            }
        }
        return walk(self, 1)
    }
}

extension ContractValue: Codable {
    public init(from decoder: Decoder) throws {
        // `codingPath` grows by one per nesting level, so it doubles as a
        // depth guard that runs *before* recursing into a hostile payload.
        if decoder.codingPath.count >= ContractValue.maximumDepth {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Nesting deeper than \(ContractValue.maximumDepth)"))
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([ContractValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: ContractValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a contract value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension ContractValue: CustomStringConvertible {
    /// Deterministic, key-sorted rendering, used in traces and the demo UI.
    /// Bounded like every other walk over a `ContractValue`: nesting past
    /// `maximumDepth` renders as `…`, so describing hostile model output
    /// (for a log line or a trace) cannot exhaust the stack.
    public var description: String { render(level: 1) }

    private func render(level: Int) -> String {
        if level > ContractValue.maximumDepth { return "…" }
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let items): return "[" + items.map { $0.render(level: level + 1) }.joined(separator: ", ") + "]"
        case .object(let fields):
            let body = fields.keys.sorted().compactMap { key in fields[key].map { "\(key): \($0.render(level: level + 1))" } }
            return "{" + body.joined(separator: ", ") + "}"
        }
    }
}

/// Small saturating helpers. Every arithmetic path reachable from the public
/// API that could trap on overflow goes through one of these instead.
enum Saturating {
    static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        if !overflow { return result }
        return b > 0 ? Int.max : Int.min
    }

    static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        if !overflow { return result }
        return (a < 0) == (b < 0) ? Int.max : Int.min
    }

    /// `numerator * scale / denominator`, rounded down, with a zero (or
    /// negative) denominator answering `0` instead of trapping.
    static func ratio(_ numerator: Int, _ denominator: Int, scale: Int) -> Int {
        guard denominator > 0 else { return 0 }
        let scaled = multiply(numerator, scale)
        return scaled / denominator // denominator > 0, so no `Int.min / -1`.
    }
}
