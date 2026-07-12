import Foundation
import PEXCore

public struct DSPFPEXParser: PEXParserProtocol {
    public let format: PEXOutputFormat = .dspf

    public let groundNodes: Set<String>

    public init(groundNodes: Set<String> = ["0", "gnd", "gnd!", "vsubs", "substrate", "sub!"]) {
        self.groundNodes = Set(groundNodes.map { $0.lowercased() })
    }

    public func parse(_ raw: PEXRawOutput, context: PEXParseContext) throws -> ParasiticIR {
        try validateFormat(raw.format, context: context)
        let fileURL = try selectedFile(from: raw, context: context)
        let source = try readSource(from: fileURL, context: context)
        return try lower(source: source, sourceFileName: fileURL.lastPathComponent, raw: raw, context: context)
    }

    private func validateFormat(_ rawFormat: PEXOutputFormat, context: PEXParseContext) throws {
        guard rawFormat == format else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "DSPF parser received raw output format '\(rawFormat.rawValue)'"
            )
        }
    }

    private func selectedFile(from raw: PEXRawOutput, context: PEXParseContext) throws -> URL {
        guard let fileURL = raw.fileURLs.first else {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "No DSPF file found in raw output"
            )
        }
        return fileURL
    }

    private func readSource(from fileURL: URL, context: PEXParseContext) throws -> String {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw PEXError.parseFailed(
                cornerID: context.cornerID,
                message: "Failed to read DSPF file: \(fileURL.lastPathComponent)",
                underlying: error
            )
        }
    }

    private func lower(
        source: String,
        sourceFileName: String,
        raw: PEXRawOutput,
        context: PEXParseContext
    ) throws -> ParasiticIR {
        return try DSPFLowering(
            source: source,
            sourceFileName: sourceFileName,
            requestedTopSubckt: raw.metadata["topSubckt"] ?? raw.metadata["topCell"] ?? raw.metadata["designName"],
            groundNodes: groundNodes,
            options: context.options,
            cornerID: context.cornerID
        ).lower()
    }
}

private struct DSPFLowering {
    let source: String
    let sourceFileName: String
    let requestedTopSubckt: String?
    let groundNodes: Set<String>
    let options: PEXRunOptions
    let cornerID: PEXCornerID

    func lower() throws -> ParasiticIR {
        let document = try parseDocument()
        let selection = try selectContent(from: document)
        let content = selection.content
        let resolvedParams = document.global.params.merging(content.params) { _, local in local }
        let flattened = try flatten(
            content: content,
            document: document,
            inheritedParams: document.global.params,
            path: [],
            bindings: [:],
            stack: [selection.topSubcktName]
        )

        struct GroundCapRecord { let id: String; let signal: String; let value: Double }
        struct PairRecord { let id: String; let a: String; let b: String; let value: Double }
        var grounds: [GroundCapRecord] = []
        var couplings: [PairRecord] = []
        var resistors: [PairRecord] = []
        var inductors: [PairRecord] = []
        var elementIDResolver = DSPFElementIDResolver()

        var nodeOrder: [String] = []
        var seenNodes: Set<String> = []
        var parent: [String: String] = [:]

        func isGround(_ node: String) -> Bool {
            groundNodes.contains(node.lowercased())
        }

        func see(_ node: String) {
            if parent[node] == nil {
                parent[node] = node
            }
            if seenNodes.insert(node).inserted {
                nodeOrder.append(node)
            }
        }

        func find(_ node: String) -> String {
            var root = node
            while parent[root] != root {
                guard let next = parent[root] else { return root }
                root = next
            }

            var cursor = node
            while parent[cursor] != root {
                guard let next = parent[cursor] else { break }
                parent[cursor] = root
                cursor = next
            }
            return root
        }

        func union(_ a: String, _ b: String) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB {
                parent[rootB] = rootA
            }
        }

        for record in flattened.elements {
            let nodeA = record.nodeA
            let nodeB = record.nodeB
            let value = try resolveValue(record.valueToken, params: record.params, sourceLine: record.sourceLine)
            let elementID = elementIDResolver.resolve(sourceID: record.id, subcktName: content.name)

            switch record.kind {
            case .capacitor:
                let aGround = isGround(nodeA)
                let bGround = isGround(nodeB)
                if aGround && bGround {
                    continue
                }
                if aGround || bGround {
                    let signal = aGround ? nodeB : nodeA
                    see(signal)
                    guard shouldIncludeCapacitance(value) else { continue }
                    grounds.append(GroundCapRecord(id: elementID, signal: signal, value: value))
                } else {
                    see(nodeA)
                    see(nodeB)
                    guard options.includeCouplingCaps else { continue }
                    guard shouldIncludeCapacitance(value) else { continue }
                    couplings.append(PairRecord(id: elementID, a: nodeA, b: nodeB, value: value))
                }
            case .resistor:
                see(nodeA)
                see(nodeB)
                union(nodeA, nodeB)
                guard shouldIncludeResistance(value) else { continue }
                resistors.append(PairRecord(id: elementID, a: nodeA, b: nodeB, value: value))
            case .inductor:
                see(nodeA)
                see(nodeB)
                union(nodeA, nodeB)
                guard shouldIncludeInductance() else { continue }
                inductors.append(PairRecord(id: elementID, a: nodeA, b: nodeB, value: value))
            }
        }

        var componentNodes: [String: [String]] = [:]
        for node in nodeOrder {
            componentNodes[find(node), default: []].append(node)
        }

        var netNameOf: [String: String] = [:]
        for (_, nodes) in componentNodes {
            let baseNames = Array(Set(nodes.map(Self.baseNetName)))
            let netName: String
            if baseNames.count == 1, let baseName = baseNames.first {
                netName = baseName
            } else {
                netName = baseNames.sorted().first ?? nodes.sorted().first ?? nodes[0]
            }
            for node in nodes {
                netNameOf[node] = netName
            }
        }

        func netName(_ node: String) -> String {
            netNameOf[node] ?? Self.baseNetName(node)
        }

        func nodeRef(_ node: String) -> NodeRef {
            NodeRef(netName: NetName(netName(node)), nodeName: NodeName(node))
        }

        let nodeAnnotations = Self.nodeAnnotations(flattened.annotations, nodeOrder: nodeOrder)
        var elements: [ParasiticElement] = []
        var groundCap: [String: Double] = [:]
        var couplingCap: [String: Double] = [:]
        var resistance: [String: Double] = [:]

        for ground in grounds {
            elements.append(ParasiticElement(
                id: ground.id,
                kind: .capacitor,
                nodeA: nodeRef(ground.signal),
                nodeB: nil,
                value: ground.value,
                source: .extracted
            ))
            groundCap[netName(ground.signal), default: 0] += ground.value
        }

        for coupling in couplings {
            elements.append(ParasiticElement(
                id: coupling.id,
                kind: .coupling,
                nodeA: nodeRef(coupling.a),
                nodeB: nodeRef(coupling.b),
                value: coupling.value,
                source: .extracted
            ))
            couplingCap[netName(coupling.a), default: 0] += coupling.value
        }

        for resistor in resistors {
            elements.append(ParasiticElement(
                id: resistor.id,
                kind: .resistor,
                nodeA: nodeRef(resistor.a),
                nodeB: nodeRef(resistor.b),
                value: resistor.value,
                source: .extracted
            ))
            resistance[netName(resistor.a), default: 0] += resistor.value
        }

        for inductor in inductors {
            elements.append(ParasiticElement(
                id: inductor.id,
                kind: .inductor,
                nodeA: nodeRef(inductor.a),
                nodeB: nodeRef(inductor.b),
                value: inductor.value,
                source: .extracted
            ))
        }

        var netOrder: [String] = []
        var seenNets: Set<String> = []
        for node in nodeOrder {
            let name = netName(node)
            if seenNets.insert(name).inserted {
                netOrder.append(name)
            }
        }

        let nets = netOrder.map { name in
            ParasiticNet(
                name: NetName(name),
                nodes: nodeOrder
                    .filter { netName($0) == name }
                    .map { nodeName in
                        let annotation = nodeAnnotations[nodeName]
                        let flattenedInstancePath = flattened.nodeInstancePaths[nodeName]
                        return ParasiticNode(
                            name: NodeName(nodeName),
                            kind: annotation?.kind ?? .internal,
                            instancePath: annotation?.instancePath ?? flattenedInstancePath,
                            coordinate: annotation?.coordinate
                        )
                    },
                totalGroundCapF: groundCap[name] ?? 0,
                totalCouplingCapF: couplingCap[name] ?? 0,
                totalResistanceOhm: resistance[name] ?? 0
            )
        }

        let irMetadata = try metadata(
            document: document,
            selection: selection,
            resolvedParams: resolvedParams,
            renamedElementIDs: elementIDResolver.renames,
            hierarchyExpansions: flattened.expansions,
            effectiveAnnotations: flattened.annotations,
            unresolvedInstances: flattened.unresolvedInstances
        )

        return ParasiticIR(
            version: ParasiticIR.currentVersion,
            cornerID: cornerID,
            units: .canonical,
            nets: nets,
            elements: elements,
            metadata: irMetadata
        )
    }

    private func shouldIncludeCapacitance(_ value: Double) -> Bool {
        guard options.extractMode != .rOnly else { return false }
        if let minCapacitanceF = options.minCapacitanceF, value < minCapacitanceF {
            return false
        }
        return true
    }

    private func shouldIncludeResistance(_ value: Double) -> Bool {
        guard options.extractMode != .cOnly else { return false }
        if let minResistanceOhm = options.minResistanceOhm, value < minResistanceOhm {
            return false
        }
        return true
    }

    private func shouldIncludeInductance() -> Bool {
        options.extractMode == .rc
    }

    private func parseDocument() throws -> DSPFDocument {
        var builder = DSPFDocumentBuilder(cornerID: cornerID)
        let lines = Self.logicalLines(from: source)
        for (offset, line) in lines.enumerated() {
            try builder.consume(line, lineNumber: offset + 1)
        }
        return try builder.finish()
    }

    private struct DSPFDocumentBuilder {
        var global = DSPFContent(
            name: nil,
            ports: [],
            elements: [],
            instances: [],
            annotations: [],
            params: [:],
            startsAtLine: nil,
            endsAtLine: nil
        )
        var subckts: [DSPFContent] = []
        var current: DSPFContent?
        let cornerID: PEXCornerID

        mutating func consume(_ line: String, lineNumber: Int) throws {
            switch DSPFLowering.directiveName(from: line) {
            case ".subckt":
                try beginSubckt(line, lineNumber: lineNumber)
            case ".ends":
                try endSubckt(line, lineNumber: lineNumber)
            case ".param":
                try mergeParameters(line)
            default:
                try appendRecords(line, lineNumber: lineNumber)
            }
        }

        mutating func finish() throws -> DSPFDocument {
            if let active = current {
                throw parseError("Unterminated .SUBCKT \(active.name ?? "")")
            }
            return DSPFDocument(global: global, subckts: subckts)
        }

        private mutating func beginSubckt(_ line: String, lineNumber: Int) throws {
            guard current == nil else {
                throw parseError("Nested .SUBCKT is not supported at line \(lineNumber): \(line)")
            }
            current = try DSPFLowering.subckt(from: line, lineNumber: lineNumber, cornerID: cornerID)
        }

        private mutating func endSubckt(_ line: String, lineNumber: Int) throws {
            guard var active = current else {
                throw parseError(".ENDS without active .SUBCKT at line \(lineNumber): \(line)")
            }
            let endName = DSPFLowering.endSubcktName(from: line)
            if let endName, endName.caseInsensitiveCompare(active.name ?? "") != .orderedSame {
                throw parseError(".ENDS \(endName) does not match .SUBCKT \(active.name ?? "") at line \(lineNumber)")
            }
            active.endsAtLine = lineNumber
            subckts.append(active)
            current = nil
        }

        private mutating func mergeParameters(_ line: String) throws {
            let params = try DSPFLowering.parameters(from: line, cornerID: cornerID)
            updateActiveOrGlobal { content in
                content.params.merge(params) { _, new in new }
            }
        }

        private mutating func appendRecords(_ line: String, lineNumber: Int) throws {
            if let annotation = DSPFLowering.annotation(from: line, subcktName: current?.name, lineNumber: lineNumber) {
                updateActiveOrGlobal { $0.annotations.append(annotation) }
            }
            if let element = try DSPFLowering.element(from: line, subcktName: current?.name, lineNumber: lineNumber, cornerID: cornerID) {
                updateActiveOrGlobal { $0.elements.append(element) }
            }
            if let instance = DSPFLowering.instance(from: line, subcktName: current?.name, lineNumber: lineNumber) {
                updateActiveOrGlobal { $0.instances.append(instance) }
            }
        }

        private mutating func updateActiveOrGlobal(_ update: (inout DSPFContent) -> Void) {
            if var active = current {
                update(&active)
                current = active
            } else {
                update(&global)
            }
        }

        private func parseError(_ message: String) -> PEXError {
            PEXError.parseFailed(cornerID: cornerID, message: message)
        }
    }

    private func selectContent(from document: DSPFDocument) throws -> DSPFContentSelection {
        if let requestedTopSubckt {
            let trimmed = requestedTopSubckt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed == "__global__" {
                    return DSPFContentSelection(content: document.global, topSubcktName: "__global__", reason: "explicit-global")
                }
                if let selected = document.subckts.first(where: { ($0.name ?? "").caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    return DSPFContentSelection(content: selected, topSubcktName: selected.name ?? trimmed, reason: "explicit")
                }
                throw parseError("Requested DSPF top subckt '\(trimmed)' was not found")
            }
        }

        if let selected = document.subckts.last(where: { !$0.elements.isEmpty || !$0.instances.isEmpty }) {
            return DSPFContentSelection(content: selected, topSubcktName: selected.name ?? "__unnamed__", reason: "last-element-bearing-subckt")
        }
        if !document.global.elements.isEmpty {
            return DSPFContentSelection(content: document.global, topSubcktName: "__global__", reason: "global-elements")
        }
        if let selected = document.subckts.last {
            return DSPFContentSelection(content: selected, topSubcktName: selected.name ?? "__unnamed__", reason: "last-declared-subckt")
        }
        return DSPFContentSelection(content: document.global, topSubcktName: "__global__", reason: "empty-document")
    }

    private func resolveValue(_ token: String, params: [String: String], sourceLine: String) throws -> Double {
        if let value = MagicSPICEParasiticParser.parseSPICEValue(token) {
            return value
        }

        let key = Self.parameterKey(from: token)
        return try resolveParameterValue(key, params: params, visited: [], sourceToken: token, sourceLine: sourceLine)
    }

    private func resolveParameterValue(
        _ key: String,
        params: [String: String],
        visited: Set<String>,
        sourceToken: String,
        sourceLine: String
    ) throws -> Double {
        guard let resolved = params[key] else {
            throw parseError("Unparseable DSPF value '\(sourceToken)' in line: \(sourceLine)")
        }

        if let value = MagicSPICEParasiticParser.parseSPICEValue(resolved) {
            return value
        }

        let nextKey = Self.parameterKey(from: resolved)
        guard nextKey != key, !visited.contains(nextKey) else {
            throw parseError("DSPF parameter '\(sourceToken)' has a cyclic definition at '\(resolved)' in line: \(sourceLine)")
        }

        var nextVisited = visited
        nextVisited.insert(key)
        return try resolveParameterValue(
            nextKey,
            params: params,
            visited: nextVisited,
            sourceToken: sourceToken,
            sourceLine: sourceLine
        )
    }

    private func metadata(
        document: DSPFDocument,
        selection: DSPFContentSelection,
        resolvedParams: [String: String],
        renamedElementIDs: [DSPFElementRename],
        hierarchyExpansions: [DSPFHierarchyExpansion],
        effectiveAnnotations: [DSPFAnnotationRecord],
        unresolvedInstances: [DSPFUnresolvedInstance]
    ) throws -> [String: String] {
        let sourceAnnotations = document.allAnnotations
        var metadata: [String: String] = [
            "sourceFormat": "dspf",
            "sourceFile": sourceFileName,
            "dspf.topSubckt": selection.topSubcktName,
            "dspf.topSubcktSelection": selection.reason,
            "topCell": selection.topSubcktName,
            "dspf.subckt.count": "\(document.subckts.count)",
            "dspf.annotation.count": "\(sourceAnnotations.count)",
            "dspf.annotation.pin.count": "\(sourceAnnotations.filter { $0.kind == "P" }.count)",
            "dspf.annotation.instance.count": "\(sourceAnnotations.filter { $0.kind == "I" }.count)",
            "dspf.annotation.subnode.count": "\(sourceAnnotations.filter { $0.kind == "S" }.count)",
            "dspf.effectiveAnnotation.count": "\(effectiveAnnotations.count)",
            "dspf.effectiveAnnotation.pin.count": "\(effectiveAnnotations.filter { $0.kind == "P" }.count)",
            "dspf.effectiveAnnotation.instance.count": "\(effectiveAnnotations.filter { $0.kind == "I" }.count)",
            "dspf.effectiveAnnotation.subnode.count": "\(effectiveAnnotations.filter { $0.kind == "S" }.count)",
            "dspf.param.count": "\(resolvedParams.count)",
            "dspf.renamedElementID.count": "\(renamedElementIDs.count)",
            "dspf.hierarchyExpansion.count": "\(hierarchyExpansions.count)",
            "dspf.unresolvedInstance.count": "\(unresolvedInstances.count)",
        ]
        metadata["dspf.subckts"] = try metadataJSON(document.subckts.map(DSPFSubcktMetadata.init(content:)))
        metadata["dspf.annotations"] = try metadataJSON(sourceAnnotations)
        metadata["dspf.sourceAnnotations"] = try metadataJSON(sourceAnnotations)
        metadata["dspf.effectiveAnnotations"] = try metadataJSON(effectiveAnnotations)
        metadata["dspf.params"] = try metadataJSON(resolvedParams.sorted { $0.key < $1.key }.map { DSPFParameterMetadata(name: $0.key, value: $0.value) })
        metadata["dspf.renamedElementIDs"] = try metadataJSON(renamedElementIDs)
        metadata["dspf.hierarchyExpansions"] = try metadataJSON(hierarchyExpansions)
        metadata["dspf.unresolvedInstances"] = try metadataJSON(unresolvedInstances)
        return metadata
    }

    private func flatten(
        content: DSPFContent,
        document: DSPFDocument,
        inheritedParams: [String: String],
        path: [String],
        bindings: [String: String],
        stack: [String]
    ) throws -> DSPFFlattenedContent {
        let localParams = inheritedParams.merging(content.params) { _, local in local }
        var flattened = Self.emptyFlattenedContent()
        appendMappedAnnotations(content.annotations, bindings: bindings, path: path, to: &flattened)
        appendMappedElements(
            content.elements,
            contentName: content.name,
            localParams: localParams,
            bindings: bindings,
            path: path,
            to: &flattened
        )
        try appendFlattenedInstances(
            content.instances,
            parentSubckt: content.name,
            document: document,
            localParams: localParams,
            path: path,
            bindings: bindings,
            stack: stack,
            to: &flattened
        )
        return flattened
    }

    private static func emptyFlattenedContent() -> DSPFFlattenedContent {
        DSPFFlattenedContent(
            elements: [],
            annotations: [],
            nodeInstancePaths: [:],
            expansions: [],
            unresolvedInstances: []
        )
    }

    private func appendMappedAnnotations(
        _ annotations: [DSPFAnnotationRecord],
        bindings: [String: String],
        path: [String],
        to flattened: inout DSPFFlattenedContent
    ) {
        flattened.annotations.append(contentsOf: annotations.map { annotation in
            Self.mappedAnnotation(
                annotation,
                bindings: bindings,
                path: path,
                groundNodes: groundNodes
            )
        })
    }

    private func appendMappedElements(
        _ elements: [DSPFElementRecord],
        contentName: String?,
        localParams: [String: String],
        bindings: [String: String],
        path: [String],
        to flattened: inout DSPFFlattenedContent
    ) {
        for element in elements {
            var nodeInstancePaths: [String: InstancePath] = [:]
            let nodeA = Self.mappedNode(
                element.nodeA,
                bindings: bindings,
                path: path,
                groundNodes: groundNodes,
                nodeInstancePaths: &nodeInstancePaths
            )
            let nodeB = Self.mappedNode(
                element.nodeB,
                bindings: bindings,
                path: path,
                groundNodes: groundNodes,
                nodeInstancePaths: &nodeInstancePaths
            )
            flattened.nodeInstancePaths.merge(nodeInstancePaths) { current, _ in current }
            flattened.elements.append(DSPFFlattenedElementRecord(
                id: Self.scopedElementID(element.id, path: path),
                kind: element.kind,
                nodeA: nodeA,
                nodeB: nodeB,
                valueToken: element.valueToken,
                params: localParams,
                sourceSubcktName: contentName,
                sourceLine: element.sourceLine,
                lineNumber: element.lineNumber
            ))
        }
    }

    private func appendFlattenedInstances(
        _ instances: [DSPFInstanceRecord],
        parentSubckt: String?,
        document: DSPFDocument,
        localParams: [String: String],
        path: [String],
        bindings: [String: String],
        stack: [String],
        to flattened: inout DSPFFlattenedContent
    ) throws {
        for instance in instances {
            try appendFlattenedInstance(
                instance,
                parentSubckt: parentSubckt,
                document: document,
                localParams: localParams,
                path: path,
                bindings: bindings,
                stack: stack,
                to: &flattened
            )
        }
    }

    private func appendFlattenedInstance(
        _ instance: DSPFInstanceRecord,
        parentSubckt: String?,
        document: DSPFDocument,
        localParams: [String: String],
        path: [String],
        bindings: [String: String],
        stack: [String],
        to flattened: inout DSPFFlattenedContent
    ) throws {
        guard let target = Self.resolveTarget(for: instance, in: document) else {
            flattened.unresolvedInstances.append(unresolvedInstance(
                instance,
                parentSubckt: parentSubckt,
                path: path,
                reason: "no_known_subckt_token"
            ))
            return
        }
        guard let child = document.subckt(named: target.subcktName) else {
            flattened.unresolvedInstances.append(unresolvedInstance(
                instance,
                parentSubckt: parentSubckt,
                path: path,
                reason: "subckt_not_found"
            ))
            return
        }
        if stack.contains(target.subcktName) {
            throw parseError("Cyclic DSPF subckt hierarchy through \(target.subcktName) at line \(instance.lineNumber)")
        }
        guard target.connections.count == child.ports.count else {
            throw parseError(
                "Instance \(instance.id) binds \(target.connections.count) ports, but subckt \(target.subcktName) declares \(child.ports.count) ports at line \(instance.lineNumber)"
            )
        }

        let resolvedBindings = Self.childBindings(
            child: child,
            target: target,
            bindings: bindings,
            path: path,
            groundNodes: groundNodes
        )
        flattened.nodeInstancePaths.merge(resolvedBindings.nodeInstancePaths) { current, _ in current }
        let instanceParams = Self.instanceParameters(from: target.parameterTokens)
        let childParams = localParams
            .merging(child.params) { _, childValue in childValue }
            .merging(instanceParams) { _, instanceValue in instanceValue }
        let childPath = path + [instance.id]
        let childFlattened = try flatten(
            content: child,
            document: document,
            inheritedParams: childParams,
            path: childPath,
            bindings: resolvedBindings.bindings,
            stack: stack + [target.subcktName]
        )
        Self.mergeChildFlattened(
            childFlattened,
            childPath: childPath,
            parentSubckt: parentSubckt,
            childSubckt: target.subcktName,
            portBindings: resolvedBindings.portBindings,
            instanceLineNumber: instance.lineNumber,
            into: &flattened
        )
    }

    private func unresolvedInstance(
        _ instance: DSPFInstanceRecord,
        parentSubckt: String?,
        path: [String],
        reason: String
    ) -> DSPFUnresolvedInstance {
        DSPFUnresolvedInstance(
            id: instance.id,
            instancePath: Self.scopedElementID(instance.id, path: path),
            parentSubckt: parentSubckt ?? "__global__",
            reason: reason,
            lineNumber: instance.lineNumber,
            sourceLine: instance.sourceLine
        )
    }

    private static func childBindings(
        child: DSPFContent,
        target: DSPFInstanceTarget,
        bindings: [String: String],
        path: [String],
        groundNodes: Set<String>
    ) -> DSPFChildBindingResolution {
        var nodeInstancePaths: [String: InstancePath] = [:]
        var childBindings: [String: String] = [:]
        for (port, connection) in zip(child.ports, target.connections) {
            childBindings[port] = mappedNode(
                connection,
                bindings: bindings,
                path: path,
                groundNodes: groundNodes,
                nodeInstancePaths: &nodeInstancePaths
            )
        }
        let portBindings = childBindings.sorted { $0.key < $1.key }.map {
            DSPFPortBinding(port: $0.key, node: $0.value)
        }
        return DSPFChildBindingResolution(
            bindings: childBindings,
            nodeInstancePaths: nodeInstancePaths,
            portBindings: portBindings
        )
    }

    private static func mergeChildFlattened(
        _ childFlattened: DSPFFlattenedContent,
        childPath: [String],
        parentSubckt: String?,
        childSubckt: String,
        portBindings: [DSPFPortBinding],
        instanceLineNumber: Int,
        into flattened: inout DSPFFlattenedContent
    ) {
        flattened.elements.append(contentsOf: childFlattened.elements)
        flattened.annotations.append(contentsOf: childFlattened.annotations)
        flattened.nodeInstancePaths.merge(childFlattened.nodeInstancePaths) { current, _ in current }
        flattened.expansions.append(DSPFHierarchyExpansion(
            instancePath: childPath.joined(separator: "/"),
            parentSubckt: parentSubckt ?? "__global__",
            childSubckt: childSubckt,
            portBindings: portBindings,
            elementCount: childFlattened.elements.count,
            lineNumber: instanceLineNumber
        ))
        flattened.expansions.append(contentsOf: childFlattened.expansions)
        flattened.unresolvedInstances.append(contentsOf: childFlattened.unresolvedInstances)
    }

    private func metadataJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw PEXError.parseFailed(
                cornerID: cornerID,
                message: "Failed to encode DSPF metadata",
                underlying: error
            )
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw parseError("Failed to encode DSPF metadata as UTF-8")
        }
        return string
    }

    private func parseError(_ message: String) -> PEXError {
        PEXError.parseFailed(cornerID: cornerID, message: message)
    }

    private static func logicalLines(from source: String) -> [String] {
        var lines: [String] = []
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("+") {
                let continuation = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if let previous = lines.popLast() {
                    lines.append("\(previous) \(continuation)")
                } else {
                    lines.append(continuation)
                }
                continue
            }

            lines.append(trimmed)
        }
        return lines
    }

    private static func directiveName(from line: String) -> String? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first, first.hasPrefix(".") else { return nil }
        return first.lowercased()
    }

    private static func subckt(from line: String, lineNumber: Int, cornerID: PEXCornerID) throws -> DSPFContent {
        let tokens = componentTokens(from: line)
        guard tokens.count >= 2 else {
            throw PEXError.parseFailed(cornerID: cornerID, message: "Malformed .SUBCKT at line \(lineNumber): \(line)")
        }
        return DSPFContent(
            name: tokens[1],
            ports: Array(tokens.dropFirst(2)),
            elements: [],
            instances: [],
            annotations: [],
            params: [:],
            startsAtLine: lineNumber,
            endsAtLine: nil
        )
    }

    private static func endSubcktName(from line: String) -> String? {
        let tokens = componentTokens(from: line)
        guard tokens.count >= 2 else { return nil }
        return tokens[1]
    }

    private static func parameters(from line: String, cornerID: PEXCornerID) throws -> [String: String] {
        let normalized = line.replacingOccurrences(of: "=", with: " = ")
        let rawTokens = componentTokens(from: normalized)
        let tokens = Array(rawTokens.dropFirst())
        var params: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let name = tokens[index]
            guard index + 2 < tokens.count, tokens[index + 1] == "=" else {
                throw PEXError.parseFailed(cornerID: cornerID, message: "Malformed .PARAM assignment in line: \(line)")
            }
            let value = tokens[index + 2]
            params[parameterKey(from: name)] = strippedParameterValue(value)
            index += 3
        }
        return params
    }

    private static func element(
        from line: String,
        subcktName: String?,
        lineNumber: Int,
        cornerID: PEXCornerID
    ) throws -> DSPFElementRecord? {
        let tokens = componentTokens(from: line)
        guard let firstToken = tokens.first, let first = firstToken.first else { return nil }
        let kind = first.lowercased()
        guard kind == "c" || kind == "r" || kind == "l" else { return nil }
        guard tokens.count >= 4 else {
            throw PEXError.parseFailed(
                cornerID: cornerID,
                message: "Truncated DSPF \(kind) element at line \(lineNumber): \(line)"
            )
        }
        let elementKind: DSPFElementKind
        switch kind {
        case "c":
            elementKind = .capacitor
        case "r":
            elementKind = .resistor
        default:
            elementKind = .inductor
        }
        return DSPFElementRecord(
            id: tokens[0],
            kind: elementKind,
            nodeA: tokens[1],
            nodeB: tokens[2],
            valueToken: tokens[3],
            subcktName: subcktName,
            sourceLine: line,
            lineNumber: lineNumber
        )
    }

    private static func instance(from line: String, subcktName: String?, lineNumber: Int) -> DSPFInstanceRecord? {
        let tokens = componentTokens(from: line)
        guard tokens.count >= 3 else { return nil }
        guard let first = tokens[0].first, first.lowercased() == "x" else { return nil }
        return DSPFInstanceRecord(
            id: tokens[0],
            rawTokens: Array(tokens.dropFirst()),
            subcktName: subcktName,
            sourceLine: line,
            lineNumber: lineNumber
        )
    }

    private static func annotation(from line: String, subcktName: String?, lineNumber: Int) -> DSPFAnnotationRecord? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let markerIndex = tokens.firstIndex(where: { $0.hasPrefix("*|") }) else { return nil }
        let annotationTokens = Array(tokens[markerIndex...])
        guard let marker = annotationTokens.first else { return nil }
        let kind = String(marker.dropFirst(2)).uppercased()
        guard ["P", "I", "S"].contains(kind) else { return nil }
        let target = annotationTokens.dropFirst().first
        return DSPFAnnotationRecord(
            kind: kind,
            subckt: subcktName,
            target: target,
            tokens: annotationTokens,
            coordinate: coordinate(from: Array(annotationTokens.dropFirst(2))),
            lineNumber: lineNumber
        )
    }

    private static func componentTokens(from line: String) -> [String] {
        guard let first = line.first else { return [] }
        if first == "*" {
            return []
        }

        var tokens: [String] = []
        for token in line.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("*|") || token.hasPrefix("$") {
                break
            }
            tokens.append(token)
        }
        return tokens
    }

    private static func nodeAnnotations(_ annotations: [DSPFAnnotationRecord], nodeOrder: [String]) -> [String: DSPFNodeAnnotation] {
        var annotationsByNode: [String: DSPFNodeAnnotation] = [:]
        let nodeSet = Set(nodeOrder)
        let pins = annotations.filter { $0.kind == "P" }
        let subnodes = annotations.filter { $0.kind == "S" }
        let instances = annotations.filter { $0.kind == "I" }
        let instanceNames = instances.compactMap(\.target)

        for annotation in subnodes {
            guard let target = annotation.target, nodeSet.contains(target) else { continue }
            annotationsByNode[target] = DSPFNodeAnnotation(
                kind: .internal,
                instancePath: instancePath(for: target, instanceNames: instanceNames),
                coordinate: annotation.coordinate?.point
            )
        }

        var assignedPinNodes: Set<String> = []
        for annotation in pins {
            guard let target = annotation.target else { continue }
            let nodeName: String?
            if nodeSet.contains(target) {
                nodeName = target
            } else {
                nodeName = nodeOrder.first { !assignedPinNodes.contains($0) && baseNetName($0) == target }
            }
            guard let nodeName else { continue }
            assignedPinNodes.insert(nodeName)
            let existing = annotationsByNode[nodeName]
            annotationsByNode[nodeName] = DSPFNodeAnnotation(
                kind: .pin,
                instancePath: existing?.instancePath ?? instancePath(for: nodeName, instanceNames: instanceNames),
                coordinate: existing?.coordinate ?? annotation.coordinate?.point
            )
        }

        for node in nodeOrder where annotationsByNode[node] == nil {
            if let instancePath = instancePath(for: node, instanceNames: instanceNames) {
                annotationsByNode[node] = DSPFNodeAnnotation(kind: .internal, instancePath: instancePath, coordinate: nil)
            }
        }

        return annotationsByNode
    }

    private static func instancePath(for nodeName: String, instanceNames: [String]) -> InstancePath? {
        for instanceName in instanceNames.sorted(by: { $0.count > $1.count }) {
            if nodeName == instanceName || nodeName.hasPrefix("\(instanceName)/") || nodeName.hasPrefix("\(instanceName).") {
                return InstancePath(instanceName)
            }
        }
        return nil
    }

    private static func resolveTarget(for instance: DSPFInstanceRecord, in document: DSPFDocument) -> DSPFInstanceTarget? {
        for index in stride(from: instance.rawTokens.count - 1, through: 0, by: -1) {
            let token = instance.rawTokens[index]
            guard document.subckt(named: token) != nil else { continue }
            return DSPFInstanceTarget(
                subcktName: token,
                connections: Array(instance.rawTokens[..<index]),
                parameterTokens: Array(instance.rawTokens.dropFirst(index + 1))
            )
        }
        return nil
    }

    private static func instanceParameters(from tokens: [String]) -> [String: String] {
        var params: [String: String] = [:]
        for token in tokens {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            params[parameterKey(from: parts[0])] = strippedParameterValue(parts[1])
        }
        return params
    }

    private static func mappedNode(
        _ node: String,
        bindings: [String: String],
        path: [String],
        groundNodes: Set<String>,
        nodeInstancePaths: inout [String: InstancePath]
    ) -> String {
        if groundNodes.contains(node.lowercased()) {
            return node
        }
        if let binding = bindings[node] {
            return binding
        }

        let baseName = baseNetName(node)
        if let binding = bindings[baseName], baseName != node {
            let suffix = node.dropFirst(baseName.count)
            return "\(binding)\(suffix)"
        }

        guard !path.isEmpty else {
            return node
        }

        let mapped = "\(path.joined(separator: "/"))/\(node)"
        nodeInstancePaths[mapped] = InstancePath(path.joined(separator: "/"))
        return mapped
    }

    private static func mappedAnnotation(
        _ annotation: DSPFAnnotationRecord,
        bindings: [String: String],
        path: [String],
        groundNodes: Set<String>
    ) -> DSPFAnnotationRecord {
        guard let target = annotation.target else { return annotation }
        var ignoredInstancePaths: [String: InstancePath] = [:]
        let mappedTarget: String
        if annotation.kind == "I", !path.isEmpty {
            mappedTarget = "\(path.joined(separator: "/"))/\(target)"
        } else {
            mappedTarget = mappedNode(
                target,
                bindings: bindings,
                path: path,
                groundNodes: groundNodes,
                nodeInstancePaths: &ignoredInstancePaths
            )
        }

        var updatedTokens = annotation.tokens
        if updatedTokens.count > 1 {
            updatedTokens[1] = mappedTarget
        }
        return DSPFAnnotationRecord(
            kind: annotation.kind,
            subckt: annotation.subckt,
            target: mappedTarget,
            tokens: updatedTokens,
            coordinate: annotation.coordinate,
            lineNumber: annotation.lineNumber
        )
    }

    private static func scopedElementID(_ elementID: String, path: [String]) -> String {
        guard !path.isEmpty else { return elementID }
        return "\(path.joined(separator: "/"))/\(elementID)"
    }

    private static func coordinate(from tokens: [String]) -> DSPFCoordinate? {
        guard tokens.count >= 2 else { return nil }
        for index in 0..<(tokens.count - 1) {
            guard let x = Double(tokens[index]), let y = Double(tokens[index + 1]) else { continue }
            return DSPFCoordinate(x: x, y: y)
        }
        return nil
    }

    private static func parameterKey(from token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{"), value.hasSuffix("}"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value.lowercased()
    }

    private static func strippedParameterValue(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("{"), value.hasSuffix("}"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func baseNetName(_ node: String) -> String {
        let separators: [Character] = [":"]
        for separator in separators {
            if let index = node.firstIndex(of: separator), index > node.startIndex {
                return String(node[..<index])
            }
        }
        return node
    }
}

private struct DSPFDocument {
    var global: DSPFContent
    var subckts: [DSPFContent]

    var allAnnotations: [DSPFAnnotationRecord] {
        (global.annotations + subckts.flatMap(\.annotations)).sorted { lhs, rhs in
            lhs.lineNumber < rhs.lineNumber
        }
    }

    func subckt(named name: String) -> DSPFContent? {
        subckts.first { ($0.name ?? "").caseInsensitiveCompare(name) == .orderedSame }
    }
}

private struct DSPFContent {
    var name: String?
    var ports: [String]
    var elements: [DSPFElementRecord]
    var instances: [DSPFInstanceRecord]
    var annotations: [DSPFAnnotationRecord]
    var params: [String: String]
    var startsAtLine: Int?
    var endsAtLine: Int?
}

private struct DSPFContentSelection {
    var content: DSPFContent
    var topSubcktName: String
    var reason: String
}

private enum DSPFElementKind {
    case capacitor
    case resistor
    case inductor
}

private struct DSPFElementRecord {
    var id: String
    var kind: DSPFElementKind
    var nodeA: String
    var nodeB: String
    var valueToken: String
    var subcktName: String?
    var sourceLine: String
    var lineNumber: Int
}

private struct DSPFInstanceRecord {
    var id: String
    var rawTokens: [String]
    var subcktName: String?
    var sourceLine: String
    var lineNumber: Int
}

private struct DSPFInstanceTarget {
    var subcktName: String
    var connections: [String]
    var parameterTokens: [String]
}

private struct DSPFFlattenedContent {
    var elements: [DSPFFlattenedElementRecord]
    var annotations: [DSPFAnnotationRecord]
    var nodeInstancePaths: [String: InstancePath]
    var expansions: [DSPFHierarchyExpansion]
    var unresolvedInstances: [DSPFUnresolvedInstance]
}

private struct DSPFChildBindingResolution {
    var bindings: [String: String]
    var nodeInstancePaths: [String: InstancePath]
    var portBindings: [DSPFPortBinding]
}

private struct DSPFFlattenedElementRecord {
    var id: String
    var kind: DSPFElementKind
    var nodeA: String
    var nodeB: String
    var valueToken: String
    var params: [String: String]
    var sourceSubcktName: String?
    var sourceLine: String
    var lineNumber: Int
}

private struct DSPFCoordinate: Sendable, Codable, Hashable {
    var x: Double
    var y: Double

    var point: Point2D {
        Point2D(x: x, y: y)
    }
}

private struct DSPFAnnotationRecord: Sendable, Codable, Hashable {
    var kind: String
    var subckt: String?
    var target: String?
    var tokens: [String]
    var coordinate: DSPFCoordinate?
    var lineNumber: Int
}

private struct DSPFNodeAnnotation {
    var kind: NodeKind
    var instancePath: InstancePath?
    var coordinate: Point2D?
}

private struct DSPFSubcktMetadata: Sendable, Codable, Hashable {
    var name: String
    var ports: [String]
    var elementCount: Int
    var instanceCount: Int
    var annotationCount: Int
    var parameterNames: [String]
    var startsAtLine: Int?
    var endsAtLine: Int?

    init(content: DSPFContent) {
        self.name = content.name ?? "__global__"
        self.ports = content.ports
        self.elementCount = content.elements.count
        self.instanceCount = content.instances.count
        self.annotationCount = content.annotations.count
        self.parameterNames = content.params.keys.sorted()
        self.startsAtLine = content.startsAtLine
        self.endsAtLine = content.endsAtLine
    }
}

private struct DSPFParameterMetadata: Sendable, Codable, Hashable {
    var name: String
    var value: String
}

private struct DSPFElementRename: Sendable, Codable, Hashable {
    var sourceID: String
    var irID: String
    var occurrence: Int
    var subckt: String?
}

private struct DSPFHierarchyExpansion: Sendable, Codable, Hashable {
    var instancePath: String
    var parentSubckt: String
    var childSubckt: String
    var portBindings: [DSPFPortBinding]
    var elementCount: Int
    var lineNumber: Int
}

private struct DSPFPortBinding: Sendable, Codable, Hashable {
    var port: String
    var node: String
}

private struct DSPFUnresolvedInstance: Sendable, Codable, Hashable {
    var id: String
    var instancePath: String
    var parentSubckt: String
    var reason: String
    var lineNumber: Int
    var sourceLine: String
}

private struct DSPFElementIDResolver {
    private var sourceOccurrences: [String: Int] = [:]
    private var usedIDs: Set<String> = []
    private(set) var renames: [DSPFElementRename] = []

    mutating func resolve(sourceID: String, subcktName: String?) -> String {
        let occurrence = (sourceOccurrences[sourceID] ?? 0) + 1
        sourceOccurrences[sourceID] = occurrence

        var candidate = occurrence == 1 ? sourceID : "\(sourceID)#\(occurrence)"
        var suffix = 1
        while usedIDs.contains(candidate) {
            candidate = "\(sourceID)#\(occurrence)#\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)

        if candidate != sourceID {
            renames.append(DSPFElementRename(sourceID: sourceID, irID: candidate, occurrence: occurrence, subckt: subcktName))
        }
        return candidate
    }
}
