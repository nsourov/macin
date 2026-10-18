import XCTest
@testable import FootprintCore

final class AssistantTests: XCTestCase {
    func testRedaction() {
        let s = Redactor.redact("/Users/jane/Library at 192.168.1.20 for jane", home: "/Users/jane", user: "jane")
        XCTAssertEqual(s, "~/Library at [ip] for user")
    }

    func testAgentCheckAcceptsToolFacts() throws {
        let facts = [Evidence(id: "f1", module: .general, title: "macOS version", value: "macOS Tahoe 26.6.2"),
                     Evidence(id: "f2", module: .memory, title: "Memory in use", value: "14 GB of 18 GB")]
        let reply = try AgentPrompt.check("**Your Mac runs macOS Tahoe 26.6.2** and uses 14 GB of 18 GB memory.", facts: facts, question: "what os?")
        XCTAssertFalse(reply.contains("**"))
        XCTAssertEqual(Set(AgentPrompt.used(reply, facts: facts)), ["f1", "f2"])
    }

    func testAgentCheckRejectsGuesses() {
        let facts = [Evidence(id: "f1", module: .general, title: "macOS version", value: "macOS Tahoe 26.6.2")]
        XCTAssertThrowsError(try AgentPrompt.check("You have 45 apps installed.", facts: facts, question: "how many apps?"))
        XCTAssertThrowsError(try AgentPrompt.check("You run macOS Big Sur.", facts: facts, question: "what os?"))
        XCTAssertThrowsError(try AgentPrompt.check("  ", facts: facts, question: "hi"))
        XCTAssertNoThrow(try AgentPrompt.check("Hi! Ask me anything about your Mac.", facts: [], question: "hi"))
    }

    func testNameCheckUsesToolFactsOnly() {
        let facts = [Evidence(id: "f1", module: .general, title: "macOS name (from Apple's license file)", value: "macOS Tahoe"),
                     Evidence(id: "f2", module: .general, title: "ProductVersion", value: "26.6.2")]
        XCTAssertNoThrow(try AssistantPrompt.checkNames("You're on macOS Tahoe 26.6.2.", evidence: facts, question: "os?"))
        XCTAssertThrowsError(try AssistantPrompt.checkNames("You're on macOS Big Sur.", evidence: facts, question: "os?"))
        XCTAssertThrowsError(try AssistantPrompt.checkNames("You run macOS 25.", evidence: facts, question: "os?"))
        XCTAssertNoThrow(try AssistantPrompt.checkNames("Is it macOS 25? No.", evidence: facts, question: "am I on macOS 25?"))
    }

    func testAgentToolsAndActions() {
        XCTAssertEqual(Set(AgentTools.all.map(\.name)).count, AgentTools.all.count)
        XCTAssertEqual(AgentTools.spec("list_apps")?.param?.options, ["size", "name", "running"])
        let cleanup = [Evidence(id: "f1", module: .storage, title: "Safe to clean (from last scan)", value: "3 GB")]
        let steps = AgentTools.actions(forTools: ["storage_status", "memory_status"], facts: cleanup)
        XCTAssertEqual(steps.map(\.action), ["review.cleanup", "open.storage"])
        XCTAssertTrue(steps.allSatisfy { ActionRegistry.action($0.action) != nil })
    }
}
