import GeneratedDomain

var owner = Counter.Local(.init(["a": [1, nil]]))
guard case .idle(let idle) = owner.snapshot() else { fatalError("initial phase") }
guard case .committed(let receipt) = owner.commit(try idle.finish(8)), case .done(let done) = receipt.snapshot else {
    fatalError("atomic admission")
}
precondition(done.value.value == 9)
precondition(receipt.revision == 1)
precondition(owner.drainCommands(limit: 1).count == 1)
print("external generated client passed")
