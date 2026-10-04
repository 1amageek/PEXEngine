import Foundation
import Testing
import CircuiteFoundation
@testable import PEXCLICore
import PEXCore

@Suite("Native extract command admission", .timeLimit(.minutes(1)))
struct PEXNativeExtractCommandTests {
    @Test func directRequestLoadsTypedReferenceWithoutRewritingURLs() throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let artifactID = try ArtifactID(
            digest: ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "a", count: 64)),
            byteCount: 8
        )
        let calibration = PEXCalibrationInput(artifactID: artifactID, url: directory.appending(path: "calibration.json"))
        let reference = try PEXNativeInputReference(configurationURL: directory.appending(path: "model.json"), calibrations: [calibration])
        let url = directory.appending(path: "reference.json")
        try JSONEncoder().encode(reference).write(to: url)
        let command = try ExtractCommand(arguments: directArguments() + ["--corner", "tt", "--native-input", url.path])
        let request = try command.buildRequestFromDirectParams(#require(command.directParams))
        #expect(request.nativeInput == reference)
        #expect(request.corners.map(\.id) == ["tt"])
        #expect(request.options.maxParallelJobs == 2)
    }

    @Test func configReferenceResolvesAgainstConfigDirectoryAndCLIOverridesIt() async throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let first = try PEXNativeInputReference(configurationURL: directory.appending(path: "first.json"), calibrations: [])
        let second = try PEXNativeInputReference(configurationURL: directory.appending(path: "second.json"), calibrations: [])
        let firstURL = directory.appending(path: "reference.json")
        let secondURL = directory.appending(path: "override.json")
        try JSONEncoder().encode(first).write(to: firstURL)
        try JSONEncoder().encode(second).write(to: secondURL)
        let configURL = directory.appending(path: "project.json")
        try writeConfig(["backendID": "native", "corners": ["tt"], "inputs": ["nativeInput": "reference.json"]], to: configURL)
        let command = try ExtractCommand(arguments: ["--config", configURL.path])
        let request = try await command.buildRequestFromConfigFile(configURL)
        #expect(request.nativeInput == first)
        let overrideCommand = try ExtractCommand(arguments: ["--config", configURL.path, "--native-input", secondURL.path])
        let overrideRequest = try await overrideCommand.buildRequestFromConfigFile(configURL)
        #expect(overrideRequest.nativeInput == second)
    }

    @Test func directNativeRequiresReferenceAndExplicitUniqueNonemptyCorners() throws {
        for arguments in [
            directArguments(),
            directArguments() + ["--corner", " "],
            directArguments() + ["--corner", "tt", "--corner", " tt "],
            directArguments() + ["--corner", "tt"],
            directArguments() + ["--corner", "tt", "--native-input", ""],
        ] {
            expectInvalidInput {
                let command = try ExtractCommand(arguments: arguments)
                if let params = command.directParams { _ = try command.buildRequestFromDirectParams(params) }
            }
        }
    }

    @Test func nonNativeRejectsUnusedReferenceInDirectAndConfigModes() async throws {
        expectInvalidInput {
            let command = try ExtractCommand(arguments: directArguments(backend: "magic") + ["--native-input", "/missing/reference.json"])
            _ = try command.buildRequestFromDirectParams(#require(command.directParams))
        }
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let configURL = directory.appending(path: "project.json")
        try writeConfig(["backendID": "magic", "inputs": ["nativeInput": "unused.json"]], to: configURL)
        await expectInvalidInputAsync {
            let command = try ExtractCommand(arguments: ["--config", configURL.path])
            _ = try await command.buildRequestFromConfigFile(configURL)
        }
    }

    @Test func missingAndMalformedReferenceDocumentsFailWithTypedErrors() throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let url = directory.appending(path: "reference.json")
        let command = try ExtractCommand(arguments: directArguments() + ["--corner", "tt", "--native-input", url.path])
        let params = try #require(command.directParams)
        do {
            _ = try command.buildRequestFromDirectParams(params)
            Issue.record("Expected missing local document to fail")
        } catch let error as PEXError {
            #expect(error.kind == .persistenceFailed)
        }
        try Data("not JSON".utf8).write(to: url)
        expectInvalidInput { _ = try command.buildRequestFromDirectParams(params) }
    }

    @Test func referenceDecodeRejectsMissingFieldsNonlocalURLsAndBadBudgets() throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let reference = try PEXNativeInputReference(configurationURL: directory.appending(path: "model.json"), calibrations: [])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        var missingBudget = object
        missingBudget.removeValue(forKey: "maximumCalibrationBytes")
        var nonlocal = object
        nonlocal["configurationURL"] = "https://example.com/config.json"
        var zeroBudget = object
        zeroBudget["maximumConfigurationBytes"] = 0
        var wrongBudgetType = object
        wrongBudgetType["maximumCalibrationArtifacts"] = true
        let url = directory.appending(path: "reference.json")
        let command = try ExtractCommand(arguments: directArguments() + ["--corner", "tt", "--native-input", url.path])
        let params = try #require(command.directParams)
        for invalid in [missingBudget, nonlocal, zeroBudget, wrongBudgetType] {
            try writeConfig(invalid, to: url)
            expectInvalidInput { _ = try command.buildRequestFromDirectParams(params) }
        }
    }

    @Test func typedReferenceDecoderRejectsCalibrationIdentityAndBudgetViolations() throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let artifactID = try ArtifactID(
            digest: ContentDigest(algorithm: .sha256, hexadecimalValue: String(repeating: "a", count: 64)),
            byteCount: 8
        )
        let calibration = PEXCalibrationInput(artifactID: artifactID, url: directory.appending(path: "calibration.json"))
        let reference = try PEXNativeInputReference(configurationURL: directory.appending(path: "model.json"), calibrations: [calibration])
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
        var perArtifact = object
        perArtifact["maximumCalibrationBytes"] = 4
        var total = object
        total["maximumTotalCalibrationBytes"] = 4
        var duplicate = object
        let encodedCalibration = try #require((object["calibrations"] as? [[String: Any]])?.first)
        duplicate["calibrations"] = [encodedCalibration, encodedCalibration]
        var nonlocalCalibration = encodedCalibration
        nonlocalCalibration["url"] = "https://example.com/calibration.json"
        var nonlocal = object
        nonlocal["calibrations"] = [nonlocalCalibration]
        let url = directory.appending(path: "reference.json")
        let command = try ExtractCommand(arguments: directArguments() + ["--corner", "tt", "--native-input", url.path])
        let params = try #require(command.directParams)
        for invalid in [perArtifact, total, duplicate, nonlocal] {
            try writeConfig(invalid, to: url)
            expectInvalidInput { _ = try command.buildRequestFromDirectParams(params) }
        }
    }

    @Test func referenceDocumentReadHonorsFourMiBCeiling() throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let url = directory.appending(path: "reference.json")
        let reference = try PEXNativeInputReference(configurationURL: directory.appending(path: "model.json"), calibrations: [])
        var data = try JSONEncoder().encode(reference)
        data.append(Data(repeating: 0x20, count: PEXNativeInputLoader.maximumReferenceBytes - data.count))
        try data.write(to: url)
        let command = try ExtractCommand(arguments: directArguments() + ["--corner", "tt", "--native-input", url.path])
        let params = try #require(command.directParams)
        #expect(try command.buildRequestFromDirectParams(params).nativeInput == reference)
        data.append(0x20)
        try data.write(to: url)
        expectInvalidInput { _ = try command.buildRequestFromDirectParams(params) }
    }

    @Test func configRejectsMissingEmptyDuplicateAndWrongTypedNativeInputs() async throws {
        let invalid: [[String: Any]] = [
            ["backendID": "native"],
            ["backendID": "native", "corners": []],
            ["backendID": "native", "corners": [" "]],
            ["backendID": "native", "corners": ["tt", " tt "]],
            ["backendID": "native", "corners": "tt"],
            ["backendID": "native", "corners": ["tt", 1]],
            ["backendID": "native", "corners": ["tt"]],
            ["backendID": "native", "corners": ["tt"], "inputs": ["nativeInput": ""]],
            ["backendID": "native", "corners": ["tt"], "inputs": ["nativeInput": false]],
            ["backendID": "native", "corners": ["tt"], "inputs": []],
        ]
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let configURL = directory.appending(path: "project.json")
        for object in invalid {
            try writeConfig(object, to: configURL)
            await expectInvalidInputAsync {
                let command = try ExtractCommand(arguments: ["--config", configURL.path])
                _ = try await command.buildRequestFromConfigFile(configURL)
            }
        }
    }

    @Test func nativeOptionsPreserveNumbersAndRejectBooleanCoercionFractionAndOverflow() async throws {
        let directory = try temporaryDirectory()
        defer { remove(directory) }
        let reference = try PEXNativeInputReference(configurationURL: directory.appending(path: "model.json"), calibrations: [])
        let referenceURL = directory.appending(path: "reference.json")
        try JSONEncoder().encode(reference).write(to: referenceURL)
        let configURL = directory.appending(path: "project.json")
        var object: [String: Any] = ["backendID": "native", "corners": ["tt"], "inputs": ["nativeInput": "reference.json"]]
        object["options"] = ["maxParallelJobs": 1, "includeCouplingCaps": false, "minResistanceOhm": 1]
        try writeConfig(object, to: configURL)
        let command = try ExtractCommand(arguments: ["--config", configURL.path])
        let request = try await command.buildRequestFromConfigFile(configURL)
        #expect(request.options.maxParallelJobs == 1)
        #expect(request.options.minResistanceOhm == 1)
        #expect(request.options.includeCouplingCaps == false)
        let invalidOptions: [[String: Any]] = [
            ["maxParallelJobs": true], ["maxParallelJobs": 1.5], ["maxParallelJobs": 1e100],
            ["maxParallelJobs": 0], ["maxParallelJobs": "2"],
            ["includeCouplingCaps": 1], ["strictValidation": 0], ["minResistanceOhm": true],
            ["minCapacitanceF": "1e-15"], ["minCapacitanceF": -1], ["sourceConnectivityPolicy": "invalid"],
        ]
        for options in invalidOptions {
            object["options"] = options
            try writeConfig(object, to: configURL)
            await expectInvalidInputAsync { _ = try await command.buildRequestFromConfigFile(configURL) }
        }
    }

    @Test func directThresholdsRejectNonfiniteAndNegativeValues() {
        for value in ["nan", "inf", "-1", "1e1000"] {
            expectInvalidInput {
                _ = try ExtractCommand(arguments: directArguments() + ["--corner", "tt", "--min-cap-f", value])
            }
        }
    }

    private func directArguments(backend: String = "native") -> [String] {
        ["--layout", "/tmp/layout.gds", "--netlist", "/tmp/netlist.sp", "--top-cell", "TOP", "--technology", "/tmp/technology.json", "--backend", backend]
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pex-native-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeConfig(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func remove(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch { Issue.record("Temporary directory cleanup failed: \(error)") }
    }

    private func expectInvalidInput(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected native request admission to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            Issue.record("Expected typed invalidInput: \(error)")
        }
    }

    private func expectInvalidInputAsync(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected native request admission to fail")
        } catch let error as PEXError {
            #expect(error.kind == .invalidInput)
        } catch {
            Issue.record("Expected typed invalidInput: \(error)")
        }
    }
}
