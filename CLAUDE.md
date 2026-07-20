# CLAUDE.md

Repository-specific engineering rules are in [AGENTS.md](AGENTS.md). User-facing setup and verification commands are in [README.md](README.md).

## Current Architecture

- `server.js` and `lib/` implement the local Express API and long-running workflows.
- `public/` contains the plain HTML, CSS, and JavaScript interface.
- `macos/ChapterPublisher/` and `ChapterPublisher.xcodeproj/` implement the native SwiftUI macOS app and local API client.
- `inkos/` is a vendored, locally modified InkOS source snapshot. Preserve its license and build it before running the app.
- `book/` is the project-local InkOS workspace and source of truth for chapters.
- `data/` stores private Publisher metadata, workflow jobs, backups, and LLM configuration.

## Required Checks

Run `npm test`, run `node --check` over project JavaScript, and exercise the affected browser workflow. Native changes also require an `xcodebuild` build with a writable DerivedData path and an application lifecycle check.

Never commit `data/`, `book/`, `.env` files, credentials, dependency directories, or generated build output.
