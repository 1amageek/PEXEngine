import Foundation
import PEXCore

public struct OpenRCXToolchain: Sendable, Hashable {
    public static let technologyLEFRole = "technologyLEF"
    public static let libraryLEFRolePrefix = "libraryLEF:"

    public let openROADExecutableURL: URL
    public let technologyLEFURL: URL
    public let libraryLEFURLs: [URL]
    public let extractionRulesURL: URL

    public init(
        openROADExecutableURL: URL,
        technologyLEFURL: URL,
        libraryLEFURLs: [URL],
        extractionRulesURL: URL
    ) {
        self.openROADExecutableURL = openROADExecutableURL
        self.technologyLEFURL = technologyLEFURL
        self.libraryLEFURLs = libraryLEFURLs
        self.extractionRulesURL = extractionRulesURL
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> OpenRCXToolchain? {
        guard let executable = nonEmpty(environment["OPENROAD_BIN"]),
              let technologyLEF = nonEmpty(environment["OPENRCX_TECH_LEF"]),
              let extractionRules = nonEmpty(environment["OPENRCX_RULES"]),
              fileManager.isExecutableFile(atPath: executable),
              isRegularFile(technologyLEF, fileManager: fileManager),
              isRegularFile(extractionRules, fileManager: fileManager) else {
            return nil
        }
        let libraryLEFs = environment["OPENRCX_LIBRARY_LEFS"]?
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { isRegularFile($0, fileManager: fileManager) } ?? []
        return OpenRCXToolchain(
            openROADExecutableURL: URL(filePath: executable),
            technologyLEFURL: URL(filePath: technologyLEF),
            libraryLEFURLs: libraryLEFs.map { URL(filePath: $0) },
            extractionRulesURL: URL(filePath: extractionRules)
        )
    }

    public static func resolve(
        processProfile: PEXProcessProfileReference,
        executableOverride: String? = nil,
        configuredToolchain: OpenRCXToolchain? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> OpenRCXToolchain {
        let executablePath = nonEmpty(executableOverride)
            ?? configuredToolchain?.openROADExecutableURL.path(percentEncoded: false)
            ?? nonEmpty(environment["OPENROAD_BIN"])
        guard let executablePath, fileManager.isExecutableFile(atPath: executablePath) else {
            throw OpenRCXToolchainError.executableUnavailable(executablePath)
        }
        guard let technologyLEFPath = processProfile.requiredViewPaths[technologyLEFRole],
              isRegularFile(technologyLEFPath, fileManager: fileManager) else {
            throw OpenRCXToolchainError.requiredViewUnavailable(technologyLEFRole)
        }
        guard let extractionRulesPath = processProfile.primaryDeckPath,
              isRegularFile(extractionRulesPath, fileManager: fileManager) else {
            throw OpenRCXToolchainError.extractionRulesUnavailable(processProfile.primaryDeckPath)
        }
        let libraryLEFs = processProfile.requiredViewPaths
            .filter { $0.key.hasPrefix(libraryLEFRolePrefix) }
            .sorted { $0.key < $1.key }
        guard !libraryLEFs.isEmpty else {
            throw OpenRCXToolchainError.libraryViewsUnavailable
        }
        if let invalidRole = libraryLEFs.first(where: {
            $0.key.dropFirst(libraryLEFRolePrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.key {
            throw OpenRCXToolchainError.requiredViewUnavailable(invalidRole)
        }
        for (role, path) in libraryLEFs where !isRegularFile(path, fileManager: fileManager) {
            throw OpenRCXToolchainError.requiredViewUnavailable(role)
        }
        return OpenRCXToolchain(
            openROADExecutableURL: URL(filePath: executablePath),
            technologyLEFURL: URL(filePath: technologyLEFPath),
            libraryLEFURLs: libraryLEFs.map { URL(filePath: $0.value) },
            extractionRulesURL: URL(filePath: extractionRulesPath)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isRegularFile(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
