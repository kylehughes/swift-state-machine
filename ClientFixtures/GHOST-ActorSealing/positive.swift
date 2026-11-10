import StateMachine
import StateMachineExamples
import StateMachineUI

nonisolated func legal() async throws {
    let user = try UserID("client")
    let owner = GeneratedProfile.ActorHost(
        .init(userID: user),
        drivers: .init(
            fetch: { request in
                .success(Profile(userID: request.userID, name: "Value"))
            },
            audit: { _ in .failure(.unavailable) }
        )
    )
    _ = try await owner.send(.load(ProfileRequest(userID: user)))
    print(await owner.snapshot().revision)
    await owner.shutdown()
}
