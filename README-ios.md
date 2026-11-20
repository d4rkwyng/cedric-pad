# Owlink for iPhone and iPad

The iOS app lives in `ios/` and builds on the same `CedricCore` and
`CedricAI` packages as the Mac app; only the UI is separate.

| | |
|---|---|
| Project | `ios/Owlink.xcodeproj`, scheme **Owlink** |
| Bundle ID | `net.mindtricks.owlink.ios` |
| Version | 0.3.0 (1), set in `ios/Scripts/gen-xcodeproj.py` |
| Devices | iPhone and iPad (universal), iOS 17 or later |
| Signing | Automatic, team `V868MD2SHX` |

The project file is generated: edit `ios/Scripts/gen-xcodeproj.py` and run
`python3 ios/Scripts/gen-xcodeproj.py`, rather than changing build settings
in Xcode (a change made in Xcode is lost the next time the script runs).
Source files can be added in Xcode or Finder: `ios/Owlink`,
`ios/OwlinkUITests` and `Tests/*` are synchronized folders.

## What it does

- Opens and saves files from the Files app, iCloud Drive and other file
  providers (a document browser in each window). The encoding and line
  ending are detected and written back unchanged (the core's `TextCodec`).
- Syntax colouring (the core's highlighter), the seven themes including
  Dracula, font size, wrap.
- Find and replace (`⌘F`, `⌥⌘F`, or the magnifier and the ⋯ menu).
- Markdown preview (`⇧⌘P`), side by side on iPad.
- Cedric's offline hints with **Fix it**; Ask Cedric (`⇧⌘K`) and Check
  with Cedric (`⌥⌘H`).
- iPad: menu bar and keyboard shortcuts, several windows, Stage Manager.

Not on iOS: the `cedric` command, Replace in Files, the folder sidebar, Git,
the certificate view, XML formatting.

## Cedric AI on iOS

Off by default, as on the Mac. The offline hints never use the network.

- **Apple Intelligence** (iOS 26 or later on a device that supports it,
  with Apple Intelligence turned on). Settings › Cedric AI shows whether it
  is available, or why not (device not eligible, turned off, model not
  ready). On-device only; Private Cloud Compute is never used.
- **Built-in model** (llama.cpp): **real devices only**. The pinned
  XCFramework has an iOS device slice but no simulator slice, so simulator
  builds leave it out and Settings says "Built-in model: needs a real
  device". iPhones (and iPads without an M chip) are offered the small
  models (up to 2B parameters, about 1.1 GB); M-series iPads also the 3–4B
  ones. Downloads come from huggingface.co only when asked, show the licence
  first, are checked against their SHA-256, and are kept out of iCloud
  backups. Before loading, the app checks `os_proc_available_memory()` and
  refuses with a message rather than being killed for using too much memory.
- **A server on your network** (LM Studio, Ollama, another Mac): local
  addresses only.

Device builds run `ios/Scripts/fetch-llama.sh` first, which takes the iOS
slice from SwiftPM's download cache or downloads the same pinned zip from
GitHub, and checks it against the SHA-256 in `Package.swift`.

## Option A: archive and upload from Xcode (recommended now)

On a Mac signed in to the Apple developer account for team V868MD2SHX:

1. `git checkout feat/ios-app` (once merged: `main`), then open
   `ios/Owlink.xcodeproj` in Xcode 26 or later.
2. Xcode › Settings › Accounts: make sure the account is signed in.
3. Select the **Owlink** target › Signing & Capabilities: Team
   V868MD2SHX, "Automatically manage signing" on. Xcode registers the
   bundle ID `net.mindtricks.owlink.ios` and the Increased Memory Limit
   capability on first use.
4. In App Store Connect (https://appstoreconnect.apple.com) › Apps › **+**
   › New App: platform iOS, name "Owlink" (or "Owlink Editor" if the name
   is taken), bundle ID `net.mindtricks.owlink.ios`, SKU e.g. `owlink-ios`.
5. In Xcode, choose the destination **Any iOS Device (arm64)**, then
   Product › **Archive**. The first device build downloads the llama.cpp
   zip (about 65 MB) unless SwiftPM already has it cached.
6. In the Organizer: **Distribute App** › **App Store Connect** ›
   Distribute. Xcode signs the app and the embedded `llama.framework`.
7. App Store Connect › the app › **TestFlight**: once the build has
   finished processing, answer the export-compliance question (the Info.plist
   already says no non-exempt encryption), add yourself as an internal
   tester, and install it with the TestFlight app.

Before an App Store release (not needed for internal TestFlight): a privacy
policy URL, the App Privacy answers ("Data Not Collected" matches
`PrivacyInfo.xcprivacy`), screenshots and a description.

## Option B: build in CI (GitHub Actions)

Not set up. What it would need:

- **Secrets** (created by Derek in App Store Connect › Users and Access ›
  Integrations › App Store Connect API, role App Manager):
  `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the .p8 file's contents).
  With an API key, `xcodebuild -allowProvisioningUpdates` can create the
  signing certificate and profiles itself (cloud-managed signing), so no
  certificate has to be exported into a secret.
- **A macOS runner** with Xcode 26 or later (`macos-26` or a self-hosted
  Mac).
- **Workflow outline** (`.github/workflows/ios-testflight.yml`, run by
  hand or on a tag):

```yaml
on: workflow_dispatch
jobs:
  testflight:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: API key
        run: |
          mkdir -p ~/.appstoreconnect/private_keys
          echo "$ASC_KEY_P8" > ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
        env: { ASC_KEY_P8: "${{ secrets.ASC_KEY_P8 }}", ASC_KEY_ID: "${{ secrets.ASC_KEY_ID }}" }
      - name: Archive
        run: |
          xcodebuild -project ios/Owlink.xcodeproj -scheme Owlink \
            -destination 'generic/platform=iOS' -archivePath build/Owlink.xcarchive \
            CURRENT_PROJECT_VERSION=${{ github.run_number }} \
            -allowProvisioningUpdates \
            -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_${{ secrets.ASC_KEY_ID }}.p8 \
            -authenticationKeyID ${{ secrets.ASC_KEY_ID }} \
            -authenticationKeyIssuerID ${{ secrets.ASC_ISSUER_ID }} \
            archive
      - name: Upload to TestFlight
        run: |
          cat > ExportOptions.plist <<'EOF'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>method</key><string>app-store-connect</string>
            <key>destination</key><string>upload</string>
            <key>teamID</key><string>V868MD2SHX</string>
          </dict></plist>
          EOF
          xcodebuild -exportArchive -archivePath build/Owlink.xcarchive \
            -exportOptionsPlist ExportOptions.plist -exportPath build/export \
            -allowProvisioningUpdates \
            -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_${{ secrets.ASC_KEY_ID }}.p8 \
            -authenticationKeyID ${{ secrets.ASC_KEY_ID }} \
            -authenticationKeyIssuerID ${{ secrets.ASC_ISSUER_ID }}
```

The build number must go up with every upload (`CURRENT_PROJECT_VERSION`
above). A runner without SwiftPM's cache downloads the llama zip on every
run; caching `~/Library/Caches/org.swift.swiftpm` avoids that.

## Building and testing on this Mac

`xcode-select` may point at the Command Line Tools; use full Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ios
xcodebuild -project Owlink.xcodeproj -scheme Owlink -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Owlink.xcodeproj -scheme Owlink -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -project Owlink.xcodeproj -scheme Owlink -destination 'generic/platform=iOS' \
  -archivePath /tmp/Owlink.xcarchive CODE_SIGNING_ALLOWED=NO archive   # proves the device build compiles and links llama
```

Test targets:

- `OwlinkCoreTests` and `OwlinkAITests` run the package's own
  `Tests/CedricCoreTests` and `Tests/CedricAITests` on the simulator
  (557 + 167 pass; the Mac-only files are listed in `gen-xcodeproj.py`).
- `OwlinkUITests` (XCUITest) drives the app: open, edit, save and reopen;
  the owl's fix; the Markdown preview; find. It opens bundled samples with
  the launch argument `-OwlinkOpen <name>`, skipping the document browser.
- `OwlinkSnapshotTests` compiles the app's sources into a test bundle and
  drives the editor in a window, rendering PNGs.

Run the last two on a device or a simulator that can draw. On the fleet
Mac (geonosis) the iOS 27.2 simulator boots but never draws its home
screen (SpringBoard stays on the Apple logo; Metal in the simulator), so
apps can't launch there and any UIKit window hangs, in tests too. Run only
the first two there (`-only-testing:OwlinkCoreTests -only-testing:OwlinkAITests`).

### The self-check (debug builds)

`-OwlinkSelfCheck <dir>` runs the editor through a script inside the app
(open a sample, the owl's hint and Fix it, type, save and read the file
back, the language menu, find, the Markdown preview, Ask Cedric with
whatever engine is ready, the themes) and writes PNGs and
`selfcheck.txt` (PASS/FAIL lines) to `<dir>`, then quits. Where the
simulator can't draw, run it as a Mac Catalyst build, which uses the same
UIKit code (a local-only project variant; never commit it):

```sh
OWLINK_CATALYST=1 python3 ios/Scripts/gen-xcodeproj.py
xcodebuild -project ios/Owlink.xcodeproj -scheme Owlink -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .dd build
.dd/Build/Products/Debug-maccatalyst/Owlink.app/Contents/MacOS/Owlink -OwlinkSelfCheck /tmp/owlink-shots
python3 ios/Scripts/gen-xcodeproj.py   # back to the committed project
```

**Warning:** launching a Catalyst build registers it with LaunchServices,
and it can become the Mac's default app for a file type (it took `.csv`
on geonosis once). Run it in a test VM, not on a Mac people use; if it ran
on one, unregister it afterwards with
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path>/Owlink.app`
and delete the build.

Catalyst draws the iOS layouts in a Mac window (sizes forced to an
iPhone and an iPad in landscape); the bars look slightly more Mac-like
than on a device.

## What only a real device can show

- The built-in model actually loading and answering (Metal on iOS, memory).
- Apple Intelligence answering (the simulator reports what the host Mac
  allows; a device with Apple Intelligence on is the real test).
- iCloud Drive syncing and conflicts, and other file providers.
- Typing feel with the software keyboard and with a hardware keyboard.
