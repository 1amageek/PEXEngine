import CryptoKit
import Foundation
import PEXEngine

public struct WriteSPEFCommand: Sendable {
    public let inputPath: String
    public let outputPath: String
    public let jsonOutput: Bool
    public let reportPath: String?
    public let roundTrip: Bool
    public let roundTripCornerID: String?
    public let designName: String?
    public let date: String?
    public let vendor: String?
    public let program: String?

    public init(arguments: [String]) throws {
        let parsed = try WriteSPEFCommandArguments(arguments: arguments)
        self.inputPath = parsed.inputPath
        self.outputPath = parsed.outputPath
        self.jsonOutput = parsed.jsonOutput
        self.reportPath = parsed.reportPath
        self.roundTrip = parsed.roundTrip
        self.roundTripCornerID = parsed.roundTripCornerID
        self.designName = parsed.designName
        self.date = parsed.date
        self.vendor = parsed.vendor
        self.program = parsed.program
    }

    public func run() async throws {
        let report = try write()
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print("SPEF write: \(report.status)")
            print("Input: \(report.inputPath)")
            print("Output: \(report.outputPath)")
            print("Nets: \(report.netCount), nodes: \(report.nodeCount), elements: \(report.elementCount)")
            print("Validation: \(report.validationStatus)")
            if let roundTrip = report.roundTrip {
                print("Round-trip: \(roundTrip.status) (\(roundTrip.netCount) nets, \(roundTrip.elementCount) elements)")
            }
            if let reportPath = report.reportPath {
                print("Report: \(reportPath)")
            }
            print("SHA256: \(report.outputSHA256)")
        }
    }

    public func write() throws -> SPEFWriteReport {
        let inputURL = URL(filePath: inputPath)
        let outputURL = URL(filePath: outputPath)
        let payload = try loadInput(from: inputURL)
        let validation = try validateIR(payload.ir)
        let spefData = try writeSPEFData(for: payload.ir)
        try persist(spefData, to: outputURL)
        let roundTripReport = try makeRoundTripReportIfRequested(
            originalIR: payload.ir,
            outputURL: outputURL,
            cornerID: payload.ir.cornerID
        )
        let reportURL = reportPath.map { URL(filePath: $0) }
        let report = makeReport(
            inputURL: inputURL,
            inputData: payload.data,
            outputURL: outputURL,
            outputData: spefData,
            reportURL: reportURL,
            ir: payload.ir,
            validation: validation,
            roundTripReport: roundTripReport
        )
        try writeReportIfRequested(report, to: reportURL)
        return report
    }

    private func loadInput(from inputURL: URL) throws -> WriteSPEFInputPayload {
        let inputData: Data
        do {
            inputData = try Data(contentsOf: inputURL)
        } catch {
            throw PEXError.invalidInput("Failed to read ParasiticIR JSON at \(inputURL.path(percentEncoded: false)): \(error)")
        }
        let ir: ParasiticIR
        do {
            ir = try JSONDecoder().decode(ParasiticIR.self, from: inputData)
        } catch {
            throw PEXError.invalidInput("Failed to decode ParasiticIR JSON at \(inputURL.path(percentEncoded: false)): \(error)")
        }
        return WriteSPEFInputPayload(data: inputData, ir: ir)
    }

    private func validateIR(_ ir: ParasiticIR) throws -> ParasiticIRValidationResult {
        let validation = ParasiticIRValidator().validate(ir)
        guard validation.isValid else {
            throw PEXError.irValidationFailed(cornerID: ir.cornerID, errors: validation.errors)
        }
        return validation
    }

    private func writeSPEFData(for ir: ParasiticIR) throws -> Data {
        let writer = SPEFWriter(options: SPEFWriterOptions(
            designName: designName ?? ir.metadata["designName"] ?? ir.metadata["topCell"] ?? "PEXEngine",
            date: date ?? "1970-01-01",
            vendor: vendor ?? "PEXEngine",
            program: program ?? "PEXEngine"
        ))
        return Data(try writer.write(ir).utf8)
    }

    private func persist(_ spefData: Data, to outputURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try spefData.write(to: outputURL, options: [.atomic])
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write SPEF to \(outputURL.path(percentEncoded: false))",
                underlying: error
            )
        }
    }

    private func makeRoundTripReportIfRequested(
        originalIR: ParasiticIR,
        outputURL: URL,
        cornerID: PEXCornerID
    ) throws -> SPEFWriteRoundTripReport? {
        guard roundTrip else { return nil }
        return try validateRoundTrip(originalIR: originalIR, outputURL: outputURL, cornerID: cornerID)
    }

    private func makeReport(
        inputURL: URL,
        inputData: Data,
        outputURL: URL,
        outputData: Data,
        reportURL: URL?,
        ir: ParasiticIR,
        validation: ParasiticIRValidationResult,
        roundTripReport: SPEFWriteRoundTripReport?
    ) -> SPEFWriteReport {
        SPEFWriteReport(
            status: "passed",
            inputPath: inputURL.path(percentEncoded: false),
            inputSHA256: Self.sha256Hex(inputData),
            inputByteCount: inputData.count,
            outputPath: outputURL.path(percentEncoded: false),
            outputSHA256: Self.sha256Hex(outputData),
            outputByteCount: outputData.count,
            reportPath: reportURL?.path(percentEncoded: false),
            cornerID: ir.cornerID.value,
            netCount: ir.nets.count,
            nodeCount: ir.nets.reduce(0) { $0 + $1.nodes.count },
            elementCount: ir.elements.count,
            validationStatus: validation.isValid ? "passed" : "failed",
            validationErrorCount: validation.errors.count,
            validationWarningCount: validation.warnings.count,
            roundTrip: roundTripReport
        )
    }

    private func writeReportIfRequested(_ report: SPEFWriteReport, to reportURL: URL?) throws {
        if let reportURL {
            do {
                try FileManager.default.createDirectory(
                    at: reportURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let reportData = try encoder.encode(report)
                try reportData.write(to: reportURL, options: [.atomic])
            } catch {
                throw PEXError.persistenceFailed(
                    "Failed to write SPEF report to \(reportURL.path(percentEncoded: false))",
                    underlying: error
                )
            }
        }
    }

    private func validateRoundTrip(
        originalIR: ParasiticIR,
        outputURL: URL,
        cornerID: PEXCornerID
    ) throws -> SPEFWriteRoundTripReport {
        let effectiveCornerID = PEXCornerID(roundTripCornerID ?? cornerID.value)
        let raw = PEXRawOutput(
            format: .spef,
            fileURLs: [outputURL],
            metadata: [:]
        )
        let context = PEXParseContext(
            cornerID: effectiveCornerID,
            runID: PEXRunID(),
            technology: nil,
            options: .default
        )
        let roundTrippedIR = try SPEFPEXParser().parse(raw, context: context)
        let validation = ParasiticIRValidator().validate(roundTrippedIR)
        guard validation.isValid else {
            throw PEXError.irValidationFailed(cornerID: effectiveCornerID, errors: validation.errors)
        }
        let semanticViolations = PEXIRSemanticComparator().compare(
            baseline: originalIR,
            candidate: roundTrippedIR
        )
        guard semanticViolations.isEmpty else {
            throw PEXError.invalidInput(
                "SPEF round-trip semantic comparison failed with \(semanticViolations.count) violation(s): "
                    + semanticViolations.map(\.kind).joined(separator: ", ")
            )
        }
        return SPEFWriteRoundTripReport(
            status: "passed",
            cornerID: effectiveCornerID.value,
            netCount: roundTrippedIR.nets.count,
            nodeCount: roundTrippedIR.nets.reduce(0) { $0 + $1.nodes.count },
            elementCount: roundTrippedIR.elements.count,
            validationStatus: validation.isValid ? "passed" : "failed",
            validationErrorCount: validation.errors.count,
            validationWarningCount: validation.warnings.count,
            semanticStatus: semanticViolations.isEmpty ? "passed" : "failed",
            semanticViolationCount: semanticViolations.count
        )
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct WriteSPEFInputPayload {
    let data: Data
    let ir: ParasiticIR
}
