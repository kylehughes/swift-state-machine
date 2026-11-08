@attached(member, names: arbitrary)
public macro ProbeDomain() = #externalMacro(module: "DomainPlugin", type: "ProbeDomainMacro")
