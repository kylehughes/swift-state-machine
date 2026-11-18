import StateMachine
import StateMachineExamples
// An operation that can fail has a driver that returns a Result.
nonisolated func misuse(_ profile: Profile) async {
    let owner = GeneratedProfile.Shared(
        GeneratedProfile.Idle(userID: profile.userID),
        fetchDriver: { _ in profile },
        auditDriver: { _ in .failure(.unavailable) }
    )
    await owner.shutdown()
}
