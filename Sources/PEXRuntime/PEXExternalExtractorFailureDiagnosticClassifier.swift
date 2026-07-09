import PEXCore

public struct PEXExternalExtractorFailureDiagnosticClassifier: Sendable {
    public init() {}

    public func classify(
        report: PEXExternalExtractorCorpusReport,
        readiness: [PEXEvidenceReadiness],
        diagnostics: [PEXEvidenceDiagnostic]
    ) -> [PEXFailureDiagnosticClassification] {
        let casesByID = Dictionary(report.cases.map { ($0.caseID, $0) }, uniquingKeysWith: { first, _ in first })
        var accumulators: [PEXFailureDiagnosticClass: Accumulator] = [:]

        for readinessItem in readiness where readinessItem.status != .ready {
            let failureClass: PEXFailureDiagnosticClass = readinessItem.status == .blocked
                ? .missingExtractorReadiness
                : .externalExtractorFailure
            accumulators[failureClass, default: Accumulator(failureClass: failureClass)]
                .add(
                    reasonCode: "readiness_\(readinessItem.status.rawValue)",
                    severity: readinessItem.status == .blocked ? .blocked : .warning,
                    artifactIDs: readinessItem.artifactIDs,
                    suggestedActions: readinessItem.suggestedActions
                )
        }

        for diagnostic in diagnostics {
            for failureClass in failureClasses(for: diagnostic) {
                let caseResult = diagnostic.caseID.flatMap { casesByID[$0] }
                accumulators[failureClass, default: Accumulator(failureClass: failureClass)]
                    .add(
                        diagnostic: diagnostic,
                        caseResult: caseResult,
                        metricIDs: metricIDs(for: diagnostic, caseResult: caseResult),
                        suggestedActions: suggestedActions(for: failureClass)
                    )
            }
        }

        for caseResult in report.cases where caseResult.status == "failed" {
            accumulators[.perCornerFailure, default: Accumulator(failureClass: .perCornerFailure)]
                .add(
                    reasonCodes: caseResult.failures.map(\.code) + ["case_status_failed"],
                    severity: .error,
                    caseID: caseResult.caseID,
                    cornerID: caseResult.corner,
                    metricIDs: caseResult.failures.compactMap(\.metric),
                    artifactIDs: artifactIDs(caseResult),
                    suggestedActions: suggestedActions(for: .perCornerFailure)
                )
        }

        for failure in report.qualification.failures {
            accumulators[.qualificationFailure, default: Accumulator(failureClass: .qualificationFailure)]
                .add(
                    reasonCodes: [failure.failureCode, failure.code].compactMap { $0 },
                    severity: .error,
                    caseID: failure.caseID,
                    cornerID: failure.caseID.flatMap { casesByID[$0]?.corner },
                    suggestedActions: suggestedActions(for: .qualificationFailure)
                )
        }

        return accumulators.values
            .map { $0.classification(backendID: report.oracleBackendID) }
            .sorted { $0.classificationID < $1.classificationID }
    }

    private func failureClasses(for diagnostic: PEXEvidenceDiagnostic) -> [PEXFailureDiagnosticClass] {
        var classes: [PEXFailureDiagnosticClass] = []
        let text = [
            diagnostic.code,
            diagnostic.category,
            diagnostic.message,
            diagnostic.observedText,
            diagnostic.expectedText,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if containsAny(text, ["readiness", "toolchain", "executable", "tool_not_found", "missing_tool", "extract_command_failed"]) {
            classes.append(.missingExtractorReadiness)
        }
        if containsAny(text, ["process_profile", "process profile", "pdk", "technology", "techfile"]) {
            classes.append(.processProfileError)
        }
        if containsAny(text, ["unit", "scale", "dimension"]) {
            classes.append(.unitMismatch)
        }
        if diagnostic.category == "normalization_failure" || containsAny(text, ["parse", "decode", "ir_read_failed", "spef_read_failed"]) {
            classes.append(.parseFailure)
        }
        if diagnostic.category == "physical_bound_mismatch"
            || containsAny(text, ["physical_bound_failed", "out_of_tolerance"])
        {
            classes.append(.physicalBoundMismatch)
        }
        if diagnostic.category == "qualification" {
            classes.append(.qualificationFailure)
        }
        if classes.isEmpty {
            classes.append(.externalExtractorFailure)
        }
        return Array(Set(classes)).sorted { $0.rawValue < $1.rawValue }
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func metricIDs(
        for diagnostic: PEXEvidenceDiagnostic,
        caseResult: PEXExternalExtractorCorpusReport.CaseResult?
    ) -> [String] {
        guard let caseResult else { return [] }
        return caseResult.failures
            .filter { $0.code == diagnostic.code }
            .compactMap(\.metric)
    }

    private func artifactIDs(_ caseResult: PEXExternalExtractorCorpusReport.CaseResult) -> [String] {
        var ids = caseResult.artifactRefs?.map(\.artifactID) ?? []
        if caseResult.manifestPath != nil {
            ids.append("\(caseResult.caseID):manifestPath")
        }
        if caseResult.irPath != nil {
            ids.append("\(caseResult.caseID):irPath")
        }
        if caseResult.layoutPath != nil {
            ids.append("\(caseResult.caseID):layoutPath")
        }
        return ids
    }

    private func suggestedActions(for failureClass: PEXFailureDiagnosticClass) -> [String] {
        switch failureClass {
        case .missingExtractorReadiness:
            return ["check_extractor_readiness_before_rerun", "inspect_extractor_command_output"]
        case .processProfileError:
            return ["inspect_process_profile_resolution", "inspect_pdk_and_technology_inputs"]
        case .parseFailure:
            return ["inspect_extractor_raw_output", "verify_output_format", "rerun_adapter_with_diagnostics"]
        case .unitMismatch:
            return ["check_extractor_units", "inspect_layer_unit_scaling", "compare_against_physical_bounds"]
        case .physicalBoundMismatch:
            return ["inspect_external_pex_physical_bounds", "inspect_top_parasitic_nets", "check_extractor_units"]
        case .perCornerFailure:
            return ["inspect_failed_corner_artifacts", "compare_corner_configuration", "rerun_failed_corners"]
        case .qualificationFailure:
            return ["inspect_external_pex_case_failures", "review_qualification_policy"]
        case .externalExtractorFailure:
            return ["inspect_external_pex_case_failures"]
        }
    }

    private struct Accumulator: Sendable {
        let failureClass: PEXFailureDiagnosticClass
        var severity: PEXEvidenceSeverity = .info
        var reasonCodes: [String] = []
        var caseIDs: [String] = []
        var cornerIDs: [String] = []
        var metricIDs: [String] = []
        var diagnosticIDs: [String] = []
        var artifactIDs: [String] = []
        var suggestedActions: [String] = []

        mutating func add(
            diagnostic: PEXEvidenceDiagnostic,
            caseResult: PEXExternalExtractorCorpusReport.CaseResult?,
            metricIDs: [String],
            suggestedActions: [String]
        ) {
            add(
                reasonCodes: [diagnostic.code],
                severity: diagnostic.severity,
                caseID: diagnostic.caseID,
                cornerID: caseResult?.corner,
                metricIDs: metricIDs,
                diagnosticIDs: [diagnostic.diagnosticID],
                artifactIDs: diagnostic.artifactIDs,
                suggestedActions: diagnostic.suggestedActions + suggestedActions
            )
        }

        mutating func add(
            reasonCode: String,
            severity: PEXEvidenceSeverity,
            artifactIDs: [String],
            suggestedActions: [String]
        ) {
            add(
                reasonCodes: [reasonCode],
                severity: severity,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions
            )
        }

        mutating func add(
            reasonCodes: [String],
            severity: PEXEvidenceSeverity,
            caseID: String? = nil,
            cornerID: String? = nil,
            metricIDs: [String] = [],
            diagnosticIDs: [String] = [],
            artifactIDs: [String] = [],
            suggestedActions: [String] = []
        ) {
            self.severity = maxSeverity(self.severity, severity)
            self.reasonCodes.append(contentsOf: reasonCodes.compactMap { $0 })
            if let caseID {
                self.caseIDs.append(caseID)
            }
            if let cornerID {
                self.cornerIDs.append(cornerID)
            }
            self.metricIDs.append(contentsOf: metricIDs)
            self.diagnosticIDs.append(contentsOf: diagnosticIDs)
            self.artifactIDs.append(contentsOf: artifactIDs)
            self.suggestedActions.append(contentsOf: suggestedActions)
        }

        func classification(backendID: String) -> PEXFailureDiagnosticClassification {
            PEXFailureDiagnosticClassification(
                classificationID: "external-extractor:\(backendID):\(failureClass.rawValue)",
                failureClass: failureClass,
                severity: severity,
                reasonCodes: reasonCodes,
                backendID: backendID,
                caseIDs: caseIDs,
                cornerIDs: cornerIDs,
                metricIDs: metricIDs,
                diagnosticIDs: diagnosticIDs,
                artifactIDs: artifactIDs,
                suggestedActions: suggestedActions
            )
        }

        private func maxSeverity(
            _ lhs: PEXEvidenceSeverity,
            _ rhs: PEXEvidenceSeverity
        ) -> PEXEvidenceSeverity {
            rank(rhs) > rank(lhs) ? rhs : lhs
        }

        private func rank(_ severity: PEXEvidenceSeverity) -> Int {
            switch severity {
            case .info:
                return 0
            case .warning:
                return 1
            case .error:
                return 2
            case .blocked:
                return 3
            }
        }
    }
}
