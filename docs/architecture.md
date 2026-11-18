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
  change count moved since their last buffer write are rewritten.
- Quit (`applicationShouldTerminate`) saves synchronously and returns
  `.terminateNow`: no prompts. Windows closed by termination keep their
  buffers; a tab the user closes drops its buffer.
- On launch the session is restored before anything else opens. A file tab
  with a buffer gets the buffer's text and stays unsaved; a clean file tab
  reopens the file from disk; a file that has gone and had no buffer is
  dropped.
- `Scripts/session-check.sh` checks it end to end (kill -9 and normal quit).

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
  `MoreRules.swift` adds (in the order offered): merge-conflict markers,
  secrets (warning, no fix), JSON that doesn't parse, brackets (a small
  lexer skipping strings, comments, JS regexes and Swift/JS
  interpolations; whole documents only, "never closed" only when saved),
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
the file name. All four URLs and hashes were checked by downloading the
files and hashing them.

| Model | File | Size | Licence |
|---|---|---|---|
| Qwen2.5 Coder 3B (default) | `qwen2.5-coder-3b-instruct-q4_k_m.gguf` | 2.10 GB | Qwen Research License (non-commercial) |
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
Scripts/release.sh                    # dist/Cedric.app (signed, notarized, stapled) and dist/Cedric.zip
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
`Scripts/release.sh` with `CEDRIC_VERSION` from the tag, and attaches `Cedric.zip` to the
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
nothing sent anywhere), on by default (View › Check Spelling While Typing,
saved; also in Edit › Spelling and Grammar with Show Spelling and Grammar
and Check Document Now). Every batch of results passes through
`EditorTextView.handleTextCheckingResults`, which keeps only misspellings
inside `SpellScope.ranges`: prose in Plain Text and Markdown (minus code,
links and markup tokens), only comments and strings in code. The marks are
the text view's spelling state, a drawing attribute, so text colours are
never touched; suggestions, Learn and Ignore are the standard context menu.
Check Document Now walks our scope (the system's would stop on
identifiers). With the owl on, prose with three or more fixable
misspellings in his context window gets "Fix 3 typos?": the first
suggestion for each, as one replacement over their span, so one undo step.
`SpellScope.isFixable` skips ALL-CAPS words, words with digits, URLs, paths
and addresses. Offered once per document unless snoozed.

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
