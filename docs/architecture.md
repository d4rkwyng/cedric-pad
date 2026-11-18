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
with the screen locked), perf (`CEDRIC_PERF_OPEN`, `CEDRIC_LAUNCH_METRICS`)
and the session check. None of them is saved.
