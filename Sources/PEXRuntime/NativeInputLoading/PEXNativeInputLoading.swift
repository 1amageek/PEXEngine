import Foundation
import PEXCore

/// Admits the selected backend and loads its exact native reference document.
public protocol PEXNativeInputLoading: Sendable {
    func load(backendID: String, referenceURL: URL?) throws -> PEXNativeInputReference?
}
