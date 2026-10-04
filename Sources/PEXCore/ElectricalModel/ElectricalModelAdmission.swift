import Foundation

enum ElectricalModelAdmission {
    static func identity(_ value: String, field: String) throws(PEXElectricalModelError) {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw .invalidIdentity(field: field)
        }
    }

    static func number(_ value: Double, field: String, positive: Bool = false) throws(PEXElectricalModelError) {
        guard value.isFinite, positive ? value > 0 : value >= 0 else {
            throw .invalidNumber(field: field)
        }
    }
}
