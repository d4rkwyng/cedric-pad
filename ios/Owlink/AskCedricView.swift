import SwiftUI
import CedricCore
import CedricAI

/// Ask Cedric: a question about the document (or a quick action), answered
/// by the engine Settings picked: Apple Intelligence on the device, the
/// built-in model (a device only), or a server on the local network the
/// user set up. Nothing is sent anywhere unless a LAN server is chosen. The
/// core's `OwlChatRunner` runs it, as on the Mac.
@MainActor
final class AskCedricModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var role: OwlChatEntry.Role
        var text: String
        var proposal: OwlEditProposal?
        var applied = false
    }

    @Published var question = ""
    @Published var entries: [Entry] = []
    @Published var running = false
    @Published var engineTitle: String?
    @Published var unavailable: String?

    let text: String
    let selection: NSRange
    let visible: NSRange
    let fileName: String?
    let language: Language
    var apply: (OwlEditProposal) -> Bool = { _ in false }
    var openSettings: () -> Void = {}
    private var task: Task<Void, Never>?
    private let gate = OwlToolGate.bundled()

    init(text: String, selection: NSRange, visible: NSRange, fileName: String?, language: Language) {
        self.text = text
        self.selection = selection
        self.visible = visible
        self.fileName = fileName
        self.language = language
    }

    var prose: Bool { SpellScope.isProse(language) }

    var actions: [OwlQuickAction] {
        OwlQuickAction.allCases.filter { $0 != .scriptSafety && $0.isOffered(prose: prose, language: language) }
    }

    /// The settings Ask Cedric runs on (nil: nothing ready), as on the Mac.
    static func chatSettings() -> LocalAISettings? {
        OwlChatSetup.chatSettings(LocalAISettings.load(), appleAvailable: AppleFoundationModelsProvider.isAvailable,
                                  builtInInstalled: !BuiltInEngine().installedModels.isEmpty)
    }

    func prepare() async {
        guard let s = Self.chatSettings(), let engine = await OwlChatEngines.make(settings: s) else {
            unavailable = AIStatus.noEngineMessage
            return
        }
        engineTitle = engine.title
    }

    func ask(_ q: String, action: OwlQuickAction? = nil) {
        guard !running else { return }
        let shown = action?.title(prose: prose) ?? q
        guard !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let history = entries.filter { $0.role == .user || $0.role == .owl }.map { OwlChatEntry(role: $0.role, text: $0.text) }
        entries.append(Entry(role: .user, text: shown))
        entries.append(Entry(role: .owl, text: ""))
        question = ""
        running = true
        let snap = OwlDocumentSnapshot(text: text, generation: 0, selection: selection, visible: visible,
                                       fileName: fileName, language: language.rawValue)
        let prose = self.prose
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false }
            guard let s = Self.chatSettings(), let engine = await OwlChatEngines.make(settings: s) else {
                self.finish(error: AIStatus.noEngineMessage)
                return
            }
            self.engineTitle = engine.title
            let scope: OwlChatScope = self.selection.length > 0 ? .selection : .wholeDocument
            guard let ctx = OwlChatContext.build(snap, scope: scope, budget: engine.contextBudget)
                    ?? OwlChatContext.build(snap, scope: .visible, budget: engine.contextBudget) else {
                self.finish(error: String(localized: "Too much text for this model: select less and ask again."))
                return
            }
            let req = OwlChatRequest(question: q, action: action, context: ctx, snapshot: snap, history: history,
                                     useTools: self.gate.allowsTools(engine.scoreKey), prose: prose)
            do {
                let outcome = try await OwlChatRunner.run(req, engine: engine, model: engine.scoreKey) { ev in
                    if case .text(let t) = ev {
                        Task { @MainActor [weak self] in self?.append(t) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))   // let queued text land first
                if var last = self.entries.last, last.role == .owl {
                    last.text = OwlChatRunner.stripThinking(outcome.answer)
                    last.proposal = outcome.proposal
                    self.entries[self.entries.count - 1] = last
                }
            } catch is CancellationError {
                self.finish(error: String(localized: "Stopped."))
            } catch {
                self.finish(error: AIStatus.describe(error))
            }
        }
    }

    private func append(_ t: String) {
        guard running, var last = entries.last, last.role == .owl else { return }
        last.text += t
        entries[entries.count - 1] = last
    }

    private func finish(error: String) {
        if var last = entries.last, last.role == .owl {
            last.role = .note
            last.text = error
            entries[entries.count - 1] = last
        }
    }

    func stop() { task?.cancel() }

    func applyProposal(_ e: Entry) {
        guard let p = e.proposal, let i = entries.firstIndex(of: e) else { return }
        if apply(p) {
            entries[i].applied = true
        } else {
            entries.append(Entry(role: .note, text: String(localized: "The text changed since Cedric read it, so the edit wasn’t applied.")))
        }
    }
}

struct AskCedricView: View {
    @ObservedObject var model: AskCedricModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if model.entries.isEmpty { intro }
                            ForEach(model.entries) { e in row(e).id(e.id) }
                        }
                        .padding()
                    }
                    .onChange(of: model.entries) { _, list in
                        if let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle(String(localized: "Ask Cedric"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { model.stop(); dismiss() }
                }
            }
            .task { await model.prepare() }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image("Owl").resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text(String(localized: "Ask about this document.")).font(.headline)
                    if let t = model.engineTitle {
                        Text(String(localized: "Answered by \(t).")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let why = model.unavailable {
                Text(why).font(.footnote).foregroundStyle(.secondary)
                Button(String(localized: "Open Settings")) { model.openSettings() }
            }
            FlowButtons(actions: model.actions, prose: model.prose) { model.ask("", action: $0) }
                .disabled(model.unavailable != nil)
        }
    }

    @ViewBuilder private func row(_ e: AskCedricModel.Entry) -> some View {
        switch e.role {
        case .user:
            Text(e.text).padding(10).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .owl:
            VStack(alignment: .leading, spacing: 8) {
                if e.text.isEmpty && model.running {
                    ProgressView().accessibilityIdentifier("ask.thinking")
                } else {
                    Text(.init(e.text)).textSelection(.enabled).accessibilityIdentifier("ask.answer")
                }
                if let p = e.proposal {
                    Text(p.reason.isEmpty ? String(localized: "Proposed edit") : p.reason).font(.footnote).foregroundStyle(.secondary)
                    Text(p.replacement).font(.system(.footnote, design: .monospaced)).lineLimit(12)
                        .padding(8).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Button(e.applied ? String(localized: "Applied") : String(localized: "Apply")) { model.applyProposal(e) }
                        .buttonStyle(.borderedProminent).disabled(e.applied)
                }
            }
        default:
            Text(e.text).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var inputBar: some View {
        HStack {
            TextField(String(localized: "Ask Cedric…"), text: $model.question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.ask(model.question) }
                .accessibilityIdentifier("ask.field")
            if model.running {
                Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
            } else {
                Button { model.ask(model.question) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(model.question.trimmingCharacters(in: .whitespaces).isEmpty || model.unavailable != nil)
                    .accessibilityIdentifier("ask.send")
            }
        }
        .padding(10)
    }
}

/// The quick actions as a wrapping row of buttons.
struct FlowButtons: View {
    let actions: [OwlQuickAction]
    let prose: Bool
    let tap: (OwlQuickAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(actions, id: \.self) { a in
                    Button(a.title(prose: prose)) { tap(a) }.buttonStyle(.bordered)
                }
            }
        }
    }
}
