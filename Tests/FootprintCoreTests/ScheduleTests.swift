import XCTest
@testable import FootprintCore

final class ScheduleTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testOffIsNeverDue() {
        XCTAssertFalse(CleanupFrequency.off.isDue(last: nil, now: start))
        XCTAssertNil(CleanupFrequency.off.nextRun(after: start))
    }

    func testDueAfterInterval() {
        let day: TimeInterval = 86_400
        XCTAssertFalse(CleanupFrequency.daily.isDue(last: start, now: start.addingTimeInterval(day - 60), calendar: calendar))
        XCTAssertTrue(CleanupFrequency.daily.isDue(last: start, now: start.addingTimeInterval(day + 60), calendar: calendar))
        XCTAssertFalse(CleanupFrequency.weekly.isDue(last: start, now: start.addingTimeInterval(day * 6), calendar: calendar))
        XCTAssertTrue(CleanupFrequency.weekly.isDue(last: start, now: start.addingTimeInterval(day * 7 + 60), calendar: calendar))
        XCTAssertFalse(CleanupFrequency.monthly.isDue(last: start, now: start.addingTimeInterval(day * 20), calendar: calendar))
        XCTAssertTrue(CleanupFrequency.monthly.isDue(last: start, now: start.addingTimeInterval(day * 32), calendar: calendar))
        XCTAssertTrue(CleanupFrequency.weekly.isDue(last: nil, now: start))
    }

    func testScheduledPickOnlyTakesSureEligibleItemsAndRespectsUserChoices() {
        let sure = makeCandidate(path: "/tmp/macin-test/a", confidence: .high)
        let medium = makeCandidate(path: "/tmp/macin-test/b", confidence: .medium)
        let review = makeCandidate(path: "/tmp/macin-test/c", eligibility: .needsUserReview)
        let unticked = makeCandidate(path: "/tmp/macin-test/d", confidence: .high)
        let ignored = makeCandidate(path: "/tmp/macin-test/ignored/e", confidence: .high)

        let picked = ScheduledCleanupPolicy.pick([sure, medium, review, unticked, ignored], skipping: [unticked.path], ignoredPaths: ["/tmp/macin-test/ignored"])
        XCTAssertEqual(picked.map(\.path), [sure.path])
    }
}
