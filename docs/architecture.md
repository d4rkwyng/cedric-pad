# Cedric architecture

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

## Session restore

`SessionStore` keeps `session.json` (windows, tab order, selection, scroll
line, encoding, line ending, a hand-picked language) and one UTF-8 buffer per
tab with unsaved text, in `~/Library/Application Support/Cedric/Session/`.
Writes are atomic; buffers are written before the session that refers to
them; orphan buffers are pruned after each save.

- Every edit schedules a save 1.5 s later (coalesced). Only tabs whose
  change count moved since their last buffer write are rewritten.
- Quit (`applicationShouldTerminate`) saves synchronously and returns
  `.terminateNow`: no prompts. Windows closed by termination keep their
  buffers; a tab the user closes drops its buffer.
- On launch the session is restored before anything else opens. A file tab
  with a buffer gets the buffer's text and stays unsaved; a clean file tab
  reopens the file from disk; a file that has gone and had no buffer is
  dropped.
- `Scripts/session-check.sh` checks it end to end (kill -9 and normal quit).

Known gaps: a large unsaved file is rewritten whole on each autosave; a file
changed on disk under unsaved edits isn't flagged yet (clean tabs reload).

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
`SyntaxColorizer` colours the viewport plus a margin as TextKit 2 rendering
attributes, remembers which lines are coloured, and uncolours from an edit
down. Lines longer than 20,000 characters are coloured up to that point.

A tree-sitter tokenizer could later implement the same protocol for one
language where lexical colouring isn't enough.

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

Scroll sync: Markdown blocks carry `data-line`; the app scrolls the preview to
the last block at or above the editor's top line (in the app's own content
world, so it works with page JavaScript off). HTML scrolls by fraction.

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
| Compare two tabs | View › Compare With… (next/previous difference) | ⌥⌘C (⌥⌘↓ / ⌥⌘↑) |
| Follow a log file | View › Follow File | ⌥⌘T |

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
  leave the text alone.
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
  tab is selected; a click opens the file with the match selected.
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
split UTF-8 character). In-process: `Scripts/tools-check.sh` launches the
app once per feature with `CEDRIC_CHECK=…` (`DevChecks.swift`), drives it
with key and mouse NSEvents and writes snapshots. When Cedric can't become
the active app (screen locked, launched from a script) there is no key
window and AppKit won't route a synthetic key equivalent or a click on a
table: the check then sends the matching menu item's action along the front
window's responder chain, and selects the clicked row and sends the table's
action, and says so in its output.

## Where the remaining non-goals plug in

- **Macros:** record the `NSTextView` insert/delete commands the window
  controller already routes.
- **The owl assistant / local AI:** a side panel in the preview slot; the
  session store already keeps every tab's text locally.

## Dev hooks

`DevHooks.swift` documents the `CEDRIC_*` launch variables used for
screenshots (`CEDRIC_SNAPSHOT`, rendered with `cacheDisplay`, so it works
with the screen locked), perf (`CEDRIC_PERF_OPEN`, `CEDRIC_LAUNCH_METRICS`)
and the session check. None of them is saved.
