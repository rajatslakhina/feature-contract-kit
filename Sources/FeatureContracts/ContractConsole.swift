import Foundation

/// One scripted request through a configured router, for the console.
public struct RouteScenario: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var note: String
    public var request: ContractValue
    public var router: TierRouter

    public init(id: String, title: String, note: String, request: ContractValue, router: TierRouter) {
        self.id = id
        self.title = title
        self.note = note
        self.request = request
        self.router = router
    }
}

/// Everything the console shows, described as data. The demo app builds
/// one; the SwiftUI module only renders the `ConsoleSnapshot` it produces,
/// so all of the console's logic runs (and is tested) on Linux too.
public struct ConsoleScenario: Sendable {
    public var contract: FeatureContract
    /// A revision someone has proposed on a PR, linted against the head.
    public var proposed: ContractRevision?
    public var apps: [AppBuild]
    public var servers: [ServerBuild]
    public var routes: [RouteScenario]
    public var golden: [GoldenCase]
    public var parity: ParityEval
    public var reference: any StructuredModel
    public var candidate: any StructuredModel

    public init(contract: FeatureContract, proposed: ContractRevision?, apps: [AppBuild], servers: [ServerBuild],
                routes: [RouteScenario], golden: [GoldenCase], parity: ParityEval,
                reference: any StructuredModel, candidate: any StructuredModel) {
        self.contract = contract
        self.proposed = proposed
        self.apps = apps
        self.servers = servers
        self.routes = routes
        self.golden = golden
        self.parity = parity
        self.reference = reference
        self.candidate = candidate
    }
}

public struct RouteResult: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var note: String
    public var outcome: RouteOutcome
}

public struct ConsoleSnapshot: Hashable, Sendable {
    public var contractID: String
    public var head: ContractVersion?
    public var lint: ContractLinter.Report
    public var proposedVersion: ContractVersion?
    public var proposedFindings: [LintFinding]
    public var matrix: CompatibilityMatrix
    public var routes: [RouteResult]
    public var parity: ParityReport
}

public enum ContractConsole {
    public static func evaluate(_ scenario: ConsoleScenario) async -> ConsoleSnapshot {
        let lint = ContractLinter.lint(scenario.contract)
        var proposedFindings: [LintFinding] = []
        if let proposed = scenario.proposed, let head = scenario.contract.latest {
            proposedFindings = ContractLinter.compare(head, proposed)
            for side in [ContractSide.request, .response] {
                for issue in SkewTranslator.schema(proposed, side).selfCheck() {
                    proposedFindings.append(LintFinding(severity: .breaking, side: side, from: nil, to: proposed.version,
                                                        path: issue.path, rule: "schema-self-check", detail: issue.message))
                }
            }
        }
        var routes: [RouteResult] = []
        for route in scenario.routes {
            let outcome = await route.router.route(route.request, requestID: route.id)
            routes.append(RouteResult(id: route.id, title: route.title, note: route.note, outcome: outcome))
        }
        let parity = await scenario.parity.run(scenario.golden, reference: scenario.reference, candidate: scenario.candidate)
        return ConsoleSnapshot(contractID: scenario.contract.id, head: scenario.contract.latest?.version, lint: lint,
                               proposedVersion: scenario.proposed?.version, proposedFindings: proposedFindings,
                               matrix: CompatibilityMatrix(contract: scenario.contract, apps: scenario.apps, servers: scenario.servers),
                               routes: routes, parity: parity)
    }
}
