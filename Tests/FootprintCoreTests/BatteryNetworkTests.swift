import IOKit.ps
import XCTest
@testable import FootprintCore

final class BatteryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testDesktopOrMissingDescriptionHasNoBattery() {
        XCTAssertFalse(BatterySnapshot.parse(nil).hasBattery)
        XCTAssertFalse(BatterySnapshot.parse([kIOPSTypeKey: "UPS"]).hasBattery)
    }

    func testMissingKeysStayUnavailable() {
        let snap = BatterySnapshot.parse([kIOPSTypeKey: kIOPSInternalBatteryType])
        XCTAssertTrue(snap.hasBattery)
        XCTAssertNil(snap.chargePercent)
        XCTAssertNil(snap.minutesToEmpty)
        XCTAssertNil(snap.condition)
        XCTAssertEqual(snap.state, .unknown)
    }

    func testParsesDischargingAndIgnoresInvalidTime() {
        let snap = BatterySnapshot.parse([
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 57, kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue, kIOPSIsChargingKey: false, kIOPSTimeToEmptyKey: -1,
            kIOPSBatteryHealthKey: "Good"
        ])
        XCTAssertEqual(snap.chargePercent, 57)
        XCTAssertEqual(snap.state, .discharging)
        XCTAssertEqual(snap.source, .battery)
        XCTAssertNil(snap.minutesToEmpty)
        XCTAssertEqual(snap.condition, "Good")
    }

    func testParsesChargingWithTimeToFull() {
        let snap = BatterySnapshot.parse([
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: true, kIOPSTimeToFullChargeKey: 75
        ])
        XCTAssertEqual(snap.state, .charging)
        XCTAssertEqual(snap.minutesToFull, 75)
        XCTAssertNil(snap.minutesToEmpty)
    }

    private func series(_ values: [(Int, Bool)], step: TimeInterval = 120, cpu: Double? = nil) -> [BatterySample] {
        values.enumerated().map { i, v in BatterySample(time: t0.addingTimeInterval(Double(i) * step), percent: v.0, onBattery: v.1, charging: !v.1, cpu: cpu) }
    }

    func testEventsAndGaps() {
        var s = series([(80, true), (79, true), (79, false), (81, false)])
        s.append(BatterySample(time: t0.addingTimeInterval(3 * 120 + 3600), percent: 90, onBattery: true, charging: false))
        let kinds = BatteryAnalysis.events(s).map(\.kind)
        XCTAssertEqual(kinds, [.pluggedIn, .gap, .unplugged])
    }

    func testInsufficientWhenTooShort() {
        XCTAssertEqual(BatteryAnalysis.diagnose(series([(80, true), (79, true)])).level, .insufficient)
    }

    func testNormalAndFastDrain() {
        let normal = series((0..<16).map { (90 - $0 / 4, true) })
        XCTAssertEqual(BatteryAnalysis.diagnose(normal).level, .normal)
        let fast = series((0..<16).map { (90 - $0, true) }, cpu: 0.7)
        let finding = BatteryAnalysis.diagnose(fast)
        XCTAssertEqual(finding.level, .worthReviewing)
        XCTAssertTrue(finding.nextStep.contains("Performance"))
    }

    func testChargingBreaksDischargeSegment() {
        let s = series([(80, true), (78, true), (79, false), (85, false), (84, true), (82, true)])
        XCTAssertEqual(BatteryAnalysis.dischargeSegments(s).count, 2)
    }

    func testLowBatteryAlertFiresOnceUntilRecovered() {
        var alert = LowBatteryAlert(threshold: 20)
        func snap(_ p: Int, _ src: PowerSourceKind = .battery) -> BatterySnapshot {
            BatterySnapshot(hasBattery: true, chargePercent: p, state: src == .battery ? .discharging : .charging, source: src)
        }
        XCTAssertFalse(alert.shouldNotify(snap(25)))
        XCTAssertTrue(alert.shouldNotify(snap(20)))
        XCTAssertFalse(alert.shouldNotify(snap(18)))
        XCTAssertFalse(alert.shouldNotify(snap(22)))
        XCTAssertFalse(alert.shouldNotify(snap(19)))
        XCTAssertFalse(alert.shouldNotify(snap(30, .external)))
        XCTAssertTrue(alert.shouldNotify(snap(19)))
    }
}

final class NetworkTests: XCTestCase {
    private let site = EndpointDefinition(name: "A", url: "https://a.example")

    private func result(_ name: String, failAt: StageKind? = nil) -> EndpointTestResult {
        let stages = StageKind.allCases.map { kind -> StageResult in
            guard let failAt else { return StageResult(kind: kind, state: .passed, duration: 0.01) }
            let order = StageKind.allCases
            let i = order.firstIndex(of: kind)!, f = order.firstIndex(of: failAt)!
            return StageResult(kind: kind, state: i < f ? .passed : (i == f ? .failed : .skipped))
        }
        return EndpointTestResult(endpointID: UUID(), endpointName: name, host: "\(name).example", stages: stages)
    }

    private let online = NetworkPathSnapshot(status: .available, interfaces: [.wifi])

    func testNoPath() {
        XCTAssertEqual(NetworkDiagnosis.evaluate(path: NetworkPathSnapshot(status: .unavailable), results: []).level, .problem)
    }

    func testConnectedButUntestedIsNotCalledWorking() {
        let f = NetworkDiagnosis.evaluate(path: online, results: [])
        XCTAssertEqual(f.level, .unknown)
    }

    func testAllPass() {
        XCTAssertEqual(NetworkDiagnosis.evaluate(path: online, results: [result("a"), result("b")]).level, .good)
    }

    func testOneFailingSiteIsNotAnOutage() {
        let f = NetworkDiagnosis.evaluate(path: online, results: [result("a"), result("b", failAt: .http)])
        XCTAssertEqual(f.level, .warning)
        XCTAssertFalse(f.title.lowercased().contains("down"))
    }

    func testAllDNSFailures() {
        let f = NetworkDiagnosis.evaluate(path: online, results: [result("a", failAt: .dns), result("b", failAt: .dns)])
        XCTAssertEqual(f.title, "Name lookup is failing")
    }

    func testAllConnectFailures() {
        let f = NetworkDiagnosis.evaluate(path: online, results: [result("a", failAt: .connect), result("b", failAt: .tls)])
        XCTAssertEqual(f.level, .problem)
    }

    func testLatencyStats() {
        let s = LatencyStats(samples: [0.02, 0.04, 0.03], failures: 1)
        XCTAssertEqual(s.median, 0.03)
        XCTAssertEqual(s.minimum, 0.02)
        XCTAssertEqual(s.maximum, 0.04)
        XCTAssertEqual(s.jitter!, 0.015, accuracy: 0.0001)
        XCTAssertNil(LatencyStats(samples: [], failures: 3).median)
    }

    func testEndpointValidation() {
        XCTAssertNotNil(EndpointDefinition.validate("https://example.com/health"))
        XCTAssertNil(EndpointDefinition.validate("ftp://example.com"))
        XCTAssertNil(EndpointDefinition.validate("example.com"))
        XCTAssertNil(EndpointDefinition.validate("https://"))
    }

    func testCounterRateRejectsResetOrWrap() {
        let a = InterfaceCounters(received: 1_000, sent: 500)
        let b = InterfaceCounters(received: 3_000, sent: 700)
        XCTAssertEqual(InterfaceCounters.rate(from: a, to: b, seconds: 2)?.down, 1_000)
        XCTAssertNil(InterfaceCounters.rate(from: b, to: a, seconds: 2))
    }

    func testInvalidEndpointIsUnsupported() async {
        let r = await EndpointTester.run(EndpointDefinition(name: "Bad", url: "not a url"), pathAvailable: true)
        XCTAssertEqual(r.stages.first?.state, .unsupported)
    }

    func testNoPathSkipsLaterStages() async {
        let r = await EndpointTester.run(site, pathAvailable: false)
        XCTAssertEqual(r.stage(.path)?.state, .failed)
        XCTAssertEqual(r.stage(.dns)?.state, .skipped)
        XCTAssertEqual(r.stage(.http)?.state, .skipped)
    }
}

final class MetricsStoreTests: XCTestCase {
    func testRoundTripAndDelete() async throws {
        let tree = try TempTree()
        let store = MetricsStore(url: tree.root.appendingPathComponent("m.sqlite"))
        let now = Date()
        try await store.append(BatterySample(time: now, percent: 50, onBattery: true, charging: false, cpu: 0.2))
        try await store.append(BatterySample(time: now.addingTimeInterval(60), percent: 49, onBattery: true, charging: false, cpu: nil))
        let samples = try await store.batterySamples(since: now.addingTimeInterval(-10))
        XCTAssertEqual(samples.map(\.percent), [50, 49])
        XCTAssertEqual(samples[0].cpu ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertNil(samples[1].cpu)

        try await store.append(NetworkEventRecord(time: now, status: .available, interface: .wifi))
        try await store.append(NetworkEventRecord(time: now.addingTimeInterval(1), status: .unavailable, interface: nil))
        let events = try await store.networkEvents(since: now.addingTimeInterval(-10))
        XCTAssertEqual(events.map(\.status), [.available, .unavailable])
        XCTAssertEqual(events[0].interface, .wifi)
        XCTAssertNil(events[1].interface)

        let r = EndpointTestResult(endpointID: UUID(), endpointName: "A", host: "a.example", stages: [StageResult(kind: .dns, state: .passed, duration: 0.01)], httpStatus: 200, bytes: 10)
        try await store.append(r)
        let results = try await store.networkResults(since: now.addingTimeInterval(-10))
        XCTAssertEqual(results.first?.stages.first?.state, .passed)
        XCTAssertEqual(results.first?.httpStatus, 200)

        try await store.deleteBatteryHistory()
        try await store.deleteNetworkHistory()
        let afterBattery = try await store.batterySamples(since: .distantPast)
        let afterNetwork = try await store.networkResults(since: .distantPast)
        XCTAssertTrue(afterBattery.isEmpty)
        XCTAssertTrue(afterNetwork.isEmpty)
    }
}
