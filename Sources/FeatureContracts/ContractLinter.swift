import Foundation

public struct LintFinding: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable, Comparable {
        /// Information only (a major bump, which is allowed to break).
        case note
        /// Allowed, but `SkewTranslator` can fail at runtime for *some*
        /// values (a widened range: an old reader rejects the new extremes).
        case lossy
        /// Some valid value cannot cross the skew at all. Blocks the merge.
        case breaking

        private var rank: Int { self == .note ? 0 : self == .lossy ? 1 : 2 }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var severity: Severity
    public var side: ContractSide?
    public var from: ContractVersion?
    public var to: ContractVersion?
    public var path: String
    public var rule: String
    public var detail: String

    public var description: String {
        let versions = [from, to].compactMap { $0?.description }.joined(separator: "→")
        let sidePart = side.map { "\($0.rawValue) " } ?? ""
        return "[\(severity.rawValue)] \(versions) \(sidePart)\(path): \(rule) — \(detail)"
    }
}

/// Enforces the evolution rules that make two-sided skew safe, in CI, on
/// the shared contract package. Run it as a test (`XCTAssertTrue(report
/// .isMergeable)`) so a breaking schema change fails the build the same way
/// a type error does.
///
/// The rules are deliberately the *same* for requests and responses.
/// Textbook variance says requests may only widen and responses may only
/// narrow; that holds when one side is always newer. In a mobile fleet it is
/// not: a server can be older than a just-released app for a whole deploy
/// window. Then the app downgrades its request and upgrades the response,
/// so both halves must survive both directions.
public enum ContractLinter {
    public struct Report: Hashable, Sendable {
        public var findings: [LintFinding]
        public var isMergeable: Bool { !findings.contains { $0.severity == .breaking } }
        public var breaking: [LintFinding] { findings.filter { $0.severity == .breaking } }
    }

    public static func lint(_ contract: FeatureContract) -> Report {
        var findings: [LintFinding] = []
        if contract.revisions.isEmpty {
            findings.append(.init(severity: .breaking, side: nil, from: nil, to: nil, path: "$",
                                  rule: "no-revisions", detail: "a contract needs at least one revision"))
        }
        var seen: Set<ContractVersion> = []
        for revision in contract.revisions {
            if !seen.insert(revision.version).inserted {
                findings.append(.init(severity: .breaking, side: nil, from: nil, to: revision.version, path: "$",
                                      rule: "duplicate-version", detail: "two revisions claim \(revision.version)"))
            }
            for side in [ContractSide.request, .response] {
                for issue in SkewTranslator.schema(revision, side).selfCheck() {
                    findings.append(.init(severity: .breaking, side: side, from: nil, to: revision.version,
                                          path: issue.path, rule: "schema-self-check", detail: issue.message))
                }
            }
        }
        for (old, new) in zip(contract.revisions, contract.revisions.dropFirst()) {
            findings += compare(old, new)
        }
        return Report(findings: findings)
    }

    /// Checks one adjacent pair. Exposed so a PR bot can lint a proposed
    /// revision against the current head without building a whole contract.
    public static func compare(_ old: ContractRevision, _ new: ContractRevision) -> [LintFinding] {
        guard old.version.major == new.version.major else {
            return [.init(severity: .note, side: nil, from: old.version, to: new.version, path: "$",
                          rule: "major-bump", detail: "breaking changes allowed; old major must stay served until retired")]
        }
        var findings: [LintFinding] = []
        for side in [ContractSide.request, .response] {
            var context = Context(side: side, from: old.version, to: new.version, findings: [])
            context.compareObjects(SkewTranslator.schema(old, side), SkewTranslator.schema(new, side), path: "")
            findings += context.findings
        }
        if old.promptTemplate != new.promptTemplate {
            findings.append(.init(severity: .note, side: nil, from: old.version, to: new.version, path: "$",
                                  rule: "prompt-changed",
                                  detail: "fingerprint \(old.promptFingerprint) → \(new.promptFingerprint); rerun parity eval"))
        }
        return findings
    }

    private struct Context {
        let side: ContractSide
        let from: ContractVersion
        let to: ContractVersion
        var findings: [LintFinding]

        mutating func add(_ severity: LintFinding.Severity, _ path: String, _ rule: String, _ detail: String) {
            findings.append(.init(severity: severity, side: side, from: from, to: to,
                                  path: path.isEmpty ? "$" : path, rule: rule, detail: detail))
        }

        mutating func compareObjects(_ old: ObjectSchema, _ new: ObjectSchema, path: String) {
            for oldField in old.fields {
                let fieldPath = path.isEmpty ? oldField.name : path + "." + oldField.name
                guard let newField = new.field(named: oldField.name) else {
                    // Downgrading a new value to the old revision must
                    // produce this field from nothing.
                    if oldField.isRequired && oldField.defaultValue == nil {
                        add(.breaking, fieldPath, "removed-required-field",
                            "old readers require it and it has no default")
                    } else {
                        add(.lossy, fieldPath, "removed-field", "old values lose it on upgrade")
                    }
                    continue
                }
                // Upgrading an old value that omitted an optional field.
                if newField.isRequired && !oldField.isRequired && newField.defaultValue == nil {
                    add(.breaking, fieldPath, "optional-became-required", "old writers may omit it; give it a default")
                }
                // Downgrading a new value that omitted a now-optional field.
                if oldField.isRequired && !newField.isRequired && oldField.defaultValue == nil {
                    add(.breaking, fieldPath, "required-became-optional", "old readers require it; give the old field a default")
                }
                compareTypes(oldField.type, newField.type, path: fieldPath)
            }
            for newField in new.fields where old.field(named: newField.name) == nil {
                let fieldPath = path.isEmpty ? newField.name : path + "." + newField.name
                // Upgrading an old value, which never had this field.
                if newField.isRequired && newField.defaultValue == nil {
                    add(.breaking, fieldPath, "added-required-field-without-default",
                        "values written at \(from) cannot be upgraded")
                }
            }
        }

        mutating func compareTypes(_ old: FieldType, _ new: FieldType, path: String) {
            guard old.kind == new.kind else {
                add(.breaking, path, "type-changed", "\(old.kind) → \(new.kind)")
                return
            }
            switch (old, new) {
            case (.string(let oldMax), .string(let newMax)):
                if newMax < oldMax { add(.breaking, path, "narrowed-max-length", "\(oldMax) → \(newMax)") }
                if newMax > oldMax { add(.lossy, path, "widened-max-length", "\(oldMax) → \(newMax); long values cannot downgrade") }
            case (.integer(let oldRange), .integer(let newRange)):
                compareRanges(contains: newRange.lowerBound <= oldRange.lowerBound && newRange.upperBound >= oldRange.upperBound,
                              equal: oldRange == newRange, path: path, detail: "\(oldRange) → \(newRange)")
            case (.number(let oldRange), .number(let newRange)):
                compareRanges(contains: newRange.lowerBound <= oldRange.lowerBound && newRange.upperBound >= oldRange.upperBound,
                              equal: oldRange == newRange, path: path, detail: "\(oldRange) → \(newRange)")
            case (.enumeration(let oldCases, _), .enumeration(let newCases, let fallbacks)):
                for removed in oldCases where !newCases.contains(removed) {
                    add(.breaking, path, "removed-enum-case", "'\(removed)' cannot be upgraded")
                }
                for added in newCases where !oldCases.contains(added) {
                    if !Self.resolves(added, fallbacks: fallbacks, into: oldCases, bound: newCases.count) {
                        add(.breaking, path, "added-enum-case-without-fallback",
                            "'\(added)' needs a fallback chain into \(from)'s cases")
                    }
                }
            case (.array(let oldElement, let oldMax), .array(let newElement, let newMax)):
                if newMax < oldMax { add(.breaking, path, "narrowed-max-count", "\(oldMax) → \(newMax)") }
                if newMax > oldMax { add(.lossy, path, "widened-max-count", "\(oldMax) → \(newMax); long arrays cannot downgrade") }
                compareTypes(oldElement, newElement, path: path + "[]")
            case (.object(let oldSchema), .object(let newSchema)):
                compareObjects(oldSchema, newSchema, path: path)
            default:
                break // .boolean, identical kinds with no constraints.
            }
        }

        mutating func compareRanges(contains: Bool, equal: Bool, path: String, detail: String) {
            if !contains {
                add(.breaking, path, "narrowed-range", detail + "; old values may not upgrade")
            } else if !equal {
                add(.lossy, path, "widened-range", detail + "; new extremes cannot downgrade")
            }
        }

        static func resolves(_ start: String, fallbacks: [String: String], into cases: [String], bound: Int) -> Bool {
            var current = start
            for _ in 0...max(0, bound) {
                guard let next = fallbacks[current] else { return false }
                if cases.contains(next) { return true }
                current = next
            }
            return false
        }
    }
}
