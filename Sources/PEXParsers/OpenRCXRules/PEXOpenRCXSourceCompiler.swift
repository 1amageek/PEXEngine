import Foundation
import CryptoKit
import PEXCore

public struct PEXOpenRCXSourceCompiler: PEXOpenRCXCompiling {
    public init() {}

    public func compile(bytes: borrowing Data, selection: PEXOpenRCXSourceModel.Selection,
                        limits: PEXOpenRCXCompilationLimits, isCancelled: () -> Bool = { Task.isCancelled })
        throws(PEXOpenRCXSourceError) -> PEXOpenRCXSourceModel {
        var parser = try Parser(bytes: bytes, limits: limits, isCancelled: isCancelled)
        try parser.admitSelection(selection, isCancelled)
        try selection.validate()
        try parser.verifySource(selection, isCancelled)
        return try parser.parse(selection, isCancelled)
    }

    public func validate(model: borrowing PEXOpenRCXSourceModel, bytes: borrowing Data,
                         limits: PEXOpenRCXCompilationLimits, isCancelled: () -> Bool = { Task.isCancelled })
        throws(PEXOpenRCXSourceError) {
        let restored = try compile(bytes: bytes, selection: model.selection, limits: limits, isCancelled: isCancelled)
        guard restored == model else { throw .modelMismatch }
    }

    private struct Parser {
        typealias Model = PEXOpenRCXSourceModel
        struct Line {
            let number: Int
            let range: Model.SourceRange
        }
        struct Tokens {
            let line: Line
            let values: [Substring]
        }
        let bytes: Data
        let limits: PEXOpenRCXCompilationLimits
        var work: Int
        var records: Int
        var rows: Int
        var lines: [Line] = []
        var position = 0

        init(bytes: borrowing Data, limits: PEXOpenRCXCompilationLimits, isCancelled: () -> Bool)
            throws(PEXOpenRCXSourceError) {
            guard [limits.maximumSourceBytes, limits.maximumLineBytes, limits.maximumLines,
                   limits.maximumRecords, limits.maximumRows, limits.maximumWorkVisits].allSatisfy({ $0 >= 0 }) else {
                throw .invalidSelection("Negative compiler limit")
            }
            guard bytes.count <= limits.maximumSourceBytes else { throw .limitExceeded(.sourceBytes) }
            self.bytes = copy bytes; self.limits = limits
            work = limits.maximumWorkVisits; records = limits.maximumRecords; rows = limits.maximumRows
            var start = 0, cursor = 0, lineNumber = 1
            while cursor < bytes.count {
                try visit(1, isCancelled)
                let byte = bytes[bytes.startIndex + cursor]
                guard byte == 9 || byte == 10 || byte == 13 || (byte >= 32 && byte <= 126) else {
                    throw .invalidSource(line: lineNumber, reason: "Non-ASCII source byte")
                }
                if byte == 10 {
                    try appendLine(start, cursor, number: lineNumber, isCancelled)
                    start = cursor + 1; lineNumber += 1
                } else if cursor - start >= limits.maximumLineBytes {
                    throw .limitExceeded(.lineBytes)
                }
                cursor += 1
            }
            if start < bytes.count { try appendLine(start, bytes.count, number: lineNumber, isCancelled) }
        }

        mutating func appendLine(_ start: Int, _ end: Int, number: Int, _ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) {
            guard number <= limits.maximumLines else { throw .limitExceeded(.lines) }
            var lower = start, upper = end
            while lower < upper && [9, 13, 32].contains(bytes[bytes.startIndex + lower]) { try visit(1, isCancelled); lower += 1 }
            while upper > lower && [9, 13, 32].contains(bytes[bytes.startIndex + upper - 1]) { try visit(1, isCancelled); upper -= 1 }
            if lower < upper { lines.append(Line(number: number, range: .init(lowerBound: lower, upperBound: upper))) }
        }

        mutating func visit(_ count: Int, _ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) {
            guard !isCancelled() else { throw .cancelled }
            guard count >= 0, count <= work else { throw .limitExceeded(.workVisits) }
            work -= count
        }

        mutating func record(_ isRow: Bool, _ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) {
            try visit(1, isCancelled)
            guard records > 0 else { throw .limitExceeded(.records) }
            if isRow {
                guard rows > 0 else { throw .limitExceeded(.rows) }
                rows -= 1
            }
            records -= 1
        }

        mutating func admitSelection(_ selection: Model.Selection, _ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) {
            guard selection.routingLayerNames.count == 6 else { throw .invalidSelection("Six routing names required") }
            for name in [selection.processName] + selection.routingLayerNames {
                for _ in name.utf8 { try visit(1, isCancelled) }
            }
        }

        mutating func verifySource(_ selection: Model.Selection, _ isCancelled: () -> Bool)
            throws(PEXOpenRCXSourceError) {
            guard UInt64(bytes.count) == selection.rulesArtifactID.byteCount else { throw .sourceMismatch }
            var hash = SHA256(), cursor = 0
            while cursor < bytes.count {
                let end = cursor + min(4096, bytes.count - cursor)
                try visit(end - cursor, isCancelled)
                hash.update(data: bytes[(bytes.startIndex + cursor)..<(bytes.startIndex + end)])
                cursor = end
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined()
                    == selection.rulesArtifactID.digest.hexadecimalValue else { throw .sourceMismatch }
        }

        mutating func peek(_ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) -> Tokens {
            guard position < lines.count else { throw .invalidSource(line: lines.last?.number ?? 1, reason: "Unexpected end of source") }
            let line = lines[position]
            try visit(line.range.upperBound - line.range.lowerBound, isCancelled)
            // One-time bounded lexical conversion; Native queries never rematerialize tokens.
            let text = String(decoding: bytes[(bytes.startIndex + line.range.lowerBound)..<(bytes.startIndex + line.range.upperBound)], as: UTF8.self)
            return Tokens(line: line, values: text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }))
        }

        mutating func read(_ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) -> Tokens {
            let result = try peek(isCancelled); position += 1; return result
        }

        func fail(_ line: Tokens, _ reason: String) -> PEXOpenRCXSourceError {
            .invalidSource(line: line.line.number, reason: reason)
        }
        func number(_ token: Substring, _ line: Tokens) throws(PEXOpenRCXSourceError) -> Double {
            guard let value = Double(token), value.isFinite, value >= 0 else { throw fail(line, "Finite nonnegative number required") }
            return value
        }
        func integer(_ token: Substring, _ line: Tokens) throws(PEXOpenRCXSourceError) -> Int {
            guard let value = Int(token), value >= 0 else { throw fail(line, "Nonnegative integer required") }
            return value
        }
        mutating func expect(_ expected: [String], _ isCancelled: () -> Bool) throws(PEXOpenRCXSourceError) {
            let line = try read(isCancelled)
            guard line.values.elementsEqual(expected.map { Substring($0) }) else { throw fail(line, "Expected " + expected.joined(separator: " ")) }
        }

        mutating func parse(_ selection: Model.Selection, _ isCancelled: () -> Bool)
            throws(PEXOpenRCXSourceError) -> Model {
            try expect(["Extraction", "Rules", "for", "OpenRCX"], isCancelled)
            try expect(["DIAGMODEL", "ON"], isCancelled)
            try expect(["LayerCount", "6"], isCancelled)
            try expect(["DensityRate", "1", "0"], isCancelled)
            try expect(["DensityModel", "0"], isCancelled)
            let first = try peek(isCancelled)
            let header = Model.SourceRange(lowerBound: 0, upperBound: first.line.range.lowerBound)
            var families: [Model.Family] = [], tables: [Model.Table] = []
            while true {
                let familyLine = try read(isCancelled)
                if familyLine.values == ["END", "DensityModel", "0"] {
                    guard position == lines.count else { throw fail(familyLine, "Trailing source records") }
                    break
                }
                guard familyLine.values.count == 3, familyLine.values[0] == "Metal",
                      let kind = Model.Kind(rawValue: String(familyLine.values[2])) else { throw fail(familyLine, "Family header") }
                let metal = try integer(familyLine.values[1], familyLine)
                let widthLine = try read(isCancelled)
                guard widthLine.values.count >= 4, widthLine.values[0] == "WIDTH", widthLine.values[1] == "Table",
                      widthLine.values[3] == "entries:" else { throw fail(widthLine, "Width declaration") }
                let count = try integer(widthLine.values[2], widthLine)
                guard count <= 1, widthLine.values.count - 4 == count else { throw fail(widthLine, "Selected profile has zero or one width") }
                var widths: [Double] = []
                for token in widthLine.values.dropFirst(4) {
                    let value = try number(token, widthLine)
                    guard value > 0 else { throw fail(widthLine, "Positive width required") }
                    widths.append(value)
                }
                try record(false, isCancelled)
                var familyEnd = widthLine.line.range.upperBound
                while position < lines.count {
                    let contextLine = try peek(isCancelled)
                    if contextLine.values.first == "END" || contextLine.values.count == 3 { break }
                    position += 1
                    let context = try parseContext(contextLine, metal: metal, kind: kind)
                    guard widths.count == 1 else { throw fail(contextLine, "Context in empty-width family") }
                    let table = try parseTable(contextLine, context: context, width: widths[0], isCancelled)
                    familyEnd = table.sourceRange.upperBound
                    tables.append(table)
                }
                families.append(.init(metal: metal, kind: kind, widthsMicrons: widths,
                    sourceRange: .init(lowerBound: familyLine.line.range.lowerBound, upperBound: familyEnd)))
            }
            let outputCount = limits.maximumRecords - records
            let (validationWork, overflow) = outputCount.multipliedReportingOverflow(by: 8)
            guard !overflow else { throw .limitExceeded(.workVisits) }
            try visit(validationWork, isCancelled)
            return try Model(selection: selection, sourceHeaderRange: header, families: families, tables: tables)
        }

        func parseContext(_ line: Tokens, metal: Int, kind: Model.Kind) throws(PEXOpenRCXSourceError) -> Model.Context {
            let tokens = line.values
            guard tokens.count >= 4, tokens[0] == "Metal", try integer(tokens[1], line) == metal else { throw fail(line, "Context metal") }
            if kind == .overUnder {
                guard tokens.count == 6, tokens[2] == "OVER", tokens[4] == "UNDER" else { throw fail(line, "OVERUNDER context") }
                return .init(metal: metal, kind: kind, underMetal: try integer(tokens[3], line), overMetal: try integer(tokens[5], line))
            }
            guard tokens.count == 4, tokens[2] == Substring(kind.rawValue) else { throw fail(line, "Context family") }
            let other = try integer(tokens[3], line)
            return .init(metal: metal, kind: kind, underMetal: kind == .resOver || kind == .over ? other : nil,
                         overMetal: kind == .under || kind == .diagUnder ? other : nil)
        }

        mutating func parseTable(_ contextLine: Tokens, context: Model.Context, width: Double, _ isCancelled: () -> Bool)
            throws(PEXOpenRCXSourceError) -> Model.Table {
            let declaration = try read(isCancelled)
            guard declaration.values.count == 5, declaration.values[0] == "DIST", declaration.values[1] == "count",
                  declaration.values[3] == "width", try number(declaration.values[4], declaration) == width else {
                throw fail(declaration, "Distance declaration and width")
            }
            let count = try integer(declaration.values[2], declaration)
            guard count <= rows else { throw .limitExceeded(.rows) }
            try record(false, isCancelled)
            var caps: [Model.CapacitanceSample] = [], resistance: [Model.ResistanceSample] = []
            for _ in 0..<count {
                let line = try read(isCancelled)
                guard line.values.count == 4 else { throw fail(line, "Four numeric row columns required") }
                try record(true, isCancelled)
                let a = try number(line.values[0], line), b = try number(line.values[1], line)
                let c = try number(line.values[2], line), d = try number(line.values[3], line)
                if context.kind == .resOver {
                    resistance.append(.init(firstSpacingMicrons: a, secondSpacingMicrons: b,
                        fringeFemtofaradsPerNanometer: c, resistanceOhmsPerNanometer: d, sourceRange: line.line.range))
                } else {
                    caps.append(.init(distanceMicrons: a, couplingFemtofaradsPerNanometer: b,
                        fringeFemtofaradsPerNanometer: c, resistanceOhmsPerNanometer: d, sourceRange: line.line.range))
                }
            }
            let end = try read(isCancelled)
            guard end.values == ["END", "DIST"] else { throw fail(end, "DIST row count or terminator") }
            return .init(context: context, widthMicrons: width,
                         sourceRange: .init(lowerBound: contextLine.line.range.lowerBound, upperBound: end.line.range.upperBound),
                         capacitanceSamples: caps, resistanceSamples: resistance)
        }
    }
}
