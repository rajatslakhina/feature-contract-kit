import Foundation

/// The server half. Transport-agnostic on purpose: a Hummingbird route on
/// Cloud Run is three lines around `handle(data:)` —
///
/// ```swift
/// router.post("/v1/features") { request, context in
///     let body = try await request.body.collect(upTo: 1 << 20)
///     return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: await endpoint.handle(data: Data(buffer: body)))))
/// }
/// ```
///
/// — and keeping the framework out of this package means the contract
/// package the *app* links has no server dependencies at all.
///
/// Stateless and `Sendable`: no actor, so no reentrancy across the model's
/// `await`. Every request carries everything needed to answer it.
public struct ContractEndpoint: Sendable {
    public var contracts: [String: FeatureContract]
    /// Oldest revision still served, per contract id.
    public var retiredBelow: [String: ContractVersion]
    public var model: any StructuredModel

    public init(contracts: [FeatureContract], retiredBelow: [String: ContractVersion] = [:], model: any StructuredModel) {
        var byID: [String: FeatureContract] = [:]
        for contract in contracts { byID[contract.id] = contract }
        self.contracts = byID
        self.retiredBelow = retiredBelow
        self.model = model
    }

    /// Request bodies above this are refused before decoding.
    public static let maximumBodyBytes = 1 << 20

    public func handle(data: Data) async -> Data {
        let response: ResponseEnvelope
        if data.count > Self.maximumBodyBytes {
            response = ResponseEnvelope(status: .invalidRequest, detail: "body over \(Self.maximumBodyBytes) bytes", requestID: "")
        } else if let request = try? JSONDecoder().decode(RequestEnvelope.self, from: data) {
            response = await handle(request)
        } else {
            response = ResponseEnvelope(status: .invalidRequest, detail: "undecodable envelope", requestID: "")
        }
        // Encoding a value built from validated parts cannot realistically
        // fail; if it ever does, an empty body decodes as a client error.
        return (try? Self.makeEncoder().encode(response)) ?? Data()
    }

    public func handle(_ request: RequestEnvelope) async -> ResponseEnvelope {
        let id = request.requestID
        guard let contract = contracts[request.contractID] else {
            return ResponseEnvelope(status: .unknownContract, detail: request.contractID, requestID: id)
        }
        let floor = retiredBelow[contract.id]
        let served = contract.versions(from: floor)
        guard let agreed = Negotiation.agree(client: request.supported, server: served) else {
            return ResponseEnvelope(status: .upgradeRequired, version: served.first,
                                    detail: "oldest served is \(served.first?.description ?? "none")", requestID: id)
        }
        guard served.contains(request.payloadVersion) else {
            // The app is newer than this deploy. Ask it to resend at
            // `agreed`; it downgrades its own request (it has every
            // revision compiled in, the server does not).
            return ResponseEnvelope(status: .renegotiate, version: agreed,
                                    detail: "\(request.payloadVersion) unknown here", requestID: id)
        }
        // Generate at the newest revision this server has for that major.
        guard let generation = contract.revisions.last(where: { $0.version.major == agreed.major }) else {
            return ResponseEnvelope(status: .upgradeRequired, detail: "no handler for major \(agreed.major)", requestID: id)
        }
        let input: ContractValue
        do {
            input = try SkewTranslator.translate(request.payload, side: .request, in: contract,
                                                 from: request.payloadVersion, to: generation.version)
        } catch {
            return ResponseEnvelope(status: .invalidRequest, detail: String(describing: error), requestID: id)
        }

        let output: ContractValue
        do {
            output = try await model.generate(prompt: generation.renderPrompt(input), schema: generation.response)
        } catch {
            return ResponseEnvelope(status: .modelFailed, detail: "\(model.name): \(error)",
                                    promptFingerprint: generation.promptFingerprint, requestID: id)
        }
        do {
            // Validates `output` against the generation revision first
            // (`invalidSource`), then walks it down to what the app reads.
            let answer = try SkewTranslator.translate(output, side: .response, in: contract,
                                                      from: generation.version, to: agreed)
            return ResponseEnvelope(status: .ok, version: agreed, payload: answer,
                                    promptFingerprint: generation.promptFingerprint, requestID: id)
        } catch TranslationError.notExpressible(let path, let detail, let version) {
            return ResponseEnvelope(status: .notExpressible, version: agreed,
                                    detail: "\(path) not expressible in \(version): \(detail)",
                                    promptFingerprint: generation.promptFingerprint, requestID: id)
        } catch {
            return ResponseEnvelope(status: .modelFailed, detail: String(describing: error),
                                    promptFingerprint: generation.promptFingerprint, requestID: id)
        }
    }

    /// A fresh encoder per call: `JSONEncoder` is a mutable class, and a
    /// shared static one is a data race the moment two requests overlap.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
