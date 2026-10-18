import FootprintCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleStopped: LocalizedError {
    var errorDescription: String? { "Apple's model stopped while answering. Please try again." }
}

enum AgentRunner {
    @MainActor
    static func session(engine: AssistantEngine, endpoint: CustomEndpoint, key: String?, toolbox: AgentToolbox) -> AssistantSession? {
        switch engine {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return AppleAgentSession(toolbox: toolbox) }
            #endif
            return nil
        case .custom:
            return endpoint.isConfigured ? CustomAgentSession(endpoint: endpoint, key: key, toolbox: toolbox) : nil
        default:
            return nil
        }
    }

    @MainActor
    static func route(_ question: String, engine: AssistantEngine) async -> Bool? {
        #if canImport(FoundationModels)
        if engine == .apple, #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: "Classify the user's message.")
            let kind = try? await session.respond(to: question, generating: AppleRoute.self, options: GenerationOptions(temperature: 0)).content.kind
            return kind.map(AgentPrompt.needsMac)
        }
        #endif
        return nil
    }

    @MainActor
    static func plainSession(engine: AssistantEngine, endpoint: CustomEndpoint, key: String?, instructions: String) -> AssistantSession? {
        switch engine {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26, *) { return ApplePlainSession(instructions: instructions) }
            #endif
            return nil
        case .custom:
            return endpoint.isConfigured ? CustomSession(endpoint: endpoint, key: key, instructions: instructions) : nil
        default:
            return nil
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
struct PlainAgentTool: Tool {
    let name: String
    let description: String
    let box: AgentToolbox

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await box.run(name, nil)
    }
}

@available(macOS 26, *)
struct NameAgentTool: Tool {
    let name: String
    let description: String
    let box: AgentToolbox

    @Generable
    struct Arguments {
        @Guide(description: "The name to look up, for example Safari")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.run(name, arguments.name)
    }
}

@available(macOS 26, *)
struct PathAgentTool: Tool {
    let name: String
    let description: String
    let box: AgentToolbox

    @Generable
    struct Arguments {
        @Guide(description: "Folder path starting with ~/, for example ~/Downloads")
        var path: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.run(name, arguments.path)
    }
}

@available(macOS 26, *)
struct SortAgentTool: Tool {
    let name: String
    let description: String
    let box: AgentToolbox

    @Generable
    struct Arguments {
        @Guide(description: "How to sort the apps", .anyOf(["size", "name", "running"]))
        var sort_by: String
    }

    func call(arguments: Arguments) async throws -> String {
        await box.run(name, arguments.sort_by)
    }
}

@available(macOS 26, *)
@Generable
struct AppleRoute {
    @Guide(description: "What the message is", .anyOf(AgentPrompt.routeKinds))
    var kind: String
}

@available(macOS 26, *)
enum AppleErrors {
    static func map(_ error: Error) -> Error {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return AssistantProviderError(message: "Too much information for Apple's model at once. Try a narrower question.")
            case .unsupportedLanguageOrLocale: return AssistantProviderError(message: "Apple's model doesn't support this language yet.")
            case .guardrailViolation, .refusal: return AssistantProviderError(message: "Apple's model declined to answer this.")
            case .assetsUnavailable: return AssistantProviderError(message: "Apple's model isn't ready yet.")
            default: return AppleStopped()
            }
        }
        if let error = error as? LanguageModelSession.ToolCallError {
            return AssistantProviderError(message: "A check failed while answering (\(error.tool.name)).")
        }
        if (error as NSError).domain.contains("FoundationModels") {
            return AppleStopped()
        }
        return error
    }
}

@available(macOS 26, *)
@MainActor
final class ApplePlainSession: AssistantSession {
    private let session: LanguageModelSession

    init(instructions: String) {
        session = LanguageModelSession(instructions: instructions)
    }

    func send(_ text: String) async throws -> String {
        do {
            return try await session.respond(to: text, options: GenerationOptions(temperature: 0.5, maximumResponseTokens: 250)).content
        } catch {
            throw AppleErrors.map(error)
        }
    }
}

@available(macOS 26, *)
@MainActor
final class AppleAgentSession: AssistantSession {
    private let session: LanguageModelSession

    init(toolbox: AgentToolbox) {
        let tools: [any Tool] = AgentTools.all.map { spec in
            switch spec.param?.name {
            case "name": return NameAgentTool(name: spec.name, description: spec.description, box: toolbox)
            case "path": return PathAgentTool(name: spec.name, description: spec.description, box: toolbox)
            case "sort_by": return SortAgentTool(name: spec.name, description: spec.description, box: toolbox)
            default: return PlainAgentTool(name: spec.name, description: spec.description, box: toolbox)
            }
        }
        session = LanguageModelSession(tools: tools, instructions: AgentPrompt.instructions)
    }

    func send(_ text: String) async throws -> String {
        do {
            return try await session.respond(to: text, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 500)).content
        } catch {
            throw AppleErrors.map(error)
        }
    }
}
#endif

@MainActor
final class CustomAgentSession: AssistantSession {
    private let endpoint: CustomEndpoint
    private let key: String?
    private let toolbox: AgentToolbox
    private var messages: [[String: Any]]
    private var toolsSupported = true
    private let maxRounds = 8

    init(endpoint: CustomEndpoint, key: String?, toolbox: AgentToolbox) {
        self.endpoint = endpoint
        self.key = key
        self.toolbox = toolbox
        messages = [["role": "system", "content": AgentPrompt.instructions]]
    }

    private static var toolSchema: [[String: Any]] {
        AgentTools.all.map { spec in
            var properties: [String: Any] = [:]
            var required: [String] = []
            if let p = spec.param {
                var prop: [String: Any] = ["type": "string", "description": p.description]
                if let options = p.options { prop["enum"] = options }
                properties[p.name] = prop
                required.append(p.name)
            }
            return ["type": "function", "function": [
                "name": spec.name, "description": spec.description,
                "parameters": ["type": "object", "properties": properties, "required": required]
            ] as [String: Any]]
        }
    }

    func send(_ text: String) async throws -> String {
        messages.append(["role": "user", "content": text])
        for round in 0..<maxRounds {
            try Task.checkCancellation()
            let allowTools = toolsSupported && round < maxRounds - 1
            let message: [String: Any]
            do {
                message = try await post(withTools: allowTools)
            } catch ToolsUnsupported.yes {
                toolsSupported = false
                continue
            }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                let content = message["content"] as? String ?? ""
                messages.append(["role": "assistant", "content": content])
                return content
            }
            messages.append(message)
            for call in calls {
                let function = call["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                var argument: String?
                if let raw = function["arguments"] as? String, let data = raw.data(using: .utf8),
                   let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    argument = AgentTools.spec(name)?.param.flatMap { args[$0.name] as? String }
                }
                let result = await toolbox.run(name, argument)
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? name, "content": result])
            }
        }
        throw AssistantProviderError(message: "The model kept asking for more checks without answering.")
    }

    private enum ToolsUnsupported: Error { case yes }

    private func post(withTools: Bool) async throws -> [String: Any] {
        guard let base = endpoint.url else { throw AssistantProviderError(message: "The model address isn't set.") }
        var r = OpenAICompatible.request(base.appendingPathComponent("chat/completions"), key: key)
        r.httpMethod = "POST"
        var body: [String: Any] = ["model": endpoint.model, "messages": messages, "temperature": 0.2, "max_tokens": 700, "stream": false]
        if withTools { body["tools"] = Self.toolSchema }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await OpenAICompatible.fetch(r)
        if withTools, let http = response as? HTTPURLResponse, http.statusCode == 400 || http.statusCode == 422 { throw ToolsUnsupported.yes }
        try OpenAICompatible.check(response, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw AssistantProviderError(message: "The server answered in a format Macin doesn't understand.")
        }
        var clean: [String: Any] = ["role": "assistant", "content": message["content"] as? String ?? ""]
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty { clean["tool_calls"] = calls }
        return clean
    }
}
