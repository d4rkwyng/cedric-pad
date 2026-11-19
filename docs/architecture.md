# OwlInk architecture

**Name.** The app is OwlInk (`OwlInk.app`, CFBundleName and
CFBundleDisplayName "OwlInk", the app menu's About / Hide / Quit). The
owl assistant is Cedric, and the internal names say Cedric after the owl.
Everything users' data or tools hang on keeps that name on purpose, for
continuity of settings, session and models; don't "fix" these to OwlInk:
bundle id `net.mindtricks.cedric` (the UserDefaults domain), the `cedric://`
URL scheme, `~/Library/Application Support/Cedric/`
(Session, Models), the `cedric` command, the executable
`Contents/MacOS/Cedric` (crash reports, `pgrep -x Cedric`), the Swift
modules (CedricCore, CedricAI, CedricApp), the theme names "Cedric" and
"Cedric Night", and the model downloader's User-Agent `Cedric`.

Two targets, after Tankard's layout:

- **CedricCore** (Foundation only, fully unit-tested): languages and their
  detection, the tokenizers and `HighlightEngine`, `LineIndex`, the Markdown
  renderer, `TextCodec` (encodings and line endings), `FindEngine`,
  `SessionStore`, and the theme palettes.
- **CedricApp** (AppKit, WebKit): the app. `main.swift` builds the menus;
  `AppDelegate` owns the tabs and the session; one `EditorWindowController`
  per tab.

## Tabs and documents

Each tab is an `NSWindow` grouped by native window tabbing
(`tabbingMode = .preferred`), with an `EditorWindowController` and an
`EditorDocument`. Cedric does not use NSDocument: NSDocument reviews unsaved
documents on quit and autosaves untitled documents to its own locations,
both of which fight the Notepad++ model (quit silently, restore everything).

Untitled tabs are named as TextEdit names them (`UntitledNames.next`):
"Untitled", then the lowest free "Untitled N" among the untitled tabs open
now. (A counter that only grew gave "Untitled 3" with none open.)

## Session restore

`SessionStore` keeps `session.json` (windows, tab order, selection, scroll
line, encoding, line ending, a hand-picked language) and one UTF-8 buffer per
tab with unsaved text, in `~/Library/Application Support/Cedric/Session/`.
Writes are atomic; buffers are written before the session that refers to
them; orphan buffers are pruned after each save.

- Every edit schedules a save 1.5 s later (coalesced). Only tabs whose
  change count moved since their last buffer write are rewritten. A
  tab's written count moves only after its write succeeded (a failed one
  is logged and retried by the next save), because hot close skips its
  own write when the count matches (`CEDRIC_CHECK=closefail`).
- Quit (`applicationShouldTerminate`) saves synchronously and returns
  `.terminateNow`: no prompts. Windows closed by termination keep their
  buffers. A tab the user closes doesn't ask (hot close): its unsaved
  text is written to its buffer synchronously before the window goes, it
  joins `Session.closedTabs` (newest last, `ClosedTabs.limit` 50: clean
  tabs are dropped; tabs with unsaved text never are, so the list may
  grow past 50) and the session is saved at once, so the buffer is
  never pruned and a kill -9 right after keeps it. File › Reopen Closed
  Tab (⇧⌘T) pops the newest, with the same id (the buffer stays its
  buffer). If writing the buffer fails, closing asks as before.
- On launch the session is restored before anything else opens. A file tab
  with a buffer gets the buffer's text and stays unsaved; a clean file tab
  reopens the file from disk; a file that has gone and had no buffer is
  dropped.
- `Scripts/session-check.sh` checks it end to end (kill -9 and normal quit).
- Only each window's selected tab is built during launch. The others are
  built 0.25 s after the first frame, one per run-loop turn, into their
  saved places in the tab bar (AppKit spends ~10 ms adding a window to a
  tab group, ~45 ms for the first, which creates the tab bar). A save,
  quit, opening one of their files or a dev hook builds them first.

## Launch

`Scripts/launch-speed-check.sh` prints median phase times from process
start (`CEDRIC_LAUNCH_TRACE`, LaunchTrace.swift), including a key posted at
the first frame through the event queue, typed and drawn. What is off the
launch path: the unselected restored tabs (above); the Open Recent rebuild
and the owl hub (`AfterFirstFrame`: after the first frame, one block per
run-loop turn); the find bar (built on first use); llama.framework (not
linked: `CLlamaLoader` dlopens it on the first model load;
`CEDRIC_LLAMA_CHECK=1`, run by launch-check.sh, checks it loads). What is
left is mostly AppKit's own: NSApplication (~25 ms), finishing launching
(~20 ms), the first window, text view and its layout (~40 ms), and the
first display (~18 ms); a minimal AppKit window with a text view takes
~95 ms to its first frame on the same Mac.

- The timed saves snapshot the tabs on the main thread (one copy of each
  changed buffer's text) and write the buffers, then `session.json`, then
  the prune, in that order, on a serial utility queue; quit runs the same
  work synchronously on that queue, so it also waits for a timed save in
  flight.

Known gaps: a large unsaved file is rewritten whole on each autosave (off
the main thread since the large-documents work); a file
changed on disk under unsaved edits is only flagged by the owl's "Reload?"
(when the owl is on; clean tabs reload).

## Text system

`EditorTextView` is an `NSTextView` built on an explicit TextKit 2 stack
(`NSTextContentStorage` + `NSTextLayoutManager`), so layout is lazy and
viewport-based. Nothing touches `layoutManager` (that would switch the view
back to TextKit 1); the app logs a warning if it ever happens. Line numbers
are a `GutterView` beside the scroll view rather than an `NSRulerView` for
the same reason. Line endings are normalised to LF on load and paste;
`EditorDocument` writes the chosen ending back on save.

`LineIndex` holds every line start and is updated incrementally from
`NSTextStorage` edit notifications (`editedRange`, `changeInLength`); the
gutter, status bar, go-to-line and highlighter all use it.

## Multiple carets

| Action | Menu / gesture | Shortcut |
|---|---|---|
| Column selection (or a column of carets, dragging straight down) | ⌥-drag | |
| Add or remove a caret | ⌘-click (⌘-drag adds a selection) | |
| Add Caret Above / Below | Edit › Selection | ⌃⇧↑ / ⌃⇧↓ |
| Add Next Occurrence (first press: the word at the caret) | Edit › Selection | ⌘D |
| Select All Occurrences | Edit › Selection | ⌃⌘G |
| Single Caret | Edit › Selection (no key in the menu) | ⎋ while there are several |

**Why NSTextView's own multi-range editing isn't used.** Probed on TextKit 2
with the app's exact stack (plan-0.2.0.md §0): `setSelectedRanges` keeps
several *non-empty* ranges, but several empty ranges (carets) collapse to
one, and setting `textLayoutManager.textSelections` directly is reset by the
view. Typing over several ranges replaces only the first and drops the rest;
pasting over two put the text in the first and deleted the second, and ⌘Z
then restored the wrong text. Column *selection* drawing would have been
free; carets and editing at each of them are not, and the built-in undo is
unsafe. So OwlInk owns them.

**Model.** `EditorTextView.multiCarets: [MultiCaret.Caret]?` is nil with one
caret: NSTextView's own selection is the only state, and every override that
the feature adds (`insertText`, `doCommand(by:)`, `deleteBackward`,
`insertNewline`, `insertTab`, `setSelectedRanges`, `setMarkedText`,
`mouseDown` with ⌥/⌘, paste, copy, cut, `drawBackground`, `textEdited`)
checks only that, so a keystroke costs a nil check when the feature is
unused. With 2 or more, the list is sorted and merged after every operation
(`MultiCaret.normalize`: overlapping selections merge, a caret touching a
selection joins it). The **primary** caret is also NSTextView's selection, so
input methods, accessibility (VoiceOver sees the primary only), Services,
the status bar's counts and the find bar keep working on it; the others are
drawn by the editor. A caret has an anchor, a head and a goal column, so
⇧-moves extend from the right end and ↑/↓ keep their column across short
lines.

**Leaving.** Any selection the layer didn't set itself (a click, find, go
to line, a menu command such as Duplicate Line, undo) collapses to one caret:
`setSelectedRanges` is overridden and the layer sets `multiOwnsSelection`
around its own calls. Key commands it doesn't handle (page moves, transpose,
⇧Tab…) collapse to the primary and run as usual. ⎋ (`cancelOperation:`,
`complete:`) collapses only while there are several carets, so with one it
keeps its meaning.

**Editing.** `MultiCaretEditing.swift` works out one edit per caret with the
same rules as one caret (`AutoEdit.typingEdit` for pairing, skip-over and
wrapping; `AutoEdit.newlineEdit` for Return's indent; the Python clause
realign; composed characters and surrogate pairs are never split), then
`MultiCaret.resolve` sorts them and clips overlaps (two carets deleting the
same character delete it once). They are applied **from the last caret to
the first, each as its own storage edit** through
`shouldChangeText(in:replacementString:)`, then one `didChangeText` for the
lot, inside one undo group. `didChangeText` per caret ran the window's whole
text-changed path (status, preview, outline, owl…) once per caret: 518 ms a
key at 800 carets on a 400-line file, against 62 ms with one call (same
machine, load ~5). Why not the alternatives:

- not one `beginEditing`/`endEditing` bracket (27 ms in the same test),
  because `storageEdited` then sees only the union `editedRange`: carets on
  line 1 and line 200,000 would make the line index and the colouriser rescan
  the whole span on every key, and bookmarks and git bars would follow the
  union, not each edit;
- not `shouldChangeText(inRanges:)`, whose multi-range undo corrupted text.

The group also holds two caret records (the bookmarks' pattern): one made
before the edits puts the carets back after the text's own undo, one made
after them puts them back after redo. One ⌘Z undoes one multi-caret edit.

**Input methods.** Marked text (a dead key's ´, Japanese) composes at the
primary only; carets follow the composing text (`textEdited` shifts them for
any edit the layer didn't make). On commit NSTextView puts the text in at the
primary and the layer inserts it at every other caret, in one undo step.
Spelling and Writing Tools replacements (an `insertText` with another range)
act on the primary and collapse the rest.

**Paste and copy.** A clipboard with exactly as many lines as carets (a
trailing newline ignored) goes one line per caret; otherwise the whole text
at each. Copy and cut join the selections with "\n" in document order, as
AppKit does.

**Column selection.** The ⌥-drag tracking loop is the editor's own (AppKit's
can't give a zero-width column): one caret or selection per text row the
rectangle crosses, from `characterIndexForInsertion` at the start's x to the
current x, so a shorter row gets a caret at its end. Rows are TextKit line
fragments, so a wrapped line gives one per row.

**Drawing.** Extra selections and carets are drawn in `drawBackground`, for
the viewport only (`forEachSegment`), in the theme's selection and caret
colours. Extra carets don't blink. Occurrence highlighting pauses while
there are several carets, and the status bar shows "N carets" in place of
Ln/Col.

**Limits.** At most 10,000 carets (1,000 in large-document mode), with a
beep beyond. ⌃⇧↑/↓ and ↑/↓ step through logical lines (a wrapped line's
rows aren't stepped through by the extra carets). Typing at many carets is
one undo step per key, not one per typing run. Carets aren't saved in the
session.

**Checks.** `MultiCaretTests` (merging, overlap, ordering, deletes, goal
columns, paste split, occurrences); `CEDRIC_CHECK=multicaret` drives ⌥-drag,
⌘-click, ⌃⇧↓, ⌘D, ⌃⌘G, ⎋, typing, Backspace, Return, paste, copy, undo and
redo, the dead key, IME and auto-close with real key and mouse events, checks
the drawn glyphs and carets, and that ⌘D in a save alert is still Don't
Save. `typing-check.sh` types at three carets in every theme and commits IME
text at three carets.

## Highlighting: hand-written tokenizers vs tree-sitter

Chosen for v0: hand-written, line-at-a-time tokenizers.

| | Hand-written (chosen) | tree-sitter |
|---|---|---|
| Dependencies | none | C runtime + one generated parser per language (each parser.c is hundreds of KB to several MB of C), plus Swift bindings |
| 10 MB file | only the viewport ±80 lines is tokenized; stateless languages (JSON, YAML) never scan above it; measured 7.5 ms to jump to the end of a 10 MB JSON | full parse of the file before the first colour (tree-sitter parses incrementally after that), and a syntax tree in memory several times the file size |
| Correctness | lexical: keywords, strings, comments, numbers, multi-line strings and comments, fenced code, embedded script/style. No semantic scopes | real grammars: nesting, context, injections |
| Effort per language | 20–100 lines (a `CodeSpec` for C-like languages) | a grammar dependency and highlight queries per language |

Measured, not estimated: the numbers in `perf.md` (scratch) and the 10 MB
test in `EngineTests`. Tree-sitter was not built or benchmarked here; its
column is from its design (whole-tree parse, generated C parsers), not from a
measurement on this machine.

How it works: `Tokenizer.tokenize(line, state:inout, into:)` scans UTF-16
code units; `state` carries open block comments, multi-line strings, code
fences or HTML modes to the next line. `HighlightEngine` caches the state at
each line start; an edit drops the cache from the edited line down.
`SyntaxColorizer` colours the viewport plus a margin as foreground-colour
attributes on the text storage (not registered with undo, skipped while an
input method has marked text), remembers which lines are coloured, and
uncolours from an edit down. Typing attributes are reset to the theme's text
colour on every selection change, so new text never inherits a token's colour
or a default black. (v0 used TextKit 2 rendering attributes; after the
"typed text invisible" report on the first test build they were replaced by
the ordinary attribute path, which TextKit re-lays out and redraws like any
edit. `Scripts/typing-check.sh` checks typing in every theme.) Lines longer than 20,000 characters are coloured up to that point; in large mode (below) colouring is paused.

A tree-sitter tokenizer could later implement the same protocol for one
language where lexical colouring isn't enough.

**PowerShell, batch, .reg** (`PowerShellTokenizer.swift`,
`WindowsTokenizers.swift`). PowerShell has its own tokenizer, not a
`CodeSpec`: an expandable string's `$( … )` is code that may hold another
string with its own subexpression, so the string scanner calls back into
the code scanner (stopping at the `)` that balances it), to any depth on
one line. State carries `<# … #>`, a `'…'` or `"…"` string open at the
line end, and here-strings (`@'` / `@"` ending a line; closed only by
`'@` / `"@` at column 0). A subexpression left open at a line end inside
a string isn't carried (the next line is string again). `#` is a comment
only at a token start (`fix#1` is a word); `[` after a name, `)` or `}` is
an index, otherwise a `[type]` or, when a `(` follows the name, an
`[Attribute(…)]` whose arguments are code. Verb-Noun words are cmdlets
when the verb is an approved one (`Get-Verb`) or the word follows
`function`/`filter`. Sniffing (`PowerShellSignals`): `param(`,
`function Verb-Noun`, `[CmdletBinding(`, `$PSVersionTable`, common
cmdlets, `$x = ` and `-eq` score PowerShell, and a line that scores is
not also counted as shell (its `$variables` would be). The owl's bracket
check has a PowerShell lexer (`RulesHintProvider.scanPowerShell`):
here-strings are skipped whole, `$( … )` inside strings is scanned as
code, `${any name}` and backtick escapes are skipped, and typographic
quotes are quotes (PowerShell accepts them), so they are never "curly
quotes in code". The outline lists `function`/`filter`/`class`/`enum`
lines outside block comments and here-strings (`PowerShellOutline`).
Batch and .reg are stateless line tokenizers; .reg is data for spelling.

## Large documents (long lines, big files)

Derek's report: opening a 636,293-character file that is one line (a game
add-on import string, base64-like, no newline) made Cedric sluggish and
set the owl thinking. Measured on this M4 Pro with `CEDRIC_PERF_BIG`
(LargeDocPerf.swift), owl on, before → after:

| His file | before | after |
|---|---|---|
| open to first window drawn | 2,177 ms | 71–87 ms |
| keystroke, median (start / middle / end of the line) | 105 / 110 / 107 ms | 4.4 / 5.8 / 3.4 ms |
| keystroke, worst | 120 ms | 26 ms (the first one) |
| scripted scroll, worst step | 106 ms | 3–6 ms |
| idle CPU, owl on | 1.0 % | 0.4 % |

Where the time went: TextKit 2 lays out a paragraph as a whole, so every
keystroke and every newly exposed scroll position re-typeset the whole
636 K line (~0.16 µs per character; wrapping off was no cure: 100 ms per
keystroke unwrapped). The first full layout was forced by the owl's
`appeared()` (`layoutSubtreeIfNeeded`), which is why the open took 2 s with
the owl on and 0.44 s without. The highlighter costs nothing on that file
(plain text) but its whole-document `addAttribute` in `recolorAll` was a
second full relayout (57 ms). Reading, decoding, the line index and
language detection are 1–3 ms each. Keystroke cost by line length,
unchunked, wrapping on: 5 ms at 20 K characters, 9 ms at 40 K, 24 ms at
80 K, 34 ms at 160 K, 142 ms at 636 K.

What Cedric does now:

- **Chunked layout.** `ChunkedContentStorage` (an `NSTextContentStorage`
  subclass) hands TextKit lines longer than `LargeDocument.chunkLength`
  (2,048) as consecutive text elements of that length instead of one
  paragraph, so TextKit lays out only the chunks near the viewport and
  re-lays out only the chunk being edited. The text is untouched (copy,
  save, find and the line index see one line); a chunk boundary is a
  forced row break on screen, so a wrapped row ends early there. Chunks
  start at fixed steps from the line start (moved back so they never split
  a composed character), so an edit only drops the cached chunk elements
  from the edit on. Chunk elements are `NSTextParagraph`s with their
  content and separator ranges supplied (TextKit raises without them).
  Lines that fit in one chunk get TextKit's own paragraph (making those
  ourselves broke its height estimates: scrolling a 6 MB many-line file
  snapped back).
  Chunk size, measured: 500 → 31 ms per keystroke (too many elements),
  1,000 → 6–10 ms, 2,048 → 6.5 ms, 4,096 → 6.7 ms, 8,192 → 7.6 ms.
  Wrapping stays as the user set it: chunked, wrapped and unwrapped cost
  the same, so there's no reason to turn it off.
- **Large mode** (`LargeDocument` in CedricCore): on when any line is
  longer than 20,000 characters (from the table above: well under a frame
  on slower Macs) or the document is longer than 5,000,000 UTF-16 units.
  Checked before the text reaches TextKit on open, reload and restore, and
  after each edit for the edited lines only (a long paste turns it on; the
  pause takes effect for that same edit, the chunks a run-loop turn later).
  Typing a line short again doesn't turn it off; a new text does. It
  shows a slim bar ("Very long lines: colouring, spell check and the owl
  are paused for speed. [Turn On Anyway]"), pauses colouring
  (`SyntaxColorizer.paused`, including the whole-document recolour), spell
  checking (`EditorSpelling.apply`, and the owl's typo offer) and the
  untitled-tab language sniff. "Turn On Anyway" brings those and the owl
  back; the chunks stay.
- **The owl never analyses the whole document.** The rules only ever see
  the `OwlContextWindow` (≤ 8 KB around the viewport; a test checks this on
  a 636 K line). In large mode the owl stays idle: no scheduled rules
  query, nothing fed to the AI. Clicking him runs the rules once on the
  window (`OwlCoordinator.queryNow`, rules only); with nothing to say he
  shows his popover as before. His caret-avoidance no longer asks TextKit
  for the rect of a caret that is scrolled out of view (that laid out up to
  the caret and re-anchored the viewport: scrolling stalled).
- **AI gates, every engine.** `OwlScheduler` never asks for a document
  marked large (`setLargeDocument`, kept by `LocalAIOwlBridge` across
  scheduler rebuilds; going large cancels a request in flight), and asks
  only once a document has been open and untouched for `minIdle` (10 s,
  `LocalAISettings.minIdle`; settings saved before it existed load with
  10). The built-in llama.cpp engine loads its model on the first request,
  so a large document never loads a model.
- **Per-keystroke work** is O(edit) or O(log n): the line index, the
  status bar's Ln/Col (a binary search and a subtraction), the gutter
  (numbers the first fragment of each line only, so chunks of one line
  don't repeat its number), and the session autosave (coalesced to 1.5 s,
  written off the main thread, see Session restore).

Checks: `LargeDocumentTests` (triggers, chunk tiling, composed
characters, the capped owl window), `LargeDocumentGateTests` (no request
for a large document, the 10 s idle gate, the bridge keeping marks across
rebuilds, old settings), `CEDRIC_CHECK=large` in `Scripts/tools-check.sh`
(opens a 636 K line with the owl on: bar, chunks, paused extras, typing
through real key events under 16 ms, no owl query or AI feed, click → one
rules query and a bubble, Turn On Anyway, a long paste; snapshots), and
`Scripts/perf-check.sh` (a generated 636 K base64 line and a 6 MB log
with thresholds: open < 300 ms, keystroke median < 16 ms at start, middle
and end, worst scroll step < 50 ms with no snap-back, idle CPU < 3 %;
`--file` runs it on any file).

## Preview

`PreviewController` wraps a `WKWebView` created only when the preview is
first shown (no WebKit work at launch). Markdown goes through
`Markdown.render` into a themed page; HTML is shown as written. Safety:

- JavaScript: off (`WKWebpagePreferences.allowsContentJavaScript = false`)
  unless View › Allow JavaScript in Preview.
- Network: off unless View › Allow Network in Preview: a compiled
  `WKContentRuleList` blocks http(s), ws(s) and ftp loads, and a
  Content-Security-Policy meta tag is injected as a second layer.
- Non-persistent website data store; clicked links open in the browser.

The preview bar (`PreviewBar` in `PreviewPane.swift`) sits in the pane's
24 pt header, docked or detached. Which controls a preview gets is
`PreviewBarItem.items(for:certificate:)` in CedricCore (Markdown: refresh,
sync, zoom −/+, export, JavaScript, network, detach; HTML the same without
export; CSV: row count, Unsort, refresh, sync, zoom, detach; the
Certificate panel: refresh, detach). The tab recomputes a
`PreviewBarState` after each render, toggle, detach/attach and CSV sort
(`updatePreviewBar`, a no-op when nothing changed). Buttons are fixed-size
SF Symbols laid out from the right edge, so toggles and a changing row count
never move anything. Zoom steps through `PreviewZoom.ladder`
(`WKWebView.pageZoom` for the web preview, the grid's font and row height
for CSV). Refresh drops the loaded page (`forceReload`) so the next render
is a whole load. Sync off stops scroll sync both ways until it is on again.
The View menu's JavaScript/Network items still work; the bar follows them.
Nothing of it exists until a preview is first shown.

Scroll sync: Markdown blocks carry `data-line`; the app scrolls the preview to
the last block at or above the editor's top line (in the app's own content
world, so it works with page JavaScript off). HTML scrolls by fraction.

The preview sits in a `PreviewPane` (a 24 pt header with Detach / Attach,
and a `PreviewRenderer`: the web view, or the CSV grid). **Detach Preview**
moves the pane into a `PreviewWindowController` window owned by the tab,
so it stays bound to that document (not the front tab) and closes with
it; the same debounced `renderPreview` feeds it. `SessionTab` keeps
`previewDetached` and `previewFrame`; restore detaches with
`AfterFirstFrame`, so a restored detached preview costs nothing before the
first frame and nothing at all when there is none.

**CSV / TSV grid** (`CSVPreview`): `CSV.parse` (CedricCore, RFC 4180,
UTF-16 offsets) on a background queue from an immutable copy of the text
(at most 16 M characters, 2 M in large mode), at most 50,000 rows shown,
a generation counter dropping stale results. A view-based `NSTableView`
(cells only for visible rows), row numbers in an `NSRulerView` (clipped to
its bounds), sorting by header on the same queue (view only), a click
maps the view row back to the record's start and `CSV.fieldOffset` for the
caret. `CSV.dialect` sniffs a `Dialect` from the first 50 lines (64 K):
the delimiter (Excel `sep=X` line, then extension, then the candidate
whose most common per-line count is most consistent, quotes opening only
at a field start, blank lines ignored, all-decimal commas losing to a
consistent semicolon), `skipInitialSpace` (60 % of in-line delimiters
followed by a space; never tab), `trimTrailingSpace` (60 % preceded by
one) and `edgeDelimiters` (every line a `| … |` pipe row). The parser and
`fieldOffset` both follow it, so a click still lands in the right field.
Table-driven samples in `CSVDialectTests`.

**Closing the last window** (`AppDelegate.isClosingLastDocument`,
`quitAfterLastClose`): a document tab's `onClose` (text, PDF, image,
Office, certificate) asks, before the tab leaves its list, whether no other
document tab exists and no restored tab is still pending. The tab is then
hot-closed like any other (`rememberClosed`/`rememberClosedViewer`: in the
closed list, unsaved text in its buffer), and only then does the quit path
run (`prepareToQuit`: synchronous session save, waiters released) and
`NSApp.terminate` on the next turn. So the next launch has no open tab
(an empty Untitled one) and ⇧⌘T brings the closed one back; Quit (⌘Q)
alone keeps every open tab open. Other windows
(detached previews, Settings, panels, the owl) don't count.
`applicationShouldTerminateAfterLastWindowClosed` gives the same answer
for AppKit's own case (e.g. Settings closed last). Off before launch has
finished, under the dev hooks (unless `CEDRIC_TEST_QUIT_ON_LAST_CLOSE=1`)
and with the setting off. File › Close Window on the only window hot-closes each tab, then quits.

## Editor tools

Notepad++'s everyday extras. The logic is in CedricCore (tested without a
window); the app side is `EditorTools.swift`, `FindInFilesPanel.swift` and
`CompareView.swift`.

| Feature | Menu | Shortcut |
|---|---|---|
| Open Recent | File › Open Recent (+ Clear Menu) | ⌥⌘1 … ⌥⌘9 |
| Sort lines A→Z / Z→A / numerically | Edit › Text Tools | ⌃⌘S / ⌃⇧⌘S / ⌃⌥⌘S |
| Remove duplicate lines / reverse lines | Edit › Text Tools | ⌃⌘R / ⌃⇧⌘R |
| Join lines / trim trailing whitespace | Edit › Text Tools | ⌃⌘J / ⌃⌘W |
| UPPER / lower / Title case | Edit › Text Tools | ⌃⌘U / ⌃⌘L / ⌃⌘T |
| JSON pretty-print / minify, XML pretty-print | Edit › Text Tools | ⌃⌥⌘J / ⌃⌥⇧⌘J / ⌃⌥⌘X |
| Base64 encode / decode, URL encode / decode | Edit › Text Tools | ⌃⌘B / ⌃⇧⌘B, ⌃⌘E / ⌃⇧⌘E |
| Find in Files | Edit › Find in Files… | ⇧⌘F |
| Replace in Files (+ Undo Replace in Files) | Edit › Replace in Files… / Edit › Undo Replace in Files | ⌥⇧⌘F / none |
| Compare two tabs | View › Compare With… (next/previous difference) | ⌥⌘C (⌥⌘↓ / ⌥⌘↑) |
| Follow a log file | View › Follow File | ⌥⌘T |
| Folder sidebar | File › Open Folder… / View › Show Folder Sidebar | ⇧⌘O / ⌃⌘1 |

`CEDRIC_DUMP_SHORTCUTS=1` prints every key equivalent in the main menu and
exits 1 on a clash with another item or with a system shortcut (Lock Screen
⌃⌘Q, Look Up ⌃⌘D, Spotlight, screenshots…).

- **Open Recent** reads and writes NSDocumentController's recent-documents
  list (the system one, shared with the Dock menu) although Cedric doesn't
  use NSDocument: `AppDelegate.noteRecent` records opens and saves and
  rebuilds the submenu, so its key equivalents always match the list.
  Clear Menu uses Cedric's own action, so NSDocumentController doesn't try
  to manage (and reopen through NSDocument) the menu itself.
- **Text tools** (`TextTools`, `JSONFormatter`): pure `String → String`
  functions. They apply to the selection, or the whole document when
  nothing is selected; line tools widen a partial selection to whole lines.
  The change goes through `shouldChangeText`/`didChangeText` inside one
  undo group named after the tool, so one ⌘Z undoes it. JSON is
  re-printed by a small validating parser that keeps key order and number
  spelling (JSONSerialization does neither) and reports the line and column
  of an error; XML uses `XMLDocument`. Errors show as an alert sheet and
  leave the text alone. The owl's "Format it?" hint uses the same
  formatter (`JSONFormatter.prettyIfMinified`), so both give identical
  text. The output is inserted with `baseAttributes()` (theme text
  colour) through the text storage, as typed text is, so it is never
  drawn in a stale or default colour before the highlighter runs; a
  whole-document transform leaves the caret at the start. tools-check
  samples the pixels of pretty-printed JSON in the Dracula theme the way
  typing-check samples typed text.
- **Find in Files** (`FileSearch`): collects the files under the folder
  (exclude globs match any path component, so `.git`, `node_modules`,
  `build`, `dist` skip whole folders; include globs match the file name, or
  the relative path if they contain `/`), sorts them, and searches each on
  a background queue with the same regex builder as the find bar. Files
  over 20 MB and binaries (a NUL in the first 8 KB, UTF-16 with a BOM
  excepted, or undecodable) are skipped and counted. One result per
  matching line, batched to the main queue at most every 50 ms or 200
  results, capped at 10,000; Stop sets a flag checked per file and every
  256 results. The panel is one view, docked in the split view of whichever
  tab is selected; a click opens the file with the match selected. The
  results are a two-level `NSOutlineView` (file row with its count, then
  `line: text` rows), view-based, filled incrementally per batch.
  **Respect .gitignore** (on by default) uses `GitIgnore`: a pure matcher,
  no git process (the `/usr/bin/git` stub without the Command Line Tools,
  and a process per search, ruled git out). It finds the repository root
  above the folder (or uses the folder), reads `.git/info/exclude` (a
  worktree's through `commondir`) and each `.gitignore` lazily as the walk
  reaches its folder; deeper files win, the last matching line wins, `!`
  can't re-include below an ignored folder, `**` follows wildmatch.
  Not read: `core.excludesFile`; matching is case-sensitive (git's
  `core.ignoreCase` isn't read). Each result also carries its matches as
  offsets into the whole decoded file and the file's stamp at search time.
- **Replace in Files** (`FileReplace`, `ReplaceInFiles+App.swift`): the
  same panel with its Replace box on (⌥⇧⌘F turns it on; for Find users the
  panel looks as before). Data safety is the design:
  - *Preview first.* Preview Replace… (or Return in the Replace field)
    re-runs the search if the fields changed, then `FileReplace.plan` runs
    off the main thread: per file, every match and its replacement through
    `FindEngine.regex`/`FindEngine.replacement`, so `$1` and the case
    option behave exactly as the find bar's Replace All. The list turns into
    the preview: a box per file and per match (`before → after`, the match
    struck through, the replacement highlighted), a summary ("N
    replacements in M files. Skipped: …") and a Skipped group listing each
    left-out file and why. The fields lock while it shows. A capped
    (10,000) search is never replaced.
  - *What is skipped.* Binary, over 20 MB, mixed line endings
    (`TextCodec.decode` normalises them, so writing back would rewrite every
    ending; open the file to replace there), bytes that don't decode and
    re-encode to exactly the same bytes, a replacement the file's encoding
    can't hold, a file changed since the search (date, size), symbolic
    links, hard-linked files, and anything outside the folder.
  - *Open tabs.* A file open in a tab (tabs restored lazily are built
    first) is planned from the tab's text and edited through
    `replaceAsOneStep` as one ⌘Z step named Replace in Files; it is marked
    unsaved and never written behind the tab's back. At Replace All the
    tab's text must still be the previewed text, else it is skipped.
  - *Writes.* Replace All acts on the checked matches only. Each file is
    re-read and must still match the preview's date, size and SHA-256;
    then every target's original bytes go to
    `~/Library/Application Support/Cedric/ReplaceUndo/<uuid>/` (0700,
    `manifest.json` with path, mode, SHA-256 of the original and of the
    written bytes; the last 5 operations or 7 days are kept) before the
    first write. Each write is atomic: a temp file in the same folder, the
    original's mode, ACL and extended attributes copied onto it
    (`copyfile`), renamed over the file, in the file's own encoding, BOM
    and line ending.
  - *Undo.* Edit › Undo Replace in Files (and the panel's Undo Replace)
    covers the last operation until quit: it restores each written file
    whose bytes are still exactly what was written (others are skipped and
    reported), and undoes each tab edit that is still the top of that tab's
    undo stack with the text left by the replace. The manifest survives a
    crash; recovery from it isn't offered in 0.2.0.
  - Zero cost when unused: nothing new runs at launch, the panel is built
    on first use, and the undo store is touched only by a replace.
- **Compare** (`LineDiff`): Myers' O(ND) diff over lines (interned to
  integers, common prefix and suffix trimmed first). It keeps each step's
  diagonal array for the walk back, O(D²) memory, so past 4,000 differences
  the middle is shown as one replaced block. A run of deletions followed by
  insertions pairs up as changed rows. `DiffView` draws only the visible
  rows: added, removed and changed lines are the theme's background mixed
  with green, red and amber; the differing part of a changed line is
  stronger. A snapshot of the two texts, read-only, in its own tab.
- **Follow File** (`FileTail`): a DispatchSource on the file (write, extend,
  delete, rename, revoke). Growth reads only the new bytes from the last
  offset, holding back a character or CRLF cut in half; a smaller size or a
  new inode (truncate, replace) re-reads the whole file; delete or rename
  (rotation) polls every 250 ms until the path exists again and starts
  over. The tab is read-only while following, stays clean, and appends
  without `didChangeText` (the line index and colouring update from the
  storage edit). It scrolls to the end only if it was at the end.

Checks: unit tests in `EditorToolsTests.swift` (every transform, the diff
against a brute-force LCS, the walker on a temp tree with excluded
folders, a binary and a 21 MB file, tail on append, truncate, rotate and a
split UTF-8 character), `GitIgnoreTests.swift` (57 root-pattern cases
checked against `git check-ignore`/`git ls-files -i`, nested files,
info/exclude, worktrees, the walker) and `FileReplaceTests.swift`
(byte-exact UTF-8/BOM/UTF-16/Latin-1/CRLF/CR round trips, skips, `$1`,
stamps and hashes, mode and xattrs, undo, pruning, links). In-process: `Scripts/tools-check.sh` launches the
app once per feature with `CEDRIC_CHECK=…` (`DevChecks.swift`), drives it
with key and mouse NSEvents and writes snapshots. When Cedric can't become
the active app (screen locked, launched from a script) there is no key
window and AppKit won't route a synthetic key equivalent or a click on a
table: the check then sends the matching menu item's action along the front
window's responder chain, and selects the clicked row and sends the table's
action, and says so in its output.

## Folder sidebar

File › Open Folder… (⇧⌘O), a folder dropped on the Dock icon or on an
editor window (the text, or anywhere beside it: `FileDropStackView`), or
`cedric some/dir` (all reach `AppDelegate.open`, which routes a folder
that isn't a package to `openFolder`) shows a folder tree at the left of
the editor. View › Show Folder Sidebar (⌃⌘1) hides and shows it; it is
disabled until a folder is open. The model is `CedricCore/FolderTree.swift`
(tested in `FolderTreeTests.swift`); the app side is `FolderSidebar.swift`
and `FolderWatcher.swift`. `cedric -w some/dir` returns at once: `-w`
waits for each file's tab, a folder has none, so the app deletes the
folder's wait marker as it opens it (the `cli` check).

- **Invisible until used.** Nothing is built at launch: no view, no
  listing, no FSEvents stream, no per-tab object. A session with a
  folder whose sidebar was hidden only remembers it
  (`FolderSidebar.pendingFolder`); the sidebar is built on the first
  ⌃⌘1.
- **One sidebar for the app**, like the Find in Files panel: every tab is
  its own NSWindow, so the one `FolderSidebar` is docked at index 0 of the
  selected tab's `split` (`EditorWindowController.dockLeftPanel`) and moved
  on `tabBecameKey`. A re-dock is one remove + insert (5–13 ms in the
  check, including the tab switch). The outline sidebar stays inside the
  editor pane, so both can show: Folder | Outline | gutter | text, with the
  preview and Find in Files still docked to the right (the split is
  searched by identity, never by count).
- **Width.** NSSplitView shares space out by proportion when the window
  resizes or a panel docks, whatever the holding priorities, so the
  sidebar puts its width back after any resize that isn't the user
  dragging its divider (a mouse event in that window, not a live window
  resize). A divider drag is kept and saved.
- **Lazy listing.** Only expanded folders are listed: `FolderTree.list`
  reads one level with `contentsOfDirectory` and the directory, hidden,
  package and symlink keys, on a background queue. Folders first, then
  Finder's order (`localizedStandardCompare`). `.git` and `.DS_Store`
  never show; hidden files show with the context menu's Show Hidden Files.
  Packages are files. A symbolic link to a folder can be expanded unless
  its real path is that of a folder above it (`FolderTree.wouldLoop`). A
  20,000-entry folder is a unit test (`twentyThousandEntriesListQuickly`).
- **Git-ignored entries are dimmed**, not hidden. `FolderIgnore` (in
  `FolderTree.swift`) wraps the `GitIgnore` matcher Find in Files uses: it
  is made on the sidebar's first listing (no folder open, no cost), and
  marks each listed entry by its place in the tree, reading a
  `.gitignore` only when a listing reaches its folder (and the ones
  above it, once), never walking the tree. Listings run on background
  threads, so it takes a lock. An FSEvents batch drops what it has read;
  a changed folder that has a `.gitignore` re-lists its loaded subtree,
  and rows whose flags changed are reloaded in place (`Diff.changed`).
- **Updates.** `FolderWatcher` is an FSEvents stream on the root (no
  per-file events, 0.3 s latency, its own utility queue), running only
  while the sidebar shows; hiding stops it, showing again re-lists the
  loaded folders once. An event re-lists the folder it names if that
  folder is loaded (events under folders never expanded cost a path walk).
  `FolderNode.apply` diffs the new listing against the old by name and
  kind and keeps the nodes that stayed, so the outline gets
  `removeItems`/`insertItems` and expansion and selection survive. A
  dropped-events flag re-lists the loaded subtree; the root going away
  closes the folder. FSEvents report real paths (`/private/var/…`), so
  paths are matched against the root's `realpath` as well as the path
  as opened.
- **Opening.** A click on a file opens it through `AppDelegate.open`
  (PDF, image, Office and binary files included) or selects its tab;
  Return does the same; double-click, → and ← expand and collapse. The
  selected tab's file is selected in the tree when its folder is
  already expanded (nothing is expanded for it). Context menu: Reveal in
  Finder, Copy Path, Find in Folder… (Find in Files on that folder), Show
  Hidden Files, Close Folder.
- **Session.** `Session.folder` (`SessionFolder`: path, visible, width,
  expanded folders as relative paths, parents first, at most 200, show
  hidden) is optional, so 0.1.x sessions decode. A visible sidebar is
  rebuilt through `AfterFirstFrame`, a frame after the window, and its
  expanded folders are expanded top-down as their parents are listed.

Checks: `CEDRIC_CHECK=folder` (`FolderCheck.swift`) opens a temp tree the
way a dropped folder arrives and drives it with a click on a disclosure
triangle, → on a selected folder, clicks and Return on files, dimmed
git-ignored rows (and an edited .gitignore re-dimming them), ⌃⌘1 twice
and the × button; it creates, deletes and renames files on disk and waits
for the rows, checks the loop guard, the layout with the preview and Find
in Files docked too, the re-dock on a tab switch, that the stream stops
while hidden, the session state, and snapshots light and dark.
`render-check.sh` renders the sidebar beside typed text in a light and a
dark theme; `session-check.sh` restores a saved folder after a kill -9.

## Git and GitHub links

`CedricCore/Git.swift` (tested in `GitTests.swift`) and
`CedricApp/GitIntegration.swift`. No network, no sign-in, no GitHub API.

- **Finding the repository**: `GitLocation.find` walks up from the file's
  folder to a `.git` folder (with a HEAD) or a `.git` file
  (`gitdir: …`: a linked work tree or submodule). File lookups only.
- **Which git**: `GitRunner` looks once, on the git queue, for a git
  outside the system (`/opt/homebrew/bin`, `/usr/local/bin`, MacPorts, the
  PATH), else `/usr/bin/git` only when `xcode-select -p` names a
  developer folder that exists: without the tools that git is a stub that
  pops up the install dialog, so Cedric does nothing instead. Each run sets
  `GIT_OPTIONAL_LOCKS=0` (a status never takes the index lock),
  `GIT_TERMINAL_PROMPT=0`, and has a 10 s timeout.
- **When**: nothing at launch. A tab with a file queues
  `gitTabShown` with `AfterFirstFrame`; 0.5 s later, if the window is on
  screen and typing has paused, the first refresh runs (an unselected
  restored tab starts when it is first selected). Never in large mode,
  never for untitled tabs. A refresh (on save, app focus, reload, or a
  change in the git folder) runs on one serial utility queue:
  `status --porcelain=v2 --branch -z -- file` (branch, HEAD, upstream and
  whether the file differs or is untracked, in one process),
  `rev-parse --show-prefix` once per tab, `config --get remote.origin.url`,
  and `show <HEAD>:./file` only when HEAD moved.
- **Watching**: one `GitRepo` per git folder, shared by its tabs, holds a
  vnode dispatch source on the git folder itself: git replaces HEAD and
  index by renaming a `.lock` file, which is a write to the folder (a
  source on the files would lose them at the first rename). Debounced
  0.3 s, then the tabs refresh.
- **Gutter**: the buffer is diffed against HEAD's text in-process with
  `LineDiff`, off the main thread, 0.4 s after typing pauses (an immutable
  copy of the text is taken on the main thread). `GitLineChanges.compute`
  turns each hunk into marks: as many inserted lines as deleted are
  modified, the rest added, and a surplus of deletions leaves a deleted
  mark below the hunk. Until the next diff, an edit shifts the marks below
  it (`shift`), so they don't sit on the wrong lines while typing. A result
  computed from text that has since changed is dropped. The bars are 3 pt
  at the gutter's right edge, clear of the bookmark tabs on the left and
  the numbers, drawn clipped to the gutter; colours are GitHub's, lighter
  on dark themes.
- **Links**: `GitHubRemote.parse` reads https, scp-style and `ssh://`
  remotes; any host with "github" in its name counts (github.com, GitHub
  Enterprise hosts such as github.example.com), others disable the
  GitHub items. The ref is the branch when it has an upstream, else
  HEAD's commit. Lines come from the buffer (with no selection, the
  caret's line), so they can drift from the commit's after edits.
- Checked by `CEDRIC_CHECK=git` in tools-check: a temp repository with a
  GitHub remote, the file edited with key events, the label and dirty dot,
  the marks and their pixels, the copied link, Compare with Last Commit,
  a commit and a detached checkout made outside the app (seen through
  the watcher), and a file outside git.

## Where the remaining non-goals plug in

- **Macros:** record the `NSTextView` insert/delete commands the window
  controller already routes.
- **Local AI hints:** an `OwlHintProvider` registered with `isAI: true`
  (see *Cedric the owl*); it gets the same 8 KB context as the rules.

## Cedric the owl

View › Show Cedric the Owl (off by default, `Settings.showOwl`). A 72 pt owl
sits in the bottom-right corner of the editor, above the status bar, and
offers hints in a speech bubble.

**Core** (`CedricCore/Owl`, Foundation only, unit-tested in `OwlTests`):

- `OwlHint.swift`: the shared contract (`OwlHint`, `OwlContext`,
  `OwlHintProvider`), identical in the ai-owl branch.
- `OwlContextWindow` builds the context: the visible lines ±40, whole lines,
  capped at 8,192 UTF-16 units (a smaller document is sent whole).
  **Ranges:** `visibleRange`, `selection` and every hint's `range` are
  relative to `context.text`; `context.textStart` is where that text starts
  in the document. The coordinator moves a hint's range by `textStart` and
  drops the hint if the result is out of the document's bounds or the
  document's edit generation (`EditorDocument.changeCount`) moved while the
  providers ran. The rules provider follows the same convention (its ranges
  are document ranges only when `textStart` is 0). Apply checks once more
  that the text at the range is still what the provider saw.
- `RulesHintProvider` (no AI): one-line JSON → "Format it?" (re-indents
  without reordering keys; whole document only); mixed tab/space
  indentation → convert tabs to spaces; ≥5 lines with trailing whitespace →
  trim (not in Markdown, where two spaces are a line break); file changed
  on disk under unsaved edits → "Reload?"; unsaved for over 2 h → "Save a
  copy?"; CRLF → an info line; and a document that starts with "Dear " and
  has more than three lines gets, once ever, "It looks like you're writing a
  letter. Would you like help?" with "No thanks, I'm an owl" as the only
  button. The document facts it needs come in `OwlDocumentFacts` through
  `OwlFactsAwareProvider`.
  In a window of a longer file (`OwlContext.isWholeDocument` false),
  fixes say they change only the part around the screen; the JSON format
  offer appears for a long one-line file whose start is in view, with no
  replacement, and Fix it validates and formats the whole text off the
  main thread (`RulesHintProvider.formatWholeJSON`, `formatWholeJSON` in
  OwlController.swift, one undo step), or says the file isn't valid JSON.
  AI claims that the JSON doesn't parse are dropped for a window (a
  fragment never parses).
  `MoreRules.swift` adds (in the order offered): merge-conflict markers,
  secrets (warning, no fix), JSON that doesn't parse, brackets (a small
  lexer skipping strings, comments, JS and Swift regexes and Swift/JS
  interpolations; whole documents only, "never closed" only when saved,
  and no "never closed" or extra closer in C with `#if`/`#else`), the
  word typed twice (one plain space or a line break between; not
  case-differing pairs, nor "die die", "nous nous" and the like),
  curly quotes in code, YAML tabs, then mixed indentation (minority →
  majority), invisible characters, to-do list → checkboxes, plain text
  that sniffs as Markdown/HTML/JSON (`rules.language-guess.<lang>`, "Use
  <Language>"), doubled words, inconsistent double spaces, trailing
  spaces, a missing final newline (saved code files, caret elsewhere),
  mixed line endings. A hint with a range and no replacement gets **Show
  Me** (selects it, if the text is unchanged). `OwlMoreRulesTests` covers
  each one firing and its near misses, and a timing bound on a full 8 KB
  window.
- `OwlProviderRegistry`: providers in order; `register(_:isAI:)`. View ›
  Owl Hint Source › Rules + AI is disabled until an AI provider registers.
- `OwlCoordinator`: asks at most once per 30 s and only after 3 s without
  typing (activity = an edit, an open, a file changed on disk); shows each
  hint id once per document; "Not now" snoozes the id for an hour; "Don't
  show again" is saved in UserDefaults (`owlNeverShowHints`); "Quiet for 1
  hour" stops queries. No timers: it reports `nextDueDate`, on an injected
  clock.

**App** (`CedricApp/Owl`):

- `OwlHub` (one per app) owns the registry and coordinator and a single
  one-shot timer at the due date. Typing doesn't reset it; when it fires
  early it re-arms for the new due date.
- `OwlController` (one per tab) puts an `OwlOverlay` over the scroll view's
  content (clicks pass through except on the owl and bubble), and runs the
  idle behaviour: a blink every 4–9 s (random), a monocle polish about one
  time in eight, the sleepy pose after 5 min without typing (no timer at all
  while asleep; typing wakes it), two wing beats on save, the talking pose
  while the bubble is up. The idle timer exists only while the window is
  visible (occlusion state), not miniaturized, and the app is active.
  Blinks and flaps run a short frame timer only while they play.
- Keeping out of the way: on every selection change, edit and scroll the
  caret's rect is compared with the owl's and the bubble's frames; whichever
  is near fades to ~12% and comes back when the caret leaves.
- Apply replaces only the changed span (`OwlEdit.minimal`) inside
  `shouldChangeText`/`didChangeText` with undo coalescing broken on both
  sides, so it is exactly one undo step. "Reload" is also one undoable
  edit. Clicking the owl opens a popover with recent hints, "Quiet for 1
  Hour" and "Hide Cedric".
- Art: `Resources/Owl` (from `tools/icon/cedric_icon.py`), copied into
  OwlInk.app/Contents/Resources/Owl by `bundle-app.sh`; `swift run` loads it
  from the source tree. On dark themes a faint disc behind the navy owl
  keeps it readable.

**Checks.** `OwlTests` (throttle, pause, dedupe, snooze, never-again,
quiet, once-ever letter, textStart/generation dropping, every rule,
minimal edits). `CEDRIC_OWL_CHECK=/dir` runs `OwlCheck` in process: waits for
the JSON hint on a one-line JSON file, snapshots the bubble, clicks Apply
with real mouse events, checks the formatted text, ⌘Z once restores the
original and ⇧⌘Z reapplies, types until the caret reaches the owl and checks
it faded, ⌘S and checks it flaps. On a locked screen (every window
occluded, app inactive) it first checks the owl has no timer and made no
query, then treats the window as visible; with no key window it performs
the menu item a key equivalent maps to, and hands a click the window
swallowed to the control under it.

- **The owl assistant / local AI:** a side panel in the preview slot; the
  session store already keeps every tab's text locally. The local-AI hint
  provider exists: see *Owl AI hints* below.

## Owl AI hints (CedricAI, optional, OFF by default)

The owl can ask a small local model for coding hints. `CedricAI` is a
separate module (Foundation, URLSession, IOKit; no third-party code) that
implements the shared `OwlHintProvider` contract from `CedricCore/Owl`.

**Privacy: what is sent, where, when.**

- *Off by default.* `LocalAISettings.enabled` is `false`; while it is off
  `LocalAIOwl.makeProvider` returns nil and nothing is ever sent.
- *Where:* only to the configured OpenAI-compatible server, LM Studio
  (`http://localhost:1234/v1`) or Ollama (`http://localhost:11434/v1`), or
  the same on a LAN machine. `LocalEndpointPolicy` refuses any host that is
  not loopback, `.local`/`.lan`/`.home.arpa`, a bare LAN name, a tailnet
  `.ts.net` name, or a private/CGNAT/link-local address, before a request is
  built, and a name must also resolve only to private addresses (so a
  public Funnel `.ts.net` host or a search-domain surprise is refused; the
  connection's own lookup a moment later could still differ: DNS rebinding
  is not ruled out). Redirects are followed only to the same host and
  port, and a response over 2 MB is dropped. There is no cloud backend and
  no API-key field. The session is ephemeral (no cookies or disk cache)
  and ignores system proxies.
- *What:* `OwlContext.text` only — the visible range plus a margin, capped
  again here at 8 KB of UTF-8 — plus the language and the file name. Never
  the whole file, the path, other tabs, the selection or the clipboard.
- *When:* `OwlScheduler` decides. A check fires only after typing pauses
  for 5 s, at most once per 90 s per document, never twice for the same
  `editGeneration`, never while the app is inactive, in Low Power Mode, or
  on battery below 20 %. Each request is hard-capped at 20 s and is
  cancelled the moment the document is edited again or the app goes
  inactive; results for a stale generation are dropped.
  *Intel:* `LocalAISettings.automaticChecks` defaults to off on x86_64
  (on elsewhere). Off, the scheduler arms nothing and the hub feeds it no
  contexts; the model is asked only by the owl popover's "Ask AI Now"
  (`OwlScheduler.checkNow`, never for a large document), so nothing loads
  a model or runs one until the user asks. The settings sheet has the
  checkbox to turn automatic checks back on.
- *Logs:* one `os_log` line per request (subsystem `net.mindtricks.cedric`,
  category `owl-ai`): model, generation, bytes sent, prompt/completion
  tokens, latency, hint count. No document text, file names or model output.

**Model choice.** `GET /v1/models` (enriched from LM Studio's
`/api/v0/models` or Ollama's `/api/tags` for type, quantisation and size)
then `ModelPicker`: a Qwen coder model of 0.5–3B, else a Qwen3 of ≤ 4B,
else none and the user picks. It never auto-picks a large model, so a
default setup cannot make LM Studio JIT-load a 35B model. "Test connection"
(`LocalModelClient.testConnection`) returns the list, sizes, latency and
the suggested model.

**Prompt and parsing.** One system prompt asks for at most 2 high-confidence
hints as strict JSON (sent as a `json_schema` `response_format`; retried
without it if the server returns 400). Qwen3 gets `/no_think`. `HintPrompt.parse`
is defensive: it strips `<think>` and code fences, drops unknown kinds,
filler titles, confidence < 0.6, and any hint whose `find` snippet is not in
the context when it carries a replacement. A replacement is kept only when
it is anchored in the context, changes more than whitespace, and shares
more than half its words with what it replaces (small models sometimes
"fix" a line with unrelated code). Hint ranges are UTF-16 offsets into
`OwlContext.text`, not document offsets; hint ids are FNV hashes of source,
title and snippet, so a snoozed hint stays snoozed when lines move.

**Apple Intelligence.** `AppleFoundationModelsProvider` runs the owl's
prompts on the on-device `SystemLanguageModel` (macOS 26+, Apple silicon,
Apple Intelligence on, model ready; `AppleFoundationModelsProvider.status`
maps the framework's availability to a reason the sheet shows). The SDK's
Private Cloud Compute model is deliberately never used. A fresh
`LanguageModelSession` per request takes `OwlPrompts.system(for:)` as its
instructions; the code is trimmed to 6 KB (the on-device context is small)
and the answer is constrained by guided generation. `@Generable` needs the
`FoundationModelsMacros` compiler plugin, which only Xcode ships, so the
same shape is built at run time as a `DynamicGenerationSchema` (kind as an
enum, ≤ 2 hints) and the JSON goes through `HintPrompt.parse`. Temperature
0, at most 400 response tokens. Behind `#if canImport(FoundationModels) &&
arch(arm64)`: with CI's Swift 6.1 / macOS 15 SDK, and on Intel, a
placeholder that is never available compiles instead.

**Engines.** "Where the AI runs" is an `AIEngine` (`CedricAI/AIEngine.swift`):
availability (+ reason), `needsAddress`, an optional `note`, `models()`,
`test()`, `suggestedModel(in:)`, `makeProvider(model:)`.
`AIEngines.engine(for:)` maps `LocalAISettings.backend` to one: **Built-in
(on this Mac)** (`BuiltInEngine`, see *Built-in AI* below), **LM Studio on
this Mac**, **Ollama on this Mac**, **Another Mac on your network (URL)**
(`ServerEngine`, local/LAN only), **Apple Intelligence (on this Mac,
private)** (`AppleIntelligenceEngine`, enabled only when the on-device
model is). The sheet and `LocalAIOwl.makeProvider` only talk to the
protocol. With nothing saved yet, `LocalAISettings.load` starts on
`AIEngines.defaultBackend()`: Apple Intelligence when available, else
Built-in, else LM Studio. AI hints themselves stay off until the user
turns them on.

**Verifier and cited lines** (`HintVerifier.swift`, used by
`HintPrompt.parse` for every engine). The code is sent with line numbers
(`12| `); each hint must name its `line`, a `category` (`unclosed-tag`,
`brackets`, `unused`, `undefined`, `json`, `logic`, `other`) and the exact
`find` snippet, which must occur within two lines of the cited line or the
hint is dropped (copied line numbers are stripped). Claims we can check
deterministically are checked, by the model's category and by keywords,
and dropped when the code contradicts them: tag balance (`TagScan`:
ignores comments, doctype, CDATA, script/style bodies, void and
self-closed elements; HTML's optional end tags such as html, head, body,
p, li close implicitly; XML is strict), bracket and quote balance
(`BracketScan`, skipping strings and comments per language), "unused X"
when X occurs again, "undefined X" when X is absent or declared, and JSON
validity (`isStrictJSON`: JSONSerialization plus a trailing-comma check,
since recent Foundation accepts trailing commas). Checks only ever drop:
a slice of a bigger file can look unbalanced, so a failed check keeps the
hint. The prompt asks for a minimal `replacement` whenever the problem is
fixable; a fix is offered (Apply) only if it is anchored at the cited
snippet, shares most of its words, is at most about three times its size,
and, in a checkable category, makes that check pass. Fixable hints rank
first. Derek's valid 7-line page, where Apple Intelligence claimed
"`<html>` is not closed", now yields no hint from either engine.
`HintSource.displayName` turns a hint's `source` into "AI suggestion ·
Apple Intelligence" / "AI suggestion · Qwen2.5 Coder 3B" (nil for rules).

**Status line.** `LocalAIOwlBridge.statusLine()` ("Last checked 12 s ago ·
Apple Intelligence · no suggestions", "… · waiting for a pause in
typing", nil while off) shows in the owl's tooltip (computed when the
tooltip appears) and at the top of its popover, so a throttled engine
reads as "checked, nothing to say" rather than "dead".

**Settings sheet with Apple Intelligence.** No model menu and no Test
Connection; instead "Apple Intelligence: ready" or the reason it isn't
(`AppleIntelligenceStatus`). The checkbox reads "Ask Apple Intelligence
for hints". Wrapping labels are capped at 380 pt so the privacy line wraps
instead of running into the sheet's edge.

**Prompts.** All prompts live in `CedricAI/OwlPrompts.swift`: one
`persona` (Cedric, the quiet owl with a monocle in the editor's corner)
plus a task prompt per `OwlPrompts.Task` (today `.codeHints`). Every engine
sends `OwlPrompts.system(for:)` = persona + task; `HintPrompt` only adds
the JSON schema and the defensive parser.

**Model choice (auto).** `ModelPicker.pickSmallQwen`: a Qwen
coder/instruct of 2.5–4B (coder first, closest to 3B), else 1–2B (closest
to 1.5B), else 0.5–1B; never above 4B (`maxAutoParametersB`). A 1.5B model
gives noticeably weaker hints; the sheet says "Small models give weaker
hints." when the chosen or suggested model is ≤ 2B (`ModelPicker.isWeak`).

**Wiring into the owl** (`LocalAIOwlBridge`, CedricAI, main actor). On
`apply(settings)` it tears down the old provider and, when enabled with an
available engine, a local/LAN address and a model (set or auto-picked),
builds an `OwlScheduler` and registers a `ScheduledAIEntry` named
`local:<model>` with `isAI: true`. That entry answers the coordinator's
own 30 s queries with nothing: only the scheduler (5 s pause, interval,
20 s cap, one request per edit generation, inactive/power gates) ever asks
the model. The bridge reports `onThinking(doc, on)` (a request started;
ended, timed out or was cancelled) and `onHints(context, hints)`.

In the app, `OwlHub` owns the bridge:

- edits and scrolls of a tab with the owl feed `contextChanged` with that
  tab's `OwlContextWindow` context, batched on a 0.3 s trailing timer, so
  a keystroke or scroll never builds the context itself; nothing is fed
  while the AI is off;
- `didBecomeActive`/`didResignActive` → `setAppActive`; a closed tab →
  `documentClosed`; the source set to Rules, or the owl hidden →
  `setPaused(true)` (cancels in-flight work, stops asking);
- `onThinking` → the tab's owl takes the thinking pose (unless a bubble is
  up) and goes back to idle when the request ends or times out;
- `onHints` → `OwlCoordinator.acceptAI` (only with Rules + AI and an AI
  provider registered; the same range-in-document, edit-generation,
  dedupe/snooze/never and quiet checks as a rules query) → the same bubble,
  with `OwlCoordinator.documentRange` (`range + textStart`) for Apply.

**Settings sheet.** View › Cedric AI Settings… (`AISettingsSheet`): "Ask a
local model for hints" (off by default), "Where the AI runs" (the engines
above; unavailable ones disabled), the address (Custom only; typed text
gets `http://` and `/v1` as needed and must pass `LocalEndpointPolicy`),
the privacy line "Sends only the visible text (up to 8 KB) to the address
above. Never the cloud.", Test Connection (models with size and
quantisation, latency, the suggested model), a model picker (Automatic or
a listed model), the weak-model note, and "Check at most every" (30 s–5
min, default 90 s). Save stores `LocalAISettings` (UserDefaults
`CedricLocalAISettings`), applies them and, once a provider registers,
selects View › Owl Hint Source › Rules + AI.

**Tests.** `Tests/CedricAITests` uses a URLProtocol stub server, a fake
clock and a fake power source. `CEDRIC_AI_LIVE=1 Scripts/test.sh --filter
LiveCheckTests` runs three sample snippets and a scheduler burst against a
real local server (`CEDRIC_AI_URL`, `CEDRIC_AI_MODEL` override); CI never
sets it. `WiringTests` cover the settings (defaults, presets, URL parsing,
save/load) and the bridge (off registers nothing; on registers an entry
that never reaches the model; public URLs and missing models refused;
thinking → hints → idle with the textStart-moved range; timeout → idle;
paused/inactive never asks; turning off mid-request clears thinking; real
factory auto-picks from a stub server).

`Scripts/ai-check.sh` runs `AICheck` in process with real NSEvents (fake
provider, no server; CI-safe): opens the sheet through the menu action,
ticks the box, Save → provider registered and Rules + AI selected; on line
200 of a 260-line Swift file (past the 8 KB cap, so `textStart` > 0) types
`for i in 0...items.count`, checks the thinking pose, the bubble with the
`local:<model>` hint whose document range is exactly the typed text,
Apply, then a request that outlives the timeout returns the owl to idle.
`Scripts/ai-check.sh --live MODEL` does the same against LM Studio (Test
Connection, pick MODEL, save, type, wait for the model's bubble).

## Built-in AI (CedricAI/BuiltIn)

Cedric's own engine: a Qwen model downloaded inside the app and run
in-process. No LM Studio, no server, no account.

**Engine choice: llama.cpp.** Evaluated with real builds in a scratch
package (2026-11-17, M4 Pro, Command Line Tools only, Swift 6.4.2):

- *mlx-swift* (0.33.0 via mlx-swift-lm 3.33.0) does not build: SwiftPM
  compiles MLX's `.metal` kernels with `metal`, which the Command Line
  Tools don't have (`unable to spawn process 'metal'`), and there is no
  fallback. Apple silicon only as well.
- *llama.cpp* (MIT) ships a prebuilt XCFramework per release. Its macOS
  slice is universal (arm64 + x86_64), links only system frameworks, has a
  minimum OS of 13.3, and embeds ggml's Metal shaders as source that
  compile at run time, so no `metal` compiler is needed. It builds with
  `swift build` for arm64, x86_64 and `--arch arm64 --arch x86_64`.
  Pinned in `Package.swift` as a `binaryTarget` (release `b12360`, the
  zip's SHA-256 checked by SwiftPM). Cost: `llama.framework` adds 25 MB to
  the universal app (26 MB binary); no extra compile time (prebuilt).
- Measured with Qwen2.5-Coder-3B Q4_K_M on Metal: ~95 tok/s unconstrained,
  ~39 tok/s with the hint grammar, ~400 tok/s prompt processing; 1.4–1.8 s
  per owl hint end to end. CPU only (the Intel path, measured on Apple
  silicon as a stand-in; Rosetta isn't installed here, so not on x86_64
  itself): ~5 tok/s, about 35–50 s per hint.

`LlamaRuntime` (`BuiltInRuntime`) loads a GGUF with every layer on Metal
(Apple silicon) or on the CPU with one thread per physical core (Intel),
a 4096-token context and the model's own chat template (ChatML fallback),
and decodes greedily. Every llama.cpp call runs on one serial queue;
cancellation (a new edit, the scheduler's 20 s cap) is checked per token.
Loaded models are freed from an `atexit` handler: ggml's Metal device is a
C++ static whose destructor aborts if a context still holds Metal buffers
at exit, which would leave a crash report on every quit.
Output is constrained by a GBNF grammar (`HintGrammar`) to the hint JSON
(the four kinds, numeric confidence, ≤ 2 hints), then parsed by the same
`HintPrompt.parse`. On Intel the engine's `note` says it is slow and
suggests another Mac on the network.

`BuiltInModelHost` keeps at most one model in memory: it loads on the
first request, swaps when a different model is chosen, and unloads after
5 minutes without a request (`idleTimeout`) to give the RAM back, never
during a generation. The scheduler's gates (5 s pause, ≤ 1 per 90 s, app
inactive, Low Power Mode, battery) apply unchanged: the built-in engine is
just another `OwlHintProvider` (`BuiltInHintProvider`, source
`local:<model id>`), prompted with the shared `OwlPrompts`.

**Catalog.** `Resources/AI/models.json` (copied into
`Contents/Resources/AI/` by `Scripts/bundle-app.sh`), decoded and
validated by `ModelCatalog`: each entry has a name, parameters,
quantisation, file name, exact size, a Hugging Face URL pinned to a commit,
that commit, the file's SHA-256, its licence and licence URL, and the
memory it needs. Validation refuses anything not `https://huggingface.co`,
not pinned to its revision, without a 64-hex SHA-256, or with a path in
the file name. All five URLs and hashes were checked by downloading the
files and hashing them.

The default moved from Qwen2.5-Coder-3B (Qwen Research License,
non-commercial) to Qwen3-4B-Instruct-2507 (Apache-2.0) on 2026-11-18,
after a side-by-side run of owl hints, explanations and grammar prompts.
The 2507 instruct model has no thinking mode; its GGUF carries a ChatML
template whose generation prompt is a plain `<|im_start|>assistant`, so
llama.cpp's built-in template applies and no `<think>` block is produced
(the hint parser still strips one if it appears). Someone who had
downloaded the old default keeps it: on Automatic, `suggestedModel` picks
the default only once it is downloaded, else the first downloaded model.

| Model | File | Size | Licence |
|---|---|---|---|
| Qwen3 4B Instruct 2507 (default) | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` (unsloth/Qwen3-4B-Instruct-2507-GGUF; Qwen publishes no GGUF of it) | 2.50 GB | Apache-2.0 |
| Qwen2.5 Coder 3B (optional, the default until 2026-11-18) | `qwen2.5-coder-3b-instruct-q4_k_m.gguf` | 2.10 GB | Qwen Research License (non-commercial) |
| Qwen2.5 Coder 1.5B (fast) | `qwen2.5-coder-1.5b-instruct-q4_k_m.gguf` | 1.12 GB | Apache-2.0 |
| Qwen2.5 Coder 7B (≥ 16 GB RAM) | `qwen2.5-coder-7b-instruct-q4_k_m.gguf` | 4.68 GB | Apache-2.0 |
| Qwen3 4B (general) | `Qwen3-4B-Q4_K_M.gguf` | 2.50 GB | Apache-2.0 |

**Downloads.** `ModelDownloader` (an actor) fetches one model with a plain
HTTPS GET into `~/Library/Application Support/Cedric/Models/.partial/<file>.part`
(`CEDRIC_MODELS_DIR` overrides the folder), hashing as bytes arrive. Pause
or a dropped connection keeps the partial; resuming (even after a
relaunch) re-hashes it and continues with an HTTP `Range` request (a
server that ignores `Range` restarts cleanly). Before any request it
checks free space (size still to fetch + 256 MB). A wrong size or SHA-256
deletes the file and reports the error; a verified file is moved to
`Models/<file>` next to a `<file>.verified` marker holding its hash
(installed = right size + marker matches the catalog) and excluded from
Time Machine. Delete removes the file, marker and partial.

**Privacy.** The only network traffic is the model download itself, from
huggingface.co (and the CDN it redirects to): an ephemeral URLSession, no
cookies, no cache, no identifiers, User-Agent `Cedric`. Nothing is sent
about the user or their code, and there is no telemetry. Inference is
fully local; the owl's text never leaves the process.

**Settings sheet.** With Built-in selected, a "Download:" row lists the
catalog: name (the default marked recommended), size, licence, a memory
warning where it applies, and per-model Download / Pause / Resume / Cancel
/ Delete with a progress bar and status. The Model menu offers the
downloaded models; Automatic picks the default if downloaded. Test
Connection loads the model and times a first answer.

**Tests.** `BuiltInTests.swift`: the bundled catalog (valid, pinned, one
default) and its validation; the downloader against a URLProtocol fake
that honours `Range` (progress, install, SHA mismatch → deleted + error,
pause → partial kept → resume with the right `Range`, a server ignoring
`Range`, a dropped connection, cancel, disk-full precheck with no request,
non-Hugging Face URL refused, oversized response, HTTP errors); the host
and engine with a fake runtime (load on demand, reuse, swap, idle unload
on a fake clock, never during a generation, OwlPrompts + grammar + parser,
Qwen3 `/no_think`, the scheduler's timeout cancelling a generation).
`CEDRIC_BUILTIN_LIVE=1 swift test --filter LiveBuiltInTests` downloads the
default model for real (optionally pausing and resuming with
`CEDRIC_BUILTIN_PAUSE=1`) and runs the three owl snippets;
`CEDRIC_APPLE_LIVE=1 swift test --filter LiveAppleTests` does the same on
Apple Intelligence. `CEDRIC_BUILTIN_CHECK=/out CEDRIC_MODELS_DIR=/tmp/x`
runs `BuiltInCheck` in the app: real clicks on Download, Pause, Resume and
Delete in the sheet, with snapshots.

## Dev hooks

`DevHooks.swift` documents the `CEDRIC_*` launch variables used for
screenshots (`CEDRIC_SNAPSHOT`, rendered with `cacheDisplay`, so it works
with the screen locked), perf (`CEDRIC_PERF_OPEN`, `CEDRIC_LAUNCH_METRICS`),
the session check, and the owl (`CEDRIC_OWL*`). None of them is saved.

## Drawing on a real window, and checking it

Since macOS 14, `NSView.clipsToBounds` is false by default and AppKit may
pass `draw(_:)` a `dirtyRect` much larger than the view: the status bar
(24 pt tall) was handed the whole window and filled all of it with the
status-bar colour, over the split view. On a real screen that hid the
gutter, the text and the owl (test build 2: a flat purple window in
Tankard, only the status and tab bars drawn). So every custom view fills
`dirtyRect.intersection(bounds)`, never `dirtyRect`, and the opaque bars and
panels (`StatusBar`, `FindBar`, `GutterView`, `FindInFilesPanel`,
`DiffView`) set `clipsToBounds = true`.

None of our checks saw it: they rendered the text view, gutter and owl
each on its own (`cacheDisplay` on the view) and pasted them on top of the
window image, so the paint-over never showed. Now:

- `CEDRIC_SNAPSHOT` renders the window whole (one `cacheDisplay` on the
  frame view; only web views are pasted in, from `takeSnapshot`).
- `Scripts/render-check.sh` (`CEDRIC_RENDER_CHECK`, `RenderDump.check`):
  every theme at 900×670, the owl turned on through the same settings
  notification the menu posts, text typed with key events; the whole window
  is rendered from its CALayer tree (`layer.render(in:)`) and with
  `cacheDisplay`, and the typed text, line numbers, owl and an empty patch
  of editor background are checked in both. It fails on the status-bar bug.
  Also checks untitled numbering.
- `CEDRIC_LAYER_DUMP=/dir` (`RenderDump.run`): the view tree with frames,
  hidden/alpha, layer state, z-order and overlap with the text, plus the
  window rendered three ways (`cacheDisplay`, CALayer tree,
  `CGWindowListCreateImage`; the last needs an unlocked screen).

What this can't show: the window server's own compositing. With the screen
locked `CGWindowListCreateImage` returns a blank image, so the layer-tree
render is the closest stand-in; a real-screen look is still the last word.

The owl: `OwlHub` is created at launch (it observes the owl setting; created
lazily, the View menu's toggle did nothing on a fresh untitled-only launch),
and a just-turned-on owl shows at full strength (`OwlController.appeared`),
whatever the occlusion state or the caret, until the user types or moves
the caret. Occlusion only ever gated the idle animation timers, not
visibility.

## Signing a release

Same pipeline as Tankard's, sharing `Scripts/release.sh` between the owner's Mac and CI.

**Version.** One source: `CedricVersion.source` in `Sources/CedricCore/Version.swift`.
`Scripts/bundle-app.sh` writes it (or `CEDRIC_VERSION`) into Info.plist as both
`CFBundleShortVersionString` and `CFBundleVersion`. `release.sh` refuses to sign a build
whose Info.plist differs from the source, from `CEDRIC_VERSION`, or from the tag (`TAG`
in CI, without the `v` and any `-rcN` suffix). `CHANGELOG.md` must have a `## [X.Y.Z]`
section for it (a test checks the source's version; the workflow checks the tag's).

**On your Mac** (Developer ID certificate in the login keychain). Once:

```sh
xcrun notarytool store-credentials cedric
# Apple ID, Team ID, and an app-specific password made at appleid.apple.com
```

Then:

```sh
Scripts/release.sh --dry-run          # print every step
Scripts/release.sh                    # "dist/OwlInk.app" (signed, notarized, stapled) and dist/OwlInk-<version>.zip
CEDRIC_SIGN_ID=- Scripts/release.sh --skip-notarize   # ad-hoc test of the whole signing path
```

It builds universal (`--host-arch` for this Mac only), finds the "Developer ID
Application:" identity (override: `CEDRIC_SIGN_ID`), and signs inside out with
`codesign --force --options runtime --timestamp`, never `--deep`: first
`Contents/Frameworks/llama.framework` (and any other nested framework, dylib or XPC
service a later version adds), then the app. It then checks `codesign --verify --strict
--deep`, that the app and the framework carry the same Team ID and the hardened runtime,
and that neither has entitlements; real-launches the signed app five times
(`Scripts/launch-check.sh`); submits a zip with `notarytool --wait` (profile
`CEDRIC_NOTARY_PROFILE`, default `cedric`); fetches Apple's log after every submission,
accepted or not (`dist/notary-log.json`, next to `dist/notary-result.json`); fails unless
Accepted; staples; checks with `spctl -a -vv`; and zips the stapled app.

**Entitlements: none.** Checked 2026-11-17 on the M4 Pro:

- *Library validation* (part of the hardened runtime) only loads code signed by Apple or
  by the app's own Team ID. `llama.framework` is re-signed with our Developer ID, so it
  passes. An ad-hoc signature has no Team ID, and an ad-hoc hardened-runtime build
  doesn't start at all (`dyld: Library not loaded: @rpath/llama.framework/... mapping
  process and mapped file (non-platform) have different Team IDs`). So the ad-hoc test
  mode (`CEDRIC_SIGN_ID=-`) alone adds `com.apple.security.cs.disable-library-validation`
  to the app, and `release.sh` asserts a Developer ID build has no entitlements.
- *Metal shaders compiled at run time* need neither `allow-jit` nor
  `allow-unsigned-executable-memory`: ggml's embedded Metal source is compiled by Metal's
  compiler service (a separate process) into GPU code; the app maps no writable and
  executable memory. Checked with a hardened-runtime build carrying only
  disable-library-validation: in the app, Settings › Test Connection with the built-in
  engine loaded Qwen2.5-Coder-3B and answered in 4.1 s; a small C program linking the same
  framework, signed the same way, logged `ggml_metal_library_init: using embedded metal
  library`, compiled its pipelines, `offloaded 37/37 layers to GPU`, and decoded a prompt.
- *The WKWebView preview* needs nothing outside the App Sandbox: WebKit's content and
  network processes are Apple's own XPC services with their own entitlements.
  (`com.apple.security.network.client` exists only for sandboxed apps.)
- *Models* are downloaded at run time into `~/Library/Application Support/Cedric/Models`,
  never bundled; a GGUF is data that llama.cpp maps read-only, not code, so neither
  signing nor notarization sees it.

**On GitHub.** `.github/workflows/release.yml` runs on a `v*` tag push (or by hand with a
tag) on `macos-15`: checks the five secrets, builds the release notes from
`CHANGELOG.md` (`Scripts/changelog-section.sh`, after Tankard's), restores the SwiftPM
artifact cache, resolves packages, imports the certificate, runs `Scripts/test.sh`, then
`Scripts/release.sh` with `CEDRIC_VERSION` from the tag, and attaches `OwlInk-<version>.zip` to the
release. A tag with a suffix (`v0.1.0-rc1`) makes a draft prerelease. `notary-result.json`
and `notary-log.json` are kept as the workflow artifact `notary-<tag>` (90 days) with
`if: always()`, so a failed notarization leaves Apple's issues list behind. Actions are
pinned by commit SHA. `.github/workflows/tests.yml` runs `Scripts/test.sh` on pushes to
`main` and `release-*` and on pull requests, and logs `swift --version`.

The llama.cpp binary target (a 65 MB zip from the llama.cpp GitHub releases) has hung
while fetching on the build Mac. Both workflows cache SwiftPM's global artifact cache
(`~/Library/Caches/org.swift.swiftpm/artifacts`, keyed on `Package.swift`, where the URL
and checksum are pinned); SwiftPM extracts a cached zip without the network. Then
`swift package resolve` gets five minutes per try (killed by a `perl alarm`, since macOS
has no `timeout`), three tries, before the build starts.

Secrets (Settings › Secrets and variables › Actions), the same five as Tankard's:

| secret | value |
|---|---|
| `CERT_P12_BASE64` | `base64 -i DeveloperID.p12` of the exported Developer ID Application certificate and key |
| `CERT_P12_PASSWORD` | the .p12 password |
| `NOTARY_APPLE_ID` | Apple ID |
| `NOTARY_TEAM_ID` | Team ID |
| `NOTARY_PASSWORD` | app-specific password |

No secrets live in the repository.

**Apple Intelligence and the CI SDK.** The Apple Intelligence engine is compiled only
when the SDK has `FoundationModels` (macOS 26 SDK, Xcode 26). `macos-15` with Swift 6.1
builds the placeholder, so a release built there offers Apple Intelligence as
unavailable. A release that should include it must be built with the macOS 26 SDK (a
`macos-26` runner, or on the owner's Mac).

## Owl placement, language auto-detect, spelling, Cedric themes

**Dragging the owl.** `OwlView` tells a click from a drag by
`OwlPlacement.dragThreshold` (3 pt): a press that moves less opens the
popover; more picks him up (closed-hand cursor, open hand on hover). On
release `OwlPlacement.snapped` puts him on the nearest edge of the editor,
keeping his position along it, and into the corner when he is within
`cornerPull` (56 pt) of one; he slides there in 0.16 s. Snapping rather
than "stay where dropped": in the middle he would sit over text and the
fade-near-caret would fire constantly; on an edge he is out of the text but
still where you put him. The placement is stored (UserDefaults
`owlPlacement`, shared by all tabs) as a corner plus an inset from that
corner's two edges, so a resize keeps him the same distance from the same
corner, clamped inside when the window gets small. Double-click, or "Reset
Position" in his popover, puts him back bottom right. The bubble opens
above him when there is room (else below) and towards the wider side, its
tail pointing at him (`OwlPlacement.bubble`). The fade-near-caret still
runs after every drop, so he never sits on the caret at full strength.
The disc that used to sit behind him on dark themes is gone; the sprite
gets a soft light rim (a 2.5 pt white shadow) on dark editors and a faint
drop shadow on light ones. Checks that move him don't save
(`CEDRIC_NO_SESSION_SAVE`).

**Language auto-detect** (`LanguageChoice`, CedricCore): a tab's language
has a source. `.auto` (untitled, nobody chose): typing re-sniffs when it
pauses (0.4 s), a paste at once; the status bar shows "HTML (auto)".
`.manual` (picked from the status bar or Format › Language): never switched
again, not by typing, pasting or saving. `.file`: the extension decides on
save (or the content once, without a known extension), and sniffing stops.
Markdown sniffing (`MarkdownSignals`) needs two kinds of evidence (ATX
headings, bold, lists, links, quotes; a fence counts alone), each kind
capped, so a shell script's `# comments` or a YAML `- item` list doesn't
turn into Markdown, while "# Title / ## Sub Title / **Test**" does.

**Spelling.** NSTextView's own continuous checking (NSSpellChecker: local,
nothing sent anywhere), on by default (Edit › Spelling and Grammar › Check Spelling While Typing,
saved; beside Show Spelling and Grammar and Check Document Now). Every batch of results passes through
`EditorTextView.handleTextCheckingResults`, which keeps only misspellings
inside `SpellScope.ranges`: prose in Plain Text and Markdown (minus code,
links and markup tokens), only comments and strings in code, nothing in
data (`SpellScope.checks`: JSON, YAML, TOML/INI/.env, XML, and CSV/TSV
files; checking is off for those tabs, so no underlines and no typo
hint). The marks are
the text view's spelling state, a drawing attribute, so text colours are
never touched; suggestions, Learn and Ignore are the standard context menu.
Check Document Now walks our scope (the system's would stop on
identifiers). With the owl on, prose with three or more fixable
misspellings in his context window gets "Fix 3 typos?": the first
suggestion for each, as one replacement over their span, so one undo step.
`SpellScope.isFixable` skips ALL-CAPS words, words with digits, URLs, paths
and addresses. Offered once per document unless snoozed. The bubble's
default is now **Fix Typos…** (the step-through below); **Fix All** is the
one-step fix.

**Fix Typos… (step-through).** `SpellStepper` (CedricCore, pure, tested)
holds one pass: an anchor at the start of the caret's word, the document
cut into line-aligned chunks of ~16 K characters from there to the end and
then from the top back to it, the words found so far in pass order, the
current word, Ignore All and Change All sets. Every edit (the panel's
Change / Change All, and the user's typing or ⌘Z, via
`EditorWindowController.storageEdited`) moves the words and chunks after
it and drops what it touched. `SpellStepController` (the app) checks a
chunk with `EditorSpelling.misspellings` (same scope as continuous
checking, URLs and paths skipped), at most four per run-loop turn while
looking for the next word; a normal document finishes the count in idle
turns, large mode never goes further than the next word. Change All
changes the words found so far as one undo group, and later ones as their
chunk is checked. Learn Word is `NSSpellChecker.learnWord` (the user's
dictionary; tools-check learns a nonsense word and forgets it again).

**Themes.** Cedric (peach paper from the logo's coral plate, navy text,
gold/coral/navy tokens, the chest chevron's grey-blue for comments) and
Cedric Night (the owl's navy as the page, sepia text). Both pass the AA
tests with the other palettes.

**Checks** (in `Scripts/render-check.sh`, `PolishCheck.swift`): the owl
dragged to the top left with real mouse-down/drag/up events (snapped there,
faded over the caret with the text still readable, full strength once the
caret moves away), a 2 pt press opens the popover, the bubble opens below
and right with "Fix it" and its source line, a resize keeps him top left, a
double-click resets him; "<html>" typed shows "HTML (auto)", Plain Text
picked from the menu stays put through more typed and pasted HTML, Derek's
Markdown is detected, a pasted JSON switches at once; Swift, Markdown with
preview and HTML in both Cedric themes; spelling marks in a Swift file
(comment and string, not the identifier) and in Markdown (prose, not code
or the link), colours unchanged, in light and dark; the owl's "Fix 3
typos?" applied and undone with one undo.

## Grammar in prose

`Grammar.swift` (app) and `Prose.swift` / `Grammar.swift` (CedricCore,
pure, tested in `ProseTests` and `GrammarTests`).

**Which documents.** `ProseDetector.isProse`: Plain Text or Markdown, not a
data or log file by name (`.log`, `.csv`, `.conf`, …), and a sample (at
most 8 KB, the owl's context window) that reads as sentences after
`ProseMask` blanks what isn't prose (Markdown front matter, fenced and
indented code, tables, inline code, link targets, tags, markup characters,
URLs and email addresses; replaced by spaces, newlines kept, so offsets
stay the document's). The signals: at least 8 words; ≥ 75% of tokens
word-shaped (letters only, not camelCase or snake_case, no digits); ≥ 12%
of the words are common function words (a built-in list for English,
French, German, Spanish, Italian, Portuguese and Dutch; Foundation has no
dictionary, and the real checker would be too slow for a per-pause
decision); sentence punctuation with 3–60 words per sentence on average;
symbols (`{}[]<>=;|\/_*&^%$#@~` and backticks) ≤ 4% of visible
characters; ≤ 25% of lines `looksLikeCode` (statement ends, comments,
keywords with code punctuation, calls, timestamps or log levels first,
`key = value`, `key: value` with a code-like key or data value, 3+
separated short fields). Short bullet lists don't count; bullets of whole
sentences do. The corpus in `ProseTests` has 22 prose samples (emails,
letters, notes, stories, Markdown with code and front matter, French,
German, Spanish) and 23 that must not be (logs, syslog, Maven output,
INI, YAML, shell, .env, Swift/Python/C/JS/SQL/HTML/JSON pasted into a
.txt, a diff, a traceback, plain and bulleted shopping lists, CSV, TSV,
a .log and a .csv by name, a one-line "Hello there.").

**Checking.** `EditorGrammar` (one per tab, lazy) runs after typing pauses
for 3 s, the owl's own pause (`textDidChange` → `schedule`, a one-shot
timer; also after open, once the first frame is up, and on settings,
language or large-mode changes). Scrolling never starts a pass. Never in a
document over 1 M characters (`maxLength`: a pass starts on the main
thread by copying the owl's window, which a multi-megabyte log must not
pay for; perf-check's 6 MB log scrolled with a 72 ms worst step before
this). After a "not prose" verdict the next pass waits until the length
has changed by 200 characters or 20 s have passed. A pass copies the owl's context window (visible lines ±40, at
most 8 KB), masks and measures it on a utility queue, and if it is prose
hands the masked text to `NSSpellChecker.requestChecking` (asynchronous;
types spelling + grammar, because on macOS 26 grammar alone returns
nothing; spelling results are dropped). Language: the checker's own
(per-text identification when the user has "Automatic by Language", else
an orthography for their chosen language). Results map through
`GrammarMap.issues` (NSGrammarRange is relative to the result's sentence
range); issues whose text no longer matches, or touching blanked text,
are dropped; a result for an edit generation that has moved is thrown
away. Issues follow edits (`GrammarMap.shift`: ones an edit touches go).
Never in large mode (`extrasPaused`), never for other languages, PDF tabs
or read-only text. The underlines' `didSet` redraws only the visible rect,
and only when the ranges changed: an unconditional `needsDisplay` on
opening a large file doubled perf-check's open time for the long line.

**Language sniffing.** A .txt (or untitled) file of meeting notes with
"Date:", "Status:" lines scored as YAML, which turned off spelling and
the owl's prose help (build 7 test pass, F-M3). `LanguageDetector.sniff`
now returns Plain Text when YAML wins but the text reads as prose.

**Showing.** `EditorTextView.grammarRanges`: a green dotted line under the
words (`EditorPalette.grammarMark`, lighter on dark themes; drawn in
`drawBackground` like the occurrence marks, viewport segments only,
clipped to the bounds). `menu(for:)` puts the checker's description,
"Change to “…”" for up to five corrections and "Ignore Grammar" (this
tab) at the top of the usual menu. With the owl on, `offerHint` picks the
first issue in view after the caret (not a doubled word: the rules
already offer those) and presents `GrammarMap.hint` ("Grammar: ‘a’ →
‘an’?", the description as detail, the correction as the replacement, so
Fix it is `applyPresented`, one undo step). `GrammarPopupPolicy` (one per
app): no bubble within the owl's typing pause (3 s) of the last keystroke
(a pass that finishes earlier asks again when the pause is over), and at most one per
10 minutes, unless the user clicked the owl and chose "Grammar Hint" in
his popover. Hint ids are `grammar.<words>→<fix>` (the coordinator's
once-per-document and snooze apply; the close box snoozes); "Don't show
again" saves `grammar` in the never list (all grammar hints); "Not in
This File" is per tab (not kept with the session). The bubble now wraps
its buttons onto a second row when they don't fit.

**Fix Grammar…** (`GrammarStepController`, `GrammarStepper` in Core):
checks the document (at most 200 K characters around the caret) once in
the background, then steps through from the caret and round from the
top in a `SpellStepPanel`: the words, the checker's note, its
suggestions (first picked), Change (one undo step), Skip, Done, "N of M";
Return / Tab or ⌘→ / Esc. Edits made meanwhile move what is to come.

**Check:** `CEDRIC_CHECK=grammar` (tools-check). The system checker in
this environment flags "a elephant" and doubled words but nothing in
"Their going too the store tomorrow and we was late.", so after the
real-checker part (typed email, underline, bubble, Fix it, ⌘Z/⇧⌘Z) the
check swaps in `FakeGrammarChecker` (also `CEDRIC_GRAMMAR_FAKE=1`) for the
right-click menu, rate limit, Grammar Hint, Not in This File and Fix
Grammar…, and for the negatives: the same sentences in a Swift comment,
a JSON string, a `.log` file and a .txt of log lines get no underline and
no hint; large mode and the setting off check nothing.

## PDF tabs

A PDF opens in a `PDFTabController` (PDFTab.swift), not an
`EditorWindowController`: its own window in the same tab group
(`tabbingIdentifier` "CedricEditor"), with a PDFKit `PDFView`
(`singlePageContinuous`), a `PDFThumbnailView` sidebar, Cedric's
`FindBar` (Regex and Whole Word hidden: PDFKit searches plain text) and
`StatusBar` (only the page and the zoom). `AppDelegate.pdfTabs` holds them
beside `tabs`; `currentTab` is nil while a PDF tab is in front, so every
editor command that checks it is off without more code, and the PDF
controller answers (as nothing, disabled) the few that don't check
(Format menus, Show Preview, Find and Replace, Save, Find in Files).

- **Reader controls** (`PDFOverlay.swift`): a capsule floating at the
  bottom centre of the pages (a subview of `PDFPagesView`, laid out over
  the `PDFView`, clear of the thumbnails sidebar), built with
  `AfterFirstFrame` so nothing of it is on the launch path. Previous/next,
  an editable page field (`PageNumberInput`), zoom, actual size, fit width
  (`autoScales`), fit page (`PDFReader.fitPageScale`, rotation-aware),
  thumbnails, find, rotate left/right and Open in Default App. Rotation sets
  `PDFPage.rotation` on the in-memory document only; the tab has no save
  path, so the file is never written (pdfoverlay compares its bytes).
  ←/→ and Page Up/Down page (`CedricPDFView.onPageKey`); ←/→ still scroll
  sideways when the page is wider than the view. Narrow windows drop the
  lowest-priority groups (`PDFReader.visibleGroups`); page stepping always
  stays. Auto-hide (`PDFReader.AutoHide`, 2 s): mouse moves (a tracking
  area on `PDFPagesView`), scrolling (the clip view's bounds) and page
  changes show it; hovering or editing the page field keep it; hidden it
  returns nil from `hitTest`, so the page gets every click. Reduce Motion:
  no fade, it just appears and disappears. Drawn with a plain layer in the
  status bar's colour (rounded, `masksToBounds`), not a vibrancy material.

- **Which files:** `DocumentKind.detect(url:)` (CedricCore, tested) reads
  the first 8 bytes: `%PDF-` at the start, or a `.pdf` name (so a damaged
  `.pdf` gets the viewer's "damaged" alert rather than binary text in the
  editor). `AppDelegate.open` routes every path through it: File › Open,
  drops on text or on a PDF, the Dock, `cedric://open` (with `line` as the
  page, and `-w` waiting on the PDF tab's id), Open Recent.
- **Never written:** there is no save path; `saveDocument:` and friends
  are validated off on the PDF controller. Open as Text extracts with a
  second `PDFDocument` on a background queue (PDFKit objects stay on one
  thread) and opens the text as a new unsaved untitled tab.
- **Find:** the count comes from `beginFindString` (PDFKit's own thread,
  `PDFDocumentDidFindMatch` notifications); next / previous use
  `findString(_:fromSelection:)`, wrapping. Matches are highlighted.
- **Zoom:** ⌘+ / ⌘− step by 25% (the view's own `zoomIn:` is routed to
  the controller, so the steps are Cedric's, clamped to 10%–1600%); ⌘0 is
  100%; ⌘9 fits the width (`autoScales`, how a PDF opens).
- **Session:** `SessionTab.pdf` (`PDFTabState`: page, scale or nil for
  fit, sidebar) marks a PDF tab; older sessions decode without it, and a
  `.pdf` tab with no buffer from before PDF tabs restores as one. Only a
  window's selected tab is built at launch, as for text; a PDF tab loads
  its document only when first shown (`loadIfShown`, checked on the next
  run-loop turn, since inserting a tab into a group makes it key for a
  moment), so a session full of PDFs costs nothing until they are clicked.
  PDFKit itself is linked (2 more images from the shared cache), but no
  PDFKit object is created at launch unless the selected tab is a PDF.
- **Locked and damaged:** an encrypted PDF shows a message and a password
  sheet (wrong passwords ask again, Cancel leaves an Enter Password…
  button); `PDFDocument(url:)` returning nil is an alert on open (no tab)
  or a message in a restored tab.
- `Scripts/pdf-check.sh` drives all of it in the running app with PDFs it
  draws with Core Graphics, then relaunches to check the session;
  `render-check.sh` renders a PDF tab in every theme (white page, themed
  chrome).

## Image tabs and Office (Quick Look) tabs

Built the way PDF tabs are (above): each is its own `NSWindowController`
in the editor's tab group, kept in `AppDelegate.imageTabs` /
`officeTabs` beside `pdfTabs`. `ViewerTab` (ViewerTabs.swift) is what all
three share: `id`, `fileURL`, `sessionTab`, `reloadIfChangedOnDisk`.
`viewerTabs` / `currentViewerTab` replace the PDF-only lookups wherever
the app asks "which windows are ours", "is a viewer in front" (then
`currentTab` is nil and the editor's commands are off), the session,
`cedric -w` and Reopen Closed Tab.

- **Which files:** `DocumentKind.detect(url:)` (CedricCore, tested) reads
  32 bytes: `%PDF-`, then `ImageFormat.detect` (PNG, JPEG, GIF, TIFF,
  WebP, ICNS, PSD, JPEG 2000, the HEIF family by its `ftyp` brand, ICO/CUR
  and BMP with their header fields checked so text starting "BM" stays
  text), then `OfficeFormat.detect` (an OLE2 compound file; a zip named
  .docx/.xlsx/.pptx/.pages/.numbers/.key; an Office name with no header,
  so a damaged one reaches the viewer). A zip with no telling name is
  `.office` if its central directory lists `[Content_Types].xml` plus
  word/ xl/ or ppt/, or `Index/Document.iwa`. Package directories
  (.pages, .rtfd) go by name. `.key` needs the zip header (PEM keys are
  text); `{\rtf` in a `.doc` is text; SVG is always text.
- **Image tab** (ImageTab.swift): an `NSScrollView` with magnification
  (the zoom; pinch for free), a `CenteringClipView`, and an `ImageCanvas`
  the size of the image in points that draws only its dirty rect: an
  8-point checkerboard (light or dark to match the theme) and the image,
  `interpolationQuality` none from 2 screen pixels per image pixel. The
  file is read and decoded in `ImageFileInfo.load` on a global queue with
  `CGImageSourceCreateThumbnailAtIndex` (with its EXIF transform, cached
  immediately), at `ImageZoom.displayMaxPixelSize`: the whole image up to
  40 MP, else ~32 MP, never over 8192 px a side. Only the header is read
  on the main thread (`openImage`, to refuse a damaged file with an
  alert). Animations (GIF, APNG, WebP with more than one frame) play with
  `CGAnimateImageAtURLWithBlock`; a generation counter stops a superseded
  run. Copy puts the file's own bytes on the pasteboard under its UTI and
  promises TIFF and PNG through `ImagePasteProvider`, made only if pasted.
  Print uses an `NSImageView` sized to the page's imageable area.
  `ImageTabState` (scale or nil for fit, centre as fractions) is the
  session state. Deferred loading as for PDFs (`loadIfShown`).
- **Office tab** (OfficeTab.swift): Quick Look's `QLPreviewView`, found
  with `NSClassFromString` after `dlopen` of QuickLookUI on first use, so
  neither Quartz nor QuickLookUI is linked or loaded at launch; it works
  under a Command Line Tools-only SwiftPM build. Open as Text uses
  `NSAttributedString(url:options:)` (`.officeOpenXML`, `.docFormat` for
  OLE2, `.rtfd`) on a global queue. For an .xlsx it is Open Sheet as CSV:
  `ZipArchive` (CedricCore, central directory + `compression_decode_buffer`
  raw DEFLATE, entries over 512 MB refused) and `XLSXSheet` (XMLParser:
  workbook → first sheet's relationship → sheet XML; shared, inline and
  formula strings, booleans, errors, numbers as stored, formulas' cached
  values; gaps kept; rows padded to the widest). The CSV opens as an
  untitled tab detected as CSV.
- **Open in <app>** (File menu, all three viewer kinds): the file's
  default app other than Cedric (`NSWorkspace.urlForApplication`), named
  in the item's title.
- `Scripts/image-check.sh` drives both in the running app with files it
  makes (ImageIO, NSAttributedString, `/usr/bin/zip`), measures typing in
  a text tab while a 12000×12000 PNG decodes (a background thread asks the
  main queue for a key every 20 ms and records each wait, with App Nap
  held off), then relaunches to check the session.

## Certificates

`CedricCore/Certificates.swift` (tested in `CertificateTests` with
certificates made by `/usr/bin/openssl` during the test: RSA with SANs,
usages and EKUs, EC P-256 named and explicit-curve, a CA and a leaf it
signed, a request, PKCS#7 in DER and PEM) and
`CedricApp/CertificateTab.swift`.

- **Reading.** `PEM.blocks` finds `-----BEGIN X-----` … `-----END X-----`
  blocks (at most 500) with their UTF-16 ranges; a block whose label ends
  in `PRIVATE KEY` is never base64-decoded. Certificates go through
  `SecCertificateCreateWithData` and `SecCertificateCopyValues` (subject
  and issuer by attribute OID, validity, SANs, basic constraints, key
  usage bits, EKU OIDs, the signature and key algorithms), the serial from
  `SecCertificateCopySerialNumberData`, the key size from
  `SecCertificateCopyKey` (for an EC key with explicit curve parameters
  Security returns no key: the point's length gives the curve), SHA-256 /
  SHA-1 with CryptoKit. PKCS#7 bundles through `SecItemImport`
  (`kSecFormatPKCS7`, no keychain). A request's subject, and EKU OIDs,
  through a small DER reader (`DER`), since Security doesn't read
  PKCS#10. Security and CryptoKit are system frameworks already loaded in
  every AppKit process; nothing here runs before a certificate is shown.
  CedricCore is otherwise Foundation only.
- **PEM text** stays in the editor. `EditorWindowController.previewApplies`
  is `language.hasPreview || showsCertificatePanel`
  (`Certificates.isCertificateText`: a certificate file name, or `BEGIN `
  in the first 64 K, only for languages without a preview of their own),
  and the preview pane gets a `CertificatePanel` renderer (native
  `CertificateDetailsView`, an attributed read-only NSTextView: no
  WebKit). It parses on a utility queue on each debounced render (2 s in
  large mode, then only the first megabyte), a generation counter
  dropping stale results. `AppDelegate.open` shows it one run-loop turn
  after a certificate text file opens (never during session restore,
  never in large mode, never once the user closed it with ⌥⌘P:
  `CertificatePanel.closedByUser`, UserDefaults `certificatePanelClosed`,
  cleared when it is shown again). Copy links are `.link` attributes
  (`cedric-copy://N`) handled by the details view's text delegate: each
  field's value as shown, and per certificate its block exactly as it is
  in the editor's text (the panel keeps each block's range from
  `PEM.blocks`); the DER tab's blocks are `PEM.encode` (64 columns, LF). Certificate, key and request file names are data
  for spelling (no underlines in base64).
- **DER files**: `DocumentKind.certificate` when the name is .der .cer
  .crt .p7b .p7c and the file starts with an ASN.1 SEQUENCE (`0x30` and a
  valid length byte); a PEM `.crt` stays text. `CertificateTabController`
  is a `ViewerTab` like the Office tab (`certificateTabs`,
  `SessionTab.certificate`, Reopen Closed Tab, deferred loading for
  restored tabs); files over 4 MB are refused. Copy as PEM (the default
  button) puts every certificate's PEM on the clipboard; Open as PEM Text
  opens it in an untitled tab.
- **The owl** (`RulesHintProvider.certificateExpiry`, warning
  `rules.certificate-expiry`): the first whole certificate block in his
  8 KB window that has expired or expires within 30 days
  (`OwlDocumentFacts.now`, nil = now, lets tests pick the date).
- **Check:** `CEDRIC_CHECK=cert` in `Scripts/tools-check.sh`: ⌘A ⌘C, each
  Copy link (clicked through `NSTextView.clicked(onLink:at:)`) and Copy as
  PEM compared byte for byte with the files openssl wrote; the clipboard
  and the remembered setting are saved first and put back.
