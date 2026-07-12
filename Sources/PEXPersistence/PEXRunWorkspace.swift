import Foundation
import PEXCore

public struct PEXRunWorkspace: Sendable {
    public let baseURL: URL
    public let runID: PEXRunID

    public var runDirectory: URL { baseURL.appending(path: runID.description) }
    public var manifestURL: URL { runDirectory.appending(path: "manifest.json") }
    public var inputsDirectory: URL { runDirectory.appending(path: "inputs") }
    public var requestURL: URL { inputsDirectory.appending(path: "request.json") }
    public var reportURL: URL { runDirectory.appending(path: "reports").appending(path: "summary.md") }
    public var spefDirectory: URL { runDirectory.appending(path: "spef") }

    public init(baseURL: URL, runID: PEXRunID) {
        self.baseURL = baseURL
        self.runID = runID
    }

    public func cornerRawDirectory(_ cornerID: PEXCornerID) -> URL {
        runDirectory.appending(path: "raw").appending(path: cornerID.value)
    }

    public func cornerIRURL(_ cornerID: PEXCornerID) -> URL {
        runDirectory.appending(path: "ir").appending(path: "\(cornerID.value).json")
    }

    public func cornerSPEFRoundTripURL(_ cornerID: PEXCornerID) -> URL {
        spefDirectory.appending(path: "\(cornerID.value).spef")
    }

    public func cornerSPICEBackannotationURL(_ cornerID: PEXCornerID) -> URL {
        runDirectory.appending(path: "spice").appending(path: "\(cornerID.value).cir")
    }

    public func cornerLogURL(_ cornerID: PEXCornerID) -> URL {
        runDirectory.appending(path: "raw").appending(path: cornerID.value).appending(path: "extraction.log")
    }

    public func cornerSourceConnectivityURL(_ cornerID: PEXCornerID) -> URL {
        runDirectory
            .appending(path: "reports")
            .appending(path: "source-connectivity")
            .appending(path: "\(cornerID.value).json")
    }

    public func createDirectories(corners: [PEXCornerID]) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: inputsDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: runDirectory.appending(path: "ir"), withIntermediateDirectories: true)
            try fm.createDirectory(at: spefDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: runDirectory.appending(path: "spice"), withIntermediateDirectories: true)
            try fm.createDirectory(at: runDirectory.appending(path: "reports"), withIntermediateDirectories: true)
            for corner in corners {
                try fm.createDirectory(at: cornerRawDirectory(corner), withIntermediateDirectories: true)
            }
        } catch {
            throw PEXError.persistenceFailed(
                "Failed to create workspace directories at \(runDirectory.path(percentEncoded: false))",
                underlying: error
            )
        }
    }
}
