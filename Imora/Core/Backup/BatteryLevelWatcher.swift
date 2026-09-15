import UIKit

/// Refresh after suspension as well as on charge changes; an unknown level
/// (including the simulator) never counts as a low battery.
final class BatteryLevelWatcher {
    private var tokens: [NSObjectProtocol] = []
    private let onChange: (Int?) -> Void

    init(onChange: @escaping (Int?) -> Void) {
        self.onChange = onChange
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIApplication.didBecomeActiveNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let level = UIDevice.current.batteryLevel
        onChange(level < 0 ? nil : Int((level * 100).rounded()))
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }
}
