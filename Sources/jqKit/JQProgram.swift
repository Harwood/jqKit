import Cjq
import Coniguruma
import Foundation

// MARK: - JQProgram

/// A compiled jq program that can be applied repeatedly to JSON inputs.
///
/// Initialisation compiles the jq expression once; subsequent calls to
/// ``run(json:pretty:rawStrings:indent:)`` reuse the compiled state.
/// The underlying jq state processes one input at a time — concurrent
/// invocations are serialised via an internal lock. For high-throughput
/// parallel use, create one `JQProgram` per concurrent call site.
///
/// ```swift
/// let program = try JQProgram(expression: ".[] | .name")
/// let names   = try program.run(json: #"[{"name":"Alice"},{"name":"Bob"}]"#)
/// // names == ["Alice", "Bob"]
/// ```
public final class JQProgram: @unchecked Sendable {

    // MARK: - Public

    /// The jq expression this program was compiled from.
    public let expression: String

    /// Compiles `expression` and retains the compiled state for repeated use.
    ///
    /// - Throws: ``JQError/initializationFailed`` if the jq runtime cannot
    ///   allocate state (OOM), or ``JQError/compilationFailed(_:)`` if the
    ///   expression contains a syntax error.
    public init(expression: String) throws {
        self.expression = expression

        guard let s = jq_init() else {
            throw JQError.initializationFailed
        }
        state = s

        // Collect compilation error messages via a C callback.
        // We pass a typed pointer to a local [String] buffer as the context.
        var errorMessages: [String] = []
        try withUnsafeMutablePointer(to: &errorMessages) { ptr in
            jq_set_error_cb(state, JQProgram.compilationErrorCallback, ptr)
            defer { jq_set_error_cb(state, nil, nil) }

            guard jq_compile(state, expression) != 0 else {
                jq_teardown(&self.state)
                throw JQError.compilationFailed(errorMessages.joined(separator: "\n"))
            }
        }

        // Disable debug and input callbacks — not needed.
        jq_set_debug_cb(state, nil, nil)
        jq_set_input_cb(state, nil, nil)
    }

    deinit {
        jq_teardown(&state)
    }

    /// Runs the compiled program against `json` and returns all emitted values.
    ///
    /// - Parameters:
    ///   - json: A valid JSON string to process.
    ///   - pretty: If `true` (default), output is pretty-printed with indentation.
    ///   - rawStrings: If `true` (default), string values are returned without JSON
    ///     quoting — e.g. `hello` instead of `"hello"`.
    ///   - indent: Spaces per indent level (0–7). Only used when `pretty` is `true`.
    /// - Returns: All values emitted by the jq program, one entry per output.
    /// - Throws: ``JQError/invalidJSON(_:)`` if `json` is not valid,
    ///   or ``JQError/processingFailed(_:)`` if the program raises an error.
    public func run(
        json: String,
        pretty: Bool = true,
        rawStrings: Bool = true,
        indent: Int = 2
    ) throws -> [String] {
        // Parse the input outside the lock — jv_parse is stateless.
        let input = jv_parse(json)
        guard jv_is_valid(input) != 0 else {
            let msgJV = jv_invalid_get_msg(input)   // consumes `input`
            defer { jv_free(msgJV) }
            let msg = jv_get_kind(msgJV) == JV_KIND_STRING
                ? String(cString: jv_string_value(msgJV))
                : "malformed JSON"
            throw JQError.invalidJSON(msg)
        }

        // Serialise access to the shared jq state.
        lock.lock()
        defer {
            // Reset state by feeding jv_null, then release lock.
            jq_start(state, jv_null(), 0)
            lock.unlock()
        }

        jq_start(state, input, 0)   // jq_start takes ownership of `input`

        let flags = printFlags(pretty: pretty, indent: indent)
        var results: [String] = []

        // Drain all emitted values.
        var current = jq_next(state)
        while jv_is_valid(current) != 0 {
            results.append(stringify(current, rawStrings: rawStrings, flags: flags))
            // stringify consumes `current`, so fetch the next one.
            current = jq_next(state)
        }

        // Determine why the loop ended.
        if jq_halted(state) != 0 {
            let exitJV = jq_get_exit_code(state)
            let exitCode: Int
            if jv_get_kind(exitJV) == JV_KIND_NUMBER {
                exitCode = Int(jv_number_value(exitJV))
            } else {
                exitCode = 0
            }
            jv_free(exitJV)

            if exitCode != 0 {
                let errJV = jq_get_error_message(state)
                defer { jv_free(errJV) }
                let msg = jv_get_kind(errJV) == JV_KIND_STRING
                    ? String(cString: jv_string_value(errJV))
                    : "halt_error(\(exitCode))"
                jv_free(current)
                throw JQError.processingFailed(msg)
            }
            // Normal halt (exit code 0) — return collected results.
            jv_free(current)
            return results
        }

        if jv_invalid_has_msg(jv_copy(current)) != 0 {
            let msgJV = jv_invalid_get_msg(current)   // consumes `current`
            defer { jv_free(msgJV) }
            let msg = jv_get_kind(msgJV) == JV_KIND_STRING
                ? String(cString: jv_string_value(msgJV))
                : "unknown jq error"
            throw JQError.processingFailed(msg)
        }

        jv_free(current)
        return results
    }

    // MARK: - Private

    private var state: OpaquePointer?
    private let lock = NSLock()

    /// C-compatible compilation error callback. Appends each error message to
    /// the `[String]` buffer whose pointer is passed as `ctx`.
    private static let compilationErrorCallback: jq_err_cb = { ctx, msg in
        guard let ctx else { return }
        if jv_get_kind(msg) == JV_KIND_STRING {
            ctx.assumingMemoryBound(to: [String].self)
               .pointee
               .append(String(cString: jv_string_value(msg)))
        }
        jv_free(msg)
    }

    /// Converts a jv value to a String and frees the jv.
    private func stringify(_ value: jv, rawStrings: Bool, flags: Int32) -> String {
        if rawStrings, jv_get_kind(value) == JV_KIND_STRING {
            let s = String(cString: jv_string_value(value))
            jv_free(value)
            return s
        }
        let dumped = jv_dump_string(value, flags)
        let s = String(cString: jv_string_value(dumped))
        jv_free(dumped)
        return s
    }

    /// Builds jv print flags from the caller's preferences.
    private func printFlags(pretty: Bool, indent: Int) -> Int32 {
        guard pretty else { return 0 }
        // JV_PRINT_PRETTY = 1; JV_PRINT_INDENT_FLAGS(n) = n << 8
        return 1 | (Int32(min(max(indent, 0), 7)) << 8)
    }
}

// MARK: - Convenience

/// One-shot convenience: compiles `expression`, runs it against `json`,
/// and returns all emitted values joined by newlines.
///
/// When reusing the same expression on multiple inputs, prefer ``JQProgram``
/// directly to avoid recompiling the expression each time.
public func jqRun(
    _ json: String,
    expression: String,
    pretty: Bool = true,
    rawStrings: Bool = true,
    indent: Int = 2
) throws -> String {
    let program = try JQProgram(expression: expression)
    return try program.run(json: json, pretty: pretty, rawStrings: rawStrings, indent: indent)
        .joined(separator: "\n")
}
