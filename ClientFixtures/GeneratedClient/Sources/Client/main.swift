import GeneratedDomain

var owner = Counter.Local(.init(["a": [1, nil]]))
// A graph without operations queues no command batches, so a long run of edits needs no draining.
for value in 1 ... 300 { try owner.send(.add(value)) }
guard case .idle(let idle) = owner.snapshot() else { fatalError("initial phase") }
guard case .committed(let receipt) = owner.commit(idle.finish(8)), case .done(let done) = receipt.snapshot else {
    fatalError("atomic admission")
}
precondition(done.value.value == 10)
precondition(receipt.revision == 301)
print("external generated client passed")
