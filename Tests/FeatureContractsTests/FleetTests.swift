@testable import FeatureContracts
import XCTest

final class FleetTests: XCTestCase {
    private let apps = [
        AppBuild(name: "3.8", shipped: ContractVersion(1, 0), installBasisPoints: 600),
        AppBuild(name: "4.0", shipped: ContractVersion(1, 1), installBasisPoints: 3_100),
        AppBuild(name: "4.1", shipped: ContractVersion(1, 2), installBasisPoints: 6_300),
    ]

    func testNegotiationPicksHighestShared() {
        XCTAssertEqual(Negotiation.agree(client: [ContractVersion(1, 0), ContractVersion(1, 1)],
                                         server: [ContractVersion(1, 1), ContractVersion(1, 2)]), ContractVersion(1, 1))
        XCTAssertNil(Negotiation.agree(client: [ContractVersion(1, 0)], server: [ContractVersion(1, 1)]))
        XCTAssertNil(Negotiation.agree(client: [], server: []))
    }

    func testMatrixClassifiesEverySkewDirection() {
        let servers = [
            ServerBuild(name: "old", shipped: ContractVersion(1, 1)),
            ServerBuild(name: "new", shipped: ContractVersion(1, 2)),
            ServerBuild(name: "retiring", shipped: ContractVersion(1, 2), retiredBelow: ContractVersion(1, 1)),
        ]
        let matrix = CompatibilityMatrix(contract: Expense.contract, apps: apps, servers: servers)
        XCTAssertEqual(matrix.cell(app: 0, server: 0), .serverAhead(agreed: ContractVersion(1, 0), server: ContractVersion(1, 1)))
        XCTAssertEqual(matrix.cell(app: 1, server: 0), .native(ContractVersion(1, 1)))
        // The app is ahead, so it downgrades its request: v1.2's widened `text` is the one lossy step.
        guard case .degraded(let base, let lossy)? = matrix.cell(app: 2, server: 0) else {
            return XCTFail("expected degraded, got \(String(describing: matrix.cell(app: 2, server: 0)))")
        }
        XCTAssertEqual(base, .clientAhead(agreed: ContractVersion(1, 1), client: ContractVersion(1, 2)))
        XCTAssertEqual(lossy.map(\.path), ["text"])
        XCTAssertEqual(lossy.map(\.side), [.request])
        // The server is ahead, so it downgrades its answer: v1.2's widened `total` bites.
        guard case .degraded(let serverBase, let serverLossy)? = matrix.cell(app: 0, server: 1) else {
            return XCTFail("expected degraded")
        }
        XCTAssertEqual(serverBase, .serverAhead(agreed: ContractVersion(1, 0), server: ContractVersion(1, 2)))
        XCTAssertEqual(serverLossy.map(\.path), ["total"])
        XCTAssertTrue(matrix.cell(app: 0, server: 1)?.isServable ?? false)
        XCTAssertFalse(matrix.cell(app: 0, server: 1)?.isLossless ?? true)
        XCTAssertEqual(matrix.degradedBasisPoints(server: 0), 6_300)
        XCTAssertEqual(matrix.degradedBasisPoints(server: 1), 3_700)
        XCTAssertEqual(matrix.cell(app: 2, server: 1), .native(ContractVersion(1, 2)))
        XCTAssertEqual(matrix.cell(app: 0, server: 2), .noSharedVersion)
        XCTAssertEqual(matrix.brokenBasisPoints(server: 0), 0)
        XCTAssertEqual(matrix.brokenBasisPoints(server: 2), 600)
        XCTAssertNil(matrix.cell(app: 3, server: 0))
        XCTAssertNil(matrix.cell(app: 0, server: -1))
        XCTAssertEqual(matrix.brokenBasisPoints(server: 99), 0)
    }

    func testMajorBumpOnTheServerBreaksEveryMajorOneApp() {
        let matrix = CompatibilityMatrix(contract: Expense.withMajor, apps: apps,
                                         servers: [ServerBuild(name: "v2-only", shipped: ContractVersion(2, 0),
                                                               retiredBelow: ContractVersion(2, 0)),
                                                   ServerBuild(name: "both", shipped: ContractVersion(2, 0))])
        XCTAssertEqual(matrix.brokenBasisPoints(server: 0), 10_000)
        // A server that still serves major 1 answers 1.x apps at its newest 1.x revision.
        guard case .degraded(let base, _)? = matrix.cell(app: 1, server: 1) else { return XCTFail("expected degraded") }
        XCTAssertEqual(base, .serverAhead(agreed: ContractVersion(1, 1), server: ContractVersion(1, 2)))
        XCTAssertTrue(matrix.cell(app: 0, server: 1)?.isServable ?? false)
        XCTAssertEqual(matrix.cell(app: 2, server: 1), .native(ContractVersion(1, 2)))
    }

    /// A removed optional field is lossy on upgrade (the value is dropped)
    /// but can never make a downgrade fail, so it must not mark a pair degraded.
    func testRemovedOptionalFieldDoesNotDegradeAPair() {
        var trimmed = Expense.v11
        trimmed.version = ContractVersion(1, 2)
        trimmed.response.fields.removeAll { $0.name == "currency" }
        let contract = FeatureContract(id: "x", residency: .serverAllowed, revisions: [Expense.v11, trimmed])
        XCTAssertTrue(ContractLinter.lint(contract).findings.contains { $0.rule == "removed-field" })
        let matrix = CompatibilityMatrix(contract: contract,
                                         apps: [AppBuild(name: "a", shipped: ContractVersion(1, 1), installBasisPoints: 100)],
                                         servers: [ServerBuild(name: "s", shipped: ContractVersion(1, 2))])
        XCTAssertEqual(matrix.cell(app: 0, server: 0), .serverAhead(agreed: ContractVersion(1, 1), server: ContractVersion(1, 2)))
    }

    func testUnsafeCellNamesTheBreakingFinding() {
        var bad = Expense.v11
        bad.response.fields.removeAll { $0.name == "merchant" }
        let contract = FeatureContract(id: "x", residency: .serverAllowed, revisions: [Expense.v10, bad])
        let matrix = CompatibilityMatrix(contract: contract, apps: [apps[0]],
                                         servers: [ServerBuild(name: "s", shipped: ContractVersion(1, 1))])
        guard case .unsafe(let agreed, let findings) = matrix.cell(app: 0, server: 0) else {
            return XCTFail("expected unsafe, got \(String(describing: matrix.cell(app: 0, server: 0)))")
        }
        XCTAssertEqual(agreed, ContractVersion(1, 0))
        XCTAssertEqual(findings.map(\.rule), ["removed-required-field"])
        XCTAssertEqual(matrix.brokenBasisPoints(server: 0), 600)
    }

    func testInstallSharesAreClampedAndSumsSaturate() {
        let wild = [AppBuild(name: "a", shipped: ContractVersion(1, 0), installBasisPoints: Int.max),
                    AppBuild(name: "b", shipped: ContractVersion(1, 0), installBasisPoints: 20_000),
                    AppBuild(name: "c", shipped: ContractVersion(1, 0), installBasisPoints: -5)]
        XCTAssertEqual(wild.map(\.installBasisPoints), [10_000, 10_000, 0])
        let matrix = CompatibilityMatrix(contract: Expense.contract, apps: wild,
                                         servers: [ServerBuild(name: "s", shipped: ContractVersion(1, 2), retiredBelow: ContractVersion(1, 2))])
        XCTAssertEqual(matrix.brokenBasisPoints(server: 0), 10_000)
        let empty = CompatibilityMatrix(contract: Expense.contract, apps: [], servers: [])
        XCTAssertTrue(empty.cells.isEmpty)
    }
}
