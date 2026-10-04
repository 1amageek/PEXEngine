extension TechnologyIR {
    public func validateElectricalModels() throws(PEXElectricalModelError) {
        var cornerIDs = Set<PEXCornerID>()
        for model in electricalModels ?? [] {
            guard cornerIDs.insert(model.cornerID).inserted else { throw .duplicate(field: "electricalModels.cornerID") }
            try model.validate(in: self)
        }
    }

    public func electricalModel(for corner: PEXCorner) throws(PEXElectricalModelError) -> PEXElectricalModel {
        try validateElectricalModels()
        guard let model = electricalModels?.first(where: { $0.cornerID == corner.id }) else {
            throw .missing(field: "electricalModels.\(corner.id.value)")
        }
        if let celsius = corner.temperature {
            guard celsius.isFinite, celsius + 273.15 == model.temperatureKelvin else {
                throw .cornerMismatch(field: "temperatureKelvin")
            }
        }
        if let voltage = corner.voltage {
            guard voltage.isFinite, voltage == model.voltageVolts else { throw .cornerMismatch(field: "voltageVolts") }
        }
        guard corner.parameters == model.parameters else { throw .cornerMismatch(field: "parameters") }
        return model
    }
}
