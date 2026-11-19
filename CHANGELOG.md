# Changelog

All notable changes to Cedric Pad. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Cedric Pad uses [semantic versioning](https://semver.org/). Each release's notes on GitHub
are its section below (`Scripts/changelog-section.sh`).

## [Unreleased]

### Added
- **Preview bar.** A compact bar across the top of the preview (docked or detached) with Refresh, Sync Scrolling, Zoom − / +, Export ▸ HTML / PDF for Markdown, Allow JavaScript, Allow Network and Detach / Attach; for CSV, the row count and Unsort. The View menu items still work.
- **PDF reader controls.** A floating capsule at the bottom of a PDF tab: previous / next page, an editable page number, zoom, actual size, fit width, fit page, thumbnails, find, rotate (the view only; the file is never changed) and Open in Preview. It fades when the mouse is still and comes back when it moves (no fade with Reduce Motion). ← / → and Page Up / Page Down turn the page.

### Changed
- **Closing the last tab no longer brings it back.** Closing the last document tab or window still quits Cedric Pad, but it is now a close like any other: the tab goes to File › Reopen Closed Tab (⇧⌘T) with any unsaved text kept, and the next launch opens an empty Untitled tab. Quit (⌘Q) still restores every open tab.

## [0.1.0]

The first release: a fast, simple, native text editor for macOS 14 Sonoma and later, in the
spirit of Notepad++. Universal (Apple silicon and Intel), signed with Developer ID and notarized.

### Changed
- **Renamed to Cedric Pad** (`Cedric Pad.app`). The owl assistant is still Cedric, and the command is still `cedric`. Test builds named Cedric.app keep their settings, open tabs and downloaded models: the bundle identifier (`net.mindtricks.cedric`), the `cedric://` scheme and `~/Library/Application Support/Cedric` are unchanged. Delete the old Cedric.app after installing.
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
- **The `cedric` command:** `Cedric Pad.app/Contents/Resources/cedric` opens files in the running app (`cedric notes.md`, `cedric src/main.c:120`, `git log | cedric -`).
- **Cedric the owl** (View › Show Cedric the Owl, off by default): a small owl in the editor's corner that offers hints in a speech bubble: format one-line JSON, mixed indentation, trailing whitespace, a file changed on disk under your edits, long-unsaved work. Apply is one undo step; hints can be snoozed or silenced. It fades when the caret comes near.
- **Optional AI hints for the owl, off by default** (View › Cedric AI Settings…). Where the AI runs is your choice, and it is always local:
  - **Built-in:** Cedric Pad downloads a Qwen model (1.1–4.7 GB, pinned by URL and SHA-256, licence shown first) and runs it in the app with llama.cpp. Pause and resume, delete at any time. Nothing is sent anywhere; the only network traffic is the model download from Hugging Face.
  - **Apple Intelligence** on macOS 26 with Apple silicon, on-device only (never Private Cloud Compute).
  - **LM Studio or Ollama** on this Mac or another Mac on your local network. Public internet addresses are refused.
  - Only the visible text (up to 8 KB) is used, after a pause in typing, at most every 90 seconds by default, never on battery below 20 % or in Low Power Mode. AI suggestions are checked against the code and dropped when they are provably wrong.

### Known gaps
- **Find in Files** searches only (there is no Replace in Files). It skips files over 20 MB, and UTF-16 files without a byte-order mark are treated as binary and skipped, although the editor opens them. Files that are not UTF-8 or UTF-16 are read as Latin-1, so a regex for non-ASCII text won't match a file in another legacy encoding (Windows-1252, Shift JIS…). At most 10,000 results.
- **Compare** is a read-only snapshot of both tabs; past 4,000 differences the middle is shown as one changed block.
- **The Markdown preview** is not full CommonMark: no reference-style links, simplified emphasis rules, no lazy continuation lines.
- **A large unsaved file** is rewritten whole on each autosave. A file changed on disk while its tab has unsaved edits is only flagged by the owl's "Reload?" hint (when the owl is on).
- **Built-in AI on Intel Macs** runs on the CPU: expect 35–50 seconds per hint (measured on Apple silicon as a stand-in, not yet on an Intel Mac). A faster Mac on your network is the better choice there.
- **No macros, no printing, no automatic updates** yet. Cedric Pad is not sandboxed (an editor opens arbitrary files by path from the command line).

### For contributors
- SwiftPM and the Command Line Tools only: `Scripts/bundle-app.sh` builds `Cedric Pad.app` (`--universal` for both architectures), `Scripts/test.sh` runs the Swift Testing suite, and in-process checks drive the real app with NSEvents and snapshots (`Scripts/typing-check.sh`, `render-check.sh`, `owl-check.sh`, `ai-check.sh`, `tools-check.sh`, `session-check.sh`, `launch-check.sh`).
- Two portable modules (CedricCore, CedricAI: Foundation only, no AppKit) and the AppKit app. llama.cpp is a pinned SwiftPM binary target (release b12360, checksum-verified), copied into `Contents/Frameworks`.
- Releases: `Scripts/release.sh` builds universal, signs `llama.framework` and then the app with the hardened runtime and no entitlements, checks both carry the same Team ID, real-launches the signed app, notarizes, staples and zips; `.github/workflows/release.yml` runs it on a `v*` tag (a `-rcN` suffix makes a draft prerelease) and keeps Apple's notary log as a workflow artifact. `.github/workflows/tests.yml` runs the tests on pushes and pull requests with Swift 6.1. The version lives in one place, `CedricVersion.source`; the release refuses a build whose Info.plist, `CEDRIC_VERSION` or tag disagree with it.

[0.1.0]: https://github.com/d4rkwyng/cedric/releases/tag/v0.1.0
