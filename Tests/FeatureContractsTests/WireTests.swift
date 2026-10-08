@testable import FeatureContracts
import XCTest

final class WireTests: XCTestCase {
    /// Independent model of what an app at `app` must receive when the
    /// server generated `answer` at `server`: written from the contract's
    /// documented semantics, not by calling `SkewTranslator`.
    static func expected(_ answer: ContractValue, server: ContractVersion, app: ContractVersion) -> ContractValue {
        guard var fields = answer.objectValue else { return answer }
        let served = min(server, app)
        // Down to the served revision: fields it lacks are dropped; categories follow the chain.
        if served.minor < 2 { fields["confidence"] = nil }
        if served.minor < 1 { fields["currency"] = nil }
        if case .string(var category)? = fields["category"] {
            if served.minor < 2, category == "hostel" { category = "lodging" }
            if served.minor < 1, category == "lodging" { category = "travel" }
            fields["category"] = .string(category)
        }
        // Back up to the app's revision: the added response fields are optional with no default.
        return .object(fields)
    }

    private func client(app: ContractVersion, server: ContractVersion, retiredBelow: ContractVersion? = nil,
                        model: any StructuredModel) -> ContractClient {
        let endpoint = ContractEndpoint(contracts: [Expense.contract.asShipped(upTo: server)],
                                        retiredBelow: retiredBelow.map { ["expense.extract": $0] } ?? [:],
                                        model: model)
        return ContractClient(contract: Expense.contract.asShipped(upTo: app), transport: InProcessTransport(endpoint: endpoint))
    }

    func testOlderAppNewerServerGetsADowngradedAnswer() async throws {
        let server = Expense.model("server", Expense.answer(category: "hostel", currency: "EUR", confidence: 80))
        let answer = try await client(app: ContractVersion(1, 0), server: ContractVersion(1, 2), model: server)
            .answer(Expense.request(), requestID: "r1")
        XCTAssertEqual(answer.servedVersion, ContractVersion(1, 0))
        XCTAssertFalse(answer.renegotiated)
        XCTAssertEqual(answer.value, Expense.answer(category: "travel"))
        XCTAssertEqual(answer.promptFingerprint, Expense.v12.promptFingerprint)
    }

    func testNewerAppOlderServerRenegotiatesOnceAndUpgradesTheAnswer() async throws {
        let server = Expense.model("server", Expense.answer(category: "lodging", currency: "USD"))
        let answer = try await client(app: ContractVersion(1, 2), server: ContractVersion(1, 1), model: server)
            .answer(.object(["text": .string("Hotel"), "hint": .string("business")]), requestID: "r2")
        XCTAssertTrue(answer.renegotiated)
        XCTAssertEqual(answer.servedVersion, ContractVersion(1, 1))
        // Upgraded to v1.2: `confidence` is optional with no default, so it stays absent.
        XCTAssertEqual(answer.value, Expense.answer(category: "lodging", currency: "USD"))
    }

    func testNewerAppCannotSendWhatTheOlderServerCannotRead() async {
        let long = ContractValue.object(["text": .string(String(repeating: "x", count: 3_000))])
        do {
            _ = try await client(app: ContractVersion(1, 2), server: ContractVersion(1, 1), model: Expense.model())
                .answer(long, requestID: "r3")
            XCTFail("expected a translation error")
        } catch let error as ContractClientError {
            guard case .translation(.notExpressible(let path, _, _)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, "text")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRetiredVersionGetsUpgradeRequired() async {
        do {
            _ = try await client(app: ContractVersion(1, 0), server: ContractVersion(1, 2), retiredBelow: ContractVersion(1, 1),
                                 model: Expense.model()).answer(Expense.request(), requestID: "r4")
            XCTFail("expected upgradeRequired")
        } catch {
            XCTAssertEqual(error as? ContractClientError, .upgradeRequired(oldestServed: ContractVersion(1, 1)))
        }
    }

    func testServerNeverForwardsAnInvalidOrInexpressibleAnswer() async {
        let invalid = Expense.model("server", .object(["merchant": .string("x")]))
        let tooBig = Expense.model("server", Expense.answer(total: 900_000))
        let expectations: [(ScriptedModel, ContractVersion, ResponseEnvelope.Status)] = [
            (invalid, ContractVersion(1, 2), .modelFailed),
            // Valid at v1.2, but v1.0's range is narrower: a typed, distinct status, never a clamped total.
            (tooBig, ContractVersion(1, 0), .notExpressible),
        ]
        for (model, app, status) in expectations {
            do {
                _ = try await client(app: app, server: ContractVersion(1, 2), model: model).answer(Expense.request(), requestID: "r5")
                XCTFail("expected \(status)")
            } catch {
                guard case .server(let got, _)? = error as? ContractClientError else { return XCTFail("\(error)") }
                XCTAssertEqual(got, status)
            }
        }
        do {
            _ = try await client(app: ContractVersion(1, 2), server: ContractVersion(1, 2), model: Expense.failing())
                .answer(Expense.request(), requestID: "r6")
            XCTFail("expected modelFailed")
        } catch {
            guard case .server(.modelFailed, _)? = error as? ContractClientError else { return XCTFail("\(error)") }
        }
    }

    func testEndpointRejectsGarbageAndUnknownContracts() async throws {
        let endpoint = ContractEndpoint(contracts: [Expense.contract], model: Expense.model())
        let garbage = try JSONDecoder().decode(ResponseEnvelope.self, from: await endpoint.handle(data: Data("nope".utf8)))
        XCTAssertEqual(garbage.status, .invalidRequest)
        // A *valid* envelope padded past the limit: only the size guard can reject it.
        let padded = RequestEnvelope(contractID: "expense.extract", supported: [ContractVersion(1, 2)],
                                     payloadVersion: ContractVersion(1, 2),
                                     payload: .object(["text": .string("x"), "pad": .string(String(repeating: "p", count: ContractEndpoint.maximumBodyBytes))]),
                                     requestID: "big")
        let huge = try JSONDecoder().decode(ResponseEnvelope.self, from: await endpoint.handle(data: try JSONEncoder().encode(padded)))
        XCTAssertEqual(huge.status, .invalidRequest)
        XCTAssertTrue(huge.detail.contains("body over"), huge.detail)
        let unknown = await endpoint.handle(RequestEnvelope(contractID: "nope", supported: [ContractVersion(1, 0)],
                                                            payloadVersion: ContractVersion(1, 0), payload: Expense.request(),
                                                            requestID: "u"))
        XCTAssertEqual(unknown.status, .unknownContract)
        let badPayload = await endpoint.handle(RequestEnvelope(contractID: "expense.extract", supported: [ContractVersion(1, 2)],
                                                               payloadVersion: ContractVersion(1, 2), payload: .object([:]),
                                                               requestID: "b"))
        XCTAssertEqual(badPayload.status, .invalidRequest)
        XCTAssertEqual(badPayload.requestID, "b")
    }

    func testServerErrorsWithoutARequestIDAreNotReportedAsMismatches() async {
        let garbled = CannedTransport { _ in ResponseEnvelope(status: .invalidRequest, detail: "undecodable envelope", requestID: "") }
        do {
            _ = try await ContractClient(contract: Expense.contract, transport: garbled).answer(Expense.request(), requestID: "me")
            XCTFail("expected server error")
        } catch {
            XCTAssertEqual(error as? ContractClientError, .server(status: .invalidRequest, detail: "undecodable envelope"))
        }
    }

    func testClientRejectsMismatchedIDsAndRenegotiationLoops() async {
        let mismatched = CannedTransport { _ in
            ResponseEnvelope(status: .ok, version: ContractVersion(1, 2), payload: Expense.answer(), requestID: "other")
        }
        let loop = CannedTransport { request in
            ResponseEnvelope(status: .renegotiate, version: ContractVersion(1, 1), requestID: request.requestID)
        }
        let sideways = CannedTransport { request in
            ResponseEnvelope(status: .renegotiate, version: ContractVersion(1, 2), requestID: request.requestID)
        }
        let okNoVersion = CannedTransport { request in
            ResponseEnvelope(status: .ok, payload: Expense.answer(), requestID: request.requestID)
        }
        let expectations: [(CannedTransport, ContractClientError)] = [
            (mismatched, .requestIDMismatch),
            (loop, .renegotiationLoop),
            (sideways, .renegotiationLoop),
        ]
        for (transport, expected) in expectations {
            let client = ContractClient(contract: Expense.contract, transport: transport)
            do {
                _ = try await client.answer(Expense.request(), requestID: "me")
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ContractClientError, expected)
            }
        }
        do {
            _ = try await ContractClient(contract: Expense.contract, transport: okNoVersion).answer(Expense.request(), requestID: "me")
            XCTFail("expected failure")
        } catch {
            guard case .server(.ok, _)? = error as? ContractClientError else { return XCTFail("\(error)") }
        }
        do {
            _ = try await ContractClient(contract: FeatureContract(id: "e", residency: .serverAllowed, revisions: []),
                                         transport: okNoVersion).answer(Expense.request(), requestID: "me")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ContractClientError, .noRevisions)
        }
    }

    /// A renegotiation must move strictly down. A server that asks the app
    /// to "resend" at the version it already sent is broken, even if its
    /// second reply would be fine.
    func testRenegotiationToTheSameVersionIsRefused() async {
        actor Attempts { var count = 0; func next() -> Int { count += 1; return count } }
        let attempts = Attempts()
        struct FlakyTransport: ContractTransport {
            let attempts: Attempts
            func send(_ body: Data) async throws -> Data {
                let request = try JSONDecoder().decode(RequestEnvelope.self, from: body)
                let reply = await attempts.next() == 1
                    ? ResponseEnvelope(status: .renegotiate, version: request.payloadVersion, requestID: request.requestID)
                    : ResponseEnvelope(status: .ok, version: request.payloadVersion, payload: Expense.answer(), requestID: request.requestID)
                return try JSONEncoder().encode(reply)
            }
        }
        do {
            _ = try await ContractClient(contract: Expense.contract, transport: FlakyTransport(attempts: attempts))
                .answer(Expense.request(), requestID: "same")
            XCTFail("expected renegotiationLoop")
        } catch {
            XCTAssertEqual(error as? ContractClientError, .renegotiationLoop)
        }
        let sent = await attempts.count
        XCTAssertEqual(sent, 1)
    }

    /// The README's two-sided-skew claim, end to end, for every pair of
    /// app and server revisions in major 1 and many generated answers.
    func testEveryAppServerPairServesGeneratedAnswers() async throws {
        var rng = SplitMix64(seed: 42)
        let versions = Expense.contract.revisions.map(\.version)
        for app in versions {
            for server in versions {
                for _ in 0..<20 {
                    var answer = ValueGenerator.value(for: Expense.contract.revision(server)?.response ?? ObjectSchema([]), using: &rng)
                    // Keep totals inside v1.0's range: a widened range is *declared* lossy,
                    // and that path is covered by its own test.
                    if case .object(var fields) = answer { fields["total"] = .double(12.5); answer = .object(fields) }
                    let fixed = answer
                    let model = ScriptedModel(name: "gen") { _, _ in fixed }
                    let result = try await client(app: app, server: server, model: model).answer(Expense.request(), requestID: "p")
                    XCTAssertEqual(result.servedVersion, min(app, server))
                    XCTAssertEqual(result.value, Self.expected(fixed, server: server, app: app),
                                   "server \(server) → app \(app)")
                }
            }
        }
    }
}
