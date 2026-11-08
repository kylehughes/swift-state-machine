import StateMachine
import StateMachineExamples
nonisolated func accepted(_ idle: GeneratedProfile.Observed<GeneratedProfile.Idle>, _ request: ProfileRequest) throws -> GeneratedProfile.Prepared {
    try idle.begin(request)
}
