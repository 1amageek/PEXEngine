import Foundation
import Testing
@testable import PEXCLICore
@testable import PEXCore

@Suite("PEX action domain command")
struct PEXActionDomainCommandTests {
    @Test func actionDomainCommandEmitsPEXPlanningOperations() throws {
        let snapshot = PEXActionDomainExporter().snapshot()

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.domainID == "pex-extraction")
        #expect(snapshot.ownerPackages == ["PEXEngine"])

        let operationIDs = Set(snapshot.operations.map(\.operationID))
        #expect(operationIDs.contains("pex.extract"))
        #expect(operationIDs.contains("pex.parse-spef"))
        #expect(operationIDs.contains("pex.write-spef"))
        #expect(operationIDs.contains("pex.compare-ir"))
        #expect(operationIDs.contains("pex.evaluate-spef-corpus"))
        #expect(operationIDs.contains("pex.export-corpus-observations"))
        #expect(operationIDs.contains("pex.export-evidence-packet"))
        #expect(operationIDs.contains("pex.export-extractor-evidence-packet"))
        #expect(operationIDs.contains("pex.audit-extractor-physical-bounds"))
        #expect(operationIDs.contains("pex.summarize-run"))
        #expect(operationIDs.contains("pex.metric-recovery-objective"))

        let extract = try #require(snapshot.operations.first { $0.operationID == "pex.extract" })
        #expect(extract.maturity == "implemented")
        #expect(extract.producedArtifacts.contains("pex-summary"))
        #expect(extract.verificationGates.contains("pex-artifacts"))

        let recovery = try #require(snapshot.operations.first { $0.operationID == "pex.metric-recovery-objective" })
        #expect(recovery.maturity == "implemented")
        #expect(recovery.producedArtifacts.contains("planning-problem"))
        #expect(recovery.producedArtifacts.contains("pex-metric-recovery-planning-problem"))
        #expect(recovery.verificationGates.contains("simulation-metric-gate"))

        let writeSPEF = try #require(snapshot.operations.first { $0.operationID == "pex.write-spef" })
        #expect(writeSPEF.maturity == "implemented")
        #expect(writeSPEF.inputRefs == ["parasitic-ir-ref", "spef-output-ref", "optional-spef-write-report-ref"])
        #expect(writeSPEF.producedArtifacts.contains("spef"))
        #expect(writeSPEF.verificationGates.contains("parasitic-ir-validation"))

        let compareIR = try #require(snapshot.operations.first { $0.operationID == "pex.compare-ir" })
        #expect(compareIR.maturity == "implemented")
        #expect(compareIR.inputRefs.contains("baseline-parasitic-ir-ref"))
        #expect(compareIR.inputRefs.contains("candidate-parasitic-ir-ref"))
        #expect(compareIR.inputRefs.contains("optional-comparison-mode"))
        #expect(compareIR.inputRefs.contains("optional-equivalence-tolerance"))
        #expect(compareIR.producedArtifacts == ["pex-ir-comparison-report"])
        #expect(compareIR.verificationGates.contains("threshold-evaluation"))
        #expect(compareIR.verificationGates.contains("optional-semantic-equivalence"))
    }

    @Test func actionDomainSnapshotPinsEveryOperationContract() throws {
        let snapshot = PEXActionDomainExporter().snapshot()
        let operationIDs = snapshot.operations.map(\.operationID)

        #expect(operationIDs.count == Set(operationIDs).count)
        #expect(Set(operationIDs) == Set([
            "pex.extract",
            "pex.parse-spef",
            "pex.write-spef",
            "pex.compare-ir",
            "pex.evaluate-spef-corpus",
            "pex.export-corpus-observations",
            "pex.export-evidence-packet",
            "pex.export-extractor-evidence-packet",
            "pex.audit-extractor-physical-bounds",
            "pex.summarize-run",
            "pex.metric-recovery-objective",
        ]))

        for operation in snapshot.operations {
            #expect(!operation.inputRefs.isEmpty, "\(operation.operationID) must expose input references")
            #expect(!operation.preconditions.isEmpty, "\(operation.operationID) must expose preconditions")
            #expect(!operation.effects.isEmpty, "\(operation.operationID) must expose effects")
            #expect(!operation.producedArtifacts.isEmpty, "\(operation.operationID) must expose produced artifacts")
            #expect(!operation.verificationGates.isEmpty, "\(operation.operationID) must expose verification gates")
            #expect(operation.inputRefs.count == Set(operation.inputRefs).count)
            #expect(operation.preconditions.count == Set(operation.preconditions).count)
            #expect(operation.effects.count == Set(operation.effects).count)
            #expect(operation.producedArtifacts.count == Set(operation.producedArtifacts).count)
            #expect(operation.verificationGates.count == Set(operation.verificationGates).count)
            #expect(["implemented", "planned"].contains(operation.maturity))
        }

        let implemented = snapshot.operations.filter { $0.maturity == "implemented" }
        #expect(implemented.count == 11)
        for operation in implemented {
            let gates = Set(operation.verificationGates)
            #expect(
                !gates.intersection([
                    "artifact-integrity",
                    "schema-validation",
                    "parasitic-ir-validation",
                    "corpus-observation-validation",
                ]).isEmpty,
                "\(operation.operationID) must include a machine-checkable gate"
            )
        }

        let extract = try #require(snapshot.operations.first { $0.operationID == "pex.extract" })
        #expect(Set(extract.inputRefs) == Set(["layout-ref", "source-netlist-ref", "technology-ref", "corner-set"]))
        #expect(Set(extract.producedArtifacts).isSuperset(of: ["pex-artifact-manifest", "parasitic-ir", "pex-summary"]))
        #expect(Set(extract.verificationGates).isSuperset(of: [
            "tool-trust",
            "pex-artifacts",
            "pex-flow-artifacts",
            "artifact-integrity",
        ]))

        let writeSPEF = try #require(snapshot.operations.first { $0.operationID == "pex.write-spef" })
        #expect(writeSPEF.effects.contains("spef-produced"))
        #expect(writeSPEF.effects.contains("spef-write-report-produced"))
        #expect(writeSPEF.effects.contains("optional-round-trip-validation-produced"))
        #expect(writeSPEF.verificationGates == ["parasitic-ir-validation", "artifact-integrity", "optional-spef-round-trip"])

        let compareIR = try #require(snapshot.operations.first { $0.operationID == "pex.compare-ir" })
        #expect(compareIR.effects.contains("ir-comparison-report-produced"))
        #expect(compareIR.effects.contains("parasitic-regression-diagnostics-produced"))
        #expect(compareIR.effects.contains("optional-semantic-equivalence-diagnostics-produced"))
        #expect(compareIR.verificationGates == [
            "parasitic-ir-validation",
            "schema-validation",
            "threshold-evaluation",
            "optional-semantic-equivalence",
            "artifact-integrity",
        ])

        let audit = try #require(snapshot.operations.first { $0.operationID == "pex.audit-extractor-physical-bounds" })
        #expect(audit.producedArtifacts == ["pex-extractor-physical-bounds-audit"])
        #expect(audit.verificationGates.contains("physical-bound-evaluation"))

        let summarize = try #require(snapshot.operations.first { $0.operationID == "pex.summarize-run" })
        #expect(summarize.inputRefs == ["pex-run-directory"])
        #expect(summarize.preconditions.contains("pex-artifact-manifest-readable"))
        #expect(summarize.effects.contains("multi-corner-spread-produced"))
        #expect(summarize.effects.contains("worst-corner-identified"))
        #expect(summarize.verificationGates == ["artifact-integrity"])

        let recovery = try #require(snapshot.operations.first { $0.operationID == "pex.metric-recovery-objective" })
        #expect(recovery.maturity == "implemented")
        #expect(Set(recovery.inputRefs).isSuperset(of: [
            "pex-summary",
            "pex-ir-comparison-report",
            "post-layout-metric-report",
            "source-netlist-ref",
            "layout-ref",
        ]))
        #expect(Set(recovery.verificationGates).isSuperset(of: [
            "simulation-metric-gate",
            "pex-summary-gate",
            "artifact-integrity",
        ]))
    }

    @Test func actionDomainCommandParsesJSONFlag() throws {
        let command = try ActionDomainCommand(arguments: ["--json"])

        #expect(command.jsonOutput)
    }

    @Test func actionDomainCommandRejectsUnknownArgument() throws {
        #expect(throws: PEXError.self) {
            _ = try ActionDomainCommand(arguments: ["--unknown"])
        }
    }
}
