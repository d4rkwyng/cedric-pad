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
edit. `Scripts/typing-check.sh` checks typing in every theme.) Lines longer than 20,000 characters are coloured up to that point.

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
  Cedric.app/Contents/Resources/Owl by `bundle-app.sh`; `swift run` loads it
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
  built. There is no cloud backend and no API-key field. The session is
  ephemeral (no cookies or disk cache) and ignores system proxies.
- *What:* `OwlContext.text` only — the visible range plus a margin, capped
  again here at 8 KB of UTF-8 — plus the language and the file name. Never
  the whole file, the path, other tabs, the selection or the clipboard.
- *When:* `OwlScheduler` decides. A check fires only after typing pauses
  for 5 s, at most once per 90 s per document, never twice for the same
  `editGeneration`, never while the app is inactive, in Low Power Mode, or
  on battery below 20 %. Each request is hard-capped at 20 s and is
  cancelled the moment the document is edited again or the app goes
  inactive; results for a stale generation are dropped.
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

**Apple Foundation Models.** `AppleFoundationModelsProvider` uses the
on-device `SystemLanguageModel` (macOS 26+, Apple silicon, Apple
Intelligence on) behind `#if canImport(FoundationModels)` and a runtime
availability check. The SDK's Private Cloud Compute model is deliberately
not used. With CI's Swift 6.1 / macOS 15 SDK the module is absent and a
placeholder that is never available compiles instead.

**Registry hook.** The owl UI owns the provider registry. It calls
`LocalAIOwl.makeProvider(settings:)` (nil while off) and wraps the provider
in `LocalAIOwl.makeScheduler`, feeding it `contextChanged` on edits and
scrolls and `setAppActive` from NSApplication notifications.

**Tests.** `Tests/CedricAITests` uses a URLProtocol stub server, a fake
clock and a fake power source. `CEDRIC_AI_LIVE=1 Scripts/test.sh --filter
LiveCheckTests` runs three sample snippets and a scheduler burst against a
real local server (`CEDRIC_AI_URL`, `CEDRIC_AI_MODEL` override); CI never
sets it.

## Dev hooks

`DevHooks.swift` documents the `CEDRIC_*` launch variables used for
screenshots (`CEDRIC_SNAPSHOT`, rendered with `cacheDisplay`, so it works
with the screen locked), perf (`CEDRIC_PERF_OPEN`, `CEDRIC_LAUNCH_METRICS`),
the session check, and the owl (`CEDRIC_OWL*`). None of them is saved.
