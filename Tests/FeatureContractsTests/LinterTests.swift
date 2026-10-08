@testable import FeatureContracts
import XCTest

final class LinterTests: XCTestCase {
    private func rules(_ findings: [LintFinding], _ severity: LintFinding.Severity = .breaking) -> Set<String> {
        Set(findings.filter { $0.severity == severity }.map(\.rule))
    }

    private func revision(_ minor: Int, request: [Field] = [Field("text", .string(maxLength: 10))],
                          response: [Field]) -> ContractRevision {
        ContractRevision(version: ContractVersion(1, minor), request: ObjectSchema(request),
                         response: ObjectSchema(response), promptTemplate: "p")
    }

    func testShippedHistoryIsMergeableAndReportsItsLossyWidenings() {
        let report = ContractLinter.lint(Expense.contract)
        XCTAssertTrue(report.isMergeable, report.breaking.map(\.description).joined(separator: "\n"))
        // The two deliberate widenings in v1.2 must surface as lossy, not vanish.
        XCTAssertEqual(rules(report.findings, .lossy), ["widened-max-length", "widened-range"])
        let lossyPaths = Set(report.findings.filter { $0.severity == .lossy }.map(\.path))
        XCTAssertEqual(lossyPaths, ["text", "total"])
    }

    func testMajorBumpIsANoteNotAFailure() {
        let report = ContractLinter.lint(Expense.withMajor)
        XCTAssertTrue(report.isMergeable)
        XCTAssertTrue(report.findings.contains { $0.rule == "major-bump" && $0.severity == .note })
        // The rename inside v2.0 would be breaking within a major; across one it is not reported.
        XCTAssertFalse(report.findings.contains { $0.path == "merchant" && $0.severity == .breaking })
    }

    func testEveryBreakingRuleFires() {
        let base = revision(0, response: [
            Field("a", .string(maxLength: 10)),
            Field("b", .integer(0...10)),
            Field("c", .enumeration(cases: ["x", "y"])),
            Field("d", .array(of: .string(maxLength: 5), maxCount: 4)),
            Field("e", .boolean, required: false),
            Field("f", .boolean),
            Field("g", .object(ObjectSchema([Field("inner", .integer(0...5))]))),
        ])
        let cases: [(String, [Field])] = [
            ("removed-required-field", [Field("b", .integer(0...10)), Field("c", .enumeration(cases: ["x", "y"])),
                                        Field("d", .array(of: .string(maxLength: 5), maxCount: 4)),
                                        Field("e", .boolean, required: false), Field("f", .boolean),
                                        Field("g", .object(ObjectSchema([Field("inner", .integer(0...5))])))]),
        ]
        // Each mutation changes exactly one field of `base`.
        func mutate(_ name: String, _ replacement: Field?) -> [Field] {
            base.response.fields.compactMap { $0.name == name ? replacement : $0 }
        }
        let table: [(rule: String, fields: [Field])] = cases + [
            ("type-changed", mutate("a", Field("a", .integer(0...1)))),
            ("narrowed-max-length", mutate("a", Field("a", .string(maxLength: 9)))),
            ("narrowed-range", mutate("b", Field("b", .integer(1...10)))),
            ("removed-enum-case", mutate("c", Field("c", .enumeration(cases: ["x"])))),
            ("added-enum-case-without-fallback", mutate("c", Field("c", .enumeration(cases: ["x", "y", "z"])))),
            ("narrowed-max-count", mutate("d", Field("d", .array(of: .string(maxLength: 5), maxCount: 3)))),
            ("narrowed-max-length", mutate("d", Field("d", .array(of: .string(maxLength: 4), maxCount: 4)))),
            ("optional-became-required", mutate("e", Field("e", .boolean))),
            ("required-became-optional", mutate("f", Field("f", .boolean, required: false))),
            ("narrowed-range", mutate("g", Field("g", .object(ObjectSchema([Field("inner", .integer(0...4))]))))),
            ("added-required-field-without-default", base.response.fields + [Field("h", .boolean)]),
        ]
        for (rule, fields) in table {
            let findings = ContractLinter.compare(base, revision(1, response: fields))
            XCTAssertTrue(rules(findings).contains(rule), "expected \(rule), got \(findings)")
            // Same rules apply to the request side (two-sided skew).
            let requestSide = ContractLinter.compare(
                revision(0, request: base.response.fields, response: []),
                revision(1, request: fields, response: []))
            XCTAssertTrue(rules(requestSide).contains(rule), "request side: expected \(rule)")
        }
    }

    func testAllowedChangesAreNotBreaking() {
        let old = revision(0, response: [Field("c", .enumeration(cases: ["x", "y"])), Field("n", .integer(0...10))])
        let new = revision(1, response: [
            Field("c", .enumeration(cases: ["x", "y", "z", "w"], fallbacks: ["w": "z", "z": "y"])),
            Field("n", .integer(0...10)),
            Field("added", .string(maxLength: 3), required: false),
            Field("addedWithDefault", .boolean, default: .bool(false)),
        ])
        XCTAssertTrue(rules(ContractLinter.compare(old, new)).isEmpty)
    }

    func testChangedDefaultIsReported() {
        let old = revision(0, response: [Field("n", .integer(0...9), required: false, default: .int(1))])
        let new = revision(1, response: [Field("n", .integer(0...9), required: false, default: .int(2))])
        let findings = ContractLinter.compare(old, new)
        XCTAssertTrue(findings.contains { $0.rule == "default-changed" && $0.severity == .note })
        XCTAssertTrue(rules(findings).isEmpty)
    }

    func testFallbackCycleIsBreakingNotAHang() {
        let old = revision(0, response: [Field("c", .enumeration(cases: ["x"]))])
        let new = revision(1, response: [Field("c", .enumeration(cases: ["x", "p", "q"], fallbacks: ["p": "q", "q": "p"]))])
        XCTAssertTrue(rules(ContractLinter.compare(old, new)).contains("added-enum-case-without-fallback"))
    }

    func testSelfCheckCatchesImpossibleSchemas() {
        let bad = ContractRevision(version: ContractVersion(1, 0),
                                   request: ObjectSchema([Field("a", .string(maxLength: -1)), Field("a", .boolean)]),
                                   response: ObjectSchema([
                                       Field("n", .number(0...Double.infinity)),
                                       Field("e", .enumeration(cases: [], fallbacks: ["ghost": "ghost"])),
                                       Field("d", .integer(0...5), default: .int(9)),
                                   ]),
                                   promptTemplate: "")
        let report = ContractLinter.lint(FeatureContract(id: "bad", residency: .serverAllowed, revisions: [bad]))
        XCTAssertFalse(report.isMergeable)
        let messages = report.findings.map(\.detail)
        for expected in ["negative maxLength", "duplicate field name", "number bounds must be finite", "enum has no cases",
                         "fallback from unknown case 'ghost'", "fallback 'ghost' points at itself",
                         "default value fails its own field type"] {
            XCTAssertTrue(messages.contains(expected), "missing: \(expected)")
        }
    }

    func testDuplicateAndEmptyHistories() {
        XCTAssertFalse(ContractLinter.lint(FeatureContract(id: "x", residency: .serverAllowed, revisions: [])).isMergeable)
        let dup = FeatureContract(id: "x", residency: .serverAllowed, revisions: [Expense.v10, Expense.v10])
        XCTAssertTrue(ContractLinter.lint(dup).breaking.contains { $0.rule == "duplicate-version" })
    }

    func testPromptChangeIsReportedWithFingerprints() {
        let findings = ContractLinter.compare(Expense.v10, Expense.v11)
        let note = findings.first { $0.rule == "prompt-changed" }
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.detail.contains(Expense.v11.promptFingerprint) ?? false)
    }

    /// Soundness: for a lint-clean pair, every valid old value upgrades and
    /// comes back unchanged. Then the mutation: narrow one range, and the
    /// linter must flag it *and* some generated value must really fail —
    /// otherwise the rule (or this test) proves nothing.
    func testLintCleanPairsTranslateEveryGeneratedValue() throws {
        var rng = SplitMix64(seed: 0xFEED)
        for _ in 0..<300 {
            let old = ValueGenerator.value(for: Expense.v10.response, using: &rng)
            let up = try SkewTranslator.translate(old, side: .response, in: Expense.contract,
                                                  from: ContractVersion(1, 0), to: ContractVersion(1, 2))
            let back = try SkewTranslator.translate(up, side: .response, in: Expense.contract,
                                                    from: ContractVersion(1, 2), to: ContractVersion(1, 0))
            XCTAssertEqual(back, old)
            let request = ValueGenerator.value(for: Expense.v10.request, using: &rng)
            let upgraded = try SkewTranslator.translate(request, side: .request, in: Expense.contract,
                                                        from: ContractVersion(1, 0), to: ContractVersion(1, 2))
            XCTAssertEqual(upgraded.objectValue?["text"], request.objectValue?["text"])
            XCTAssertEqual(upgraded.objectValue?["locale"], .string("en_US"))

            // The other direction: a v1.2 answer inside v1.0's range must reach a v1.0 app,
            // with exactly the fields v1.0 declares and the category mapped into v1.0's cases.
            guard case .object(var newer) = ValueGenerator.value(for: Expense.v12.response, using: &rng) else {
                return XCTFail("generator produced a non-object")
            }
            newer["total"] = .double(42)
            let down = try SkewTranslator.translate(.object(newer), side: .response, in: Expense.contract,
                                                    from: ContractVersion(1, 2), to: ContractVersion(1, 0))
            XCTAssertEqual(Set(down.objectValue?.keys.map { $0 } ?? []), ["merchant", "total", "category"])
            XCTAssertEqual(down.objectValue?["merchant"], newer["merchant"])
            if case .string(let category)? = down.objectValue?["category"] {
                XCTAssertTrue(Expense.categoriesV10.contains(category))
            } else {
                XCTFail("category missing")
            }
        }
    }

    func testNarrowedRangeIsFlaggedAndReallyFailsAtRuntime() {
        var narrowed = Expense.v11
        narrowed.version = ContractVersion(1, 1)
        narrowed.response.fields = narrowed.response.fields.map {
            $0.name == "total" ? Field("total", .number(50_000...100_000)) : $0
        }
        XCTAssertTrue(rules(ContractLinter.compare(Expense.v10, narrowed)).contains("narrowed-range"))
        let broken = FeatureContract(id: "x", residency: .serverAllowed, revisions: [Expense.v10, narrowed])
        var rng = SplitMix64(seed: 7)
        var failures = 0
        for _ in 0..<200 {
            let old = ValueGenerator.value(for: Expense.v10.response, using: &rng)
            if (try? SkewTranslator.translate(old, side: .response, in: broken,
                                              from: ContractVersion(1, 0), to: ContractVersion(1, 1))) == nil {
                failures += 1
            }
        }
        XCTAssertGreaterThan(failures, 0, "the linter flagged a change that never actually breaks anything")
    }
}
