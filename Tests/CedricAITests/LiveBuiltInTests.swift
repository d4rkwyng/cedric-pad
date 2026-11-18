import Foundation
import Testing
import Darwin
@testable import CedricAI
import CedricCore

/// The built-in engine for real: downloads the catalog's default model
/// from Hugging Face into ~/Library/Application Support/Cedric/Models/
/// (skipped if it is already there and verified), then runs the three owl
/// snippets through llama.cpp. Skipped unless CEDRIC_BUILTIN_LIVE=1 (CI
/// never sets it). CEDRIC_BUILTIN_MODEL=<catalog id> picks another model.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_BUILTIN_LIVE"] == "1"), .serialized)
struct LiveBuiltInTests {
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    @Test func liveDownloadAndHints() async throws {
        let env = ProcessInfo.processInfo.environment
        let catalog = try #require(ModelCatalog.bundled())
        let model = try #require(env["CEDRIC_BUILTIN_MODEL"].flatMap(catalog.model(id:)) ?? catalog.defaultModel)
        let store = ModelStore()
        print("LIVE store=\(store.directory.path) model=\(model.id) \(model.shortDescription)")

        let lastPrint = Box(Date.distantPast)
        let downloader = ModelDownloader(store: store, observer: { _, s in
            if case .downloading(let r, let t) = s, Date().timeIntervalSince(lastPrint.value) > 5 {
                lastPrint.mutate { $0 = Date() }
                print(String(format: "LIVE   download %.1f%% (%lld / %lld)", Double(r) / Double(t) * 100, r, t))
            }
        })
        if !store.isInstalled(model) {
            let t0 = Date()
            try await downloader.start(model)
            // Exercise pause + resume against the real server once.
            if env["CEDRIC_BUILTIN_PAUSE"] == "1" {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                await downloader.pause(model)
                let paused = await downloader.waitUntilSettled(model)
                print("LIVE paused: \(paused) partial=\(store.partialBytes(model))")
                try await downloader.start(model)
            }
            let final = await downloader.waitUntilSettled(model)
            let secs = Date().timeIntervalSince(t0)
            print(String(format: "LIVE download finished: %@ in %.1f s (%.0f MB/s)", "\(final)", secs, Double(model.sizeBytes) / secs / 1e6))
            #expect(final == .installed)
        } else {
            print("LIVE already installed (verified marker matches the catalog sha256)")
        }
        #expect(store.isInstalled(model))

        let host = BuiltInModelHost(runtime: LlamaRuntime())
        let engine = BuiltInEngine(catalog: catalog, store: store, host: host)
        let before = Self.footprintMB()
        let t = Date()
        let report = await engine.test()
        print("LIVE engine.test latency=\(Int(Date().timeIntervalSince(t) * 1000))ms (load + first answer) error=\(String(describing: report.error)) footprint \(before)→\(Self.footprintMB()) MB")
        #expect(report.error == nil)
        let provider = BuiltInHintProvider(model: model, path: store.fileURL(for: model), host: host)
        for (lang, file, code) in LiveCheckTests.snippets {
            let ctx = OwlContext(fileName: file, language: lang, text: code, textStart: 0,
                                 visibleRange: NSRange(location: 0, length: (code as NSString).length),
                                 selection: nil, documentID: UUID(), editGeneration: 1)
            let start = Date()
            let (hints, result) = try await provider.requestHints(for: ctx)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print(String(format: "LIVE [%@] %d ms hints=%d prompt=%d tok (%.0f ms) gen=%d tok %.1f tok/s footprint=%d MB",
                         file, ms, hints.count, result.promptTokens, result.promptSeconds * 1000,
                         result.completionTokens, result.tokensPerSecond, Self.footprintMB()))
            if env["CEDRIC_AI_RAW"] == "1" { print("LIVE   raw=\(result.text.replacingOccurrences(of: "\n", with: " "))") }
            for h in hints {
                let anchored = h.range.map { (code as NSString).substring(with: $0) } ?? "-"
                print("LIVE   \(h.kind.rawValue): \(h.title) | detail=\(h.detail ?? "-") | at=\(anchored) | replacement=\(h.replacement ?? "-")")
                #expect(h.title.count <= 60)
            }
            #expect(ms < 20_000)
        }
        await host.unload()
        try await Task.sleep(nanoseconds: 500_000_000)   // the free runs on llama's queue
        print("LIVE after unload footprint=\(Self.footprintMB()) MB")
    }
}
