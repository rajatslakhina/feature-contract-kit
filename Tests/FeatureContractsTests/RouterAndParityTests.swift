@testable import FeatureContracts
import XCTest

final class RouterTests: XCTestCase {
    private let served = RemoteAnswer(value: Expense.answer(merchant: "Server"), servedVersion: ContractVersion(1, 2),
                                      promptFingerprint: nil, renegotiated: false)

    private func router(onDevice: any StructuredModel, remote: (any RemoteContractAnswering)?,
                        residency: DataResidency = .serverAllowed, budget: Int = 1_000,
                        escalate: Bool = true) -> TierRouter {
        var contract = Expense.contract
        contract.residency = residency
        return TierRouter(contract: contract, onDevice: onDevice, remote: remote,
                          policy: RoutingPolicy(onDeviceContextBudget: budget, escalateOnInvalidOutput: escalate))
    }

    private func events(_ outcome: RouteOutcome) -> [TraceStep.Event] { outcome.trace.map(\.event) }

    func testCapableDeviceShortPromptStaysOnDevice() async {
        let counter = CallCounter()
        let outcome = await router(onDevice: Expense.model("device"),
                                   remote: CountingRemote(counter: counter, result: .success(served)))
            .route(Expense.request(), requestID: "1")
        XCTAssertEqual(outcome.result, .answered(Expense.answer(), tier: .onDevice))
        XCTAssertEqual(events(outcome), [.generated, .answered])
        let remoteCalls = await counter.count
        XCTAssertEqual(remoteCalls, 0)
    }

    func testUnavailableDeviceAndOversizedContextGoToTheServer() async {
        let remote = CountingRemote(counter: CallCounter(), result: .success(served))
        let unavailable = await router(onDevice: Expense.model("device", availability: .unavailable(reason: "Apple Intelligence off")),
                                       remote: remote).route(Expense.request(), requestID: "2")
        XCTAssertEqual(unavailable.result, .answered(served.value, tier: .server(ContractVersion(1, 2))))
        XCTAssertEqual(events(unavailable), [.skippedUnavailable, .answered])

        let counter = CallCounter()
        let long = Expense.request(String(repeating: "receipt line ", count: 400))
        let oversized = await router(onDevice: CountingModel(counter: counter, value: Expense.answer()), remote: remote, budget: 512)
            .route(long, requestID: "3")
        XCTAssertEqual(events(oversized), [.skippedContext, .answered])
        XCTAssertGreaterThan(oversized.estimatedTokens, 512)
        let deviceCalls = await counter.count
        XCTAssertEqual(deviceCalls, 0)
    }

    func testInvalidOnDeviceAnswerEscalatesAndIsNeverReturned() async {
        let hallucinated = Expense.model("device", Expense.answer(category: "groceries"))
        let outcome = await router(onDevice: hallucinated, remote: CountingRemote(counter: CallCounter(), result: .success(served)))
            .route(Expense.request(), requestID: "4")
        XCTAssertEqual(events(outcome), [.generated, .outputRejected, .answered])
        XCTAssertEqual(outcome.answer, served.value)

        let thrown = await router(onDevice: Expense.failing(), remote: CountingRemote(counter: CallCounter(), result: .success(served)))
            .route(Expense.request(), requestID: "5")
        XCTAssertEqual(events(thrown), [.modelError, .answered])
    }

    /// Hostile model output must be rejected before anything walks it,
    /// including the trace's description of it.
    func testDeeplyNestedOnDeviceOutputIsRejectedWithoutWalkingIt() async {
        var deep = ContractValue.int(0)
        for _ in 0..<5_000 { deep = .array([deep]) }
        let outcome = await router(onDevice: Expense.model("device", .object(["merchant": deep])), remote: nil)
            .route(Expense.request(), requestID: "deep")
        XCTAssertEqual(outcome.result, .failed(.noTierAvailable))
        XCTAssertEqual(events(outcome), [.generated, .outputRejected, .noServerTier])
        XCTAssertEqual(outcome.trace.first?.detail, "(nesting too deep to show)")
    }

    func testOnDeviceOnlyContractNeverLeavesTheDevice() async {
        let counter = CallCounter()
        let outcome = await router(onDevice: Expense.model("device", Expense.answer(category: "groceries")),
                                   remote: CountingRemote(counter: counter, result: .success(served)),
                                   residency: .onDeviceOnly).route(Expense.request(), requestID: "6")
        XCTAssertEqual(outcome.result, .failed(.residencyForbidsEscalation))
        let remoteCalls = await counter.count
        XCTAssertEqual(remoteCalls, 0)
    }

    func testEscalationOffAndMissingRemoteFailClosed() async {
        let counter = CallCounter()
        let noEscalation = await router(onDevice: Expense.model("device", .object([:])),
                                        remote: CountingRemote(counter: counter, result: .success(served)), escalate: false)
            .route(Expense.request(), requestID: "7")
        XCTAssertEqual(noEscalation.result, .failed(.noTierAvailable))
        let remoteCalls = await counter.count
        XCTAssertEqual(remoteCalls, 0)

        let noRemote = await router(onDevice: Expense.model("d", availability: .unavailable(reason: "x")), remote: nil)
            .route(Expense.request(), requestID: "8")
        XCTAssertEqual(noRemote.result, .failed(.noTierAvailable))
        XCTAssertEqual(events(noRemote), [.skippedUnavailable, .noServerTier])
    }

    func testInvalidRequestTouchesNoModel() async {
        let counter = CallCounter()
        let outcome = await router(onDevice: CountingModel(counter: counter, value: Expense.answer()),
                                   remote: CountingRemote(counter: counter, result: .success(served)))
            .route(.object(["text": .int(3)]), requestID: "9")
        XCTAssertEqual(outcome.result, .failed(.invalidRequest))
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testServerErrorAndCancellation() async {
        let failing = await router(onDevice: Expense.model("d", availability: .unavailable(reason: "x")),
                                   remote: CountingRemote(counter: CallCounter(), result: .failure(.upgradeRequired(oldestServed: nil))))
            .route(Expense.request(), requestID: "10")
        guard case .failed(.serverFailed(let detail)) = failing.result else { return XCTFail("\(failing.result)") }
        XCTAssertTrue(detail.contains("upgrade required"))

        let counter = CallCounter()
        let routerUnderTest = router(onDevice: Expense.model("d", availability: .unavailable(reason: "x")),
                                     remote: CountingRemote(counter: counter, result: .success(served)))
        let task = Task { () -> RouteOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await routerUnderTest.route(Expense.request(), requestID: "11")
        }
        let cancelled = await task.value
        XCTAssertEqual(cancelled.result, .failed(.cancelled))
        let calls = await counter.count
        XCTAssertEqual(calls, 0)
    }

    func testRealClientBehindTheRouterReportsRenegotiation() async {
        let endpoint = ContractEndpoint(contracts: [Expense.contract.asShipped(upTo: ContractVersion(1, 1))],
                                        model: Expense.model("server", Expense.answer(merchant: "Hilton", category: "lodging")))
        let client = ContractClient(contract: Expense.contract, transport: InProcessTransport(endpoint: endpoint))
        let outcome = await router(onDevice: Expense.model("d", availability: .unavailable(reason: "x")), remote: client)
            .route(Expense.request(), requestID: "12")
        XCTAssertEqual(events(outcome), [.skippedUnavailable, .renegotiated, .answered])
        XCTAssertEqual(outcome.result, .answered(Expense.answer(merchant: "Hilton", category: "lodging"),
                                                 tier: .server(ContractVersion(1, 1))))
    }
}

final class ParityTests: XCTestCase {
    private let golden = (1...5).map { GoldenCase(id: "case-\($0)", request: Expense.request("receipt \($0)")) }

    private func eval(threshold: Int = 9_000, rules: [String: ParityRule] = ["merchant": .normalizedText, "total": .tolerance(0.01)]) -> ParityEval {
        ParityEval(revision: Expense.v12, rules: rules, thresholdBasisPoints: threshold)
    }

    func testIdenticalTiersPass() async {
        let report = await eval().run(golden, reference: Expense.model("a"), candidate: Expense.model("b"))
        XCTAssertEqual(report.verdict, .pass)
        XCTAssertEqual(report.agreementBasisPoints, 10_000)
        XCTAssertEqual(report.cases.map(\.compared), Array(repeating: 5, count: 5))
    }

    /// The mutation the README brags about: a candidate that systematically
    /// disagrees on one field must fail the gate.
    func testCandidateThatGetsCategoryWrongFails() async {
        let broken = Expense.model("b", Expense.answer(category: "other"))
        let report = await eval().run(golden, reference: Expense.model("a"), candidate: broken)
        XCTAssertEqual(report.agreementBasisPoints, 8_000) // 4 of 5 fields agree in every case
        XCTAssertEqual(report.verdict, .fail("agreement 8000 bp < threshold 9000 bp"))
        XCTAssertEqual(report.cases.first?.differences, ["category: \"food\" ≠ \"other\""])
    }

    func testSchemaViolationFailsEvenAtZeroThreshold() async {
        let invalid = Expense.model("b", Expense.answer(confidence: 400))
        let report = await eval(threshold: 0).run(golden, reference: Expense.model("a"), candidate: invalid)
        XCTAssertEqual(report.verdict, .fail("5 case(s) violated the schema"))
        let thrown = await eval(threshold: 0).run(golden, reference: Expense.failing(), candidate: Expense.model("b"))
        XCTAssertFalse(thrown.verdict.isPass)
    }

    func testNothingComparedIsInconclusiveNotPass() async {
        let none = await eval().run([], reference: Expense.model("a"), candidate: Expense.model("b"))
        XCTAssertEqual(none.verdict, .inconclusive("no golden cases"))
        let ignored = Dictionary(uniqueKeysWithValues: Expense.v12.response.fields.map { ($0.name, ParityRule.ignore) })
        let allIgnored = await eval(rules: ignored).run(golden, reference: Expense.model("a"), candidate: Expense.model("b"))
        XCTAssertEqual(allIgnored.verdict, .inconclusive("every field is ignored"))
    }

    func testComparisonRules() {
        XCTAssertTrue(ParityEval.agrees(.double(10), .double(10.004), .tolerance(0.01)))
        XCTAssertFalse(ParityEval.agrees(.double(10), .double(10.02), .tolerance(0.01)))
        XCTAssertTrue(ParityEval.agrees(.int(10), .double(10.0), .tolerance(0)))
        XCTAssertFalse(ParityEval.agrees(.double(10), .double(10.004), .tolerance(.nan)))
        XCTAssertFalse(ParityEval.agrees(.double(10), .double(10.004), .tolerance(-1)))
        XCTAssertFalse(ParityEval.agrees(.double(.nan), .double(.nan), .tolerance(1)))
        XCTAssertTrue(ParityEval.agrees(.string("Blue  Bottle"), .string("blue bottle"), .normalizedText))
        XCTAssertFalse(ParityEval.agrees(.string("Blue Bottle"), .string("Blue Bottle Co"), .normalizedText))
        XCTAssertTrue(ParityEval.agrees(nil, .null, .exact))
        XCTAssertFalse(ParityEval.agrees(nil, .int(1), .exact))
        XCTAssertEqual(ParityEval(revision: Expense.v10, rules: [:], thresholdBasisPoints: 99_999).thresholdBasisPoints, 10_000)
        XCTAssertEqual(ParityEval(revision: Expense.v10, rules: [:], thresholdBasisPoints: -4).thresholdBasisPoints, 0)
    }
}

final class ConsoleTests: XCTestCase {
    func testConsoleSnapshotCoversEveryTab() async {
        let routes = [
            RouteScenario(id: "a", title: "on device", note: "", request: Expense.request(),
                          router: TierRouter(contract: Expense.contract, onDevice: Expense.model("d"), remote: nil,
                                             policy: RoutingPolicy(onDeviceContextBudget: 1_000))),
            RouteScenario(id: "b", title: "fails", note: "", request: Expense.request(),
                          router: TierRouter(contract: Expense.contract, onDevice: Expense.failing(), remote: nil,
                                             policy: RoutingPolicy(onDeviceContextBudget: 1_000))),
        ]
        var proposed = Expense.v12
        proposed.version = ContractVersion(1, 3)
        proposed.response.fields.removeAll { $0.name == "merchant" }
        proposed.response.fields.append(Field("taxRate", .number(0...1)))
        let scenario = ConsoleScenario(
            contract: Expense.contract, proposed: proposed,
            apps: [AppBuild(name: "a", shipped: ContractVersion(1, 0), installBasisPoints: 10_000)],
            servers: [ServerBuild(name: "s", shipped: ContractVersion(1, 2))],
            routes: routes, golden: [GoldenCase(id: "g", request: Expense.request())],
            parity: ParityEval(revision: Expense.v12, rules: [:], thresholdBasisPoints: 9_000),
            reference: Expense.model("a"), candidate: Expense.model("b"))
        let snapshot = await ContractConsole.evaluate(scenario)
        XCTAssertTrue(snapshot.lint.isMergeable)
        XCTAssertEqual(snapshot.proposedVersion, ContractVersion(1, 3))
        XCTAssertEqual(Set(snapshot.proposedFindings.filter { $0.severity == .breaking }.map(\.rule)),
                       ["removed-required-field", "added-required-field-without-default"])
        XCTAssertEqual(snapshot.matrix.degradedBasisPoints(server: 0), 10_000)
        XCTAssertEqual(snapshot.routes.map { $0.outcome.answer != nil }, [true, false])
        XCTAssertEqual(snapshot.parity.verdict, .pass)
    }
}
