import Foundation
import PEXCore
import PEXAdapters
import PEXParsers
import PEXPersistence

struct PEXPipeline: Sendable {
    let adapterRegistry: PEXAdapterRegistry
    let parserRegistry: PEXParserRegistry

    func validateRequest(_ request: PEXRunRequest) throws {
        if request.topCell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PEXError.invalidInput("topCell must not be empty")
        }
        if request.corners.isEmpty {
            throw PEXError.invalidInput("At least one corner must be specified")
        }
    }

    func resolveAdapter(for backendID: String) throws -> any PEXAdapter {
        guard let adapter = adapterRegistry.adapter(for: backendID) else {
            throw PEXError.adapterUnavailable(backendID: backendID)
        }
        return adapter
    }

    func resolveParser(for format: PEXOutputFormat) throws -> any PEXParserProtocol {
        guard let parser = parserRegistry.parser(for: format) else {
            throw PEXError(
                kind: .parseFailed,
                stage: .parsing,
                message: "No parser registered for format '\(format.rawValue)'"
            )
        }
        return parser
    }

    func executeCorner(
        adapter: any PEXAdapter,
        context: PEXExecutionContext
    ) async throws -> PEXRawOutput {
        try await adapter.prepare(context)
        let output = try await adapter.execute(context)
        return output
    }

    func parseOutput(
        raw: PEXRawOutput,
        context: PEXParseContext
    ) throws -> ParasiticIR {
        let parser = try resolveParser(for: raw.format)
        return try parser.parse(raw, context: context)
    }

    func validateIR(
        _ ir: ParasiticIR,
        strict: Bool
    ) throws -> (ir: ParasiticIR, warnings: [PEXWarning]) {
        let validator = ParasiticIRValidator()
        let result = validator.validate(ir)

        var warnings: [PEXWarning] = []
        for w in result.warnings {
            warnings.append(PEXWarning(
                stage: .irValidation,
                cornerID: ir.cornerID,
                message: String(describing: w)
            ))
        }

        if !result.isValid {
            if strict {
                throw PEXError.irValidationFailed(cornerID: ir.cornerID, errors: result.errors)
            }
            // In non-strict mode, report errors as warnings
            for e in result.errors {
                warnings.append(PEXWarning(
                    stage: .irValidation,
                    cornerID: ir.cornerID,
                    message: "Validation error (non-strict): \(String(describing: e))"
                ))
            }
        }

        return (ir, warnings)
    }
}
