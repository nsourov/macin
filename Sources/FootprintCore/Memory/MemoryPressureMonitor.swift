import Dispatch
import Foundation

public final class MemoryPressureMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (MemoryPressureState, Date) -> Void

    private let queue = DispatchQueue(label: "com.macin.memory-pressure", qos: .utility)
    private var source: DispatchSourceMemoryPressure?
    private let lock = NSLock()
    private var state: MemoryPressureState = .unknown

    public init() {}

    public var current: MemoryPressureState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func start(_ handler: @escaping Handler) {
        stop()
        update(SystemMemoryProvider.currentPressureLevel(), handler)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            self.update(Self.state(for: event), handler)
        }
        source.resume()
        lock.lock(); self.source = source; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let old = source
        source = nil
        lock.unlock()
        old?.cancel()
    }

    public static func state(for event: DispatchSource.MemoryPressureEvent) -> MemoryPressureState {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        if event.contains(.normal) { return .normal }
        return .unknown
    }

    private func update(_ new: MemoryPressureState, _ handler: Handler) {
        lock.lock()
        let changed = new != state
        state = new
        lock.unlock()
        if changed { handler(new, Date()) }
    }

    deinit { source?.cancel() }
}
