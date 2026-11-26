import Dispatch
import PublicSchema

@inline(never)
func mix(_ value: UInt64) -> UInt64 {
    value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
}

/// Repeatedly reads six fields through `obs.value.<field>` across a module boundary.
@inline(never)
func readMultiField(_ obs: PublicReaderFlow.Observed<PublicReaderFlow.Active>) -> UInt64 {
    var acc = UInt64(obs.value.title.utf8.count)
    acc = (acc &* 31) &+ UInt64(obs.value.subtitle.utf8.count)
    acc = (acc &* 31) &+ UInt64(obs.value.tags.count)
    acc = (acc &* 31) &+ UInt64(obs.value.metadata.count)
    acc = (acc &* 31) &+ obs.value.handle.id
    acc = (acc &* 31) &+ obs.value.score
    return acc
}

@inline(never)
func readGeneric<Phase>(_ obs: PublicReaderFlow.Observed<Phase>) -> Phase { obs.value }

func makeActive(_ index: Int) -> PublicReaderFlow.Active {
    PublicReaderFlow.Active(
        title: "Document title number \(index) with realistic length",
        subtitle: "Subtitle section \(index % 13) for external consumer",
        tags: ["alpha-\(index)", "beta-\(index % 7)", "gamma-\(index % 5)"],
        metadata: ["k1": "v\(index)", "k2": "w\(index % 11)", "k3": "z\(index % 3)"],
        handle: PublicReaderFlow.Handle(id: UInt64(index &* 131 &+ 7), label: "handle-\(index)"),
        score: UInt64(index &* 17 &+ 3)
    )
}

@main
nonisolated enum PublicReaderMain {
    static func main() throws {
        let args = CommandLine.arguments
        func intArg(_ flag: String, _ fallback: Int) -> Int {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count, let v = Int(args[i + 1]) else {
                return fallback
            }
            return v
        }
        let iterations = intArg("--iterations", 250_000)
        let warmup = intArg("--warmup", 1)
        let repetitions = intArg("--repetitions", 3)
        precondition(iterations > 0 && warmup >= 0 && repetitions >= 1)

        // Retain 64 historical Active observations, then advance the owner to terminal Done and close it.
        var owner = PublicReaderFlow.Local(
            PublicReaderFlow.Idle(handle: PublicReaderFlow.Handle(id: 1, label: "init"))
        )
        var retained: [PublicReaderFlow.Observed<PublicReaderFlow.Active>] = []
        retained.reserveCapacity(64)
        if case .active(let obs) = try owner.send(.activate(makeActive(0))).snapshot { retained.append(obs) }
        for index in 1 ..< 64 {
            if case .active(let obs) = try owner.send(.update(makeActive(index))).snapshot { retained.append(obs) }
        }
        let terminal = try owner.send(.finish("archived"))
        _ = owner.close()

        precondition(retained.count == 64 && owner.snapshot().isClosed)
        guard case .done(let doneObs) = terminal.snapshot, doneObs.value.finalTitle == "archived" else {
            preconditionFailure("Expected terminal Done snapshot")
        }
        let sample = readGeneric(retained[7])
        precondition(sample.title == retained[7].value.title && sample.handle.id == retained[7].value.handle.id)

        for run in 0 ..< (warmup + repetitions) {
            let start = DispatchTime.now().uptimeNanoseconds
            var acc: UInt64 = 0x1234_5678
            for i in 0 ..< iterations {
                acc ^= mix(readMultiField(retained[i & 63]) &+ UInt64(i))
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let nsPerOp = Double(elapsed) / Double(iterations)
            print(
                "{\"checksum\":\(acc),\"iterations\":\(iterations),\"nsPerOp\":\(nsPerOp),"
                    + "\"run\":\(run),\"wallNanoseconds\":\(elapsed),\"warmup\":\(run < warmup ? 1 : 0),"
                    + "\"workload\":\"retained_multi_field\"}"
            )
        }
    }
}
