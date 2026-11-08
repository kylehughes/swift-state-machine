import Foundation
import StateMachine

/// A typed URLSession driver using the endpoint's `userID` query parameter.
///
/// Identifiers remain query data. A valid request URL receives one URLSession data call
/// and at most one decode; URLSession controls wire-level retries and redirects.
nonisolated public struct ProfileHTTPClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    /// Selects the endpoint and URLSession used by every request.
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }
    /// Fetch retains this endpoint and session; the separate audit operation reports unavailable.
    public var drivers: ReferenceProfile.Drivers {
        ReferenceProfile.Drivers(
            fetch: { request in
                guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                    return .failure(.unavailable)
                }
                var query = (components.queryItems ?? []).filter { $0.name != "userID" }
                query.append(URLQueryItem(name: "userID", value: request.userID.rawValue))
                components.queryItems = query
                guard let url = components.url else { return .failure(.unavailable) }
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let response = response as? HTTPURLResponse else { return .failure(.unavailable) }
                    if response.statusCode == 401 { return .failure(.unauthorized) }
                    guard (200 ..< 300).contains(response.statusCode) else { return .failure(.unavailable) }
                    let profile = try JSONDecoder().decode(Profile.self, from: data)
                    guard profile.userID == request.userID else { return .failure(.unavailable) }
                    return .success(profile)
                } catch { return .failure(.unavailable) }
            },
            audit: { _ in .failure(.unavailable) }
        )
    }
}

/// An event-driven fake that deliberately ignores task cancellation until explicitly completed.
///
/// Tests can establish launch, revoke authority, and then prove that shutdown still
/// retains the physical execution. Every issued request must eventually be completed.
public actor ControlledProfileNetwork {
    /// The identity of one controlled physical request.
    public struct RequestID: Equatable, Sendable {
        private let identity = RuntimeIdentity()
        /// Compares request identity only.
        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity === rhs.identity }
    }
    /// A request announced only after its completion continuation is registered.
    public struct Request: Sendable {
        /// The identity accepted by explicit completion.
        public let id: RequestID
        /// The immutable validated request supplied to the driver.
        public let input: ProfileRequest
    }
    private struct InFlight {
        let request: Request
        let continuation: CheckedContinuation<Result<Profile, ProfileFailure>, Never>
    }
    private var inFlight: [InFlight] = []
    private var requests: [Request] = []
    private var observers: [CheckedContinuation<Request, Never>] = []
    /// Creates an empty event-driven network fake.
    public init() {}
    /// Fetch suspends until explicitly completed; the separate audit operation reports unavailable.
    public nonisolated var drivers: ReferenceProfile.Drivers {
        ReferenceProfile.Drivers(fetch: { await self.fetch($0) }, audit: { _ in .failure(.unavailable) })
    }
    private func fetch(_ input: ProfileRequest) async -> Result<Profile, ProfileFailure> {
        await withCheckedContinuation { continuation in
            let request = Request(id: RequestID(), input: input)
            inFlight.append(InFlight(request: request, continuation: continuation))
            if observers.isEmpty {
                requests.append(request)
            } else {
                observers.removeFirst().resume(returning: request)
            }
        }
    }
    /// Waits for the next announced request without inferring launch from timing.
    public func nextRequest() async -> Request {
        if !requests.isEmpty { return requests.removeFirst() }
        return await withCheckedContinuation { observers.append($0) }
    }
    /// The number of registered requests not explicitly completed.
    public var inFlightCount: Int { inFlight.count }
    /// Completes exactly this registered request once; duplicate identities return false.
    @discardableResult public func complete(_ id: RequestID, with result: Result<Profile, ProfileFailure>) -> Bool {
        guard let index = inFlight.firstIndex(where: { $0.request.id == id }) else { return false }
        inFlight.remove(at: index).continuation.resume(returning: result)
        return true
    }
}
