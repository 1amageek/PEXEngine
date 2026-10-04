import LayoutVerify

/// Serialized admission ceilings; defaults are inherited from the geometry owner.
public struct NativePEXCaptureLimits: Sendable, Equatable, Codable {
    public let maximumOccurrences: Int
    public let maximumObjects: Int
    public let maximumGeometryPoints: Int
    public let maximumDepth: Int
    public let maximumInputEntries: Int
    public let maximumEdgeProbes: Int
    public let maximumOutputBands: Int
    public let maximumTechnologyRecords: Int
    public let maximumFootprints: Int
    public let maximumContactProbes: Int

    public init(maximumOccurrences: Int = LayoutConductorCaptureLimits.default.hierarchy.maximumOccurrences,
                maximumObjects: Int = LayoutConductorCaptureLimits.default.hierarchy.maximumObjects,
                maximumGeometryPoints: Int = LayoutConductorCaptureLimits.default.hierarchy.maximumGeometryPoints,
                maximumDepth: Int = LayoutConductorCaptureLimits.default.hierarchy.maximumDepth,
                maximumInputEntries: Int? = nil,
                maximumEdgeProbes: Int? = nil,
                maximumOutputBands: Int? = nil,
                maximumTechnologyRecords: Int = LayoutConductorCaptureLimits.default.maximumTechnologyRecords,
                maximumFootprints: Int = LayoutConductorCaptureLimits.default.maximumFootprints,
                maximumContactProbes: Int = LayoutConductorCaptureLimits.default.maximumContactProbes) {
        self.maximumOccurrences = maximumOccurrences; self.maximumObjects = maximumObjects
        self.maximumGeometryPoints = maximumGeometryPoints; self.maximumDepth = maximumDepth
        self.maximumInputEntries = maximumInputEntries ?? LayoutConductorCaptureLimits.default.decomposition.maximumInputEntries; self.maximumEdgeProbes = maximumEdgeProbes ?? LayoutConductorCaptureLimits.default.decomposition.maximumEdgeProbes
        self.maximumOutputBands = maximumOutputBands ?? LayoutConductorCaptureLimits.default.decomposition.maximumOutputBands; self.maximumTechnologyRecords = maximumTechnologyRecords
        self.maximumFootprints = maximumFootprints; self.maximumContactProbes = maximumContactProbes
    }

    public var geometryLimits: LayoutConductorCaptureLimits {
        .init(hierarchy: .init(maximumOccurrences: maximumOccurrences, maximumObjects: maximumObjects,
                              maximumGeometryPoints: maximumGeometryPoints, maximumDepth: maximumDepth),
              decomposition: .init(maximumInputEntries: maximumInputEntries, maximumEdgeProbes: maximumEdgeProbes,
                                   maximumOutputBands: maximumOutputBands),
              maximumTechnologyRecords: maximumTechnologyRecords, maximumFootprints: maximumFootprints,
              maximumContactProbes: maximumContactProbes)
    }

    var values: [Int] {
        [maximumOccurrences, maximumObjects, maximumGeometryPoints, maximumDepth, maximumInputEntries,
         maximumEdgeProbes, maximumOutputBands, maximumTechnologyRecords, maximumFootprints, maximumContactProbes]
    }
}
