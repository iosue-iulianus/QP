#if os(macOS)
import Network

/// Counts network changes (Wi-Fi ↔ hotspot, VPN on/off, cable plugged in).
/// Plex clients compare the count against the one from their last connection
/// check, so the next request after a change re-checks which server address
/// is reachable instead of waiting for a stale one to time out.
@MainActor
final class NetworkChangeMonitor {
    static let shared = NetworkChangeMonitor()

    private(set) var generation = 0
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.generation += 1
            }
        }
        monitor.start(queue: .main)
    }
}
#endif
