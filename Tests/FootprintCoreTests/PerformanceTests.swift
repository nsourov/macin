import XCTest
@testable import FootprintCore

final class PerformanceTests: XCTestCase {
    private func points(_ values: [Double], step: TimeInterval = 2, start: Date = Date(timeIntervalSince1970: 1_000)) -> [PerformancePoint] {
        values.enumerated().map { PerformancePoint(time: start.addingTimeInterval(Double($0.offset) * step), value: $0.element) }
    }

    func testSystemUsageMath() {
        let a = CPUTicks(busy: 100, total: 1_000)
        let b = CPUTicks(busy: 400, total: 2_000)
        XCTAssertEqual(SystemCPU.usage(from: a, to: b)!, 0.3, accuracy: 0.0001)
    }

    func testSystemUsageRejectsResetCounters() {
        XCTAssertNil(SystemCPU.usage(from: CPUTicks(busy: 500, total: 2_000), to: CPUTicks(busy: 100, total: 1_000)))
        XCTAssertNil(SystemCPU.usage(from: CPUTicks(busy: 100, total: 1_000), to: CPUTicks(busy: 100, total: 1_000)))
    }

    func testProcessUsageIsCoreEquivalent() {
        let t0 = Date(timeIntervalSince1970: 0)
        let usage = SystemCPU.processUsage(fromNanos: 0, at: t0, toNanos: 3_000_000_000, at: t0.addingTimeInterval(2))
        XCTAssertEqual(usage!, 1.5, accuracy: 0.0001)
        XCTAssertNil(SystemCPU.processUsage(fromNanos: 10, at: t0, toNanos: 5, at: t0.addingTimeInterval(2)))
        XCTAssertNil(SystemCPU.processUsage(fromNanos: 0, at: t0, toNanos: 5, at: t0.addingTimeInterval(0.1)))
    }

    func testShortSpikeIsNotSustained() {
        let rules = PerformanceRules()
        XCTAssertNil(rules.sustained(points([0.1, 0.1, 0.95, 0.97, 0.9]), threshold: 0.8))
    }

    func testSustainedRunIsDetected() {
        let rules = PerformanceRules()
        let run = rules.sustained(points([0.2] + Array(repeating: 0.9, count: 20)), threshold: 0.8)
        XCTAssertNotNil(run)
        XCTAssertEqual(run!.duration, 38, accuracy: 0.001)
        XCTAssertEqual(run!.average, 0.9, accuracy: 0.0001)
    }

    func testSmallDipDoesNotBreakRun() {
        let rules = PerformanceRules()
        var values = Array(repeating: 0.9, count: 20)
        values[10] = 0.75
        XCTAssertNotNil(rules.sustained(points(values), threshold: 0.8))
    }

    func testGapBreaksRun() {
        let rules = PerformanceRules()
        var p = points(Array(repeating: 0.9, count: 10))
        p += points(Array(repeating: 0.9, count: 10), start: p.last!.time.addingTimeInterval(60))
        XCTAssertNil(rules.sustained(p, threshold: 0.8))
    }

    func testDiagnoseOrdersThermalFirstAndLimitsProcesses() {
        let rules = PerformanceRules()
        let busy = points(Array(repeating: 1.2, count: 20))
        let procs = (0..<5).map { (id: "\($0)", name: "App \($0)", points: busy) }
        let result = rules.diagnose(system: points(Array(repeating: 0.2, count: 20)), processes: procs, thermal: .serious)
        XCTAssertEqual(result.first?.kind, .thermal(.serious))
        XCTAssertEqual(result.filter { if case .sustainedProcess = $0.kind { return true }; return false }.count, 3)
        XCTAssertFalse(result.contains { $0.kind == .sustainedSystem })
    }

    func testNothingToReportWhenCalm() {
        let rules = PerformanceRules()
        let calm = points(Array(repeating: 0.1, count: 30))
        XCTAssertTrue(rules.diagnose(system: calm, processes: [(id: "a", name: "A", points: calm)], thermal: .nominal).isEmpty)
    }

    func testLiveSystemTicksAdvance() throws {
        let a = try XCTUnwrap(SystemCPU.ticks())
        Thread.sleep(forTimeInterval: 0.3)
        let b = try XCTUnwrap(SystemCPU.ticks())
        let usage = try XCTUnwrap(SystemCPU.usage(from: a, to: b))
        XCTAssert((0...1).contains(usage))
    }

    func testLiveOwnProcessCPUMatchesBusyLoop() throws {
        let me = getpid()
        func cpu() -> UInt64? {
            ProcessMemoryProvider().samples().samples.first { $0.identity.pid == me }?.cpuTimeNanos
        }
        let t0 = Date()
        let a = try XCTUnwrap(cpu())
        var x = 0.0
        while Date().timeIntervalSince(t0) < 1.0 { x += sin(x) + 1 }
        XCTAssertGreaterThan(x, 0)
        let b = try XCTUnwrap(cpu())
        let usage = try XCTUnwrap(SystemCPU.processUsage(fromNanos: a, at: t0, toNanos: b, at: Date()))
        XCTAssertGreaterThan(usage, 0.6)
        XCTAssertLessThan(usage, 1.4)
    }

    func testTemperatureSummaryUsesHottestDieAndAveragesBattery() {
        let reading = TemperatureReading.summarize([
            ("PMU tdie1", 48), ("PMU tdie2", 52), ("PMU tdev1", 40),
            ("gas gauge battery", 35), ("gas gauge battery", 37),
            ("NAND CH0 temp", 38), ("PMU tdie3", -1), ("PMU tdie4", 400)
        ])
        XCTAssertEqual(reading.chip, 52)
        XCTAssertEqual(reading.battery, 36)
        XCTAssertEqual(reading.storage, 38)
    }

    func testTemperatureSummaryFallsBackAndCanBeEmpty() {
        XCTAssertEqual(TemperatureReading.summarize([("PMU tdev1", 41)]).chip, 41)
        XCTAssertTrue(TemperatureReading.summarize([]).isEmpty)
    }
}
