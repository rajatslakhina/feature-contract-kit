#if canImport(SwiftUI)
import FeatureContracts
import SwiftUI

/// A four-tab console over one `ConsoleScenario`: the fleet compatibility
/// matrix, the tier router's decision traces, the evolution linter, and the
/// cross-tier parity eval. All logic lives in `ContractConsole` (core
/// module, tested on Linux); this view only renders its snapshot.
public struct ContractConsoleView: View {
    public enum Tab: String, CaseIterable, Sendable {
        case fleet, router, lint, parity
    }

    private let scenario: ConsoleScenario
    @State private var selection: Tab
    @State private var snapshot: ConsoleSnapshot?

    public init(scenario: ConsoleScenario, initialTab: Tab = .fleet) {
        self.scenario = scenario
        _selection = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selection) {
            page(title: "Fleet") { FleetPage(snapshot: $0) }
                .tabItem { Label("Fleet", systemImage: "square.grid.3x3") }
                .tag(Tab.fleet)
            page(title: "Router") { RouterPage(snapshot: $0) }
                .tabItem { Label("Router", systemImage: "arrow.triangle.branch") }
                .tag(Tab.router)
            page(title: "Lint") { LintPage(snapshot: $0) }
                .tabItem { Label("Lint", systemImage: "checklist") }
                .tag(Tab.lint)
            page(title: "Parity") { ParityPage(snapshot: $0) }
                .tabItem { Label("Parity", systemImage: "equal.square") }
                .tag(Tab.parity)
        }
        .task {
            let scenario = self.scenario
            snapshot = await ContractConsole.evaluate(scenario)
        }
    }

    @ViewBuilder
    private func page<Content: View>(title: String, @ViewBuilder content: (ConsoleSnapshot) -> Content) -> some View {
        NavigationStack {
            Group {
                if let snapshot {
                    content(snapshot)
                } else {
                    ProgressView("Evaluating contract…")
                }
            }
            .navigationTitle(title)
        }
    }
}

// MARK: - Fleet

private struct FleetPage: View {
    let snapshot: ConsoleSnapshot

    var body: some View {
        List {
            Section {
                Text("Every app build in the field against every server deploy, computed from the one shared contract (\(snapshot.contractID), head \(snapshot.head?.description ?? "–")).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.matrix.servers.enumerated()), id: \.offset) { serverIndex, server in
                Section {
                    ForEach(Array(snapshot.matrix.apps.enumerated()), id: \.offset) { appIndex, app in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.subheadline.weight(.semibold))
                                Text("ships \(app.shipped.description) · \(percent(app.installBasisPoints)) of installs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let cell = snapshot.matrix.cell(app: appIndex, server: serverIndex) {
                                CellBadge(cell: cell)
                            }
                        }
                    }
                } header: {
                    let retired = server.retiredBelow.map { " · retires < \($0)" } ?? ""
                    Text("\(server.name) (\(server.shipped.description)\(retired))")
                } footer: {
                    let broken = snapshot.matrix.brokenBasisPoints(server: serverIndex)
                    let degraded = snapshot.matrix.degradedBasisPoints(server: serverIndex)
                    VStack(alignment: .leading, spacing: 2) {
                        if broken > 0 {
                            Text("\(percent(broken)) of installs cannot use the feature on this deploy.")
                                .foregroundStyle(Color.red)
                        }
                        if degraded > 0 {
                            Text("\(percent(degraded)) are served on a lossy path: some answers or requests cannot cross and fail with a typed error.")
                                .foregroundStyle(Color.orange)
                        }
                        if broken == 0 && degraded == 0 {
                            Text("Every install is served losslessly.").foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct CellBadge: View {
    let cell: Compatibility

    var body: some View {
        Text(cell.label)
            .font(.caption.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch cell {
        case .native: return .green
        case .serverAhead, .clientAhead: return .blue
        case .degraded: return .orange
        case .noSharedVersion, .unsafe: return .red
        }
    }
}

// MARK: - Router

private struct RouterPage: View {
    let snapshot: ConsoleSnapshot

    var body: some View {
        List {
            ForEach(snapshot.routes) { route in
                Section {
                    Text(route.note).font(.footnote).foregroundStyle(.secondary)
                    ForEach(route.outcome.trace) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(step.tier) · \(step.event.rawValue)")
                                .font(.caption.weight(.semibold))
                            Text(step.detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                } header: {
                    HStack {
                        Text(route.title)
                        Spacer()
                        Text(resultLabel(route.outcome))
                            .foregroundStyle(route.outcome.answer == nil ? Color.red : Color.green)
                    }
                }
            }
        }
    }

    private func resultLabel(_ outcome: RouteOutcome) -> String {
        switch outcome.result {
        case .answered(_, let tier): return "✓ \(tier.label)"
        case .failed(let failure): return "✗ \(String(describing: failure))"
        }
    }
}

// MARK: - Lint

private struct LintPage: View {
    let snapshot: ConsoleSnapshot

    var body: some View {
        List {
            Section {
                Label(snapshot.lint.isMergeable ? "History is mergeable" : "History has breaking changes",
                      systemImage: snapshot.lint.isMergeable ? "checkmark.seal" : "xmark.octagon")
                    .foregroundStyle(snapshot.lint.isMergeable ? Color.green : Color.red)
                if snapshot.lint.findings.isEmpty {
                    Text("No findings.").foregroundStyle(.secondary)
                }
                ForEach(Array(snapshot.lint.findings.enumerated()), id: \.offset) { _, finding in
                    FindingRow(finding: finding)
                }
            } header: {
                Text("Shipped revisions")
            }
            if let proposed = snapshot.proposedVersion {
                Section {
                    let breaking = snapshot.proposedFindings.filter { $0.severity == .breaking }.count
                    Label(breaking == 0 ? "Proposed \(proposed.description) can merge" : "Proposed \(proposed.description) blocked: \(breaking) breaking",
                          systemImage: breaking == 0 ? "checkmark.seal" : "xmark.octagon")
                        .foregroundStyle(breaking == 0 ? Color.green : Color.red)
                    ForEach(Array(snapshot.proposedFindings.enumerated()), id: \.offset) { _, finding in
                        FindingRow(finding: finding)
                    }
                } header: {
                    Text("Pull request: proposed \(proposed.description)")
                }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: LintFinding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(finding.severity.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                Text(finding.rule).font(.caption.monospaced())
            }
            Text("\(finding.side?.rawValue ?? "contract") \(finding.path) — \(finding.detail)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch finding.severity {
        case .breaking: return .red
        case .lossy: return .orange
        case .note: return .secondary
        }
    }
}

// MARK: - Parity

private struct ParityPage: View {
    let snapshot: ConsoleSnapshot

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Agreement")
                    Spacer()
                    Text("\(percent(snapshot.parity.agreementBasisPoints)) (threshold \(percent(snapshot.parity.thresholdBasisPoints)))")
                        .font(.body.monospacedDigit())
                }
                Text(verdictLabel)
                    .font(.headline)
                    .foregroundStyle(snapshot.parity.verdict.isPass ? Color.green : Color.red)
            }
            ForEach(snapshot.parity.cases) { result in
                Section {
                    Text("\(result.agreed)/\(result.compared) fields agree").font(.subheadline)
                    ForEach(Array((result.differences + result.schemaViolations).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).foregroundStyle(.red)
                    }
                } header: {
                    Text(result.id)
                }
            }
        }
    }

    private var verdictLabel: String {
        switch snapshot.parity.verdict {
        case .pass: return "PASS — tiers are interchangeable for this contract"
        case .fail(let reason): return "FAIL — \(reason)"
        case .inconclusive(let reason): return "INCONCLUSIVE — \(reason)"
        }
    }
}

private func percent(_ basisPoints: Int) -> String {
    let whole = basisPoints / 100
    let fraction = basisPoints % 100 // basisPoints is clamped 0…10 000 upstream; `% 100` cannot trap.
    return fraction == 0 ? "\(whole)%" : String(format: "%ld.%02ld%%", whole, fraction)
}
#endif
