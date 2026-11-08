import DomainFixture
func mismatch(_ domain: inout Domain, _ completion: Domain.Completion<Domain.OperationB>) { _ = domain.admit(completion) }
