import DEF
import LEF
import PEXCore

extension NativeRoutedPEXStandardGeometry {
    mutating func prepareRouting(isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        // FIXME(INCOMPLETE_IMPLEMENTATION): Floating DEF FILL has no source net/role in this admitted routed profile.
        // Public preparation refuses it until exact floating/reference conductor semantics are represented in Native input.
        guard source.fills.isEmpty else { throw .unsupportedSource("DEF FILL conductor role is not represented") }
        var names = Set<NetName>()
        for net in source.nets {
            try appendNet(net.name, use: net.use, names: &names, isCancelled: isCancelled)
            for route in net.routing {
                try budget.visit(isCancelled: isCancelled)
                guard !route.taper, route.style == nil, let layer = layerByName[route.layerName] else {
                    throw .unsupportedSource("Regular routing requires a selected layer without taper/style")
                }
                try checkUsedLayer(route.layerName, isCancelled: isCancelled)
                guard route.pointExtensions.isEmpty || route.pointExtensions.count == route.points.count else {
                    throw .sourceMismatch("Per-point extension inventory differs from route points")
                }
                for index in 1..<max(1, route.points.count) {
                    let a = route.points[index - 1], b = route.points[index]
                    let start = route.pointExtensions.isEmpty ? nil : route.pointExtensions[index - 1]
                    let end = route.pointExtensions.isEmpty ? nil : route.pointExtensions[index]
                    try appendWire(net: NetName(net.name), layer: route.layerName,
                        ax: Int64(a.x), ay: Int64(a.y), bx: Int64(b.x), by: Int64(b.y),
                        width: layer.defaultWidthDatabaseUnits, startExtension: start.map(Int64.init), endExtension: end.map(Int64.init),
                        isCancelled: isCancelled)
                }
                if let name = route.viaName {
                    guard let point = route.points.last else { throw .sourceMismatch("Via route lacks its actual origin") }
                    try appendVia(net: NetName(net.name), name: name, orientation: route.viaOrientation,
                        x: Int64(point.x), y: Int64(point.y), isCancelled: isCancelled)
                } else if route.points.count < 2 { throw .sourceMismatch("Route has no conductor segment or via") }
            }
        }
        for net in source.specialNets {
            try appendNet(net.name, use: net.use, names: &names, isCancelled: isCancelled)
            for route in net.routing {
                try budget.visit(isCancelled: isCancelled)
                guard route.status != .shield else { throw .unsupportedSource("Unrepresented SHIELD relation or absent special-net WIDTH") }
                try checkUsedLayer(route.layerName, isCancelled: isCancelled)
                var previous: (Int64, Int64, Int64?)?
                for point in route.points {
                    try budget.visit(isCancelled: isCancelled)
                    guard let x = point.x.map(Int64.init) ?? previous?.0,
                          let y = point.y.map(Int64.init) ?? previous?.1 else { throw .sourceMismatch("Unresolved first special-route coordinate") }
                    let ext = point.ext.map(Int64.init)
                    if let a = previous, a.0 != x || a.1 != y {
                        try appendWire(net: NetName(net.name), layer: route.layerName, ax: a.0, ay: a.1, bx: x, by: y,
                            width: Int64(route.width), startExtension: a.2, endExtension: ext, isCancelled: isCancelled)
                    }
                    if let name = point.viaName {
                        try appendVia(net: NetName(net.name), name: name, orientation: point.viaOrientation ?? .n,
                            x: x, y: y, isCancelled: isCancelled)
                    }
                    previous = (x, y, ext)
                }
            }
        }
    }

    mutating func appendNet(_ name: String, use: DEFSpecialNet.NetUse?, names: inout Set<NetName>,
                            isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        try budget.visit(isCancelled: isCancelled); try budget.record(2); try budget.string(name)
        let net = NetName(name)
        guard !name.isEmpty, names.insert(net).inserted else { throw .sourceMismatch("Duplicate or empty DEF net") }
        nets.append(.init(name: net, role: use == .power || use == .ground ? .reference : .signal, sourceFacts: [defFact]))
    }

    mutating func appendWire(net: NetName, layer: String, ax: Int64, ay: Int64, bx: Int64, by: Int64,
                             width: Int64, startExtension: Int64?, endExtension: Int64?,
                             isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        try budget.visit(isCancelled: isCancelled)
        guard layerByName[layer] != nil, width > 0, width.isMultiple(of: 2),
              (ax == bx) != (ay == by), (startExtension ?? 0) >= 0, (endExtension ?? 0) >= 0 else {
            throw .unsupportedSource("Wire requires a nonzero Manhattan segment and exact even-width DBU extensions")
        }
        let start = startExtension ?? width / 2, end = endExtension ?? width / 2
        let horizontal = ay == by
        let ascending = horizontal ? ax < bx : ay < by
        let lowExtension = ascending ? start : end, highExtension = ascending ? end : start
        let rect: Input.Rect
        if horizontal {
            rect = try .init(minX: add(min(ax, bx), -lowExtension), minY: add(ay, -width / 2),
                             maxX: add(max(ax, bx), highExtension), maxY: add(ay, width / 2))
        } else {
            rect = try .init(minX: add(ax, -width / 2), minY: add(min(ay, by), -lowExtension),
                             maxX: add(ax, width / 2), maxY: add(max(ay, by), highExtension))
        }
        let facts = [defFact, routeTechnology.fact, technology.fact]
        let a = try node(net: net, layer: layer, x: ax, y: ay, facts: facts, isCancelled: isCancelled)
        let b = try node(net: net, layer: layer, x: bx, y: by, facts: facts, isCancelled: isCancelled)
        let ordinal = try ordinal()
        try budget.record(); try budget.reserveGeneratedName(prefix: "DEF.wire.", ordinal: ordinal)
        let id = "DEF.wire.\(ordinal)"
        wires.append(.init(sourceID: id, sourceOrdinal: ordinal, netName: net, layerName: layer,
                           axis: horizontal ? .horizontal : .vertical, rect: rect, sourceNode: a, targetNode: b, sourceFacts: facts))
    }

    mutating func appendVia(net: NetName, name: String, orientation: DEFOrientation, x: Int64, y: Int64,
                            isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) {
        try budget.visit(isCancelled: isCancelled)
        let actual = try actualViaShapes(name: name, isCancelled: isCancelled)
        for corner in cornerTechnologies {
            let original = try lefViaShapes(name: name, document: corner.document, isCancelled: isCancelled)
            try budget.record(original.count); try budget.record(actual.count)
            guard Set(original).count == original.count, Set(actual).count == actual.count, Set(original) == Set(actual) else { throw .sourceMismatch("Actual via cut/landing rectangles differ from the full original source") }
        }
        var cuts: [Input.Cut] = [], landings: [Input.Landing] = []
        var routingNames = Set<String>()
        let facts = [defFact, routeTechnology.fact, technology.fact]
        for shape in actual {
            try budget.visit(isCancelled: isCancelled); try budget.record()
            try checkUsedLayer(shape.layer, isCancelled: isCancelled)
            guard let definition = technologyLayers[shape.layer] else { throw .sourceMismatch("Missing source via layer") }
            let rect = try posed(shape.rect, orientation: orientation, x: x, y: y)
            if definition.type == .routing {
                guard layerByName[shape.layer] != nil else { throw .unsupportedSource("Via landing is outside selected routing layers") }
                landings.append(.init(layerName: shape.layer, rect: rect, sourceFacts: facts)); routingNames.insert(shape.layer)
            } else if definition.type == .cut {
                guard let resistance = definition.cutResistanceOhms, resistance.isFinite, resistance > 0 else {
                    throw .sourceMismatch("Each source via cut requires its own explicit LEF cut resistance")
                }
                cuts.append(.init(layerName: shape.layer, rect: rect, resistanceOhms: resistance, sourceFacts: facts))
            } else { throw .unsupportedSource("Via contains an unrepresented nonrouting/noncut layer") }
        }
        guard routingNames.count == 2, !cuts.isEmpty else { throw .unsupportedSource("Via requires exactly two routing landings and actual cuts") }
        try budget.record(2)
        let ordered = layers.filter { routingNames.contains($0.name) }
        guard ordered.count == 2 else { throw .sourceMismatch("Via routing-layer inventory differs from its landings") }
        let first = ordered[0], second = ordered[1]
        guard second.level == first.level + 1 else {
            throw .unsupportedSource("Via must join adjacent selected routing layers")
        }
        let a = try node(net: net, layer: first.name, x: x, y: y, facts: facts, isCancelled: isCancelled)
        let b = try node(net: net, layer: second.name, x: x, y: y, facts: facts, isCancelled: isCancelled)
        let ordinal = try ordinal()
        try budget.record(); try budget.reserveGeneratedName(prefix: "DEF.via.", ordinal: ordinal)
        let id = "DEF.via.\(ordinal)"
        vias.append(.init(sourceID: id, sourceOrdinal: ordinal, netName: net, sourceNode: a, targetNode: b,
                          cuts: cuts, landings: landings, sourceFacts: facts))
    }

    mutating func actualViaShapes(name: String, isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) -> [ViaShape] {
        var found: DEFViaDef?
        for candidate in source.viaDefs {
            try budget.visit(isCancelled: isCancelled)
            if candidate.name == name {
                guard found == nil else { throw .sourceMismatch("Duplicate DEF via definition") }; found = candidate
            }
        }
        guard let definition = found else { return try lefViaShapes(name: name, document: routeTechnology.document, isCancelled: isCancelled) }
        // FIXME(INCOMPLETE_IMPLEMENTATION): Generated-only DEF vias need an owned exact rule materializer.
        // Public preparation cannot replace generated geometry with a bounding box or a same-name fixed via.
        guard definition.viaRule == nil, !definition.layers.isEmpty else { throw .unsupportedSource("Generated DEF via geometry is not materialized") }
        var result: [ViaShape] = []
        for layer in definition.layers {
            for r in layer.rects {
                try budget.visit(isCancelled: isCancelled); try budget.record()
                guard r.x1 < r.x2, r.y1 < r.y2 else { throw .sourceMismatch("Empty source DEF via rectangle") }
                result.append(.init(layer: layer.layerName, rect: .init(minX: Int64(r.x1), minY: Int64(r.y1), maxX: Int64(r.x2), maxY: Int64(r.y2))))
            }
        }
        return result
    }
    mutating func lefViaShapes(name: String, document: LEFDocument,
                               isCancelled: () -> Bool) throws(NativeRoutedPEXPreparationError) -> [ViaShape] {
        var found: LEFViaDef?
        for candidate in document.vias {
            try budget.visit(isCancelled: isCancelled)
            if candidate.name == name { guard found == nil else { throw .sourceMismatch("Duplicate LEF via definition") }; found = candidate }
        }
        // FIXME(INCOMPLETE_IMPLEMENTATION): This public routed profile retains fixed explicit source via rectangles.
        // Generated-only/aliased rules require exact owned materialization before preparation can report success.
        guard let definition = found, !definition.isGenerate, definition.viaRule == nil, !definition.layers.isEmpty else {
            throw .unsupportedSource("Missing fixed original source via geometry: \(name)")
        }
        var result: [ViaShape] = []
        for layer in definition.layers {
            guard layer.polygons.isEmpty else { throw .unsupportedSource("Polygon via geometry is outside this routed profile") }
            for rect in layer.rects {
                try budget.visit(isCancelled: isCancelled); try budget.record()
                result.append(.init(layer: layer.layerName, rect: try lefRect(rect)))
            }
        }
        return result
    }
}
