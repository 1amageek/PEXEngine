import Foundation
import LayoutCore
import LayoutVerify

/// Resolves durable selectors within one imported and captured generation.
struct NativePEXInputNetResolver {
    static func resolve(document: LayoutDocument, snapshot: LayoutConductorSnapshot,
                        configuration: NativePEXConfiguration, budget: inout NativePEXInputBudget,
                        isCancelled: () -> Bool) throws(NativePEXInputError) -> [NativePEXNetBinding] {
        func checkCancellation() throws(NativePEXInputError) {
            if isCancelled() { throw .cancelled }
        }
        try checkCancellation()
        try budget.charge(document.cells.count)
        var cells: [UUID: LayoutCell] = [:]
        for cell in document.cells {
            try checkCancellation()
            guard cells.updateValue(cell, forKey: cell.id) == nil else { throw .invalidField("source.cellID") }
        }
        try budget.charge(configuration.netBindings.count)
        var result: [NativePEXNetBinding] = []
        var resolved: Set<LayoutConductorSnapshot.NetReference> = []
        for binding in configuration.netBindings {
            try checkCancellation()
            let selector = binding.selector, index = selector.occurrenceIndex
            guard snapshot.hierarchy.occurrences.indices.contains(index) else { throw .invalidNetOccurrence(index) }
            try budget.charge(1)
            let occurrence = snapshot.hierarchy.occurrences[index]
            guard let cell = cells[occurrence.sourceCellID] else { throw .invalidField("source.cellID") }
            try budget.identifier(cell.name, field: "source.cellName")
            guard cell.name == selector.expectedCellName else {
                throw .netCellMismatch(occurrenceIndex: index, expected: selector.expectedCellName, actual: cell.name)
            }
            let netID: UUID
            switch selector {
            case .sourceDeclared(_, _, let name):
                try budget.charge(cell.nets.count)
                var match: UUID?
                for net in cell.nets {
                    try checkCancellation()
                    try budget.charge(net.name.utf8.count)
                    guard net.name == name else { continue }
                    guard match == nil else { throw .ambiguousSourceNet(occurrenceIndex: index, name: name) }
                    match = net.id
                }
                guard let match else { throw .missingSourceNet(occurrenceIndex: index, name: name) }
                netID = match
            case .supplemental(_, _, let id):
                try budget.charge(configuration.supplementalPins.count)
                var declared = false
                for definition in configuration.supplementalPins {
                    try checkCancellation()
                    try budget.charge(definition.cellName.utf8.count)
                    if definition.cellName == cell.name, definition.pin.netID == id { declared = true }
                }
                guard declared else { throw .undeclaredSupplementalNet(cell: cell.name, netID: id) }
                netID = id
            }
            let reference = LayoutConductorSnapshot.NetReference(occurrenceIndex: index, netID: netID)
            guard resolved.insert(reference).inserted else {
                throw .duplicateResolvedNetBinding(occurrenceIndex: index, netID: netID)
            }
            result.append(.init(reference: reference, netName: binding.netName))
        }
        try checkCancellation()
        return result
    }
}
