import Testing
import Foundation
@testable import PEXCore

@Suite("PEXCore Model Tests")
struct PEXCoreModelTests {
    @Test func runIDCreation() {
        let id1 = PEXRunID()
        let id2 = PEXRunID()
        #expect(id1 != id2)
    }

    @Test func cornerIDStringLiteral() {
        let id: PEXCornerID = "tt_25c_1v0"
        #expect(id.value == "tt_25c_1v0")
        #expect(id.description == "tt_25c_1v0")
    }

    @Test func netNameEquality() {
        let a = NetName("VDD")
        let b = NetName("VDD")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func cornerFromStringID() {
        let corner = PEXCorner(id: "ss_125c_0v81")
        #expect(corner.id.value == "ss_125c_0v81")
        #expect(corner.name == "ss_125c_0v81")
        #expect(corner.temperature == nil)
    }

    @Test func runStatusRawValues() {
        #expect(PEXRunStatus.success.rawValue == "success")
        #expect(PEXRunStatus.partialSuccess.rawValue == "partialSuccess")
        #expect(PEXRunStatus.failed.rawValue == "failed")
    }

    @Test func backendSelectionMock() {
        let sel = PEXBackendSelection.mock()
        #expect(sel.backendID == "mock")
        #expect(sel.executablePath == nil)
    }

    @Test func runOptionsDefault() {
        let opts = PEXRunOptions.default
        #expect(opts.extractMode == .rc)
        #expect(opts.includeCouplingCaps == true)
        #expect(opts.maxParallelJobs == 2)
    }

    @Test func extractionRulesDefault() {
        let rules = ExtractionRules.default
        #expect(rules.reductionPolicy == .none)
        #expect(rules.minCapacitanceF == nil)
    }

    @Test func parasiticUnitsCanonical() {
        let units = ParasiticUnits.canonical
        #expect(units.resistance == .ohm)
        #expect(units.capacitance == .farad)
        #expect(units.coordinate == .micrometer)
    }

    @Test func cornerResultWarningsField() {
        let result = PEXCornerResult(
            cornerID: "tt", status: .success, ir: nil,
            rawOutputURLs: [], logURL: nil,
            warnings: [PEXWarning(stage: .irValidation, cornerID: "tt", message: "test warning")],
            metrics: PEXCornerMetrics(durationSeconds: 0, netCount: 0, elementCount: 0, peakMemoryBytes: nil)
        )
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].message == "test warning")
    }

    @Test func errorInternalInvariantViolation() {
        let error = PEXError.internalInvariantViolation("test invariant")
        #expect(error.kind == .internalInvariantViolation)
        #expect(error.stage == .reporting)
        #expect(error.message == "test invariant")
    }

    @Test func artifactRecordUsesRunRelativePathAndHashMetadata() throws {
        let record = PEXArtifactRecord(
            id: "raw-tt",
            kind: .rawOutput,
            stage: .backendExecution,
            cornerID: "tt",
            relativePath: try PEXArtifactPath("raw/tt/tt.spef"),
            sha256: String(repeating: "a", count: 64),
            byteCount: 5,
            status: .available
        )
        #expect(record.relativePath.value == "raw/tt/tt.spef")
        #expect(record.status == .available)
        #expect(record.sha256 != nil)
        #expect(record.byteCount == 5)
    }

    @Test func artifactPathRejectsAbsoluteOrEscapingPaths() {
        do {
            _ = try PEXArtifactPath("/tmp/raw.spef")
            #expect(Bool(false), "Should reject absolute paths")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("relative"))
        } catch {
            Issue.record("Unexpected artifact path error: \(error)")
        }
        do {
            _ = try PEXArtifactPath("../raw.spef")
            #expect(Bool(false), "Should reject escaping paths")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
            #expect(error.message.contains("escape"))
        } catch {
            Issue.record("Unexpected artifact path error: \(error)")
        }
    }

    @Test func extractorRunRequestCarriesProfileAndCornerMetadata() {
        let profile = PEXProcessProfileReference(
            profileID: "sky130.signoff",
            pdkID: "sky130",
            source: "signoff-pdk-profile.json",
            requirementID: "magic",
            pdkRoot: "/pdk/root",
            primaryDeckPath: "/pdk/root/libs.tech/magic/sky130A.magicrc"
        )
        let capabilities = PEXBackendCapabilities(
            supportsCouplingCaps: true,
            supportsCornerSweep: false,
            supportsIncremental: false,
            supportsRCReduction: false,
            nativeOutputFormats: [.spice]
        )
        let request = PEXRunRequest(
            layoutURL: URL(filePath: "/tmp/layout.gds"),
            layoutFormat: .gds,
            sourceNetlistURL: URL(filePath: "/tmp/source.spice"),
            sourceNetlistFormat: .spice,
            topCell: "INV",
            corners: [
                PEXCorner(
                    id: "tt",
                    name: "Typical",
                    temperature: 25,
                    voltage: 1.8,
                    parameters: ["model": "tt"]
                ),
            ],
            technology: .jsonFile(URL(filePath: "/tmp/technology.json")),
            processProfile: profile,
            backendSelection: PEXBackendSelection(backendID: "magic"),
            options: .default
        )

        let extractorRequest = PEXExtractorRunRequest(
            runRequest: request,
            capabilities: capabilities
        )

        #expect(extractorRequest.backendID == "magic")
        #expect(extractorRequest.processProfile?.profileID == "sky130.signoff")
        #expect(extractorRequest.technology.path == "/tmp/technology.json")
        #expect(extractorRequest.corners.first?.cornerID == "tt")
        #expect(extractorRequest.corners.first?.temperatureC == 25)
        #expect(extractorRequest.corners.first?.voltageV == 1.8)
        #expect(extractorRequest.requestedOutputFormats == [.spice])
        #expect(extractorRequest.requestedArtifactKinds.contains(.parasiticIR))
        #expect(extractorRequest.requestedArtifactKinds.contains(.spefRoundTrip))
    }

    @Test func extractorRunResultSeparatesReadinessDiagnosticsFromCornerStatus() {
        let request = PEXExtractorRunRequest(
            backendID: "magic",
            topCell: "INV",
            layoutFormat: .gds,
            sourceNetlistFormat: .spice,
            technology: PEXTechnologyReference(sourceKind: "jsonFile", path: "technology.json"),
            corners: [PEXExtractorCornerMetadata(cornerID: "tt", name: "tt")],
            options: .default,
            requestedOutputFormats: [.spice]
        )
        let readiness = PEXExtractorToolReadiness(
            backendID: "magic",
            status: .blocked,
            reason: "Magic toolchain is unavailable.",
            diagnostics: [
                PEXExtractorDiagnostic(
                    diagnosticID: "magic:missing",
                    code: "extractor_toolchain_missing",
                    severity: .blocked,
                    message: "Magic executable was not found."
                )
            ],
            suggestedActions: ["set_MAGIC_BIN"]
        )
        let result = PEXExtractorRunResult(
            request: request,
            readiness: readiness,
            status: .failed,
            cornerResults: [
                PEXExtractorRunResult.CornerSummary(
                    cornerID: "tt",
                    status: .failed,
                    netCount: 0,
                    elementCount: 0,
                    rawOutputCount: 0,
                    warningCount: 1,
                    unitSystem: "canonical",
                    totalGroundCapF: 1e-15,
                    totalCouplingCapF: 2e-16,
                    totalCapacitanceF: 1.2e-15,
                    totalResistanceOhm: 3.0,
                    rawOutputArtifactIDs: ["raw-tt"],
                    parasiticIRArtifactID: "ir-tt",
                    spefRoundTripArtifactID: "spef-roundtrip-tt",
                    failureStage: .backendExecution,
                    failureMessage: "Magic extraction failed."
                )
            ],
            artifactIDs: ["input-request", "report-summary"],
            diagnostics: readiness.diagnostics
        )

        #expect(result.readiness.status == .blocked)
        #expect(result.cornerResults.first?.failureStage == .backendExecution)
        #expect(result.cornerResults.first?.spefRoundTripArtifactID == "spef-roundtrip-tt")
        #expect(result.cornerResults.first?.totalCapacitanceF == 1.2e-15)
        #expect(result.multiCorner.comparisonStatus == .noSuccessfulCorners)
        #expect(result.multiCorner.failedCornerIDs == ["tt"])
        #expect(result.multiCorner.totalCapacitance.observedCornerCount == 0)
        #expect(result.diagnostics.first?.code == "extractor_toolchain_missing")
        #expect(result.artifactIDs == ["input-request", "report-summary"])
    }

    @Test func extractorRunResultRejectsMissingMultiCornerSummary() throws {
        let json = """
        {
          "request": {
            "backendID": "mock",
            "topCell": "TOP",
            "layoutFormat": "gds",
            "sourceNetlistFormat": "spice",
            "technology": { "sourceKind": "jsonFile", "path": "technology.json" },
            "corners": [
              { "cornerID": { "value": "tt" }, "name": "tt", "parameters": {} },
              { "cornerID": { "value": "ss" }, "name": "ss", "parameters": {} }
            ],
            "options": {
              "extractMode": "rc",
              "includeCouplingCaps": true,
              "maxParallelJobs": 2,
              "emitRawArtifacts": true,
              "emitIRJSON": true,
              "strictValidation": true
            },
            "requestedOutputFormats": ["spef"],
            "requestedArtifactKinds": ["rawOutput", "parasiticIR", "spefRoundTrip", "report"]
          },
          "readiness": {
            "backendID": "mock",
            "status": "ready",
            "reason": "ready",
            "diagnostics": [],
            "suggestedActions": []
          },
          "status": "success",
          "cornerResults": [
            {
              "cornerID": { "value": "tt" },
              "status": "success",
              "netCount": 1,
              "elementCount": 2,
              "rawOutputCount": 1,
              "warningCount": 0,
              "unitSystem": "canonical",
              "totalGroundCapF": 1.0e-15,
              "totalCouplingCapF": 1.0e-16,
              "totalCapacitanceF": 1.1e-15,
              "totalResistanceOhm": 4.0,
              "rawOutputArtifactIDs": ["raw-tt"],
              "parasiticIRArtifactID": "ir-tt",
              "spefRoundTripArtifactID": "spef-tt"
            },
            {
              "cornerID": { "value": "ss" },
              "status": "success",
              "netCount": 1,
              "elementCount": 2,
              "rawOutputCount": 1,
              "warningCount": 0,
              "unitSystem": "canonical",
              "totalGroundCapF": 2.0e-15,
              "totalCouplingCapF": 2.0e-16,
              "totalCapacitanceF": 2.2e-15,
              "totalResistanceOhm": 8.0,
              "rawOutputArtifactIDs": ["raw-ss"],
              "parasiticIRArtifactID": "ir-ss",
              "spefRoundTripArtifactID": "spef-ss"
            }
          ],
          "artifactIDs": ["ir-tt", "ir-ss"],
          "diagnostics": []
        }
        """

        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PEXExtractorRunResult.self, from: data)
        }
    }

    @Test func evidencePacketRejectsMissingEvidenceCollections() throws {
        let json = """
        {
          "schemaVersion": 1,
          "packetID": "incomplete-packet",
          "domain": "pex.parasitic-evidence",
          "subject": {
            "kind": "pex-run",
            "identifier": "run-1"
          },
          "intent": {
            "summary": "inspect run",
            "cornerIDs": [],
            "targetNets": [],
            "requestedObservations": []
          },
          "confidence": {
            "level": "unknown",
            "rationale": "incomplete artifact",
            "strengths": [],
            "uncertainties": ["missing collections"]
          }
        }
        """

        let data = try #require(json.data(using: .utf8))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PEXEvidencePacket.self, from: data)
        }
    }

    @Test func evidencePacketDecodeRestoresCanonicalCollections() throws {
        let json = """
        {
          "schemaVersion": 1,
          "packetID": "packet-1",
          "domain": "pex.parasitic-evidence",
          "subject": {
            "kind": "spef-corpus",
            "identifier": "fixture-manifest"
          },
          "intent": {
            "summary": "decode retained packet",
            "cornerIDs": ["ss", "", "tt", "ss"],
            "targetNets": ["out", "", "vdd", "out"],
            "requestedObservations": ["physical", "", "physical", "artifact"]
          },
          "inputs": [
            {
              "artifactID": "manifest",
              "path": "fixture-manifest.json",
              "role": "intent",
              "kind": "corpus-manifest",
              "format": "json"
            }
          ],
          "readiness": [
            {
              "component": "packet-artifacts",
              "status": "blocked",
              "reason": "artifact evidence is incomplete",
              "artifactIDs": ["manifest", "", "manifest"],
              "suggestedActions": ["inspect_artifact", "", "rerun_packet_export"]
            }
          ],
          "artifacts": [],
          "normalizedViews": [
            {
              "viewID": "summary",
              "kind": "parasitic-summary",
              "scope": "corpus",
              "summaryMetrics": {},
              "summaryCounts": {},
              "sourceArtifactIDs": ["manifest", "", "manifest"]
            }
          ],
          "metrics": [],
          "diagnostics": [
            {
              "diagnosticID": "diag-1",
              "code": "artifact_missing_hash",
              "category": "artifact_integrity",
              "severity": "blocked",
              "message": "Artifact hash is missing.",
              "artifactIDs": ["manifest", "", "manifest"],
              "suggestedActions": ["inspect_artifact", "", "rerun_packet_export"]
            }
          ],
          "failureClassifications": [
            {
              "classificationID": "classification-1",
              "failureClass": "parse_failure",
              "severity": "error",
              "reasonCodes": ["parse_failed", "", "parse_failed"],
              "caseIDs": ["case-a", "", "case-a"],
              "cornerIDs": ["tt", "", "tt"],
              "metricIDs": ["metric-a", "", "metric-a"],
              "diagnosticIDs": ["diag-1", "", "diag-1"],
              "artifactIDs": ["manifest", "", "manifest"],
              "suggestedActions": ["inspect_parse_log", "", "inspect_parse_log"]
            }
          ],
          "confidence": {
            "level": "low",
            "rationale": "retained packet contains artifact integrity diagnostics",
            "strengths": ["schema", "", "schema"],
            "uncertainties": ["missing-hash", "", "missing-hash"]
          },
          "decisionHints": [
            {
              "hintID": "hint-1",
              "priority": "high",
              "action": "inspect_artifact",
              "rationale": "artifact evidence is incomplete",
              "relatedDiagnosticIDs": ["diag-1", "", "diag-1"],
              "artifactIDs": ["manifest", "", "manifest"]
            }
          ],
          "coverageTags": ["pex.magic", "", "pex.magic", "pex.physical-value"],
          "relatedEvidenceIDs": ["tool-evidence", "", "tool-evidence"]
        }
        """

        let data = try #require(json.data(using: .utf8))
        let packet = try JSONDecoder().decode(PEXEvidencePacket.self, from: data)

        #expect(packet.intent.cornerIDs == ["ss", "tt"])
        #expect(packet.intent.targetNets == ["out", "vdd"])
        #expect(packet.intent.requestedObservations == ["artifact", "physical"])
        #expect(packet.readiness.first?.artifactIDs == ["manifest"])
        #expect(packet.readiness.first?.suggestedActions == ["inspect_artifact", "rerun_packet_export"])
        #expect(packet.normalizedViews.first?.sourceArtifactIDs == ["manifest"])
        #expect(packet.diagnostics.first?.artifactIDs == ["manifest"])
        #expect(packet.diagnostics.first?.suggestedActions == ["inspect_artifact", "rerun_packet_export"])

        let classification = try #require(packet.failureClassifications.first)
        #expect(classification.reasonCodes == ["parse_failed"])
        #expect(classification.caseIDs == ["case-a"])
        #expect(classification.cornerIDs == ["tt"])
        #expect(classification.metricIDs == ["metric-a"])
        #expect(classification.diagnosticIDs == ["diag-1"])
        #expect(classification.artifactIDs == ["manifest"])
        #expect(classification.suggestedActions == ["inspect_parse_log"])

        #expect(packet.confidence.strengths == ["schema"])
        #expect(packet.confidence.uncertainties == ["missing-hash"])
        #expect(packet.decisionHints.first?.relatedDiagnosticIDs == ["diag-1"])
        #expect(packet.decisionHints.first?.artifactIDs == ["manifest"])
        #expect(packet.coverageTags == ["pex.magic", "pex.physical-value"])
        #expect(packet.relatedEvidenceIDs == ["tool-evidence"])
    }
}
