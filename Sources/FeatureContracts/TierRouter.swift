import Foundation

public struct RoutingPolicy: Hashable, Sendable {
    /// Prompts estimated above this many tokens skip the on-device model.
    public var onDeviceContextBudget: Int
    /// Whether an on-device answer that fails validation may be retried on
    /// the server tier. Never retried on the *same* tier: a model that
    /// produced an invalid answer for a prompt is not evidence it will
    /// produce a valid one for the same prompt, and the retry costs the
    /// user the latency either way.
    public var escalateOnInvalidOutput: Bool

    public init(onDeviceContextBudget: Int, escalateOnInvalidOutput: Bool = true) {
        self.onDeviceContextBudget = max(0, onDeviceContextBudget)
        self.escalateOnInvalidOutput = escalateOnInvalidOutput
    }
}

public enum Tier: Hashable, Sendable {
    case onDevice
    case server(ContractVersion)

    public var label: String {
        switch self {
        case .onDevice: return "on-device"
        case .server(let version): return "server @ \(version)"
        }
    }
}

public struct TraceStep: Hashable, Sendable, Identifiable {
    public enum Event: String, Hashable, Sendable {
        case requestRejected, skippedUnavailable, skippedContext, generated, modelError,
             outputRejected, answered, escalationForbidden, noServerTier, cancelled, serverFailed, renegotiated
    }
    public var id: Int
    public var tier: String
    public var event: Event
    public var detail: String
}

public enum RouteFailure: Hashable, Sendable {
    case invalidRequest
    case residencyForbidsEscalation
    case noTierAvailable
    case cancelled
    case serverFailed(String)
}

public struct RouteOutcome: Hashable, Sendable {
    public enum Result: Hashable, Sendable {
        case answered(ContractValue, tier: Tier)
        case failed(RouteFailure)
    }
    public var result: Result
    public var trace: [TraceStep]
    public var estimatedTokens: Int

    public var answer: ContractValue? {
        if case .answered(let value, _) = result { return value }
        return nil
    }
}

/// On-device first, server second, and nothing reaches the caller unless it
/// validates against the app's own revision of the contract.
///
/// A plain `Sendable` struct with no mutable state: two concurrent routes
/// cannot interleave through shared fields, so there is no actor and no
/// reentrancy to reason about across the two model `await`s. Each call
/// returns a full decision trace, because "why did this request go to the
/// server?" is the first question in every cost and privacy review.
public struct TierRouter: Sendable {
    public var contract: FeatureContract
    public var onDevice: any StructuredModel
    public var remote: (any RemoteContractAnswering)?
    public var policy: RoutingPolicy

    public init(contract: FeatureContract, onDevice: any StructuredModel,
                remote: (any RemoteContractAnswering)?, policy: RoutingPolicy) {
        self.contract = contract
        self.onDevice = onDevice
        self.remote = remote
        self.policy = policy
    }

    public func route(_ request: ContractValue, requestID: String) async -> RouteOutcome {
        var trace: [TraceStep] = []
        func log(_ tier: String, _ event: TraceStep.Event, _ detail: String) {
            trace.append(TraceStep(id: trace.count, tier: tier, event: event, detail: detail))
        }

        guard let revision = contract.latest else {
            log("router", .requestRejected, "contract has no revisions")
            return RouteOutcome(result: .failed(.invalidRequest), trace: trace, estimatedTokens: 0)
        }
        let requestIssues = Validator.validate(request, against: revision.request)
        guard requestIssues.isEmpty else {
            log("router", .requestRejected, requestIssues.map(\.description).joined(separator: "; "))
            return RouteOutcome(result: .failed(.invalidRequest), trace: trace, estimatedTokens: 0)
        }
        let prompt = revision.renderPrompt(request)
        let tokens = TokenEstimate.of(prompt)

        // Tier 1: on-device.
        let deviceName = onDevice.name
        switch await onDevice.availability() {
        case .unavailable(let reason):
            log(deviceName, .skippedUnavailable, reason)
        case .available where tokens > policy.onDeviceContextBudget:
            log(deviceName, .skippedContext, "~\(tokens) tokens > budget \(policy.onDeviceContextBudget)")
        case .available:
            do {
                let output = try await onDevice.generate(prompt: prompt, schema: revision.response)
                // Validate before describing: the output is untrusted, and
                // `Validator` rejects hostile nesting before anything walks it.
                let issues = Validator.validate(output, against: revision.response)
                log(deviceName, .generated, issues.contains { $0.kind == .tooDeep } ? "(nesting too deep to show)" : output.description)
                if issues.isEmpty {
                    log(deviceName, .answered, "valid against \(revision.version)")
                    return RouteOutcome(result: .answered(output, tier: .onDevice), trace: trace, estimatedTokens: tokens)
                }
                log(deviceName, .outputRejected, issues.map(\.description).joined(separator: "; "))
                if !policy.escalateOnInvalidOutput {
                    return RouteOutcome(result: .failed(.noTierAvailable), trace: trace, estimatedTokens: tokens)
                }
            } catch {
                log(deviceName, .modelError, String(describing: error))
            }
        }

        // Tier 2: server. Crossing this line sends user data off device.
        guard contract.residency == .serverAllowed else {
            log("router", .escalationForbidden, "\(contract.id) is onDeviceOnly")
            return RouteOutcome(result: .failed(.residencyForbidsEscalation), trace: trace, estimatedTokens: tokens)
        }
        guard let remote else {
            log("router", .noServerTier, "no server tier configured")
            return RouteOutcome(result: .failed(.noTierAvailable), trace: trace, estimatedTokens: tokens)
        }
        if Task.isCancelled {
            log("router", .cancelled, "before server call")
            return RouteOutcome(result: .failed(.cancelled), trace: trace, estimatedTokens: tokens)
        }
        do {
            let answer = try await remote.answer(request, requestID: requestID)
            if answer.renegotiated {
                log("server", .renegotiated, "app \(revision.version) resent at \(answer.servedVersion)")
            }
            let shape = answer.servedVersion == revision.version
                ? "served \(answer.servedVersion)"
                : "served \(answer.servedVersion), upgraded to \(revision.version)"
            log("server", .answered, "\(shape): \(answer.value)")
            return RouteOutcome(result: .answered(answer.value, tier: .server(answer.servedVersion)),
                                trace: trace, estimatedTokens: tokens)
        } catch {
            log("server", .serverFailed, String(describing: error))
            return RouteOutcome(result: .failed(.serverFailed(String(describing: error))), trace: trace, estimatedTokens: tokens)
        }
    }
}
