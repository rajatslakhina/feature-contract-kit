import Foundation

public struct RemoteAnswer: Hashable, Sendable {
    /// Already upgraded to the app's own revision.
    public var value: ContractValue
    /// The revision the server actually answered at.
    public var servedVersion: ContractVersion
    public var promptFingerprint: String?
    /// True when the request had to be resent at an older revision.
    public var renegotiated: Bool
}

public enum ContractClientError: Error, Hashable, Sendable, CustomStringConvertible {
    case noRevisions
    case upgradeRequired(oldestServed: ContractVersion?)
    case server(status: ResponseEnvelope.Status, detail: String)
    case renegotiationLoop
    case translation(TranslationError)
    case transport(String)
    case undecodableResponse
    case requestIDMismatch

    public var description: String {
        switch self {
        case .noRevisions: return "contract has no revisions"
        case .upgradeRequired(let version): return "upgrade required (oldest served \(version?.description ?? "?"))"
        case .server(let status, let detail): return "server \(status.rawValue): \(detail)"
        case .renegotiationLoop: return "server asked to renegotiate twice"
        case .translation(let error): return error.description
        case .transport(let detail): return "transport: \(detail)"
        case .undecodableResponse: return "undecodable response"
        case .requestIDMismatch: return "response is for a different request"
        }
    }
}

/// Anything that can answer a contract request remotely. `ContractClient`
/// is the real one; tests and the demo can substitute a fake.
public protocol RemoteContractAnswering: Sendable {
    func answer(_ request: ContractValue, requestID: String) async throws -> RemoteAnswer
}

/// The app half of the wire protocol. Stateless: it negotiates per call and
/// renegotiates at most once, so there is no cached "server version" to go
/// stale when a load balancer moves the app between an old and a new deploy
/// mid-rollout — the exact window where skew exists.
public struct ContractClient: RemoteContractAnswering {
    public var contract: FeatureContract
    public var floor: ContractVersion?
    public var transport: any ContractTransport

    public init(contract: FeatureContract, floor: ContractVersion? = nil, transport: any ContractTransport) {
        self.contract = contract
        self.floor = floor
        self.transport = transport
    }

    public func answer(_ request: ContractValue, requestID: String) async throws -> RemoteAnswer {
        guard let latest = contract.latest?.version else { throw ContractClientError.noRevisions }
        let supported = contract.versions(from: floor).filter { $0.major == latest.major }

        var payloadVersion = latest
        var payload = request
        var renegotiated = false
        // Two attempts: the original, and one resend at the agreed revision.
        for _ in 0..<2 {
            let envelope = RequestEnvelope(contractID: contract.id, supported: supported,
                                           payloadVersion: payloadVersion, payload: payload, requestID: requestID)
            let response = try await exchange(envelope)
            guard response.requestID == requestID else {
                // A body the server could not even decode comes back with an
                // empty id. Surface the server's own error, not a mismatch.
                if response.requestID.isEmpty, response.status != .ok, response.status != .renegotiate {
                    throw ContractClientError.server(status: response.status, detail: response.detail)
                }
                throw ContractClientError.requestIDMismatch
            }
            switch response.status {
            case .ok:
                guard let served = response.version, let body = response.payload,
                      supported.contains(served) else {
                    throw ContractClientError.server(status: .ok, detail: "ok without a usable version/payload")
                }
                do {
                    let value = try SkewTranslator.translate(body, side: .response, in: contract, from: served, to: latest)
                    return RemoteAnswer(value: value, servedVersion: served,
                                        promptFingerprint: response.promptFingerprint, renegotiated: renegotiated)
                } catch let error as TranslationError {
                    throw ContractClientError.translation(error)
                }
            case .renegotiate:
                // Strictly downward and bounded by the two-iteration loop, so a
                // misbehaving server cannot keep the app resending forever.
                guard let target = response.version, supported.contains(target), target < payloadVersion else {
                    throw ContractClientError.renegotiationLoop
                }
                do {
                    payload = try SkewTranslator.translate(request, side: .request, in: contract, from: latest, to: target)
                } catch let error as TranslationError {
                    throw ContractClientError.translation(error)
                }
                payloadVersion = target
                renegotiated = true
            case .upgradeRequired:
                throw ContractClientError.upgradeRequired(oldestServed: response.version)
            case .unknownContract, .invalidRequest, .modelFailed, .notExpressible:
                throw ContractClientError.server(status: response.status, detail: response.detail)
            }
        }
        throw ContractClientError.renegotiationLoop
    }

    private func exchange(_ envelope: RequestEnvelope) async throws -> ResponseEnvelope {
        let body: Data
        do {
            body = try JSONEncoder().encode(envelope)
        } catch {
            throw ContractClientError.transport("encode: \(error)")
        }
        let data: Data
        do {
            data = try await transport.send(body)
        } catch {
            throw ContractClientError.transport(String(describing: error))
        }
        guard let response = try? JSONDecoder().decode(ResponseEnvelope.self, from: data) else {
            throw ContractClientError.undecodableResponse
        }
        return response
    }
}
