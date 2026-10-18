import Foundation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AssistantEngine: String, CaseIterable, Identifiable {
    case automatic, rules, apple, custom

    var id: String { rawValue }

    static let choices: [AssistantEngine] = [.automatic, .apple, .custom]

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .rules: return "No AI model"
        case .apple: return "Apple on-device model"
        case .custom: return "Your own model"
        }
    }
}

enum ProviderStatus: Equatable {
    case ready
    case unavailable(String)

    var isReady: Bool { self == .ready }

    var message: String {
        switch self {
        case .ready: return "Ready"
        case .unavailable(let why): return why
        }
    }
}

@MainActor
protocol AssistantSession: AnyObject {
    func send(_ text: String) async throws -> String
}

struct AssistantProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppleModel {
    static var status: ProviderStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(.deviceNotEligible):
                return .unavailable("This Mac can't run Apple's on-device model.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in System Settings to use it.")
            case .unavailable(.modelNotReady):
                return .unavailable("macOS is still getting Apple's model ready. Try again later.")
            case .unavailable:
                return .unavailable("Apple's model isn't available right now.")
            }
        }
        #endif
        return .unavailable("Needs macOS 26 or later with Apple Intelligence.")
    }
}

struct CustomEndpoint: Equatable {
    var base: String
    var model: String

    var url: URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard var comps = URLComponents(string: text), let scheme = comps.scheme?.lowercased(), ["http", "https"].contains(scheme), comps.host?.isEmpty == false else { return nil }
        if comps.path.isEmpty { comps.path = "/v1" }
        return comps.url
    }

    var isLocal: Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    var isConfigured: Bool { url != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum OpenAICompatible {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 180
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func request(_ url: URL, key: String?) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return r
    }

    static func models(_ endpoint: CustomEndpoint, key: String?) async throws -> [String] {
        guard let base = endpoint.url else { throw AssistantProviderError(message: "That address doesn't look right. Example: http://localhost:11434/v1") }
        var r = request(base.appendingPathComponent("models"), key: key)
        r.timeoutInterval = 8
        let (data, response) = try await fetch(r)
        try check(response, data)
        struct List: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw AssistantProviderError(message: "The server answered, but not with a model list.") }
        return list.data.map(\.id).sorted()
    }

    static func fetch(_ r: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: r)
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .cannotFindHost {
            throw AssistantProviderError(message: "Couldn't reach the server. Is Ollama or LM Studio running?")
        } catch let e as URLError where e.code == .timedOut {
            throw AssistantProviderError(message: "The model took too long to answer.")
        }
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AssistantProviderError(message: "No answer from the server.") }
        guard data.count < 512_000 else { throw AssistantProviderError(message: "The server's answer was too big.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw AssistantProviderError(message: "The server needs a valid API key.") }
            if http.statusCode == 404 { throw AssistantProviderError(message: "The server doesn't know this address or model (404).") }
            throw AssistantProviderError(message: "The server returned an error (\(http.statusCode)).")
        }
    }
}

@MainActor
final class CustomSession: AssistantSession {
    private let endpoint: CustomEndpoint
    private let key: String?
    private var messages: [[String: String]]

    init(endpoint: CustomEndpoint, key: String?, instructions: String) {
        self.endpoint = endpoint
        self.key = key
        messages = [["role": "system", "content": instructions]]
    }

    func send(_ text: String) async throws -> String {
        guard let base = endpoint.url else { throw AssistantProviderError(message: "The model address isn't set.") }
        messages.append(["role": "user", "content": text])
        var r = OpenAICompatible.request(base.appendingPathComponent("chat/completions"), key: key)
        r.httpMethod = "POST"
        let body: [String: Any] = ["model": endpoint.model, "messages": messages, "temperature": 0.2, "max_tokens": 700, "stream": false]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await OpenAICompatible.fetch(r)
        try OpenAICompatible.check(response, data)
        struct Reply: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }; let choices: [Choice] }
        guard let content = (try? JSONDecoder().decode(Reply.self, from: data))?.choices.first?.message.content else {
            throw AssistantProviderError(message: "The server answered in a format Macin doesn't understand.")
        }
        messages.append(["role": "assistant", "content": content])
        return content
    }
}

enum AssistantKeychain {
    private static let service = "com.macin.app.assistant"
    private static let account = "custom-endpoint"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
