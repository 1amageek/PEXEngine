import Foundation
import CircuiteFoundation
import CryptoKit
import PEXCore
import PEXNative

/// Exact source observations for one measured routed execution; decoding is not checked authority.
public struct NativeRoutedPEXExecutionEvidence: Sendable, Codable {
    public static let inputFileName = "native-routed-input.json"
    public static let resultFileName = "native-routed-result.json"
    public static let sourceFileName = "native-routed-source.json"
    public static let currentVersion = 2
    public let version: Int
    public let algorithm: NativeRoutedPEXConfiguration.Algorithm
    public let configurationKind: PEXNativeConfigurationKind
    public let cornerID: PEXCornerID
    public let requestedCornerIDs: [PEXCornerID]
    public let sourceReferences: [ArtifactReference]
    public let sourceJoin: NativeRoutedPEXSourceJoinEvidence
    /// Binds every original geometry/source fact in the separately retained input artifact.
    public let inputDigest: ContentDigest
    public let model: PEXOpenRCXSourceModel
    public let groundCapacitanceModel: PEXRoutedGroundCapacitanceModel
    public let maximumCellSpanDatabaseUnits: Int32
    public let limits: NativeRoutedPEXLimits
    public let policy: NativePEXBackendPolicy
    public let image: NativePEXCodeImage
    public let executionIdentity: PEXBackendExecutionIdentity

    init(prepared: PreparedNativeRoutedPEXInput, context: PEXExecutionContext,
         policy: NativePEXBackendPolicy, image: NativePEXCodeImage, identity: PEXBackendExecutionIdentity) throws {
        version = Self.currentVersion; algorithm = .unionSheetAreaBoundaryV1
        configurationKind = .routedOpenRCXV1; cornerID = context.corner.id
        requestedCornerIDs = context.requestedCornerIDs; sourceReferences = prepared.sourceReferences
        sourceJoin = prepared.sourceJoin; inputDigest = try Self.digest(prepared.input)
        model = prepared.model; groundCapacitanceModel = prepared.groundCapacitanceModel
        maximumCellSpanDatabaseUnits = prepared.maximumCellSpanDatabaseUnits
        limits = prepared.limits; self.policy = policy
        self.image = image; executionIdentity = identity
    }

    /// Call only after fresh preparation has verified the exact captured source bytes.
    /// This comparison binds observations; it does not rerun the numerical solver or qualify physics.
    public func requireBinding(to prepared: PreparedNativeRoutedPEXInput, context: PEXExecutionContext,
                               policy: NativePEXBackendPolicy, image: NativePEXCodeImage,
                               identity: PEXBackendExecutionIdentity) throws {
        guard version == Self.currentVersion, algorithm == .unionSheetAreaBoundaryV1,
              configurationKind == .routedOpenRCXV1, context.nativeInput?.configurationKind == .routedOpenRCXV1,
              cornerID == context.corner.id, requestedCornerIDs == context.requestedCornerIDs,
              sourceReferences == prepared.sourceReferences,
              try Self.canonical(sourceJoin) == Self.canonical(prepared.sourceJoin),
              inputDigest == (try Self.digest(prepared.input)),
              model == prepared.model,
              groundCapacitanceModel == prepared.groundCapacitanceModel,
              maximumCellSpanDatabaseUnits > 0, maximumCellSpanDatabaseUnits == prepared.maximumCellSpanDatabaseUnits,
              limits == prepared.limits, self.policy == policy, self.image == image,
              executionIdentity == identity, identity.producer.identifier == "pex-native",
              identity.producer.version == "4.0.0", identity.binaryDigest == image.digest,
              identity.environment.environmentDigest == (try NativePEXAdapter.routedEnvironmentDigest(prepared)) else {
            throw NativePEXBackendError.unsupportedRequest("Routed source evidence differs from fresh prepared sources or runtime identity")
        }
    }

    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func digest<T: Encodable>(_ value: T) throws -> ContentDigest {
        try .init(algorithm: .sha256, hexadecimalValue: SHA256.hash(data: canonical(value))
            .map { String(format: "%02x", $0) }.joined())
    }
    private enum CodingKeys: String, CodingKey {
        case version, algorithm, configurationKind, cornerID, requestedCornerIDs, sourceReferences, sourceJoin, inputDigest
        case model, groundCapacitanceModel, maximumCellSpanDatabaseUnits, limits, policy, image, executionIdentity
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Only union-sheet routed evidence version 2 is supported")
        }
        algorithm = try c.decode(NativeRoutedPEXConfiguration.Algorithm.self, forKey: .algorithm)
        configurationKind = try c.decode(PEXNativeConfigurationKind.self, forKey: .configurationKind)
        cornerID = try c.decode(PEXCornerID.self, forKey: .cornerID)
        requestedCornerIDs = try c.decode([PEXCornerID].self, forKey: .requestedCornerIDs)
        sourceReferences = try c.decode([ArtifactReference].self, forKey: .sourceReferences)
        sourceJoin = try c.decode(NativeRoutedPEXSourceJoinEvidence.self, forKey: .sourceJoin)
        inputDigest = try c.decode(ContentDigest.self, forKey: .inputDigest)
        model = try c.decode(PEXOpenRCXSourceModel.self, forKey: .model)
        groundCapacitanceModel = try c.decode(PEXRoutedGroundCapacitanceModel.self, forKey: .groundCapacitanceModel)
        maximumCellSpanDatabaseUnits = try c.decode(Int32.self, forKey: .maximumCellSpanDatabaseUnits)
        limits = try c.decode(NativeRoutedPEXLimits.self, forKey: .limits)
        policy = try c.decode(NativePEXBackendPolicy.self, forKey: .policy)
        image = try c.decode(NativePEXCodeImage.self, forKey: .image)
        executionIdentity = try c.decode(PEXBackendExecutionIdentity.self, forKey: .executionIdentity)
        guard configurationKind == .routedOpenRCXV1, maximumCellSpanDatabaseUnits > 0,
              groundCapacitanceModel.algorithm == .lefAreaBoundaryV1,
              groundCapacitanceModel.cornerID == cornerID, groundCapacitanceModel.selection == model.selection,
              requestedCornerIDs.contains(cornerID), inputDigest.algorithm == .sha256 else {
            throw DecodingError.dataCorruptedError(forKey: .groundCapacitanceModel, in: c,
                debugDescription: "Routed evidence law, positive span and selected ground corner must agree")
        }
    }
}
