import Foundation
import PEXCore
import SignoffToolSupport

/// Locates an installed Magic plus profile-declared PDK toolchain for parasitic extraction.
///
/// Returning `nil` from `locate()` — rather than substituting the mock — leaves
/// the decision to the caller; `MagicPEXAdapter` fails loudly when the toolchain
/// is unavailable instead of silently producing fabricated parasitics.
public struct MagicToolchain: Sendable {
    public static let magicRequirementID = "magic"

    public let magicExecutableURL: URL
    public let rcFileURL: URL
    public let pdkRoot: String
    public let profileID: String?
    public let pdkID: String?
    public let requirementID: String

    public init(
        magicExecutableURL: URL,
        rcFileURL: URL,
        pdkRoot: String,
        profileID: String? = nil,
        pdkID: String? = nil,
        requirementID: String = MagicToolchain.magicRequirementID
    ) {
        self.magicExecutableURL = magicExecutableURL
        self.rcFileURL = rcFileURL
        self.pdkRoot = pdkRoot
        self.profileID = profileID
        self.pdkID = pdkID
        self.requirementID = requirementID
    }

    public var processProfileReference: PEXProcessProfileReference {
        PEXProcessProfileReference(
            profileID: profileID,
            pdkID: pdkID,
            source: "SignoffPDKProfile",
            requirementID: requirementID,
            pdkRoot: pdkRoot,
            primaryDeckPath: rcFileURL.path(percentEncoded: false),
            metadata: [
                "tool": "magic",
                "deckRole": "extraction",
            ]
        )
    }

    /// The Tcl driver that extracts parasitics and writes a SPICE netlist.
    /// Inputs are passed via environment: `PEX_CELL`, `PEX_OUT`, `PEX_CTHRESH`,
    /// and optionally `PEX_GDS` (read before loading the cell). When
    /// `PEX_EXTRESIST == on`, resistance is also extracted (`extresist`).
    ///
    /// Resistance extraction requires `extresist threshold 0` (the default
    /// threshold lumps away every small resistor) and `select top cell` so
    /// `extresist all` targets the loaded cell rather than the empty (UNNAMED)
    /// cell. The parser groups the resulting resistor sub-nodes (Y/Y.n0/Y.t0...)
    /// back into one net.
    public static let extractionDriver = """
    # Headless parasitic extraction driver for PEXEngine.
    if {![info exists env(PEX_CELL)]} { puts "PEX_ERROR PEX_CELL not set"; quit -noprompt }
    set cell $env(PEX_CELL)
    if {[info exists env(PEX_GDS)]} {
        if {![file exists $env(PEX_GDS)]} { puts "PEX_ERROR gds not found: $env(PEX_GDS)"; quit -noprompt }
        gds read $env(PEX_GDS)
    }
    load $cell
    select top cell
    # Fail loud if the cell did not load (empty 1x1 placeholder) instead of
    # silently extracting nothing.
    lassign [box values] llx lly urx ury
    if {[expr {($urx - $llx) * ($ury - $lly)}] <= 1} {
        puts "PEX_ERROR cell not found or empty: $cell"
        quit -noprompt
    }
    extract do local
    extract all
    set extresist 0
    if {[info exists env(PEX_EXTRESIST)] && $env(PEX_EXTRESIST) eq "on"} {
        set extresist 1
        extresist threshold 0
        extresist tolerance 1
        extresist extout on
        extresist all
    }
    ext2spice cthresh $env(PEX_CTHRESH)
    if {$extresist} {
        ext2spice rthresh 0
        ext2spice extresist on
    }
    ext2spice -o $env(PEX_OUT)
    puts "PEX_DONE"
    quit -noprompt
    """

    public static func locate(
        profile: SignoffPDKProfile,
        requirementID: String = magicRequirementID,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MagicToolchain? {
        let magicPath = environment["MAGIC_BIN"]
            ?? NSString(string: "~/.local/magic/bin/magic").expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: magicPath) else { return nil }

        guard let pdkRoot = SignoffPDKLocator.root(
            requirementID: requirementID,
            profile: profile,
            environment: environment,
            fileManager: fileManager
        ) else { return nil }
        let rcFile: URL
        do {
            rcFile = try SignoffPDKLocator.requiredFileURL(
                in: pdkRoot,
                profile: profile,
                requirementID: requirementID
            )
        } catch {
            return nil
        }
        guard fileManager.fileExists(atPath: rcFile.path(percentEncoded: false)) else { return nil }

        return MagicToolchain(
            magicExecutableURL: URL(filePath: magicPath),
            rcFileURL: rcFile,
            pdkRoot: pdkRoot,
            profileID: profile.profileID,
            pdkID: profile.pdkID,
            requirementID: requirementID
        )
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MagicToolchain? {
        let profile: SignoffPDKProfile
        do {
            profile = try SignoffPDKProfile.bundledDefaultProfile()
        } catch {
            return nil
        }
        return locate(profile: profile, environment: environment, fileManager: fileManager)
    }
}
