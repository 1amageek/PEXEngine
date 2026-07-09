import Testing
@testable import PEXCore
@testable import PEXParsers

@Suite("SPEF PEX parser boundary tests")
struct SPEFPEXParserBoundaryTests {
    @Test func rejectsWrongRawOutputFormat() throws {
        let context = PEXParseContext(
            cornerID: "tt",
            runID: PEXRunID(),
            technology: nil,
            options: .default
        )
        let raw = PEXRawOutput(format: .spice, fileURLs: [])

        do {
            _ = try SPEFPEXParser().parse(raw, context: context)
            Issue.record("Expected SPEF parser to reject non-SPEF raw output format")
        } catch let error as PEXError {
            #expect(error.kind == .parseFailed)
            #expect(error.message.contains("raw output format 'spice'"))
        } catch {
            Issue.record("Expected PEXError.parseFailed, got \(error)")
        }
    }
}
