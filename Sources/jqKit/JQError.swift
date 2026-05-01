/// Errors thrown by ``JQProgram`` and the ``jqRun(_:expression:)`` convenience function.
public enum JQError: Error, LocalizedError, Sendable {
    /// The jq runtime state could not be allocated (extremely unlikely; out of memory).
    case initializationFailed
    /// The jq expression failed to compile. The associated value is the compiler's error message.
    case compilationFailed(String)
    /// The JSON input could not be parsed. The associated value is the parse error.
    case invalidJSON(String)
    /// The jq program halted with an error or raised an uncaught exception.
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .initializationFailed:
            "Failed to initialise jq state (out of memory?)."
        case .compilationFailed(let message):
            "jq compile error: \(message)"
        case .invalidJSON(let message):
            "Invalid JSON: \(message)"
        case .processingFailed(let message):
            "jq error: \(message)"
        }
    }
}
