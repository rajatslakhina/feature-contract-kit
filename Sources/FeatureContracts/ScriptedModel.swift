import Foundation

public struct ScriptedModelError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A deterministic `StructuredModel` driven by a closure. It is what the
/// tests, the parity-eval fixtures and the demo app run against, so every
/// routing and skew path can be exercised without Apple Intelligence
/// hardware or a cloud account — and so nothing in this repo pretends a
/// fixture is a real model.
public struct ScriptedModel: StructuredModel {
    public let name: String
    private let state: ModelAvailability
    private let respond: @Sendable (String, ObjectSchema) throws -> ContractValue

    public init(name: String, availability: ModelAvailability = .available,
                respond: @escaping @Sendable (_ prompt: String, _ schema: ObjectSchema) throws -> ContractValue) {
        self.name = name
        self.state = availability
        self.respond = respond
    }

    public func availability() async -> ModelAvailability { state }

    public func generate(prompt: String, schema: ObjectSchema) async throws -> ContractValue {
        try respond(prompt, schema)
    }
}
