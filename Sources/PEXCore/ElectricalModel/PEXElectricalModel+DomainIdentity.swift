import Foundation
import CircuiteFoundation

extension PEXElectricalModel {
    /// Canonical numerical-domain identity, independent of layout, run, and corner selection.
    /// The caller admits the containing technology; identity does not grant qualification.
    public func domainDigest() throws -> ContentDigest {
        let pairs = couplings.map { pair in
            PEXCouplingElectricalModel(firstLayerName: min(pair.firstLayerName, pair.secondLayerName),
                secondLayerName: max(pair.firstLayerName, pair.secondLayerName),
                areaFaradsPerSquareMeter: pair.areaFaradsPerSquareMeter,
                sidewallFarads: pair.sidewallFarads, gapRange: pair.gapRange)
        }.sorted {
            ($0.firstLayerName, $0.secondLayerName) < ($1.firstLayerName, $1.secondLayerName)
        }
        let normalized = PEXElectricalModel(law: law, coplanarScreening: coplanarScreening,
            processName: processName, cornerID: cornerID, temperatureKelvin: temperatureKelvin,
            voltageVolts: voltageVolts, parameters: parameters, referenceNodeName: referenceNodeName,
            calibrationArtifacts: calibrationArtifacts.sorted {
                ($0.digest.hexadecimalValue, $0.byteCount) < ($1.digest.hexadecimalValue, $1.byteCount)
            }, conductors: conductors.sorted { $0.layerName < $1.layerName },
            vias: vias.sorted { $0.viaName < $1.viaName }, couplings: pairs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try ContentDigest(algorithm: .sha256,
            hexadecimalValue: PEXRequestHash.compute(from: encoder.encode(normalized)).value)
    }
}
