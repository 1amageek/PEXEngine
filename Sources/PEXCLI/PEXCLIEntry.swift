import PEXCLICore

@main
struct PEXCLIEntry {
    static func main() async {
        await CLIRouter.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
}
