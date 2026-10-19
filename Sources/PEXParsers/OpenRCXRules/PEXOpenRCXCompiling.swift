import Foundation
import PEXCore

public protocol PEXOpenRCXCompiling: Sendable {
    func compile(bytes: borrowing Data, selection: PEXOpenRCXSourceModel.Selection,
                 limits: PEXOpenRCXCompilationLimits, isCancelled: () -> Bool)
        throws(PEXOpenRCXSourceError) -> PEXOpenRCXSourceModel
    func validate(model: borrowing PEXOpenRCXSourceModel, bytes: borrowing Data,
                  limits: PEXOpenRCXCompilationLimits, isCancelled: () -> Bool)
        throws(PEXOpenRCXSourceError)
}
