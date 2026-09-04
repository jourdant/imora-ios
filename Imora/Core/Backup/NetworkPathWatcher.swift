import Foundation
import Network

/// watches the interface uploads would actually leave by, so backup can hold
/// off on the user's data plan. ios marks cellular and a personal hotspot
/// alike as expensive, and a hotspot is someone else's data plan, so both
/// count as cellular here.
final class NetworkPathWatcher {
    private let monitor = NWPathMonitor()
    private let onChange: (Bool) -> Void
    private var isMetered = false
    private var hasReported = false

    /// `onChange` fires on the main actor for the first path the monitor
    /// sees and for every change of answer after it.
    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            // an unsatisfied path is offline, not metered. a run that could
            // not reach the server anyway has no business being blamed on
            // the data plan.
            let metered = path.status == .satisfied && path.isExpensive
            Task { @MainActor in self?.adopt(metered) }
        }
        monitor.start(queue: DispatchQueue(label: "app.imora.networkpath"))
    }

    func stop() {
        monitor.cancel()
    }

    private func adopt(_ metered: Bool) {
        guard !hasReported || metered != isMetered else { return }
        hasReported = true
        isMetered = metered
        onChange(metered)
    }
}
