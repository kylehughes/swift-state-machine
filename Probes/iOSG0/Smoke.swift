import Foundation
import ProbeCore
import UIKit

@main
@MainActor
final class SmokeApplication: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let host = Shared(Idle("initial"))
        guard let request = Request("request"), case .idle(let idle) = host.snapshot() else {
            preconditionFailure("Initial observation failed")
        }

        precondition(host.commit(idle.begin(request)) == .accepted)
        guard case .loading(let loading) = host.snapshot() else {
            preconditionFailure("Committed loading phase was not readable")
        }

        precondition(loading.value.request == "request")
        precondition(host.commit(loading.cancel()) == .accepted)
        guard case .idle(let cancelled) = host.snapshot() else {
            preconditionFailure("Cancellation did not restore idle")
        }

        precondition(cancelled.value.name == "request")
        host.close()
        precondition(host.isClosed)
        precondition(host.commit(cancelled.begin(request)) == .closed)

        let result: [String: Any] = [
            "probe": "G0-P07",
            "status": "pass",
            "systemVersion": UIDevice.current.systemVersion,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "checks": ["initial", "start", "commit", "read", "cancel", "close", "closed-rejection"],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            let directory = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try data.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch {
            preconditionFailure("Could not record smoke result: \(error)")
        }

        let controller = UIViewController()
        let label = UILabel(frame: CGRect(x: 24, y: 100, width: 340, height: 80))
        label.numberOfLines = 0
        label.text = "StateMachine G0-P07 passed on iOS \(UIDevice.current.systemVersion)"
        controller.view.backgroundColor = .systemBackground
        controller.view.addSubview(label)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
        return true
    }
}
