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
  stop typing, so a crash or power cut loses at most that. Closing a tab
  doesn't ask either (hot close): its unsaved text is written to the
  session first, and **File › Reopen Closed Tab** (⇧⌘T) brings it back,
  unsaved changes and all, even after a quit or a crash. The last 50
  closed tabs are remembered (tabs without unsaved text are forgotten
  first).
- **Fast to open.** TextKit 2 lays out only what is on screen; a 10 MB JSON
  file opens and is coloured in under 0.1 s, a 50 MB log in about 0.2 s on an
  M-series Mac (see Performance below).
- **Syntax colouring** for Swift, Python, JavaScript, TypeScript, JSON, YAML,
  Markdown, HTML (with embedded `<script>` and `<style>`), XML (with CDATA;
  `.xml`, `.plist` and friends, no longer coloured as HTML), CSS, shell,
  C/C++/Objective-C, Ruby, SQL, diff/patch, and INI/TOML/.env/.properties. Only the visible lines plus a margin are coloured, so
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
  default, or any installed fixed-pitch font; ⌘+ / ⌘− / ⌘0 zoom.
- **Settings** (Cedric › Settings…, ⌘,): theme, font and size, wrap,
  invisibles, line numbers, highlight occurrences, auto-close brackets,
  spelling while typing, and the default indentation, in one window (the
  menu toggles still work and the window follows them).
- **Mac file basics:** Save All (⌥⌘S), Revert to Saved (undoable with ⌘Z),
  Close Window (⇧⌘W: every tab in the window, each hot-closed), and the
  system Services in the app menu.
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
- **Indent and outdent:** Tab and ⇧Tab on a selection of several lines
  (or Edit › Line › Indent ⌘] / Outdent ⌘[) shift every line by one step,
  as one undo step. Each tab follows the file's own indentation (tabs, or
  2, 3, 4 or 8 spaces, read from its first lines), else the default in
  Settings; Format › Indentation picks spaces or tabs and the tab width for
  one tab (kept with the session) and converts the whole file between
  them. Where spaces were chosen (the file's own, the tab's, or a default
  saved in Settings), Tab inserts spaces to the next tab stop; otherwise
  it types a tab character, as before.
- **Bookmarks** (Edit › Bookmarks, as in Notepad++): Toggle Bookmark (⌘F2,
  or click a line number), Next / Previous Bookmark (F2 / ⇧F2, wrapping),
  Bookmark All Matches (⌥⌘F2: every line matching the find bar's search,
  or the selection or word under the caret), Clear Bookmarks (⇧⌘F2).
  Bookmarks stay on their lines as you edit, move with Move Line, and are
  kept with the session. Copy Bookmarked Lines and Delete Bookmarked Lines
  act on them all.
- **Filter lines** (Edit › Line › Keep Lines Matching… / Delete Lines
  Matching…): plain text or a regular expression, with or without case,
  as one undo step; bookmarks on the lines that stay follow them.
- **Auto-indent and pairing:** Return keeps the line's indent, one step
  more after `{` `[` `(` (and `:` in Python and YAML); Return between a
  pair puts the closer on its own line. In code, brackets and quotes close
  themselves, typing the closer steps over it, Backspace between a pair
  deletes both, and typing one with a selection wraps it (Edit ›
  Auto-Close Brackets and Quotes; never in plain text or Markdown). The
  bracket next to the caret and its partner are boxed.
- **Word, line and character counts** in the status bar, of the
  selection when there is one (characters are Unicode scalars). Documents
  over a million characters show lines only, so typing never waits on a
  count; over 50,000 they are counted when typing pauses.
- **Print** (File › Print…, ⌘P; Page Setup…, ⇧⌘P): the text in the
  editor's font, dark on white (not the theme's colours), wrapped to the
  page, with the file name, date and page numbers; line numbers are an
  option in the print panel.
- **Go to line** (⌘L, `42` or `42:7`), line numbers, current-line highlight,
  show invisibles (⌥⌘I), wrap lines (⌥Z).
- **Encodings and line endings:** UTF-8 (with or without BOM), UTF-16 LE/BE,
  Latin-1, Windows-1252 and Mac Roman, and LF/CRLF/CR, detected on open
  (a file that isn't UTF-8 is read as whichever 8-bit Western encoding
  makes sense of its accented letters and quotes) and shown in the status bar,
  with menus to convert (applied on save) or reopen with another encoding.
  Mixed line endings are shown as such and written as one kind on save.
- **PDFs open in a viewer tab** (read-only, PDFKit), from File › Open, a
  drop on a window or the Dock icon, `cedric file.pdf` (`file.pdf:3` for
  page 3), Open Recent or Finder's Open With (Cedric is registered as an
  alternate PDF viewer; Preview stays the default). A PDF is recognised by
  its `%PDF-` header, so one without the extension opens too. Continuous
  scroll; ⌘+ / ⌘− zoom, ⌘0 actual size, ⌘9 fit to the window; View › Show
  Page Thumbnails (⌥⌘B); ⌘F finds in the PDF with the find bar (⌘G / ⇧⌘G,
  Match Case); select and ⌘C copies text; ⌘L is Go to Page; the status bar
  shows page N of M and the zoom. **File › Open as Text** puts the PDF's
  text in a new untitled tab to edit (extracted in the background). Saving
  and editing commands are off in a PDF tab, and Cedric never writes to a
  PDF. A password-protected PDF asks for its password; a damaged one says
  so. PDF tabs come back with the session on their page and zoom (a PDF
  tab that isn't selected loads when you first click it); the owl stays
  out of them.
- **Drop a file on the text to open it** (in its own tab), rather than
  pasting its path; dropped text is inserted as before.
- **Files changed on disk** reload by themselves when the tab has no unsaved
  changes.
- **`cedric` command-line launcher** (below), with `-w` so it can be
  git's editor, and `file:line:col`.
- **Cedric the owl** (View › Show Cedric the Owl, off by default): a small
  assistant in the corner that offers one hint at a time, with **Fix it**
  where a safe fix exists, **Show Me** where it points at something, **Not
  now** and **Don't show again**. His rules need no AI and only ever look
  at the text in view (at most 8 KB):
  - warnings: merge-conflict markers left in the file; something that looks
    like a secret (a private key, an AWS key, a GitHub, Slack, Stripe or
    OpenAI/Anthropic token); JSON that doesn't parse (with the line);
    an unmatched or unclosed bracket in Swift, JavaScript, TypeScript, C,
    CSS or Python (strings, comments and regexes skipped; "never closed"
    only in a saved file); a file changed on disk under your edits;
  - fixes: format one-line JSON; curly quotes pasted into code; tabs
    indenting YAML; tabs and spaces mixed (to whichever the file mostly
    uses; a Makefile keeps its tabs); zero-width and stray byte-order-mark
    characters; trailing spaces; "It looks like you're writing a to-do
    list" → Markdown checkboxes; a word typed twice ("the the"); two spaces
    after some full stops but not others; no newline at the end of a saved
    code file;
  - offers and notes: plain text that is really Markdown, HTML or JSON
    (colour it that way); unsaved for two hours (save a copy); CRLF or
    mixed line endings; and, once ever, a letter.

  Optional AI hints (View › Cedric AI Settings…, off by default) use a
  local model only. On Intel Macs automatic AI checks are **off** by
  default so typing stays fast: click the owl and choose **Ask AI Now**,
  or turn on "Check automatically when I pause typing" in the settings.
  In very large documents the owl only looks when clicked.

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
Scripts/pdf-check.sh                # PDF tabs in the running app: find, copy, zoom, Open as Text, session
Scripts/launch-speed-check.sh       # launch phase medians: empty, 8-tab session, 500 KB file
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
cedric src/main.c:120:7         # line 120, column 7 (grep -n / compiler output works too)
git log | cedric -              # stdin into a new untitled tab
git config --global core.editor "cedric -w"   # -w / --wait: return when the tab closes
```

It talks to the app through a `cedric://open?path=…&line=…&col=…` URL.
With `-w` the script makes a `cedric-wait.*` marker file in the temp
folder and passes it along; Cedric deletes it when that file's tab closes
(or when Cedric quits), and the script returns.

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

Macros, Replace in Files, automatic updates. See
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
