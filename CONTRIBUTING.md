# Contributing

Thanks for helping with NoteMesh. Issues and pull requests are both welcome.

## Getting started

1. Build with `scripts/build-app.sh` (Xcode's Command Line Tools are enough).
2. Run with `open build/NoteMesh.app --args --sample` to work against the built-in sample library. It never reads your own notes, which keeps screenshots, bug reports and test runs free of personal data.
3. `scripts/build-app.sh debug` adds test hooks such as `--click-channel`. Don't distribute that build.

## Guidelines

- **Privacy first.** NoteMesh must never send anything off the Mac, write to the Notes library, or read locked notes. Changes that touch data handling should say how they keep to that.
- **Native and fast.** SwiftUI for the interface, Metal for the graph. Keep the graph's frame build well under a millisecond (`--bench` measures it).
- **Liquid Glass with care.** Glass belongs to controls and floating surfaces; content uses fills.
- **Plain words** in the interface: short, specific, no jargon.
- Keep pull requests small and focused, and include a screenshot for visual changes (taken with `--sample`).

## Reporting bugs

Open an issue with your macOS version, what you did, what you expected and what happened. Please don't attach real notes or screenshots of them; reproduce with `--sample` if you can. Security and privacy problems go through [SECURITY.md](SECURITY.md) instead.
