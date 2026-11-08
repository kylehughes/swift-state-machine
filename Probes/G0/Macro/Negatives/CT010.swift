import DomainFixture
struct Forged: EdgeDescription { static let name = "undeclared" }
var domain = Domain()
let forged = domain.prepare(Forged())
