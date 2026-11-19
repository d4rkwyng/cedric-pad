# Changelog

All notable changes to OwlInk. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and OwlInk uses [semantic versioning](https://semver.org/). Each release's notes on GitHub
are its section below (`Scripts/changelog-section.sh`).

## [0.2.0]

### Added
- **Replace in Files.** Edit › Replace in Files… (⌥⇧⌘F) opens the Find in Files panel with a Replace field. Preview Replace… lists every change as before → after, with a box per file and per match to leave some out, and the files it skips and why (binary, over 20 MB, mixed line endings, changed since the search…). Replace All writes the rest atomically in each file's own encoding and line endings, keeping its permissions; files open in a tab are changed in the tab (one ⌘Z, unsaved) instead of on disk. Edit › Undo Replace in Files puts the last replace back byte for byte, skipping any file edited since. Find in Files results are now grouped by file, and a **Respect .gitignore** box (on by default) skips what the folder's .gitignore files ignore.
- **Folder sidebar** (in progress).
- **Multiple carets and column selection** (in progress).

### Known gaps
- Code folding and split view come in 0.3.0.
- Replace in Files skips files with mixed line endings (open them to replace there), symbolic links and hard-linked files. Respect .gitignore doesn't read git's `core.excludesFile` and matches case-sensitively.

## [0.1.2]

### Changed
- **The app is named OwlInk** (`OwlInk.app`). The owl assistant is still Cedric, and the command is still `cedric`. The release download is `OwlInk-<version>.zip`, the Homebrew cask is `owlink` (`brew install --cask d4rkwyng/tap/owlink`), Help › OwlInk Help opens the manual (docs/MANUAL.md), and the repository is github.com/d4rkwyng/owlink.

## [0.1.1]

### Added
- **Preview bar.** A compact bar across the top of the preview (docked or detached) with Refresh, Sync Scrolling, Zoom − / +, Export ▸ HTML / PDF for Markdown, Allow JavaScript, Allow Network and Detach / Attach; for CSV, the row count and Unsort. The View menu items still work.
- **PDF reader controls.** A floating capsule at the bottom of a PDF tab: previous / next page, an editable page number, zoom, actual size, fit width, fit page, thumbnails, find, rotate (the view only; the file is never changed) and Open in Default App. It fades when the mouse is still and comes back when it moves (no fade with Reduce Motion). ← / → and Page Up / Page Down turn the page.
- **Script risk check.** Edit ▸ Check Script for Risks… (also in the owl's menu) for shell, PowerShell, batch, .reg, Python and Ruby files. An offline scan runs first, with no AI and no network, and lists risky lines: downloaded code run directly (also by path or through `tee`), encoded or hidden commands, reverse shells, setuid, broad deletes, disk erasing, sudo and RunAs, persistence (including SSH `authorized_keys`), credential access, registry, quarantine, TCC and security changes. Only the first 20,000 lines are scanned, and a longer script says so. With an AI engine, Cedric then explains each finding and ends with a verdict: "No obvious red flags (not a guarantee)", "Run only if you trust the source" or "Don't run it". Cedric never claims a script is safe: the app rewrites any line that does, even for a moment while the answer streams, and forces "Don't run it — review the flagged lines" after a high-risk finding or a partial review, whatever the model said. The script's own text is passed as data and can't talk the model into a verdict; without an engine, the panel says it is the scan only.
- **Explain Line** and **What Does It Do?** quick actions for the selection, the caret's line or a whole script.
- **AI grammar check** in the owl's menu, using Ask Cedric's engine. The macOS spelling and grammar checker stays on.
- **The owl uses tools with the built-in Qwen3 model** (it scored 0.90 on Cedric's tool test after a prompt rewrite). Apple Intelligence and Qwen2.5-Coder stay without tools.
- More owl animations; idle CPU with the owl visible stays about the same.

### Changed
- **Ask Cedric is on by default when a local AI engine is ready** (Apple Intelligence, the downloaded built-in model, or a local server you set up and turned on), and works even when automatic AI hints are off; a network server is still used only when AI is on. Your choice sticks once you change it. Clicking the owl offers "Ask about this file…" first, or "Set Up Ask Cedric…" when there is no engine, and a one-time owl bubble points it out.
- **Long AI answers are no longer cut off.** The 120-second limit now covers only the wait for the first word; after that an answer may stream as long as words keep coming (30 seconds between them at most, 15 minutes in all).
- **Closing the last tab no longer brings it back.** Closing the last document tab or window still quits OwlInk, but it is now a close like any other: the tab goes to File › Reopen Closed Tab (⇧⌘T) with any unsaved text kept, and the next launch opens an empty Untitled tab. Quit (⌘Q) still restores every open tab.

### Fixed
- **A file opened while Ask Cedric or Settings was in front no longer becomes a tab of that window.** It opens as a tab in the document window (from Finder, the Dock, Open Recent, the `cedric` command or Reopen Closed Tab).

### Security
- **No AI through the environment.** The test switches that turned Ask Cedric on for one run (`CEDRIC_ASK_ENGINE`, `CEDRIC_AI_FAKE`) work only in debug builds; a release build always waits for your opt-in.
- **Honest privacy wording.** The owl's Ask Cedric bubble, the Ask Cedric setting's tooltip and the owl's own instructions now say where text goes for the engine in use: on this Mac (built-in, Apple Intelligence), or to the AI server you set up (named), and that automatic AI grammar, when on, also sends prose after you pause typing.
- **Owner-only Cedric folder.** `~/Library/Application Support/Cedric` (CLI token, session buffers, models) and the folders made in it are created 0700, and tightened to 0700 if an older version left them wider. The CLI token stays 0600.
- **CLI token made atomically.** The `cedric` script writes a new token to a private temp file and hard-links it into place (a token already there is kept), and retries an empty read once after 50 ms, so a run racing the app never sends an empty token.

## [0.1.0]

The first release: a fast, simple, native text editor for macOS 14 Sonoma and later, in the
spirit of Notepad++. Universal (Apple silicon and Intel), signed with Developer ID and notarized.

### Changed
- **Built-in AI default is now Qwen3 4B Instruct (2507), Apache-2.0.** It replaces Qwen2.5 Coder 3B, whose Qwen Research License is non-commercial; that model stays an optional download labelled "Non-commercial licence", and anyone who already downloaded it keeps using it until the new default is downloaded.

### Added
- **Tabs that come back.** Native window tabs. Quitting never asks to save: every tab, untitled ones and unsaved changes included, is restored on the next launch. Unsaved text is autosaved about 1.5 seconds after you stop typing, so a crash or power cut loses at most that. Closing a tab with unsaved changes still asks. Untitled tabs are numbered as TextEdit numbers them.
- **Fast with big files.** TextKit 2 lays out only what is on screen; a 10 MB JSON file opens and is coloured in under 0.1 s, a 50 MB log in about 0.2 s on an M-series Mac.
- **Syntax colouring** for Swift, Python, JavaScript, TypeScript, JSON, YAML, Markdown, HTML (with embedded script and style), CSS, shell, C/C++/Objective-C and Ruby. The language comes from the extension, a `#!` line or, for pasted text, the content; the status bar overrides it.
- **Live preview** for Markdown and HTML, side by side (View › Show Preview, ⌥⌘P). JavaScript and network access in the preview are off by default and can be turned on per tab.
- **Themes:** System, Light, Dark, Tankard and Dracula. Every theme's text meets WCAG AA contrast. SF Mono by default; ⌘+ / ⌘− / ⌘0 zoom.
- **Find and replace** in the document with regular expressions (`$1` in replacements), match case and whole word; Replace All is one undo step. **Go to line** (⌘L, `42` or `42:7`), line numbers, current-line highlight, show invisibles, wrap lines.
- **Encodings and line endings:** UTF-8 (with or without BOM), UTF-16 LE/BE and Latin-1; LF, CRLF and CR. Detected on open, shown in the status bar, convertible on save; a file can be reopened in another encoding.
- **Files changed on disk** reload by themselves when the tab has no unsaved changes.
- **Editor tools:** Open Recent (⌥⌘1…9); text tools for sorting, removing duplicate lines, reversing, joining, trimming, changing case, JSON pretty-print/minify, XML pretty-print and Base64/URL encoding (each one undo step); **Find in Files** (⇧⌘F) with include and exclude globs; **Compare** two tabs side by side (⌥⌘C); **Follow File** for logs (⌥⌘T).
- **The `cedric` command:** `OwlInk.app/Contents/Resources/cedric` opens files in the running app (`cedric notes.md`, `cedric src/main.c:120`, `git log | cedric -`).
- **Cedric the owl** (View › Show Cedric the Owl, off by default): a small owl in the editor's corner that offers hints in a speech bubble: format one-line JSON, mixed indentation, trailing whitespace, a file changed on disk under your edits, long-unsaved work. Apply is one undo step; hints can be snoozed or silenced. It fades when the caret comes near.
- **Optional AI hints for the owl, off by default** (View › Cedric AI Settings…). Where the AI runs is your choice, and it is always local:
  - **Built-in:** OwlInk downloads a Qwen model (1.1–4.7 GB, pinned by URL and SHA-256, licence shown first) and runs it in the app with llama.cpp. Pause and resume, delete at any time. Nothing is sent anywhere; the only network traffic is the model download from Hugging Face.
  - **Apple Intelligence** on macOS 26 with Apple silicon, on-device only (never Private Cloud Compute).
  - **LM Studio or Ollama** on this Mac or another Mac on your local network. Public internet addresses are refused.
  - Only the visible text (up to 8 KB) is used, after a pause in typing, at most every 90 seconds by default, never on battery below 20 % or in Low Power Mode. AI suggestions are checked against the code and dropped when they are provably wrong.

### Known gaps
- **Find in Files** searches only (there is no Replace in Files). It skips files over 20 MB, and UTF-16 files without a byte-order mark are treated as binary and skipped, although the editor opens them. Files that are not UTF-8 or UTF-16 are read as Latin-1, so a regex for non-ASCII text won't match a file in another legacy encoding (Windows-1252, Shift JIS…). At most 10,000 results.
- **Compare** is a read-only snapshot of both tabs; past 4,000 differences the middle is shown as one changed block.
- **The Markdown preview** is not full CommonMark: no reference-style links, simplified emphasis rules, no lazy continuation lines.
- **A large unsaved file** is rewritten whole on each autosave. A file changed on disk while its tab has unsaved edits is only flagged by the owl's "Reload?" hint (when the owl is on).
- **Built-in AI on Intel Macs** runs on the CPU: expect 35–50 seconds per hint (measured on Apple silicon as a stand-in, not yet on an Intel Mac). A faster Mac on your network is the better choice there.
- **No macros, no printing, no automatic updates** yet. OwlInk is not sandboxed (an editor opens arbitrary files by path from the command line).

### For contributors
- SwiftPM and the Command Line Tools only: `Scripts/bundle-app.sh` builds `OwlInk.app` (`--universal` for both architectures), `Scripts/test.sh` runs the Swift Testing suite, and in-process checks drive the real app with NSEvents and snapshots (`Scripts/typing-check.sh`, `render-check.sh`, `owl-check.sh`, `ai-check.sh`, `tools-check.sh`, `session-check.sh`, `launch-check.sh`).
- Two portable modules (CedricCore, CedricAI: Foundation only, no AppKit) and the AppKit app. llama.cpp is a pinned SwiftPM binary target (release b12360, checksum-verified), copied into `Contents/Frameworks`.
- Releases: `Scripts/release.sh` builds universal, signs `llama.framework` and then the app with the hardened runtime and no entitlements, checks both carry the same Team ID, real-launches the signed app, notarizes, staples and zips; `.github/workflows/release.yml` runs it on a `v*` tag (a `-rcN` suffix makes a draft prerelease) and keeps Apple's notary log as a workflow artifact. `.github/workflows/tests.yml` runs the tests on pushes and pull requests with Swift 6.1. The version lives in one place, `CedricVersion.source`; the release refuses a build whose Info.plist, `CEDRIC_VERSION` or tag disagree with it.

[0.2.0]: https://github.com/d4rkwyng/owlink/releases/tag/v0.2.0
[0.1.2]: https://github.com/d4rkwyng/owlink/releases/tag/v0.1.2
[0.1.1]: https://github.com/d4rkwyng/owlink/releases/tag/v0.1.1
[0.1.0]: https://github.com/d4rkwyng/owlink/releases/tag/v0.1.0
