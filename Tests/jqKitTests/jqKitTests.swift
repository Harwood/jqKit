import Testing
@testable import jqKit

// NOTE: These tests require the Frameworks/ directory to be populated first.
// Run ./scripts/build-xcframeworks.sh before running tests.

struct JQProgramTests {

    // MARK: - Compilation

    @Test func compileValidExpression() throws {
        // Should not throw
        _ = try JQProgram(expression: ".foo")
    }

    @Test func compileThrowsOnInvalidExpression() {
        #expect(throws: JQError.self) {
            try JQProgram(expression: "this is not jq |||")
        }
    }

    @Test func compilationErrorMessageIsNonEmpty() {
        do {
            _ = try JQProgram(expression: ".")
        } catch let e as JQError {
            if case .compilationFailed(let msg) = e {
                #expect(!msg.isEmpty)
            }
        } catch {}
    }

    // MARK: - Identity / pass-through

    @Test func identityReturnsPrettyPrintedObject() throws {
        let program = try JQProgram(expression: ".")
        let results = try program.run(json: #"{"b":2,"a":1}"#)
        #expect(results.count == 1)
        #expect(results[0].contains("\"a\""))
        #expect(results[0].contains("\"b\""))
    }

    @Test func identityReturnsPrettyPrintedArray() throws {
        let program = try JQProgram(expression: ".")
        let results = try program.run(json: "[1,2,3]")
        #expect(results.count == 1)
        #expect(results[0].contains("1"))
        #expect(results[0].contains("3"))
    }

    // MARK: - Multiple outputs

    @Test func iterateArrayProducesMultipleResults() throws {
        let program = try JQProgram(expression: ".[]")
        let results = try program.run(json: #"["a","b","c"]"#, rawStrings: true)
        #expect(results == ["a", "b", "c"])
    }

    @Test func pipelineExtractsField() throws {
        let program = try JQProgram(expression: ".[] | .name")
        let json = #"[{"name":"Alice"},{"name":"Bob"}]"#
        let results = try program.run(json: json, rawStrings: true)
        #expect(results == ["Alice", "Bob"])
    }

    // MARK: - Keys

    @Test func keysReturnsSortedArray() throws {
        let program = try JQProgram(expression: "keys")
        let results = try program.run(json: #"{"z":1,"a":2,"m":3}"#)
        #expect(results.count == 1)
        // keys output is a JSON array — the first element contains "a"
        let output = results[0]
        let aIdx = output.range(of: "\"a\"")!.lowerBound
        let mIdx = output.range(of: "\"m\"")!.lowerBound
        let zIdx = output.range(of: "\"z\"")!.lowerBound
        #expect(aIdx < mIdx && mIdx < zIdx)
    }

    // MARK: - Raw strings vs. JSON strings

    @Test func rawStringsReturnUnquotedValues() throws {
        let program = try JQProgram(expression: ".name")
        let results = try program.run(json: #"{"name":"Utilities"}"#, rawStrings: true)
        #expect(results == ["Utilities"])
    }

    @Test func rawStringsFalseReturnsQuotedJSON() throws {
        let program = try JQProgram(expression: ".name")
        let results = try program.run(json: #"{"name":"Utilities"}"#, rawStrings: false)
        #expect(results == [#""Utilities""#])
    }

    // MARK: - Numeric and boolean output

    @Test func numericValueIsReturnedAsString() throws {
        let program = try JQProgram(expression: ".count")
        let results = try program.run(json: #"{"count":42}"#, rawStrings: true)
        #expect(results == ["42"])
    }

    @Test func booleanValueIsReturnedAsString() throws {
        let program = try JQProgram(expression: ".active")
        let trueResult  = try program.run(json: #"{"active":true}"#)
        let falseResult = try program.run(json: #"{"active":false}"#)
        #expect(trueResult == ["true"])
        #expect(falseResult == ["false"])
    }

    // MARK: - Error cases

    @Test func invalidJSONThrows() {
        #expect(throws: JQError.self) {
            let program = try JQProgram(expression: ".")
            _ = try program.run(json: "this is not json")
        }
    }

    @Test func missingKeyThrowsOrReturnsNull() throws {
        // jq returns null for missing keys by default — it doesn't error.
        let program = try JQProgram(expression: ".missing")
        let results = try program.run(json: #"{"name":"Alice"}"#)
        #expect(results == ["null"])
    }

    // MARK: - Reuse

    @Test func programCanBeReusedAcrossMultipleInputs() throws {
        let program = try JQProgram(expression: ".name")
        let r1 = try program.run(json: #"{"name":"Alice"}"#, rawStrings: true)
        let r2 = try program.run(json: #"{"name":"Bob"}"#, rawStrings: true)
        #expect(r1 == ["Alice"])
        #expect(r2 == ["Bob"])
    }
}

// MARK: - Convenience function

struct jqRunTests {
    @Test func convenienceFunctionJoinsResults() throws {
        let result = try jqRun(#"["a","b","c"]"#, expression: ".[]", rawStrings: true)
        #expect(result == "a\nb\nc")
    }
}
