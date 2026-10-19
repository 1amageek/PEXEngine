import Foundation
import CircuiteFoundation
import DEF
import LEF
import PEXCore
import PEXNative
import PEXParsers
import PEXPersistence
import LogicDesignSerialization

public struct DefaultNativeRoutedPEXInputPreparer: NativeRoutedPEXInputPreparing {
    private let compiler: any PEXOpenRCXCompiling
    let decoder: any StructuralVerilogSourceDecoding
    public init(compiler: any PEXOpenRCXCompiling = PEXOpenRCXSourceCompiler(),
                decoder: any StructuralVerilogSourceDecoding = MappedGateVerilogCodec()) {
        self.compiler = compiler; self.decoder = decoder
    }

    public func prepare(context: PEXExecutionContext, requiredCornerIDs: [PEXCornerID],
                        isCancelled: @Sendable () -> Bool = { Task.isCancelled })
        throws(NativeRoutedPEXPreparationError) -> PreparedNativeRoutedPEXInput {
        guard let reference = context.nativeInput, reference.configurationKind == .routedOpenRCXV1,
              context.layoutFormat == .def, context.sourceNetlistFormat == .verilog else { throw .invalidConfiguration("Routed preparation requires explicit routed kind, DEF and structural Verilog") }
        let config: NativeRoutedPEXConfiguration
        do {
            guard !isCancelled(), !Task.isCancelled else { throw NativeRoutedPEXPreparationError.cancelled }
            config = try JSONDecoder().decode(NativeRoutedPEXConfiguration.self,
                from: Self.readInput(reference.configurationURL, maximumBytes: reference.maximumConfigurationBytes,
                    diagnostic: "Routed configuration"))
        } catch let error as NativeRoutedPEXPreparationError { throw error }
        catch { throw .sourceDecode("Routed configuration: \(error)") }
        var budget = NativeRoutedPEXPreparationBudget(limits: config.preparationLimits)
        try config.validate(requiredCornerIDs: requiredCornerIDs, processName: context.technology.processName,
            authorityReferences: context.executionInputArtifacts, budget: &budget, isCancelled: isCancelled)
        guard requiredCornerIDs.contains(context.corner.id),
              let selected = config.sources.corners.first(where: { $0.cornerID == context.corner.id }) else {
            throw .missingSource("Selected execution corner has no requested source selection")
        }
        var calibrations: [ArtifactID: URL] = [:]
        for file in reference.calibrations {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            guard calibrations.updateValue(file.url, forKey: file.artifactID) == nil else {
                throw .invalidConfiguration("Duplicate calibration content identity")
            }
        }
        var loaded: [ArtifactID: Data] = [:]
        var sourceReferences: [ArtifactReference] = []
        func load(_ source: ArtifactReference, at location: URL? = nil) throws(NativeRoutedPEXPreparationError) -> Data {
            try budget.visit(isCancelled: isCancelled)
            if let previous = loaded[source.id] { return previous }
            guard let url = location ?? calibrations[source.id],
                  let count = Int(exactly: source.id.byteCount), count > 0,
                  count <= config.preparationLimits.maximumSourceBytes else {
                throw .missingSource("Source is absent or exceeds its byte ceiling: \(source.id.digest.hexadecimalValue)")
            }
            try budget.visit(count, isCancelled: isCancelled)
            let bytes: Data
            bytes = try Self.readInput(url, maximumBytes: count, diagnostic: "Source read")
            guard bytes.count == count, PEXRequestHash.compute(from: bytes).value == source.id.digest.hexadecimalValue else {
                throw .sourceMismatch("Actual source digest/count differs from its exact declaration")
            }
            try budget.record(2)
            loaded[source.id] = bytes; sourceReferences.append(source)
            return bytes
        }
        let defBytes = try load(config.sources.expectedDEF, at: context.layoutURL)
        let netlistBytes = try load(config.sources.expectedSourceNetlist, at: context.sourceNetlistURL)
        var decodedLEFs: [ArtifactID: NativeRoutedPEXDecodedLEF] = [:]
        func decodeLEF(_ source: ArtifactReference) throws(NativeRoutedPEXPreparationError) -> NativeRoutedPEXDecodedLEF {
            try budget.visit(isCancelled: isCancelled)
            if let decoded = decodedLEFs[source.id] { return decoded }
            let bytes = try load(source)
            let result: NativeRoutedPEXDecodedLEF
            do { result = .init(document: try LEFLibraryReader.read(bytes), reference: source) }
            catch { throw .sourceDecode("Owned LEF codec refused source: \(error)") }
            try budget.record(); decodedLEFs[source.id] = result
            return result
        }
        let rules = try load(selected.rules)
        let source: DEFSourceDocument
        do {
            source = try DEFLibraryReader.readForRoutedPEX(defBytes,
                maximumSourceBytes: config.preparationLimits.maximumSourceBytes, isCancelled: isCancelled)
        } catch DEFError.cancelled { throw .cancelled }
        catch { throw .sourceDecode("Owned DEF codec refused source: \(error)") }
        let technology = try decodeLEF(selected.technologyLEF)
        let routeTechnology = try decodeLEF(config.sources.routedTechnologyLEF)
        var cornerTechnologies: [NativeRoutedPEXDecodedLEF] = []
        for cornerID in requiredCornerIDs {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            guard let corner = config.sources.corners.first(where: { $0.cornerID == cornerID }),
                  corner.selection.routingLayerNames == selected.selection.routingLayerNames else {
                throw .sourceMismatch("Requested corners must retain the same exact routing-layer domain")
            }
            cornerTechnologies.append(try decodeLEF(corner.technologyLEF))
        }
        var libraries: [NativeRoutedPEXDecodedLEF] = []
        for library in config.sources.standardCellLEFs {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            libraries.append(try decodeLEF(library))
        }
        let model: PEXOpenRCXSourceModel
        do { model = try compiler.compile(bytes: rules, selection: selected.selection,
            limits: config.compilationLimits, isCancelled: isCancelled) }
        catch PEXOpenRCXSourceError.cancelled { throw .cancelled }
        catch { throw .sourceDecode("Original RC source compiler refused source: \(error)") }
        try budget.record(sourceReferences.count)
        var geometry = try NativeRoutedPEXStandardGeometry(source: source, defReference: config.sources.expectedDEF,
            technology: technology, routeTechnology: routeTechnology, cornerTechnologies: cornerTechnologies, libraries: libraries, selection: selected.selection, topCell: context.topCell,
            budget: budget, isCancelled: isCancelled)
        let structural = try decodeSource(netlistBytes, top: context.topCell, limits: config.preparationLimits,
            budget: &geometry.budget, isCancelled: isCancelled)
        let sourceJoin = try geometry.joinSource(structural, sourceReference: config.sources.expectedSourceNetlist,
            isCancelled: isCancelled)
        let ground = try NativeRoutedPEXGroundSourceProjection.project(technology: technology,
            selection: selected.selection, cornerID: context.corner.id, budget: &geometry.budget, isCancelled: isCancelled)
        let input = try geometry.project(sourceArtifacts: sourceReferences.map(\.id), isCancelled: isCancelled)
        return .init(input: input, model: model, groundCapacitanceModel: ground,
            maximumCellSpanDatabaseUnits: config.maximumCellSpanDatabaseUnits, limits: config.extractionLimits, sourceReferences: sourceReferences, sourceJoin: sourceJoin)
    }

    // Both production read sites use this boundary so reader failures retain one mapping.
    internal static func readInput(_ url: URL, maximumBytes: Int, diagnostic: String)
        throws(NativeRoutedPEXPreparationError) -> Data {
        do { return try PEXBoundedInputReader().read(url, maximumBytes: maximumBytes) }
        catch let error as PEXError where error.kind == .cancelled { throw .cancelled }
        catch { throw .sourceDecode("\(diagnostic): \(error)") }
    }

}
