import Foundation
import LayoutCore
import LayoutVerify

public struct LayoutPEXInputPreparer: NativePEXInputPreparing {
    public init() {}

    public func prepare(document: LayoutDocument, topCell: String, configuration: NativePEXConfiguration,
                        isCancelled: () -> Bool = { Task.isCancelled }) throws -> NativePEXPreparedInput {
        func cancelled() throws(NativePEXInputError) { if isCancelled() { throw .cancelled } }
        try cancelled()
        var budget = try NativePEXInputBudget(configuration.maximumMetadataEntries)
        try budget.charge(configuration.metadataEntriesUsed)
        try budget.charge(document.cells.count)
        try budget.identifier(topCell, field: "topCell")
        var indices: [String: Int] = [:]
        var pinIDs: [Int: Set<UUID>] = [:], pinNames: [Int: Set<String>] = [:]
        for (index, cell) in document.cells.enumerated() {
            try cancelled()
            try budget.identifier(cell.name, field: "source.cellName")
            guard indices.updateValue(index, forKey: cell.name) == nil else { throw NativePEXInputError.duplicateCell(cell.name) }
            try budget.charge(cell.pins.count)
            for pin in cell.pins {
                try cancelled()
                try budget.identifier(pin.name, field: "source.pinName")
                guard pinIDs[index, default: []].insert(pin.id).inserted,
                      pinNames[index, default: []].insert(pin.name).inserted else {
                    throw NativePEXInputError.duplicatePin(cell: cell.name, name: pin.name)
                }
            }
        }
        guard let root = indices[topCell] else { throw NativePEXInputError.missingCell(topCell) }
        var prepared = document
        for definition in configuration.supplementalPins {
            try cancelled()
            guard let index = indices[definition.cellName] else { throw NativePEXInputError.missingCell(definition.cellName) }
            guard pinIDs[index, default: []].insert(definition.pin.id).inserted,
                  pinNames[index, default: []].insert(definition.pin.name).inserted else {
                throw NativePEXInputError.duplicatePin(cell: definition.cellName, name: definition.pin.name)
            }
            prepared.cells[index].pins.append(definition.pin)
        }
        try cancelled()
        let snapshot: LayoutConductorSnapshot
        do {
            snapshot = try LayoutConnectivityExtractor().captureConductors(document: prepared,
                tech: configuration.layoutTechnology, conductiveLayers: configuration.conductiveLayers,
                cellID: document.cells[root].id, limits: configuration.captureLimits.geometryLimits, isCancelled: isCancelled)
        } catch let error as LayoutConductorCaptureError { throw NativePEXInputError.capture(error) }
        catch let error as LayoutHierarchyCaptureError { throw NativePEXInputError.hierarchy(error) }
        try cancelled()
        guard snapshot.coordinateUnits == configuration.expectedCoordinateUnits else { throw NativePEXInputError.coordinateUnitsMismatch }
        return NativePEXPreparedInput(snapshot: snapshot, configuration: configuration)
    }
}
