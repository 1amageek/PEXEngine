import LEF
import PEXCore

/// Projects already decoded source values; Native owns every numerical R/C operation.
struct NativeRoutedPEXGroundSourceProjection {
    static func project(technology: NativeRoutedPEXDecodedLEF, selection: PEXOpenRCXSourceModel.Selection,
                        cornerID: PEXCornerID, budget: inout NativeRoutedPEXPreparationBudget,
                        isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) -> PEXRoutedGroundCapacitanceModel {
        try budget.visit(isCancelled: isCancelled)
        guard technology.reference.id == selection.technologyLEFArtifactID,
              technology.reference.byteCount > 0, let byteCount = Int(exactly: technology.reference.byteCount),
              selection.routingLayerNames.count == 6, !cornerID.value.isEmpty else {
            throw .sourceMismatch("Ground calibration requires the exact selected corner technology")
        }
        guard technology.document.unitDeclarations.capacitancePicofarads == 1 else {
            throw .unsupportedSource("Ground calibration requires explicit CAPACITANCE PICOFARADS 1")
        }
        try budget.record()
        let ranges = [PEXOpenRCXSourceModel.SourceRange(lowerBound: 0, upperBound: byteCount)]
        var layers: [PEXRoutedGroundCapacitanceModel.Layer] = []
        for name in selection.routingLayerNames {
            try budget.visit(isCancelled: isCancelled)
            try budget.string(name)
            for previous in layers {
                try budget.visit(isCancelled: isCancelled)
                guard previous.name != name else { throw .sourceMismatch("Duplicate selected ground calibration layer") }
            }
            var found: LEFLayerDef?
            for source in technology.document.layers {
                try budget.visit(isCancelled: isCancelled)
                if source.name == name {
                    guard found == nil else { throw .sourceMismatch("Ambiguous ground calibration source layer") }
                    found = source
                }
            }
            guard let source = found, source.type == .routing,
                  let area = source.capacitance, area.isFinite, area > 0,
                  let edge = source.edgeCapacitance, edge.isFinite, edge > 0,
                  source.thickness.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw .unsupportedSource("Ground calibration requires positive finite original area/edge coefficients and optional thickness")
            }
            try budget.record(2)
            layers.append(.init(name: name, areaPicofaradsPerSquareMicron: area,
                edgePicofaradsPerMicron: edge, thicknessMicrons: source.thickness, sourceRanges: ranges))
        }
        return .init(selection: selection, cornerID: cornerID, capacitanceUnitPicofarads: 1,
            unitSourceRanges: ranges, layers: layers)
    }
}
