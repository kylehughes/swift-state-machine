extension ReferenceProfile {
    /// A model restoration policy rejection.
    public enum RestoreRejection: Error, Sendable { case interruptedLoading }
    /// Validated, versioned model data without live authority.
    ///
    /// Version 1 stores `version`, `model`, and `presentation`. Version 0 uses the same
    /// model and presentation shape; an absent version identifies that legacy format.
    /// Decoding migrates legacy data through current validation. Loading is rejected.
    public struct Archive: Codable, Sendable {
        /// The only version emitted by the encoder.
        public static let currentVersion = 1
        /// An archive version that this implementation cannot migrate.
        public enum DecodingRejection: Error, Equatable, Sendable {
            case unsupportedVersion(Int)
        }
        /// The ordinary model projection.
        public let model: Model
        /// An unrelated presentation field.
        public let presentation: String
        /// Validates restorable model data without granting live authority.
        ///
        /// Throws `RestoreRejection.interruptedLoading` for a loading model.
        public init(model: Model, presentation: String = "") throws(RestoreRejection) {
            if case .loading = model { throw .interruptedLoading }
            self.model = model
            self.presentation = presentation
        }
        private enum CodingKeys: CodingKey {
            case model
            case presentation
            case version
        }
        /// Checks the version before decoding and validating any model payload.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.contains(.version) ? container.decode(Int.self, forKey: .version) : 0
            switch version {
            case 0, Self.currentVersion:
                break
            default:
                throw DecodingRejection.unsupportedVersion(version)
            }
            try self.init(
                model: container.decode(Model.self, forKey: .model),
                presentation: container.decode(String.self, forKey: .presentation)
            )
        }
        /// Encodes current-version domain data, without provenance or execution state.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.currentVersion, forKey: .version)
            try container.encode(model, forKey: .model)
            try container.encode(presentation, forKey: .presentation)
        }
    }
}
