# Changelog

All notable changes to Owlink. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and Owlink uses [semantic versioning](https://semver.org/). Each release's notes on GitHub
are its section below (`Scripts/changelog-section.sh`).

## [0.2.1]

### Added
- **Cedric follows Ask Cedric.** The editor's owl, wherever you put him, reacts to the conversation (there is no second owl in the panel): a wave when it opens, a glance toward the panel while you type, thinking (and searching) while the model works, talking while the answer streams, writing while he proposes an edit, a nod when it's done, a wing flap on Apply, and a sleepy look after an error or with no engine. While the chat is busy his own idle animations and hints wait; under Reduce Motion he shows still poses only. The panel opens beside him, on the side of the screen with room, and still floats free; once you move it, it reopens where you left it until you quit. With Cedric hidden, the chat works as before and opens at the window's bottom-right corner.
- **Image tabs have a right-click menu:** Zoom In, Zoom Out, Actual Size, Zoom to Fit, Rotate Left and Right (the view only; the file is never changed), Copy Image, Copy Path, Reveal in Finder, Open in the default app and Show Info (dimensions, file size, format, colour space).

### Changed
- **The app is now called Owlink** (lowercase l, `Owlink.app`, download `Owlink-<version>.zip`). Only the spelling changed: the owl is still Cedric, the command is still `cedric`, the Homebrew cask is still `owlink`, and your settings, tabs and models carry over. If you installed by hand, delete the old `OwlInk.app` and re-pin the Dock icon.
- **About Owlink** shows the version (without a build number), who made it, a link to github.com/d4rkwyng/owlink, the BSD-2-Clause licence, credits for llama.cpp (MIT) and the AI models (downloaded on request, each under its own licence), a note that Cedric the owl is a fan's tribute and Owlink is not affiliated with or endorsed by Sierra or its successors, and © 2026 d4rkwyng.
- **Help menu:** Owlink Help opens the manual for the version you have (a release opens it at its tag), and there are new Owlink on GitHub and Report an Issue… items.
- **View › Preview menu** with the preview bar's actions and shortcuts: Show Preview ⌥⌘P, Detach Preview ⇧⌥⌘P, Refresh Preview ⌥⌘R, Sync Scrolling, Zoom In Preview ⌥⌘=, Zoom Out Preview ⌥⌘−, Restore File Order (CSV), Export as HTML / PDF, Allow JavaScript and Allow Network, each enabled when the bar's button is. Show and Detach Preview moved there from the top of the View menu.
- **Settings no longer repeats the menus.** Each option is in one place: Settings has the theme, font, default indentation, git changes in the gutter, Ask Cedric and quitting on the last close; wrap lines, invisibles, line numbers and highlight occurrences stay in the View menu, auto-close brackets, spelling and grammar in the Edit menu. The View › Theme submenu is gone (Settings has it). Your choices are kept as they were.
- **Status bar zoom** ("110%") is a menu: Zoom In ⌘+, Zoom Out ⌘−, Actual Size ⌘0 and 75 % to 200 %. With the preview docked, the editor's status items stay under the editor instead of running under the preview.

### Fixed
- **Undo Replace in Files can always be tried again.** If the backup copy of a file couldn't be read (missing, no permission, or not matching the original), Undo used to mark the replace as undone and offer no retry. Now the file is left as the replace wrote it, the message names it and says why ("backup copy unreadable: permission denied"), and Edit › Undo Replace in Files stays available.
- **Undo Replace in Files from the Edit menu with the Find in Files panel hidden** now shows its progress and then its result in a bar at the top of the tab.
- **Dragging the Ask Cedric panel is smooth.** It was a child window of the editor and trailed the pointer by one mouse event all the way (measured with real mouse drags on macOS 26); it is now a floating panel of its own that keeps up with the pointer. It no longer moves with the editor window, and it hides when you switch to another tab and comes back with its tab.

### Security
Fixes from a security review of 0.2.0. None needs anything from you; the details are in the manual.
- **Release builds ignore Owlink's developer and test switches.** Another program on your Mac could start Owlink with them to open files or load an AI model in its name. Only a few switches that open nothing are left, for the release's own launch check.
- **Links in PDFs no longer open in one click.** A web or mail link asks first and shows the whole address, a link to a file only shows it in Finder, and any other kind of link is ignored, as in the Markdown preview.
- **The preview with JavaScript on can load only images, fonts and CSS from the document's folder**, never other files or hidden ones, so a page can't read the files next to it. JavaScript and Network switch off when the file is reloaded from disk, and their tooltips say what the two allow together.
- **Crafted Markdown can no longer stall the preview.** Long runs of brackets, links, emphasis marks and very deep lists or quotes render in linear time; lists and quotes nested more than 64 deep show the rest as text. Copy as HTML and Export as HTML render in the background, and very deep nesting can no longer exhaust a render thread's stack.
- **Cedric's document search has a time limit**, and a regular expression the model writes is limited in length. A pattern that would run for ever is stopped with an error.
- **LM Studio and Ollama on the network are reached at the address that was checked**, not looked up a second time, so a DNS answer that changes in between can't send your text elsewhere (plain http; with https the server's certificate must match its name).
- **Replace in Files and its undo write through the folders they checked.** A folder swapped for a link to somewhere else while a replace runs makes that file's write fail instead of landing outside the searched folder.
- **Unsaved text and Replace in Files' copies are kept out of Time Machine**, and a closed tab's unsaved text is now deleted 30 days after closing (at most 100 such tabs). The manual has a new Privacy section saying what Owlink keeps.
- **The `cedric` command's token is no longer on the command line**, where other users of the Mac could see it, and Owlink makes a new one at every launch.
- **A downloaded AI model's checksum is checked again** before it is first loaded and whenever the file changes; one that doesn't match isn't loaded.
- **Copied and exported HTML loses every script handler**, including ones written without a space before them.
- **The "Open … requested by a link?" question shows hidden and direction-changing characters as codes**, so a path can't pretend to be another.
- An unused library search path was dropped from the app.

## [0.2.0]

### Added
- **Replace in Files.** Edit › Replace in Files… (⌥⇧⌘F) opens the Find in Files panel with a Replace field. Preview Replace… lists every change as before → after, with a box per file and per match to leave some out, and the files it skips and why (binary, over 20 MB, mixed line endings, changed since the search…). Replace All writes the rest atomically in each file's own encoding and line endings, keeping its permissions, in the background with a progress bar; files open in a tab are changed in the tab (one ⌘Z, unsaved) instead of on disk. Edit › Undo Replace in Files puts the last replace back byte for byte, skipping any file edited since. Find in Files results are now grouped by file, and a **Respect .gitignore** box (on by default) skips what the folder's .gitignore files ignore.
- **Folder sidebar.** File › Open Folder… (⇧⌘O), or a folder dropped on the Dock icon or a window, shows the folder as an expandable tree at the left of the editor; View › Show Folder Sidebar (⌃⌘1) hides and shows it. Hidden by default: nothing is loaded or watched until a folder is opened. Folders list only when expanded, folders first in Finder order, without `.git`, `.DS_Store` or hidden files (Show Hidden Files in the context menu). What the folder's .gitignore files ignore is dimmed. A click opens the file in a tab, or selects its tab if it is open. The tree follows files created, deleted and renamed on disk. Context menu: Reveal in Finder, Copy Path, Find in Folder…, Close Folder. The folder, its expanded folders and the sidebar's width come back with the session.
- **Multiple carets and column selection.** ⌥-drag selects a column (dragging straight down makes a column of carets); ⌘-click adds or removes a caret; Edit › Selection › Add Caret Above / Below (⌃⇧↑ / ⌃⇧↓), Add Next Occurrence (⌘D: the word at the caret first, then each next match) and Select All Occurrences (⌃⌘G); ⎋ goes back to one caret. Typing, Delete, Return (with indent), Tab, auto-closed brackets and quotes, paste (one line per caret when the clipboard has as many lines), copy, cut, the arrow keys and ⇧-arrows work at every caret. Input methods and dead keys compose at the main caret and the committed text goes in at all of them. One ⌘Z undoes one edit at all carets and puts the carets back.

### Known gaps
- Code folding and split view come in 0.3.0.
- Replace in Files skips files with mixed line endings (open them to replace there), symbolic links, hard-linked files, read-only files ("read-only"), anything inside a `.git` folder or a `.git` file (whatever the Exclude field says), and files whose encoding was guessed as Latin-1, Windows-1252 or Mac Roman when the replacement has non-ASCII text or the file holds UTF-8 sequences ("encoding uncertain": it may be UTF-8 with a stray byte; open it to replace there). Undo Replace in Files leaves a file that has become read-only and says so; Undo stays available to try again once it can be written. Respect .gitignore doesn't read git's `core.excludesFile` and matches case-sensitively.
- Multiple carets: VoiceOver follows the main caret only; the extra carets don't blink; ↑/↓ and Add Caret Above/Below move by logical lines, not wrapped rows; each typed key at several carets is its own undo step.

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
