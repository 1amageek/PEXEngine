import CircuiteFoundation
import PEXCore
@testable import PEXNative

struct RoutedPEXFixture {
    typealias Input = NativeRoutedPEXInput
    struct WireSpec {
        let id: String, net: String
        var role: Input.Role = .signal
        var layer = 2
        let x0: Int64, y0: Int64, x1: Int64, y1: Int64
    }
    let model: PEXOpenRCXSourceModel
    let facts: [Input.SourceFact]
    let artifacts: [ArtifactID]
    let limits = NativeRoutedPEXLimits(maximumInputRecords: 100_000, maximumStringBytes: 100_000,
        maximumSourceRecords: 10_000, maximumWorkVisits: 1_000_000, maximumTrackEntries: 100_000,
        maximumCoordinateValues: 100_000, maximumGraphNodes: 10_000, maximumGraphElements: 100_000, maximumQueryReceipts: 100_000)

    init(empty: PEXOpenRCXSourceModel.Context? = nil) throws {
        let rules = try ArtifactID(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: "ab", count: 32)), byteCount: 1_000_000)
        let tech = try ArtifactID(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: "bc", count: 32)), byteCount: 1000)
        let def = try ArtifactID(digest: .init(algorithm: .sha256, hexadecimalValue: String(repeating: "cd", count: 32)), byteCount: 1000)
        artifacts = [rules, tech, def]
        facts = [tech, def].map { .init(artifactID: $0, byteRange: .init(lowerBound: 0, upperBound: 10)) }
        var families: [PEXOpenRCXSourceModel.Family] = [], tables: [PEXOpenRCXSourceModel.Table] = []
        for metal in 1...6 {
            var kinds: [PEXOpenRCXSourceModel.Kind] = [.resOver, .over, .under, .diagUnder]
            if (2...5).contains(metal) { kinds.append(.overUnder) }
            for kind in kinds {
                let start = 100 + families.count * 20_000
                let width = [0.17, 0.14, 0.14, 0.3, 0.3, 1.6][metal - 1]
                families.append(.init(metal: metal, kind: kind,
                    widthsMicrons: metal == 6 && (kind == .under || kind == .diagUnder) ? [] : [width],
                    sourceRange: .init(lowerBound: start, upperBound: start + 20_000)))
                var contexts: [PEXOpenRCXSourceModel.Context] = []
                switch kind {
                case .resOver, .over: contexts = (0..<metal).map { .init(metal: metal, kind: kind, underMetal: $0) }
                case .under, .diagUnder:
                    if metal < 6 { contexts = ((metal + 1)...6).map { .init(metal: metal, kind: kind, overMetal: $0) } }
                case .overUnder:
                    for lower in 1..<metal { for upper in (metal + 1)...6 {
                        contexts.append(.init(metal: metal, kind: kind, underMetal: lower, overMetal: upper))
                    } }
                }
                for (index, context) in contexts.enumerated() {
                    let position = start + index * 100
                    let samples: [PEXOpenRCXSourceModel.CapacitanceSample] = kind == .resOver || context == empty ? [] : [0.0, 0.1].enumerated().map { i, d in
                        .init(distanceMicrons: d, couplingFemtofaradsPerNanometer: 0.002,
                            fringeFemtofaradsPerNanometer: 0.001, resistanceOhmsPerNanometer: 1,
                            sourceRange: .init(lowerBound: position + 10 + i, upperBound: position + 11 + i))
                    }
                    tables.append(.init(context: context, widthMicrons: width,
                        sourceRange: .init(lowerBound: position, upperBound: position + 100), capacitanceSamples: samples))
                }
            }
        }
        model = try .init(selection: .init(processName: "synthetic-routed-source-law", corner: .nominal,
            rulesArtifactID: rules, technologyLEFArtifactID: tech,
            routingLayerNames: ["li1", "met1", "met2", "met3", "met4", "met5"]),
            sourceHeaderRange: .init(lowerBound: 0, upperBound: 100), families: families, tables: tables)
    }
    func input(_ specs: [WireSpec]) -> Input {
        var nets: [Input.Net] = [], nodes: [Input.Node] = [], wires: [Input.Wire] = [], terminals: [Input.Terminal] = []
        var pointRefs: [NativeRoutedPEXGeometry.PointKey: NodeRef] = [:]
        for (ordinal, spec) in specs.enumerated() {
            let net = NetName(spec.net), layer = model.selection.routingLayerNames[spec.layer - 1]
            if !nets.contains(where: { $0.name == net }) { nets.append(.init(name: net, role: spec.role, sourceFacts: facts)) }
            let axis: Input.Axis = spec.y0 == spec.y1 ? .horizontal : .vertical
            func node(_ x: Int64, _ y: Int64, _ suffix: String) -> NodeRef {
                let key = NativeRoutedPEXGeometry.PointKey(net: net, layer: layer, x: x, y: y)
                if let ref = pointRefs[key] { return ref }
                let ref = NodeRef(netName: net, nodeName: .init(spec.id + suffix))
                pointRefs[key] = ref
                if spec.role == .signal {
                    nodes.append(.init(ref: ref, layerName: layer, x: x, y: y, sourceFacts: facts))
                    terminals.append(.init(ref: ref, contacts: [.init(layerName: layer,
                        rect: .init(minX: x - 5, minY: y - 5, maxX: x + 5, maxY: y + 5), sourceFacts: facts)], sourceFacts: facts))
                }
                return ref
            }
            let a = node(spec.x0, spec.y0, ".a"), b = node(spec.x1, spec.y1, ".b")
            wires.append(.init(sourceID: spec.id, sourceOrdinal: ordinal, netName: net, layerName: layer, axis: axis,
                rect: .init(minX: min(spec.x0, spec.x1) - 5, minY: min(spec.y0, spec.y1) - 5,
                            maxX: max(spec.x0, spec.x1) + 5, maxY: max(spec.y0, spec.y1) + 5),
                sourceNode: a, targetNode: b, sourceFacts: facts))
        }
        let layers = (1...6).map { level in Input.Layer(name: model.selection.routingLayerNames[level - 1], level: level,
            preferredDirection: .horizontal, pitchDatabaseUnits: 100, defaultWidthDatabaseUnits: 10,
            sheetResistanceOhmsPerSquare: 2, searchOriginX: 0, searchOriginY: 0,
            originDerivationX: .dieLowerLeft, originDerivationY: .dieLowerLeft, sourceFacts: facts) }
        return .init(selection: model.selection, defArtifactID: artifacts[2], sourceArtifacts: artifacts,
            databaseUnitsPerMicron: 1000, dieBounds: .init(minX: 0, minY: 0, maxX: 3000, maxY: 3000),
            layers: layers, nets: nets, nodes: nodes, wires: wires, vias: [], terminals: terminals)
    }
    func replace(_ value: Input, wires: [Input.Wire]? = nil, vias: [Input.Via]? = nil,
                 terminals: [Input.Terminal]? = nil, nodes: [Input.Node]? = nil,
                 layers: [Input.Layer]? = nil, sourceArtifacts: [ArtifactID]? = nil) -> Input {
        .init(selection: value.selection, defArtifactID: value.defArtifactID, sourceArtifacts: sourceArtifacts ?? value.sourceArtifacts,
            databaseUnitsPerMicron: value.databaseUnitsPerMicron, dieBounds: value.dieBounds, layers: layers ?? value.layers,
            nets: value.nets, nodes: nodes ?? value.nodes, wires: wires ?? value.wires,
            vias: vias ?? value.vias, terminals: terminals ?? value.terminals)
    }
    func calculate(_ input: Input, limits: NativeRoutedPEXLimits? = nil, isCancelled: () -> Bool = { false }) throws -> NativeRoutedPEXResult {
        try PinnedRoutedPEXCalculator().calculate(input: input, model: model, cornerID: "tt",
            limits: limits ?? self.limits, isCancelled: isCancelled)
    }
}
