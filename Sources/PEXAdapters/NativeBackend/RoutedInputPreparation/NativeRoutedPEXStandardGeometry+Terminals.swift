import DEF
import LEF
import PEXCore

extension NativeRoutedPEXStandardGeometry {
    mutating func prepareTerminals(isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        for net in source.nets { try appendTerminals(net: NetName(net.name), use: net.use, connections: net.connections, isCancelled: isCancelled) }
        for net in source.specialNets { try appendTerminals(net: NetName(net.name), use: net.use, connections: net.connections, isCancelled: isCancelled) }
    }

    mutating func appendTerminals(net: NetName, use: DEFSpecialNet.NetUse?, connections: [DEFConnection],
                                 isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        let reference = use == .power || use == .ground
        for connection in connections {
            try budget.visit(isCancelled: isCancelled)
            var contacts: [Input.Landing] = []
            let path: InstancePath?
            let name: String
            let facts: [Input.SourceFact]
            if connection.componentName == "PIN" {
                guard let port = ports[connection.pinName], port.netName == net.value,
                      (port.use == .power || port.use == .ground) == reference else {
                    throw .sourceMismatch("Source top port net/use disagrees with its DEF connection")
                }
                path = nil; name = reference ? "" : try terminalName(connection); facts = [defFact]
                if !reference {
                    for layer in port.layerRects {
                        try checkUsedLayer(layer.layerName, isCancelled: isCancelled)
                        for r in layer.rects {
                            try budget.visit(isCancelled: isCancelled); try budget.record()
                            let local = Input.Rect(minX: Int64(r.x1), minY: Int64(r.y1), maxX: Int64(r.x2), maxY: Int64(r.y2))
                            let rect = try posed(local, orientation: port.orientation, x: Int64(port.x), y: Int64(port.y))
                            contacts.append(.init(layerName: layer.layerName, rect: rect, sourceFacts: facts))
                        }
                    }
                }
            } else {
                guard let component = components[connection.componentName], let master = masters[component.macro] else {
                    throw .sourceMismatch("DEF connection references a missing placed cell")
                }
                var found: LEFPinDef?
                for pin in master.definition.pins {
                    try budget.visit(isCancelled: isCancelled)
                    if pin.name == connection.pinName {
                        guard found == nil else { throw .sourceMismatch("Duplicate source master pin") }; found = pin
                    }
                }
                guard let pin = found, (pin.use == .power || pin.use == .ground) == reference else {
                    throw .sourceMismatch("Source cell pin/use disagrees with its DEF connection")
                }
                path = InstancePath(component.name); name = reference ? "" : try terminalName(connection)
                facts = [defFact, master.source.fact]
                if !reference {
                    // FIXME(INCOMPLETE_IMPLEMENTATION): The admitted placement frame is source ORIGIN zero.
                    // Public preparation must refuse nonzero origins until exact standard origin/pose behavior is represented and tested.
                    guard master.definition.origin == nil || master.definition.origin == LEFPoint(x: 0, y: 0),
                          let widthValue = master.definition.width, let heightValue = master.definition.height else {
                        throw .unsupportedSource("A zero-origin master with exact SIZE is required")
                    }
                    let width = try grid(widthValue), height = try grid(heightValue)
                    guard width > 0, height > 0 else { throw .sourceMismatch("Empty source master SIZE") }
                    let offset: (Int64, Int64)
                    switch component.orientation {
                    case .n, .fw: offset = (0, 0)
                    case .s: offset = (width, height)
                    case .e: offset = (0, width)
                    case .w: offset = (height, 0)
                    case .fn: offset = (width, 0)
                    case .fs: offset = (0, height)
                    case .fe: offset = (height, width)
                    }
                    let x = try add(Int64(component.x), offset.0), y = try add(Int64(component.y), offset.1)
                    for port in pin.ports {
                        try budget.visit(isCancelled: isCancelled)
                        // FIXME(INCOMPLETE_IMPLEMENTATION): Polygon/path/named-via pin surfaces are not projected by this routed host.
                        // Public preparation refuses them until exact Native contact geometry can retain every source surface.
                        guard port.polygons.isEmpty, port.paths.isEmpty, port.vias.isEmpty else {
                            throw .unsupportedSource("Only explicit rectangular source pin contacts are admitted")
                        }
                        try checkUsedLayer(port.layerName, isCancelled: isCancelled)
                        for r in port.rects {
                            try budget.visit(isCancelled: isCancelled); try budget.record()
                            contacts.append(.init(layerName: port.layerName,
                                rect: try posed(lefRect(r), orientation: component.orientation, x: x, y: y), sourceFacts: facts))
                        }
                    }
                }
            }
            guard !reference else { continue }
            guard !contacts.isEmpty else { throw .sourceMismatch("Source terminal has no actual contact rectangle") }
            let ref = NodeRef(netName: net, nodeName: NodeName(name))
            guard !connectedTerminals.contains(ref), let contact = try contactPoint(net: net, contacts: contacts, isCancelled: isCancelled) else {
                throw .sourceMismatch("Source terminal has no actual wire-centerline or via-endpoint incidence")
            }
            try budget.record(3)
            let value = Input.Node(ref: ref, layerName: contact.layer, x: contact.x, y: contact.y, sourceFacts: facts)
            nodes.append(value); nodePositions[ref] = value; connectedTerminals.insert(ref)
            terminals.append(.init(ref: ref, instancePath: path, contacts: contacts, sourceFacts: facts))
        }
    }

    mutating func contactPoint(net: NetName, contacts: [Input.Landing], isCancelled: () -> Bool)
        throws(NativeRoutedPEXPreparationError) -> (layer: String, x: Int64, y: Int64)? {
        for contact in contacts {
            for wire in wires {
                try budget.visit(isCancelled: isCancelled)
                guard wire.netName == net, wire.layerName == contact.layerName,
                      min(wire.rect.maxX, contact.rect.maxX) > max(wire.rect.minX, contact.rect.minX),
                      min(wire.rect.maxY, contact.rect.maxY) > max(wire.rect.minY, contact.rect.minY),
                      let a = nodePositions[wire.sourceNode], let b = nodePositions[wire.targetNode] else { continue }
                for endpoint in [a, b] {
                    try budget.visit(isCancelled: isCancelled)
                    if contact.rect.minX <= endpoint.x, endpoint.x <= contact.rect.maxX,
                       contact.rect.minY <= endpoint.y, endpoint.y <= contact.rect.maxY {
                        return (contact.layerName, endpoint.x, endpoint.y)
                    }
                }
                if wire.axis == .horizontal, contact.rect.minY <= a.y, a.y <= contact.rect.maxY {
                    let low = max(min(a.x, b.x), contact.rect.minX), high = min(max(a.x, b.x), contact.rect.maxX)
                    if low <= high { return (contact.layerName, low, a.y) }
                } else if wire.axis == .vertical, contact.rect.minX <= a.x, a.x <= contact.rect.maxX {
                    let low = max(min(a.y, b.y), contact.rect.minY), high = min(max(a.y, b.y), contact.rect.maxY)
                    if low <= high { return (contact.layerName, a.x, low) }
                }
            }
            for via in vias {
                try budget.visit(isCancelled: isCancelled)
                guard via.netName == net else { continue }
                for ref in [via.sourceNode, via.targetNode] {
                    try budget.visit(isCancelled: isCancelled)
                    guard let node = nodePositions[ref], node.layerName == contact.layerName,
                          contact.rect.minX <= node.x, node.x <= contact.rect.maxX,
                          contact.rect.minY <= node.y, node.y <= contact.rect.maxY else { continue }
                    for landing in via.landings {
                        try budget.visit(isCancelled: isCancelled)
                        if landing.layerName == contact.layerName,
                           min(landing.rect.maxX, contact.rect.maxX) > max(landing.rect.minX, contact.rect.minX),
                           min(landing.rect.maxY, contact.rect.maxY) > max(landing.rect.minY, contact.rect.minY) {
                            return (contact.layerName, node.x, node.y)
                        }
                    }
                }
            }
        }
        return nil
    }
}
