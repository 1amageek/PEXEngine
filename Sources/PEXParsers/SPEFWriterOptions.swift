import Foundation

public struct SPEFWriterOptions: Sendable, Hashable {
    public let designName: String
    public let date: String
    public let vendor: String
    public let program: String
    public let spefVersion: String
    public let divider: String
    public let delimiter: String
    public let busDelimiterOpen: String
    public let busDelimiterClose: String
    public let capacitanceUnit: SPEFCapacitanceUnit
    public let resistanceUnit: SPEFResistanceUnit

    public init(
        designName: String = "PEXEngine",
        date: String = "1970-01-01",
        vendor: String = "PEXEngine",
        program: String = "PEXEngine",
        spefVersion: String = "IEEE 1481-1998",
        divider: String = "/",
        delimiter: String = ":",
        busDelimiterOpen: String = "[",
        busDelimiterClose: String = "]",
        capacitanceUnit: SPEFCapacitanceUnit = .picoFarad,
        resistanceUnit: SPEFResistanceUnit = .ohm
    ) {
        self.designName = designName
        self.date = date
        self.vendor = vendor
        self.program = program
        self.spefVersion = spefVersion
        self.divider = divider
        self.delimiter = delimiter
        self.busDelimiterOpen = busDelimiterOpen
        self.busDelimiterClose = busDelimiterClose
        self.capacitanceUnit = capacitanceUnit
        self.resistanceUnit = resistanceUnit
    }
}
