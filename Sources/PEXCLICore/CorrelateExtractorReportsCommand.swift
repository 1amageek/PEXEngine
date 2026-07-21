import Foundation
import PEXEngine

public struct CorrelateExtractorReportsCommand: Sendable {
    public let corpusURL: URL
    public let primaryReportURL: URL
    public let oracleReportURL: URL
    public let outputURL: URL
    public let correlationID: String
    public let jsonOutput: Bool

    public init(arguments: [String]) throws {
        let parsed = try CorrelateExtractorReportsCommandArguments(arguments: arguments)
        self.corpusURL = parsed.corpusURL
        self.primaryReportURL = parsed.primaryReportURL
        self.oracleReportURL = parsed.oracleReportURL
        self.outputURL = parsed.outputURL
        self.correlationID = parsed.correlationID
        self.jsonOutput = parsed.jsonOutput
    }

    @discardableResult
    public func run() async throws -> PEXExtractorCorrelation {
        let correlation = try buildCorrelation()
        let data = try correlation.canonicalData()
        try writeImmutable(data, to: outputURL)

        if jsonOutput {
            guard let json = String(data: data, encoding: .utf8) else {
                throw PEXError.persistenceFailed("Canonical correlation is not UTF-8 JSON")
            }
            print(json)
        } else {
            print("Status: \(correlation.passed ? "passed" : "failed")")
            print("Primary backend: \(correlation.primaryBackendID)")
            print("Oracle backend: \(correlation.oracleBackendID)")
            print("Cases: \(correlation.cases.count)")
            print("Correlation: \(outputURL.path(percentEncoded: false))")
        }
        return correlation
    }

    public func buildCorrelation() throws -> PEXExtractorCorrelation {
        do {
            return try PEXExtractorCorrelationBuilder().build(
                correlationID: correlationID,
                corpusData: Data(contentsOf: corpusURL, options: [.mappedIfSafe]),
                primaryReportData: Data(contentsOf: primaryReportURL, options: [.mappedIfSafe]),
                oracleReportData: Data(contentsOf: oracleReportURL, options: [.mappedIfSafe])
            )
        } catch let error as PEXError {
            throw error
        } catch let error as PEXExtractorCorrelationBuildError {
            throw PEXError(
                kind: .irValidationFailed,
                stage: .irValidation,
                cornerID: "extractor-correlation",
                message: error.localizedDescription,
                underlyingDescription: String(describing: error)
            )
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to read or validate canonical extractor correlation inputs",
                underlying: error
            )
        }
    }

    private func writeImmutable(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        guard !fileManager.fileExists(atPath: path) else {
            throw PEXError.persistenceFailed(
                "Refusing to overwrite immutable extractor correlation at \(path)"
            )
        }
        do {
            let parent = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let temporaryURL = parent.appending(
                path: ".\(url.lastPathComponent).\(UUID().uuidString).pending"
            )
            do {
                try data.write(to: temporaryURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o444],
                    ofItemAtPath: temporaryURL.path(percentEncoded: false)
                )
                try fileManager.linkItem(at: temporaryURL, to: url)
                try fileManager.removeItem(at: temporaryURL)
            } catch {
                if fileManager.fileExists(atPath: temporaryURL.path(percentEncoded: false)) {
                    do {
                        try fileManager.removeItem(at: temporaryURL)
                    } catch let cleanupError {
                        throw PEXError.persistenceFailed(
                            "Failed to clean temporary correlation after write failure: \(cleanupError)",
                            underlying: error
                        )
                    }
                }
                throw error
            }
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to write immutable extractor correlation to \(path)",
                underlying: error
            )
        }
    }
}
