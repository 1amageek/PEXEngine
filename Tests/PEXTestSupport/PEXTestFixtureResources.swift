import Foundation

public enum PEXTestFixtureResources: Sendable {
    public enum ResourceError: Error, Sendable, Equatable, LocalizedError {
        case missingOpenROADDirectory
        case missingOpenROADFixture(String)

        public var errorDescription: String? {
            switch self {
            case .missingOpenROADDirectory:
                "The shared OpenROAD test fixture directory is missing."
            case .missingOpenROADFixture(let fileName):
                "The shared OpenROAD test fixture is missing: \(fileName)"
            }
        }
    }

    public static func openROADDirectoryURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "OpenROAD",
            withExtension: nil
        ) else {
            throw ResourceError.missingOpenROADDirectory
        }
        return url
    }

    public static func openROADManifestURL() throws -> URL {
        try openROADFixtureURL(fileName: "fixture-manifest.json")
    }

    public static func openROADFixtureURL(fileName: String) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: fileName,
            withExtension: nil,
            subdirectory: "OpenROAD"
        ) else {
            throw ResourceError.missingOpenROADFixture(fileName)
        }
        return url
    }
}
