# Repository Guidelines

Guidance for AI coding agents working in this repository. Setup and user-facing
architecture details are in [README.md](README.md); the InkOS migration audit is in
[INKOS_COMPATIBILITY_AUDIT.md](INKOS_COMPATIBILITY_AUDIT.md).

## Project Overview

MacInkostomo is a native SwiftUI macOS application — an AI-assisted long-form novel
workbench (bundle ID `com.lanting200.MacInkostomo`). The InkOS engine has been
migrated into the Xcode target as an in-process Swift library called `InkOSCore`;
the UI calls it directly through typed functions.

The application has exactly one runtime path:

```text
SwiftUI View
  -> WorkspaceModel
  -> InkOSLibrary typed functions
  -> InkOSCore Swift actor
  -> book/data files + configured remote LLM endpoint
```

Do not add a local web server, loopback port, HTTP client boundary, Node runtime,
CLI bridge, subprocess, or browser UI. The fanqie (番茄) login sheet only hosts the
platform's official authentication page; it is not an app-owned web UI.

There is no build-system manifest at the repository root (no root `package.json`,
`pyproject.toml`, etc.). The root `node_modules/` directory holds leftover Express
dependencies from the removed local-server prototype; it is gitignored and not part
of the build or runtime. The only build system is the Xcode project.

## Project Structure

- `macos/ChapterPublisher/`: all Swift sources (~14k lines). Key files:
  - `ChapterPublisherApp.swift`, `ContentView.swift`: app entry and root view.
  - `WorkspaceModel.swift`: UI state coordination; never reads or writes novel
    files directly.
  - `InkOSLibrary.swift`: typed function entry points used by SwiftUI (books,
    chapters, generation, revision, review, settings, long-form planning, model
    configuration, debug, fanqie comparison).
  - `InkOSCore.swift`: native storage, books, chapters, approval, task isolation,
    structured debug events.
  - `InkOSCorePlanning.swift`: fixed creation guidance, exact per-volume/per-chapter
    budgeting, 3,000,000-word upper bound.
  - `InkOSCoreContinuity.swift`: approved-chapter continuity projection, legacy
    delta migration, manual overrides, immutable-conflict protection.
  - `InkOSCoreLLM.swift`: model configuration, creation assistance, chapter
    generation, revision, independent consistency review.
  - `InkOSCoreCraft.swift`: craft kernel, per-book craft rules, batched
    chapter beat sheets, chapter length validation, runtime state regeneration.
  - `InkOSCoreSettings.swift`: settings files and atomic backup/restore.
  - `InkOSCoreFanqie.swift`: fanqie session, online work/chapter reading, work
    creation, chapter upload and replacement.
  - `NativeModels.swift`, `NativeComponents.swift`, `NativeWorkspaceView.swift`,
    `ActivityWorkspaceView.swift`, `BookDialogs.swift`,
    `FanqieWorkspaceView.swift`, `ReviewWorkspaceView.swift`,
    `SettingsWorkspaceView.swift`: UI models and workspace views.
- `ChapterPublisher.xcodeproj/`: Xcode project with the shared `ChapterPublisher`
  scheme. Swift 5, macOS deployment target 13.0, generated Info.plist disabled
  (uses `macos/ChapterPublisher/Info.plist`).
- `test/NativeCoreSmoke.swift`: native-core regression test running against a
  temporary workspace.
- `book/`: Debug-workspace novel projects (`book/books/<bookId>/` is the
  authoritative store for chapter text, chapter index, long-form plan, story bible,
  characters, world rules, foreshadowing, persistent objects, resources, runtime
  state). Private user data — never commit.
- `data/`: Debug-workspace workbench state, private model configuration, backups,
  structured debug events. Private user data — never commit.
- `inkos/`: upstream InkOS source snapshot (TypeScript/pnpm monorepo) kept only for
  license provenance, migration comparison, and semantic regression reference. It
  is not compiled into or launched by the app; do not wire it into the Xcode target.

## Build and Test

Environment: macOS 13+, Xcode 14+.

- `open ChapterPublisher.xcodeproj` opens the native project.
- Debug build:
  `xcodebuild -project ChapterPublisher.xcodeproj -scheme ChapterPublisher -configuration Debug -derivedDataPath /tmp/MacInkostomo-DerivedData CODE_SIGNING_ALLOWED=NO build`
- Build the same command with `-configuration Release` before packaging.

Native core smoke test (storage and planning regression coverage):

```bash
swiftc -parse-as-library \
  macos/ChapterPublisher/NativeModels.swift \
  macos/ChapterPublisher/InkOSCore.swift \
  macos/ChapterPublisher/InkOSCorePlanning.swift \
  macos/ChapterPublisher/InkOSCoreContinuity.swift \
  macos/ChapterPublisher/InkOSCoreLLM.swift \
  macos/ChapterPublisher/InkOSCoreCraft.swift \
  macos/ChapterPublisher/InkOSCoreSettings.swift \
  macos/ChapterPublisher/InkOSCoreFanqie.swift \
  test/NativeCoreSmoke.swift \
  -o /tmp/macingkostomo-native-core-smoke

/tmp/macingkostomo-native-core-smoke
```

The smoke test exercises book creation, exact budgeting, settings reads, atomic
backup/restore, continuity projection, policy enforcement, volume-end checkpoints,
and deletion inside a temporary directory; it must not touch real `book/` or `data/`.

## Data Directories

- Debug builds use the existing `book/` and `data/` next to the Xcode project.
  These are live user novels, not fixtures.
- Release builds use `~/Library/Application Support/MacInkostomo/`; first launch
  copies existing books and configuration from the legacy workspace.
- `MACINKOSTOMO_WORKSPACE` explicitly selects a data workspace; use it for tests
  and controlled migrations. All persistence tests must run against a temporary
  workspace.
- Workspace resolution order (`InkOSCore.swift`): `MACINKOSTOMO_WORKSPACE`, then
  in DEBUG only `CHAPTER_PUBLISHER_ROOT`, the `ChapterPublisherRoot` Info.plist
  key, and the current directory. A Debug build launched without an explicit
  workspace therefore resolves the real `book/` and `data/`.
- `MACINKOSTOMO_WORKSPACE` must be exported into the app's own process. `open -a`
  goes through LaunchServices, which does not inherit shell environment
  variables, so a shell-set variable does not reach the app.

## Coding Style

- Swift 5, two-space indentation.
- `async` functions for InkOS operations; actor isolation for mutable core state
  (`InkOSCore` is an actor).
- New product behavior must enter through typed `InkOSLibrary` functions backed by
  a focused native core module — keep storage, planning, LLM, settings, continuity,
  and fanqie responsibilities in their respective `InkOSCore*.swift` files.
- All JSON writes go through a temporary file followed by atomic replacement.
  Settings edits copy the full story directory first and roll back on failure.
- Validate book IDs and story relative paths before any file access.
- Preserve Chinese UI strings and novel content unless the task explicitly requests
  copy changes. Code comments and identifiers are in English.

## Documentation

`README.md`, this file, and `INKOS_COMPATIBILITY_AUDIT.md` describe behavior that
ships, not behavior that is planned. During the native migration these documents
were written as the intended spec and ran ahead of the Swift wiring, which made
half-built features read as done.

- Before trusting a documented behavior, grep for callers of the named symbol. A
  core function with no caller is not a shipped feature: `craftAdvisoryList` had
  no UI consumer and `invalidateChapterBeats` had no caller while both were
  documented as active.
- Before writing a documented behavior, confirm the whole path exists — typed
  `InkOSLibrary` entry point, core implementation, and the UI or core caller that
  actually reaches it. Describe partial wiring as partial.
- When code and docs disagree on a detail (settings grouping, file path, group
  title), check which placement the code chose deliberately and fix the doc
  instead of moving the code.
- Update these three files in the same change as the behavior they describe.
  Doc-only corrections need no rebuild; state that they were not built.

## Long-Form Governance

- Creating a novel requires target total word count, volume count, per-chapter word
  count, tolerance, and special constraints. Bounds: 1,000–3,000,000 words, up to
  100 volumes and 10,000 chapters; the total is distributed exactly (integer
  quotient + remainder) so per-chapter targets sum to the total.
- Chapter generation reads the story bible, hard rules, character knowledge
  boundaries, current state, persistent-object and resource ledgers, foreshadowing
  pool, chapter summaries, the latest volume-end checkpoint, and the full text of
  the previous chapter. Generated chapters must submit a `consistencyDelta`.
- Local rules validate cross-chapter order, entity admission, deletion targets, and
  immutable conflicts before an independent model jointly reviews the text, the
  candidate delta, and the post-application continuity index. Any hard conflict
  puts the chapter into `revision_failed`.
- After manual approval (`approveChapter`), the chapter's `consistencyDelta` is
  projected into `long-form-plan.json.continuity`; re-revision retracts the old
  contribution and re-approval replaces it. Manual edits in the settings page are
  stored as an overlay. Projection records live in
  `story/runtime/continuity-projection.json`.
- Consistency policies all run: `requireContinuousVolumes` (no skipping chapters or
  unreviewed chapters), `allowUnplannedEntities` (whether text may introduce
  unregistered entities), `requireConsistencyDelta` (mandatory chapter contract),
  `checkpointAtVolumeEnd` (writes `story/runtime/checkpoints/volume-XXXX.canon.json`
  once a volume fully passes; invalidated on re-revision and rebuilt on re-review).

## Testing

- Build both Debug and Release for native changes.
- Run the native smoke test for storage or planning changes.
- Persistence tests must use a temporary workspace and leave `data/` and `book/`
  untouched.

App-level verification (no child runtime process, no listening socket) launches a
real app that writes to a real workspace. Never point it at `book/` or `data/`:

```bash
MACINKOSTOMO_WORKSPACE=$(mktemp -d) \
  /path/to/MacInkostomo.app/Contents/MacOS/MacInkostomo
```

- Exec the binary inside the bundle directly. Do not use `open -a` — it drops the
  workspace variable and the app falls back to the real Debug workspace.
- Confirm the isolation actually took effect by checking the temporary directory
  is non-empty afterward. Do not assume the variable applied.
- Scope `lsof` to the app's PID with `-a`; without it the selection filters are
  ORed and unrelated processes' listeners appear in the result.
- `MacInkostomo.app` must not spawn an internal service or listen on any local
  port. Verify against the app's own process subtree.
- If a launch does reach the real workspace, books are recoverable: `deleteBook`
  moves the directory to `data/deleted-books/<epoch>-<id>/` instead of deleting,
  and `fetchBooks` unions `state.json` keys with the on-disk `book/books/`
  listing, so moving the directory back restores the book with no `state.json`
  edit. Snapshot `data/state.json` before any launch that could write.

## Security

- Keep secrets out of logs, source control, and `JSONValue`. Model keys live in a
  private configuration file with `0600` permissions; the settings page shows only
  masked previews.
- Remote model endpoints default to requiring HTTPS; if an existing configuration
  explicitly enables HTTP, the native core still applies the same configuration
  constraints.
- Validate all book IDs and story paths before file access.
- No inbound listener belongs in the app; remote model requests may only use the
  configured endpoint.
- Never commit `data/`, `book/`, `test-results/`, credentials, `.env` files, user
  state, backups, or build output (all are gitignored).

## License

GNU Affero General Public License v3.0 only. InkOS upstream source and base commit
are recorded in [NOTICE](NOTICE); migration boundaries are described in
[INKOS_COMPATIBILITY_AUDIT.md](INKOS_COMPATIBILITY_AUDIT.md).
