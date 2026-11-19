<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="OwlInk icon">
</p>

<h1 align="center">OwlInk</h1>

<p align="center">
  A fast, simple, native text editor for the Mac.<br>
  With Cedric the owl as an optional, offline AI helper.
</p>

OwlInk is for quick work on files, in the spirit of Notepad++: open, edit,
close, and everything is still there next time. It is built with AppKit and
TextKit 2, with no dependencies outside Apple's frameworks.

## Install

With [Homebrew](https://brew.sh):

```sh
brew trust --tap d4rkwyng/tap      # once: newer Homebrew asks you to trust a third-party tap
brew install --cask d4rkwyng/tap/owlink
```

Or download `OwlInk-<version>.zip` from
[Releases](https://github.com/d4rkwyng/owlink/releases), open it, and move
OwlInk to Applications.

Needs macOS 14 or later, on Apple silicon or Intel.

Coming from Cedric Pad? It is the same app, renamed in 0.1.2. Your settings,
tabs and models carry over; see the [changelog](CHANGELOG.md).

## Features

- **Tabs that come back.** Quit without saving prompts; every tab, saved or
  not, is there on the next launch. ⇧⌘T reopens closed tabs.
- **Fast with big files.** A 10 MB JSON file opens and is coloured in under
  0.1 s.
- **Syntax colouring** for Swift, Python, JavaScript, HTML, shell,
  PowerShell, C and more.
- **Live preview** for Markdown and HTML, side by side or in its own window.
- **CSV and TSV as a spreadsheet**: a sortable grid next to the text.
- **PDFs, images and Office files** open in tabs too.
- **Find and replace** with regular expressions.
- **Git, lightly**: changed lines in the gutter, and Compare with Last
  Commit.
- **The `cedric` command** opens files from Terminal (`cedric notes.md:42`)
  and can be git's editor (`cedric -w`).
- **Cedric the owl** (off by default): one hint at a time, an offline
  check of scripts for risky commands, and Ask Cedric on a local model.
  Private and opt-in.

Everything else is in the [manual](docs/MANUAL.md).

## Documentation

- [Manual](docs/MANUAL.md): every feature, in detail.
- [Changelog](CHANGELOG.md): what each version added and fixed.
- Keyboard shortcuts: Help › Keyboard Shortcuts in the app lists them all.
- [Architecture](docs/architecture.md): how it is put together.

## Building from source

Needs Xcode 26 or its Command Line Tools (Swift 6.3, macOS 26 SDK).

```sh
Scripts/bundle-app.sh        # builds dist/OwlInk.app
Scripts/test.sh              # unit tests
open dist/OwlInk.app
```

More in the manual: [Building from source](docs/MANUAL.md#building-from-source).

## Privacy

Nothing leaves your Mac unless you choose to download a model.

## Built with Claude

OwlInk is built with Claude: Claude Code agents under Derek's direction, with
review and tests before release.

## License

BSD-2-Clause. See [LICENSE](LICENSE). Third-party credits (llama.cpp, the
Dracula theme, the downloadable models) are in the
[manual](docs/MANUAL.md#licences).
