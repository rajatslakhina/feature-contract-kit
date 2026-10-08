@testable import FeatureContracts
import XCTest

final class TranslatorTests: XCTestCase {
    private let v10 = ContractVersion(1, 0)
    private let v11 = ContractVersion(1, 1)
    private let v12 = ContractVersion(1, 2)

    func testUpgradeFillsDefaultsAndDowngradeDropsUnknownFields() throws {
        let up = try SkewTranslator.translate(Expense.request(), side: .request, in: Expense.contract, from: v10, to: v12)
        XCTAssertEqual(up, .object(["text": .string("Blue Bottle Coffee 4.50"), "locale": .string("en_US")]))

        let newAnswer = Expense.answer(currency: "USD", confidence: 91)
        let down = try SkewTranslator.translate(newAnswer, side: .response, in: Expense.contract, from: v12, to: v10)
        XCTAssertEqual(down, Expense.answer())
    }

    func testEnumFallbackChainWalksOneRevisionAtATime() throws {
        let hostel = Expense.answer(category: "hostel")
        let atV11 = try SkewTranslator.translate(hostel, side: .response, in: Expense.contract, from: v12, to: v11)
        XCTAssertEqual(atV11.objectValue?["category"], .string("lodging"))
        let atV10 = try SkewTranslator.translate(hostel, side: .response, in: Expense.contract, from: v12, to: v10)
        XCTAssertEqual(atV10.objectValue?["category"], .string("travel"))
    }

    func testWidenedRangeIsLossyAtRuntimeAndNeverClamped() {
        let big = Expense.answer(total: 450_000)
        XCTAssertThrowsError(try SkewTranslator.translate(big, side: .response, in: Expense.contract, from: v12, to: v11)) { error in
            guard case TranslationError.notExpressible(let path, _, let version) = error else {
                return XCTFail("expected notExpressible, got \(error)")
            }
            XCTAssertEqual(path, "total")
            XCTAssertEqual(version, self.v11)
        }
        let longText = ContractValue.object(["text": .string(String(repeating: "x", count: 5_000))])
        XCTAssertThrowsError(try SkewTranslator.translate(longText, side: .request, in: Expense.contract, from: v12, to: v11))
    }

    func testRejectsInvalidSourceUnknownVersionsAndCrossMajor() {
        XCTAssertThrowsError(try SkewTranslator.translate(.object([:]), side: .response, in: Expense.contract, from: v12, to: v10)) {
            guard case TranslationError.invalidSource = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try SkewTranslator.translate(Expense.answer(), side: .response, in: Expense.contract,
                                                          from: ContractVersion(1, 9), to: v10)) {
            XCTAssertEqual($0 as? TranslationError, .unknownVersion(ContractVersion(1, 9)))
        }
        XCTAssertThrowsError(try SkewTranslator.translate(Expense.answer(), side: .response, in: Expense.withMajor,
                                                          from: v12, to: ContractVersion(2, 0))) {
            XCTAssertEqual($0 as? TranslationError, .crossMajor(from: self.v12, to: ContractVersion(2, 0)))
        }
    }

    func testRemovedRequiredFieldMakesDowngradeImpossible() {
        // A contract the linter would block; the translator must fail loudly, not invent a value.
        let old = ContractRevision(version: v10, request: ObjectSchema([]),
                                   response: ObjectSchema([Field("keep", .boolean), Field("gone", .boolean)]), promptTemplate: "")
        let new = ContractRevision(version: v11, request: ObjectSchema([]),
                                   response: ObjectSchema([Field("keep", .boolean)]), promptTemplate: "")
        let contract = FeatureContract(id: "x", residency: .serverAllowed, revisions: [old, new])
        XCTAssertFalse(ContractLinter.lint(contract).isMergeable)
        XCTAssertThrowsError(try SkewTranslator.translate(.object(["keep": .bool(true)]), side: .response, in: contract,
                                                          from: v11, to: v10)) {
            XCTAssertEqual($0 as? TranslationError, .missingRequired(path: "gone", at: self.v10))
        }
    }

    func testNestedArraysAndObjectsTranslate() throws {
        let item10 = ObjectSchema([Field("sku", .string(maxLength: 8))])
        let item11 = ObjectSchema([Field("sku", .string(maxLength: 8)), Field("qty", .integer(1...99), default: .int(1))])
        let old = ContractRevision(version: v10, request: ObjectSchema([]),
                                   response: ObjectSchema([Field("items", .array(of: .object(item10), maxCount: 5))]), promptTemplate: "")
        let new = ContractRevision(version: v11, request: ObjectSchema([]),
                                   response: ObjectSchema([Field("items", .array(of: .object(item11), maxCount: 5))]), promptTemplate: "")
        let contract = FeatureContract(id: "x", residency: .serverAllowed, revisions: [old, new])
        XCTAssertTrue(ContractLinter.lint(contract).isMergeable)
        let value = ContractValue.object(["items": .array([.object(["sku": .string("A1")]), .object(["sku": .string("B2")])])])
        let up = try SkewTranslator.translate(value, side: .response, in: contract, from: v10, to: v11)
        XCTAssertEqual(up, .object(["items": .array([.object(["sku": .string("A1"), "qty": .int(1)]),
                                                     .object(["sku": .string("B2"), "qty": .int(1)])])]))
        XCTAssertEqual(try SkewTranslator.translate(up, side: .response, in: contract, from: v11, to: v10), value)
    }
}

final class ValidatorTests: XCTestCase {
    private let schema = ObjectSchema([
        Field("n", .integer(0...10)),
        Field("x", .number(-1...1), required: false),
        Field("s", .string(maxLength: 3), required: false),
        Field("tags", .array(of: .enumeration(cases: ["a", "b"]), maxCount: 2), required: false),
    ])

    private func kinds(_ value: ContractValue) -> [ValidationIssue.Kind] {
        Validator.validate(value, against: schema).map(\.kind)
    }

    func testNumericEdgeCasesNeverTrap() {
        XCTAssertEqual(kinds(.object(["n": .double(3.0)])), [])
        XCTAssertEqual(kinds(.object(["n": .double(3.5)])), [.wrongType])
        XCTAssertEqual(kinds(.object(["n": .double(.nan)])), [.wrongType])
        XCTAssertEqual(kinds(.object(["n": .double(.infinity)])), [.wrongType])
        XCTAssertEqual(kinds(.object(["n": .double(1e300)])), [.wrongType])
        XCTAssertEqual(kinds(.object(["n": .int(Int.max)])), [.outOfRange])
        XCTAssertEqual(kinds(.object(["n": .int(Int.min)])), [.outOfRange])
        XCTAssertEqual(kinds(.object(["n": .int(1), "x": .double(.nan)])), [.notFinite])
        XCTAssertEqual(kinds(.object(["n": .int(1), "x": .double(-.infinity)])), [.notFinite])
        XCTAssertEqual(kinds(.object(["n": .int(1), "x": .int(2)])), [.outOfRange])
    }

    func testStructuralIssues() {
        XCTAssertEqual(kinds(.object([:])), [.missingRequired])
        XCTAssertEqual(kinds(.object(["n": .null])), [.missingRequired])
        XCTAssertEqual(kinds(.array([])), [.wrongType])
        XCTAssertEqual(kinds(.object(["n": .int(1), "zzz": .bool(true)])), [.unexpectedField])
        XCTAssertEqual(Validator.validate(.object(["n": .int(1), "zzz": .bool(true)]), against: schema, strict: false), [])
        XCTAssertEqual(kinds(.object(["n": .int(1), "s": .string("abcd")])), [.tooLong])
        XCTAssertEqual(kinds(.object(["n": .int(1), "tags": .array([.string("a"), .string("b"), .string("c")])])),
                       [.tooMany, .unknownCase])
        XCTAssertEqual(kinds(.object(["n": .int(1), "tags": .array([])])), [])
    }

    func testDepthGuardOnValidationAndDecoding() throws {
        var deep = ContractValue.int(0)
        for _ in 0..<40 { deep = .array([deep]) }
        XCTAssertEqual(Validator.validate(.object(["n": deep]), against: schema).map(\.kind), [.tooDeep])

        let json = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        XCTAssertThrowsError(try JSONDecoder().decode(ContractValue.self, from: Data(json.utf8)))
        let shallow = try JSONDecoder().decode(ContractValue.self, from: Data(#"{"a":[1,2.5,"x",true,null]}"#.utf8))
        XCTAssertEqual(shallow, .object(["a": .array([.int(1), .double(2.5), .string("x"), .bool(true), .null])]))
    }

    func testPromptFingerprintIsFNV1a64() {
        // Known FNV-1a 64 vectors: a regression to `Hasher` (per-process
        // random seed) or to a different algorithm changes these.
        func fingerprint(_ template: String) -> String {
            ContractRevision(version: ContractVersion(1, 0), request: ObjectSchema([]), response: ObjectSchema([]),
                             promptTemplate: template).promptFingerprint
        }
        XCTAssertEqual(fingerprint(""), "cbf29ce484222325")
        XCTAssertEqual(fingerprint("a"), "af63dc4c8601ec8c")
        XCTAssertEqual(fingerprint("foobar"), "85944171f73967e8")
    }

    func testPromptRenderingFillsDefaultsAndBlanksAbsentOptionals() {
        let rendered = Expense.v12.renderPrompt(.object(["text": .string("T")]))
        XCTAssertTrue(rendered.contains("(locale en_US, hint )"), rendered)
        XCTAssertFalse(rendered.contains("{{"))
        XCTAssertTrue(rendered.hasSuffix("\nT"))
        // A placeholder naming no request field is a template bug: left visible.
        var typo = Expense.v12
        typo.promptTemplate = "{{txet}} {{text}}"
        XCTAssertEqual(typo.renderPrompt(.object(["text": .string("T")])), "{{txet}} T")
    }

    func testUserTextContainingPlaceholdersIsNotReSubstituted() {
        let rendered = Expense.v12.renderPrompt(.object(["text": .string("note: {{locale}} {{hint}} }}{{"),
                                                         "locale": .string("de_DE")]))
        XCTAssertTrue(rendered.hasSuffix("\nnote: {{locale}} {{hint}} }}{{"), rendered)
        XCTAssertTrue(rendered.contains("(locale de_DE, hint )"), rendered)
        var unterminated = Expense.v12
        unterminated.promptTemplate = "{{text}} and {{oops"
        XCTAssertEqual(unterminated.renderPrompt(.object(["text": .string("T")])), "T and {{oops")
    }

    func testSameVersionTranslationFillsDefaultsLikeTheSkewPath() throws {
        let v12 = ContractVersion(1, 2)
        let native = try SkewTranslator.translate(Expense.request(), side: .request, in: Expense.contract, from: v12, to: v12)
        let skewed = try SkewTranslator.translate(Expense.request(), side: .request, in: Expense.contract,
                                                  from: ContractVersion(1, 0), to: v12)
        XCTAssertEqual(native, skewed)
        XCTAssertEqual(native.objectValue?["locale"], .string("en_US"))
    }

    func testDescriptionOfHostileNestingIsBounded() {
        var deep = ContractValue.int(0)
        for _ in 0..<300 { deep = .array([deep]) } // far past maximumDepth (32), shallow enough that releasing it cannot overflow a 512 KB cooperative-thread stack
        let text = deep.description
        XCTAssertTrue(text.contains("…"))
        XCTAssertLessThan(text.count, 200)
    }

    func testSaturatingHelpers() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.min, 2), Int.min)
        XCTAssertEqual(Saturating.ratio(5, 0, scale: 10_000), 0)
        XCTAssertEqual(Saturating.ratio(Int.min, -1, scale: 1), 0)
        XCTAssertEqual(Saturating.ratio(1, 3, scale: 10_000), 3_333)
        XCTAssertEqual(TokenEstimate.of(""), 0)
        XCTAssertEqual(TokenEstimate.of("abcde"), 2)
    }
}

final class DefenceInDepthTests: XCTestCase {
    /// A history the linter rejects (an invalid default) must still never
    /// produce an invalid value: the translator's final validation catches
    /// what the per-step walk lets through.
    func testInvalidDefaultIsCaughtByFinalValidation() {
        let v10 = ContractVersion(1, 0)
        let v11 = ContractVersion(1, 1)
        let old = ContractRevision(version: v10, request: ObjectSchema([]),
                                   response: ObjectSchema([Field("a", .boolean)]), promptTemplate: "")
        let new = ContractRevision(version: v11, request: ObjectSchema([]),
                                   response: ObjectSchema([Field("a", .boolean), Field("n", .integer(0...5), default: .int(9))]),
                                   promptTemplate: "")
        let contract = FeatureContract(id: "x", residency: .serverAllowed, revisions: [old, new])
        XCTAssertFalse(ContractLinter.lint(contract).isMergeable)
        XCTAssertThrowsError(try SkewTranslator.translate(.object(["a": .bool(true)]), side: .response, in: contract,
                                                          from: v10, to: v11)) {
            guard case TranslationError.invalidResult(let issues) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(issues.map(\.path), ["n"])
        }
    }
}
