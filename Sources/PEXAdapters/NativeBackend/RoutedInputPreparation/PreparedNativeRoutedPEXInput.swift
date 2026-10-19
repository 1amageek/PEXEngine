import CircuiteFoundation
import PEXCore
import PEXNative

/// Exact source preparation, not a numerical extraction or process qualification result.
public struct PreparedNativeRoutedPEXInput: Sendable {
    public let input: NativeRoutedPEXInput
    public let model: PEXOpenRCXSourceModel
    public let groundCapacitanceModel: PEXRoutedGroundCapacitanceModel
    public let maximumCellSpanDatabaseUnits: Int32
    public let limits: NativeRoutedPEXLimits
    public let sourceJoin: NativeRoutedPEXSourceJoinEvidence
    public let sourceReferences: [ArtifactReference]

    init(input: NativeRoutedPEXInput, model: PEXOpenRCXSourceModel,
         groundCapacitanceModel: PEXRoutedGroundCapacitanceModel, maximumCellSpanDatabaseUnits: Int32,
         limits: NativeRoutedPEXLimits,
         sourceReferences: [ArtifactReference], sourceJoin: NativeRoutedPEXSourceJoinEvidence) {
        self.input = input; self.model = model; self.groundCapacitanceModel = groundCapacitanceModel
        self.maximumCellSpanDatabaseUnits = maximumCellSpanDatabaseUnits; self.limits = limits
        self.sourceReferences = sourceReferences; self.sourceJoin = sourceJoin
    }
}
