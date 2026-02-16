import Foundation
import PEXCore

public struct SPEFPEXParser: PEXParserProtocol {
    public let format: PEXOutputFormat = .spef

    public init() {}

    public func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR {
        guard let fileURL = raw.fileURLs.first else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "No SPEF file found in raw output"
            )
        }

        let source: String
        do {
            source = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Failed to read SPEF file: \(fileURL.lastPathComponent)",
                underlying: error
            )
        }

        // Stage 1: Lex
        var lexer = SPEFLexer(source: source, fileName: fileURL.lastPathComponent)
        let tokens = lexer.tokenize()

        // Stage 2: Parse
        let parser = SPEFParser()
        let tree: SPEFParseTree
        do {
            tree = try parser.parse(tokens: tokens)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "SPEF parse failed",
                underlying: error
            )
        }

        // Stage 3: Lower
        let lowering = SPEFLowering()
        do {
            return try lowering.lower(tree, cornerID: context.cornerID)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "SPEF lowering failed",
                underlying: error
            )
        }
    }
}
