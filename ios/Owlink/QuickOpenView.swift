import SwiftUI
import CedricCore

/// File › Open Quickly, as a sheet: the open Markdown document's headings
/// (`#` in the query, or the only list when no folder can be read) and the
/// files under a folder this app can list. The index is built when the
/// sheet opens. There is no folder sidebar and no live watcher.
struct QuickOpenView: View {
    let headings: [MarkdownOutline.Heading]
    /// A folder `FileIndex` can list. Nil: files stay unavailable.
    let root: URL?
    var onHeading: (MarkdownOutline.Heading) -> Void
    var onFile: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var match: FileMatchIndex?
    @State private var truncated = false
    @State private var indexing = false

    var body: some View {
        NavigationStack {
            List {
                switch QuickOpen.parse(query, filesMode: root != nil) {
                case .commands:
                    Text(String(localized: "Menu commands are on the Mac. Type # to search this document’s headings."))
                        .foregroundStyle(.secondary)
                case .headings(let q):
                    headingRows(q)
                case .files(let q):
                    fileRows(q)
                }
            }
            .accessibilityIdentifier("quickopen.list")
            .navigationTitle(String(localized: "Open Quickly"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: Text(String(localized: "File or # heading")))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .task { await indexFolder() }
    }

    @ViewBuilder private func headingRows(_ q: String) -> some View {
        if headings.isEmpty {
            Text(String(localized: "No headings in this document."))
                .foregroundStyle(.secondary)
        } else {
            let ranked = QuickOpen.rankHeadings(headings, query: q).prefix(QuickOpen.shownLimit)
            ForEach(Array(ranked), id: \.self) { i in
                let h = headings[i]
                Button {
                    onHeading(h)
                } label: {
                    HStack {
                        Text(h.title.isEmpty ? String(localized: "Heading") : h.title)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(max(0, h.level - 1)) * 12)
                        Spacer()
                        Text("\(h.line + 1)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityIdentifier("quickopen.heading")
            }
        }
    }

    @ViewBuilder private func fileRows(_ q: String) -> some View {
        if root == nil {
            Text(String(localized: "Owlink can’t list a folder for this file. Open the folder from the preview, or type # to search headings."))
                .foregroundStyle(.secondary)
        } else if indexing && match == nil {
            HStack {
                ProgressView()
                Text(String(localized: "Reading the folder…"))
                    .foregroundStyle(.secondary)
            }
        } else if let match {
            let hits = match.rank(q)
            if hits.isEmpty {
                Text(String(localized: "No matching files."))
                    .foregroundStyle(.secondary)
            }
            ForEach(hits, id: \.self) { i in
                let path = match.paths[i]
                Button {
                    onFile(root!.appendingPathComponent(path))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.name(i)).lineLimit(1)
                        if path.contains("/") {
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityIdentifier("quickopen.file")
            }
            if truncated {
                Text(String(localized: "The folder has more files than Open Quickly lists."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func indexFolder() async {
        guard let root else { return }
        indexing = true
        let built = await Task.detached(priority: .userInitiated) {
            FileIndex.build(root: root, showHidden: false)
        }.value
        guard !Task.isCancelled else { return }
        match = FileMatchIndex(paths: built.paths)
        truncated = built.truncated
        indexing = false
    }
}
