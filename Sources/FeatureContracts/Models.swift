import Foundation

public enum ModelAvailability: Hashable, Sendable {
    case available
    case unavailable(reason: String)
}

/// A structured-output model: given a prompt and the response schema of a
/// contract revision, produce a value. On iOS this is where an adapter over
/// Foundation Models' guided generation goes; on the server, an adapter
/// over a hosted model (Gemini on Vertex AI, Claude, anything with JSON
/// output). The package ships neither adapter — see the README for why —
/// only the port, so the same router and parity harness run against both.
public protocol StructuredModel: Sendable {
    var name: String { get }
    func availability() async -> ModelAvailability
    func generate(prompt: String, schema: ObjectSchema) async throws -> ContractValue
}

/// Rough token estimate used to decide whether a prompt fits the on-device
/// context window. Four UTF-8 bytes per token overestimates for English and
/// underestimates for CJK; it is a routing heuristic, not a meter, and the
/// router treats it as one (the budget should leave headroom).
public enum TokenEstimate {
    public static func of(_ text: String) -> Int {
        Saturating.add(text.utf8.count, 3) / 4
    }
}
