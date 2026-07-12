import Foundation
import PEXEngine

/// Composes a retained ParasiticIR JSON artifact into a source SPICE deck.
public struct BackannotateCommand: Sendable {
    public let sourceNetlistURL: URL
    public let irURL: URL
    public let outputURL: URL
    public let topCell: String?
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        var sourcePath: String?
        var irPath: String?
        var outputPath: String?
        var topCell: String?
        var jsonOutput = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--netlist", "--source-netlist":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("\(argument) requires a path")
                }
                sourcePath = arguments[index]
            case "--ir":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--ir requires a path")
                }
                irPath = arguments[index]
            case "--output", "--out":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("\(argument) requires a path")
                }
                outputPath = arguments[index]
            case "--top-cell":
                index += 1
                guard index < arguments.count else {
                    throw PEXError.invalidInput("--top-cell requires a name")
                }
                topCell = arguments[index]
            case "--json":
                jsonOutput = true
            default:
                throw PEXError.invalidInput("Unknown backannotate argument: \(argument)")
            }
            index += 1
        }

        guard let sourcePath, !sourcePath.isEmpty else {
            throw PEXError.invalidInput("backannotate requires --netlist <path>")
        }
        guard let irPath, !irPath.isEmpty else {
            throw PEXError.invalidInput("backannotate requires --ir <path>")
        }
        guard let outputPath, !outputPath.isEmpty else {
            throw PEXError.invalidInput("backannotate requires --output <path>")
        }
        self.sourceNetlistURL = URL(filePath: sourcePath)
        self.irURL = URL(filePath: irPath)
        self.outputURL = URL(filePath: outputPath)
        self.topCell = topCell
        self.jsonOutput = jsonOutput
    }

    public func run() async throws {
        let source: String
        do {
            source = try String(contentsOf: sourceNetlistURL, encoding: .utf8)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to read source netlist \(sourceNetlistURL.path(percentEncoded: false))",
                underlying: error
            )
        }

        let irData: Data
        do {
            irData = try Data(contentsOf: irURL)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to read ParasiticIR \(irURL.path(percentEncoded: false))",
                underlying: error
            )
        }
        let ir: ParasiticIR
        do {
            ir = try PEXIRSerializer().decode(from: irData)
        } catch {
            throw PEXError.parseFailed(
                cornerID: PEXCornerID("unknown"),
                message: "Failed to decode ParasiticIR: \(error)"
            )
        }

        let composed: String
        do {
            composed = try PEXSPICEBackannotationComposer(
                options: PEXSPICEBackannotationOptions(topCell: topCell)
            ).compose(sourceNetlist: source, ir: ir)
        } catch let error as PEXSPICEBackannotationError {
            throw PEXError(
                kind: .irValidationFailed,
                stage: .irValidation,
                cornerID: ir.cornerID,
                message: error.localizedDescription
            )
        } catch {
            throw PEXError(
                kind: .irValidationFailed,
                stage: .irValidation,
                cornerID: ir.cornerID,
                message: String(describing: error)
            )
        }

        do {
            try Data(composed.utf8).write(to: outputURL, options: .atomic)
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write backannotated netlist \(outputURL.path(percentEncoded: false))",
                underlying: error
            )
        }

        let report = Output(
            status: "success",
            cornerID: ir.cornerID.value,
            outputURL: outputURL,
            byteCount: composed.utf8.count
        )
        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print("Backannotated netlist: \(outputURL.path(percentEncoded: false))")
            print("Corner: \(ir.cornerID.value)")
            print("Bytes: \(composed.utf8.count)")
        }
    }

    private struct Output: Codable, Sendable {
        let status: String
        let cornerID: String
        let outputURL: URL
        let byteCount: Int
    }
}
