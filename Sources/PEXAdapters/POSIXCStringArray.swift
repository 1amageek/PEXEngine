import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

final class POSIXCStringArray {
    private var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ strings: [String]) throws {
        for string in strings {
            guard let pointer = strdup(string) else {
                throw ProcessLaunchError.posixFailure(operation: "strdup", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }

    func withUnsafeMutablePointers<R>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
    ) throws -> R {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ProcessLaunchError.posixFailure(operation: "argv buffer", code: EINVAL)
            }
            return try body(baseAddress)
        }
    }
}

enum ProcessLaunchError: Error, CustomStringConvertible {
    case posixFailure(operation: String, code: Int32)
    case unsupportedPlatform

    var description: String {
        switch self {
        case .posixFailure(let operation, let code):
            return "\(operation) failed with errno \(code): \(String(cString: strerror(code)))"
        case .unsupportedPlatform:
            return "Process groups are not supported on this platform"
        }
    }
}
