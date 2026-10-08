import Foundation

public struct ValidationIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable {
        case wrongType, missingRequired, unexpectedField, outOfRange, tooLong, tooMany, unknownCase, tooDeep, notFinite
    }
    public var path: String
    public var kind: Kind
    public var detail: String
    public var description: String { "\(path.isEmpty ? "$" : path): \(kind.rawValue) (\(detail))" }
}

/// Validates a value against a schema. The router runs this on *every*
/// model answer, on-device or server, before anything reaches the caller.
/// A model's output is untrusted input that happens to be well-formatted.
public enum Validator {
    public static func validate(_ value: ContractValue, against schema: ObjectSchema, strict: Bool = true) -> [ValidationIssue] {
        if value.depth() > ContractValue.maximumDepth {
            return [ValidationIssue(path: "", kind: .tooDeep, detail: "limit \(ContractValue.maximumDepth)")]
        }
        return validateObject(value, schema, path: "", strict: strict)
    }

    static func validate(_ value: ContractValue, as type: FieldType, path: String, strict: Bool = true) -> [ValidationIssue] {
        switch type {
        case .string(let maxLength):
            guard case .string(let text) = value else { return [wrong(path, "string", value)] }
            return text.count > maxLength ? [.init(path: path, kind: .tooLong, detail: "\(text.count) > \(maxLength)")] : []
        case .integer(let range):
            guard let number = integer(value) else { return [wrong(path, "integer", value)] }
            return range.contains(number) ? [] : [.init(path: path, kind: .outOfRange, detail: "\(number) ∉ \(range)")]
        case .number(let range):
            let number: Double
            switch value {
            case .int(let raw): number = Double(raw)
            case .double(let raw): number = raw
            default: return [wrong(path, "number", value)]
            }
            guard number.isFinite else { return [.init(path: path, kind: .notFinite, detail: "\(number)")] }
            return range.contains(number) ? [] : [.init(path: path, kind: .outOfRange, detail: "\(number) ∉ \(range)")]
        case .boolean:
            guard case .bool = value else { return [wrong(path, "boolean", value)] }
            return []
        case .enumeration(let cases, _):
            guard case .string(let text) = value else { return [wrong(path, "enum", value)] }
            return cases.contains(text) ? [] : [.init(path: path, kind: .unknownCase, detail: "'\(text)'")]
        case .array(let element, let maxCount):
            guard case .array(let items) = value else { return [wrong(path, "array", value)] }
            var issues: [ValidationIssue] = []
            if items.count > maxCount { issues.append(.init(path: path, kind: .tooMany, detail: "\(items.count) > \(maxCount)")) }
            for (index, item) in items.enumerated() {
                issues += validate(item, as: element, path: "\(path)[\(index)]", strict: strict)
            }
            return issues
        case .object(let schema):
            return validateObject(value, schema, path: path, strict: strict)
        }
    }

    /// Integral JSON numbers sometimes arrive as `3.0`. `Int(exactly:)`
    /// answers `nil` for NaN, infinities, fractions and out-of-range values
    /// instead of trapping the way `Int(_: Double)` would.
    static func integer(_ value: ContractValue) -> Int? {
        switch value {
        case .int(let raw): return raw
        case .double(let raw): return Int(exactly: raw)
        default: return nil
        }
    }

    private static func validateObject(_ value: ContractValue, _ schema: ObjectSchema, path: String, strict: Bool) -> [ValidationIssue] {
        guard let fields = value.objectValue else { return [wrong(path, "object", value)] }
        var issues: [ValidationIssue] = []
        for field in schema.fields {
            let fieldPath = path.isEmpty ? field.name : path + "." + field.name
            guard let present = fields[field.name], present != .null else {
                if field.isRequired { issues.append(.init(path: fieldPath, kind: .missingRequired, detail: field.type.kind)) }
                continue
            }
            issues += validate(present, as: field.type, path: fieldPath, strict: strict)
        }
        if strict {
            let known = Set(schema.fields.map(\.name))
            for key in fields.keys.sorted() where !known.contains(key) {
                issues.append(.init(path: path.isEmpty ? key : path + "." + key, kind: .unexpectedField, detail: "not in schema"))
            }
        }
        return issues
    }

    private static func wrong(_ path: String, _ expected: String, _ got: ContractValue) -> ValidationIssue {
        ValidationIssue(path: path, kind: .wrongType, detail: "expected \(expected)")
    }
}
