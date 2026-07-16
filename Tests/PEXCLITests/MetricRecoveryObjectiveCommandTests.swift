import Foundation
import Testing
@testable import PEXCLICore
@testable import PEXCore
@testable import PEXEngine

@Suite("Metric recovery objective command")
struct MetricRecoveryObjectiveCommandTests {
    @Test func arguments() throws {
        let command = try MetricRecoveryObjectiveCommand(arguments: [
            "--summary", "/tmp/pex-summary.json",
            "--comparison", "/tmp/pex-comparison.json",
            "--metric-report", "/tmp/post-layout-metrics.json",
            "--layout", "/tmp/layout.gds",
            "--source-netlist", "/tmp/source.spice",
            "--technology", "/tmp/pex-tech.json",
            "--out", "/tmp/pex-recovery.json",
            "--problem-id", "pex-recovery-1",
            "--json",
        ])

        #expect(command.summaryURL.path(percentEncoded: false) == "/tmp/pex-summary.json")
        #expect(command.comparisonURL?.path(percentEncoded: false) == "/tmp/pex-comparison.json")
        #expect(command.metricReportURL?.path(percentEncoded: false) == "/tmp/post-layout-metrics.json")
        #expect(command.layoutPath == "/tmp/layout.gds")
        #expect(command.sourceNetlistPath == "/tmp/source.spice")
        #expect(command.technologyPath == "/tmp/pex-tech.json")
        #expect(command.outputURL?.path(percentEncoded: false) == "/tmp/pex-recovery.json")
        #expect(command.problemID == "pex-recovery-1")
        #expect(command.jsonOutput)
    }

    @Test func rejectsOptionTokenAsOptionValue() {
        let cases: [([String], String)] = [
            (["--summary", "--json"], "--summary requires a value"),
            (["--summary", "/tmp/summary.json", "--comparison", "--json"], "--comparison requires a value"),
            (["--summary", "/tmp/summary.json", "--metric-report", "--out"], "--metric-report requires a value"),
            (["--summary", "/tmp/summary.json", "--layout", "--source-netlist"], "--layout requires a value"),
            (["--summary", "/tmp/summary.json", "--netlist", "--technology"], "--netlist requires a value"),
            (["--summary", "/tmp/summary.json", "--technology", "--problem-id"], "--technology requires a value"),
            (["--summary", "/tmp/summary.json", "--problem-id", "--json"], "--problem-id requires a value"),
        ]

        for (arguments, expectedMessage) in cases {
            expectInvalidInput(arguments: arguments, contains: expectedMessage)
        }
    }

    @Test func rejectsMissingSummary() {
        expectInvalidInput(
            arguments: ["--comparison", "/tmp/comparison.json"],
            contains: "--summary <path> is required"
        )
    }

    @Test func buildsAndWritesActionablePlanningProblem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-metric-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let summaryURL = directory.appending(path: "pex-summary.json")
        let comparisonURL = directory.appending(path: "pex-ir-comparison.json")
        let metricURL = directory.appending(path: "post-layout-metric.json")
        let layoutURL = directory.appending(path: "layout.gds")
        let netlistURL = directory.appending(path: "source.spice")
        let technologyURL = directory.appending(path: "pex-tech.json")
        let outputURL = directory.appending(path: "planning/pex-recovery.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeSummary()).write(to: summaryURL, options: .atomic)
        try encoder.encode(try makeComparison()).write(to: comparisonURL, options: .atomic)
        try encoder.encode(makeMetricReport()).write(to: metricURL, options: .atomic)
        try Data("GDSII payload".utf8).write(to: layoutURL, options: .atomic)
        try Data(".subckt top in out\n.ends\n".utf8).write(to: netlistURL, options: .atomic)
        try Data(#"{"processName":"test","stack":[]}"#.utf8).write(to: technologyURL, options: .atomic)

        let command = try MetricRecoveryObjectiveCommand(arguments: [
            "--summary", summaryURL.path(percentEncoded: false),
            "--comparison", comparisonURL.path(percentEncoded: false),
            "--metric-report", metricURL.path(percentEncoded: false),
            "--layout", layoutURL.path(percentEncoded: false),
            "--source-netlist", netlistURL.path(percentEncoded: false),
            "--technology", technologyURL.path(percentEncoded: false),
            "--out", outputURL.path(percentEncoded: false),
            "--problem-id", "run-pex-recovery",
        ])
        let problem = try command.buildProblem()
        try await command.run()
        let saved = try JSONDecoder().decode(
            PEXMetricRecoveryPlanningProblem.self,
            from: Data(contentsOf: outputURL)
        )

        #expect(problem.problemID == "run-pex-recovery")
        #expect(problem.status == "actionable")
        #expect(problem.summary.objectiveCount >= 5)
        #expect(problem.summary.hotspotCount >= 2)
        #expect(problem.summary.comparisonViolationCount == 1)
        #expect(problem.summary.metricFailureCount >= 3)
        #expect(problem.inputArtifacts.contains {
            $0.id.rawValue == "pex-summary" && $0.digest.hexadecimalValue.count == 64
        })
        #expect(problem.inputArtifacts.contains { $0.id.rawValue == "layout-ref" })
        #expect(problem.objectives.contains { $0.target == "resolve-parasitic-ir-regression" })
        #expect(problem.objectives.contains { $0.target == "post-layout-metric-gate-passed" })
        #expect(problem.objectives.contains { $0.target == "simulation-metric-within-tolerance" })
        #expect(problem.hotspots.contains { $0.netName == "OUT" })
        #expect(problem.candidateActions.first?.operationID == "pex.metric-recovery-objective")
        #expect(problem.candidateActions.first?.maturity == "implemented")
        #expect(problem.verificationGates.contains("simulation-metric-gate"))
        #expect(saved == problem)
    }

    @Test func planningProblemWithoutMetricReportDoesNotRequireMissingMetricInputRef() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pex-metric-recovery-no-metric-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemporaryItem(directory) }

        let summaryURL = directory.appending(path: "pex-summary.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(makeSummary()).write(to: summaryURL, options: .atomic)

        let problem = try PEXMetricRecoveryObjectiveBuilder().build(
            summary: makeSummary(),
            summaryPath: summaryURL.path(percentEncoded: false),
            metricReport: nil,
            metricReportPath: nil
        )

        let action = try #require(problem.candidateActions.first)
        #expect(!problem.inputArtifacts.contains { $0.id.rawValue == "post-layout-metric-report" })
        #expect(!action.requiredInputRefs.contains("post-layout-metric-report"))
        #expect(!problem.verificationGates.contains("simulation-metric-gate"))
    }

    @Test func decodesPostLayoutComparisonStyleMetricReport() throws {
        let json = """
        {
          "status": "failed",
          "gateStatus": "failed",
          "gateViolations": ["oscillation frequency drift"],
          "diagnostics": ["post-layout waveform delta exceeded tolerance"],
          "comparedVariables": [
            {"variableName": "v(out)", "pointCount": 128, "maxAbsoluteDelta": 0.12, "maxRelativeDelta": 0.2}
          ],
          "requiredPostVariables": [
            {"variableName": "i(vdd)", "present": false}
          ],
          "oscillationMetrics": [
            {"variableName": "v(out)", "violations": ["frequency"], "frequencyRelativeDelta": 0.15}
          ],
          "maxAbsoluteDelta": 0.12,
          "maxRelativeDelta": 0.2
        }
        """
        let data = try #require(json.data(using: .utf8))
        let report = try JSONDecoder().decode(PEXMetricRecoveryMetricReport.self, from: data)

        #expect(report.diagnostics.first?.message == "post-layout waveform delta exceeded tolerance")
        #expect(report.comparedVariables.first?.variableName == "v(out)")
        #expect(report.requiredPostVariables.first?.present == false)
        #expect(report.oscillationMetrics.first?.frequencyRelativeDelta == 0.15)
    }

    private func makeSummary() -> PEXRunSummaryReport {
        PEXRunSummaryReport(
            manifestURL: URL(filePath: "/tmp/pex-run/manifest.json"),
            completeness: PEXArtifactCompletenessReport(
                status: .incomplete,
                issues: [
                    PEXArtifactCompletenessIssue(
                        kind: .missingIR,
                        artifactID: "parasitic-ir-ss",
                        cornerID: PEXCornerID("ss"),
                        message: "Corner ss is missing ParasiticIR."
                    ),
                ]
            ),
            summary: PEXRunSummary(
                runID: "run-pex",
                status: PEXRunStatus.partialSuccess.rawValue,
                backendID: "magic",
                corners: [
                    PEXCornerParasiticSummary(
                        cornerID: "tt",
                        status: PEXRunStatus.success.rawValue,
                        netCount: 2,
                        elementCount: 4,
                        totalGroundCapF: 1.2e-12,
                        totalCouplingCapF: 3e-13,
                        totalCapacitanceF: 1.5e-12,
                        totalResistanceOhm: 42,
                        parasiticIRArtifactID: "parasitic-ir-tt",
                        topNets: [
                            PEXNetParasiticSummary(
                                name: "OUT",
                                groundCapF: 1e-12,
                                couplingCapF: 2e-13,
                                resistanceOhm: 40,
                                nodeCount: 3
                            ),
                            PEXNetParasiticSummary(
                                name: "CLK",
                                groundCapF: 2e-13,
                                couplingCapF: 1e-13,
                                resistanceOhm: 2,
                                nodeCount: 2
                            ),
                        ],
                        diagnostics: [
                            PEXRunSummaryDiagnostic(
                                severity: "warning",
                                code: "high-capacitance",
                                message: "OUT capacitance dominates the corner."
                            ),
                        ]
                    ),
                    PEXCornerParasiticSummary(
                        cornerID: "ss",
                        status: PEXRunStatus.failed.rawValue,
                        netCount: 0,
                        elementCount: 0,
                        topNets: []
                    ),
                ]
            )
        )
    }

    private func makeComparison() throws -> PEXIRComparisonReport {
        let baseline = ParasiticNet(
            name: NetName("OUT"),
            nodes: [],
            totalGroundCapF: 1e-12,
            totalCouplingCapF: 0,
            totalResistanceOhm: 10
        )
        let candidate = ParasiticNet(
            name: NetName("OUT"),
            nodes: [],
            totalGroundCapF: 1.8e-12,
            totalCouplingCapF: 0,
            totalResistanceOhm: 15
        )
        let baselineIR = ParasiticIR(
            version: "1.0",
            cornerID: PEXCornerID("tt"),
            units: .canonical,
            nets: [baseline],
            elements: [],
            metadata: [:]
        )
        let candidateIR = ParasiticIR(
            version: "1.0",
            cornerID: PEXCornerID("tt"),
            units: .canonical,
            nets: [candidate],
            elements: [],
            metadata: [:]
        )
        return PEXIRComparisonReport(
            status: "failed",
            baseline: PEXIRComparisonInput(
                artifact: try comparisonArtifact(path: "/tmp/base.json", digest: String(repeating: "a", count: 64)),
                ir: baselineIR
            ),
            candidate: PEXIRComparisonInput(
                artifact: try comparisonArtifact(path: "/tmp/candidate.json", digest: String(repeating: "b", count: 64)),
                ir: candidateIR
            ),
            thresholds: PEXIRComparisonThresholds(maxCapDeltaF: 1e-13),
            summary: PEXIRComparisonSummary(
                matchedNetCount: 1,
                addedNetCount: 0,
                removedNetCount: 0,
                changedNetCount: 1,
                violationCount: 1,
                totalCapDeltaF: 8e-13,
                totalResistanceDeltaOhm: 5,
                worstCapDeltaNet: "OUT",
                worstCapDeltaF: 8e-13,
                worstResistanceDeltaNet: "OUT",
                worstResistanceDeltaOhm: 5
            ),
            netDiffs: [
                PEXIRNetComparison(
                    netName: "OUT",
                    status: "changed",
                    baseline: PEXIRNetMetrics(net: baseline),
                    candidate: PEXIRNetMetrics(net: candidate),
                    deltaGroundCapF: 8e-13,
                    deltaCouplingCapF: 0,
                    deltaTotalCapF: 8e-13,
                    deltaResistanceOhm: 5,
                    relativeTotalCapDelta: 0.8,
                    relativeResistanceDelta: 0.5
                ),
            ],
            violations: [
                PEXIRComparisonViolation(
                    netName: "OUT",
                    kind: "capacitance_absolute_regression",
                    observed: 8e-13,
                    limit: 1e-13,
                    message: "OUT capacitance regression exceeds limit."
                ),
            ]
        )
    }

    private func comparisonArtifact(path: String, digest: String) throws -> ArtifactReference {
        ArtifactReference(
            locator: ArtifactLocator(
                location: try ArtifactLocation(fileURL: URL(filePath: path)),
                role: .input,
                kind: .parasitics,
                format: .json
            ),
            digest: try ContentDigest(algorithm: .sha256, hexadecimalValue: digest),
            byteCount: 32
        )
    }

    private func makeMetricReport() -> PEXMetricRecoveryMetricReport {
        PEXMetricRecoveryMetricReport(
            status: "failed",
            source: "post-layout-comparison",
            gateStatus: "failed",
            gateViolations: ["delay exceeded tolerance"],
            diagnostics: [
                PEXMetricRecoveryMetricDiagnostic(
                    severity: "error",
                    code: "SIMULATION_METRIC_OUT_OF_TOLERANCE",
                    message: "Delay exceeded tolerance."
                ),
            ],
            verdicts: [
                PEXMetricRecoveryMetricVerdict(
                    name: "tpd",
                    status: "failed",
                    value: 1.4e-9,
                    target: 1e-9,
                    tolerance: 1e-10
                ),
            ],
            comparedVariables: [
                PEXMetricRecoveryComparedVariable(
                    variableName: "v(out)",
                    pointCount: 100,
                    maxAbsoluteDelta: 0.25,
                    maxRelativeDelta: 0.4
                ),
            ],
            requiredPostVariables: [
                PEXMetricRecoveryRequiredVariable(variableName: "i(vdd)", present: false),
            ],
            oscillationMetrics: [
                PEXMetricRecoveryOscillationMetric(
                    variableName: "v(out)",
                    violations: ["frequency"],
                    frequencyRelativeDelta: 0.1
                ),
            ],
            maxAbsoluteDelta: 0.25,
            maxRelativeDelta: 0.4
        )
    }

    private func removeTemporaryItem(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove temporary item at \(url.path(percentEncoded: false)): \(error)")
        }
    }

    private func expectInvalidInput(arguments: [String], contains expectedMessage: String) {
        do {
            _ = try MetricRecoveryObjectiveCommand(arguments: arguments)
            Issue.record("Expected invalid input for arguments: \(arguments)")
        } catch let error as PEXError {
            guard error.kind == .invalidInput else {
                Issue.record("Expected invalidInput, got \(error)")
                return
            }
            #expect(error.message.contains(expectedMessage))
        } catch {
            Issue.record("Expected PEXError.invalidInput, got \(error)")
        }
    }
}
