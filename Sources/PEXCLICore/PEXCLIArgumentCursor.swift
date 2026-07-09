import PEXEngine

struct PEXCLIArgumentCursor: Sendable {
    private let arguments: [String]
    private var index = 0

    init(arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func requireValue(for option: String) throws -> String {
        guard let value = next(), !value.isEmpty, !value.hasPrefix("-") else {
            throw PEXError.invalidInput("\(option) requires a value")
        }
        return value
    }
}
