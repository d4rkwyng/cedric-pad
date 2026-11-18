# Cedric

A fast, simple, native text editor for macOS, in the spirit of Notepad++: for
quick work on files, not for projects or compiling. AppKit and TextKit 2, no
dependencies outside Apple's frameworks.

Requires macOS 14 or later. Builds as a universal app (Apple silicon and Intel).

## Features (v0)

- **Tabs that come back.** Native macOS window tabs. Quitting never asks to
  save: every tab, including untitled tabs and unsaved changes, is restored on
  the next launch, as Notepad++ does. Unsaved text is autosaved to
  `~/Library/Application Support/Cedric/Session/` about 1.5 seconds after you
  stop typing, so a crash or power cut loses at most that. Closing a tab with
  unsaved changes still asks.
- **Fast to open.** TextKit 2 lays out only what is on screen; a 10 MB JSON
  file opens and is coloured in under 0.1 s, a 50 MB log in about 0.2 s on an
  M-series Mac (see Performance below).
- **Syntax colouring** for Swift, Python, JavaScript, TypeScript, JSON, YAML,
  Markdown, HTML (with embedded `<script>` and `<style>`), CSS, shell, C/C++/
  Objective-C and Ruby. Only the visible lines plus a margin are coloured, so
  big files stay fast. The language comes from the file extension, a `#!` line,
  or, for pasted text in an untitled tab, from the content; the status bar
  menu overrides it.
- **Live preview** for Markdown and HTML, side by side (View › Show Preview,
  ⌥⌘P). JavaScript and network access in the preview are **off** by default
  and can be turned on per tab (View menu). Scrolling the editor scrolls the
  preview to roughly the same place.
- **Themes:** System (light or dark with macOS), Light, Dark, Tankard (deep
  purple and amber) and Dracula, the same set as Tankard. Every theme's text
  colours meet WCAG AA contrast (4.5:1), checked by a test. SF Mono by
  default; ⌘+ / ⌘− / ⌘0 zoom.
- **Find and replace** in the current document, with regular expressions
  (ICU syntax, `$1` in replacements), match case and whole word; ⌘F, ⌥⌘F,
  ⌘G / ⇧⌘G, ⌘E. Replace All is one undo step.
- **Highlight occurrences:** other occurrences of the selection, or of the
  word under the caret, are tinted on screen (View › Highlight
  Occurrences). **Mark All** (⌃⌘M) marks every occurrence until Clear
  Marks (⌃⇧⌘M), with a count in the status bar. Only the visible text is
  searched, so typing stays fast in big files.
- **Line operations** (Edit › Line): Duplicate Line (⇧⌘D), Move Line Up /
  Down (⌃⌘↑ / ⌃⌘↓), Delete Line (⇧⌘K), Toggle Comment (⌘/, with the
  language's own comment marker: `//`, `#`, `/* */` or `<!-- -->`). Each
  works on every line the selection touches and is one undo step. ⌘X with
  nothing selected cuts the whole line.
- **Go to line** (⌘L, `42` or `42:7`), line numbers, current-line highlight,
  show invisibles (⌥⌘I), wrap lines (⌥Z).
- **Encodings and line endings:** UTF-8 (with or without BOM), UTF-16 LE/BE
  and Latin-1, and LF/CRLF/CR, detected on open and shown in the status bar,
  with menus to convert (applied on save) or reopen with another encoding.
  Mixed line endings are shown as such and written as one kind on save.
- **Files changed on disk** reload by themselves when the tab has no unsaved
  changes.
- **`cedric` command-line launcher** (below).

## Build and run

Needs the Command Line Tools (Swift 6.0 or later); Xcode is not required.

```sh
Scripts/bundle-app.sh               # dist/Cedric.app for this Mac, ad-hoc signed
Scripts/bundle-app.sh --universal   # arm64 + x86_64
open dist/Cedric.app
```

Tests (Swift Testing; the script adds the paths the Command Line Tools need):

```sh
Scripts/test.sh                     # unit tests: tokenizers, Markdown, codecs, find, session store, themes
Scripts/session-check.sh            # end to end: unsaved tabs survive a kill -9 and a normal quit
Scripts/typing-check.sh             # real key events in every theme; typed glyphs' pixels must be visible
Scripts/launch-check.sh             # real launches: stays up, quits cleanly, no crash report
swift Scripts/launch-time.swift dist/Cedric.app /System/Applications/TextEdit.app
```

A local build is ad-hoc signed, not notarized. If macOS refuses to open a
copied build, remove the quarantine flag: `xattr -dr com.apple.quarantine Cedric.app`.

## The `cedric` command

`Cedric.app/Contents/Resources/cedric` opens files in the running app (or
starts it). Link it onto your PATH:

```sh
ln -s /Applications/Cedric.app/Contents/Resources/cedric /usr/local/bin/cedric
cedric notes.md                 # open (a missing file opens as a new tab that saves there)
cedric src/main.c:120           # open at line 120 (also: cedric +120 src/main.c)
git log | cedric -              # stdin into a new untitled tab
```

It talks to the app through a `cedric://open?path=…&line=…` URL.

## Design notes

- **Own tab model, not NSDocument.** Notepad++'s model (quit without prompts,
  restore everything) fights NSDocument's unsaved-changes review on quit and
  its own autosave locations for untitled documents. `EditorDocument` is a
  small model; `SessionStore` (in CedricCore, tested) writes `session.json`
  and one buffer file per unsaved tab, atomically, buffers first.
- **Hand-written highlighter, not tree-sitter.** Each language is a line
  tokenizer: a pure function of (line, state at line start) → tokens + state
  at line end, scanning UTF-16 directly. The engine caches the state at each
  line start, so an edit only invalidates from the edited line down, and
  colouring the viewport only scans from the last known state. Languages
  without cross-line state (JSON, YAML, plain) never scan above the viewport.
  Colours are applied as foreground-colour attributes on the visible lines
  (not registered with undo); new text starts in the theme's text colour.
  Tree-sitter would parse more
  correctly (real grammars, nesting, embedded languages) but brings a C
  runtime plus one generated parser per language (several MB of C each),
  parses whole files up front, and would be the project's first external
  dependency; see `docs/architecture.md`. The `Tokenizer` protocol leaves room
  to plug one in later for specific languages.
- **Own Markdown renderer, not swift-markdown.** `Markdown.render` covers
  what notes and READMEs use (headings, emphasis, code spans and fences,
  lists with nesting and task items, block quotes, tables, links, images,
  autolinks, raw HTML blocks) in about 500 lines with no dependencies.
  swift-markdown would mean swift-markdown plus swift-cmark (C). Known
  differences from CommonMark: no reference-style links, simplified emphasis
  rules and lazy continuation. `data-line` attributes drive scroll sync.

More in [docs/architecture.md](docs/architecture.md).

## Releases

Signed with Developer ID and notarized, from `Scripts/release.sh` (locally or
by the Release workflow on a `v*` tag); see `CHANGELOG.md` for what each
version has, including its known gaps, and *Signing a release* in
`docs/architecture.md` for the pipeline.

## Not built yet

Macros, printing, Replace in Files, automatic updates. See
`docs/architecture.md` for where they plug in.

## Built with Claude

Cedric is built with Claude: Claude Code agents under Derek's direction, with
review and tests before release.

## License

BSD-2-Clause. See [LICENSE](LICENSE). The Dracula theme's colours are by
[Dracula Theme](https://draculatheme.com), used under the MIT license.

The built-in AI engine uses [llama.cpp](https://github.com/ggml-org/llama.cpp)
(MIT, © the ggml authors), bundled as `llama.framework`. Models are not
bundled: the ones Cedric offers to download are Qwen models by Alibaba
Cloud, each under its own licence, shown before download (Qwen2.5-Coder
1.5B and 7B and Qwen3 4B: Apache-2.0; Qwen2.5-Coder 3B: Qwen Research
License, non-commercial).
