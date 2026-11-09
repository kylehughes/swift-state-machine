import StateMachineTestSupport
import Testing

/// Serializes a test against every other test, in any suite or target, that parks a
/// cooperative-pool thread.
struct ParksCooperativeThreadTrait: TestTrait, SuiteTrait, TestScoping {
    /// Applies the scope to each test in a suite rather than to the suite as a whole.
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await withExclusiveCooperativeThreadHold(function)
    }
}

extension Trait where Self == ParksCooperativeThreadTrait {
    /// Declares that the test blocks a cooperative-pool thread until its own body releases it.
    static var parksCooperativeThread: Self { Self() }
}
