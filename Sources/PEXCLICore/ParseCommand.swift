import Foundation
import PEXEngine

public struct ParseCommand: Sendable {
    public let inputPath: String
    public let format: PEXOutputFormat
    public let cornerID: String
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var path: String?
        var fmt: String = "spef"
        var corner: String = "default"
        var json = false

        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--input":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--input requires a path argument")
                }
                path = arguments[i]
            case "--format":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--format requires a value")
                }
                fmt = arguments[i]
            case "--corner":
                i += 1
                guard i < arguments.count else {
                    throw PEXError.invalidInput("--corner requires a value")
                }
                corner = arguments[i]
            case "--json":
                json = true
            default:
                if path == nil {
                    path = arguments[i]
                }
            }
            i += 1
        }

        guard let inputPath = path else {
            throw PEXError.invalidInput("Input file path is required")
        }
        self.inputPath = inputPath
        self.format = PEXOutputFormat(rawValue: fmt) ?? .spef
        self.cornerID = corner
        self.jsonOutput = json
    }

    public func run() async throws {
        let fileURL = URL(filePath: inputPath)
        let raw = PEXRawOutput(
            format: format,
            fileURLs: [fileURL],
            logURL: nil,
            metadata: [:]
        )

        let parserRegistry = PEXParserRegistry()
        parserRegistry.register(SPEFPEXParser())

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

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ir)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("Parsed SPEF: \(ir.nets.count) nets, \(ir.elements.count) elements")
            print("Corner: \(ir.cornerID)")
            print("Validation: \(validationResult.isValid ? "PASS" : "FAIL") (\(validationResult.errors.count) errors, \(validationResult.warnings.count) warnings)")
            if !validationResult.errors.isEmpty {
                for err in validationResult.errors {
                    print("  ERROR: \(err)")
                }
            }
        }
    }
}
