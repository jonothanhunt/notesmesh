<p align="center">
  <img src="assets/icon.png" alt="NoteMesh icon" width="128">
</p>

<h1 align="center">NoteMesh</h1>

<p align="center">
  <img alt="macOS 26" src="https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI_%2B_Metal-F05138?style=flat-square&logo=swift&logoColor=white" />
  <img alt="On-device" src="https://img.shields.io/badge/Privacy-on--device-5b8def?style=flat-square" />
  <a href="./LICENSE"><img alt="License MIT" src="https://img.shields.io/badge/License-MIT-green?style=flat-square" /></a>
</p>

<p align="center">
  <strong>Your Apple Notes as a living map.</strong><br/>
  NoteMesh reads your Notes library on your Mac and draws it as a graph: islands of related notes, the people and organisations you keep notes about, and the topics that tie them together. Native SwiftUI and Metal, with Liquid Glass controls. Nothing leaves your Mac.
</p>

<p align="center">
  <img src="assets/hero.webp" alt="NoteMesh in dark mode: notes in coloured islands, with people and organisations in the drawer" width="100%">
</p>

<div align="center" style="line-height: 0;">
  <img src="assets/overview-light.webp" alt="The whole library in light mode" width="49.5%" style="margin-right: 1%; margin-bottom: 1%;" /><img src="assets/islands-connections.webp" alt="Zoomed out, each island is named with a glass pill; the Connections panel is open" width="49.5%" style="margin-bottom: 1%;" /><br>
  <img src="assets/highlight-hover.webp" alt="The Highlight panel and a note's hover card" width="49.5%" style="margin-right: 1%; margin-bottom: 1%;" /><img src="assets/note-page.webp" alt="A note's page, with its links, topics and similar notes" width="49.5%" style="margin-bottom: 1%;" /><br>
  <img src="assets/island-page.webp" alt="An island's page in dark mode, with the island on its own in the graph" width="49.5%" style="margin-right: 1%;" /><img src="assets/search.webp" alt="Searching notes, people and topics" width="49.5%" />
</div>

<p align="center"><sub>Screenshots show the built-in sample library, not real notes.</sub></p>

## Table of Contents
1. [Features](#features)
2. [Privacy](#privacy)
3. [Guide](#guide)
4. [Using NoteMesh](#using-notemesh)
5. [Project Structure](#project-structure)
6. [Contributing](#contributing)
7. [License](#license)

## Features
- **Islands:** related notes gather into islands (Louvain communities in a Barnes–Hut force layout), each with its own colour across the graph, its card and its page. Zoom out and every island is named with a Liquid Glass pill.
- **People and organisations:** a note titled with just a name ("Sam Taylor", "Acme") is a profile. Every note that mentions that name links to it, and same-titled profiles merge into one node. Tag a note `#person` or `#organisation` to say so yourself.
- **Your note links:** the `>>` links you make between notes in Apple Notes (like Obsidian's `[[links]]`) are drawn as solid lines.
- **Topics:** from Apple Intelligence on Macs that have it, reading notes privately on-device, or from keywords your notes share. Switch between them any time.
- **Similar notes:** word overlap blended with on-device sentence embeddings links notes that talk about the same things.
- **A drawer like Maps:** search (⌘F), islands, people, organisations and topics, and a page for anything you select. Double-click a note (or ⌘↩) to open it in Notes.
- **Fast:** the graph is drawn with Metal as instanced quads. On an M4 Pro it holds 116 fps with an average frame build of 0.32 ms at about 900 nodes and 1,700 edges.
- **Light and dark:** follows your Mac, or pick one with the button under the slider.

## Privacy
NoteMesh is built to be safe to point at your most personal notes.

- **Nothing leaves your Mac.** There's no network code, no accounts, no analytics and no crash reporting.
- **Read-only.** NoteMesh copies the Notes database to a temporary folder, reads the copy and deletes it straight away. It never writes to the Notes library, and it skips locked notes.
- **What it keeps:** only what it works out (topics, profile types, similarity vectors, settings) in `~/Library/Application Support/NoteMesh/`. **File → Delete NoteMesh Data** removes it all.

The full policy is in [PRIVACY.md](PRIVACY.md).

> NoteMesh is an independent project and isn't affiliated with or endorsed by Apple. It reads the Notes app's private database format, which can change with any macOS update. Apple, Apple Notes and Apple Intelligence are trademarks of Apple Inc.

## Guide

### 1. Requirements
- macOS 26 or later.
- Xcode's Command Line Tools (`xcode-select --install`). No Xcode project needed.
- Apple Intelligence is optional. Without it, or where an organisation has turned it off, topics come from keywords.

### 2. Build and install
```bash
git clone https://github.com/jonothanhunt/notemesh.git
cd notemesh
scripts/build-app.sh install
open ~/Applications/NoteMesh.app
```

The script signs with your Apple Development certificate if you have one, so macOS keeps NoteMesh's access across rebuilds. Without one it signs ad hoc, and you may need to grant access again after each build.

### 3. Connect your notes
NoteMesh opens with a sample library so you can explore straight away. The card at the top of the drawer walks you through turning on **Full Disk Access** (System Settings → Privacy & Security), which is the only way macOS lets an app read the Notes library. You can drag NoteMesh straight into the list. As soon as access is on, your own notes replace the samples.

### 4. Releasing (maintainers)
```bash
xcrun notarytool store-credentials notemesh --apple-id YOU@EXAMPLE.COM --team-id TEAMID
NOTARY_PROFILE=notemesh scripts/build-app.sh release
```
This signs with Developer ID, uses the hardened runtime, notarizes, staples and writes `build/NoteMesh.zip` for a GitHub release.

## Using NoteMesh

| Do this | To |
| ------- | -- |
| Click a node | Focus it and open its page in the drawer |
| Double-click a note, or ⌘↩ | Open it in Notes |
| Zoom out, click a pill | Explore that island |
| ⌘F | Search |
| ⌘K | Quick open |
| Scroll or drag the drawer | Resize it (pill, half, full) |
| ⌘R / ⇧⌘R | Reload notes / rebuild the index |
| Top-right buttons | Apple Intelligence, Connections, Highlight, similar-notes slider, appearance |

Launch options for development: `--sample` shows only the sample library (never your notes), `--diagnostics` writes a diagnostics file, and `--bench` measures rendering speed.

## Project Structure

```text
notemesh/
├── Sources/NoteMesh/
│   ├── NotesStore.swift, NoteProto.swift        # read the Notes database (temporary copy) and note bodies
│   ├── Intelligence.swift                       # Apple Intelligence, keywords, embeddings, the index cache
│   ├── Category.swift, GraphBuilder.swift       # people/organisation profiles, building the graph
│   ├── Indexer.swift                            # loading, background reading, live reload, deleting data
│   ├── MetalGraphView.swift, GlyphAtlas.swift   # the Metal renderer, labels and island pills
│   ├── ForceSim.swift, Communities.swift, LayoutSetup.swift   # layout and islands
│   ├── Views.swift, Panel.swift, GraphView.swift, App.swift   # SwiftUI: controls, drawer, pages
│   └── DemoLibrary.swift                        # the sample library
├── Resources/      # app icon, entitlements, privacy manifest
├── Web/fonts/      # JetBrains Mono for graph labels (OFL)
├── scripts/        # build-app.sh, make-icon.swift
└── assets/         # README images
```

## Contributing

Feedback, ideas and PRs are welcome, whether that's a new way to link notes, a layout tweak or a typo. See [CONTRIBUTING.md](CONTRIBUTING.md), and please report security or privacy problems privately as described in [SECURITY.md](SECURITY.md).

## License

MIT © 2026 Jonothan Hunt. See [LICENSE](LICENSE) for the full text. Graph labels use [JetBrains Mono](https://www.jetbrains.com/lp/mono/) under the SIL Open Font License.
