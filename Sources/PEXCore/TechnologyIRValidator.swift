import Foundation

/// Validates technology semantics that JSON decoding alone cannot establish.
/// The validator is deliberately independent from any backend so it can be
/// used by CLI, library, and evaluation workflows consistently.
public struct TechnologyIRValidator: Sendable {
    public init() {}

    public func validate(_ technology: TechnologyIR) -> [TechnologyIRValidationIssue] {
        var issues: [TechnologyIRValidationIssue] = []
        let processName = technology.processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if processName.isEmpty {
            issues.append(issue("process_name_empty", "Process name is empty"))
        }

        if technology.stack.isEmpty {
            issues.append(issue("stack_empty", "No layers defined in technology stack"))
        }
        var layerNames: Set<String> = []
        var layerOrders: Set<Int> = []
        for layer in technology.stack {
            let name = layer.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append(issue("layer_name_empty", "Technology stack contains a layer with an empty name"))
            } else if !layerNames.insert(name).inserted {
                issues.append(issue("layer_name_duplicate", "Technology layer '\(name)' is declared more than once"))
            }
            if layer.order < 0 {
                issues.append(issue("layer_order_negative", "Technology layer '\(name)' has a negative order"))
            } else if !layerOrders.insert(layer.order).inserted {
                issues.append(issue("layer_order_duplicate", "Technology stack order \(layer.order) is declared more than once"))
            }
            if let thickness = layer.thickness, !thickness.isFinite || thickness <= 0 {
                issues.append(issue("layer_thickness_invalid", "Technology layer '\(name)' thickness must be finite and positive"))
            }
            if let resistivity = layer.resistivity, !resistivity.isFinite || resistivity <= 0 {
                issues.append(issue("layer_resistivity_invalid", "Technology layer '\(name)' resistivity must be finite and positive"))
            }
        }

        for (logical, physical) in technology.logicalToPhysicalLayerMap {
            if logical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || physical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(issue("layer_map_entry_empty", "Logical-to-physical layer map contains an empty key or value"))
            } else if !layerNames.isEmpty && !layerNames.contains(physical) {
                issues.append(issue("layer_map_target_unknown", "Layer map target '\(physical)' is not present in the technology stack"))
            }
        }

        var viaNames: Set<String> = []
        for via in technology.vias {
            let name = via.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                issues.append(issue("via_name_empty", "Technology vias contain a via with an empty name"))
            } else if !viaNames.insert(name).inserted {
                issues.append(issue("via_name_duplicate", "Technology via '\(name)' is declared more than once"))
            }
            if !layerNames.isEmpty {
                if !layerNames.contains(via.topLayer) {
                    issues.append(issue("via_top_layer_unknown", "Via '\(name)' top layer '\(via.topLayer)' is not in the technology stack"))
                }
                if !layerNames.contains(via.bottomLayer) {
                    issues.append(issue("via_bottom_layer_unknown", "Via '\(name)' bottom layer '\(via.bottomLayer)' is not in the technology stack"))
                }
            }
            if let resistance = via.resistance, !resistance.isFinite || resistance < 0 {
                issues.append(issue("via_resistance_invalid", "Via '\(name)' resistance must be finite and non-negative"))
            }
        }

        if let threshold = technology.defaultExtractionRules.minCapacitanceF,
           !threshold.isFinite || threshold < 0 {
            issues.append(issue("min_capacitance_invalid", "Default minimum capacitance must be finite and non-negative"))
        }
        if let threshold = technology.defaultExtractionRules.minResistanceOhm,
           !threshold.isFinite || threshold < 0 {
            issues.append(issue("min_resistance_invalid", "Default minimum resistance must be finite and non-negative"))
        }
        return issues
    }

    private func issue(_ code: String, _ message: String) -> TechnologyIRValidationIssue {
        TechnologyIRValidationIssue(code: code, message: message)
    }
}
