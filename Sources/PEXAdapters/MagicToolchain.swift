import Foundation

/// Locates an installed Magic + Sky130 PDK toolchain for parasitic extraction.
///
/// Returning `nil` from `locate()` — rather than substituting the mock — leaves
/// the decision to the caller; `MagicPEXAdapter` fails loudly when the toolchain
/// is unavailable instead of silently producing fabricated parasitics.
public struct MagicToolchain: Sendable {

    public let magicExecutableURL: URL
    public let rcFileURL: URL
    public let pdkRoot: String

    public init(magicExecutableURL: URL, rcFileURL: URL, pdkRoot: String) {
        self.magicExecutableURL = magicExecutableURL
        self.rcFileURL = rcFileURL
        self.pdkRoot = pdkRoot
    }

    /// The Tcl driver that extracts parasitics and writes a SPICE netlist.
    /// Inputs are passed via environment: `PEX_CELL`, `PEX_OUT`, `PEX_CTHRESH`,
    /// and optionally `PEX_GDS` (read before loading the cell).
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
    ext2spice cthresh $env(PEX_CTHRESH)
    ext2spice -o $env(PEX_OUT)
    puts "PEX_DONE"
    quit -noprompt
    """

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> MagicToolchain? {
        let magicPath = environment["MAGIC_BIN"]
            ?? NSString(string: "~/.local/magic/bin/magic").expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: magicPath) else { return nil }

        guard let pdkRoot = resolvePDKRoot(environment: environment, fileManager: fileManager) else {
            return nil
        }
        let rcFile = URL(filePath: pdkRoot)
            .appending(path: "sky130A/libs.tech/magic/sky130A.magicrc")
        guard fileManager.fileExists(atPath: rcFile.path(percentEncoded: false)) else { return nil }

        return MagicToolchain(
            magicExecutableURL: URL(filePath: magicPath),
            rcFileURL: rcFile,
            pdkRoot: pdkRoot
        )
    }

    private static func resolvePDKRoot(
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        if let root = environment["PDK_ROOT"], fileManager.fileExists(atPath: root) {
            return root
        }
        let versions = NSString(string: "~/.volare/volare/sky130/versions").expandingTildeInPath
        guard let entries = try? fileManager.contentsOfDirectory(atPath: versions) else { return nil }
        let builds = entries.filter { !$0.hasPrefix(".") }
        guard builds.count == 1 else { return nil }
        return versions + "/" + builds[0]
    }
}
