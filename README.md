# XPaste

English | [简体中文](README.zh-CN.md)

A clipboard history manager for macOS, written from scratch in Swift as a personal study project.

XPaste remembers what you copy — text, rich text, images, links, colors and files — and puts it in a panel along the bottom of the screen, ready to search, preview, edit and paste back.

## Why

XPaste is a learning project. I use [**Paste**](https://pasteapp.io/) every day and love it, and I wanted to understand how an app like it is put together: clipboard capture, a fast searchable history, a polished AppKit panel, sequential pasting, privacy controls, a local MCP server.

So XPaste follows Paste's ideas and workflow closely, but it is an independent reimplementation. It contains no code, artwork, sounds or text from Paste, and it is not affiliated with or endorsed by Paste's developers.

**If you are looking for a clipboard manager to actually use, please buy Paste and support its developers.** It is better, it syncs across your Mac, iPhone and iPad, and it is actively maintained. XPaste is here for people who want to read the code and learn from it.

## What it does

- **Clipboard history** — every copy is saved locally: plain and rich text, images, links (with page titles and images), colors and files. Content marked as concealed or transient by password managers is skipped, and you can ignore whole apps.
- **Panel at the bottom of the screen** — press **⇧⌘V** to open it. Cards show the content, the source app and when it was copied. Paste with Return or a double-click, as plain text with ⇧Return, or press ⌘1–⌘9 for the first nine items.
- **Search and filters** — search the text, titles and the text recognized in images (on-device OCR), and filter by type, source app or pinboard.
- **Pinboards** — keep things you use often in named, colored pinboards that never expire.
- **Preview and edit** — press Space to preview text, images, web pages and files; edit text, links, colors and images (rotate, remove background).
- **Multi-select** — paste or drag several items at once; text is joined line by line.
- **Paste Stack** — press **⇧⌘C**, copy what you need, then paste it back in order with ⌘V, one item per press. Start a stack from items selected in the panel, drag rows to reorder, double-click a row to paste it out of turn, paste all text at once with ⌃⌥⌘V, and undo removals.
- **MCP server for AI tools** — optional and off by default. When enabled it listens on `127.0.0.1` only, and every new client has to be approved inside XPaste. Claude Code, Codex, Cursor and other MCP clients can search your history, read items, manage pinboards and add items to Paste Stack.
- **Everything else** — adjustable and lockable panel height, retention period, pause, sound effects, hiding windows during screen sharing (where respected), launch at login, onboarding, English and Simplified Chinese.

## Requirements

- macOS 27 or later
- Apple Silicon (arm64 only; no Intel or Universal builds)

## Install

There is no release yet. When there is, it will be on the [Releases](https://github.com/davie-01/Xpaste/releases) page as a zip with a SHA-256 checksum.

The build is ad-hoc signed and not notarized, so macOS quarantines it after download. After unzipping and moving XPaste to `/Applications`:

```sh
shasum -a 256 -c XPaste-<version>-arm64.zip.sha256   # check the download
xattr -dr com.apple.quarantine /Applications/XPaste.app
open /Applications/XPaste.app
```

## Build from source

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/davie-01/Xpaste.git
cd Xpaste
brew install xcodegen

# Package a release build (ad-hoc signed) into dist/
Tools/package.sh
```

For day-to-day development:

```sh
xcodegen generate
xcodebuild -project XPaste.xcodeproj -scheme XPaste -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/XPaste.app
```

`project.yml` signs with the author's team (`DEVELOPMENT_TEAM`). Replace it with your own team ID, or build with `Tools/package.sh`, which signs ad-hoc. The Debug build uses ⌃⇧⌘V and ⌃⇧⌘C so it can run next to a release build, and keeps its data separately.

Tests and checks:

```sh
swift test --package-path Packages/XPasteKit   # unit tests
Tools/check-strings.sh                         # every UI string has an English translation
Tools/check-compliance.sh                      # no resources, identifiers or text copied from Paste
XPASTE_SELFTEST=1 build/DerivedData/Build/Products/Debug/XPaste.app/Contents/MacOS/XPaste   # in-app self-test
```

## Permissions and privacy

- **Device control and data access** (called Accessibility on older macOS) is needed to paste directly into the app you are using and for Paste Stack. Without it, XPaste copies to the clipboard and you press ⌘V yourself. The grant is tied to the code signature, so every new ad-hoc build has to be allowed again.
- **Files and folders**: macOS asks the first time you paste a file copied from Desktop, Documents, Downloads, a removable disk or a network volume.
- **Network**: only used to fetch link titles and preview images, and to show web page previews. Both can be turned off in Settings › Privacy. Local and private network addresses are never loaded.
- **Data** stays on your Mac, in `~/Library/Application Support/XPaste`. There is no sync, account, analytics or telemetry.
- **Screen sharing**: the "show during screen sharing" switch marks XPaste's windows as not shareable. Many current recording and sharing tools ignore this marker, so it is not protection against screenshots or recording.

## Known limitations

- **Pasting a Stack too fast**: each ⌘V writes the next item to the clipboard. If the target app reads the clipboard slowly and you press faster than that, two presses can paste the same item. Slow down if you see this.
- **Source app**: when the copying app does not declare itself, the source is the app that was frontmost at the time, so content written by background tools is attributed to the frontmost app.
- **Deleted items written again**: if an app keeps rewriting the clipboard after you delete its item, it comes back as a new copy.
- The development notes and research behind this project (measurements and comparisons with Paste) are kept out of this repository, so some code comments refer to documents that are not here.

## Status

A personal study project, built and tested on my own Mac. Issues and pull requests are welcome, but there are no promises about features or response times.

## License

MIT. See [LICENSE](LICENSE). Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

- Inspired by [**Paste**](https://pasteapp.io/) — please support the original.
- [GRDB.swift](https://github.com/groue/GRDB.swift) for SQLite.
- Built with AppKit and SwiftUI on Apple's frameworks: Vision for text recognition and background removal, WebKit for web previews and Network for the MCP server.
