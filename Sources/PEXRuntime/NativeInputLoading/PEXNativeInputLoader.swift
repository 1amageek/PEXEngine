import Foundation
import PEXCore
import PEXPersistence

public struct PEXNativeInputLoader: PEXNativeInputLoading {
    public static let maximumReferenceBytes = 4 * 1024 * 1024

    public init() {}

    public func load(backendID: String, referenceURL: URL?) throws -> PEXNativeInputReference? {
        guard backendID == "native" else {
            guard referenceURL == nil else {
                throw PEXError.invalidInput("Native input reference requires backend native")
            }
            return nil
        }
        guard let referenceURL else {
            throw PEXError.invalidInput("Native extraction requires an explicit native input reference")
        }
        let data = try PEXBoundedInputReader().read(referenceURL, maximumBytes: Self.maximumReferenceBytes)
        do {
            return try JSONDecoder().decode(PEXNativeInputReference.self, from: data)
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.invalidInput("Failed to decode native input reference: \(referenceURL.path(percentEncoded: false)); \(error)")
        }
    }
}
