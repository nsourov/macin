import Dispatch
import XCTest
@testable import FootprintCore

final class MemoryTests: XCTestCase {
    func testBreakdownMatchesActivityMonitorDefinitions() {
        let pages = VMPageCounts(free: 10, active: 300, inactive: 200, speculative: 5, wired: 100, compressor: 50, purgeable: 20, external: 150, internal: 320)
        let b = SystemMemoryProvider.breakdown(pages, pageSize: 16_384)
        XCTAssertEqual(b.app, 300 * 16_384)
        XCTAssertEqual(b.wired, 100 * 16_384)
        XCTAssertEqual(b.compressed, 50 * 16_384)
        XCTAssertEqual(b.cached, 170 * 16_384)
        XCTAssertEqual(b.free, 15 * 16_384)
    }

    func testAppMemoryNeverNegative() {
        let pages = VMPageCounts(free: 0, active: 0, inactive: 0, speculative: 0, wired: 0, compressor: 0, purgeable: 50, external: 0, internal: 10)
        XCTAssertEqual(SystemMemoryProvider.breakdown(pages, pageSize: 4_096).app, 0)
    }

    func testPressureLevelMapping() {
        XCTAssertEqual(SystemMemoryProvider.pressure(fromLevel: 1), .normal)
        XCTAssertEqual(SystemMemoryProvider.pressure(fromLevel: 2), .warning)
        XCTAssertEqual(SystemMemoryProvider.pressure(fromLevel: 4), .critical)
        XCTAssertEqual(SystemMemoryProvider.pressure(fromLevel: 0), .unknown)
        XCTAssertEqual(SystemMemoryProvider.pressure(fromLevel: 3), .unknown)
    }

    func testPressureEventMappingPrefersWorstState() {
        XCTAssertEqual(MemoryPressureMonitor.state(for: [.warning, .critical]), .critical)
        XCTAssertEqual(MemoryPressureMonitor.state(for: .warning), .warning)
        XCTAssertEqual(MemoryPressureMonitor.state(for: .normal), .normal)
    }

    func testUsedIsUnavailableWhenAnyPartIsMissing() {
        let s = SystemMemorySnapshot(timestamp: Date(), physicalMemoryBytes: 1, pageSizeBytes: 1, appMemoryBytes: 1, wiredMemoryBytes: nil, compressedMemoryBytes: 1, cachedFilesBytes: nil, freeBytes: nil, swapUsedBytes: nil, swapTotalBytes: nil, pressure: .unknown, vmStatus: .unavailable("x"), swapStatus: .unavailable("x"))
        XCTAssertNil(s.memoryUsedBytes)
    }

    private func points(_ values: [Int64], step: TimeInterval = 5) -> [MemoryHistory.Point] {
        let start = Date(timeIntervalSince1970: 1_000)
        return values.enumerated().map { MemoryHistory.Point(time: start.addingTimeInterval(Double($0.offset) * step), bytes: $0.element) }
    }

    func testTrendNeedsEnoughSamplesAndSpan() {
        let mb: Int64 = 1_048_576
        XCTAssertEqual(MemoryHistory.trend(points([100 * mb, 400 * mb])), .unknown)
        XCTAssertEqual(MemoryHistory.trend(points([100, 200, 300, 400, 500].map { $0 * mb }, step: 1)), .unknown)
    }

    func testTrendRisingFallingSteady() {
        let mb: Int64 = 1_048_576
        XCTAssertEqual(MemoryHistory.trend(points([200, 220, 250, 270, 300].map { $0 * mb })), .rising)
        XCTAssertEqual(MemoryHistory.trend(points([300, 280, 250, 230, 200].map { $0 * mb })), .falling)
        XCTAssertEqual(MemoryHistory.trend(points([2000, 2010, 2020, 2030, 2040].map { $0 * mb })), .steady)
    }

    func testTrendUnknownAcrossLargeGap() {
        let mb: Int64 = 1_048_576
        var p = points([200, 220, 250, 270].map { $0 * mb })
        p.append(MemoryHistory.Point(time: p.last!.time.addingTimeInterval(120), bytes: 900 * mb))
        XCTAssertEqual(MemoryHistory.trend(p), .unknown)
    }

    func testHistoryDropsExitedProcessesAndKeepsReusedPIDSeparate() {
        var history = MemoryHistory(window: 300)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let snap: (Date) -> SystemMemorySnapshot = {
            SystemMemorySnapshot(timestamp: $0, physicalMemoryBytes: 1, pageSizeBytes: 1, appMemoryBytes: nil, wiredMemoryBytes: nil, compressedMemoryBytes: nil, cachedFilesBytes: nil, freeBytes: nil, swapUsedBytes: nil, swapTotalBytes: nil, pressure: .normal, vmStatus: .available, swapStatus: .available)
        }
        let old = ProcessIdentity(pid: 42, startTime: 1)
        let reused = ProcessIdentity(pid: 42, startTime: 2)
        func sample(_ id: ProcessIdentity, _ t: Date) -> ProcessMemorySample {
            ProcessMemorySample(timestamp: t, identity: id, name: "x", executablePath: nil, isCurrentUser: true, footprintBytes: 10, lifetimePeakFootprintBytes: 10)
        }
        history.record(snap(t0), samples: [sample(old, t0)])
        history.record(snap(t0.addingTimeInterval(2)), samples: [sample(reused, t0.addingTimeInterval(2))])
        XCTAssertTrue(history.points(for: old).isEmpty)
        XCTAssertEqual(history.points(for: reused).count, 1)
        history.record(snap(t0.addingTimeInterval(400)), samples: [sample(reused, t0.addingTimeInterval(400))])
        XCTAssertEqual(history.points(for: reused).count, 1)
        XCTAssertEqual(history.system.count, 1)
    }

    func testOwningAppPath() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(AppBundleResolver.owningAppPath(for: helper), "/Applications/Google Chrome.app")
        XCTAssertEqual(AppBundleResolver.appName(for: "/Applications/Google Chrome.app"), "Google Chrome")
        XCTAssertNil(AppBundleResolver.owningAppPath(for: "/usr/sbin/cfprefsd"))
        XCTAssertNil(AppBundleResolver.owningAppPath(for: nil))
    }

    func testLiveSystemSnapshotIsSane() {
        let s = SystemMemoryProvider().snapshot(pressure: .unknown)
        XCTAssertGreaterThan(s.physicalMemoryBytes, 1_000_000_000)
        XCTAssertEqual(s.vmStatus, .available)
        XCTAssertNotNil(s.memoryUsedBytes)
        XCTAssertLessThanOrEqual(s.memoryUsedBytes ?? 0, s.physicalMemoryBytes)
    }

    func testLiveProcessSamplesIncludeSelfWithStableIdentity() {
        let (samples, coverage) = ProcessMemoryProvider().samples()
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = samples.first { $0.identity.pid == me }
        XCTAssertNotNil(mine)
        XCTAssertGreaterThan(mine?.footprintBytes ?? 0, 0)
        XCTAssertTrue(mine?.isCurrentUser ?? false)
        XCTAssertEqual(coverage.readableProcesses, samples.count)
        XCTAssertEqual(Set(samples.map(\.identity)).count, samples.count)
        let again = ProcessMemoryProvider().samples().samples.first { $0.identity.pid == me }
        XCTAssertEqual(again?.identity, mine?.identity)
    }
}
