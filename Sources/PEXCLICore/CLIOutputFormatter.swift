import PEXEngine

public struct CLIOutputFormatter: Sendable {
    public init() {}

    public func formatResult(_ result: PEXRunResult) -> String {
        var lines: [String] = []

        lines.append("PEX Extraction Complete")
        lines.append("=======================")
        lines.append("Run ID:    \(result.runID)")
        lines.append("Status:    \(result.status.rawValue)")
        lines.append("Duration:  \(String(format: "%.2f", result.metrics.totalDurationSeconds))s")
        lines.append("Corners:   \(result.metrics.cornerCount) total, \(result.metrics.successCount) succeeded, \(result.metrics.failureCount) failed")
        lines.append("")

        for cr in result.cornerResults {
            let statusMark: String
            switch cr.status {
            case .success: statusMark = "[OK]"
            case .partialSuccess: statusMark = "[PARTIAL]"
            case .failed: statusMark = "[FAIL]"
            }
            lines.append("  \(statusMark) \(cr.cornerID): \(cr.metrics.netCount) nets, \(cr.metrics.elementCount) elements (\(String(format: "%.2f", cr.metrics.durationSeconds))s)")
        }

        if !result.warnings.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            for w in result.warnings {
                lines.append("  - [\(w.stage.rawValue)] \(w.message)")
            }
        }

        lines.append("")
        lines.append("Artifacts: \(result.artifacts.manifestURL.path(percentEncoded: false))")

        return lines.joined(separator: "\n")
    }
}
