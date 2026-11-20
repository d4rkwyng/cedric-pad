import SwiftUI
import CedricCore
import CedricAI

/// What the AI engines can do here, for Settings and messages.
enum AIStatus {
    static let noEngineMessage = String(localized: "No AI engine is ready. Turn on Apple Intelligence, download a built-in model (on a device) or set up a server on your network in Settings › Cedric AI.")

    static var device: ModelCatalog.Device {
        UIDevice.current.userInterfaceIdiom == .pad
            ? .iPad(physicalMemory: ProcessInfo.processInfo.physicalMemory) : .iPhone
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The Apple Intelligence row: "Available", or why not.
    static var appleLine: String {
        let s = AppleFoundationModelsProvider.status
        if s == .available { return String(localized: "Available, on this device") }
        return s.message ?? String(localized: "Not available")
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case LocalAIError.timedOut: return String(localized: "The model took too long to answer.")
        case LocalAIError.endpointNotLocal: return String(localized: "The AI address isn’t on the local network.")
        case LocalAIError.http(let c): return String(localized: "The AI server answered with an error (\(c)).")
        case BuiltInError.promptTooLong: return String(localized: "Too much text for this model: select less and ask again.")
        case BuiltInError.notInstalled: return String(localized: "No model downloaded yet: download one in Settings › Cedric AI.")
        case BuiltInError.loadFailed(let why): return why
        default: return String(localized: "Something went wrong: \(String(String(describing: e).prefix(160)))")
        }
    }

    static func backendTitle(_ b: LocalAISettings.Backend) -> String {
        switch b {
        case .apple: return String(localized: "Apple Intelligence (on this device)")
        case .builtIn: return String(localized: "Built-in model (on this device)")
        case .custom, .lmStudio, .ollama: return String(localized: "A server on your network")
        }
    }
}

/// Settings: the editor (font size, theme, wrap, Cedric's hints) and
/// Cedric AI (off by default; Apple Intelligence's availability; the
/// built-in models on a device; a LAN server).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.fontSize) private var fontSize = AppSettings.defaultFontSize
    @AppStorage(AppSettings.Key.wrap) private var wrap = true
    @AppStorage(AppSettings.Key.owlHints) private var owlHints = true
    @AppStorage(AppSettings.Key.theme) private var theme = EditorTheme.system.rawValue
    @State private var ai = LocalAISettings.load()
    @State private var address = ""
    @State private var testResult: String?
    @StateObject private var models = ModelsModel()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Editor")) {
                    Stepper(value: $fontSize, in: AppSettings.fontSizes, step: 1) {
                        HStack {
                            Text(String(localized: "Font Size"))
                            Spacer()
                            Text("\(Int(fontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("settings.fontSize")
                    Picker(String(localized: "Theme"), selection: $theme) {
                        ForEach(EditorTheme.allCases, id: \.rawValue) { t in Text(t.displayName).tag(t.rawValue) }
                    }
                    .accessibilityIdentifier("settings.theme")
                    Toggle(String(localized: "Wrap Lines"), isOn: $wrap)
                    Toggle(String(localized: "Cedric’s Hints"), isOn: $owlHints)
                }
                .onChange(of: fontSize) { AppSettings.post() }
                .onChange(of: wrap) { AppSettings.post() }
                .onChange(of: owlHints) { AppSettings.post() }
                .onChange(of: theme) { AppSettings.post() }

                Section {
                    LabeledContent(String(localized: "Apple Intelligence"), value: AIStatus.appleLine)
                        .accessibilityIdentifier("settings.appleStatus")
                    Picker(String(localized: "Engine"), selection: Binding(get: { ai.backend.usesServer ? .custom : ai.backend },
                                                                           set: { ai.selectBackend($0); save() })) {
                        ForEach([LocalAISettings.Backend.apple, .builtIn, .custom], id: \.self) { b in
                            Text(AIStatus.backendTitle(b)).tag(b)
                        }
                    }
                    Toggle(String(localized: "Automatic AI Hints"), isOn: Binding(get: { ai.enabled }, set: { ai.enabled = $0; save() }))
                } header: {
                    Text(String(localized: "Cedric AI"))
                } footer: {
                    Text(String(localized: "Off by default. Cedric’s offline hints never need it. Ask Cedric uses Apple Intelligence or the built-in model on this device, or a server on your network if you set one up. Never the cloud."))
                }

                if ai.backend.usesServer {
                    Section {
                        TextField("http://192.168.1.20:1234/v1", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit(applyAddress)
                        Button(String(localized: "Test Connection")) { applyAddress(); test() }
                        if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                    } header: {
                        Text(String(localized: "Server on Your Network"))
                    } footer: {
                        Text(LocalAISettings.privacyNote)
                    }
                }

                if ai.backend == .builtIn { builtInSection }

                Section(String(localized: "About")) {
                    LabeledContent(String(localized: "Version"), value: Self.version)
                    Text(String(localized: "Owlink doesn’t collect anything and uses the network only when you ask: downloading a model, or a server on your network you set up."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .onAppear { address = ai.backend.usesServer ? ai.baseURL.absoluteString : "" }
        }
    }

    @ViewBuilder private var builtInSection: some View {
        Section {
            if let reason = BuiltInEngine().unavailableReason {
                Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("settings.builtInStatus")
            }
            ForEach(models.offered) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.shortDescription + " · " + m.license).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelButton(m)
                    }
                    if let f = models.states[m.id]?.fraction { ProgressView(value: f) }
                    if case .failed(let e) = models.states[m.id] { Text(e.message).font(.caption).foregroundStyle(.red) }
                }
            }
        } header: {
            Text(String(localized: "Built-in Models"))
        } footer: {
            Text(String(localized: "Downloaded from Hugging Face only when you tap Download, checked against its SHA-256, and kept out of iCloud backups. Runs on this device only."))
        }
        .alert(item: $models.confirm) { m in
            Alert(title: Text(String(localized: "Download \(m.name)?")),
                  message: Text(String(localized: "\(m.shortDescription). Licence: \(m.license) (\(m.licenseURL.absoluteString)). It downloads from huggingface.co.")),
                  primaryButton: .default(Text(String(localized: "Download"))) { models.start(m) },
                  secondaryButton: .cancel())
        }
    }

    @ViewBuilder private func modelButton(_ m: BuiltInModel) -> some View {
        switch models.states[m.id] ?? .notDownloaded {
        case .installed:
            Menu(String(localized: "Installed")) {
                Button(String(localized: "Use This Model")) { ai.model = m.id; ai.selectBackend(.builtIn); save() }
                Button(String(localized: "Delete"), role: .destructive) { models.delete(m) }
            }
        case .downloading:
            Button(String(localized: "Pause")) { models.pause(m) }
        case .verifying:
            ProgressView()
        default:
            Button(String(localized: "Download")) { models.confirm = m }.disabled(BuiltInPlatform.runtime == nil)
        }
    }

    private func save() {
        ai.save()
        AppSettings.post()
    }

    private func applyAddress() {
        guard let url = LocalAISettings.parseEndpoint(address) else {
            testResult = String(localized: "That isn’t an address Owlink can use.")
            return
        }
        guard LocalEndpointPolicy.isAllowed(url) else {
            testResult = String(localized: "Only addresses on your local network are allowed.")
            return
        }
        ai.baseURL = url
        ai.selectBackend(.custom)
        ai.baseURL = url
        save()
    }

    private func test() {
        testResult = String(localized: "Testing…")
        let engine = AIEngines.engine(for: ai)
        Task {
            let r = await engine.test()
            if let e = r.error {
                testResult = AIStatus.describe(e)
            } else {
                testResult = String(localized: "Connected: \(r.models.count) models, \(Int(r.latency * 1000)) ms.")
                    + (r.suggested.map { " " + String(localized: "Suggested: \($0.id).") } ?? "")
            }
        }
    }

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }
}

extension BuiltInModel: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// The built-in models offered on this device and their download states.
@MainActor
final class ModelsModel: ObservableObject {
    @Published var states: [String: ModelDownloadState] = [:]
    @Published var confirm: BuiltInModel?
    let offered: [BuiltInModel]
    private let downloader = ModelDownloader()

    init() {
        offered = ModelCatalog.bundled()?.offered(on: AIStatus.device) ?? []
        Task {
            await downloader.setObserver { [weak self] id, state in
                Task { @MainActor in self?.states[id] = state }
            }
            for m in offered { let s = await downloader.state(of: m); states[m.id] = s }
        }
    }

    func start(_ m: BuiltInModel) {
        Task {
            do { try await downloader.start(m) } catch let e as ModelDownloadError { states[m.id] = .failed(e) } catch {}
        }
    }

    func pause(_ m: BuiltInModel) { Task { await downloader.pause(m) } }

    func delete(_ m: BuiltInModel) {
        Task {
            try? await downloader.delete(m)
            states[m.id] = .notDownloaded
        }
    }
}
