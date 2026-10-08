import Foundation

/// What the app sends. `supported` lets the server pick a revision without a
/// separate handshake; `payloadVersion` says how `payload` is shaped.
public struct RequestEnvelope: Hashable, Sendable, Codable {
    public var contractID: String
    public var supported: [ContractVersion]
    public var payloadVersion: ContractVersion
    public var payload: ContractValue
    public var requestID: String

    public init(contractID: String, supported: [ContractVersion], payloadVersion: ContractVersion,
                payload: ContractValue, requestID: String) {
        self.contractID = contractID
        self.supported = supported
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.requestID = requestID
    }
}

public struct ResponseEnvelope: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case ok
        /// The server does not know `payloadVersion` (the app is newer).
        /// `version` names the revision to resend at. At most once.
        case renegotiate
        /// No shared revision: the app is older than the server's floor.
        case upgradeRequired
        case unknownContract
        case invalidRequest
        /// The model failed, or answered something the contract rejects.
        /// The server never forwards an unvalidated answer.
        case modelFailed
        /// The model's answer is valid, but the app's older revision cannot
        /// express it (a declared-lossy widening, e.g. a total above the old
        /// range). Distinct from `modelFailed`: nothing is broken, the app
        /// is just too old for this particular answer.
        case notExpressible
    }

    public var status: Status
    public var version: ContractVersion?
    public var payload: ContractValue?
    public var detail: String
    public var promptFingerprint: String?
    public var requestID: String

    public init(status: Status, version: ContractVersion? = nil, payload: ContractValue? = nil,
                detail: String = "", promptFingerprint: String? = nil, requestID: String) {
        self.status = status
        self.version = version
        self.payload = payload
        self.detail = detail
        self.promptFingerprint = promptFingerprint
        self.requestID = requestID
    }
}

/// Bytes in, bytes out. URLSession on iOS; in tests and the demo, a closure
/// that calls a `ContractEndpoint` in-process.
public protocol ContractTransport: Sendable {
    func send(_ body: Data) async throws -> Data
}

public struct InProcessTransport: ContractTransport {
    private let endpoint: ContractEndpoint

    public init(endpoint: ContractEndpoint) {
        self.endpoint = endpoint
    }

    public func send(_ body: Data) async throws -> Data {
        await endpoint.handle(data: body)
    }
}
