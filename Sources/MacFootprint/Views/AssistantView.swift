import FootprintCore
import SwiftUI

extension AssistantModule {
    var sidebarItem: SidebarItem? {
        switch self {
        case .storage: return .candidates
        case .memory: return .memory
        case .performance: return .performance
        case .applications: return .applications
        case .battery: return .battery
        case .network: return .network
        case .general: return nil
        }
    }
}

extension EvidenceLevel {
    var color: Color {
        switch self {
        case .ok: return Palette.emerald
        case .note: return Palette.sky
        case .concern: return Palette.amber
        }
    }
}

enum AIStyle {
    static func rgb(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static let blue = rgb(0x2F5BFF)
    static let purple = rgb(0x7B2FF7)
    static let pink = rgb(0xD62FB8)
    static let coral = rgb(0xF0284A)
    static let orange = rgb(0xFF7A00)
    static let violet = rgb(0x5B21E6)
    static let accent = rgb(0x6D28D9)
    static let colors: [Color] = [blue, purple, pink, coral, orange, violet]
    static var linear: LinearGradient { LinearGradient(colors: [blue, purple, coral, orange], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static func angular(_ angle: Angle) -> AngularGradient { AngularGradient(colors: colors + [colors[0]], center: .center, angle: angle) }
}

struct AIOrb: View {
    var size: CGFloat = 28
    var active = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || (!active && size < 40))) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t * (active ? 160 : 40)).truncatingRemainder(dividingBy: 360))
            let pulse = active && !reduceMotion ? 1 + 0.06 * sin(t * 5) : 1
            ZStack {
                Circle().fill(AIStyle.angular(angle)).blur(radius: size * 0.25).opacity(active ? 0.7 : 0.35)
                Circle().fill(AIStyle.angular(angle))
                Circle().fill(AIStyle.angular(-angle * 1.4)).blur(radius: size * 0.12).opacity(0.6).scaleEffect(0.78)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.22), .clear], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.5))
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1)
            }
            .frame(width: size, height: size)
            .scaleEffect(pulse)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill([AIStyle.blue, AIStyle.purple, AIStyle.coral][i])
                        .frame(width: 7, height: 7)
                        .offset(y: reduceMotion ? 0 : -3 * max(0, sin(t * 6 - Double(i) * 0.7)))
                        .opacity(0.5 + 0.5 * max(0, sin(t * 6 - Double(i) * 0.7)))
                }
            }
        }
    }
}

struct TypewriterText: View {
    let text: String
    let animate: Bool
    @State private var shown = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var words: [Substring] { text.split(separator: " ", omittingEmptySubsequences: false) }

    var body: some View {
        Text(animate && !reduceMotion ? words.prefix(shown).joined(separator: " ") : text)
            .task(id: text) {
                guard animate, !reduceMotion else { return }
                shown = 0
                for i in 1...max(words.count, 1) {
                    try? await Task.sleep(for: .milliseconds(28))
                    if Task.isCancelled { return }
                    shown = i
                }
            }
    }
}

struct AssistantView: View {
    @EnvironmentObject private var assistant: AssistantModel
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool

    private let suggestions: [(String, String, String)] = [
        ("Why is my Mac slow?", "Check speed, heat and memory", "tortoise.fill"),
        ("Is my memory usage a problem?", "Explain memory pressure", "memorychip.fill"),
        ("How can I free up disk space?", "Find safe things to clean", "internaldrive.fill"),
        ("Why is my battery draining?", "See what uses energy", "battery.50percent"),
        ("Is my internet working?", "Wi-Fi, DNS and websites", "wifi"),
        ("How is my Mac doing overall?", "A quick health check", "heart.text.square.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if assistant.entries.isEmpty {
                ScrollView { welcome.padding(.vertical, 40).frame(maxWidth: .infinity) }
            } else {
                conversation
            }
            inputArea
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            AssistantSettingsSheet().environmentObject(assistant)
        }
        .onAppear {
            assistant.refreshStatus()
            focused = true
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            AIOrb(size: 22, active: assistant.isThinking)
            Text("Ask Your Mac").font(.headline)
            Spacer()
            modelMenu
            if !assistant.entries.isEmpty {
                Button { assistant.clear() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New chat")
            }
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help("AI settings")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().opacity(assistant.entries.isEmpty ? 0 : 1) }
    }

    private var modelMenu: some View {
        Menu {
            Picker("Answers by", selection: $assistant.engine) {
                ForEach(AssistantEngine.choices) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("AI Settings…") { showSettings = true }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(assistant.activeEngine == .rules ? Palette.slate : Palette.emerald).frame(width: 6, height: 6)
                Text(assistant.activeLabel).font(.caption.weight(.medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("Choose who writes the answers")
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            AIOrb(size: 76, active: false)
                .padding(.bottom, 4)
            VStack(spacing: 8) {
                Text("How can I help with your Mac?")
                    .font(.system(size: 28, weight: .bold))
                Text("I answer from what Macin measures on this Mac, show you the facts I used, and never change anything without asking.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(suggestions, id: \.0) { s in
                    Button { ask(s.0) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: s.2)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AIStyle.linear)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AIStyle.purple.opacity(0.12)))
                            Text(s.0).font(.callout.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            Text(s.1).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .hoverHighlight()
                }
            }
            .frame(maxWidth: 680)
            if assistant.activeEngine == .rules {
                Label("No AI model is ready. Set one up in AI Settings so I can check your Mac and answer.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(assistant.entries) { entry in
                        AssistantEntryView(entry: entry,
                                           thinking: assistant.isThinking && entry.answer == nil,
                                           animate: entry.id == assistant.entries.last?.id && Date().timeIntervalSince(entry.time) < 60,
                                           perform: perform)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24).padding(.vertical, 24)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: assistant.entries) { _, _ in
                withAnimation(Motion.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !assistant.isThinking }

    private var inputArea: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask anything about your Mac…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                if assistant.isThinking {
                    Button { assistant.cancel() } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.primary.opacity(0.75)))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(canSend ? AnyShapeStyle(AIStyle.linear) : AnyShapeStyle(Color.primary.opacity(0.15))))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(inputBorder)
            .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            Text("Answers use Macin's own measurements · \(assistant.activeLabel)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 14)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var inputBorder: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if assistant.isThinking {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let angle = Angle.degrees((context.date.timeIntervalSinceReferenceDate * 60).truncatingRemainder(dividingBy: 360))
                ZStack {
                    shape.strokeBorder(AIStyle.angular(angle), lineWidth: 3).blur(radius: 4).opacity(0.25)
                    shape.strokeBorder(AIStyle.angular(angle), lineWidth: 1.3).opacity(0.75)
                }
            }
        } else {
            shape.strokeBorder(focused ? AnyShapeStyle(AIStyle.linear.opacity(0.7)) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: focused ? 1.3 : 1)
        }
    }

    private func ask(_ q: String) {
        text = ""
        assistant.ask(q)
    }

    private func send() {
        guard canSend else { return }
        ask(text)
    }

    private func perform(_ id: String) {
        switch id {
        case "open.storage": model.storageTab = .overview; model.selection = .candidates
        case "review.cleanup": model.storageTab = .cleanUp; model.selection = .candidates
        case "open.memory": model.selection = .memory
        case "open.performance": model.selection = .performance
        case "open.applications": model.selection = .applications
        case "open.battery": model.selection = .battery
        case "open.network", "run.networkCheck": model.selection = .network
        default: break
        }
    }
}

struct SourceBadge: View {
    let entry: ChatEntry

    private var info: (symbol: String, name: String, place: String, color: Color) {
        switch entry.kind {
        case .apple:
            return ("apple.logo", "Apple on-device model", "On this Mac", Color.primary)
        case .custom:
            let host = entry.sourceHost ?? ""
            let local = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
            let app = entry.source.isEmpty ? "Your own model" : entry.source
            return ("server.rack", app, local ? "On this Mac" : (host.isEmpty ? "Your server" : "On \(host)"), Color.primary)
        default:
            return ("exclamationmark.triangle", "Macin", "No AI model", Color.secondary)
        }
    }

    var body: some View {
        let i = info
        HStack(spacing: 6) {
            Image(systemName: i.symbol).font(.system(size: 10, weight: .semibold))
            Text(i.name).font(.caption.weight(.semibold))
            Text("·").foregroundStyle(.secondary)
            Label(i.place, systemImage: i.place == "On this Mac" ? "lock.fill" : (i.place == "No AI used" ? "cpu" : "network"))
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(i.color.opacity(0.8))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .help(entry.kind == .rules ? "No AI model was ready, so nothing was answered." : "This answer was written by \(i.name) and checked by Macin.")
    }
}

struct AssistantEntryView: View {
    let entry: ChatEntry
    let thinking: Bool
    let animate: Bool
    let perform: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @State private var showSources = false
    @State private var showSteps = false

    private var thinkingText: String {
        guard let trace = entry.trace, !trace.isEmpty else { return "Thinking…" }
        return trace.contains { !$0.done } ? "Checking your Mac…" : "Reading the results…"
    }

    private func traceList(_ trace: [AgentTraceItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(trace.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if item.done {
                            Image(systemName: item.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(item.ok ? AIStyle.accent : Palette.amber)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .font(.caption)
                    .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout)
                        ForEach(item.commands, id: \.self) { command in
                            Text(command).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .animation(Motion.snappy, value: trace)
    }

    private func stepsChip(_ trace: [AgentTraceItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Motion.snappy) { showSteps.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("Ran \(trace.count) check\(trace.count == 1 ? "" : "s") on your Mac")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showSteps ? 180 : 0))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            if showSteps { traceList(trace) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer(minLength: 140)
                Text(entry.question)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
            HStack(alignment: .top, spacing: 12) {
                AIOrb(size: 28, active: thinking)
                VStack(alignment: .leading, spacing: 12) {
                    SourceBadge(entry: entry).padding(.top, 3)
                    if let answer = entry.answer {
                        if let trace = entry.trace, !trace.isEmpty { stepsChip(trace) }
                        answerBody(answer)
                    } else if thinking {
                        if let trace = entry.trace, !trace.isEmpty { traceList(trace) }
                        HStack(spacing: 10) {
                            TypingDots()
                            Text(thinkingText).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        if let note = entry.note {
                            Label(note, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Palette.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let trace = entry.trace, !trace.isEmpty { stepsChip(trace) }
                        if !entry.evidence.isEmpty { sources(entry.evidence) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func answerBody(_ a: AssistantAnswer) -> some View {
        let used = a.evidenceIDs.compactMap { id in entry.evidence.first { $0.id == id } }
        TypewriterText(text: a.summary, animate: animate)
            .font(.system(size: 15))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

        if !a.interpretation.isEmpty {
            Text(a.interpretation)
                .font(.callout).foregroundStyle(.secondary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !a.steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(a.steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.caption.weight(.semibold)).foregroundStyle(AIStyle.accent)
                        Text(step.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let action = ActionRegistry.action(step.action) {
                            Button { perform(action.id) } label: {
                                HStack(spacing: 4) {
                                    Text(action.title)
                                    Image(systemName: "arrow.up.right").font(.caption2.weight(.bold))
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AIStyle.accent)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(AIStyle.accent.opacity(0.12)))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        }

        if !used.isEmpty { sources(used) }

        if !a.unknowns.isEmpty {
            Label("I can't tell: " + a.unknowns.joined(separator: " "), systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let note = entry.note {
            Label(note, systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(Palette.amber)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            Text(entry.time.formatted(date: .omitted, time: .shortened))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(([a.summary, a.interpretation] + a.steps.map { "• " + $0.text }).filter { !$0.isEmpty }.joined(separator: "\n\n"), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy answer")
        }
        .font(.caption2).foregroundStyle(.tertiary)
    }

    private func sources(_ used: [Evidence]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Motion.snappy) { showSources.toggle() } } label: {
                HStack(spacing: 6) {
                    HStack(spacing: -3) {
                        ForEach(Array(used.prefix(4).enumerated()), id: \.offset) { _, e in
                            Circle().fill(e.level.color).frame(width: 9, height: 9)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        }
                    }
                    Text("Based on \(used.count) fact\(used.count == 1 ? "" : "s") from your Mac")
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showSources ? 180 : 0))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)

            if showSources {
                VStack(spacing: 0) {
                    ForEach(used) { e in
                        Button {
                            if let item = e.module.sidebarItem {
                                if item == .candidates { model.storageTab = .overview }
                                model.selection = item
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(e.level.color).frame(width: 7, height: 7)
                                Text(e.title).font(.callout).foregroundStyle(.primary)
                                Spacer(minLength: 12)
                                Text(e.value).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(e.module.title)")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct AssistantSettingsSheet: View {
    @EnvironmentObject private var assistant: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    engineCard
                    appleCard
                    customCard
                    historyCard
                    Text("Macin never downloads a model. Apple's model runs inside macOS. Your own model runs in an app you already use, like Ollama or LM Studio.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 640)
        .onAppear {
            key = assistant.apiKey
            assistant.refreshStatus()
        }
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who writes the answers").font(.headline)
            Picker("", selection: $assistant.engine) {
                ForEach(AssistantEngine.choices) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(assistant.engine == .automatic ? "Uses Apple's model if it's ready, then your own model. Now using: \(assistant.activeLabel)." : "If this choice isn't ready, Macin can't answer until you set it up.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 16)
    }

    private var appleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apple on-device model").font(.headline)
                Spacer()
                Button("Check again") { assistant.refreshStatus() }.controlSize(.small)
            }
            Label(assistant.appleStatus.message, systemImage: assistant.appleStatus.isReady ? "checkmark.circle.fill" : "xmark.circle")
                .font(.callout)
                .foregroundStyle(assistant.appleStatus.isReady ? Palette.emerald : .secondary)
            Text("Runs fully on this Mac. Free and private.").font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 16)
    }

    private var customCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own model").font(.headline)
            Text("Works with Ollama, LM Studio or any server with an OpenAI-style API.")
                .font(.caption).foregroundStyle(.secondary)
            field("Server address") {
                TextField("http://localhost:11434/v1", text: $assistant.endpoint.base)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Button("Ollama") { assistant.endpoint.base = "http://localhost:11434/v1" }.buttonStyle(.link)
                Button("LM Studio") { assistant.endpoint.base = "http://localhost:1234/v1" }.buttonStyle(.link)
            }
            .font(.caption)
            field("Model name") {
                HStack {
                    TextField("e.g. llama3.2", text: $assistant.endpoint.model)
                        .textFieldStyle(.roundedBorder)
                    Menu("Pick") {
                        if assistant.customModels.isEmpty {
                            Text("Press “Find models” first")
                        }
                        ForEach(assistant.customModels, id: \.self) { m in
                            Button(m) { assistant.endpoint.model = m }
                        }
                    }
                    .fixedSize()
                }
            }
            field("API key (optional)") {
                SecureField("Only if your server needs one", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.apiKey = key }
            }
            HStack {
                Button("Find models") {
                    assistant.apiKey = key
                    Task { await assistant.loadModels() }
                }
                Button {
                    assistant.apiKey = key
                    Task { await assistant.testEndpoint() }
                } label: {
                    if assistant.isTesting { ProgressView().controlSize(.small) } else { Text("Test") }
                }
                .disabled(assistant.isTesting)
                Spacer()
            }
            if let msg = assistant.testMessage {
                Label(msg.1, systemImage: msg.0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(msg.0 ? Palette.emerald : Palette.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if assistant.endpoint.url != nil && !assistant.endpoint.isLocal {
                Label("This address isn't on this Mac. Your questions and Mac facts will be sent to it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if assistant.endpoint.isLocal {
                Label("Runs on this Mac. The model app may keep its own logs.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(padding: 16)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conversations").font(.headline)
            Toggle("Save conversations on this Mac", isOn: $assistant.saveHistory)
            Text("Keeps the last 30 questions and answers. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
            Button("Clear all conversations", role: .destructive) { assistant.clear() }
                .disabled(assistant.entries.isEmpty)
        }
        .card(padding: 16)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
