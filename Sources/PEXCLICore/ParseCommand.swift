import Foundation
import PEXEngine

public struct ParseCommand: Sendable {
    public let inputPath: String
    public let format: PEXOutputFormat
    public let cornerID: String
    public let topSubckt: String?
    public let jsonOutput: Bool
    public let reportOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try ParseCommandArguments(arguments: arguments)
        self.inputPath = parsed.inputPath
        self.format = parsed.format
        self.cornerID = parsed.cornerID
        self.topSubckt = parsed.topSubckt
        self.jsonOutput = parsed.jsonOutput
        self.reportOutput = parsed.reportOutput
    }

    public func run() async throws {
        let parsed = try parse()
        if reportOutput {
            let report = PEXParseReport(
                inputPath: inputPath,
                format: format,
                cornerID: cornerID,
                topSubckt: topSubckt,
                ir: parsed.ir,
                validationResult: parsed.validationResult
            )
            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(report)
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                print("Parse report: \(report.status)")
                print("Format: \(format.rawValue)")
                print("Corner: \(cornerID)")
                print("Nets: \(report.summary.netCount), elements: \(report.summary.elementCount)")
                print("Validation: \(report.validation.status) (\(report.validation.errorCount) errors, \(report.validation.warningCount) warnings)")
            }
            return
        }

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(parsed.ir)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("Parsed \(format.rawValue.uppercased()): \(parsed.ir.nets.count) nets, \(parsed.ir.elements.count) elements")
            print("Corner: \(parsed.ir.cornerID)")
            print("Validation: \(parsed.validationResult.isValid ? "PASS" : "FAIL") (\(parsed.validationResult.errors.count) errors, \(parsed.validationResult.warnings.count) warnings)")
            if !parsed.validationResult.errors.isEmpty {
                for err in parsed.validationResult.errors {
                    print("  ERROR: \(err)")
                }
            }
        }
    }

    public func buildReport() throws -> PEXParseReport {
        let parsed = try parse()
        return PEXParseReport(
            inputPath: inputPath,
            format: format,
            cornerID: cornerID,
            topSubckt: topSubckt,
            ir: parsed.ir,
            validationResult: parsed.validationResult
        )
    }

    private struct ParsedOutput {
        let ir: ParasiticIR
        let validationResult: ParasiticIRValidationResult
    }

    private func parse() throws -> ParsedOutput {
        let fileURL = URL(filePath: inputPath)
        var metadata: [String: String] = [:]
        if let topSubckt {
            metadata["topSubckt"] = topSubckt
        }
        let raw = PEXRawOutput(
            format: format,
            fileURLs: [fileURL],
            logURL: nil,
            metadata: metadata
        )

        let parserRegistry = PEXDefaultParsers.makeRegistry()

        guard let parser = parserRegistry.parser(for: format) else {
            throw PEXError(
                kind: .parseFailed,
                stage: .parsing,
                message: "No parser available for format '\(format.rawValue)'"
            )
        }

        let context = PEXParseContext(
            cornerID: PEXCornerID(cornerID),
            runID: PEXRunID(),
            technology: nil,
            options: .default
        )

        let ir = try parser.parse(raw, context: context)

        let validator = ParasiticIRValidator()
        let validationResult = validator.validate(ir)
        return ParsedOutput(ir: ir, validationResult: validationResult)
    }
}
