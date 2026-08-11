import CryptoKit
import Foundation
import PEXCore
import CircuiteFoundation

public struct SPEFCorpusRunner: Sendable {
    public init() {}

    public func run(
        manifestURL: URL,
        fixtureDirectory: URL? = nil
    ) throws -> SPEFCorpus.Report {
        let manifestData = try readManifestData(from: manifestURL)
        let manifest = try decodeManifest(from: manifestData)
        let resolvedFixtureDirectory = fixtureDirectory ?? manifestURL.deletingLastPathComponent()
        let caseResults = manifest.fixtures.map { fixture in
            runFixture(fixture, fixtureDirectory: resolvedFixtureDirectory)
        }
        return try report(
            manifestURL: manifestURL,
            manifestData: manifestData,
            fixtureDirectory: resolvedFixtureDirectory,
            manifest: manifest,
            caseResults: caseResults
        )
    }

    private func readManifestData(from manifestURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: manifestURL)
        } catch {
            throw PEXError.parseFailed(
                cornerID: "spef-corpus",
                message: "Failed to read SPEF corpus manifest",
                underlying: error
            )
        }
    }

    private func decodeManifest(from manifestData: Data) throws -> SPEFCorpus.Manifest {
        do {
            return try JSONDecoder().decode(SPEFCorpus.Manifest.self, from: manifestData)
        } catch {
            throw PEXError.parseFailed(
                cornerID: "spef-corpus",
                message: "Failed to decode SPEF corpus manifest",
                underlying: error
            )
        }
    }

    private func report(
        manifestURL: URL,
        manifestData: Data,
        fixtureDirectory: URL,
        manifest: SPEFCorpus.Manifest,
        caseResults: [SPEFCorpus.CaseResult]
    ) throws -> SPEFCorpus.Report {
        let summary = SPEFCorpus.Summary(caseResults: caseResults)
        let evaluation = manifest.evaluationPolicy.evaluate(summary: summary)
        return SPEFCorpus.Report(
            manifestPath: manifestURL.path(percentEncoded: false),
            manifest: manifest,
            sourceArtifacts: try sourceArtifacts(
                manifestURL: manifestURL,
                manifestData: manifestData,
                fixtureDirectory: fixtureDirectory,
                manifest: manifest
            ),
            summary: summary,
            evaluation: evaluation,
            caseResults: caseResults
        )
    }

    private func sourceArtifacts(
        manifestURL: URL,
        manifestData: Data,
        fixtureDirectory: URL,
        manifest: SPEFCorpus.Manifest
    ) throws -> [SPEFCorpus.SourceArtifact] {
        var artifacts = [try artifactReference(
            logicalID: "corpus-manifest",
            url: manifestURL,
            data: manifestData,
            kind: .other,
            format: .json
        )]
        for (index, fixture) in manifest.fixtures.enumerated() {
            let fixtureURL = fixtureDirectory.appending(path: fixture.fileName)
            let fixtureData: Data
            do {
                fixtureData = try Data(contentsOf: fixtureURL)
            } catch {
                continue
            }
            artifacts.append(try artifactReference(
                logicalID: "corpus-input-\(index + 1)",
                url: fixtureURL,
                data: fixtureData,
                kind: .parasitics,
                format: .spef
            ))
        }
        return artifacts
    }

    private func artifactReference(
        logicalID: String,
        url: URL,
        data: Data,
        kind: ArtifactKind,
        format: ArtifactFormat
    ) throws -> SPEFCorpus.SourceArtifact {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return SPEFCorpus.SourceArtifact(
            logicalID: logicalID,
            reference: try ArtifactReference(
                digest: try ContentDigest(algorithm: .sha256, hexadecimalValue: digest),
                byteCount: UInt64(data.count),
                descriptor: ArtifactDescriptor(
                role: .input,
                kind: kind,
                format: format
                )
            ),
            path: url.path(percentEncoded: false)
        )
    }

    private func runFixture(
        _ fixture: SPEFCorpus.Fixture,
        fixtureDirectory: URL
    ) -> SPEFCorpus.CaseResult {
        let fixtureURL = fixtureDirectory.appending(path: fixture.fileName)
        switch loadFixtureInput(fixture: fixture, fixtureURL: fixtureURL) {
        case .success(let input):
            return evaluateFixtureInput(input)
        case .failure(let failures):
            return caseResult(fixture: fixture, failures: failures)
        }
    }

    private func loadFixtureInput(
        fixture: SPEFCorpus.Fixture,
        fixtureURL: URL
    ) -> SPEFCorpusFixtureInputLoad {
        let data: Data
        switch readFixtureData(fixture: fixture, fixtureURL: fixtureURL) {
        case .success(let fixtureData):
            data = fixtureData
        case .failure(let failure):
            return .failure([failure])
        }

        var failures = provenanceFailures(fixture: fixture, data: data)

        let source: String
        switch decodeFixtureSource(data: data, fixture: fixture) {
        case .success(let fixtureSource):
            source = fixtureSource
        case .failure(let failure):
            failures.append(failure)
            return .failure(failures)
        }

        return .success(SPEFCorpusFixtureInput(
            fixture: fixture,
            source: source,
            failures: failures
        ))
    }

    private func evaluateFixtureInput(_ input: SPEFCorpusFixtureInput) -> SPEFCorpus.CaseResult {
        switch parseFixtureInput(input) {
        case .success(let parsed):
            return evaluateParsedFixture(parsed)
        case .failure(let fixture, let observedParseSummary, let failures):
            return caseResult(
                fixture: fixture,
                observedParseSummary: observedParseSummary,
                failures: failures
            )
        }
    }

    private func parseFixtureInput(_ input: SPEFCorpusFixtureInput) -> SPEFCorpusFixtureParseLoad {
        var failures = input.failures
        let tree: SPEFParseTree
        switch parseFixture(source: input.source, fileName: input.fixture.fileName) {
        case .success(let parseTree):
            tree = parseTree
        case .failure(let failure):
            failures.append(failure)
            return .failure(input.fixture, nil, failures)
        }

        let observedParseSummary = SPEFCorpus.ParseSummary(tree: tree)
        failures.append(contentsOf: parseSummaryFailures(
            tree: tree,
            observed: observedParseSummary,
            fixture: input.fixture
        ))

        return .success(SPEFCorpusParsedFixture(
            fixture: input.fixture,
            tree: tree,
            observedParseSummary: observedParseSummary,
            failures: failures
        ))
    }

    private func evaluateParsedFixture(_ parsed: SPEFCorpusParsedFixture) -> SPEFCorpus.CaseResult {
        var failures = parsed.failures
        let ir: ParasiticIR
        switch lowerFixture(tree: parsed.tree, fileName: parsed.fixture.fileName) {
        case .success(let loweredIR):
            ir = loweredIR
        case .failure(let failure):
            failures.append(failure)
            return caseResult(
                fixture: parsed.fixture,
                observedParseSummary: parsed.observedParseSummary,
                failures: failures
            )
        }

        let validation = ParasiticIRValidator().validate(ir)
        failures.append(contentsOf: validationFailures(
            errorCount: validation.errors.count,
            fileName: parsed.fixture.fileName
        ))

        let observedLoweredSummary = loweredSummary(ir: ir, expected: parsed.fixture.loweredSummary)
        failures.append(contentsOf: loweredSummaryFailures(
            observed: observedLoweredSummary,
            expected: parsed.fixture.loweredSummary,
            fileName: parsed.fixture.fileName
        ))

        return caseResult(
            fixture: parsed.fixture,
            observedParseSummary: parsed.observedParseSummary,
            observedLoweredSummary: observedLoweredSummary,
            validationErrorCount: validation.errors.count,
            validationWarningCount: validation.warnings.count,
            failures: failures
        )
    }

    private func readFixtureData(
        fixture: SPEFCorpus.Fixture,
        fixtureURL: URL
    ) -> SPEFCorpusFixtureDataRead {
        do {
            return .success(try Data(contentsOf: fixtureURL))
        } catch {
            return .failure(SPEFCorpus.CaseFailure(
                code: "fixture_read_failed",
                category: "fixture_io",
                message: "Failed to read fixture \(fixture.fileName): \(error)",
                suggestedActions: [
                    "check_fixture_path",
                    "verify_manifest_fixture_directory",
                ]
            ))
        }
    }

    private func provenanceFailures(
        fixture: SPEFCorpus.Fixture,
        data: Data
    ) -> [SPEFCorpus.CaseFailure] {
        var failures: [SPEFCorpus.CaseFailure] = []
        let actualHash = sha256Hex(data)
        if actualHash != fixture.sha256 {
            failures.append(SPEFCorpus.CaseFailure(
                code: "sha256_mismatch",
                category: "provenance_mismatch",
                message: "Fixture SHA-256 does not match manifest for \(fixture.fileName)",
                observedText: actualHash,
                expectedText: fixture.sha256,
                suggestedActions: [
                    "verify_fixture_source_commit",
                    "refresh_fixture_manifest_hash",
                ]
            ))
        }
        if data.count != fixture.byteCount {
            failures.append(SPEFCorpus.CaseFailure(
                code: "byte_count_mismatch",
                category: "provenance_mismatch",
                message: "Fixture byte count does not match manifest for \(fixture.fileName)",
                observedText: "\(data.count)",
                expectedText: "\(fixture.byteCount)",
                suggestedActions: [
                    "verify_fixture_source_commit",
                    "refresh_fixture_manifest_hash",
                ]
            ))
        }
        return failures
    }

    private func decodeFixtureSource(
        data: Data,
        fixture: SPEFCorpus.Fixture
    ) -> SPEFCorpusFixtureSourceDecode {
        guard let source = String(data: data, encoding: .utf8) else {
            return .failure(SPEFCorpus.CaseFailure(
                code: "fixture_utf8_decode_failed",
                category: "fixture_io",
                message: "Fixture \(fixture.fileName) is not valid UTF-8 text",
                suggestedActions: [
                    "check_fixture_encoding",
                    "regenerate_spef_as_utf8",
                ]
            ))
        }
        return .success(source)
    }

    private func parseFixture(
        source: String,
        fileName: String
    ) -> SPEFCorpusParseAttempt {
        var lexer = SPEFLexer(source: source, fileName: fileName)
        do {
            return .success(try SPEFParser().parse(tokens: lexer.tokenize()))
        } catch {
            return .failure(SPEFCorpus.CaseFailure(
                code: "parse_failed",
                category: "parse_failure",
                message: "SPEF parse failed for \(fileName): \(error)",
                observedText: "\(error)",
                suggestedActions: [
                    "inspect_spef_syntax",
                    "check_extractor_spef_dialect",
                    "reduce_to_minimal_parse_case",
                ]
            ))
        }
    }

    private func parseSummaryFailures(
        tree: SPEFParseTree,
        observed: SPEFCorpus.ParseSummary,
        fixture: SPEFCorpus.Fixture
    ) -> [SPEFCorpus.CaseFailure] {
        var failures: [SPEFCorpus.CaseFailure] = []
        if tree.header.designName != fixture.designName {
            failures.append(SPEFCorpus.CaseFailure(
                code: "design_name_mismatch",
                category: "structure_mismatch",
                message: "Parsed design name does not match manifest for \(fixture.fileName)",
                observedText: tree.header.designName,
                expectedText: fixture.designName,
                suggestedActions: [
                    "verify_fixture_manifest_design_name",
                    "check_spef_design_header",
                ]
            ))
        }
        if observed != fixture.parseSummary {
            failures.append(SPEFCorpus.CaseFailure(
                code: "parse_summary_mismatch",
                category: "structure_mismatch",
                message: "Parsed SPEF structural counts do not match manifest for \(fixture.fileName)",
                observedText: "\(observed)",
                expectedText: "\(fixture.parseSummary)",
                suggestedActions: [
                    "inspect_spef_structure_sections",
                    "verify_fixture_manifest_parse_summary",
                ]
            ))
        }
        return failures
    }

    private func lowerFixture(
        tree: SPEFParseTree,
        fileName: String
    ) -> SPEFCorpusLoweringAttempt {
        do {
            return .success(try SPEFLowering().lower(tree, cornerID: "openroad"))
        } catch {
            return .failure(SPEFCorpus.CaseFailure(
                code: "lowering_failed",
                category: "lowering_failure",
                message: "SPEF lowering failed for \(fileName): \(error)",
                observedText: "\(error)",
                suggestedActions: [
                    "inspect_name_map_and_node_references",
                    "check_coupling_cap_reciprocity",
                    "reduce_to_minimal_lowering_case",
                ]
            ))
        }
    }

    private func validationFailures(
        errorCount: Int,
        fileName: String
    ) -> [SPEFCorpus.CaseFailure] {
        guard errorCount > 0 else { return [] }
        return [
            SPEFCorpus.CaseFailure(
                code: "ir_validation_failed",
                category: "ir_validation",
                message: "Lowered ParasiticIR has \(errorCount) validation errors for \(fileName)",
                observedText: "\(errorCount)",
                expectedText: "0",
                suggestedActions: [
                    "inspect_lowered_parasitic_ir",
                    "check_unit_normalization",
                ]
            )
        ]
    }

    private func caseResult(
        fixture: SPEFCorpus.Fixture,
        observedParseSummary: SPEFCorpus.ParseSummary? = nil,
        observedLoweredSummary: SPEFCorpus.LoweredSummary? = nil,
        validationErrorCount: Int = 0,
        validationWarningCount: Int = 0,
        failures: [SPEFCorpus.CaseFailure]
    ) -> SPEFCorpus.CaseResult {
        SPEFCorpus.CaseResult(
            fileName: fixture.fileName,
            designName: fixture.designName,
            passed: failures.isEmpty,
            coverageTags: fixture.coverageTags,
            observedParseSummary: observedParseSummary,
            observedLoweredSummary: observedLoweredSummary,
            validationErrorCount: validationErrorCount,
            validationWarningCount: validationWarningCount,
            failures: failures
        )
    }

    private func loweredSummary(
        ir: ParasiticIR,
        expected: SPEFCorpus.LoweredSummary
    ) -> SPEFCorpus.LoweredSummary {
        SPEFCorpus.LoweredSummary(
            netCount: ir.nets.count,
            elementCount: ir.elements.count,
            capacitorElementCount: ir.elements.filter { $0.kind == .capacitor }.count,
            couplingElementCount: ir.elements.filter { $0.kind == .coupling }.count,
            resistorElementCount: ir.elements.filter { $0.kind == .resistor }.count,
            inductorElementCount: ir.elements.filter { $0.kind == .inductor }.count,
            totalGroundCapF: ir.nets.reduce(0) { $0 + $1.totalGroundCapF },
            totalCouplingCapF: ir.nets.reduce(0) { $0 + $1.totalCouplingCapF },
            totalResistanceOhm: ir.nets.reduce(0) { $0 + $1.totalResistanceOhm },
            totalInductanceH: ir.elements.filter { $0.kind == .inductor }.reduce(0) { $0 + $1.value },
            capTolerance: expected.capTolerance,
            resistanceTolerance: expected.resistanceTolerance,
            inductanceTolerance: expected.inductanceTolerance
        )
    }

    private func loweredSummaryFailures(
        observed: SPEFCorpus.LoweredSummary,
        expected: SPEFCorpus.LoweredSummary,
        fileName: String
    ) -> [SPEFCorpus.CaseFailure] {
        var failures: [SPEFCorpus.CaseFailure] = []
        appendCountFailure(
            &failures,
            code: "lowered_net_count_mismatch",
            fileName: fileName,
            observed: observed.netCount,
            expected: expected.netCount
        )
        appendCountFailure(
            &failures,
            code: "lowered_element_count_mismatch",
            fileName: fileName,
            observed: observed.elementCount,
            expected: expected.elementCount
        )
        appendCountFailure(
            &failures,
            code: "lowered_capacitor_count_mismatch",
            fileName: fileName,
            observed: observed.capacitorElementCount,
            expected: expected.capacitorElementCount
        )
        appendCountFailure(
            &failures,
            code: "lowered_coupling_count_mismatch",
            fileName: fileName,
            observed: observed.couplingElementCount,
            expected: expected.couplingElementCount
        )
        appendCountFailure(
            &failures,
            code: "lowered_resistor_count_mismatch",
            fileName: fileName,
            observed: observed.resistorElementCount,
            expected: expected.resistorElementCount
        )
        appendCountFailure(
            &failures,
            code: "lowered_inductor_count_mismatch",
            fileName: fileName,
            observed: observed.inductorElementCount,
            expected: expected.inductorElementCount
        )
        appendDoubleFailure(
            &failures,
            code: "total_ground_cap_mismatch",
            fileName: fileName,
            observed: observed.totalGroundCapF,
            expected: expected.totalGroundCapF,
            tolerance: expected.capTolerance
        )
        appendDoubleFailure(
            &failures,
            code: "total_coupling_cap_mismatch",
            fileName: fileName,
            observed: observed.totalCouplingCapF,
            expected: expected.totalCouplingCapF,
            tolerance: expected.capTolerance
        )
        appendDoubleFailure(
            &failures,
            code: "total_resistance_mismatch",
            fileName: fileName,
            observed: observed.totalResistanceOhm,
            expected: expected.totalResistanceOhm,
            tolerance: expected.resistanceTolerance
        )
        appendDoubleFailure(
            &failures,
            code: "total_inductance_mismatch",
            fileName: fileName,
            observed: observed.totalInductanceH,
            expected: expected.totalInductanceH,
            tolerance: expected.inductanceTolerance
        )
        return failures
    }

    private func appendCountFailure(
        _ failures: inout [SPEFCorpus.CaseFailure],
        code: String,
        fileName: String,
        observed: Int,
        expected: Int
    ) {
        guard observed != expected else { return }
        failures.append(SPEFCorpus.CaseFailure(
            code: code,
            category: "physical_structure_mismatch",
            message: "\(fileName): observed \(observed), expected \(expected)",
            observedText: "\(observed)",
            expectedText: "\(expected)",
            suggestedActions: [
                "verify_fixture_manifest_lowered_summary",
                "inspect_lowered_parasitic_ir",
            ]
        ))
    }

    private func appendDoubleFailure(
        _ failures: inout [SPEFCorpus.CaseFailure],
        code: String,
        fileName: String,
        observed: Double,
        expected: Double,
        tolerance: Double
    ) {
        guard abs(observed - expected) > tolerance else { return }
        failures.append(SPEFCorpus.CaseFailure(
            code: code,
            category: "physical_bound_mismatch",
            message: "\(fileName): observed \(observed), expected \(expected), tolerance \(tolerance)",
            observedDouble: observed,
            expectedDouble: expected,
            tolerance: tolerance,
            suggestedActions: [
                "verify_fixture_manifest_physical_bounds",
                "check_extractor_units",
                "inspect_top_parasitic_nets",
            ]
        ))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct SPEFCorpusFixtureInput {
    var fixture: SPEFCorpus.Fixture
    var source: String
    var failures: [SPEFCorpus.CaseFailure]
}

private struct SPEFCorpusParsedFixture {
    var fixture: SPEFCorpus.Fixture
    var tree: SPEFParseTree
    var observedParseSummary: SPEFCorpus.ParseSummary
    var failures: [SPEFCorpus.CaseFailure]
}

private enum SPEFCorpusFixtureInputLoad {
    case success(SPEFCorpusFixtureInput)
    case failure([SPEFCorpus.CaseFailure])
}

private enum SPEFCorpusFixtureParseLoad {
    case success(SPEFCorpusParsedFixture)
    case failure(SPEFCorpus.Fixture, SPEFCorpus.ParseSummary?, [SPEFCorpus.CaseFailure])
}

private enum SPEFCorpusFixtureDataRead {
    case success(Data)
    case failure(SPEFCorpus.CaseFailure)
}

private enum SPEFCorpusFixtureSourceDecode {
    case success(String)
    case failure(SPEFCorpus.CaseFailure)
}

private enum SPEFCorpusParseAttempt {
    case success(SPEFParseTree)
    case failure(SPEFCorpus.CaseFailure)
}

private enum SPEFCorpusLoweringAttempt {
    case success(ParasiticIR)
    case failure(SPEFCorpus.CaseFailure)
}
