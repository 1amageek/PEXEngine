import CircuiteFoundation
import CircuiteFoundationCrypto
import CryptoKit
import Foundation
import PEXCore

public enum PEXTestExecutionIdentity {
    public static func manifest(
        version: Int = PEXArtifactManifest.currentVersion,
        runID: PEXRunID,
        requestHash: PEXRequestHash,
        backendID: String,
        status: PEXRunStatus,
        startedAt: Date,
        finishedAt: Date,
        corners: [PEXArtifactCorner],
        artifacts: [PEXArtifactRecord],
        warnings: [PEXWarning],
        extractorRun: PEXExtractorRunResult? = nil,
        resumedFromRunID: PEXRunID? = nil,
        backendExecutions: [PEXBackendExecutionIdentity] = [],
        provenance: ExecutionProvenance? = nil
    ) throws -> PEXArtifactManifest {
        let resolvedProvenance = try provenance ?? self.provenance(
            backendID: backendID,
            inputs: artifacts.compactMap(\.reference),
            startedAt: startedAt,
            finishedAt: finishedAt
        )
        let evidence = try EvidenceManifest.contentAddressed(
            provenance: resolvedProvenance,
            artifacts: artifacts.compactMap(\.reference),
            digester: SHA256ContentDigester()
        )
        return try PEXArtifactManifest(
            version: version,
            runID: runID,
            requestHash: requestHash,
            backendID: backendID,
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            corners: corners,
            artifacts: artifacts,
            warnings: warnings,
            extractorRun: extractorRun,
            resumedFromRunID: resumedFromRunID,
            backendExecutions: backendExecutions,
            provenance: resolvedProvenance,
            evidence: evidence
        )
    }

    public static func make(
        backendID: String,
        version: String = "test"
    ) throws -> PEXBackendExecutionIdentity {
        let digest = try ContentDigest(
            algorithm: .sha256,
            hexadecimalValue: SHA256.hash(data: Data("\(backendID):\(version)".utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let producer = try ProducerIdentity(
            kind: .tool,
            identifier: "pex-\(backendID)",
            version: version,
            build: digest.hexadecimalValue
        )
        return try PEXBackendExecutionIdentity(
            producer: producer,
            binaryDigest: digest,
            invocation: ExecutionInvocation.inProcess(entryPoint: "PEXTestSupport.\(backendID)"),
            environment: ExecutionEnvironmentFingerprint(
                platform: "test",
                architecture: "test",
                toolchain: version
            )
        )
    }

    public static func provenance(
        backendID: String = "mock",
        version: String = "test",
        inputs: [ArtifactReference] = [],
        startedAt: Date,
        finishedAt: Date
    ) throws -> ExecutionProvenance {
        let identity = try make(backendID: backendID, version: version)
        return try ExecutionProvenance(
            producer: identity.producer,
            inputs: inputs,
            invocation: identity.invocation,
            environment: identity.environment,
            startedAt: startedAt,
            completedAt: finishedAt
        )
    }
}
