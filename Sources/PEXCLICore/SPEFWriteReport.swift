import Foundation
import PEXEngine

public struct SPEFWriteReport: Codable, Sendable, Equatable {
    public let status: String
    public let inputPath: String
    public let inputSHA256: String
    public let inputByteCount: Int
    public let outputPath: String
    public let outputSHA256: String
    public let outputByteCount: Int
    public let reportPath: String?
    public let cornerID: String
    public let netCount: Int
    public let nodeCount: Int
    public let elementCount: Int
    public let validationStatus: String
    public let validationErrorCount: Int
    public let validationWarningCount: Int
    public let roundTrip: SPEFWriteRoundTripReport?

    public init(
        status: String,
        inputPath: String,
        inputSHA256: String,
        inputByteCount: Int,
        outputPath: String,
        outputSHA256: String,
        outputByteCount: Int,
        reportPath: String?,
        cornerID: String,
        netCount: Int,
        nodeCount: Int,
        elementCount: Int,
        validationStatus: String,
        validationErrorCount: Int,
        validationWarningCount: Int,
        roundTrip: SPEFWriteRoundTripReport?
    ) {
        self.status = status
        self.inputPath = inputPath
        self.inputSHA256 = inputSHA256
        self.inputByteCount = inputByteCount
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.outputByteCount = outputByteCount
        self.reportPath = reportPath
        self.cornerID = cornerID
        self.netCount = netCount
        self.nodeCount = nodeCount
        self.elementCount = elementCount
        self.validationStatus = validationStatus
        self.validationErrorCount = validationErrorCount
        self.validationWarningCount = validationWarningCount
        self.roundTrip = roundTrip
    }
}

public struct SPEFWriteRoundTripReport: Codable, Sendable, Equatable {
    public let status: String
    public let cornerID: String
    public let netCount: Int
    public let nodeCount: Int
    public let elementCount: Int
    public let validationStatus: String
    public let validationErrorCount: Int
    public let validationWarningCount: Int
    public let semanticStatus: String
    public let semanticViolationCount: Int

    public init(
        status: String,
        cornerID: String,
        netCount: Int,
        nodeCount: Int,
        elementCount: Int,
        validationStatus: String,
        validationErrorCount: Int,
        validationWarningCount: Int,
        semanticStatus: String,
        semanticViolationCount: Int
    ) {
        self.status = status
        self.cornerID = cornerID
        self.netCount = netCount
        self.nodeCount = nodeCount
        self.elementCount = elementCount
        self.validationStatus = validationStatus
        self.validationErrorCount = validationErrorCount
        self.validationWarningCount = validationWarningCount
        self.semanticStatus = semanticStatus
        self.semanticViolationCount = semanticViolationCount
    }
}
