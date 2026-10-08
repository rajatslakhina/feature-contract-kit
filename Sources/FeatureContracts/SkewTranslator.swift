import Foundation

/// Which half of a revision a value belongs to.
public enum ContractSide: String, Hashable, Sendable, Codable {
    case request
    case response
}

public enum TranslationError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownVersion(ContractVersion)
    case crossMajor(from: ContractVersion, to: ContractVersion)
    case invalidSource([ValidationIssue])
    case missingRequired(path: String, at: ContractVersion)
    case notExpressible(path: String, detail: String, at: ContractVersion)
    case invalidResult([ValidationIssue])

    public var description: String {
        switch self {
        case .unknownVersion(let version): return "unknown version \(version)"
        case .crossMajor(let from, let to): return "\(from) → \(to) crosses a major version"
        case .invalidSource(let issues): return "source invalid: " + issues.map(\.description).joined(separator: "; ")
        case .missingRequired(let path, let version): return "\(path) required by \(version) and has no default"
        case .notExpressible(let path, let detail, let version): return "\(path) not expressible in \(version): \(detail)"
        case .invalidResult(let issues): return "result invalid: " + issues.map(\.description).joined(separator: "; ")
        }
    }
}

/// Moves a value between revisions of the same major, one revision at a
/// time, in either direction.
///
/// Two-sided skew is why both directions exist. A server newer than the app
/// *downgrades* its answer to the app's version; an app newer than the
/// server *downgrades* its request to the server's version and then
/// *upgrades* the server's answer back to its own. Walking one revision at a
/// time means each step only has to be correct for adjacent revisions,
/// which is exactly the pair `ContractLinter` checks — so the linter's
/// guarantee composes across any distance.
public enum SkewTranslator {
    public static func translate(_ value: ContractValue,
                                 side: ContractSide,
                                 in contract: FeatureContract,
                                 from: ContractVersion,
                                 to: ContractVersion) throws -> ContractValue {
        guard let source = contract.revision(from) else { throw TranslationError.unknownVersion(from) }
        guard let target = contract.revision(to) else { throw TranslationError.unknownVersion(to) }
        guard from.major == to.major else { throw TranslationError.crossMajor(from: from, to: to) }

        let sourceIssues = Validator.validate(value, against: schema(source, side))
        guard sourceIssues.isEmpty else { throw TranslationError.invalidSource(sourceIssues) }

        // Same revision on both sides still gets one pass against its own
        // schema, so defaults are filled the same way native or skewed.
        var current = from == to
            ? try translateObject(value, from: schema(source, side), to: schema(source, side), path: "", at: from)
            : value
        var currentRevision = source
        for next in contract.path(from: from, to: to) {
            current = try translateObject(current, from: schema(currentRevision, side), to: schema(next, side),
                                          path: "", at: next.version)
            currentRevision = next
        }

        // Defence in depth: a step that is only correct "by construction"
        // still gets checked, because the construction is a linter that a
        // team can choose to ignore.
        let resultIssues = Validator.validate(current, against: schema(target, side))
        guard resultIssues.isEmpty else { throw TranslationError.invalidResult(resultIssues) }
        return current
    }

    static func schema(_ revision: ContractRevision, _ side: ContractSide) -> ObjectSchema {
        side == .request ? revision.request : revision.response
    }

    private static func translateObject(_ value: ContractValue, from: ObjectSchema, to: ObjectSchema,
                                        path: String, at version: ContractVersion) throws -> ContractValue {
        guard let fields = value.objectValue else {
            throw TranslationError.notExpressible(path: path.isEmpty ? "$" : path, detail: "not an object", at: version)
        }
        var result: [String: ContractValue] = [:]
        for target in to.fields {
            let fieldPath = path.isEmpty ? target.name : path + "." + target.name
            if let present = fields[target.name], present != .null, let sourceField = from.field(named: target.name) {
                result[target.name] = try translateValue(present, from: sourceField.type, to: target.type,
                                                         path: fieldPath, at: version)
            } else if let fallback = target.defaultValue {
                result[target.name] = fallback
            } else if target.isRequired {
                throw TranslationError.missingRequired(path: fieldPath, at: version)
            }
            // Optional, absent, no default: stays absent.
        }
        // Fields the target does not know are dropped: that is the
        // definition of an older reader.
        return .object(result)
    }

    private static func translateValue(_ value: ContractValue, from: FieldType, to: FieldType,
                                       path: String, at version: ContractVersion) throws -> ContractValue {
        guard from.kind == to.kind else {
            throw TranslationError.notExpressible(path: path, detail: "type changed \(from.kind) → \(to.kind)", at: version)
        }
        switch (from, to) {
        case (.enumeration(let sourceCases, let fallbacks), .enumeration(let targetCases, _)):
            guard case .string(let raw) = value else {
                throw TranslationError.notExpressible(path: path, detail: "enum value is not a string", at: version)
            }
            if targetCases.contains(raw) { return value }
            // Follow the writer's fallback chain (hostel → lodging → travel).
            // Bounded by the number of cases, so a cycle cannot spin forever.
            var current = raw
            for _ in 0...sourceCases.count {
                guard let next = fallbacks[current] else { break }
                current = next
                if targetCases.contains(current) { return .string(current) }
            }
            throw TranslationError.notExpressible(path: path, detail: "case '\(raw)' has no fallback here", at: version)
        case (.array(let sourceElement, _), .array(let targetElement, let maxCount)):
            guard case .array(let items) = value else {
                throw TranslationError.notExpressible(path: path, detail: "not an array", at: version)
            }
            guard items.count <= maxCount else {
                throw TranslationError.notExpressible(path: path, detail: "\(items.count) items > \(maxCount)", at: version)
            }
            var translated: [ContractValue] = []
            translated.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                translated.append(try translateValue(item, from: sourceElement, to: targetElement,
                                                     path: "\(path)[\(index)]", at: version))
            }
            return .array(translated)
        case (.object(let sourceSchema), .object(let targetSchema)):
            return try translateObject(value, from: sourceSchema, to: targetSchema, path: path, at: version)
        default:
            // Scalars: the value either fits the target's constraints or the
            // older reader would reject it. Never clamp: a clamped total is
            // a wrong total that validates.
            let issues = Validator.validate(value, as: to, path: path)
            if let first = issues.first {
                throw TranslationError.notExpressible(path: path, detail: first.detail, at: version)
            }
            return value
        }
    }
}
