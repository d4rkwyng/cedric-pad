# Cedric Pad

A fast, simple, native text editor for macOS, in the spirit of Notepad++: for
quick work on files, not for projects or compiling. AppKit and TextKit 2, no
dependencies outside Apple's frameworks. Its assistant is Cedric, a small
owl with a monocle (off by default).

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
  first; a closed tab with unsaved text is never forgotten).
  The first time in a launch that a file tab with unsaved edits is closed,
  the tab in front says the file wasn't written, with **Save Now**.
  Closing the last document window (text, PDF, image or Office tab) quits Cedric Pad.
  It is a close like any other: the tab goes to Reopen Closed Tab (⇧⌘T) with
  its unsaved text kept, and the next launch opens an empty Untitled tab.
  Quit (⌘Q) with tabs open brings them all back next launch.
  Detached previews, Settings and panels don't keep Cedric Pad running.
  Settings › "Quit when the last window closes" turns this off.
- **Fast to open.** TextKit 2 lays out only what is on screen; a 10 MB JSON
  file opens and is coloured in under 0.1 s, a 50 MB log in about 0.2 s on an
  M-series Mac (see Performance below).
- **Syntax colouring** for Swift, Python, JavaScript, TypeScript, JSON, YAML,
  Markdown, HTML (with embedded `<script>` and `<style>`), XML (with CDATA;
  `.xml`, `.plist` and friends, no longer coloured as HTML), CSS, shell,
  C/C++/Objective-C, Ruby, SQL, diff/patch, INI/TOML/.env/.properties,
  PowerShell (`.ps1` `.psm1` `.psd1`: comments and comment-based help,
  literal, expandable and here-strings with `$var` and nested `$( … )`
  coloured inside, variables, Verb-Noun cmdlets, `-Parameters`, `-eq`-style
  operators, `[types]` and `[Attributes()]`, `1KB` numbers), Windows batch
  files (`.bat` `.cmd`: `REM`/`::`, labels, `%var%`, `!var!`, `%%i`) and
  registry exports (`.reg`) (CSV and TSV open as plain text with a grid preview). Only the visible lines plus a margin are coloured, so
  big files stay fast. The language comes from the file extension, a `#!` line,
  or, for pasted text in an untitled tab, from the content; the status bar
  menu overrides it.
- **Live preview** for Markdown and HTML, side by side (View › Show Preview,
  ⌥⌘P). JavaScript and network access in the preview are **off** by default
  and can be turned on per tab (View menu, or the preview bar). A compact
  **preview bar** across the top of the preview (and of a detached
  preview's window) has Refresh, Sync Scrolling on/off, Zoom − / +,
  Export ▸ HTML / PDF (Markdown), Allow JavaScript, Allow Network and
  Detach / Attach; for CSV, the row count and Unsort (back to file order).
  It follows the theme; every button has a tooltip and a VoiceOver label.
  A link in the preview never
  launches anything: web and mail links open only after you confirm the
  full URL, a text file in the document's folder opens in a tab, any
  other file (or one outside the folder) is shown in Finder, and other
  schemes are ignored. The Markdown preview doesn't
  flicker or jump: it is rendered in the background (a 1 MB file costs the
  main thread about a millisecond per update), and only the blocks that
  changed are swapped into the page, so it keeps its place and its images.
  Scrolling either side scrolls the other to the same source line (by
  block, list item and quote). Relative images load from the document's
  folder (and only from there), and a link to a relative `.md` (or other
  text) file opens it in a Cedric Pad tab. The renderer follows CommonMark's
  emphasis rules (`**bold *mix***` nests properly) and knows reference
  links, footnotes (`[^1]`), GitHub alerts (`> [!NOTE]`, `[!TIP]`,
  `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), task lists (disabled
  checkboxes) and YAML frontmatter, which shows as a small metadata table
  (and is coloured as YAML in the editor). Fenced code blocks are
  coloured by their language (```` ```swift ````, `py`, `js`, `bash`, …)
  both in the editor and in the preview, by Cedric Pad's own tokenizers and
  the theme's colours (no JavaScript highlighter). **Detach Preview** (View menu, ⇧⌥⌘P,
  or Detach on the preview bar) moves it into its own resizable
  window, "notes.md — Preview", still updating as you type; it stays
  with its own document whichever tab is in front, and closes with that
  tab. Attach Preview docks it again; closing its window closes the
  preview. A detached preview and its window's frame are kept with the
  session (restored just after the window first shows).
- **Markdown editing:**
  - **Lists:** Return continues a `-`, `*`, `+`, `1.` or `1)` list (and
    one in a `> ` block quote) with the same indent; the number goes up
    and a task item `- [x]` continues as `- [ ]`. Return on an empty item
    outdents it if it is nested, else ends the list. Tab and ⇧Tab in a
    list item indent or outdent the item with its sub-items, by the
    parent's content width (2 under `- `, 3 under `1. `). Ordered lists
    renumber after Return, Tab and ⇧Tab (a list written `1. 1. 1.` stays
    so; a nested list starts at 1). Each is one undo step; nothing
    happens inside fenced code or while an input method is composing.
  - **Format › Markdown:** Bold ⌘B, Italic ⌘I, Strikethrough ⇧⌘X,
    Inline Code ⌃\` and Link ⌘K wrap the selection, or with no
    selection put the pair in with the caret between. Each takes its
    markers off when they are already there (around or inside the
    selection, or around the caret's word), so ⌘I on `*word*` doesn't
    stack another pair. ⌘K turns the selection into `[text](|)` with the
    caret in the URL, or uses the URL on the clipboard; a selected URL
    becomes `[](url)`; in a link it unlinks. Only in Markdown tabs.
  - **Checkboxes:** Format › Markdown › Toggle Checkbox (⌘↩) checks
    or unchecks `- [ ]` / `- [x]` on the caret's line or every selected
    line, adds a box to a list item without one, and turns a plain line
    into `- [ ] line`. One undo step.
  - **Tables:** in a GFM table, Tab and ⇧Tab move to the next or
    previous cell (selecting its text) and line up the whole table's
    pipes; Tab past the last cell adds a row, and Tab after a lone
    `| a | b |` header builds the `| --- |` row. Return in a row goes to
    the same cell in the row below (adding one at the end); Return in an
    empty last row ends the table. Format › Markdown › Format Table
    lines it up without moving. Widths count East Asian wide characters
    and emoji as two columns (the CJK fallback font isn't exactly twice
    SF Mono's width, so on screen those rows can be a pixel or two off);
    alignment colons are kept. Tables in fenced code, and tables over
    2,000 lines, are left alone.
  - **Smart paste:** a URL pasted over a selection makes
    `[selection](url)` (not in code). An image pasted or dropped on a
    Markdown tab (an image file, or a picture such as a screenshot on the
    clipboard) is copied into an `images` folder next to the document and
    goes in as `![](images/name.png)`; an image already inside the
    document's folder is linked where it is, not copied. An untitled tab
    has no folder yet: it inserts nothing and offers Save As. Undo takes
    the link out but leaves the copied file. Other dropped files still
    open in their own tabs, and in other languages a dropped image opens
    as before.
- **Markdown outline** (View › Show Outline, ⌃⌘O; for a PowerShell
  script it lists the functions, filters, classes and enums): the document's
  headings (`#` and underlined ones, never a `#` inside fenced code or
  frontmatter), indented by level, at the left of the text. Click one to
  jump there; the heading the caret is under stays selected; the filter
  field narrows the list. **Go to Heading…** (Edit menu, ⇧⌘J) opens it
  with the filter focused: type, ↑/↓, Return to jump (Esc goes back), and
  it puts itself away again. Built the first time it is shown and updated
  in the background when typing pauses (in large mode only when opened,
  up to 5,000 headings).
- **Markdown export and copy:** File › Export as HTML… writes a standalone
  page (no script), and File › Export as PDF… a paginated PDF (cut between
  blocks), both rendered as the preview renders them in a light,
  theme-neutral style whatever the editor's theme. Edit › Copy as HTML puts
  the rendered HTML of the selection (or the whole document) on the
  clipboard as text; Copy as Rich Text puts it there as rich text (RTF and
  HTML) for Mail, Notes or a word processor.
- **CSV and TSV as a spreadsheet:** the preview (⌥⌘P) of a `.csv`, `.tsv`
  or `.psv` file is a read-only grid: the first line is the header, row
  numbers stay at the left, columns resize, and a click on a header sorts
  the grid (never the text). Clicking a cell puts the caret in that field.
  Quoted fields with commas, quotes and line breaks are read as RFC 4180
  says; the separator (comma, tab, semicolon or pipe) is detected from
  the first lines (quotes, blank lines and decimal commas such as
  `1,5;2,3` taken into account), `.tsv` means tab, and an Excel `sep=;`
  first line is honoured. Spaces after the separator (`name, age, city`,
  `x, "a, b"`) are padding, not data, as Python's `skipinitialspace`
  reads them; spaces inside quotes and in TSV are kept. Pipe tables
  (`| a | b |`, with a `|---|` rule) show without their empty edge columns. It updates as you type, parses
  off the main thread, and shows the first 50,000 rows of a longer file
  (with a note). A quote that never closes doesn't swallow the rest of
  the file: the grid ends that field at its line and an orange note says
  "Unclosed quote on line N" (the text is untouched). It detaches like
  the other previews.
- **Themes:** System (light or dark with macOS), Light, Dark, Tankard (deep
  purple and amber) and Dracula, the same set as Tankard. Every theme's text
  colours meet WCAG AA contrast (4.5:1), checked by a test. SF Mono by
  default, or any installed fixed-pitch font; ⌘+ / ⌘− / ⌘0 zoom.
- **Settings** (Cedric Pad › Settings…, ⌘,): theme, font and size, wrap,
  invisibles, line numbers, highlight occurrences, auto-close brackets,
  spelling while typing, the default indentation, and whether closing the
  last window quits, in one window (the
  menu toggles still work and the window follows them).
- **Mac file basics:** Save All (⌥⌘S), Revert to Saved (undoable with ⌘Z),
  Close Window (⇧⌘W: every tab in the window, each hot-closed; on the last window, then quits, ⇧⌘T has the tabs), and the
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
  it types a tab character, as before. **YAML always indents with
  spaces** (2, or the file's own width; the YAML spec forbids tabs), and
  **Python with 4 spaces** unless the file uses tabs or tabs are the
  default saved in Settings.
- **Bookmarks** (Edit › Bookmarks, as in Notepad++): Toggle Bookmark (⌘F2,
  or click a line number), Next / Previous Bookmark (F2 / ⇧F2, wrapping),
  Bookmark All Matches (⌥⌘F2: every line matching the find bar's search,
  or the selection or word under the caret), Clear Bookmarks (⇧⌘F2).
  Bookmarks stay on their lines as you edit (Replace All, Toggle Comment
  and Text Tools included: a line whose text survives keeps its
  bookmark), move with Move Line (and back with Undo), and are kept with
  the session. Copy Bookmarked Lines and Delete Bookmarked Lines
  act on them all.
- **Filter lines** (Edit › Line › Keep Lines Matching… / Delete Lines
  Matching…): plain text or a regular expression, with or without case,
  as one undo step; bookmarks on the lines that stay follow them.
- **Auto-indent and pairing:** Return keeps the line's indent, one step
  more after `{` `[` `(` (and `:` in Python and YAML); Return between a
  pair puts the closer on its own line. In Python, Return after
  `return`, `pass`, `break`, `continue` or `raise` steps one level out,
  and typing the `:` of `else`, `elif`, `except` or `finally` lines the
  clause up with its `if`, `try`, `for` or `while`. In YAML, Return
  continues a `- ` item (an empty one ends the list), and after
  `- key: value` lines up under the key. In code, brackets and quotes close
  themselves (no `'` in Swift or JSON), typing the closer steps over it
  (a quote only over one that pairing typed), Backspace between a pair
  deletes both, and typing one with a selection wraps it (Edit ›
  Auto-Close Brackets and Quotes; never in plain text or Markdown). The
  bracket next to the caret and its partner are boxed.
- **Word, line and character counts** in the status bar, of the
  selection when there is one (characters are Unicode scalars). Documents
  over a million characters show lines only, so typing never waits on a
  count; over 50,000 they are counted when typing pauses, in the background.
- **Fix Typos…** (Edit › Spelling and Grammar, ⌥⌘;, or **Fix Typos…** in
  the owl's "Fix 3 typos?"): steps through the misspelled words one at a
  time, from the caret to the end and round from the top, in a small panel
  beside each word with the checker's suggestions (the first picked),
  **Change**, **Change All**, **Skip**, **Ignore All** (this document),
  **Learn Word** and **Done**, and "3 of 12". Return changes, Tab or ⌘→
  skips, Esc is done. Each change is one undo step (Change All too). Only
  the words spell check would mark: prose in Plain Text and Markdown,
  comments and strings in code, never URLs or paths. Big files are
  checked a chunk at a time, in large mode only as far as the next word.
- **Grammar in prose** (Settings › "Check grammar in prose", on by
  default; also Edit › Spelling and Grammar): macOS's own grammar checker
  (local, nothing sent anywhere) looks at documents written for people,
  never at code, data or logs. A document counts when it is Plain Text or
  Markdown and the text in view reads as sentences (words, function words
  like "the" and "and", sentence punctuation, few symbols, few lines that
  look like code, config, a log or a CSV row; Markdown's code, front
  matter, tables, inline code and URLs are left out). A short bullet list
  such as a shopping list doesn't count; a list of whole sentences does.
  After typing pauses the text in view (at most 8 KB) is checked in the
  background, in the checker's language (yours, or detected if you have
  "Automatic by Language"); findings get a green dotted underline, and a
  right-click on one shows the checker's note and its suggestion (Change
  to, Ignore Grammar). With the owl on he offers one at a time, e.g.
  "Grammar: ‘a’ → ‘an’?", with **Fix it** (one undo step), **Fix
  Grammar…** (step through them in a small panel: Change, Skip, Done, "2
  of 5"), **Not in This File** and **Don't show again**; never while you
  type (he waits for his usual 3-second pause), and at most one grammar
  bubble every 10 minutes unless you click the owl and choose **Grammar
  Hint**. Never in large mode or in files over 1 MB. Meeting notes with
  "Date:" and "Status:" lines stay Plain Text instead of being taken for
  YAML. The checker
  catches only what macOS's catches ("a elephant", doubled words, some
  agreement errors); it misses many others, such as "Their going too the
  store".
  With Ask Cedric on and an AI engine ready, **Check Grammar with
  AI** (Edit › Spelling and Grammar, or the owl's popover) asks the model
  about the prose in view; what it finds (only exact words from the text,
  a few words at a time) gets the same underline, **Fix it** and **Fix
  Grammar…**. It runs on its own only where automatic AI checks are on
  (never on Intel Macs by default); the macOS checker stays on as well.
- **Print** (File › Print…, ⌘P; Page Setup…, ⇧⌘P): the text in the
  editor's font, dark on white (not the theme's colours), wrapped to the
  page, with the file name, date and page numbers; line numbers are an
  option in the print panel.
- **Go to line** (⌘L, `42` or `42:7`), line numbers, current-line highlight,
  show invisibles (⌥⌘I), wrap lines (⌥⌘Z).
- **Encodings and line endings:** UTF-8 (with or without BOM), UTF-16 LE/BE,
  Latin-1, Windows-1252 and Mac Roman, and LF/CRLF/CR, detected on open
  (a file that isn't UTF-8 is read as whichever 8-bit Western encoding
  makes sense of its accented letters and quotes) and shown in the status bar,
  with menus to convert (applied on save) or reopen with another encoding.
  Mixed line endings are shown as such and written as one kind on save.
  A file that looks binary (a NUL byte, or many control characters, in
  its first 8 KB; never UTF-16) opens with a bar, "This looks like a
  binary file", and nothing shown: **Open Anyway** shows it as text,
  read-only, with Save off so it can't be rewritten by accident; **Allow
  Editing** on the bar makes it an ordinary text tab.
- **PDFs open in a viewer tab** (read-only, PDFKit), from File › Open, a
  drop on a window or the Dock icon, `cedric file.pdf` (`file.pdf:3` for
  page 3), Open Recent or Finder's Open With (Cedric Pad is registered as an
  alternate PDF viewer; Preview stays the default). A PDF is recognised by
  its `%PDF-` header, so one without the extension opens too. Continuous
  scroll; ⌘+ / ⌘− zoom, ⌘0 actual size, ⌘9 fit to the window; View › Show
  Page Thumbnails (⌥⌘B); ⌘F finds in the PDF with the find bar (⌘G / ⇧⌘G,
  Match Case); select and ⌘C copies text; ⌘L is Go to Page; the status bar
  shows page N of M and the zoom. A **floating control capsule** at the
  bottom of the page (as in Preview) has previous / next page, an
  editable "page N of M" field (Return jumps), zoom out / in, actual size,
  fit width, fit page, thumbnails, find, rotate left / right (the view
  only; the file is never changed) and Open in Preview. It fades after
  about 2 seconds without a mouse move or scroll and comes back on the
  next one (no fade with Reduce Motion), and stays while the pointer is
  on it. ← / → and Page Up / Page Down turn the page. **File › Open as Text** puts the PDF's
  text in a new untitled tab to edit (extracted in the background). Saving
  and editing commands are off in a PDF tab, and Cedric Pad never writes to a
  PDF. A password-protected PDF asks for its password; a damaged one says
  so. PDF tabs come back with the session on their page and zoom (a PDF
  tab that isn't selected loads when you first click it); the owl stays
  out of them.
- **Git, lightly:** for a file in a git repository (linked work trees
  too) the status bar shows the branch, or the short commit when HEAD is
  detached, with a dot when the file has uncommitted changes; clicking it
  offers Copy Branch Name, Open Repository in Finder and Open on GitHub.
  The gutter marks lines changed since the last commit as you type: green
  for added, blue for modified, a small red triangle where lines were
  deleted (Settings: "Show git changes in the gutter", on by default).
  **File › Open on GitHub** and **Copy GitHub Link** link to the file
  with `#L10` or `#L10-L20` for the selection (the branch if it has an
  upstream, else the commit), for a github.com or GitHub Enterprise
  `origin`; **View › Compare with Last Commit** shows the last commit
  beside the current text. Cedric Pad runs the local git only, after the
  window is up, on a background queue; no network, no sign-in. Without
  the developer tools (or another git) it does nothing, rather than
  setting off the install prompt; very large documents are skipped.
  A repository can't make Cedric Pad run its programs: git is only
  asked read-only questions (`rev-parse`, `cat-file`, `ls-files`, never
  `status` or `diff`), with fsmonitor, hooks, pagers and diff drivers
  forced off, and a repository whose own config names a program to run
  (fsmonitor, filters, textconv, through `include`/`includeIf` too) gets
  no git at all: the status bar says "Git info off". With "Show git
  changes" off, git never runs.
- **Images open in a viewer tab** (read-only): PNG, JPEG, GIF, HEIC/HEIF,
  AVIF, WebP, TIFF, BMP, ICO, ICNS, JPEG 2000, PSD, TGA (whatever ImageIO
  decodes), from every route a PDF takes (Open, drops, the Dock,
  `cedric photo.jpg`, Open Recent, Reopen Closed Tab, the session).
  Recognised by their first bytes, so one without its extension opens
  too; SVG stays a text file with its preview. Fitted to the window (never
  enlarged); ⌘+ / ⌘− zoom, ⌘0 actual size, ⌘9 fit, pinch to zoom, scroll
  to pan; a checkerboard behind transparency; animated GIFs play (Pause /
  Play button, or Space). The status bar shows pixel size, file size,
  format, colour space and zoom. ⌘C copies the image; File › Open in
  Preview (the file's default app); Print fits it to the page. A big
  image is decoded downsampled (about 32 megapixels at most) off the main
  thread, so a 12000×12000 PNG doesn't hold up typing in other tabs.
  Cedric Pad is an alternate image viewer (Preview stays the default) and
  never writes to an image; image tabs come back with the session at
  their zoom and place.
- **Office and iWork documents open in a Quick Look tab** (read-only):
  .docx .doc .xlsx .xls .pptx .ppt .pages .numbers .key .rtfd, shown by
  Quick Look's own previewer. Told apart by their first bytes (a zip with
  `[Content_Types].xml`, an OLE2 file) as well as the name. **File › Open
  as Text** takes a Word document's text into a new untitled tab; for an
  .xlsx the same item is **Open Sheet as CSV** (the first sheet, read
  with Cedric Pad's own zip and XML code: strings, numbers, booleans and
  formulas' cached values; dates come out as their serial numbers). File ›
  Open in <default app>. Registered as an alternate viewer.
- **Certificates.** A PEM file (`.pem` `.crt` `.cer` `.csr`, or any text
  with a `-----BEGIN CERTIFICATE-----` block) opens in the editor with a
  compact **Certificate** panel beside it. The text stays whole and
  editable (⌘A ⌘C copies it exactly); the panel never replaces it, and
  View › Show Preview (⌥⌘P) closes it, which is remembered for the next
  certificate file until it is shown again. The panel lists each certificate in the file, in order, with an **Expired** /
  **Expires in N days** badge and its subject, issuer, validity, other
  names (SANs), whether it is a CA, key usage, what it is used for, public
  key, signature algorithm, serial number and SHA-256 / SHA-1
  fingerprints, in plain words, each with a **Copy** link, and **Copy
  Certificate (PEM)** per certificate, which copies exactly that
  certificate's BEGIN/END block from the text. It follows your edits. Private keys are
  never read or shown ("Private key — not shown"; the owl's secret
  warning still applies); a certificate request shows its subject; a
  PKCS#7 bundle (`.p7b`, PEM or DER) lists its certificates. A binary
  (DER) `.cer` `.crt` `.der` `.p7b` opens in a read-only certificate tab
  with the same details; its main action is **Copy as PEM** (BEGIN/END
  lines, 64 columns), and **Open as PEM Text** opens the PEM in a new
  untitled tab. With the owl on, he
  warns when a certificate in view has expired or expires within 30
  days. Read with macOS's Security framework; nothing is sent anywhere.
- **Drop a file on the text to open it** (in its own tab), rather than
  pasting its path; dropped text is inserted as before. (On a Markdown
  tab a dropped image is linked instead; see Markdown editing.)
- **Files changed on disk** reload by themselves when the tab has no unsaved
  changes. With unsaved changes, a bar says so (**Reload** / **Keep Mine**),
  owl or no owl. **⌘S never overwrites another app's changes:** if the file
  changed since Cedric Pad read or saved it, a sheet asks first (**Keep My
  Version**, **Reload Theirs** (undoable) or **Compare**).
- **Help menu**: **Cedric Pad Help** (⌘?, this README), **Keyboard
  Shortcuts** (every menu shortcut in one window) and the system's menu
  search.
- **`cedric` command-line launcher** (below), with `-w` so it can be
  git's editor, and `file:line:col`.
- **Cedric the owl** (View › Show Cedric the Owl, off by default): a small
  assistant in the corner that offers one hint at a time, with **Fix it**
  where a safe fix exists, **Show Me** where it points at something, **Not
  now** and **Don't show again**. He blinks and glances now and then,
  looks toward the caret when you stop typing (never moves while you
  type), waves once per launch, points at the lines a hint is about, nods
  when a fix is applied, thinks / searches / writes while the AI works,
  and falls asleep after 5 minutes without typing (a click wakes him).
  With Reduce Motion on (System Settings › Accessibility) he stays still:
  no gestures, a single still frame for each state. His rules need no AI and only ever look
  at the text in view (at most 8 KB):
  - warnings: merge-conflict markers left in the file; something that looks
    like a secret (a private key, an AWS key, a GitHub, Slack, Stripe or
    OpenAI/Anthropic token); JSON that doesn't parse (with the line; a
    trailing comma is named where it is: "Extra comma at the end of line
    5");
    an unmatched or unclosed bracket in Swift, JavaScript, TypeScript, C,
    CSS or Python (strings, comments and regexes skipped; "never closed"
    only in a saved file, and not in C with `#if`/`#else`); a file changed on disk under your edits;
  - fixes: format one-line JSON; curly quotes pasted into code; tabs
    indenting YAML; tabs and spaces mixed (to whichever the file mostly
    uses; a Makefile keeps its tabs); zero-width and stray byte-order-mark
    characters; trailing spaces (never in a diff or patch, CSV, INI/.env
    or a log, where the spaces are data, nor in a certificate, key or other
    PEM text, nor inside a PowerShell here-string; in Markdown, two before another
    line of the paragraph are a line break and stay); "It looks like
    you're writing a to-do list" → Markdown checkboxes (one ⌘Z undoes the
    colouring too); a word typed twice ("the the", "the the the", also
    "por la la tarde"; **Show Me** selects it); two spaces
    after some full stops but not others; no newline at the end of a saved
    code file. Formatting JSON always does the whole file (checked
    first: if the whole file isn't valid JSON, nothing changes); in a
    file longer than his 8 KB view, the other fixes change only the part
    around what's on screen, and say so;
  - offers and notes: plain text that is really Markdown, HTML or JSON
    (colour it that way); unsaved for two hours (save a copy); CRLF or
    mixed line endings; and, once ever, a letter (a greeting and a
    sign-off or address lines, not "Dear diary");
  - typos: in prose only (writing that reads as sentences, never logs,
    config or `key=value` lines), "Fix 3 typos?" with **Fix Typos…** and
    **Fix All**, on his usual schedule: after a 3-second typing pause,
    when the rules have nothing, at most once every 10 minutes, and once
    after a prose file opens.

  The bubble keeps off the lines it is about when the window has room.

  Optional AI hints (View › Cedric AI Settings…, off by default) use a
  local model only. On Intel Macs automatic AI checks are **off** by
  default so typing stays fast: click the owl and choose **Ask AI Now**,
  or turn on "Check automatically when I pause typing" in the settings.
  A one-word AI fix in prose ("definately" → "definitely") keeps its
  **Fix it**.
  In very large documents the owl only looks when clicked.
  A network endpoint must resolve to a private address (loopback, LAN,
  Tailscale); redirects to another host are refused.
- **Ask Cedric** (Settings › "Ask Cedric"; on by default when a local
  engine is ready: Apple Intelligence, a downloaded built-in model, or an
  LM Studio / Ollama / other-Mac server you set up and turned on; with
  none, clicking the owl offers **Set Up Ask Cedric…**). Click the owl:
  **Ask about this file…** is the first item; Edit › Ask Cedric… (⌥⌘/)
  does the same, and the owl says so once, a while after a new user's
  first launch. A small panel about the current document opens. A chip
  picks what Cedric sees (Selection, Visible text, or the Whole document
  when it fits the model); quick actions **Explain** (**What Does It
  Do?** for scripts), **Explain Line** (the selection or the caret's
  line), **Find Problems**, **Summarise** / **Rewrite** (prose),
  **Simplify** and **Add Comments** (code), or type a question. Answers
  stream in (built-in, Apple Intelligence, or LM Studio / Ollama on this
  Mac or the local network, never the cloud; a slow model gets 2 minutes
  for its first word, then 30 s between words, up to 15 minutes in all);
  **Stop** cancels. An edit is never
  made by the model: it comes back as a diff with **Apply** / **Discard**,
  applied as one undo step only if the document hasn't changed since you
  asked (otherwise **Ask Again**). History is per document, in memory
  only, with **Copy as Markdown** and **Clear**.
  Cedric can also use six read-only tools on a frozen copy of the
  document (get the selection or lines, search, outline, counts, and
  propose an edit), at most three rounds per question, but only with
  models that score at least 80% on a fixed 40-prompt set
  (`Scripts/owl-tools-eval.sh`, scores in
  `Resources/AI/owl-tool-scores.json`). Other models get the quick
  actions without tools. Measured 2026-11-18: the built-in Qwen3 4B
  Instruct 90%, so it gets tools; Apple Intelligence 72.5%, Qwen2.5-Coder
  1.5B on LM Studio 75% and the built-in Qwen2.5-Coder 3B 65% stay
  without.
- **Check Script for Risks…** (Edit menu, the owl, or **Check for
  Risks** in Ask Cedric) for shell, PowerShell, batch, `.reg`, Python and
  Ruby: an offline scan, no AI and nothing sent anywhere (so it works on
  any Mac, Intel included), lists the lines worth reading first:
  downloading and running code (`curl … | sh`, `| /bin/bash`, through
  `tee`, `iex (iwr …)`, Python `exec` / Ruby `eval` of fetched code),
  `Invoke-Expression` / `eval` and AppleScript `do shell script`, encoded
  commands (`-EncodedCommand`, Base64 piped to a shell or `exec`'d,
  `&(gcm i*x)`), reverse shells (`/dev/tcp`, `nc -e`), setuid
  (`chmod u+s`), registry and system changes, `sudo` and `-Verb RunAs`,
  reading passwords or keys, turning off Defender / Gatekeeper / the
  firewall / the execution policy / quarantine / TCC, running at login
  (launch agents, cron, Run keys, scheduled tasks, `authorized_keys`),
  and recursive deletes of broad paths (`rm -rf ~/*`, `rm -rf "$DIR/"*`,
  `find / … -delete`, `Remove-Item -Recurse C:\`). Only the first 20,000
  lines are scanned, and a longer script says so. With Ask Cedric on, the
  model then reviews the script with those findings (passed as data, and
  told the script's text is never instructions) and ends with a verdict:
  "No obvious red flags (not a guarantee)", "Run only if you trust the
  source" or "Don't run it". Cedric never calls a script safe: the app
  rewrites any such line, and forces "Don't run it — review the flagged
  lines" after a high-risk finding or when only part of the script was
  reviewed, whatever the model said.
- **Careful with files:** pipes and devices (`/dev/zero`, a FIFO) are
  refused before anything is read; saving through a symbolic link writes
  the file it points to and keeps that file's permissions; Export as HTML
  and Copy as HTML drop `<script>` and `on…=` handlers; Copy as Rich Text
  loads nothing from the network; pasted images never go to an `images`
  folder that points outside the document's folder.

## Build and run

Needs the Command Line Tools or Xcode 26 (Swift 6.3 or later, macOS 26 SDK); Xcode itself is not required. Swift 6.1 / 6.2 with an older SDK still compiles and passes the unit tests, but the app it builds draws no editor text, so never ship or test the app from an older toolchain. Releases are built on GitHub's macos-26 runner.

```sh
Scripts/bundle-app.sh               # "dist/Cedric Pad.app" for this Mac, ad-hoc signed
Scripts/bundle-app.sh --universal   # arm64 + x86_64
open "dist/Cedric Pad.app"
```

Tests (Swift Testing; the script adds the paths the Command Line Tools need):

```sh
Scripts/test.sh                     # unit tests: tokenizers, Markdown, codecs, find, session store, themes
Scripts/session-check.sh            # end to end: unsaved tabs survive a kill -9, a normal quit and a last-window close
Scripts/typing-check.sh             # real key events in every theme; typed glyphs' pixels must be visible
Scripts/launch-check.sh             # real launches: stays up, quits cleanly, no crash report
Scripts/pdf-check.sh                # PDF tabs in the running app: find, copy, zoom, Open as Text, session
Scripts/image-check.sh              # image and Office tabs: zoom, copy, GIFs, docx/xlsx text, session, a 12000² PNG vs typing
Scripts/launch-speed-check.sh       # launch phase medians: empty, 8-tab session, 500 KB file
swift Scripts/launch-time.swift "dist/Cedric Pad.app" /System/Applications/TextEdit.app
```

A local build is ad-hoc signed, not notarized. If macOS refuses to open a
copied build, remove the quarantine flag: `xattr -dr com.apple.quarantine "Cedric Pad.app"`.

## The `cedric` command

`Cedric Pad.app/Contents/Resources/cedric` opens files in the running app (or
starts it). The command keeps the name `cedric`. Link it onto your PATH:

```sh
ln -s "/Applications/Cedric Pad.app/Contents/Resources/cedric" /usr/local/bin/cedric
cedric notes.md                 # open (a missing file opens as a new tab that saves there)
cedric src/main.c:120           # open at line 120 (also: cedric +120 src/main.c)
cedric src/main.c:120:7         # line 120, column 7 (grep -n / compiler output works too)
git log | cedric -              # stdin into a new untitled tab
git config --global core.editor "cedric -w"   # -w / --wait: return when the tab closes
```

It talks to the app through a `cedric://open?path=…&line=…&col=…` URL. Any
app or web page can send such a URL, so each one the script sends carries a
secret token (`~/Library/Application Support/Cedric/cli-token`, readable only
by you; the `Cedric` folder itself is owner-only, 0700, and the script writes
a new token to a temp file and links it into place, so it is never read
half-written). A link without it can't hand over stdin or `-w` files, and opening a
file from it asks first. The app deletes only the script's own temp files
(`cedric-stdin.*`, `cedric-wait.*` in your temp folder), checked after `..`
and symlinks are resolved.
With `-w` the script makes a `cedric-wait.*` marker file in the temp
folder and passes it along; Cedric Pad deletes it when that file's tab closes
(or when Cedric Pad quits), and the script returns.

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

Cedric Pad is built with Claude: Claude Code agents under Derek's direction, with
review and tests before release.

## License

BSD-2-Clause. See [LICENSE](LICENSE). The Dracula theme's colours are by
[Dracula Theme](https://draculatheme.com), used under the MIT license.

The built-in AI engine uses [llama.cpp](https://github.com/ggml-org/llama.cpp)
(MIT, © the ggml authors), bundled as `llama.framework`. Models are not
bundled: the ones Cedric Pad offers to download are Qwen models by Alibaba
Cloud, each under its own licence, shown before download. The default,
Qwen3 4B Instruct (2507, the Q4_K_M GGUF quantised by Unsloth), is
Apache-2.0, as are Qwen2.5-Coder 1.5B and 7B and Qwen3 4B. Qwen2.5-Coder
3B, the default before, stays an optional download labelled
"Non-commercial licence" (Qwen Research License).
