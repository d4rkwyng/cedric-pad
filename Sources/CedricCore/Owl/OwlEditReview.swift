import Foundation

/// What a wholesale buffer replacement does to pending edit proposals.
/// `setText` (a clean-tab disk reload, reopening in another encoding,
/// Follow File's reset) swaps the whole buffer without a user edit.
/// Proposals were made against the previous text and must not apply to
/// the new one: a `.lines` edit matches a stored offset, and the new
/// buffer can hold the same substring there; a `.text` edit can still
/// be unique in text it was never proposed against.
public enum OwlBufferReplacement {
    /// The document's edit generation after the replacement. One more
    /// than before, so a `.lines` proposal's stored generation no longer
    /// matches even when the offset still holds `original`.
    public static func generation(after generation: Int) -> Int { generation + 1 }

    /// Pending proposals after the replacement: none are kept.
    public static func kept(_ proposals: [OwlEditProposal]) -> [OwlEditProposal] {
        proposals.filter { _ in false }
    }
}

/// When Apply is refused and the card says the document is read-only.
public enum OwlEditAccess {
    /// Not editable, following the file on disk, in large-document mode
    /// (the text is chunked, including after Turn On Anyway), or with the
    /// extras paused (also the moment a paste trips large mode, before the
    /// bar is shown).
    public static func readOnly(editable: Bool, following: Bool, largeDocument: Bool, extrasPaused: Bool) -> Bool {
        !editable || following || largeDocument || extrasPaused
    }
}

/// Rechecking open edit cards after typing. One pass per burst, and only
/// while Ask Cedric is on screen: a hidden panel has nothing to update,
/// and large mode already refuses Apply, so it must not scan the buffer.
public enum OwlCardRefresh {
    /// The pause after a key before the cards are rechecked.
    public static let debounce: TimeInterval = 0.15

    public static func shouldRefresh(panelVisible: Bool, largeDocument: Bool, extrasPaused: Bool, hasCards: Bool) -> Bool {
        hasCards && panelVisible && !largeDocument && !extrasPaused
    }
}

/// One refresh of the open cards: each distinct find string is searched
/// at most once, and each search stops after two hits (enough to know
/// the text is not unique). A read-only document is not searched.
public struct OwlEditRefresh: Equatable, Sendable {
    public var states: [OwlEditProposal.ApplyState]
    public var searches: Int
}

extension OwlEditProposal {
    public static func refresh(_ proposals: [OwlEditProposal], text: NSString, generation: Int, readOnly: Bool) -> OwlEditRefresh {
        if readOnly {
            return OwlEditRefresh(states: Array(repeating: .readOnly, count: proposals.count), searches: 0)
        }
        var cache: [String: [NSRange]] = [:]
        var searches = 0
        var states: [ApplyState] = []
        states.reserveCapacity(proposals.count)
        for p in proposals {
            switch p.anchor {
            case .lines:
                states.append(p.state(text: text, generation: generation))
            case .text:
                let hits: [NSRange]
                if let found = cache[p.original] {
                    hits = found
                } else {
                    hits = occurrences(of: p.original, in: text, limit: 2)
                    cache[p.original] = hits
                    searches += 1
                }
                states.append(hits.count == 1 ? .ready(hits[0]) : .stale)
            }
        }
        return OwlEditRefresh(states: states, searches: searches)
    }
}
