import Foundation

/// How one response field is compared between the two tiers.
public enum ParityRule: Hashable, Sendable {
    case exact
    /// Numbers agree when `|a − b| ≤ tolerance`. A non-finite or negative
    /// tolerance is treated as `exact` rather than as "anything goes".
    case tolerance(Double)
    /// Strings agree after lowercasing and collapsing whitespace.
    case normalizedText
    /// Not compared (free text like a summary, where parity is a judgment).
    case ignore
}

public struct GoldenCase: Hashable, Sendable, Identifiable {
    public var id: String
    public var request: ContractValue

    public init(id: String, request: ContractValue) {
        self.id = id
        self.request = request
    }
}

public struct ParityReport: Hashable, Sendable {
    public enum Verdict: Hashable, Sendable {
        case pass
        case fail(String)
        /// Nothing was compared. Never reported as a pass: an eval with zero
        /// cases is the easiest way to get a green build that proves nothing.
        case inconclusive(String)

        public var isPass: Bool { self == .pass }
    }

    public struct CaseResult: Hashable, Sendable, Identifiable {
        public var id: String
        public var compared: Int
        public var agreed: Int
        public var differences: [String]
        public var schemaViolations: [String]
    }

    public var cases: [CaseResult]
    public var agreementBasisPoints: Int
    public var thresholdBasisPoints: Int
    public var verdict: Verdict
}

/// Runs the same golden inputs through both tiers with the same rendered
/// prompt and fails the build when their structured outputs diverge.
///
/// The point is not that the two models are equally good. It is that the
/// app's UI is written against one schema and has to behave the same
/// whichever tier answered; a field that agrees 60% of the time across
/// tiers is a field the UI cannot trust, and the place to find out is CI,
/// not a support ticket.
public struct ParityEval: Sendable {
    public var revision: ContractRevision
    /// Top-level response fields. Fields with no rule are compared `.exact`.
    public var rules: [String: ParityRule]
    public var thresholdBasisPoints: Int

    public init(revision: ContractRevision, rules: [String: ParityRule], thresholdBasisPoints: Int) {
        self.revision = revision
        self.rules = rules
        self.thresholdBasisPoints = min(max(thresholdBasisPoints, 0), 10_000)
    }

    public func run(_ cases: [GoldenCase], reference: any StructuredModel, candidate: any StructuredModel) async -> ParityReport {
        var results: [ParityReport.CaseResult] = []
        var comparedTotal = 0
        var agreedTotal = 0
        var violations = 0

        for golden in cases {
            let prompt = revision.renderPrompt(golden.request)
            let left = await Self.generate(reference, prompt, revision.response)
            let right = await Self.generate(candidate, prompt, revision.response)
            var result = ParityReport.CaseResult(id: golden.id, compared: 0, agreed: 0, differences: [], schemaViolations: [])
            for (name, outcome) in [(reference.name, left), (candidate.name, right)] {
                if case .failure(let message) = outcome { result.schemaViolations.append("\(name): \(message)") }
            }
            for field in revision.response.fields {
                let rule = rules[field.name] ?? .exact
                if rule == .ignore { continue }
                result.compared += 1
                guard case .success(let a) = left, case .success(let b) = right else { continue }
                if Self.agrees(a[field.name], b[field.name], rule) {
                    result.agreed += 1
                } else {
                    let lhs = a[field.name]?.description ?? "absent"
                    let rhs = b[field.name]?.description ?? "absent"
                    result.differences.append("\(field.name): \(lhs) ≠ \(rhs)")
                }
            }
            comparedTotal = Saturating.add(comparedTotal, result.compared)
            agreedTotal = Saturating.add(agreedTotal, result.agreed)
            if !result.schemaViolations.isEmpty { violations += 1 }
            results.append(result)
        }

        let agreement = Saturating.ratio(agreedTotal, comparedTotal, scale: 10_000)
        let verdict: ParityReport.Verdict
        if cases.isEmpty {
            verdict = .inconclusive("no golden cases")
        } else if comparedTotal == 0 {
            verdict = .inconclusive("every field is ignored")
        } else if violations > 0 {
            verdict = .fail("\(violations) case(s) violated the schema")
        } else if agreement < thresholdBasisPoints {
            verdict = .fail("agreement \(agreement) bp < threshold \(thresholdBasisPoints) bp")
        } else {
            verdict = .pass
        }
        return ParityReport(cases: results, agreementBasisPoints: agreement,
                            thresholdBasisPoints: thresholdBasisPoints, verdict: verdict)
    }

    private enum Outcome {
        case success([String: ContractValue])
        case failure(String)
    }

    private static func generate(_ model: any StructuredModel, _ prompt: String, _ schema: ObjectSchema) async -> Outcome {
        do {
            let value = try await model.generate(prompt: prompt, schema: schema)
            let issues = Validator.validate(value, against: schema)
            guard issues.isEmpty, let fields = value.objectValue else {
                return .failure(issues.map(\.description).joined(separator: "; "))
            }
            return .success(fields)
        } catch {
            return .failure(String(describing: error))
        }
    }

    static func agrees(_ a: ContractValue?, _ b: ContractValue?, _ rule: ParityRule) -> Bool {
        let left = a == .null ? nil : a
        let right = b == .null ? nil : b
        guard let left, let right else { return left == nil && right == nil }
        switch rule {
        case .ignore:
            return true
        case .exact:
            return left == right
        case .tolerance(let tolerance):
            guard tolerance.isFinite, tolerance >= 0 else { return left == right }
            guard let x = number(left), let y = number(right) else { return left == right }
            return abs(x - y) <= tolerance
        case .normalizedText:
            guard case .string(let x) = left, case .string(let y) = right else { return left == right }
            return normalize(x) == normalize(y)
        }
    }

    private static func number(_ value: ContractValue) -> Double? {
        switch value {
        case .int(let raw): return Double(raw)
        case .double(let raw): return raw.isFinite ? raw : nil
        default: return nil
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
