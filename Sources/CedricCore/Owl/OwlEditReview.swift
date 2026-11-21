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
