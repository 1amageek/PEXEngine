import Foundation
import CryptoKit
import Darwin
import Testing
import CircuiteFoundation
import PEXCore
import PEXNative

// Verification owner: external DC network algebra only, never process/field accuracy.
// Freeze before measurement: relative error <= 1e-8 for ngspice versus an independent
// matrix-free Kirchhoff solve and for analytical rectangles/parallel cuts. L refinement
// records decreasing successive differences, without assigning a physical error bound.
// Every public resistor is preserved and terminals bind directly to their contact-region
// assignments; the exporter adds no point contact, short, zero-ohm resistor, or fallback.
// Opt in with PEX_SHEET_NGSPICE_REQUIRED=1 and explicit absolute executable/evidence paths.
// An unselected suite is skipped (not qualification success); missing required tools fail.
// Output materialization admits regular-file size and each chunk against the fixed 1 MiB
// ceiling. Evidence/executable hashes stream fixed chunks; oversized raw files remain on
// disk with bounded failure metadata and are never re-materialized by failure handling.
@Suite("External sheet resistance DC network algebra",
       .enabled(if: ProcessInfo.processInfo.environment["PEX_SHEET_NGSPICE_REQUIRED"] == "1",
                "Not qualified: select PEX_SHEET_NGSPICE_REQUIRED=1 with explicit executable and evidence root."),
       .timeLimit(.minutes(3)))
struct NativeSheetResistanceOracleTests {
    private typealias Rect = NativeConductorUnion.Rect
    private let net = NetName("N")
    private let tolerance = 1e-8

    @Test func boundedOutputPreservesRawFailureAndNormalHashes() async throws {
        let evidence = try await Evidence.open("bounded-output")
        let noisyDirectory = try evidence.child("noisy")
        let noisy = Evidence(root: noisyDirectory.root, executable: URL(fileURLWithPath: "/usr/bin/head"))
        do {
            _ = try await noisy.run(arguments: ["-c", "1048577", "/dev/zero"], label: "oversized")
            Issue.record("Oversized stdout unexpectedly materialized successfully.")
        } catch let failure as OracleFailure {
            #expect(failure == .outputLimitExceeded(bytesRead: 0))
        }
        let raw = try Evidence.hashFile(noisy.root.appending(path: "oversized.stdout"))
        #expect(raw.byteCount == 1_048_577)
        let failure = try Evidence.readBounded(noisy.root.appending(path: "oversized.failure.json"))
        #expect(String(decoding: failure, as: UTF8.self).contains("outputLimitExceeded"))
        let failureHashes = try #require(try JSONSerialization.jsonObject(
            with: Evidence.readBounded(noisy.root.appending(path: "hashes.json"))) as? [String: [String: String]])
        #expect(failureHashes["sha256"]?["oversized.stdout"] == raw.hexadecimal)

        let normal = try evidence.child("normal")
        try normal.write(Data("abc".utf8), name: "normal.stdout")
        try normal.write(Data(), name: "normal.stderr")
        #expect(try Evidence.readBounded(normal.root.appending(path: "normal.stdout")) == Data("abc".utf8))
        try normal.finish()
        let normalHashes = try #require(try JSONSerialization.jsonObject(
            with: Evidence.readBounded(normal.root.appending(path: "hashes.json"))) as? [String: [String: String]])
        #expect(normalHashes["sha256"]?["normal.stdout"] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(normalHashes["sha256"]?["normal.stderr"] == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try evidence.finish()
    }

    @Test func analyticalRectanglesAcrossRotationAndThreeSpans() async throws {
        let evidence = try await Evidence.open("rectangles")
        for rotated in [false, true] {
            let bounds = rotated ? rect(0, 0, 20, 120) : rect(0, 0, 120, 20)
            let input = try makeInput(sources: [source("wire", bounds)], sheet: [("M1", 1)], contacts: [
                terminal("A", rotated ? rect(0, 0, 20, 10) : rect(0, 0, 10, 20)),
                terminal("B", rotated ? rect(0, 110, 20, 120) : rect(110, 0, 120, 20))])
            for span: Int32 in [100, 25, 10] {
                _ = try await compare(input, span: span, expected: 5,
                    name: "rotation-\(rotated)-span-\(span)", evidence: evidence)
            }
        }
        try evidence.finish()
    }

    @Test func actualThirtyFiveDBULContactRefinement() async throws {
        let evidence = try await Evidence.open("actual-35-dbu-l-contact")
        let input = try makeInput(sources: [
            source("horizontal", rect(17165, 5900, 17795, 6070)),
            source("vertical", rect(17165, 5865, 17335, 6070))], sheet: [("M1", 0.2)], contacts: [
                terminal("A", rect(17165, 5865, 17335, 5900)),
                terminal("B", rect(17760, 5900, 17795, 6070))])
        let spans: [Int32] = [35, 18, 9]
        var values: [Double] = []
        for span in spans {
            values.append(try await compare(input, span: span, expected: nil,
                name: "span-\(span)", evidence: evidence))
        }
        let coarseDelta = abs(values[1] - values[0]), fineDelta = abs(values[2] - values[1])
        try evidence.writeJSON(["spansDBU": spans, "ngspiceOhms": values,
            "coarseSuccessiveDifferenceOhms": coarseDelta, "fineSuccessiveDifferenceOhms": fineDelta,
            "physicalAccuracyQualified": false,
            "interpretation": "Successive refinement differences only; same-graph SPICE is a network-algebra oracle."],
            name: "refinement.json")
        #expect(values.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(fineDelta < coarseDelta)
        try evidence.finish()
    }

    @Test func twoParallelCutsPreserveIndividualAreaLaw() async throws {
        let evidence = try await Evidence.open("parallel-cut-area")
        let plate = rect(0, 0, 100, 100)
        let input = try makeInput(sources: [source("lower", plate), source("upper", plate, layer: "M2")],
            sheet: [("M1", 1), ("M2", 2)], contacts: [terminal("A", plate), terminal("B", plate, layer: "M2")],
            cuts: [
                .init(sourceID: "cutA", netName: net, lowerLayerName: "M1", upperLayerName: "M2", rect: plate, sourceOhms: 4),
                .init(sourceID: "cutB", netName: net, lowerLayerName: "M1", upperLayerName: "M2", rect: plate, sourceOhms: 12)])
        for span: Int32 in [100, 50, 25] {
            _ = try await compare(input, span: span, expected: 3, name: "span-\(span)", evidence: evidence)
        }
        try evidence.finish()
    }

    private func compare(_ input: NativeSheetResistanceInput, span: Int32, expected: Double?,
                         name: String, evidence: Evidence) async throws -> Double {
        let directory = try evidence.child(name)
        let inputObject = inputJSON(input, span: span)
        try directory.writeJSON(inputObject, name: "input.json")
        let sourceBytes = try JSONSerialization.data(withJSONObject: try #require(inputObject["sources"]), options: [.sortedKeys])
        try directory.write(sourceBytes, name: "source-artifact.json")
        try #require(input.conductorUnion.sources.allSatisfy {
            $0.sourceFacts.allSatisfy { $0.artifactID.digest.hexadecimalValue == Evidence.sha256(sourceBytes) }
        })
        let calculator: any NativeSheetResistanceCalculating = RectilinearSheetResistanceCalculator()
        let graph = try calculator.calculate(input: input, maximumCellSpanDatabaseUnits: span,
            limits: .init(maximumInputRecords: 100_000, maximumStringBytes: 100_000,
                maximumContributorIndices: 200_000, maximumCoordinateValues: 10_000,
                maximumMeshCells: 10_000, maximumGraphNodes: 10_000,
                maximumGraphElements: 100_000, maximumWorkVisits: 2_000_000), isCancelled: { false })
        let a = try #require(graph.terminalAssignments.first { $0.ref.nodeName.value == "A" }?.nodeIndex)
        let b = try #require(graph.terminalAssignments.first { $0.ref.nodeName.value == "B" }?.nodeIndex)
        try #require(a != b && graph.nodes[a].kind == .contact && graph.nodes[b].kind == .contact)
        try #require(graph.terminalAssignments.allSatisfy { !$0.cellIndices.isEmpty })
        try #require(graph.resistors.allSatisfy {
            $0.nodeA != $0.nodeB && $0.ohms.isFinite && $0.ohms > 0
                && graph.nodes.indices.contains($0.nodeA) && graph.nodes.indices.contains($0.nodeB)
        })
        try directory.writeJSON([
            "nodes": graph.nodes.enumerated().map { ["index": $0.offset, "kind": String(describing: $0.element.kind),
                "net": $0.element.netName.value, "layer": $0.element.layerName as Any? ?? NSNull()] as [String: Any] },
            "cells": graph.cells.map { ["rect": coordinates($0.rect), "node": $0.nodeIndex,
                "layer": $0.layerName, "contributors": $0.contributorIndices] as [String: Any] },
            "terminalAssignments": graph.terminalAssignments.map { ["terminal": $0.ref.nodeName.value,
                "node": $0.nodeIndex, "cells": $0.cellIndices] as [String: Any] },
            "resistors": graph.resistors.map { ["a": $0.nodeA, "b": $0.nodeB, "ohms": $0.ohms,
                "kind": String(describing: $0.kind), "contributors": $0.contributorIndices] as [String: Any] }
        ], name: "network.json")
        func node(_ index: Int) -> String { index == b ? "0" : "n\(index)" }
        var lines = ["Public sheet network DC algebra oracle", ".options reltol=1e-12 abstol=1e-15 vntol=1e-15",
                     "Vdrive \(node(a)) 0 DC 1"]
        for (index, edge) in graph.resistors.enumerated() {
            lines.append("R\(index) \(node(edge.nodeA)) \(node(edge.nodeB)) \(String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), edge.ohms))")
        }
        lines += [".control", "set noaskquit", "set numdgt=17", "op",
                  "let effective_resistance = -1 / i(vdrive)", "print effective_resistance", "quit", ".endc", ".end", ""]
        try directory.write(Data(lines.joined(separator: "\n").utf8), name: "network.cir")
        let independent = try solveKirchhoff(graph, drive: a, ground: b)
        let output = try await directory.run(arguments: ["-n", "-b", "network.cir"], label: "dc")
        let matches = output.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "effective_resistance" else { return nil }
            return Double(parts[1].trimmingCharacters(in: .whitespaces))
        }
        let measured = try #require(matches.count == 1 ? matches.first : nil)
        try #require(measured.isFinite && measured > 0)
        let algebraError = abs(measured - independent) / independent
        let analyticalError = expected.map { abs(measured - $0) / $0 }
        try directory.writeJSON(["ngspiceOhms": measured, "independentKirchhoffOhms": independent,
            "networkRelativeError": algebraError, "relativeTolerance": tolerance,
            "analyticalOhms": expected as Any? ?? NSNull(),
            "analyticalRelativeError": analyticalError as Any? ?? NSNull(),
            "maximumCellSpanDBU": span, "nodeCount": graph.nodes.count,
            "resistorCount": graph.resistors.count, "physicalAccuracyQualified": false], name: "results.json")
        try directory.finish()
        #expect(algebraError <= tolerance)
        if let analyticalError { #expect(analyticalError <= tolerance) }
        return measured
    }

    // Jacobi-preconditioned conjugate gradients is independent of mesh construction and
    // the existing dense elimination test helper. Only the public finite graph is consumed.
    private func solveKirchhoff(_ graph: NativeSheetResistanceResult, drive: Int, ground: Int) throws -> Double {
        try #require(graph.nodes.count <= 10_000 && graph.resistors.count <= 100_000)
        let free = graph.nodes.indices.filter { $0 != drive && $0 != ground }
        var indices = [Int](repeating: -1, count: graph.nodes.count)
        for (row, node) in free.enumerated() { indices[node] = row }
        var diagonal = [Double](repeating: 0, count: free.count), rhs = diagonal
        for edge in graph.resistors {
            for (u, v) in [(edge.nodeA, edge.nodeB), (edge.nodeB, edge.nodeA)] where indices[u] >= 0 {
                diagonal[indices[u]] += 1 / edge.ohms
                if v == drive { rhs[indices[u]] += 1 / edge.ohms }
            }
        }
        try #require(diagonal.allSatisfy { $0.isFinite && $0 > 0 })
        func product(_ vector: [Double]) -> [Double] {
            var result = [Double](repeating: 0, count: free.count)
            for edge in graph.resistors {
                let a = indices[edge.nodeA], b = indices[edge.nodeB]
                let flow = ((a >= 0 ? vector[a] : 0) - (b >= 0 ? vector[b] : 0)) / edge.ohms
                if a >= 0 { result[a] += flow }
                if b >= 0 { result[b] -= flow }
            }
            return result
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        var solution = [Double](repeating: 0, count: free.count), residual = rhs
        var direction = zip(residual, diagonal).map(/)
        var rz = dot(residual, direction)
        let target = max(dot(rhs, rhs) * 1e-26, 1e-30)
        var converged = dot(residual, residual) <= target
        for _ in 0..<(free.count * 8 + 100) where !converged {
            let applied = product(direction), denominator = dot(direction, applied)
            try #require(denominator.isFinite && denominator > 0)
            let alpha = rz / denominator
            for index in free.indices {
                solution[index] += alpha * direction[index]
                residual[index] -= alpha * applied[index]
            }
            converged = dot(residual, residual) <= target
            if converged { break }
            let preconditioned = zip(residual, diagonal).map(/), next = dot(residual, preconditioned)
            for index in free.indices { direction[index] = preconditioned[index] + next / rz * direction[index] }
            rz = next
        }
        try #require(converged)
        let actualResidual = zip(product(solution), rhs).map(-)
        try #require(dot(actualResidual, actualResidual) <= max(dot(rhs, rhs) * 1e-22, 1e-28))
        func voltage(_ node: Int) -> Double { node == drive ? 1 : (node == ground ? 0 : solution[indices[node]]) }
        var current = 0.0
        for edge in graph.resistors {
            if edge.nodeA == drive { current += (1 - voltage(edge.nodeB)) / edge.ohms }
            if edge.nodeB == drive { current += (1 - voltage(edge.nodeA)) / edge.ohms }
        }
        try #require(current.isFinite && current > 0)
        return 1 / current
    }

    private func rect(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) -> Rect {
        .init(minX: x0, minY: y0, maxX: x1, maxY: y1)
    }
    private func coordinates(_ r: Rect) -> [Int32] { [r.minX, r.minY, r.maxX, r.maxY] }
    private func source(_ id: String, _ r: Rect, layer: String = "M1") -> NativeConductorUnion.Source {
        .init(sourceID: id, netName: net, layerName: layer, rect: r, sourceFacts: [])
    }
    private func terminal(_ name: String, _ r: Rect, layer: String = "M1") -> NativeSheetResistanceInput.Terminal {
        .init(ref: .init(netName: net, nodeName: NodeName(name)), contacts: [.init(layerName: layer, rect: r)])
    }
    private func makeInput(sources: [NativeConductorUnion.Source], sheet: [(String, Double)],
                           contacts: [NativeSheetResistanceInput.Terminal], cuts: [NativeSheetResistanceInput.Cut] = []) throws -> NativeSheetResistanceInput {
        let bytes = try JSONSerialization.data(withJSONObject: sources.map {
            ["sourceID": $0.sourceID, "net": $0.netName.value, "layer": $0.layerName, "rect": coordinates($0.rect)] as [String: Any]
        }, options: [.sortedKeys])
        let artifact = try ArtifactID(digest: .init(algorithm: .sha256, hexadecimalValue: Evidence.sha256(bytes)), byteCount: UInt64(bytes.count))
        let attributed = sources.map { NativeConductorUnion.Source(sourceID: $0.sourceID, netName: $0.netName,
            layerName: $0.layerName, rect: $0.rect, sourceFacts: [.init(artifactID: artifact, byteRange: .init(lowerBound: 0, upperBound: bytes.count))]) }
        let geometry = try RectilinearConductorUnionBuilder().build(sources: attributed, databaseUnitsPerMicron: 1000,
            limits: .init(maximumInputRecords: 100_000, maximumStringBytes: 100_000, maximumUnionBands: 10_000,
                maximumBoundarySegments: 10_000, maximumContributorIndices: 100_000,
                maximumCoordinateValues: 10_000, maximumWorkVisits: 1_000_000), isCancelled: { false })
        return .init(conductorUnion: geometry, materials: sheet.map { .init(layerName: $0.0, sheetOhms: $0.1) }, cuts: cuts, terminals: contacts)
    }
    private func inputJSON(_ input: NativeSheetResistanceInput, span: Int32) -> [String: Any] {
        ["maximumCellSpanDBU": span, "databaseUnitsPerMicron": input.conductorUnion.databaseUnitsPerMicron,
         "sources": input.conductorUnion.sources.map { ["sourceID": $0.sourceID, "net": $0.netName.value,
            "layer": $0.layerName, "rect": coordinates($0.rect)] as [String: Any] },
         "materials": input.materials.map { ["layer": $0.layerName, "sheetOhms": $0.sheetOhms] as [String: Any] },
         "cuts": input.cuts.map { ["sourceID": $0.sourceID, "rect": coordinates($0.rect), "sourceOhms": $0.sourceOhms,
            "lower": $0.lowerLayerName, "upper": $0.upperLayerName] as [String: Any] },
         "terminals": input.terminals.map { ["terminal": $0.ref.nodeName.value,
            "contacts": $0.contacts.map { ["layer": $0.layerName, "rect": coordinates($0.rect)] as [String: Any] }] as [String: Any] }]
    }

    private struct Evidence {
        let root: URL
        let executable: URL

        static func open(_ name: String) async throws -> Self {
            let env = ProcessInfo.processInfo.environment
            let path = try #require(env["PEX_SHEET_NGSPICE_EVIDENCE_ROOT"])
            try #require(path.hasPrefix("/"))
            let root = URL(fileURLWithPath: path).appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let executablePath = env["PEX_SHEET_NGSPICE_EXECUTABLE"], executablePath.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: executablePath) else {
                let bytes = Data("Required external oracle unavailable: supply absolute PEX_SHEET_NGSPICE_EXECUTABLE.\n".utf8)
                try bytes.write(to: root.appending(path: "INCONCLUSIVE.txt"))
                throw OracleFailure.requiredToolUnavailable
            }
            let result = Self(root: root, executable: URL(fileURLWithPath: executablePath).resolvingSymlinksInPath())
            let identity = try hashFile(result.executable)
            try result.writeJSON(["executable": result.executable.path, "executableSHA256": identity.hexadecimal,
                "executableBytes": identity.byteCount, "processTimeoutSeconds": 30, "physicalAccuracyQualified": false,
                "relativeTolerance": 1e-8], name: "oracle.json")
            _ = try await result.run(arguments: ["--version"], label: "version")
            return result
        }
        func child(_ name: String) throws -> Self {
            let path = root.appending(path: name, directoryHint: .isDirectory)
            try #require(!FileManager.default.fileExists(atPath: path.path))
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            return Self(root: path, executable: executable)
        }
        func write(_ data: Data, name: String) throws { try data.write(to: root.appending(path: name), options: .withoutOverwriting) }
        func writeJSON(_ object: [String: Any], name: String) throws {
            try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), name: name)
        }
        static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        private static func withRegularFile<Value>(_ url: URL, _ body: (FileHandle, Int64) throws -> Value) throws -> Value {
            let handle = try FileHandle(forReadingFrom: url)
            do {
                var status = stat()
                guard fstat(handle.fileDescriptor, &status) == 0,
                      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size >= 0 else { throw OracleFailure.notRegularFile }
                let value = try body(handle, status.st_size)
                try handle.close()
                return value
            } catch {
                do { try handle.close() } catch { Issue.record("Closing oracle evidence input: \(error)") }
                throw error
            }
        }
        static func readBounded(_ url: URL) throws -> Data {
            try withRegularFile(url) { handle, size in
                let maximum = 1_048_576
                guard size <= maximum else { throw OracleFailure.outputLimitExceeded(bytesRead: 0) }
                var result = Data()
                result.reserveCapacity(Int(size))
                while let chunk = try handle.read(upToCount: min(65_536, maximum - result.count + 1)), !chunk.isEmpty {
                    guard chunk.count <= maximum - result.count else {
                        throw OracleFailure.outputLimitExceeded(bytesRead: result.count + chunk.count)
                    }
                    result.append(chunk)
                }
                return result
            }
        }
        static func hashFile(_ url: URL) throws -> (hexadecimal: String, byteCount: UInt64) {
            try withRegularFile(url) { handle, _ in
                var hash = SHA256(), count: UInt64 = 0
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    hash.update(data: chunk)
                    count += UInt64(chunk.count)
                }
                return (hash.finalize().map { String(format: "%02x", $0) }.joined(), count)
            }
        }
        func finish() throws {
            var hashes: [String: String] = [:]
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey]).sorted(by: { $0.path < $1.path }) {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    hashes[url.lastPathComponent] = try Self.hashFile(url).hexadecimal
                }
            }
            try writeJSON(["sha256": hashes], name: "hashes.json")
        }
        func run(arguments: [String], label: String) async throws -> String {
            let outURL = root.appending(path: "\(label).stdout"), errURL = root.appending(path: "\(label).stderr")
            try Data().write(to: outURL, options: .withoutOverwriting)
            try Data().write(to: errURL, options: .withoutOverwriting)
            let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
            var outOpen = true, errOpen = true
            let process = Process()
            process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = root
            process.standardOutput = out; process.standardError = err
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "LC_ALL": "C"]
            let started = ContinuousClock.now
            do {
                try process.run()
                while process.isRunning {
                    if ContinuousClock.now - started >= .seconds(30) { throw OracleFailure.processTimeout }
                    try await Task.sleep(for: .milliseconds(10))
                }
                process.waitUntilExit()
                try out.close(); outOpen = false
                try err.close(); errOpen = false
                try writeJSON(["arguments": arguments, "exitStatus": process.terminationStatus,
                    "terminationReason": process.terminationReason.rawValue], name: "\(label).process.json")
                try #require(process.terminationStatus == 0)
                let bytes = try Self.readBounded(outURL)
                return try #require(String(data: bytes, encoding: .utf8))
            } catch {
                if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
                do {
                    if outOpen { try out.close() }
                    if errOpen { try err.close() }
                } catch { Issue.record("Closing external oracle output: \(error)") }
                try writeJSON(["failure": String(describing: error), "arguments": arguments,
                    "status": "inconclusive-or-failed"], name: "\(label).failure.json")
                try finish()
                throw error
            }
        }
    }
    private enum OracleFailure: Error, Equatable {
        case requiredToolUnavailable, processTimeout, notRegularFile
        case outputLimitExceeded(bytesRead: Int)
    }
}
