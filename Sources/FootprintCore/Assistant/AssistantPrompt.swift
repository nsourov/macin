import Foundation

public enum Redactor {
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var s = text
        if !home.isEmpty { s = s.replacingOccurrences(of: home, with: "~") }
        if user.count > 2 { s = s.replacingOccurrences(of: user, with: "user", options: .caseInsensitive) }
        s = s.replacingOccurrences(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "[ip]", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b"#, with: "[ip]", options: .regularExpression)
        return s
    }
}

public struct ConversationTurn: Sendable, Equatable {
    public let question: String
    public let summary: String

    public init(question: String, summary: String) {
        self.question = question
        self.summary = summary
    }
}

public enum AnswerCheckError: Error, Equatable, LocalizedError {
    case empty
    case tooLong
    case unverifiedNumber(String)
    case unverifiedFact(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "The model gave an empty answer."
        case .tooLong: return "The model's answer was too long."
        case .unverifiedNumber(let n): return "The model used a number Macin didn't measure (\(n))."
        case .unverifiedFact(let f): return "The model said something Macin can't confirm (\(f))."
        }
    }
}

public enum AssistantPrompt {
    public static func checkNames(_ text: String, evidence: [Evidence], question: String) throws {
        let known = (evidence.map { $0.title + " " + $0.value }.joined(separator: " ") + " " + question).lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"\bmacOS\s+((?:[A-Z][a-z]+)(?:\s[A-Z][a-z]+)?|\d+(?:\.\d+)*)"#) else { return }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if !known.contains(name.lowercased()) { throw AnswerCheckError.unverifiedFact("macOS " + name) }
        }
    }

    public static func numbers(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    public static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}
