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
  - `InkOSCoreDerivative.swift`: original-work retrieval for derivative writing —
    encoding detection, chapter splitting, and hybrid BM25 + on-device semantic
    search fused by reciprocal rank. A selected txt is copied into
    `data/pending-sources/` before the book exists so ingest does not depend on the
    picker path. Splitter wrappers (`====` / `【】`) are stripped from titles, and a
    leading table of contents is collapsed into the later same-ordinal chapter.
    `CreateBookResponse.bookId` is what `CreateBookSheet` uses to start
    `prepareDerivativeSource`; the settings page can replace the source on an
    existing 同人 book. Retrieval keys include registered canon entities named in
    the beat goal, scenes and required events, not only `focusCharacters`.
    `derivativeGenerationSections` is called from generation, full revision, and
    independent review prompts, so retrieved canon and the source timeline reach
    all three chapter-stage model calls. `embedDerivativeSource` commits vectors
    in batches and reports coverage so the banner can leave `0/total` before the
    whole novel is indexed.
  - `InkOSCoreCanon.swift`: turns an imported original into continuity — batched
    extraction of canon, world rules, entities, knowledge boundaries, timeline and
    hooks, including a retained index-0 preface, checkpointed per batch so a bounded
    run plus a resume reaches the same place. Source chapter numbers are rewritten
    into the derivative book's units, with provenance kept in `markers`.
  - `InkOSCoreTimeline.swift`: the 同人 story clock. `source/timeline.json` holds the
    anchor and the day offset of chapter 1; `derivativeStoryDay` sums each beat's
    `storyDays` to place a chapter, and `derivativeTimelineStatus` splits canon
    events into past, future, and unplaced for the beat and generation prompts.
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
  macos/ChapterPublisher/InkOSCoreDerivative.swift \
  macos/ChapterPublisher/InkOSCoreCanon.swift \
  macos/ChapterPublisher/InkOSCoreTimeline.swift \
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
  and controlled migrations. An empty directory is valid and suppresses the legacy
  Release migration. All persistence tests must run against a temporary workspace.
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
- A normal chapter Delta never owns the original work's clock. The default
  `normalizedConsistencyDelta` path clears model-supplied `sourceDay` and
  `sourceChapter`; only canon extraction opts into those coordinates. Narrative
  schema fields that arrive as wrapper objects or JSON-encoded wrappers are
  unwrapped into their actual statement/label/description. Projection sync also
  sanitizes legacy wrapper pollution; an unknown required container remains a
  retryable malformed-Delta error instead of becoming JSON text in later prompts.
- A complete generated draft is always retained: if local length, craft, or
  Delta validation fails, the chapter is written as `revision_failed` with the
  native validation findings so it remains available for revision.
- Retention also covers a finished chapter trapped in a broken JSON shell.
  When `requestChapterPayload` cannot parse a response, it logs
  `chapter.invalidJson` and then tries `recoverCompleteChapterProse`, which
  decodes `title`/`content`/`summary` field-by-field without the enclosing
  object. Recovery requires a verifiably closed `content` string — an
  unescaped quote ends the field only when `}` or `,` plus the next `"key":`
  follows it, so bare quotes around dialogue do not truncate prose. A
  successful recovery logs `chapter.proseRecovered`, discards the delta from
  the torn shell, and re-requests only that delta through the existing
  `chapter.deltaRepair.*` path. The full-chapter retry with a strict-format
  suffix runs only when the prose itself is torn mid-string; a second torn
  shell is recovered the same way. Regenerating a complete chapter is what
  drove chapter 5 of 《渊雨浩劫》 into a `finishReason=length` truncation
  after its first draft had already arrived intact.
- Every delta-repair exit is logged. `chapter.deltaRepair.failed` carries a
  `reason` of `requestFailed` (with `statusCode`), `invalidJson` (with
  head/tail), or `missingDeltaField` (with the keys that did arrive). The
  repair previously swallowed all three into the same silent nil, leaving only
  the caller's "自动补登后仍缺失" to debug from.
- Every chapter-pipeline model call streams, including the ones with no live
  preview: beat batch, chapter write, review, and both delta repairs. This is a
  transport requirement, not a UI choice. A reasoning model sends nothing on a
  non-streaming request until it finishes thinking, and `URLRequest.timeoutInterval`
  measures inactivity, so the request aborts with `URLError -1001` whenever
  thinking outlasts the ceiling. Measured on one beat prompt: non-streaming
  first byte 113.9s, streaming 2.4s followed by ~800 reads. Chapter 11 of
  《渊雨浩劫》 failed six consecutive attempts at 300/305/313s — every one on the
  ceiling, none on the relay being unreachable (TCP connected in 0.023s).
  Ceilings are 900s, covering the slowest observed beat batch (899s).
  `NativeCoreSmoke` fails on a transport mismatch, so reverting any of these to
  non-streaming breaks the tests rather than regressing silently.
- The two repair entry points — `performStoredDraftRevalidation` and
  `performDeltaOnlyRevision` — start from an empty delta when the chapter has
  no `story/runtime/chapter-XXXX.consistency.json` yet, logging
  `chapter.delta.missingForRepair`. `chapterConsistencyDelta` still throws for
  approval and projection, where a chapter with no registration must not
  proceed. Repair is the opposite case: a draft whose delta request failed has
  no file, and throwing there drove the chapter into a full rewrite that
  discarded the prose recovery had just saved.
- The opening ability-anchor rule is cumulative across chapters 1-3. Once an
  earlier opening chapter establishes the anomaly, later opening chapters do
  not repeat it, and a chapter beat's forbidden list takes precedence over
  inserting another ability manifestation.
- Diary-like absolute day labels are blocked at narration boundaries by the
  deterministic craft validator and by the review prompt as `[hard][prose]`.
  Relative transitions such as `第二天一早` and dates cited by a character from
  dialogue, a ledger, or resource arithmetic remain valid; the story clock is
  owned by `storyDays`, not exposed as narrator-maintained day numbers.
- Local rules validate cross-chapter order, entity admission, deletion targets, and
  immutable conflicts before an independent model jointly reviews the text, the
  candidate delta, and the post-application continuity index. The review prompt
  requires every `[hard]` finding to carry a repair-scope tag: `[delta]` when the
  prose needs no edit and only the candidate delta must be registered, `[prose]`
  when the text itself must change. When every `[hard]` is `[delta]`, the chapter
  takes a Delta-only repair and re-review with the prose untouched; a single
  `[prose]` finding sends it to the rewrite loop.
  Untagged findings fall back to wording inference, which distinguishes prose
  cited as *evidence* for a registration gap from prose that is itself defective:
  "正文明确写出伤势，但 ENT-004 的 attributes 为空" is `[delta]`, while "正文数字与已
  登记消耗矛盾" is `[prose]`. The inference deliberately leans toward `[delta]`
  because that path is cheap and self-correcting — it leaves the text alone and a
  still-failing re-review drops through to the rewrite loop — whereas a wrong
  `[prose]` verdict makes the model rewrite already-correct prose, return it
  unchanged, and trip the stall detector. That misclassification is what left
  chapter 25 of 《渊雨浩劫》 cycling on empty `upsert.attributes`. The local
  length/craft validator always emits `[prose]`; local continuity-delta conflicts
  always emit `[delta]`.
  Findings that need prose changes enter an automatic revision loop of up to
  `maxAutoRevisionRounds` (default 3) rewrite+re-review rounds, each feeding the
  previous round's findings back into the rewrite; any round that passes goes to
  manual review, and only exhausting all rounds puts the chapter into
  `revision_failed`. Two conditions end the loop early rather than spending the
  remaining rounds: a second verbatim-identical rewrite (the first one retries
  with an escalated instruction and a raised temperature), and a 4xx rejection
  from the endpoint other than 429, which `requestLLM` has already retried —
  re-issuing an request the server refused cannot succeed. The 4xx exit covers
  endpoint rejections only: `InkOSCoreError.origin` distinguishes local
  validation, request configuration, and remote HTTP responses, so a local
  length/craft/Delta miss keeps its own 4xx-shaped UI status and is folded into
  the next round's note, because
  it is the one error the word-gap instructions are built to converge — chapter
  30 of 《渊雨浩劫》 died after a single round at 2 415 words when the local
  422 was read as a server refusal, and the chapter ping-ponged
  4000 → 2415 → 4029 across manual resubmits that each ran exactly one round.
  When a stall ends the
  loop, the recorded failure reason is the standing blocking finding rather than
  the mechanical "输出与原文完全相同", which gives a human nothing to act on.
  A manual rejection (`reviseChapter`) joins the same loop — round one uses the
  human note, later rounds continue automatically. A local length/craft
  validation failure does not enter the loop: the full draft is retained and
  written straight to `revision_failed` for manual rejection. Resubmitting the
  stored native-validator guidance first revalidates and independently reviews
  the unchanged draft; rewriting starts only if that preflight still fails.
  Every round, including local failures that never produced a reviewable draft,
  appends to `llmReview.attempts` without resetting earlier submissions. If a
  later round errors after an earlier draft was persisted, the chapter record
  still receives the complete attempt chain and the latest error. The workflow
  monitor surfaces the current round using the configured maximum.
  `attempts` is the ledger for the whole pipeline, not a rewrite counter: local
  validation, stored-draft revalidation, Delta-only repair, and each rewrite round
  all append one entry. Its length is therefore normally larger than the number of
  automatic rewrites, so read `revisionRound`/`maxRevisionRounds` — not
  `attempts.count` — when reporting how many rewrites a chapter took.
- After manual approval (`approveChapter`), the chapter's `consistencyDelta` is
  projected into `long-form-plan.json.continuity`; re-revision retracts the old
  contribution and re-approval replaces it. Manual edits in the settings page are
  stored as an overlay. Projection records live in
  `story/runtime/continuity-projection.json`.
- Approval snapshots the beat file with the other continuity transaction files,
  keeps the approved and earlier beats, and invalidates every later beat before the
  transaction commits. Runtime state is then regenerated from the post-approval
  projection. Only approval of the current batch's final chapter prefetches the next
  batch, and the in-flight key includes the book ID so two books cannot collide.
- Beat-planning prompts cap open hooks at 24 entries and 4,800 total characters,
  with 180 characters per description. Overdue/nearest deadlines win, then recent
  openings; rendering keeps whole lines and reports omissions. `storyContext`
  compacts continuity into complete parseable JSON under its character allowance,
  retains policy, prioritizes entity identity, due hooks, and recent timeline, and
  records omitted counts and clipped fields under `_truncation`.
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
- Do not keep a GUI launch as a child of the agent shell. A tracked `exec` dies
  with the shell, the window vanishes, and there is no `.ips` — it looks like an
  app crash. Detach (`setsid` / a new session) and log stdout/stderr to a file.
- Command-line Debug builds must pass `ENABLE_DEBUG_DYLIB=NO`. Xcode's stub
  executor (`MacInkostomo.debug.dylib`) is for the debugger; running it standalone
  can exit without a crash report when the window becomes frontmost.
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

## Model Roles

`ModelRole` (public, UI-facing) and `InkOSCore.LLMRole` (core-internal) are
parallel enums bridged by `LLMRole(_:)` and `LLMRole.modelRole`. Three roles
exist: `chapter`/`primary`, `review`, and `extraction`.

- `ModelRole.configKeys` is the single source of truth for the `model`,
  `baseUrl`, and `apiKey` key names of each role. Add a role there rather than
  branching on the role at each read site.
- A blank role-specific value inherits the `chapter` value. Resolve it with
  `.nonEmpty ??` and not `string(_:fallback:)`: a saved-but-blank field is stored
  as `""`, which `string(_:fallback:)` returns verbatim, so the fallback would
  not fire and an empty endpoint would reach `validatedEndpoint` and throw.
- Adding a role means touching `ModelRole`, `LLMRole`, `InkOSConfig` (decode
  defaults plus the deliberate `""` key on encode), `InkOSConfigUpdate`,
  `fetchInkOSConfig`, `updateInkOSConfig`, `fetchModels`, and
  `SettingsWorkspaceView` (section, state, `keyPlaceholder`, `endpointValues`,
  `discoverModels`, `probeModel`, `loadConfigDraft`, `saveLLMSettings`,
  `canSaveLLMSettings`, and the `onChange` invalidations). Switch over the role
  exhaustively in the view; the discovery and probe handlers previously branched
  on `if role == .chapter { … } else { … }`, which silently routes any new role
  into the review state.
- `extraction` backs the RAG model setting and is consumed by
  `extractDerivativeCanon` and `extractDerivativeSettingsOverlay` in
  `InkOSCoreCanon.swift`. Nothing else issues `role: .extraction`.

- **An empty completion is retried at a doubled `max_tokens`, not at the same one.**
  A reasoning model bills `reasoning_content` against the same ceiling as the prose
  and its length varies run to run: measured 5 347 to 16 383 tokens across identical
  requests for one beat prompt against `deepseek-v4-flash`. A ceiling near that
  margin therefore fails a large fraction of the time and looks random. `requestLLM`
  rebuilds the request per attempt and doubles the ceiling up to
  `maxTokensRetryCeiling` (65 536) whenever an attempt produced no prose, then stops
  once there is no headroom left. Two consequences for anyone editing this path:
  the raise is keyed on the response being empty rather than on
  `finishReason == "length"`, because the relay reports this as `stop` about as often
  as `length` and only the emptiness is reliable; and a transport failure must keep
  retrying at the *unchanged* ceiling, since more budget does not fix a dropped
  connection. `test/NativeCoreSmoke.swift` asserts the observed `max_tokens` of every
  attempt — a count-only assertion passes against a build that retries without
  raising, which is the bug that failed chapter 1 of 《灰雾之前》 three times.

## Canon Extraction

`extractDerivativeCanon(bookID:maxBatches:)` turns an imported original work into
canon. It batches the source by character budget, asks the extraction model for
`ContinuityDelta`-shaped JSON, and merges each batch into the continuity
projection's `baseContinuity`.

- **Chapter fields must be renumbered.** The model reads *source* chapters and
  answers in them, but `LongFormContinuity.validated` bounds
  `availableFromChapter`, `earliestChapter`, `openFromChapter`, and their peers by
  the *derivative* book's `targetChapters` — typically a few dozen against a
  source of hundreds. `canonicalizedExtractionDelta` rewrites every one of them to
  chapter 1 (canon is available from the start) and keeps source provenance in
  `markers` as `source-chapter-N`. Skipping this fails validation on the first
  knowledge entry and the error reads like a model fault.
- **Knower lists are de-overlapped.** A knowledge item that lists the same
  person in both `allowedKnowers` and `forbiddenKnowers` fails `validated()`
  and would abort a long extraction on one confused object. Extraction drops
  the overlap from `forbiddenKnowers` (allowed wins: a wrong forbid is worse
  than under-blocking) and records `canon.knowledge.knower_overlap`. Chapter
  deltas still throw.
- **`remove` and `policy` are dropped** from extraction output. The pass only
  contributes facts; letting it delete canon or rewrite policy would give the
  model authority over entries the settings text owns.
- **Layering.** Source canon goes to `baseContinuity`; the customer's settings
  text goes to `manualOverlay` via `extractDerivativeSettingsOverlay`.
  `synchronizeContinuityProjection` applies the overlay last and with
  `allowImmutableChanges: true`, so the settings text outranks both extracted
  canon and approved chapter deltas. Do not merge settings into `baseContinuity`
  — a later re-extraction would win the field back.
- **Resume.** `source/canon-progress.json` records `nextChapterIndex`, the
  accumulated delta, and the batch log, and is written after every batch. A failed
  batch keeps the batches before it. The checkpoint is keyed to
  `SourceManifest.sourceDigest`: replacing the original discards it, since the
  progress describes a source that no longer exists. Replacement also clears the
  old source-only `baseContinuity`, while preserving the author's `manualOverlay`
  and approved chapter deltas. `source/preparation.json` separately persists the
  author's settings text and embedding intent, so `resumeDerivativePreparation`
  can finish overlay/index work even when canon is already complete; bootstrap
  restores the unfinished banner after an app relaunch. A pre-`preparation.json`
  book synthesizes a resumable intent from its manifest, existing cursor, and
  index; the unavailable author-settings text becomes an empty overlay and the
  source canon/embedding work continues without re-importing the original.
- **Extraction is bounded-concurrent, commit is ordered.** Up to
  `canonExtractionConcurrency` (currently 3) adjacent batches issue their model
  calls in a sliding window. A newly opened slot uses the latest committed
  continuity, while other calls already in flight retain the roster they started
  with. Results are committed strictly in source order: entity canonicalization,
  timeline order seeding, projection validation, and `canon-progress.json` writes
  still happen one batch at a time. After the atomic checkpoint write, the core's
  typed progress callback updates `WorkspaceModel.derivativePreparation`; do not
  wait for the full extraction invocation to return before refreshing the banner.
  The prompt's entity roster is only advisory;
  `canonicalCanonEntities` is the authority and deterministically maps same-name
  entities from a stale in-wave roster back to the first ID/type. If a batch fails,
  later tasks are cancelled or discarded and the durable cursor remains at that
  gap, so resume never skips source canon. Do not replace this with unordered
  projection writes or advance `nextChapterIndex` from whichever response returns
  first.
- **Writing is gated on preparation.** `generateChapter`, `reviseChapter`, and
  `approveChapter` all call `validateDerivativePreparationForWriting` before a job
  or approval starts. Canon and the settings overlay must be complete, a requested
  embedding index must be complete, and the configured timeline anchor must resolve
  to a source chapter.
- **The preface is canon.** A retained manifest chapter at index 0 is extracted and
  checkpointed independently through `prefaceExtracted`. Legacy progress derives
  that bit from completed ranges and resumes the preface before the numeric cursor
  when needed.
- **Source entities are name-stable across batches.** Canon extraction collapses
  normalized same-name entities even when a model changes their generated IDs. The
  first entity keeps its ID and type while later batches fill attributes; a type
  mismatch records `canon.entity.type_conflict`. Loading an old checkpoint applies
  the same de-duplication and rebuilds only source `baseContinuity`, retaining the
  manual overlay and approved chapter contributions.
- **Projection writes are snapshotted.** `mutateContinuityProjection` restores the
  projection, the plan, and the volume checkpoints if the post-merge
  `synchronizeContinuityProjection` throws. Without it a delta that passes its own
  merge but fails the full `validated()` pass leaves a projection on disk that no
  later synchronize can rebuild, and the book's continuity is permanently
  unloadable.

- **Source coordinates are global and source-only.** `sourceChapter` survives every
  rewrite for source milestones. An accepted `sourceDay` must survive too, because
  these are the only inputs to the timeline gate below. Extraction accepts
  `sourceDay` only from a batch that directly contains the configured global anchor;
  otherwise it drops the model's batch-local zero. Author settings milestones keep
  both fields nil so they cannot be mistaken for original-work events. Three places
  rebuild a source milestone —
  `canonicalizedExtractionDelta`, `resolvingTimelineOrderCollision`, and
  `normalizedTimeline` — and all three must carry them forward. Dropping them in
  any one silently unplaces events, and nothing fails: the gate just stops
  reporting the event as not-yet-happened.

- **The batch budget is bounded by output, not context.** A batch must come back as
  one complete JSON object, and a reasoning model spends part of the same
  `max_tokens` on `reasoning_content` before writing any of it. At a 40 000-character
  budget the first 诡秘之主 batch produced 12 056 reasoning tokens and JSON that was
  still unclosed at the 16 384-token ceiling, so the entire batch was discarded.
  `canonBatchCharacterBudget` (15 000) and `canonItemsPerArray` (12, enforced in the
  prompt) keep one answer inside a common ceiling. Raising either means re-checking
  against the *smallest* `maxTokens` a user might configure, not the current one.
  Because the pass is checkpointed per batch, smaller batches cost wall-clock time
  rather than progress.

- **Truncation is reported separately from malformed JSON.** A batch that came back
  as prose the parser rejected is a prompt or model fault; one cut off at the ceiling
  is a budget fault, and `finishReason == "length"` is what separates them in the
  extraction error message. Collapsing the two into one "not JSON" message sent a
  whole debugging session after the prompt when the output limit was the actual
  fault. Note this is narrower than the retry rule under Model Roles: `length`
  distinguishes *truncated output* from *bad output*, but it does not identify an
  exhausted budget on its own, because a response with no content at all reports
  `stop` about as often as `length`.

- **Model output is untyped at every field.** Values arriving from extraction are
  whatever the model emitted — `null`, a number, or a nested object where the schema
  promised a string. `normalizedText` is the single flattener, and it may hand only
  containers to `JSONSerialization.data(withJSONObject:)`: a bare top-level scalar
  raises `NSInvalidArgumentException`, an ObjC exception that `try?` cannot catch and
  that terminates the app. A single `null` in real 诡秘之主 output crashed the pass
  this way. Nulls in optional fields must flatten to empty and drop; nulls in
  required fields must throw `malformedDelta` so the batch stays retryable.

## Derivative Timeline

`InkOSCoreTimeline.swift` answers one question for a derivative book: at this
chapter, which canon events are already behind the story and which must not have
happened yet. It exists because the dominant fan-fiction failure is a character
knowing a source fact too early, which no continuity check catches — the fact is
correct, only its timing is wrong.

- **Two axes, never interpolated between.** `sourceDay` is exact but sparse (source
  text says "三天后", not dates). `sourceChapter` is set for every extracted
  milestone and monotonic in a linearly told novel, so it is the fallback
  classifier. Deriving a day from a source chapter is deliberately not done:
  source chapters advance at uneven story rates, so it would be invented
  precision. Events that cannot be placed go into `unplaced`, which the prompt
  reports as uncertain rather than as fact.
- **`order` is not a time axis.** It is a dense sort key that `applyContinuityDelta`
  renumbers on collision. Never read it as chronology.
- **The story clock is summed, not stored per chapter.** `derivativeStoryDay` adds
  each preceding beat's `storyDays`, falling back to
  `DerivativeTimeline.defaultChapterDays` when a beat omits it. Beats are the only
  writer of story time, so a beat that lies about `storyDays` moves every later
  chapter.
- **Undated events past the anchor stay `unplaced` once the book passes the anchor**,
  rather than being forced into `future`. Blocking an event wrongly is worse than
  under-blocking: a derivative book that has caught up to the source is supposed to
  be able to play canon events out, and the author's beats decide that. Before the
  anchor — the case where premature references actually happen — they classify as
  `future` and are forbidden outright.
- **The anchor binds at read time.** The customer names it in prose while creating
  the book, before any extraction exists, so no milestone ID can be stored.
  `resolvedAnchor` matches by ID, then exact label, then containment, then the
  last two characters of the shorthand as a required token (`克莱恩穿越` → `穿越`)
  with any leftover prefix as a tie-break. Token search looks at source chapters
  1–80 first so a late-book “穿越真相” cannot steal an opening clock, then the
  rest of the book, and fills `anchorSourceChapter` from whatever it matched.
- **The timeline limits RAG at the SQL boundary.** Before day 0, retrieval may read
  at most `anchorSourceChapter - 1`; at or after the anchor it may read through the
  latest placed past event. The maximum is threaded through BM25/FTS and semantic
  candidate queries, so future passages never enter either candidate pool.
- **Generation, revision, and review share one derivative context builder.** It
  injects the same timeline and source passages in all three prompts. Registered
  source entities mentioned by beat goals, scenes, and required events become
  lexical keys; a non-empty beat/fallback query still runs retrieval when that key
  list is empty. Review must label premature occurrence, knowledge, prediction, or
  discussion of a future source event as `[hard][prose]`.
- **The beat prompt's forbidden list is printed at both batch ends.** The event
  lists are capped at `timelineEventListLimit`, and a batch that retires the
  nearest future events mid-batch would let an event ranked beyond the cap enter
  the writing prompt's list without the planner ever seeing it — the beat could
  schedule something the chapter prompt then forbids. `derivativeBeatClosingSection`
  names exactly those closing-only events, so both prompts cover the same events.
- **`bookKind` defaults to `.original`** when `book.json` predates the field. An
  original book merely loses prompt sections it has no source for, whereas treating
  an original book as derivative would order the writing model to obey canon that
  does not exist.

## Security

- Keep secrets out of logs, source control, and `JSONValue`. Model keys live in a
  private configuration file with `0600` permissions; the settings page shows only
  masked previews. `InkOSConfig.encode` writes `""` for every role's key.
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
