import FeatureContracts
import Foundation

/// The receipt-extraction contract used throughout the tests: three minor
/// revisions in major 1, each exercising a different evolution rule.
enum Expense {
    static let categoriesV10 = ["food", "travel", "office", "other"]

    static let v10 = ContractRevision(
        version: ContractVersion(1, 0),
        request: ObjectSchema([
            Field("text", .string(maxLength: 2_000)),
        ]),
        response: ObjectSchema([
            Field("merchant", .string(maxLength: 80)),
            Field("total", .number(0...100_000)),
            Field("category", .enumeration(cases: categoriesV10)),
        ]),
        promptTemplate: "Extract merchant, total and category from:\n{{text}}")

    static let v11 = ContractRevision(
        version: ContractVersion(1, 1),
        request: ObjectSchema([
            Field("text", .string(maxLength: 2_000)),
            Field("locale", .string(maxLength: 16), required: false, default: .string("en_US")),
        ]),
        response: ObjectSchema([
            Field("merchant", .string(maxLength: 80)),
            Field("total", .number(0...100_000)),
            Field("category", .enumeration(cases: categoriesV10 + ["lodging"], fallbacks: ["lodging": "travel"])),
            Field("currency", .string(maxLength: 3), required: false),
        ]),
        promptTemplate: "Extract merchant, total, currency and category (locale {{locale}}) from:\n{{text}}")

    static let v12 = ContractRevision(
        version: ContractVersion(1, 2),
        request: ObjectSchema([
            Field("text", .string(maxLength: 8_000)), // widened: lossy
            Field("locale", .string(maxLength: 16), required: false, default: .string("en_US")),
            Field("hint", .enumeration(cases: ["business", "personal"]), required: false),
        ]),
        response: ObjectSchema([
            Field("merchant", .string(maxLength: 80)),
            Field("total", .number(0...1_000_000)), // widened: lossy
            Field("category", .enumeration(cases: categoriesV10 + ["lodging", "hostel"],
                                           fallbacks: ["hostel": "lodging"])),
            Field("currency", .string(maxLength: 3), required: false),
            Field("confidence", .integer(0...100), required: false),
        ]),
        promptTemplate: "Extract merchant, total, currency, category and confidence (locale {{locale}}, hint {{hint}}) from:\n{{text}}")

    static let v20 = ContractRevision(
        version: ContractVersion(2, 0),
        request: v12.request,
        response: ObjectSchema([
            Field("payee", .string(maxLength: 80)),
            Field("total", .number(0...1_000_000)),
            Field("category", .enumeration(cases: categoriesV10 + ["lodging", "hostel"])),
        ]),
        promptTemplate: v12.promptTemplate)

    static let contract = FeatureContract(id: "expense.extract", residency: .serverAllowed, revisions: [v10, v11, v12])
    static let withMajor = FeatureContract(id: "expense.extract", residency: .serverAllowed, revisions: [v10, v11, v12, v20])

    static func request(_ text: String = "Blue Bottle Coffee 4.50") -> ContractValue {
        .object(["text": .string(text)])
    }

    static func answer(merchant: String = "Blue Bottle", total: Double = 4.5, category: String = "food",
                       currency: String? = nil, confidence: Int? = nil) -> ContractValue {
        var fields: [String: ContractValue] = [
            "merchant": .string(merchant), "total": .double(total), "category": .string(category),
        ]
        if let currency { fields["currency"] = .string(currency) }
        if let confidence { fields["confidence"] = .int(confidence) }
        return .object(fields)
    }

    static func model(_ name: String = "model", availability: ModelAvailability = .available,
                      _ value: ContractValue = answer()) -> ScriptedModel {
        ScriptedModel(name: name, availability: availability) { _, _ in value }
    }

    static func failing(_ name: String = "broken") -> ScriptedModel {
        ScriptedModel(name: name) { _, _ in throw ScriptedModelError("boom") }
    }
}

/// Deterministic generator so property tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Produces random values that are *valid* for a schema.
enum ValueGenerator {
    static func value(for schema: ObjectSchema, using rng: inout SplitMix64) -> ContractValue {
        var fields: [String: ContractValue] = [:]
        for field in schema.fields where field.isRequired || Bool.random(using: &rng) {
            fields[field.name] = value(for: field.type, using: &rng)
        }
        return .object(fields)
    }

    static func value(for type: FieldType, using rng: inout SplitMix64) -> ContractValue {
        switch type {
        case .string(let maxLength):
            let length = Int.random(in: 0...min(maxLength, 12), using: &rng)
            return .string(String((0..<length).map { _ in "abcxyz ".randomElement(using: &rng) ?? "a" }))
        case .integer(let range):
            return .int(Int.random(in: range, using: &rng))
        case .number(let range):
            return .double(Double.random(in: range, using: &rng))
        case .boolean:
            return .bool(Bool.random(using: &rng))
        case .enumeration(let cases, _):
            return .string(cases.randomElement(using: &rng) ?? "")
        case .array(let element, let maxCount):
            let count = Int.random(in: 0...min(maxCount, 3), using: &rng)
            return .array((0..<count).map { _ in value(for: element, using: &rng) })
        case .object(let schema):
            return value(for: schema, using: &rng)
        }
    }
}

/// A transport that returns canned envelopes, for wire-protocol edge cases.
struct CannedTransport: ContractTransport {
    let reply: @Sendable (RequestEnvelope) -> ResponseEnvelope

    func send(_ body: Data) async throws -> Data {
        let request = try JSONDecoder().decode(RequestEnvelope.self, from: body)
        return try JSONEncoder().encode(reply(request))
    }
}

/// Counts calls so tests can prove a tier was *not* used.
actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

struct CountingRemote: RemoteContractAnswering {
    let counter: CallCounter
    let result: Result<RemoteAnswer, ContractClientError>

    func answer(_ request: ContractValue, requestID: String) async throws -> RemoteAnswer {
        await counter.increment()
        return try result.get()
    }
}

struct CountingModel: StructuredModel {
    let name = "counting"
    let counter: CallCounter
    let value: ContractValue
    func availability() async -> ModelAvailability { .available }
    func generate(prompt: String, schema: ObjectSchema) async throws -> ContractValue {
        await counter.increment()
        return value
    }
}
