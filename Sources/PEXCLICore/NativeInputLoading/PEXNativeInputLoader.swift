import Foundation
import PEXEngine

struct PEXNativeInputLoader: Sendable {
    static let maximumReferenceBytes = 4 * 1024 * 1024

    func load(_ url: URL) throws -> PEXNativeInputReference {
        let data = try PEXBoundedInputReader().read(url, maximumBytes: Self.maximumReferenceBytes)
        do {
            return try JSONDecoder().decode(PEXNativeInputReference.self, from: data)
        } catch let error as PEXError {
            throw error
        } catch {
            throw PEXError.invalidInput("Failed to decode native input reference: \(url.path(percentEncoded: false)); \(error)")
        }
    }
}
