import FeatureContracts // deliberately not @testable: this file only sees the public API.
import XCTest

/// Proves the substitutable ports can be implemented from outside the
/// module, as the docs promise: a custom remote tier and a custom model.
final class PublicAPITests: XCTestCase {
    private struct FixedRemote: RemoteContractAnswering {
        let value: ContractValue
        func answer(_ request: ContractValue, requestID: String) async throws -> RemoteAnswer {
            RemoteAnswer(value: value, servedVersion: ContractVersion(1, 0))
        }
    }

    private struct Unavailable: StructuredModel {
        let name = "unavailable"
        func availability() async -> ModelAvailability { .unavailable(reason: "test") }
        func generate(prompt: String, schema: ObjectSchema) async throws -> ContractValue { .null }
    }

    func testExternalConformersPlugIntoTheRouter() async {
        let contract = FeatureContract(id: "x", residency: .serverAllowed, revisions: [Expense.v10])
        let good = ContractValue.object(["merchant": .string("M"), "total": .int(3), "category": .string("food")])
        let router = TierRouter(contract: contract, onDevice: Unavailable(), remote: FixedRemote(value: good),
                                policy: RoutingPolicy(onDeviceContextBudget: 100))
        let outcome = await router.route(.object(["text": .string("t")]), requestID: "p")
        XCTAssertEqual(outcome.answer, good)

        let bad = TierRouter(contract: contract, onDevice: Unavailable(), remote: FixedRemote(value: .object([:])),
                             policy: RoutingPolicy(onDeviceContextBudget: 100))
        let rejected = await bad.route(.object(["text": .string("t")]), requestID: "q")
        XCTAssertNil(rejected.answer)
    }
}
