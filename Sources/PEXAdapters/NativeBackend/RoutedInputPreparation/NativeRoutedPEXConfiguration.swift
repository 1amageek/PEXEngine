import CircuiteFoundation
import PEXCore
import PEXNative
import PEXParsers

/// Explicit source declarations. Decoding this value does not admit geometry or qualify its RC law.
public struct NativeRoutedPEXConfiguration: Sendable, Codable, Hashable {
    public enum Algorithm: String, Sendable, Codable, Hashable {
        case unionSheetAreaBoundaryV1 = "native-union-sheet-area-boundary-v1"
    }
    public static let currentVersion = 3
    public let version: Int
    public let algorithm: Algorithm
    public let sources: PEXRoutedInputSources
    public let maximumCellSpanDatabaseUnits: Int32
    public let extractionLimits: NativeRoutedPEXLimits
    public let compilationLimits: PEXOpenRCXCompilationLimits
    public let preparationLimits: NativeRoutedPEXPreparationLimits

    public init(version: Int = Self.currentVersion, algorithm: Algorithm,
                sources: PEXRoutedInputSources, maximumCellSpanDatabaseUnits: Int32,
                extractionLimits: NativeRoutedPEXLimits,
                compilationLimits: PEXOpenRCXCompilationLimits,
                preparationLimits: NativeRoutedPEXPreparationLimits) {
        self.version = version; self.algorithm = algorithm; self.sources = sources
        self.maximumCellSpanDatabaseUnits = maximumCellSpanDatabaseUnits
        self.extractionLimits = extractionLimits; self.compilationLimits = compilationLimits
        self.preparationLimits = preparationLimits
    }

    public func validate(requiredCornerIDs: [PEXCornerID], processName: String,
                         authorityReferences: [ArtifactReference] = [],
                         isCancelled: () -> Bool = { Task.isCancelled }) throws(NativeRoutedPEXPreparationError) {
        var budget = NativeRoutedPEXPreparationBudget(limits: preparationLimits)
        try validate(requiredCornerIDs: requiredCornerIDs, processName: processName,
                     authorityReferences: authorityReferences, budget: &budget, isCancelled: isCancelled)
    }

    func validate(requiredCornerIDs: [PEXCornerID], processName: String,
                  authorityReferences: [ArtifactReference], budget: inout NativeRoutedPEXPreparationBudget,
                  isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        guard version == Self.currentVersion, algorithm == .unionSheetAreaBoundaryV1,
              maximumCellSpanDatabaseUnits > 0 else {
            throw .invalidConfiguration("Routed schema 3 requires an explicit union/sheet/ground law and positive mesh span")
        }
        let limits = preparationLimits
        guard limits.maximumSourceBytes > 0, limits.maximumTotalSourceBytes > 0, limits.maximumRecords > 0, limits.maximumStringBytes > 0, limits.maximumWorkVisits > 0,
              limits.maximumNetlistManagedStorageBytes > 0, limits.maximumNetlistAllocationBytes > 0,
              sources.corners.count <= limits.maximumRecords,
              sources.standardCellLEFs.count <= limits.maximumRecords,
              requiredCornerIDs.count <= limits.maximumRecords,
              authorityReferences.count <= limits.maximumRecords else { throw .invalidConfiguration("Invalid routed preparation limits") }
        try budget.visit(isCancelled: isCancelled)
        let compiler = compilationLimits
        guard compiler.maximumSourceBytes > 0, compiler.maximumLineBytes > 0, compiler.maximumLines > 0,
              compiler.maximumRecords > 0, compiler.maximumRows > 0, compiler.maximumWorkVisits > 0 else {
            throw .invalidConfiguration("Invalid source compilation limits")
        }
        let extraction = extractionLimits
        guard extraction.maximumInputRecords > 0, extraction.maximumStringBytes > 0,
              extraction.maximumSourceRecords > 0, extraction.maximumWorkVisits > 0,
              extraction.maximumTrackEntries > 0, extraction.maximumCoordinateValues > 0,
              extraction.maximumGraphNodes > 0, extraction.maximumGraphElements > 0,
              extraction.maximumQueryReceipts > 0 else { throw .invalidConfiguration("Invalid routed extraction limits") }
        try budget.string(processName)
        var required = Set<PEXCornerID>()
        for corner in requiredCornerIDs {
            try budget.visit(isCancelled: isCancelled); try budget.record(); try budget.string(corner.value)
            guard !corner.value.isEmpty, required.insert(corner).inserted else {
                throw .invalidConfiguration("Requested corners must be nonempty and unique")
            }
        }
        guard !required.isEmpty, !processName.isEmpty else { throw .invalidConfiguration("Missing requested corner or process") }
        var references: [ArtifactID: ArtifactReference] = [:]
        var remainingSourceBytes = limits.maximumTotalSourceBytes
        func reference(_ value: ArtifactReference) throws(NativeRoutedPEXPreparationError) {
            try budget.visit(isCancelled: isCancelled)
            guard value.id.digest.algorithm == .sha256, value.id.byteCount > 0 else {
                throw .invalidConfiguration("Source identity requires positive SHA-256 content")
            }
            if let previous = references[value.id] {
                guard previous == value else { throw .sourceMismatch("Conflicting full references for one content identity") }
            } else {
                guard value.id.byteCount <= UInt64(limits.maximumSourceBytes), value.id.byteCount <= remainingSourceBytes else {
                    throw .limitExceeded("sourceBytes")
                }
                remainingSourceBytes -= value.id.byteCount
                try budget.record(); references[value.id] = value
            }
        }
        try reference(sources.expectedDEF); try reference(sources.expectedSourceNetlist); try reference(sources.routedTechnologyLEF)
        var cellLEFs = Set<ArtifactID>()
        for cell in sources.standardCellLEFs {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            guard cellLEFs.insert(cell.id).inserted else { throw .invalidConfiguration("Duplicate standard-cell LEF") }
            try reference(cell)
        }
        guard !cellLEFs.isEmpty else { throw .invalidConfiguration("Missing standard-cell LEFs") }
        var selected = Set<PEXCornerID>()
        for corner in sources.corners {
            try budget.visit(isCancelled: isCancelled); try budget.record(); try budget.string(corner.cornerID.value)
            guard !corner.cornerID.value.isEmpty, selected.insert(corner.cornerID).inserted,
                  corner.selection.processName == processName,
                  corner.selection.rulesArtifactID == corner.rules.id,
                  corner.selection.technologyLEFArtifactID == corner.technologyLEF.id else {
                throw .invalidConfiguration("Corner/source selection mismatch or duplicate corner")
            }
            guard corner.selection.routingLayerNames.count == 6 else { throw .invalidConfiguration("Six routing layers are required") }
            for layer in corner.selection.routingLayerNames { try budget.visit(isCancelled: isCancelled); try budget.string(layer) }
            do { try corner.selection.validate() }
            catch { throw .invalidConfiguration("Invalid routed rule selection: \(error)") }
            try reference(corner.rules); try reference(corner.technologyLEF)
        }
        guard required.isSubset(of: selected) else { throw .missingSource("Requested RC corner has no explicit source selection") }
        for authority in authorityReferences {
            try budget.visit(isCancelled: isCancelled)
            if let declared = references[authority.id], declared != authority {
                throw .sourceMismatch("Declared source differs from the caller's full artifact reference")
            }
        }
    }
}
