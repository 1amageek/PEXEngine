import Foundation
import PEXCore

/// Maps standard tokens to canonical ownership without duplicating operator values.
struct PEXSPICEIdentity: Sendable, Codable {
    struct Node: Sendable, Codable {
        let ref: NodeRef
        let kind: NodeKind
        let instancePath: InstancePath?

        init(ref: NodeRef, kind: NodeKind, instancePath: InstancePath? = nil) {
            self.ref = ref; self.kind = kind; self.instancePath = instancePath
        }
    }

    static let marker = "* PEX_IDENTITY_V1 "
    let nodes: [String: Node]
    let elementKinds: [String: ElementKind]
    let referenceName: String
    let referenceToken: String
    /// Nil preserves the original generated annotation encoding for existing writers.
    var canonicalTerminals: Bool? = nil

    func comment() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.marker + (try encoder.encode(self)).base64EncodedString()
    }

    static func read(_ source: String, cornerID: PEXCornerID, caseInsensitive: Bool = true) throws -> Self? {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let annotations = lines.filter { $0.hasPrefix(marker) }
        guard !annotations.isEmpty else {
            if lines.contains(where: { $0.hasPrefix("* PEX backannotation generated") }) {
                throw PEXError.parseFailed(cornerID: cornerID, message: "Generated PEX SPICE is missing its identity annotation")
            }
            return nil
        }
        guard annotations.count == 1,
              let data = Data(base64Encoded: String(annotations[0].dropFirst(marker.count))) else {
            throw PEXError.parseFailed(cornerID: cornerID, message: "Invalid PEX SPICE identity annotation")
        }
        let identity: Self
        do { identity = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw PEXError.parseFailed(cornerID: cornerID, message: "Invalid PEX SPICE identity annotation", underlying: error) }
        guard !identity.referenceName.isEmpty, !identity.referenceToken.isEmpty,
              Set(identity.nodes.keys.map { caseInsensitive ? $0.lowercased() : $0 }).count == identity.nodes.count,
              Set(identity.nodes.values.map(\.ref)).count == identity.nodes.count,
              identity.nodes.values.allSatisfy({ !$0.ref.netName.value.isEmpty && !$0.ref.nodeName.value.isEmpty }),
              !identity.nodes.keys.contains(where: { caseInsensitive ? $0.caseInsensitiveCompare(identity.referenceToken) == .orderedSame : $0 == identity.referenceToken }) else {
            throw PEXError.parseFailed(cornerID: cornerID, message: "Noninjective or inconsistent PEX SPICE identity annotation")
        }
        return identity
    }

    static func encodedToken(_ ref: NodeRef) -> String {
        "PEX_N_\(hex(ref.netName.value))_\(hex(ref.nodeName.value))"
    }

    static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
