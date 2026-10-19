import Foundation
import Testing
import CircuiteFoundation
import PEXTestSupport
@testable import PEXCore

@Suite("Admitted backend output contract", .timeLimit(.minutes(1)))
struct PEXBackendOutputTests {
    private func ir(units: ParasiticUnits = .canonical, missingEndpoint: Bool = false) -> ParasiticIR {
        let net = NetName("SIGNAL"), a = NodeRef(netName: NetName("SIGNAL"), nodeName: NodeName("A"))
        return ParasiticIR(version: ParasiticIR.currentVersion, cornerID: "tt", units: units,
            nets: [.init(name: net, nodes: [.init(name: a.nodeName, kind: .pin, instancePath: nil, coordinate: nil),
                .init(name: NodeName("ISOLATED"), kind: .internal, instancePath: nil, coordinate: nil)],
                totalGroundCapF: 1e-15, totalCouplingCapF: 0, totalResistanceOhm: 1)],
            elements: [.init(id: "C1", kind: missingEndpoint ? .resistor : .capacitor, nodeA: a, nodeB: nil, value: 1e-15, source: .calculated)], metadata: [:])
    }

    @Test func rawAndCanonicalPayloadsHaveExplicitDifferentAdmission() throws {
        let identity = try PEXTestExecutionIdentity.make(backendID: "contract")
        let raw = PEXRawOutput(format: .spef, fileURLs: [URL(filePath: "/fixture/output.spef")])
        let rawResult = try PEXAdapterExecutionResult(output: .raw(raw), generatedArtifacts: [], executionIdentity: identity)
        #expect(rawResult.output.rawOutput == raw && rawResult.canonicalValidationWarnings.isEmpty)
        let canonical = try PEXAdapterExecutionResult(output: .canonical(ir()), generatedArtifacts: [], executionIdentity: identity)
        #expect(canonical.output.rawOutput == nil)
        #expect(canonical.canonicalValidationWarnings == [.disconnectedNode(nodeName: "ISOLATED")])
        for value in [rawResult, canonical] {
            let encoded = try JSONEncoder().encode(value)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("canonicalValidationWarnings"))
            let decoded = try JSONDecoder().decode(PEXAdapterExecutionResult.self, from: encoded)
            #expect(decoded == value && decoded.canonicalValidationWarnings == value.canonicalValidationWarnings)
            #expect(Set([decoded, value]).count == 1)
        }
    }

    @Test func topologyEvidenceCannotDecodeNegativeCountsAndIsRetainedInDiagnosticResult() throws {
        let identity = try PEXTestExecutionIdentity.make(backendID: "contract")
        let topology = try PEXPhysicalTopology(openNetCount: 1, shortComponentCount: 0, uncontactedTerminalCount: 1)
        #expect(!topology.isSatisfied)
        let value = try PEXAdapterExecutionResult(output: .canonical(ir()), generatedArtifacts: [],
            executionIdentity: identity, physicalTopology: topology)
        #expect(try JSONDecoder().decode(PEXAdapterExecutionResult.self, from: JSONEncoder().encode(value)).physicalTopology == topology)
        #expect(throws: PEXBackendResultError.invalidPhysicalTopology) {
            try JSONDecoder().decode(PEXPhysicalTopology.self,
                from: Data("{\"openNetCount\":-1,\"shortComponentCount\":0,\"uncontactedTerminalCount\":0}".utf8))
        }
    }

    @Test func missingRawFilesAndExternalCanonicalClaimsFail() throws {
        let identity = try PEXTestExecutionIdentity.make(backendID: "contract")
        #expect(throws: PEXBackendResultError.missingRawFiles) {
            try PEXAdapterExecutionResult(output: .raw(.init(format: .spef, fileURLs: [])), generatedArtifacts: [], executionIdentity: identity)
        }
        #expect(throws: PEXBackendResultError.nonlocalRawFile) {
            try PEXAdapterExecutionResult(output: .raw(.init(format: .spef, fileURLs: [try #require(URL(string: "https://example.invalid/output.spef"))])),
                generatedArtifacts: [], executionIdentity: identity)
        }
        let external = try PEXBackendExecutionIdentity(producer: identity.producer, binaryDigest: identity.binaryDigest,
            invocation: .externalProcess(executable: "/fixture/tool"), environment: identity.environment)
        #expect(throws: PEXBackendResultError.canonicalRequiresInProcessInvocation) {
            try PEXAdapterExecutionResult(output: .canonical(ir()), generatedArtifacts: [], executionIdentity: external)
        }
    }

    @Test func canonicalValidationCannotBeBypassedByDecoding() throws {
        let identity = try PEXTestExecutionIdentity.make(backendID: "contract")
        let result = try PEXAdapterExecutionResult(output: .canonical(ir()), generatedArtifacts: [], executionIdentity: identity)
        let badUnits = ParasiticUnits(resistance: .kiloOhm, capacitance: .picoFarad, coordinate: .nanometer)
        for (payload, expected) in [(PEXBackendOutput.canonical(ir(units: badUnits)), PEXBackendResultError.noncanonicalUnits),
            (.canonical(ir(missingEndpoint: true)), .invalidCanonicalIR([.missingEndpoint(elementID: "C1", kind: .resistor)])),
            (.raw(.init(format: .spef, fileURLs: [])), .missingRawFiles)] {
            #expect(throws: expected) { try PEXAdapterExecutionResult(output: payload, generatedArtifacts: [], executionIdentity: identity) }
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            object["output"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
            #expect(throws: expected) {
                try JSONDecoder().decode(PEXAdapterExecutionResult.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func decodedCodeIdentityMustMatchItsProducerBuild() throws {
        let identity = try PEXTestExecutionIdentity.make(backendID: "contract")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any])
        var producer = try #require(object["producer"] as? [String: Any])
        producer["build"] = String(repeating: "0", count: 64); object["producer"] = producer
        #expect(throws: PEXError.self) {
            try JSONDecoder().decode(PEXBackendExecutionIdentity.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let encoded = try JSONEncoder().encode(identity)
        #expect(try JSONDecoder().decode(PEXBackendExecutionIdentity.self, from: encoded) == identity)
    }
}
