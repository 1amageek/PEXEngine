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
        var cornerIDs: Set<PEXCornerID> = []
        for corner in request.corners {
            if corner.id.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PEXError.invalidInput("corner id must not be empty")
            }
            if corner.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PEXError.invalidInput("corner name must not be empty")
            }
            if !cornerIDs.insert(corner.id).inserted {
                throw PEXError.invalidInput("corner id '\(corner.id.value)' is duplicated")
            }
        }
        let requestedCornerIDs = Set(request.corners.map(\.id.value))
        for cornerID in request.technologyByCorner.keys {
            let normalizedCornerID = cornerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCornerID.isEmpty else {
                throw PEXError.invalidInput("technologyByCorner contains an empty corner ID")
            }
            guard normalizedCornerID == cornerID else {
                throw PEXError.invalidInput(
                    "technologyByCorner corner ID '\(cornerID)' contains surrounding whitespace"
                )
            }
            guard requestedCornerIDs.contains(normalizedCornerID) else {
                throw PEXError.invalidInput(
                    "technologyByCorner references unknown corner '\(cornerID)'"
                )
            }
        }
        if request.backendSelection.backendID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PEXError.invalidInput("backendID must not be empty")
        }
        if request.options.maxParallelJobs < 1 {
            throw PEXError.invalidInput("maxParallelJobs must be at least 1")
        }
        if let minCapacitanceF = request.options.minCapacitanceF,
           !minCapacitanceF.isFinite || minCapacitanceF < 0 {
            throw PEXError.invalidInput("minCapacitanceF must be finite and non-negative")
        }
        if let minResistanceOhm = request.options.minResistanceOhm,
           !minResistanceOhm.isFinite || minResistanceOhm < 0 {
            throw PEXError.invalidInput("minResistanceOhm must be finite and non-negative")
        }
    }

    func validateInputFiles(_ request: PEXRunRequest) throws {
        let inputs = [
            (label: "layout", url: request.layoutURL),
            (label: "source netlist", url: request.sourceNetlistURL),
        ]
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: input.url.path(percentEncoded: false),
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                throw PEXError.invalidInput(
                    "\(input.label) input is not an existing regular file: \(input.url.path(percentEncoded: false))"
                )
            }
        }
    }

    func resolveAdapter(for backendID: String) throws -> any PEXAdapter {
        guard let adapter = adapterRegistry.adapter(for: backendID) else {
            throw PEXError.adapterUnavailable(backendID: backendID)
        }
        return adapter
    }

    func resolveParser(for format: PEXOutputFormat) throws -> any PEXParsing {
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
    ) async throws -> PEXAdapterExecutionResult {
        try await adapter.prepare(context)
        return try await adapter.execute(context)
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
