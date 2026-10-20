import Foundation
import Synchronization
import PEXCore
import PEXParsers
import Testing

@Suite("Controlled standard PEX pipeline", .timeLimit(.minutes(1)))
struct ControlledStandardIOTests {
    enum Stage: String, CaseIterable, Sendable { case lexer, parser, lowering, writer, composer, magic }
    private enum Refusal: Error, Equatable { case work, storage, cancelled, reservation }

    /// One immutable lease owns exactly one reservation. The tracker never owns leases.
    private final class Lease: Sendable {
        let tracker: Tracker
        let kind: PEXParserStorageKind
        let bytes: UInt64
        init(tracker: Tracker, kind: PEXParserStorageKind, bytes: UInt64) {
            self.tracker = tracker; self.kind = kind; self.bytes = bytes
        }
        deinit { tracker.release(kind: kind, bytes: bytes) }
    }
    private final class Tracker: PEXParserResourceControlling {
        struct State {
            var work: UInt64 = 0
            var temporary: UInt64 = 0
            var retained: UInt64 = 0
            var peak: UInt64 = 0
            var checkpointCalls = 0
            var reservationAttempts = 0
            var reservations = 0
            var releases = 0
            var cancelled = false
        }
        let maximumWork: UInt64
        let maximumStorage: UInt64
        let cancelAtCheckpoint: Int?
        let cancelAfterReservation: Bool
        let failReservation: Bool
        let sourceLikeRefusal: PEXSPICEWriterError?
        private let storage = Mutex(State())
        init(work: UInt64 = 10_000_000, bytes: UInt64 = 67_108_864,
            cancelAtCheckpoint: Int? = nil, cancelAfterReservation: Bool = false,
            failReservation: Bool = false, sourceLikeRefusal: PEXSPICEWriterError? = nil) {
            maximumWork = work; maximumStorage = bytes
            self.cancelAtCheckpoint = cancelAtCheckpoint
            self.cancelAfterReservation = cancelAfterReservation; self.failReservation = failReservation
            self.sourceLikeRefusal = sourceLikeRefusal
        }
        var state: State { storage.withLock { $0 } }
        func checkpoint(workUnits: UInt64) throws {
            try storage.withLock { state in
                state.checkpointCalls += 1
                if let cancelAtCheckpoint, state.checkpointCalls >= cancelAtCheckpoint { state.cancelled = true }
                if state.cancelled { throw Refusal.cancelled }
                guard workUnits <= maximumWork - state.work else { throw Refusal.work }
                state.work += workUnits
            }
        }
        func reserveStorage(kind: PEXParserStorageKind, byteCount: UInt64) throws -> any Sendable {
            try storage.withLock { state in
                state.reservationAttempts += 1
                if state.cancelled { throw Refusal.cancelled }
                if failReservation { throw Refusal.reservation }
                if let sourceLikeRefusal { throw sourceLikeRefusal }
                let live = state.temporary + state.retained
                guard byteCount <= maximumStorage - live else { throw Refusal.storage }
                switch kind {
                case .temporary: state.temporary += byteCount
                case .retained: state.retained += byteCount
                }
                state.peak = max(state.peak, live + byteCount)
                state.reservations += 1
                if cancelAfterReservation { state.cancelled = true }
            }
            // No caller callback or deallocation executes under the admission mutex.
            return Lease(tracker: self, kind: kind, bytes: byteCount)
        }
        func release(kind: PEXParserStorageKind, bytes: UInt64) {
            storage.withLock { state in
                switch kind {
                case .temporary: state.temporary -= bytes
                case .retained: state.retained -= bytes
                }
                state.releases += 1
            }
        }
        func expectRefund(sourceLocation: Testing.SourceLocation = #_sourceLocation) {
            let s = state
            #expect(s.temporary == 0 && s.retained == 0 && s.reservations == s.releases,
                sourceLocation: sourceLocation)
        }
    }

    private struct Passive: Hashable {
        let kind: ElementKind
        let a: NodeRef
        let b: NodeRef?
        let bits: UInt64
    }
    private func passiveMultiset(_ ir: ParasiticIR) -> [Passive: Int] {
        var result: [Passive: Int] = [:]
        for e in ir.elements { result[.init(kind: e.kind, a: e.nodeA, b: e.nodeB, bits: e.value.bitPattern), default: 0] += 1 }
        return result
    }
    // Input text and the legacy-derived inputs are caller-owned, admitted before controlled operators.
    private let source = """
    *SPEF "IEEE 1481-1998"
    *DESIGN "TOP"
    *DIVIDER /
    *DELIMITER :
    *BUS_DELIMITER [ ]
    *T_UNIT 1 NS
    *C_UNIT 1 PF
    *R_UNIT 1 OHM
    *L_UNIT 1 HENRY
    *NAME_MAP
    *1 NA
    *2 NB
    *3 a
    *4 b
    *5 c
    *6 d
    *PORTS
    *3 B
    *4 B
    *5 B
    *6 B
    *D_NET *1 0.22
    *CONN
    *P *3 B
    *P *4 B
    *CAP
    1 *3 0.1
    2 *3 0.1
    3 *3 *5 0.02
    *RES
    1 *3 *4 10
    2 *3 *4 10
    *INDUC
    1 *3 *4 1e-9
    *END
    *D_NET *2 0.22
    *CONN
    *P *5 B
    *P *6 B
    *CAP
    1 *5 0.2
    *RES
    1 *5 *6 20
    *END
    """
    private let deck = """
    .subckt TOP a b c d
    Vfirst a b 0
    Vsecond c d 0
    .ends TOP
    XTOP a b c d TOP
    .end
    """
    private var writer: PEXSPICEWriter { .init(options: .init(subcircuitName: "controlled_pex")) }
    private var composer: PEXSPICEBackannotationComposer {
        .init(options: .init(topCell: "TOP", subcircuitName: "controlled_pex", instanceName: "XPEX", requirePortMatches: true))
    }
    private func context() -> PEXParseContext {
        .init(cornerID: "tt", runID: .init(), topCell: "TOP", technology: nil, options: .default)
    }
    private struct Inputs {
        let tokens: [SPEFToken.Located]
        let tree: SPEFParseTree
        let ir: ParasiticIR
        let raw: PEXRawOutput
    }
    private func withInputs(_ body: (Inputs) throws -> Void) throws {
        var lexer = SPEFLexer(source: source, fileName: "two-net.spef")
        let tokens = lexer.tokenize(), tree = try SPEFParser().parse(tokens: tokens)
        let ir = try SPEFLowering().lower(tree, cornerID: "tt")
        #expect(ir.nets.count == 2 && ir.elements.count == 8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("controlled-pex-\(UUID().uuidString).cir")
        try Data(composer.compose(sourceNetlist: deck, ir: ir).utf8).write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record(error) }
        }
        try body(.init(tokens: tokens, tree: tree, ir: ir, raw: .init(format: .spice, fileURLs: [url])))
    }
    private func execute(_ stage: Stage, inputs: Inputs, tracker: Tracker) throws -> PEXParserRetention {
        switch stage {
        case .lexer: return try SPEFLexer.tokenize(source: source, fileName: "two-net.spef", control: tracker).retention
        case .parser: return try SPEFParser().parse(tokens: inputs.tokens, control: tracker).retention
        case .lowering: return try SPEFLowering().lower(inputs.tree, cornerID: "tt", control: tracker).retention
        case .writer: return try writer.write(inputs.ir, control: tracker).retention
        case .composer: return try composer.compose(sourceNetlist: deck, ir: inputs.ir, control: tracker).retention
        case .magic: return try MagicSPICEParasiticParser().parse(inputs.raw, context: context(), control: tracker).retention
        }
    }
    private func expectRefusal(_ expected: Refusal, _ operation: () throws -> PEXParserRetention,
        sourceLocation: Testing.SourceLocation = #_sourceLocation) throws {
        do {
            let unexpected = try operation()
            withExtendedLifetime(unexpected) { Issue.record("Controlled operation published after refusal", sourceLocation: sourceLocation) }
        } catch let actual as Refusal {
            #expect(actual == expected, sourceLocation: sourceLocation)
        }
    }

    @Test func completePipelinePreservesActualOperatorsAndFinalAnchorCopies() throws {
        try withInputs { inputs in
            let tracker = Tracker()
            struct Retained {
                let value: ParasiticIR
                let anchors: [PEXParserRetention]
            }
            var original: Retained?
            var work = [UInt64]()
            do {
                let tokens = try SPEFLexer.tokenize(source: source, fileName: "two-net.spef", control: tracker)
                #expect(tokens.value == inputs.tokens)
                work.append(tracker.state.work)
                let tree = try SPEFParser().parse(tokens: tokens.value, control: tracker)
                #expect(tree.value.header.designName == inputs.tree.header.designName)
                #expect(tree.value.nameMap == inputs.tree.nameMap && tree.value.nets.count == inputs.tree.nets.count)
                work.append(tracker.state.work)
                let ir = try SPEFLowering().lower(tree.value, cornerID: "tt", control: tracker)
                #expect(ir.value == inputs.ir)
                work.append(tracker.state.work)
                let fragment = try writer.write(ir.value, control: tracker)
                let legacyFragment = try writer.write(inputs.ir)
                #expect(fragment.value == legacyFragment)
                work.append(tracker.state.work)
                let composed = try composer.compose(sourceNetlist: deck, ir: ir.value, control: tracker)
                let legacyComposed = try composer.compose(sourceNetlist: deck, ir: inputs.ir)
                #expect(composed.value == legacyComposed)
                work.append(tracker.state.work)
                // This raw file contains those same exact controlled bytes. The Magic operator owns its read buffer.
                let bytes = try Data(contentsOf: inputs.raw.fileURLs[0])
                #expect(bytes == Data(composed.value.utf8))
                let sameContext = context()
                let cold = try MagicSPICEParasiticParser().parse(inputs.raw, context: sameContext, control: tracker)
                let legacyCold = try MagicSPICEParasiticParser().parse(inputs.raw, context: sameContext)
                #expect(cold.value == legacyCold)
                #expect(passiveMultiset(cold.value) == passiveMultiset(inputs.ir))
                #expect(passiveMultiset(cold.value).values.contains(2))
                work.append(tracker.state.work)
                original = .init(value: cold.value,
                    anchors: [tokens.retention, tree.retention, ir.retention, fragment.retention, composed.retention, cold.retention])
            }
            for index in 1..<work.count { #expect(work[index] > work[index - 1]) }
            #expect(tracker.state.temporary == 0 && tracker.state.retained > 0)
            #expect(tracker.state.peak > tracker.state.retained)
            var copy = original; original = nil
            do {
                let owned = try #require(copy)
                #expect(passiveMultiset(owned.value) == passiveMultiset(inputs.ir))
                #expect(owned.anchors.count == 6 && tracker.state.retained > 0)
            }
            copy = nil
            tracker.expectRefund()
            #expect(tracker.state.work == work.last)
        }
    }

    @Test(arguments: Stage.allCases)
    func zeroRemainingStorageRefusesValidInputBeforePublishing(_ stage: Stage) throws {
        try withInputs { inputs in
            let tracker = Tracker(bytes: 0)
            try expectRefusal(.storage) { try execute(stage, inputs: inputs, tracker: tracker) }
            #expect(tracker.state.reservationAttempts > 0 && tracker.state.reservations == 0 && tracker.state.peak == 0)
            tracker.expectRefund()
        }
    }

    @Test(arguments: Stage.allCases)
    func reservationFailureAndPostReservationCancellationKeepExactCause(_ stage: Stage) throws {
        try withInputs { inputs in
            let refused = Tracker(failReservation: true)
            try expectRefusal(.reservation) { try execute(stage, inputs: inputs, tracker: refused) }
            #expect(refused.state.reservationAttempts > 0 && refused.state.reservations == 0)
            refused.expectRefund()
            let cancelled = Tracker(cancelAfterReservation: true)
            try expectRefusal(.cancelled) { try execute(stage, inputs: inputs, tracker: cancelled) }
            #expect(cancelled.state.cancelled && cancelled.state.reservations > 0)
            cancelled.expectRefund()
        }
    }

    @Test(arguments: Stage.allCases)
    func workRefusalAndInnerScanCancellationUseTheSameCumulativeOwner(_ stage: Stage) throws {
        try withInputs { inputs in
            let measured = Tracker()
            do { let anchor = try execute(stage, inputs: inputs, tracker: measured); withExtendedLifetime(anchor) {} }
            measured.expectRefund()
            try #require(measured.state.work > 0 && measured.state.checkpointCalls > 2)
            let short = Tracker(work: measured.state.work - 1)
            try expectRefusal(.work) { try execute(stage, inputs: inputs, tracker: short) }
            #expect(short.state.work > 0 && short.state.work <= short.maximumWork)
            short.expectRefund()
            let cancelled = Tracker(cancelAtCheckpoint: max(2, measured.state.checkpointCalls / 2))
            try expectRefusal(.cancelled) { try execute(stage, inputs: inputs, tracker: cancelled) }
            #expect(cancelled.state.checkpointCalls >= 2 && cancelled.state.cancelled)
            cancelled.expectRefund()
        }
    }

    @Test func generatedIdentityNameMapExpansionAndOldNewPeakAreAdmitted() throws {
        try withInputs { inputs in
            // Large exact pin identities exercise the actual generated annotation/name-map decoder.
            // The input value itself is caller-owned; only its controlled expansion is charged here.
            let prefix = String(repeating: "long_identity_", count: 512)
            func renamed(_ ref: NodeRef) -> NodeRef {
                .init(netName: ref.netName, nodeName: .init(prefix + ref.nodeName.value))
            }
            let large = ParasiticIR(version: inputs.ir.version, cornerID: inputs.ir.cornerID,
                units: inputs.ir.units, nets: inputs.ir.nets.map { net in
                    .init(name: net.name, nodes: net.nodes.map {
                        .init(name: .init(prefix + $0.name.value), kind: $0.kind,
                            instancePath: $0.instancePath, coordinate: $0.coordinate)
                    }, totalGroundCapF: net.totalGroundCapF, totalCouplingCapF: net.totalCouplingCapF,
                    totalResistanceOhm: net.totalResistanceOhm)
                }, elements: inputs.ir.elements.map {
                    .init(id: $0.id, kind: $0.kind, nodeA: renamed($0.nodeA), nodeB: $0.nodeB.map(renamed),
                        value: $0.value, source: $0.source)
                }, metadata: inputs.ir.metadata)
            let generated = try SPEFWriter().write(large)
            var legacyLexer = SPEFLexer(source: generated)
            let legacyTokens = legacyLexer.tokenize()
            let legacyTree = try SPEFParser().parse(tokens: legacyTokens)
            let expected = try SPEFLowering().lower(legacyTree, cornerID: "tt")
            #expect(passiveMultiset(expected) == passiveMultiset(large))
            let measured = Tracker()
            do {
                let result = try SPEFLowering().lower(legacyTree, cornerID: "tt", control: measured)
                #expect(result.value == expected)
                #expect(measured.state.retained > 0)
                withExtendedLifetime(result.retention) {}
            }
            measured.expectRefund()
            let peak = measured.state.peak
            try #require(peak > 1)
            // This exact valid identity requires concurrent scratch and output, not just the final IR bytes.
            let tooSmall = Tracker(bytes: peak - 1)
            try expectRefusal(.storage) {
                try SPEFLowering().lower(legacyTree, cornerID: "tt", control: tooSmall).retention
            }
            #expect(tooSmall.state.peak <= tooSmall.maximumStorage)
            tooSmall.expectRefund()
        }
    }

    @Test func malformedSourceAndOperatorErrorsPreserveLegacyRefusalsAndRefund() throws {
        try withInputs { inputs in
            let duplicate = source.replacingOccurrences(of: "*2 NB", with: "*2 NB\n*2 NB")
            var legacyLexer = SPEFLexer(source: duplicate)
            let tokens = legacyLexer.tokenize()
            let tracker = Tracker()
            let legacy: SPEFParserDiagnostic
            do {
                _ = try SPEFParser().parse(tokens: tokens)
                Issue.record("Duplicate map fixture must be invalid"); return
            } catch let failure as SPEFParserDiagnostic { legacy = failure }
            var originalFailure: PEXParserSourceFailure?
            do {
                _ = try SPEFParser().parse(tokens: tokens, control: tracker)
                Issue.record("Controlled parser accepted duplicate NAME_MAP")
            } catch let failure as PEXParserSourceFailure { originalFailure = failure }
            #expect(tracker.state.temporary == 0 && tracker.state.retained > 0)
            var failureCopy = originalFailure; originalFailure = nil
            do {
                let held = try #require(failureCopy)
                let actual = try #require(held.cause as? SPEFParserDiagnostic)
                #expect(actual.severity == legacy.severity && actual.message == legacy.message && actual.location == legacy.location)
                #expect(tracker.state.retained > 0)
                withExtendedLifetime(held.retention) {}
            }
            failureCopy = nil
            tracker.expectRefund()
            let first = try #require(inputs.ir.elements.first)
            let invalid = ParasiticIR(version: inputs.ir.version, cornerID: inputs.ir.cornerID,
                units: inputs.ir.units, nets: inputs.ir.nets,
                elements: [.init(id: first.id, kind: first.kind, nodeA: first.nodeA, nodeB: first.nodeB,
                    value: -1, source: first.source)], metadata: inputs.ir.metadata)
            let writerTracker = Tracker()
            var writerFailure: PEXParserSourceFailure?
            do {
                _ = try writer.write(invalid, control: writerTracker)
                Issue.record("Controlled writer accepted a negative operator")
            } catch let failure as PEXParserSourceFailure { writerFailure = failure }
            #expect(writerTracker.state.temporary == 0 && writerTracker.state.retained > 0)
            var writerCopy = writerFailure; writerFailure = nil
            do {
                let held = try #require(writerCopy)
                let actual = try #require(held.cause as? PEXSPICEWriterError)
                #expect(actual == .negativeValue(first.id))
                #expect(writerTracker.state.retained > 0)
                withExtendedLifetime(held.retention) {}
            }
            writerCopy = nil
            writerTracker.expectRefund()
            // An identical error TYPE originating from caller admission must not become a source wrapper.
            let sentinel = PEXSPICEWriterError.negativeValue("CALLER_CONTROL")
            let caller = Tracker(sourceLikeRefusal: sentinel)
            #expect(throws: sentinel) { try writer.write(inputs.ir, control: caller) }
            caller.expectRefund()
        }
    }
}
