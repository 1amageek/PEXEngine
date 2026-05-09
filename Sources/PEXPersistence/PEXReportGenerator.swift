import Foundation
import PEXCore

public struct PEXReportGenerator: Sendable {
    public init() {}

    public func generateSummary(result: PEXRunResult) -> String {
        generateSummary(
            cornerResults: result.cornerResults,
            status: result.status,
            runID: result.runID,
            requestHash: result.requestHash,
            metrics: result.metrics,
            warnings: result.warnings
        )
    }

    public func generateSummary(
        cornerResults: [PEXCornerResult],
        status: PEXRunStatus,
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        metrics: PEXRunMetrics,
        warnings: [PEXWarning]
    ) -> String {
        var lines: [String] = []

        lines.append("# PEX Extraction Summary")
        lines.append("")
        lines.append("| Field | Value |")
        lines.append("|-------|-------|")
        lines.append("| Run ID | `\(runID)` |")
        lines.append("| Request Hash | `\(requestHash)` |")
        lines.append("| Status | \(status.rawValue) |")
        lines.append("| Duration | \(String(format: "%.2f", metrics.totalDurationSeconds))s |")
        lines.append("| Corners | \(metrics.cornerCount) (\(metrics.successCount) succeeded, \(metrics.failureCount) failed) |")
        lines.append("")

        // Per-corner table
        lines.append("## Corner Results")
        lines.append("")
        lines.append("| Corner | Status | Nets | Elements | Duration |")
        lines.append("|--------|--------|------|----------|----------|")
        for cr in cornerResults {
            lines.append("| \(cr.cornerID) | \(cr.status.rawValue) | \(cr.metrics.netCount) | \(cr.metrics.elementCount) | \(String(format: "%.2f", cr.metrics.durationSeconds))s |")
        }
        lines.append("")

        // Top nets by capacitance (from first successful corner)
        if let firstSuccess = cornerResults.first(where: { $0.status == .success }),
           let ir = firstSuccess.ir {
            let topNets = ir.nets.sorted { $0.totalGroundCapF + $0.totalCouplingCapF > $1.totalGroundCapF + $1.totalCouplingCapF }
                .prefix(10)

            if !topNets.isEmpty {
                lines.append("## Top Nets by Total Capacitance (\(firstSuccess.cornerID))")
                lines.append("")
                lines.append("| Net | Ground Cap (F) | Coupling Cap (F) | Resistance (Ohm) |")
                lines.append("|-----|----------------|------------------|-------------------|")
                for net in topNets {
                    lines.append("| \(net.name) | \(formatEngineering(net.totalGroundCapF)) | \(formatEngineering(net.totalCouplingCapF)) | \(formatEngineering(net.totalResistanceOhm)) |")
                }
                lines.append("")
            }
        }

        // Warnings
        if !warnings.isEmpty {
            lines.append("## Warnings")
            lines.append("")
            for warning in warnings {
                lines.append("- [\(warning.stage.rawValue)] \(warning.message)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatEngineering(_ value: Double) -> String {
        if value == 0 { return "0" }
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""

        if absValue >= 1e9 { return "\(sign)\(String(format: "%.3f", absValue / 1e9))G" }
        if absValue >= 1e6 { return "\(sign)\(String(format: "%.3f", absValue / 1e6))M" }
        if absValue >= 1e3 { return "\(sign)\(String(format: "%.3f", absValue / 1e3))k" }
        if absValue >= 1 { return "\(sign)\(String(format: "%.3f", absValue))" }
        if absValue >= 1e-3 { return "\(sign)\(String(format: "%.3f", absValue * 1e3))m" }
        if absValue >= 1e-6 { return "\(sign)\(String(format: "%.3f", absValue * 1e6))u" }
        if absValue >= 1e-9 { return "\(sign)\(String(format: "%.3f", absValue * 1e9))n" }
        if absValue >= 1e-12 { return "\(sign)\(String(format: "%.3f", absValue * 1e12))p" }
        if absValue >= 1e-15 { return "\(sign)\(String(format: "%.3f", absValue * 1e15))f" }
        return "\(sign)\(String(format: "%.3e", absValue))"
    }
}
