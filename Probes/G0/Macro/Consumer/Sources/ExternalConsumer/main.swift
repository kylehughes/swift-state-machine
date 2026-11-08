import DomainFixture

struct Description: EdgeDescription { static let name = "declared increment" }
var domain = Domain()
let observed = domain.snapshot
let copied = observed
if let prepared = domain.prepareIncrement(from: copied) {
    let committed = domain.commit(prepared)
    precondition(committed)
} else {
    fatalError("legal preparation rejected")
}
let work = domain.start()
let copiedTicket = work.ticket
_ = copiedTicket
precondition(domain.admit(work.complete(output: work.input + 1)))
precondition(domain.snapshot.value == 2)
print("G0-P04 external public consumer passed")
