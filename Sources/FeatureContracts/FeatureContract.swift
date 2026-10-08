import Foundation

/// Where a feature's input is allowed to go. Escalating from the on-device
/// model to a server model moves user data across a trust boundary, so it is
/// declared per contract, in the shared package, and enforced by the router;
/// it is not a call-site decision.
public enum DataResidency: String, Hashable, Sendable, Codable {
    case onDeviceOnly
    case serverAllowed
}

/// One version of a feature's contract: what the caller sends, what the
/// model must return, and the prompt that produced it.
public struct ContractRevision: Hashable, Sendable {
    public var version: ContractVersion
    public var request: ObjectSchema
    public var response: ObjectSchema
    /// `{{field}}` placeholders are filled from the (upgraded) request.
    public var promptTemplate: String

    public init(version: ContractVersion, request: ObjectSchema, response: ObjectSchema, promptTemplate: String) {
        self.version = version
        self.request = request
        self.response = response
        self.promptTemplate = promptTemplate
    }

    /// FNV-1a 64 over the template's UTF-8 bytes, as 16 hex digits. Stable
    /// across processes, platforms and launches, unlike `Hasher`, which is
    /// randomly seeded per process. Both runtimes log it next to every
    /// answer, so a parity failure can be pinned to the exact prompt.
    public var promptFingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in promptTemplate.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // wrapping multiply is the algorithm, not an overflow bug
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Renders the prompt from the request schema's fields: a present value,
    /// else the field's default, else an empty string. So the model sees the
    /// same prompt for the same request whichever deploy answers it, native
    /// or across skew. Placeholders that name no request field are left
    /// verbatim, so a template typo shows up in the parity eval instead of
    /// vanishing.
    ///
    /// Single pass over the template: a substituted value is never scanned
    /// again, so user text that happens to contain `{{locale}}` reaches the
    /// model verbatim instead of being rewritten.
    public func renderPrompt(_ request: ContractValue) -> String {
        let fields = request.objectValue ?? [:]
        var output = ""
        var rest = promptTemplate[...]
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            // The placeholder is the *innermost* `{{…}}`: in `{{{text}}}` or
            // `{{a {{text}}` the name is `text`, and what precedes its last
            // `{{` is literal text.
            var inner = afterOpen[..<close.lowerBound]
            if let lastOpen = inner.range(of: "{{", options: .backwards) {
                output += "{{" + inner[..<lastOpen.lowerBound]
                inner = inner[lastOpen.upperBound...]
            }
            // Extra opening braces (`{{{text}}}`) are literal too.
            while inner.hasPrefix("{") {
                output += "{"
                inner = inner.dropFirst()
            }
            let name = String(inner)
            if let field = self.request.field(named: name) {
                let value = fields[name].flatMap { $0 == .null ? nil : $0 } ?? field.defaultValue
                switch value {
                case .string(let raw)?: output += raw
                case let other?: output += other.description
                case nil: break
                }
            } else {
                output += "{{\(name)}}"
            }
            rest = afterOpen[close.upperBound...]
        }
        output += rest
        return output
    }
}

/// A feature's full revision history. The *same value* is compiled into the
/// iOS app and into the server: that is the whole point of the package.
public struct FeatureContract: Hashable, Sendable {
    public var id: String
    public var residency: DataResidency
    /// Strictly increasing by version; validated by `ContractLinter`.
    public var revisions: [ContractRevision]

    public init(id: String, residency: DataResidency, revisions: [ContractRevision]) {
        self.id = id
        self.residency = residency
        self.revisions = revisions.sorted { $0.version < $1.version }
    }

    public var latest: ContractRevision? { revisions.last }

    public func revision(_ version: ContractVersion) -> ContractRevision? {
        revisions.first { $0.version == version }
    }

    /// The revisions a runtime built from this contract can speak, given the
    /// oldest one it still keeps (`floor`). Ascending.
    public func versions(from floor: ContractVersion?) -> [ContractVersion] {
        revisions.map(\.version).filter { version in floor.map { version >= $0 } ?? true }
    }

    /// This contract truncated to `version`: what an *older build* of the
    /// app or server has compiled in. Used to model skew honestly — an old
    /// binary cannot know about revisions that did not exist when it shipped.
    public func asShipped(upTo version: ContractVersion) -> FeatureContract {
        FeatureContract(id: id, residency: residency, revisions: revisions.filter { $0.version <= version })
    }

    /// Revisions strictly between `from` and `to` inclusive of `to`, in the
    /// order a value must walk them. Empty if either end is unknown or the
    /// versions are in different majors.
    func path(from: ContractVersion, to: ContractVersion) -> [ContractRevision] {
        guard from.major == to.major, revision(from) != nil, revision(to) != nil else { return [] }
        if from == to { return [] }
        if from < to {
            return revisions.filter { $0.version > from && $0.version <= to }
        }
        return revisions.filter { $0.version >= to && $0.version < from }.reversed()
    }
}
