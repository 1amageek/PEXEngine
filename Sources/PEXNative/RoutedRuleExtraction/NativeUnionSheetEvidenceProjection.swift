import PEXCore

enum NativeUnionSheetEvidenceProjection {
    static func project(union: NativeConductorUnion, sheet: NativeSheetResistanceResult,
                        graph: UnionSheetRoutedPEXGraph, sourceOrigins: [String: String],
                        attachments: [NativeUnionSheetPEXEvidence.Attachment], maximumCellSpanDatabaseUnits: Int32,
                        budget: inout NativeRoutedPEXWorkBudget, isCancelled: () -> Bool)
        throws(NativeRoutedPEXError) -> NativeUnionSheetPEXEvidence {
        try budget.visit(1, isCancelled)
        guard maximumCellSpanDatabaseUnits > 0, maximumCellSpanDatabaseUnits == sheet.maximumCellSpanDatabaseUnits else {
            throw .invalidInput(reason: .units, sourceIDs: [])
        }
        var sources: [NativeUnionSheetPEXEvidence.Source] = []
        for source in union.sources {
            try budget.visit(1, isCancelled)
            guard let original = sourceOrigins[source.sourceID], !original.isEmpty else {
                throw .invalidInput(reason: .sourceIdentity, sourceIDs: [source.sourceID])
            }
            try budget.charge(.inputRecords)
            try budget.charge(.inputRecords, source.sourceFacts.count)
            var facts: [NativeRoutedPEXInput.SourceFact] = []
            for fact in source.sourceFacts {
                try budget.visit(1, isCancelled)
                facts.append(.init(artifactID: fact.artifactID, byteRange: fact.byteRange))
            }
            sources.append(.init(sourceID: source.sourceID, originalSourceID: original, netName: source.netName,
                                 layerName: source.layerName, rect: expanded(source.rect), sourceFacts: facts))
        }
        var bands: [NativeUnionSheetPEXEvidence.Band] = []
        for band in union.bands {
            try budget.visit(1, isCancelled)
            try budget.charge(.inputRecords)
            try budget.charge(.inputRecords, band.contributorIndices.count)
            try budget.visit(band.contributorIndices.count, isCancelled)
            bands.append(.init(netName: band.netName, layerName: band.layerName, rect: expanded(band.rect),
                               contributorIndices: band.contributorIndices))
        }
        var boundaries: [NativeUnionSheetPEXEvidence.Boundary] = []
        for boundary in union.boundaries {
            try budget.visit(1, isCancelled)
            try budget.charge(.inputRecords)
            try budget.charge(.inputRecords, boundary.contributorIndices.count)
            try budget.visit(boundary.contributorIndices.count, isCancelled)
            boundaries.append(.init(bandIndex: boundary.bandIndex, side: boundary.side.rawValue,
                                    coordinate: boundary.coordinate, begin: boundary.begin, end: boundary.end,
                                    contributorIndices: boundary.contributorIndices))
        }
        var cells: [NativeUnionSheetPEXEvidence.Cell] = []
        for cell in sheet.cells {
            try budget.visit(1, isCancelled)
            try budget.charge(.inputRecords)
            try budget.charge(.inputRecords, cell.contributorIndices.count)
            try budget.visit(cell.contributorIndices.count, isCancelled)
            cells.append(.init(netName: cell.netName, layerName: cell.layerName, rect: expanded(cell.rect),
                               node: graph.nodeRefs[cell.nodeIndex], contributorIndices: cell.contributorIndices))
        }
        let count = graph.resistanceContributors.count
        try budget.charge(.inputRecords, count)
        try sorting(count, budget: &budget, isCancelled: isCancelled)
        let ids = graph.resistanceContributors.keys.sorted()
        var resistances: [NativeUnionSheetPEXEvidence.Resistance] = []
        for id in ids {
            try budget.visit(1, isCancelled)
            guard let contributors = graph.resistanceContributors[id] else { throw .unrepresentableArithmetic }
            try budget.charge(.inputRecords)
            try budget.charge(.inputRecords, contributors.count)
            try budget.visit(contributors.count, isCancelled)
            let cutID = graph.resistanceCutSourceIDs[id]
            var originalCutID: String?
            if let cutID {
                guard let original = sourceOrigins[cutID], !original.isEmpty else {
                    throw .invalidInput(reason: .sourceIdentity, sourceIDs: [cutID])
                }
                originalCutID = original
            }
            resistances.append(.init(elementID: id, contributorIndices: contributors,
                                     cutSourceID: cutID, originalCutSourceID: originalCutID))
        }
        try budget.visit(1, isCancelled)
        return .init(version: 1, resistanceModel: "finite-volume-sheet-cut-area-dirichlet-v1",
                     groundModel: "lef-area-boundary-v1", couplingModel: "canonical-union-band-openrcx-empirical-cc-v1",
                     maximumCellSpanDatabaseUnits: maximumCellSpanDatabaseUnits,
                     sources: sources, bands: bands, boundaries: boundaries, cells: cells,
                     resistances: resistances, attachments: attachments)
    }

    private static func expanded(_ rect: NativeConductorUnion.Rect) -> NativeRoutedPEXInput.Rect {
        .init(minX: Int64(rect.minX), minY: Int64(rect.minY), maxX: Int64(rect.maxX), maxY: Int64(rect.maxY))
    }
    private static func sorting(_ count: Int, budget: inout NativeRoutedPEXWorkBudget,
                                isCancelled: () -> Bool) throws(NativeRoutedPEXError) {
        guard count > 1 else { try budget.visit(1, isCancelled); return }
        let (cost, overflow) = count.multipliedReportingOverflow(by: 2 * (Int.bitWidth - count.leadingZeroBitCount))
        guard !overflow else { throw .unrepresentableArithmetic }
        try budget.visit(cost, isCancelled)
    }
}
