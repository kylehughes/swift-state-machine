import Foundation

/// A profile key validated at every construction and decoding boundary.
nonisolated public struct UserID: Codable, Equatable, Sendable {
    /// The nonempty, whitespace-free identifier.
    public let rawValue: String
    /// An invalid user identifier.
    public enum ValidationFailure: Error, Sendable { case invalidIdentifier }
    /// Validates a user identifier.
    public init(_ rawValue: String) throws(ValidationFailure) {
        guard !rawValue.isEmpty, !rawValue.contains(where: { $0.isWhitespace }) else { throw .invalidIdentifier }
        self.rawValue = rawValue
    }
    /// Decodes using the same validation as ordinary construction.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }
    /// Encodes the validated identifier as a string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An immutable request whose retry limit has been validated.
nonisolated public struct ProfileRequest: Codable, Equatable, Sendable {
    /// The requested user.
    public let userID: UserID
    /// The positive bounded retry budget.
    public let attempts: Int
    /// A request validation error.
    public enum ValidationFailure: Error, Sendable { case invalidAttempts }
    /// Validates a request without starting work.
    public init(userID: UserID, attempts: Int = 1) throws(ValidationFailure) {
        guard (1 ... 5).contains(attempts) else { throw .invalidAttempts }
        self.userID = userID
        self.attempts = attempts
    }
    private enum CodingKeys: CodingKey {
        case userID
        case attempts
    }
    /// Decodes through the checked request initializer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            userID: container.decode(UserID.self, forKey: .userID),
            attempts: container.decode(Int.self, forKey: .attempts)
        )
    }
}

/// Immutable profile data supplied by a driver.
nonisolated public struct Profile: Codable, Equatable, Sendable {
    /// The profile's user.
    public let userID: UserID
    /// Its display name.
    public let name: String
    /// Creates ordinary model data, without live operation authority.
    public init(userID: UserID, name: String) {
        self.userID = userID
        self.name = name
    }
}

/// A typed terminal fetch failure.
nonisolated public enum ProfileFailure: String, Error, Codable, Sendable {
    case unavailable
    case unauthorized
}
