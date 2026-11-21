/// A failed expectation of a `StateMachineTesting` helper, with the source location of the call.
///
/// Helpers throw it instead of recording an issue, so they work with any test framework: Swift
/// Testing and XCTest both report a thrown error as a failure of the test that threw it, and the
/// description begins with the location of the helper call.
nonisolated public struct StateMachineTestFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// What the helper expected and what it observed instead.
    public let message: String
    /// The `#fileID` of the helper call.
    public let fileID: String
    /// The `#filePath` of the helper call.
    public let filePath: String
    /// The line of the helper call.
    public let line: Int
    /// The column of the helper call.
    public let column: Int

    /// Describes a failed expectation at a source location, which defaults to the caller's.
    public init(
        _ message: String,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        self.message = message
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
    }

    /// The location of the helper call, then the message.
    public var description: String { "\(fileID):\(line):\(column): \(message)" }
}
