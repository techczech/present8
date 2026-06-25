# Present Agents

This repository is the legacy SwiftUI implementation of Present.

## Status

- Treat this repo as a behavior reference by default.
- Active product development has moved to `../present8on`.
- Do not start new feature work here unless the user explicitly asks for changes in the Swift app.

## What This Repo Is Still For

- Checking the original deck format and parser behavior
- Reviewing legacy `WKWebView` handling for remote pages, YouTube, and X/Twitter embeds
- Verifying the original mobile remote API and presentation semantics
- Comparing old behavior against the Electron rewrite

## Primary Reference Files

- `Present/DeckMarkdownParser.swift`
- `Present/Slide.swift`
- `Present/WebView.swift`
- `Present/RemoteServer.swift`
- `walkthrough.md`

## Working Rules

- Prefer documenting migration or parity findings here rather than adding new product scope.
- If you must change runtime behavior in this repo, note whether the same change is required in `../present8on`.
- Keep references to `present8on` explicit so future agents do not mistake this repo for the active target.
