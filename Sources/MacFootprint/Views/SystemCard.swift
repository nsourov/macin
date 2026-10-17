import FootprintCore
import SwiftUI

@MainActor
final class LiveSystem: ObservableObject {
    @Published private(set) var snapshot = SystemSnapshot.current()
    @Published private(set) var cpuHistory: [MemoryHistory.Point] = []
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        record(snapshot)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                let next = await Task.detached(priority: .utility) { SystemSnapshot.current() }.value
                self?.record(next)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func record(_ next: SystemSnapshot) {
        snapshot = next
        cpuHistory.append(MemoryHistory.Point(time: Date(), bytes: Int64(next.cpuLoad * 1000)))
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
    }

    var uptimeText: String {
        let hours = Int(snapshot.uptime / 3600)
        if hours >= 24 { return "\(hours / 24) day\(hours / 24 == 1 ? "" : "s"), \(hours % 24) h" }
        let minutes = Int(snapshot.uptime / 60) % 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    var uptimeDays: Int { Int(snapshot.uptime / 86_400) }
}
