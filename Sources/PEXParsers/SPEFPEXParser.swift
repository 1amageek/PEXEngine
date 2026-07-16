import Foundation
import PEXCore

public struct SPEFPEXParser: PEXParsing {
    public let format: PEXOutputFormat = .spef

    public init() {}

    public func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR {
        try validateFormat(raw.format, context: context)
        let fileURL = try selectedFile(from: raw, context: context)
        let source = try readSource(from: fileURL, context: context)
        let tree = try parseTree(source: source, fileURL: fileURL, context: context)
        return try lower(tree: tree, context: context)
    }

    private func validateFormat(_ rawFormat: PEXOutputFormat, context: PEXParseContext) throws {
        guard rawFormat == format else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "SPEF parser received raw output format '\(rawFormat.rawValue)'"
            )
        }
    }

    private func selectedFile(from raw: PEXRawOutput, context: PEXParseContext) throws -> URL {
        guard let fileURL = raw.fileURLs.first else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "No SPEF file found in raw output"
            )
        }
        return fileURL
    }

    private func readSource(from fileURL: URL, context: PEXParseContext) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Failed to read SPEF file: \(fileURL.lastPathComponent)",
                underlying: error
            )
        }
    }

    private func parseTree(source: String, fileURL: URL, context: PEXParseContext) throws -> SPEFParseTree {
        var lexer = SPEFLexer(source: source, fileName: fileURL.lastPathComponent)
        let tokens = lexer.tokenize()
        let parser = SPEFParser()
        do {
            return try parser.parse(tokens: tokens)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "SPEF parse failed",
                underlying: error
            )
        }
    }

    private func lower(tree: SPEFParseTree, context: PEXParseContext) throws -> ParasiticIR {
        let lowering = SPEFLowering()
        do {
            return try lowering.lower(tree, cornerID: context.cornerID, options: context.options)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "SPEF lowering failed",
                underlying: error
            )
        }
    }
}
