import Foundation

/// One exploration: a class, the event families it enables, and the depth it enumerates to.
struct ExplorerConfiguration: Sendable, CustomStringConvertible {
    let kind: ExplorerPassiveKind
    let families: ExplorerFamilies
    let depth: Int
    /// Skips extending a sequence whose abstract state an explored sequence of no greater length
    /// already reached.
    ///
    /// Off by default: the abstract state does not capture the presentation's private
    /// state, so this pruning can miss a sequence.
    var stateHashing = false

    var description: String {
        var names: [String] = []
        if families.contains(.core) { names.append("core") }
        if families.contains(.second) { names.append("second") }
        if families.contains(.async) { names.append("async") }
        if families.contains(.combine) { names.append("combine") }
        if families.contains(.reentrant) { names.append("reentrant") }
        if families.contains(.pairs) { names.append("pairs") }
        if families.contains(.isolated) { names.append("isolated") }
        if families.contains(.callback) { names.append("callback") }
        if families.contains(.lease) { names.append("lease") }
        if families.contains(.triples) { names.append("triples") }
        if families.contains(.workers) { names.append("workers") }
        if families.contains(.followers) { names.append("followers") }
        if families.contains(.cancelDelivery) { names.append("cancelDelivery") }
        if families.contains(.clocks) { names.append("clocks") }
        if families.contains(.counts) { names.append("counts") }
        if families.contains(.reconcile) { names.append("reconcile") }
        if families.contains(.resume) { names.append("resume") }
        if families.contains(.demand) { names.append("demand") }
        if families.contains(.selection) { names.append("selection") }
        if families.contains(.sites) { names.append("sites") }
        if families.contains(.copies) { names.append("copies") }
        if families.contains(.chains) { names.append("chains") }
        if families.contains(.matrix) { names.append("matrix") }
        return "\(kind.rawValue) [\(names.joined(separator: "+"))] depth \(depth)\(stateHashing ? " hashed" : "")"
    }
}

/// What an exploration found.
struct ExplorerReport: Sendable {
    struct Finding: Sendable {
        let violation: ExplorerViolation
        let sequence: [ExplorerEvent]
        var count: Int
    }
    var configuration: ExplorerConfiguration
    var sequences = 0
    var pruned = 0
    var seconds = 0.0
    var deepest = 0
    /// The shortest failing sequence for each invariant, in the order found.
    var findings: [Finding] = []

    var summary: String {
        var lines = [
            "\(configuration): \(sequences) sequences run, \(pruned) pruned (sleep set, idle arms, state hashing), deepest \(deepest), \(String(format: "%.1f", seconds)) s"
        ]
        for finding in findings {
            lines.append(
                "  VIOLATION \(finding.violation.invariant.rawValue) (\(finding.count) sequences), minimal: \(explorerScript(finding.sequence))"
            )
            lines.append("    \(finding.violation.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Enumerates every sequence up to the configured depth, shortest first, running each from a fresh
/// state.
///
/// A sequence that violates an invariant is not extended, so the first sequence recorded for
/// an invariant is a shortest one.
@MainActor func explore(_ configuration: ExplorerConfiguration, limit: Int = .max) async -> ExplorerReport {
    var report = ExplorerReport(configuration: configuration)
    let start = Date()
    var seen: [String: Int] = [:]
    var frontier: [([ExplorerEvent], [ExplorerEvent])] = []
    guard let root = await explorerRun(configuration, []) else { return report }
    frontier = [([], root.enabled)]
    for depth in 1 ... max(configuration.depth, 1) {
        var next: [([ExplorerEvent], [ExplorerEvent])] = []
        for (prefix, enabled) in frontier {
            for event in enabled {
                guard report.sequences < limit else { break }
                // Sleep set over adjacent independent events: run only the order whose descriptions ascend.
                if let last = prefix.last, last.commutes(with: event), last.description > event.description {
                    report.pruned += 1
                    continue
                }
                let sequence = prefix + [event]
                guard let outcome = await explorerRun(configuration, sequence, pruning: true) else { continue }
                report.sequences += 1
                report.deepest = depth
                if outcome.redundant {
                    report.pruned += 1
                    continue
                }
                if let violation = outcome.violations.first {
                    explorerAppendAll(configuration, sequence, outcome.violations)
                    if let index = report.findings.firstIndex(where: { $0.violation.invariant == violation.invariant })
                    {
                        report.findings[index].count += 1
                    } else {
                        report.findings.append(.init(violation: violation, sequence: sequence, count: 1))
                        explorerAppendFailure(configuration, sequence, violation)
                    }
                    continue
                }
                if configuration.stateHashing {
                    if let earlier = seen[outcome.fingerprint], earlier <= depth {
                        report.pruned += 1
                        continue
                    }
                    seen[outcome.fingerprint] = depth
                }
                if depth < configuration.depth { next.append((sequence, outcome.enabled)) }
            }
        }
        frontier = next
        if frontier.isEmpty { break }
    }
    report.seconds = Date().timeIntervalSince(start)
    return report
}

/// Runs sequences against one presentation from a fresh state.
@MainActor protocol ExplorerRunner {
    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome
}

/// Runs one sequence from a fresh state.
@MainActor func explorerRun(
    _ configuration: ExplorerConfiguration,
    _ sequence: [ExplorerEvent],
    verbose: Bool = false,
    pruning: Bool = false
) async -> ExplorerOutcome? {
    let run: (any ExplorerRunner)? =
        if configuration.kind == .distinct {
            ExplorerDistinctRun(verbose: verbose)
        } else if configuration.kind == .ingress {
            ExplorerIngressRun(verbose: verbose)
        } else if configuration.kind == .multiCombine || configuration.kind == .multiObservation {
            ExplorerMultiOwnerRun(configuration.kind, verbose: verbose)
        } else if configuration.kind == .ownerFormsCombine || configuration.kind == .ownerFormsObservation {
            ExplorerOwnerFormsRun(configuration.kind, verbose: verbose)
        } else if configuration.kind == .realDrivingCombine || configuration.kind == .realDrivingObservation {
            ExplorerRealDrivingRun(configuration.kind, verbose: verbose)
        } else if configuration.kind == .freeSequence {
            ExplorerFreeSequenceRun(verbose: verbose)
        } else if configuration.kind == .runtimeShared, configuration.families.contains(.copies) {
            ExplorerCopiesRun(verbose: verbose)
        } else if configuration.kind == .runtimeShared {
            ExplorerRuntimeRun(families: configuration.families, verbose: verbose, pruning: pruning)
        } else if configuration.kind.isTeardown || configuration.kind == .publisher {
            ExplorerTeardownRun(configuration.kind, verbose: verbose)
        } else if configuration.kind.isGenerated {
            ExplorerGeneratedRun(configuration.kind, verbose: verbose)
        } else if configuration.kind.isSequence {
            ExplorerSequenceRun(configuration.kind, verbose: verbose)
        } else if configuration.kind.isDriving {
            ExplorerDrivingRun(configuration.kind, families: configuration.families, verbose: verbose)
        } else {
            ExplorerPassiveRun(configuration.kind, families: configuration.families, verbose: verbose, pruning: pruning)
        }
    guard let run else { return nil }
    return await run.run(sequence)
}

/// Appends a newly found violation to the file named by `EXPLORER_FAILURES`, if set.
func explorerAppendFailure(
    _ configuration: ExplorerConfiguration,
    _ sequence: [ExplorerEvent],
    _ violation: ExplorerViolation
) {
    let line =
        "- `\(configuration.kind.rawValue)` \(violation.invariant.rawValue): `\(explorerScript(sequence))` — \(violation.detail)\n"
    print("EXPLORER \(line)", terminator: "")
    guard let path = ProcessInfo.processInfo.environment["EXPLORER_FAILURES"] else { return }
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

/// Appends every violating sequence to the file named by `EXPLORER_ALL`, if set, so a defect that
/// another masks at its shortest sequence can still be found.
func explorerAppendAll(
    _ configuration: ExplorerConfiguration,
    _ sequence: [ExplorerEvent],
    _ violations: [ExplorerViolation]
) {
    guard let path = ProcessInfo.processInfo.environment["EXPLORER_ALL"] else { return }
    let line =
        "\(configuration.kind.rawValue)|\(explorerScript(sequence))|\(violations.map { "\($0.invariant.rawValue) \($0.detail)" }.joined(separator: "; "))\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
