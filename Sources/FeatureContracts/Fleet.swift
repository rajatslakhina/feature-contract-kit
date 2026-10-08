import Foundation

/// Picks the version two runtimes will speak: the highest one both know.
public enum Negotiation {
    public static func agree(client: [ContractVersion], server: [ContractVersion]) -> ContractVersion? {
        Set(client).intersection(server).max()
    }
}

/// An app build in the field. `shipped` is the newest revision compiled
/// into it; `floor` is the oldest it still keeps (normally the start of
/// its major). `installBasisPoints` is its share of active installs, 0…10 000.
public struct AppBuild: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var shipped: ContractVersion
    public var floor: ContractVersion?
    public var installBasisPoints: Int

    public init(name: String, shipped: ContractVersion, floor: ContractVersion? = nil, installBasisPoints: Int) {
        self.name = name
        self.shipped = shipped
        self.floor = floor
        // Clamped rather than trusted: shares come from analytics exports.
        self.installBasisPoints = min(max(installBasisPoints, 0), 10_000)
    }
}

/// A server deployment. `retiredBelow` is the oldest revision it still
/// serves; everything older gets `upgradeRequired`.
public struct ServerBuild: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var shipped: ContractVersion
    public var retiredBelow: ContractVersion?

    public init(name: String, shipped: ContractVersion, retiredBelow: ContractVersion? = nil) {
        self.name = name
        self.shipped = shipped
        self.retiredBelow = retiredBelow
    }
}

public enum Compatibility: Hashable, Sendable {
    /// Same revision on both sides.
    case native(ContractVersion)
    /// Server is newer: it upgrades the request and downgrades its answer.
    case serverAhead(agreed: ContractVersion, server: ContractVersion)
    /// App is newer: it downgrades its request and upgrades the answer.
    /// Only safe because the linter forbids additions without defaults.
    case clientAhead(agreed: ContractVersion, client: ContractVersion)
    /// No shared revision. The app gets a typed `upgradeRequired`.
    case noSharedVersion
    /// A shared revision exists, but a step between it and one side's
    /// revision has a breaking lint finding, so translation can fail for
    /// valid values. Listed so a reviewer sees *which* rule bites *whom*.
    case unsafe(agreed: ContractVersion, findings: [LintFinding])
    /// Served, but a step on the path is a declared-lossy widening, so some
    /// valid values cannot cross (a v1.2 total above v1.0's range; a v1.2
    /// request text longer than v1.1 allows). Those calls fail with a typed
    /// `notExpressible` / translation error rather than a wrong value.
    indirect case degraded(Compatibility, lossy: [LintFinding])

    public var isServable: Bool {
        switch self {
        case .native, .serverAhead, .clientAhead, .degraded: return true
        case .noSharedVersion, .unsafe: return false
        }
    }

    /// True only when every valid value crosses this pair.
    public var isLossless: Bool {
        switch self {
        case .native, .serverAhead, .clientAhead: return true
        case .degraded, .noSharedVersion, .unsafe: return false
        }
    }

    public var label: String {
        switch self {
        case .native(let version): return "native \(version)"
        case .serverAhead(let agreed, _): return "server ↓ to \(agreed)"
        case .clientAhead(let agreed, _): return "app ↓ to \(agreed)"
        case .noSharedVersion: return "upgrade required"
        case .unsafe(let agreed, let findings): return "UNSAFE at \(agreed) (\(findings.count))"
        case .degraded(let base, let lossy): return "\(base.label) · lossy ×\(lossy.count)"
        }
    }
}

/// Every (app build × server build) pair in the fleet, computed from the
/// one shared contract. This is the table a lead signs before retiring a
/// revision or rolling a server, and the one CI regenerates on every PR.
public struct CompatibilityMatrix: Hashable, Sendable {
    public var apps: [AppBuild]
    public var servers: [ServerBuild]
    /// `cells[appIndex][serverIndex]`.
    public var cells: [[Compatibility]]

    public init(contract: FeatureContract, apps: [AppBuild], servers: [ServerBuild]) {
        self.apps = apps
        self.servers = servers
        self.cells = apps.map { app in
            servers.map { server in Self.compatibility(contract: contract, app: app, server: server) }
        }
    }

    public func cell(app: Int, server: Int) -> Compatibility? {
        guard cells.indices.contains(app), cells[app].indices.contains(server) else { return nil }
        return cells[app][server]
    }

    /// Installs that cannot use the feature against `server`, in basis
    /// points. Saturating, and capped at 10 000 even if the export double
    /// counts.
    public func brokenBasisPoints(server: Int) -> Int {
        var total = 0
        for (index, app) in apps.enumerated() {
            if let compatibility = cell(app: index, server: server), !compatibility.isServable {
                total = Saturating.add(total, app.installBasisPoints)
            }
        }
        return min(total, 10_000)
    }

    /// Installs that are served against `server` but on a path where some
    /// answers or requests cannot cross (`degraded`), in basis points.
    public func degradedBasisPoints(server: Int) -> Int {
        var total = 0
        for (index, app) in apps.enumerated() {
            if case .degraded? = cell(app: index, server: server) {
                total = Saturating.add(total, app.installBasisPoints)
            }
        }
        return min(total, 10_000)
    }

    static func compatibility(contract: FeatureContract, app: AppBuild, server: ServerBuild) -> Compatibility {
        let appContract = contract.asShipped(upTo: app.shipped)
        let serverContract = contract.asShipped(upTo: server.shipped)
        // An app builds its request at its own revision, so it can only
        // speak revisions of its own major; a server keeps one handler per
        // major it still serves, generating at its newest revision there.
        let appVersions = appContract.versions(from: app.floor).filter { $0.major == app.shipped.major }
        let serverVersions = serverContract.versions(from: server.retiredBelow)
        guard let agreed = Negotiation.agree(client: appVersions, server: serverVersions),
              let serverHigh = serverVersions.filter({ $0.major == agreed.major }).max() else {
            return .noSharedVersion
        }
        // Every adjacent step the app's or the server's values will walk.
        let high = max(app.shipped, serverHigh)
        let span = contract.revisions.filter { $0.version >= agreed && $0.version <= high }
        let all = zip(span, span.dropFirst()).flatMap { ContractLinter.compare($0, $1) }
        let breaking = all.filter { $0.severity == .breaking }
        if !breaking.isEmpty { return .unsafe(agreed: agreed, findings: breaking) }
        let base: Compatibility
        if app.shipped > agreed {
            base = .clientAhead(agreed: agreed, client: app.shipped)
        } else if serverHigh > agreed {
            base = .serverAhead(agreed: agreed, server: serverHigh)
        } else {
            base = .native(agreed)
        }
        // Only the direction that actually downgrades can lose values: an
        // app that is ahead downgrades its *requests*; a server that is
        // ahead downgrades its *responses*. Upgrades never lose anything.
        let downgradedSide: ContractSide?
        switch base {
        case .clientAhead: downgradedSide = .request
        case .serverAhead: downgradedSide = .response
        default: downgradedSide = nil
        }
        let lossy = all.filter { $0.severity == .lossy && $0.side != nil && $0.side == downgradedSide }
        return lossy.isEmpty ? base : .degraded(base, lossy: lossy)
    }
}
