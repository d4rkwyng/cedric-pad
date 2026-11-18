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

## Where the v0 non-goals plug in

- **Find in files:** `FindEngine` already works on any NSString; a results
  panel would read files through `TextCodec.decode` off the main thread.
- **Compare tabs:** a second editor in the split view (the preview slot),
  fed by a line diff over two `LineIndex`es.
- **Text tools** (sort, case, trim, base64): pure functions in CedricCore
  applied through `shouldChangeText` so they undo.
- **Tail mode:** `reloadIfChangedOnDisk` already exists; tail mode would
  append only the new bytes and keep the caret at the end.
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

## Dev hooks

`DevHooks.swift` documents the `CEDRIC_*` launch variables used for
screenshots (`CEDRIC_SNAPSHOT`, rendered with `cacheDisplay`, so it works
with the screen locked), perf (`CEDRIC_PERF_OPEN`, `CEDRIC_LAUNCH_METRICS`),
the session check, and the owl (`CEDRIC_OWL*`). None of them is saved.
