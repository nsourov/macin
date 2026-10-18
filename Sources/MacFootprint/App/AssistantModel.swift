import AppKit
import FootprintCore
import SwiftUI

struct ChatEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    let time: Date
    let question: String
    var answer: AssistantAnswer?
    var evidence: [Evidence] = []
    var source = ""
    var note: String?
    var failed = false
    var sourceKind: String?
    var sourceHost: String?
    var trace: [AgentTraceItem]?

    var kind: AssistantEngine {
        if let k = sourceKind, let e = AssistantEngine(rawValue: k) { return e }
        switch source {
        case "Built-in rules", "": return .rules
        case "Apple on-device model": return .apple
        default: return .custom
        }
    }
}

@MainActor
final class AssistantModel: ObservableObject {
    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var isThinking = false
    @Published private(set) var appleStatus: ProviderStatus = AppleModel.status
    @Published private(set) var customModels: [String] = []
    @Published private(set) var testMessage: (Bool, String)?
    @Published private(set) var isTesting = false

    @Published var engine: AssistantEngine { didSet { defaults.set(engine.rawValue, forKey: "assistant.engine") } }
    @Published var endpoint: CustomEndpoint {
        didSet {
            defaults.set(endpoint.base, forKey: "assistant.base")
            defaults.set(endpoint.model, forKey: "assistant.model")
        }
    }
    @Published var saveHistory: Bool {
        didSet {
            defaults.set(saveHistory, forKey: "assistant.saveHistory")
            saveHistory ? persist() : try? FileManager.default.removeItem(at: Self.fileURL)
        }
    }

    private let defaults = UserDefaults.standard
    private weak var model: AppModel?
    private weak var monitor: SystemMonitor?
    private weak var battery: BatteryModel?
    private weak var network: NetworkModel?
    private weak var apps: ApplicationsModel?
    private var task: Task<Void, Never>?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacFootprint", isDirectory: true).appendingPathComponent("assistant.json")
    }

    init(model: AppModel, monitor: SystemMonitor, battery: BatteryModel, network: NetworkModel, apps: ApplicationsModel) {
        self.model = model
        self.monitor = monitor
        self.battery = battery
        self.network = network
        self.apps = apps
        let d = UserDefaults.standard
        let savedEngine = AssistantEngine(rawValue: d.string(forKey: "assistant.engine") ?? "") ?? .automatic
        engine = savedEngine == .rules ? .automatic : savedEngine
        endpoint = CustomEndpoint(base: d.string(forKey: "assistant.base") ?? "http://localhost:11434/v1", model: d.string(forKey: "assistant.model") ?? "")
        saveHistory = d.object(forKey: "assistant.saveHistory") as? Bool ?? true
        if saveHistory, let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode([ChatEntry].self, from: data) {
            entries = saved
        }
    }

    var apiKey: String {
        get { AssistantKeychain.read() ?? "" }
        set { AssistantKeychain.save(newValue); objectWillChange.send() }
    }

    func refreshStatus() {
        appleStatus = AppleModel.status
    }

    var activeEngine: AssistantEngine {
        switch engine {
        case .automatic:
            if appleStatus.isReady { return .apple }
            if endpoint.isConfigured { return .custom }
            return .rules
        default:
            return engine
        }
    }

    var activeLabel: String {
        switch activeEngine {
        case .apple: return "Apple on-device model"
        case .custom: return endpoint.model.isEmpty ? "Your own model" : endpoint.model
        default: return "No AI model"
        }
    }

    func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        refreshStatus()
        let history = entries.suffix(2).compactMap { e -> ConversationTurn? in
            guard let a = e.answer, !e.failed, e.kind != .rules else { return nil }
            return ConversationTurn(question: e.question, summary: a.summary)
        }
        var entry = ChatEntry(time: Date(), question: text)
        let toolbox = AgentToolbox(model: model, monitor: monitor, battery: battery, network: network, apps: apps)
        let session = makeAgent(toolbox)
        entry.source = session == nil ? "Macin" : activeLabel
        entry.sourceKind = session == nil ? AssistantEngine.rules.rawValue : activeEngine.rawValue
        entry.sourceHost = session != nil && activeEngine == .custom ? endpoint.url?.host : nil
        entries.append(entry)
        let index = entries.count - 1

        guard let session else {
            entry.failed = true
            entry.note = engineNote
            entries[index] = entry
            persist()
            return
        }

        isThinking = true
        let label = activeLabel
        let entryID = entry.id
        entries[index].trace = []
        toolbox.onChange = { [weak self] trace in
            guard let self, index < self.entries.count, self.entries[index].id == entryID else { return }
            self.entries[index].trace = trace
        }
        let pending = entries[index]
        let engine = activeEngine
        let chatSession = AgentRunner.plainSession(engine: engine, endpoint: endpoint, key: AssistantKeychain.read(), instructions: AgentPrompt.chatInstructions)
        let plainSession = AgentRunner.plainSession(engine: engine, endpoint: endpoint, key: AssistantKeychain.read(), instructions: AgentPrompt.instructions)
        task = Task { [weak self] in
            var result = pending
            do {
                var active = session
                var reply: String
                let needsMac = await AgentRunner.route(text, engine: engine)
                try Task.checkCancellation()
                do {
                    if needsMac == false, let chat = chatSession {
                        active = chat
                        reply = try await chat.send(AgentPrompt.question(text, history: history))
                    } else {
                        reply = try await session.send(AgentPrompt.question(text, history: history))
                        if needsMac == true && toolbox.trace.isEmpty {
                            try Task.checkCancellation()
                            reply = try await session.send(AgentPrompt.noTools)
                        }
                    }
                } catch let stopped as AppleStopped {
                    guard !toolbox.facts.isEmpty, let plain = plainSession else { throw stopped }
                    try Task.checkCancellation()
                    active = plain
                    reply = try await plain.send("Results from Macin's checks on this Mac:\n\(toolbox.resultsText)\n\nUse only these results.\n\n" + AgentPrompt.question(text, history: history))
                }
                var answer: String
                do {
                    answer = try AgentPrompt.check(reply, facts: toolbox.facts, question: text)
                } catch {
                    try Task.checkCancellation()
                    reply = try await active.send(AgentPrompt.fix(error))
                    answer = try AgentPrompt.check(reply, facts: toolbox.facts, question: text)
                }
                result.answer = AssistantAnswer(summary: answer, interpretation: "",
                                                evidenceIDs: AgentPrompt.used(answer, facts: toolbox.facts),
                                                steps: AgentTools.actions(forTools: toolbox.toolsUsed, facts: toolbox.facts))
            } catch is CancellationError {
                result.failed = true
                result.note = "You stopped the answer."
            } catch let error as AnswerCheckError {
                result.failed = true
                result.note = "\(label)'s answer didn't match the data from your Mac (\(error.localizedDescription)), so Macin didn't show it. The checks it ran are below."
            } catch {
                result.failed = true
                result.note = "\(label) couldn't answer: \(error.localizedDescription)"
            }
            result.evidence = toolbox.facts
            result.trace = toolbox.trace
            guard let self else { return }
            if index < self.entries.count, self.entries[index].id == result.id { self.entries[index] = result }
            self.isThinking = false
            self.task = nil
            self.persist()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func clear() {
        cancel()
        entries = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private var engineNote: String {
        switch engine {
        case .apple where !appleStatus.isReady: return "Apple's model isn't available: \(appleStatus.message)"
        case .custom where !endpoint.isConfigured: return "Your own model isn't set up yet. Add its address and name in AI settings."
        default: return "Ask Your Mac needs an AI model to answer. Turn on Apple Intelligence in System Settings, or add your own model in AI settings. \(appleStatus.message)"
        }
    }

    private func makeAgent(_ toolbox: AgentToolbox) -> AssistantSession? {
        if activeEngine == .apple && !appleStatus.isReady { return nil }
        return AgentRunner.session(engine: activeEngine, endpoint: endpoint, key: AssistantKeychain.read(), toolbox: toolbox)
    }

    func loadModels() async {
        do {
            customModels = try await OpenAICompatible.models(endpoint, key: AssistantKeychain.read())
            testMessage = customModels.isEmpty ? (false, "Connected, but no models were found.") : (true, "Found \(customModels.count) model(s).")
        } catch {
            customModels = []
            testMessage = (false, error.localizedDescription)
        }
    }

    func testEndpoint() async {
        guard endpoint.isConfigured else {
            testMessage = (false, "Add the address and the model name first.")
            return
        }
        isTesting = true
        defer { isTesting = false }
        do {
            let reply = try await CustomSession(endpoint: endpoint, key: AssistantKeychain.read(), instructions: "Reply with one short sentence.").send("Say hello.")
            testMessage = (true, "It works: “\(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))”")
        } catch {
            testMessage = (false, error.localizedDescription)
        }
    }

    private func persist() {
        guard saveHistory else { return }
        let recent = Array(entries.suffix(30))
        guard let data = try? JSONEncoder().encode(recent) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
