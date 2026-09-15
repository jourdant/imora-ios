import Foundation
import Network

/// watches the interface uploads would actually leave by, so backup can hold
/// off on the user's data plan. ios marks cellular and a personal hotspot
/// alike as expensive, and a hotspot is someone else's data plan, so both
/// count as cellular here.
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let onChange: (Bool, Bool, Bool) -> Void
    private var lastPath: [Bool]?

    /// `onChange` fires on the main actor for the first path the monitor
    /// sees and for every change of answer after it.
    init(onChange: @escaping (Bool, Bool, Bool) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            // an unsatisfied path is offline, not metered. a run that could
            // not reach the server anyway has no business being blamed on
            // the data plan.
            let connected = path.status == .satisfied
            let metered = connected && path.isExpensive
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in self?.adopt(connected: connected, metered: metered, wifi: wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "app.imora.networkpath"))
    }

    func stop() {
        monitor.cancel()
    }

    private func adopt(connected: Bool, metered: Bool, wifi: Bool) {
        let path = [connected, metered, wifi]
        guard path != lastPath else { return }
        lastPath = path
        onChange(connected, metered, wifi)
    }
}
