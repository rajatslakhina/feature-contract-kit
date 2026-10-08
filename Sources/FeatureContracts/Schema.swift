import Foundation

/// The structural type of one field. This is the part of a `@Generable`
/// output (or a request DTO) that both runtimes must agree on.
///
/// Constraints are part of the type on purpose: "an integer between 0 and
/// 100" and "an integer between 0 and 1000" are different contracts for a
/// reader that validates, and the evolution linter treats them that way.
public indirect enum FieldType: Hashable, Sendable {
    case string(maxLength: Int)
    case integer(ClosedRange<Int>)
    case number(ClosedRange<Double>)
    case boolean
    /// `fallbacks` maps a case to the case an *older* reader should see
    /// instead. That is what lets a writer add a case without breaking
    /// readers that predate it (`lodging` → `travel`).
    case enumeration(cases: [String], fallbacks: [String: String] = [:])
    case array(of: FieldType, maxCount: Int)
    case object(ObjectSchema)

    /// A stable name for the kind of type, used in diagnostics and lint.
    public var kind: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .enumeration: return "enum"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

public struct Field: Hashable, Sendable {
    public var name: String
    public var type: FieldType
    public var isRequired: Bool
    /// Filled in when a reader needs the field and the writer did not send
    /// it, in either skew direction. A required field added within a major
    /// version must carry one; the linter enforces that.
    public var defaultValue: ContractValue?

    public init(_ name: String, _ type: FieldType, required: Bool = true, default defaultValue: ContractValue? = nil) {
        self.name = name
        self.type = type
        self.isRequired = required
        self.defaultValue = defaultValue
    }
}

/// An ordered set of fields. Order is presentation only; identity is by name.
public struct ObjectSchema: Hashable, Sendable {
    public var fields: [Field]

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    public func field(named name: String) -> Field? {
        fields.first { $0.name == name }
    }

    /// Problems with the schema on its own, independent of any history:
    /// duplicate names, impossible constraints, defaults that would fail
    /// their own field's validation, fallbacks that point nowhere.
    public func selfCheck(path: String = "") -> [SchemaIssue] {
        var issues: [SchemaIssue] = []
        var seen: Set<String> = []
        for field in fields {
            let fieldPath = path.isEmpty ? field.name : path + "." + field.name
            if field.name.isEmpty { issues.append(.init(path: fieldPath, message: "empty field name")) }
            if !seen.insert(field.name).inserted {
                issues.append(.init(path: fieldPath, message: "duplicate field name"))
            }
            issues += Self.check(type: field.type, path: fieldPath)
            if let defaultValue = field.defaultValue {
                let problems = Validator.validate(defaultValue, as: field.type, path: fieldPath)
                if !problems.isEmpty {
                    issues.append(.init(path: fieldPath, message: "default value fails its own field type"))
                }
            }
        }
        return issues
    }

    private static func check(type: FieldType, path: String) -> [SchemaIssue] {
        switch type {
        case .string(let maxLength):
            return maxLength < 0 ? [.init(path: path, message: "negative maxLength")] : []
        case .integer:
            return [] // ClosedRange cannot be constructed inverted.
        case .number(let range):
            return range.lowerBound.isFinite && range.upperBound.isFinite
                ? [] : [.init(path: path, message: "number bounds must be finite")]
        case .boolean:
            return []
        case .enumeration(let cases, let fallbacks):
            var issues: [SchemaIssue] = []
            if cases.isEmpty { issues.append(.init(path: path, message: "enum has no cases")) }
            if Set(cases).count != cases.count { issues.append(.init(path: path, message: "duplicate enum case")) }
            for (from, to) in fallbacks.sorted(by: { $0.key < $1.key }) {
                if !cases.contains(from) { issues.append(.init(path: path, message: "fallback from unknown case '\(from)'")) }
                if from == to { issues.append(.init(path: path, message: "fallback '\(from)' points at itself")) }
            }
            return issues
        case .array(let element, let maxCount):
            let own: [SchemaIssue] = maxCount < 0 ? [.init(path: path, message: "negative maxCount")] : []
            return own + check(type: element, path: path + "[]")
        case .object(let schema):
            return schema.selfCheck(path: path)
        }
    }
}

public struct SchemaIssue: Hashable, Sendable, CustomStringConvertible {
    public var path: String
    public var message: String
    public var description: String { "\(path): \(message)" }
}

/// `major.minor`. Within a major, every revision must be readable by every
/// other revision's code (two-sided skew). A major bump is the only way to
/// make a breaking change, and it is a fleet-wide event, not a deploy.
public struct ContractVersion: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int

    public init(_ major: Int, _ minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: ContractVersion, rhs: ContractVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "v\(major).\(minor)" }
}
