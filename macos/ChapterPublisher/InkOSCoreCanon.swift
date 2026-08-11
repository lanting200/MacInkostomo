import Foundation

// MARK: - Canon extraction models

/// One completed extraction batch. Recorded so a resumed run can report what the
/// earlier rounds produced without re-reading the model output.
struct SourceCanonBatch: Codable, Equatable, Sendable {
  /// 1-based, stable across resumes: the counter continues from the checkpoint
  /// rather than restarting at the first batch of the current run.
  let index: Int
  let startChapter: Int
  let endChapter: Int
  let characterCount: Int
  let canonCount: Int
  let worldRuleCount: Int
  let entityCount: Int
  let knowledgeCount: Int
  let timelineCount: Int
  let hookCount: Int
  let model: String
  let completedAt: String
}

/// Resumable extraction state, persisted as `source/canon-progress.json`.
///
/// Holds the accumulated delta rather than the merged continuity: the merge target
/// is the projection's `baseContinuity`, which the chapter pipeline also writes, so
/// storing a merged copy here would fork into a second source of truth.
struct SourceCanonProgress: Codable, Equatable, Sendable {
  let version: Int
  let bookId: String
  /// `SourceManifest.sourceDigest` this progress belongs to. A different digest
  /// means the original was replaced, so the checkpoint describes a book that no
  /// longer exists and is discarded instead of being extended.
  let sourceDigest: String
  /// Splitter-version plus chapter-boundary digest from `SourceManifest`. The
  /// original bytes can stay identical while a corrected heading rule changes
  /// chapter offsets, so `sourceDigest` alone cannot validate a checkpoint.
  var sourceLayoutDigest: String?
  let chapterCount: Int
  /// `chapterCount` deliberately excludes index 0, so the preface needs an
  /// independent checkpoint bit. Optional keeps v1 progress decodable: loading a
  /// legacy checkpoint derives the value from its completed batch ranges.
  var prefaceExtracted: Bool?
  /// Version of the global source-time normalization applied to `delta.timeline`.
  /// Old checkpoints omitted it and may contain batch-local day-zero values.
  var sourceCoordinatesVersion: Int?
  /// 1-based index of the first chapter not yet extracted. Equal to
  /// `chapterCount + 1` once the pass is complete.
  var nextChapterIndex: Int
  var batches: [SourceCanonBatch]
  var delta: ContinuityDelta
  /// Settings text digest whose overlay is already applied, so re-running with
  /// unchanged settings does not re-issue the call.
  var settingsDigest: String?
  var updatedAt: String

  static let currentVersion = 1
  static let currentSourceCoordinatesVersion = 1

  var isComplete: Bool { (prefaceExtracted ?? true) && nextChapterIndex > chapterCount }
}

/// Extraction status for the UI.
struct SourceCanonStatus: Codable, Equatable, Sendable {
  let chapterCount: Int
  let extractedChapters: Int
  let batchCount: Int
  let isComplete: Bool
  let canonCount: Int
  let worldRuleCount: Int
  let entityCount: Int
  let knowledgeCount: Int
  let timelineCount: Int
  let hookCount: Int
  let hasSettingsOverlay: Bool
  let updatedAt: String?
}

/// The parts of source preparation that are not recoverable from canon progress
/// alone. Persisting this beside the imported source lets a later app launch finish
/// the author's overlay and the optional semantic index after any intermediate
/// failure, without asking the customer to select the original file again.
struct DerivativePreparationIntent: Codable, Equatable, Sendable {
  let version: Int
  let sourceDigest: String
  let settingsText: String
  let embedRequested: Bool
  let updatedAt: String

  static let currentVersion = 1
}

/// Read-only preparation state used by the workspace to restore a resumable banner.
struct DerivativePreparationSnapshot: Equatable, Sendable {
  let intent: DerivativePreparationIntent
  let canon: SourceCanonStatus
  let embedding: SourceEmbeddingStatus
  let overlayComplete: Bool
  let embeddingComplete: Bool

  var isComplete: Bool {
    canon.isComplete && overlayComplete && embeddingComplete
  }
}

/// A planned batch: the chapters one model call covers.
struct SourceCanonBatchPlan: Equatable, Sendable {
  let index: Int
  let chapters: [SourceChapter]

  var startChapter: Int { chapters.first?.index ?? 0 }
  var endChapter: Int { chapters.last?.index ?? 0 }
  var characterCount: Int { chapters.reduce(0) { $0 + $1.length } }
}

// MARK: - Extraction

extension InkOSCore {
  /// Characters of original text per model call.
  ///
  /// The binding constraint is the *output*, not the context window. Extraction has
  /// to write one JSON object covering everything in the batch, and a reasoning model
  /// spends part of the same `max_tokens` budget thinking first. At 40 000 characters
  /// the first 诡秘之主 batch (11 chapters) produced 12 056 reasoning tokens plus a
  /// JSON object that was still unfinished when the 16 384-token ceiling hit, so the
  /// whole batch was discarded. 15 000 keeps one batch's answer inside a common
  /// ceiling; the pass is checkpointed per batch, so more, smaller batches cost
  /// wall-clock time rather than progress.
  static let canonBatchCharacterBudget = 15_000

  /// Items the model may return per array, per batch.
  ///
  /// Without a cap the model itemizes everything it reads — the batch above listed a
  /// battleship's dimensions as canon — which spends the output budget on detail no
  /// chapter will ever need. The cap forces it to rank, and canon it skipped in one
  /// batch is still reachable through source retrieval.
  static let canonItemsPerArray = 12

  /// Retries per batch before the pass gives up. The checkpoint is written after
  /// every batch, so giving up costs only the current batch.
  static let canonBatchAttempts = 2

  func canonProgressURL(_ bookID: String) throws -> URL {
    try sourceDirectoryURL(bookID).appendingPathComponent("canon-progress.json")
  }

  func derivativePreparationIntentURL(_ bookID: String) throws -> URL {
    try sourceDirectoryURL(bookID).appendingPathComponent("preparation.json")
  }

  func loadSourceManifest(bookID: String) throws -> SourceManifest {
    let url = try sourceDirectoryURL(bookID).appendingPathComponent("manifest.json")
    guard fileManager.fileExists(atPath: url.path) else {
      throw InkOSCoreError("请先导入原著文件", statusCode: 404)
    }
    do {
      let manifest = try decoder.decode(SourceManifest.self, from: Data(contentsOf: url))
      try completePendingSourceReset(bookID: bookID, manifest: manifest)
      return manifest
    }
    catch { throw InkOSCoreError("原著清单格式错误：\(error.localizedDescription)", statusCode: 503) }
  }

  func loadCanonProgress(bookID: String, manifest: SourceManifest) throws -> SourceCanonProgress {
    let url = try canonProgressURL(bookID)
    func freshProgress(settingsDigest: String? = nil) -> SourceCanonProgress {
      SourceCanonProgress(
        version: SourceCanonProgress.currentVersion,
        bookId: bookID,
        sourceDigest: manifest.sourceDigest,
        sourceLayoutDigest: manifest.layoutDigest,
        chapterCount: manifest.chapterCount,
        prefaceExtracted: !manifest.chapters.contains { $0.index == 0 },
        sourceCoordinatesVersion: SourceCanonProgress.currentSourceCoordinatesVersion,
        nextChapterIndex: 1,
        batches: [],
        delta: ContinuityDelta(),
        settingsDigest: settingsDigest,
        updatedAt: isoTimestamp()
      )
    }
    if fileManager.fileExists(atPath: url.path) {
      do {
        var existing = try decoder.decode(
          SourceCanonProgress.self,
          from: Data(contentsOf: url)
        )
        let identityMatches = existing.version == SourceCanonProgress.currentVersion
          && existing.sourceDigest == manifest.sourceDigest
        // A v1 manifest has no layout digest. Keep it read-only until source
        // readiness rejects that manifest and the user re-imports; clearing its
        // canon merely by opening the workspace would be destructive. Once a
        // current manifest exists, the layout digest becomes mandatory.
        let currentLayoutMatches = manifest.version == SourceManifest.currentVersion
          && manifest.layoutDigest != nil
          && existing.sourceLayoutDigest == manifest.layoutDigest
        if identityMatches,
          manifest.version != SourceManifest.currentVersion || currentLayoutMatches
        {
          // v1 checkpoints did not track the retained index-0 preface. A completed
          // range beginning at zero proves it landed; otherwise resume it before the
          // numeric cursor, including a checkpoint that had already reached the end.
          if existing.prefaceExtracted == nil {
            let hasPreface = manifest.chapters.contains { $0.index == 0 }
            existing.prefaceExtracted = !hasPreface || existing.batches.contains {
              $0.startChapter == 0
            }
          }
          return existing
        }

        // The source layer was extracted against different chapter boundaries.
        // Replace it before saving the fresh cursor so an interruption can never
        // leave the stale base paired with a checkpoint that starts at chapter 1.
        let reset = freshProgress(settingsDigest: existing.settingsDigest)
        _ = try replaceCanonBaseContinuity(
          bookID: bookID,
          delta: reset.delta,
          source: "原著切章布局变化，正典游标失效"
        )
        try saveCanonProgress(reset)
        recordDebug(scope: "canon", message: "canon.progress.layout_reset", data: [
          "bookId": bookID,
          "previousLayoutDigest": existing.sourceLayoutDigest ?? "legacy",
          "sourceLayoutDigest": manifest.layoutDigest ?? "missing",
        ])
        return reset
      } catch {
        if let coreError = error as? InkOSCoreError { throw coreError }
        throw InkOSCoreError(
          "原著正典进度格式错误：\(error.localizedDescription)",
          statusCode: 503
        )
      }
    }
    return freshProgress()
  }

  @discardableResult
  func saveDerivativePreparationIntent(
    bookID: String,
    settingsText: String,
    embedRequested: Bool
  ) throws -> DerivativePreparationIntent {
    let manifest = try loadSourceManifest(bookID: bookID)
    _ = try validateSourceSearchIndex(bookID: bookID, manifest: manifest)
    let intent = DerivativePreparationIntent(
      version: DerivativePreparationIntent.currentVersion,
      sourceDigest: manifest.sourceDigest,
      settingsText: settingsText.trimmingCharacters(in: .whitespacesAndNewlines),
      embedRequested: embedRequested,
      updatedAt: isoTimestamp()
    )
    try atomicWrite(
      encoder.encode(intent),
      to: try derivativePreparationIntentURL(bookID)
    )
    return intent
  }

  func derivativePreparationSnapshot(bookID: String) throws -> DerivativePreparationSnapshot {
    let manifest = try loadSourceManifest(bookID: bookID)
    _ = try validateSourceSearchIndex(bookID: bookID, manifest: manifest)
    let url = try derivativePreparationIntentURL(bookID)
    let storedIntent: DerivativePreparationIntent?
    if fileManager.fileExists(atPath: url.path) {
      do {
        storedIntent = try decoder.decode(
          DerivativePreparationIntent.self,
          from: Data(contentsOf: url)
        )
      } catch {
        throw InkOSCoreError(
          "原著准备记录格式错误：\(error.localizedDescription)",
          statusCode: 503
        )
      }
    } else {
      storedIntent = nil
    }
    let intent = storedIntent ?? DerivativePreparationIntent(
      version: DerivativePreparationIntent.currentVersion,
      sourceDigest: manifest.sourceDigest,
      // v1.2 以前没有 preparation.json。原文件、游标和索引都还在，只有
      // 作者原始输入无法还原；用空设置恢复可续跑的正典与语义索引，而不是
      // 要求再次选择一份已经完整导入的巨型原著。
      settingsText: "",
      embedRequested: true,
      updatedAt: manifest.ingestedAt
    )
    guard intent.version == DerivativePreparationIntent.currentVersion,
      intent.sourceDigest == manifest.sourceDigest
    else {
      throw InkOSCoreError("原著准备记录已过期，请重新导入原著", statusCode: 409)
    }

    let progress = try repairedCanonProgress(bookID: bookID, manifest: manifest)
    let canon = canonStatus(progress)
    let settings = intent.settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
    let overlayComplete = storedIntent == nil
      || settings.isEmpty
      || progress.settingsDigest == stableTextDigest(settings)
    let embedding = try derivativeSourceEmbeddingStatus(bookID: bookID)
    // On macOS 13 the semantic model is unavailable by definition. The lexical
    // index was already built during import, so there is no unfinished work to
    // keep offering in that environment.
    let embeddingComplete = !intent.embedRequested
      || !embedding.semanticAvailable
      || embedding.isComplete
    return DerivativePreparationSnapshot(
      intent: intent,
      canon: canon,
      embedding: embedding,
      overlayComplete: overlayComplete,
      embeddingComplete: embeddingComplete
    )
  }

  /// Writing a derivative chapter before source preparation is complete silently
  /// turns it into an original chapter: no full canon, no semantic index, and often
  /// no timeline origin. Entry points call this before they start an async job so the
  /// customer gets a stable 409 instead of a draft produced from partial evidence.
  @discardableResult
  func validateDerivativePreparationForWriting(
    bookID: String,
    plan: LongFormPlanResponse
  ) throws -> LongFormPlanResponse {
    guard bookKind(bookID: bookID) == .derivative else { return plan }
    let snapshot = try derivativePreparationSnapshot(bookID: bookID)
    guard snapshot.canon.isComplete else {
      throw InkOSCoreError(
        "原著正典尚未准备完成（已处理 \(snapshot.canon.extractedChapters)/\(snapshot.canon.chapterCount) 章），请先继续原著准备",
        statusCode: 409
      )
    }
    guard snapshot.overlayComplete else {
      throw InkOSCoreError("作者设定尚未登记完成，请先继续原著准备", statusCode: 409)
    }
    guard snapshot.embeddingComplete else {
      throw InkOSCoreError(
        "原著语义索引尚未完成（\(snapshot.embedding.embedded)/\(snapshot.embedding.total) 段），请先继续原著准备",
        statusCode: 409
      )
    }
    // Reading the preparation snapshot can migrate a legacy canon checkpoint and
    // replace the source-owned projection. Use the post-migration plan for both
    // anchor validation and the chapter operation that follows this gate.
    let synchronizedPlan = try synchronizeContinuityProjection(bookID: bookID)
    let timeline = resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: synchronizedPlan.continuity
    )
    guard timeline.isConfigured,
      hasResolvedDerivativeSourceAnchor(timeline, continuity: synchronizedPlan.continuity)
    else {
      throw InkOSCoreError("原著时间锚点尚未绑定，请先完成正典抽取并确认开篇时间", statusCode: 409)
    }
    return synchronizedPlan
  }

  /// Groups the remaining chapters into batches under the character budget.
  ///
  /// A chapter longer than the whole budget becomes its own batch instead of being
  /// cut: a truncated batch silently drops canon, and a canon bible missing facts
  /// is worse than one that costs an extra call.
  func planCanonBatches(
    chapters: [SourceChapter],
    from nextChapterIndex: Int,
    budget: Int = InkOSCore.canonBatchCharacterBudget,
    indexOffset: Int = 0
  ) -> [SourceCanonBatchPlan] {
    let pending = chapters
      .filter { $0.index >= nextChapterIndex }
      .sorted { $0.index < $1.index }
    guard !pending.isEmpty else { return [] }
    var plans: [SourceCanonBatchPlan] = []
    var current: [SourceChapter] = []
    var used = 0
    for chapter in pending {
      if !current.isEmpty, used + chapter.length > budget {
        plans.append(SourceCanonBatchPlan(index: indexOffset + plans.count + 1, chapters: current))
        current = []
        used = 0
      }
      current.append(chapter)
      used += chapter.length
    }
    if !current.isEmpty {
      plans.append(SourceCanonBatchPlan(index: indexOffset + plans.count + 1, chapters: current))
    }
    return plans
  }

  /// Plans the retained preface independently from the numeric resume cursor.
  ///
  /// A legacy checkpoint can have `nextChapterIndex == 58` while index 0 was never
  /// extracted. Putting both into one character-budget pass would create a batch
  /// whose byte range runs from the preface through chapter 58, silently re-reading
  /// all 57 completed chapters. The preface is therefore always its own batch and
  /// the numeric plans continue from the stored cursor.
  func planPendingCanonBatches(
    manifest: SourceManifest,
    progress: SourceCanonProgress
  ) -> [SourceCanonBatchPlan] {
    var plans: [SourceCanonBatchPlan] = []
    if !(progress.prefaceExtracted ?? false),
      let preface = manifest.chapters.first(where: { $0.index == 0 })
    {
      plans.append(SourceCanonBatchPlan(
        index: progress.batches.count + 1,
        chapters: [preface]
      ))
    }
    plans.append(contentsOf: planCanonBatches(
      chapters: manifest.chapters.filter { $0.index > 0 },
      from: progress.nextChapterIndex,
      indexOffset: progress.batches.count + plans.count
    ))
    return plans
  }

  /// Rewrites a raw extraction delta into canon that the derivative book's own
  /// validator accepts.
  ///
  /// Every chapter-scoped field has to be renumbered. The model reads *source*
  /// chapters, so it reports `availableFromChapter: 180` for a fact revealed in
  /// source chapter 180 — and `LongFormContinuity.validated` bounds those fields by
  /// the *derivative* book's `targetChapters`, which is typically a few dozen. Left
  /// alone the pass fails validation on its first knowledge entry.
  ///
  /// Canon describes the world as it stands before the derivative work opens, so
  /// chapter 1 is the correct value rather than a clamp: the facts are available
  /// from the start. Source provenance is preserved in `markers` instead of being
  /// discarded.
  ///
  /// `remove` and `policy` are dropped. Extraction only contributes facts; letting
  /// it delete canon or rewrite policy would hand the model authority over entries
  /// the customer's settings text owns.
  func canonicalizedExtractionDelta(
    _ raw: ContinuityDelta,
    sourceRange: (start: Int, end: Int),
    orderSeed: Int,
    isSourceCanon: Bool = true,
    allowSourceDay: Bool = true
  ) -> ContinuityDelta {
    let marker: String
    if isSourceCanon {
      marker = sourceRange.start == sourceRange.end
        ? "source-chapter-\(sourceRange.start)"
        : "source-chapter-\(sourceRange.start)-\(sourceRange.end)"
    } else {
      marker = "author-settings"
    }
    var delta = ContinuityDelta()
    delta.upsert.immutableCanon = raw.upsert.immutableCanon
    delta.upsert.worldRules = raw.upsert.worldRules
    delta.upsert.entities = raw.upsert.entities
    delta.upsert.knowledgeBoundaries = raw.upsert.knowledgeBoundaries.map { item in
      var markers = item.markers.filter {
        isSourceCanon ? !$0.hasPrefix("chapter-") : !$0.hasPrefix("source-chapter-")
      }
      if !markers.contains(marker) { markers.append(marker) }
      return LongFormKnowledgeBoundary(
        factId: item.factId,
        statement: item.statement,
        allowedKnowers: item.allowedKnowers,
        forbiddenKnowers: item.forbiddenKnowers,
        availableFromChapter: 1,
        revealByChapter: nil,
        markers: markers
      )
    }
    delta.upsert.timeline = raw.upsert.timeline.enumerated().map { offset, item in
      // `order` only carries sort position and must be globally unique. Seed it
      // from the accumulated count so batches do not all restart at the same
      // number; `applyContinuityDelta` nudges any residual collision.
      let sourceChapter: Int? = {
        guard isSourceCanon else { return nil }
        if let supplied = item.sourceChapter,
          (sourceRange.start...sourceRange.end).contains(supplied)
        {
          return supplied
        }
        return sourceRange.start
      }()
      return LongFormTimelineMilestone(
        id: item.id,
        order: orderSeed + offset + 1,
        label: item.label,
        earliestChapter: 1,
        latestChapter: 1,
        immutable: true,
        // Kept, not recomputed: this is the only place the source's own clock
        // survives. `earliestChapter`/`latestChapter` are overwritten with 1
        // above because they mean *derivative* chapters, so without these two
        // fields nothing would remain to say when in the original the event
        // happens, and the timeline would have no events to place.
        // A batch-local day zero is not comparable with another batch's day zero.
        // Keep a day only when the caller verified that this batch directly contains
        // the configured global anchor. Author settings are on the derivative axis,
        // not the source axis, so neither source coordinate belongs on them.
        sourceDay: isSourceCanon && allowSourceDay ? item.sourceDay : nil,
        // The batch's first chapter, not an interpolation across the range.
        // Every extracted milestone comes from a known batch, so this is always
        // populated and monotonic across batches, which is what the fallback
        // classifier needs. Spreading events over the range would invent
        // precision the extraction never reported; within-batch ordering is
        // already carried by `order`.
        sourceChapter: sourceChapter
      )
    }
    delta.upsert.hooks = raw.upsert.hooks.map { item in
      LongFormHookPlan(
        hookId: item.hookId,
        description: item.description,
        openFromChapter: 1,
        resolveByChapter: nil,
        requiredVolumeNumber: nil
      )
    }
    return delta
  }

  private func canonExtractionPrompt(
    title: String,
    batch: SourceCanonBatchPlan,
    body: String,
    known: LongFormContinuity,
    timelineAnchorLabel: String
  ) -> String {
    let knownEntities = known.entities
      .prefix(120)
      .map { "\($0.id)｜\($0.name)｜\($0.type)" }
      .joined(separator: "\n")
    let knownSection = knownEntities.isEmpty
      ? "（暂无已登记实体）"
      : knownEntities
    let anchor = timelineAnchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceDayRule: String
    if anchor.isEmpty {
      sourceDayRule = """
        7. sourceDay：本书尚未配置全局时间锚点，本批所有事件都必须省略 sourceDay。\
        不得把当前批次最早事件当作第 0 天。
        """
    } else {
      sourceDayRule = """
        7. sourceDay：它是相对整部原著事件「\(anchor)」的有符号天数，\
        「\(anchor)」当天才是第 0 天。只有当前正文直接出现该锚点，并且正文明确写出\
        与它之间的天数时才填写；否则省略。不得把当前批次最早事件重置为第 0 天，\
        也不得根据章节号插值猜日期。
        """
    }
    return """
      你在为同人创作建立"原著正典设定库"。下面是原著《\(title)》第 \(batch.startChapter) 至 \
      第 \(batch.endChapter) 章的正文。请只依据这段正文抽取客观设定，不要推测、不要补写、\
      不要评价文笔。

      已登记实体（沿用其中的 id，不要为同一角色另起新 id）：
      \(knownSection)

      只输出严格 JSON，结构如下，字段可以为空数组：
      {
        "upsert": {
          "immutableCanon": [
            {"id":"CANON-...","category":"character|world|timeline|entity|object|knowledge|other",
             "statement":"一句客观事实","value":"可选的具体取值","aliases":["别名"]}
          ],
          "worldRules": [{"id":"RULE-...","statement":"世界运行规则"}],
          "entities": [
            {"id":"ENT-...","name":"名称","type":"character|object|location|faction|concept",
             "owner":"归属","location":"所在","attributes":{"键":"值"},
             "immutableAttributes":["不可变属性键"]}
          ],
          "knowledgeBoundaries": [
            {"factId":"KNOW-...","statement":"某个秘密","allowedKnowers":["知情人"],
             "forbiddenKnowers":["不知情人"]}
          ],
          "timeline": [{"id":"TL-...","label":"事件","order":1,"sourceDay":0,"sourceChapter":\(batch.startChapter)}],
          "hooks": [{"hookId":"HOOK-...","description":"尚未收束的伏笔"}]
        }
      }

      硬性要求：
      1. id 必须稳定可复现：同一事实/人物在不同批次要给出同一个 id。用内容要点构造，\
      不要用批次号或随机串。
      2. 不要输出 remove、policy 字段，也不要输出同人侧的章节号字段\
      （availableFromChapter、openFromChapter、earliestChapter、latestChapter \
      由系统统一赋值）。timeline 里的 sourceDay / sourceChapter 是例外，它们描述\
      的是原著自己的时间，必须按第 6、7 条填写。
      3. immutableAttributes 只填真正不可改动的（如血型、出生地）；不确定就留空数组。
      4. 只写正文明确写出的内容。正文没写的关系、动机、结局，一律不要写。
      5. 人物用 entities，不要塞进 immutableCanon；世界规则用 worldRules。
      6. sourceChapter：该事件发生在原著第几章，取 \(batch.startChapter) 到 \
      \(batch.endChapter) 之间的整数。这一段正文里的事件必须落在这个区间内。
      \(sourceDayRule)
      8. 每个数组最多 \(Self.canonItemsPerArray) 项，只保留最重要的：会影响后续剧情、\
      会被别的章节引用的那些。次要细节（器物尺寸、路人姓名、一次性场景）不要收录。\
      statement / description 每条不超过 60 字，不要展开成段落。
      9. 输出必须是完整闭合的 JSON。宁可少写几项，也不要写到一半被截断。

      原著正文：
      \(body)
      """
  }

  /// Extracts the canon bible from the imported original work.
  ///
  /// Batched by character budget, checkpointed after every batch, and resumable:
  /// a million-character source takes many calls and any of them can fail, so the
  /// pass records `nextChapterIndex` before returning and a re-invocation continues
  /// from there rather than starting over.
  ///
  /// - Parameter maxBatches: caps the calls one invocation makes, so the UI can
  ///   extract incrementally and show progress. Zero or negative means no cap.
  @discardableResult
  func extractDerivativeCanon(
    bookID: String,
    maxBatches: Int = 0
  ) async throws -> SourceCanonStatus {
    let manifest = try loadSourceManifest(bookID: bookID)
    _ = try validateSourceSearchIndex(bookID: bookID, manifest: manifest)
    var progress = try repairedCanonProgress(bookID: bookID, manifest: manifest)
    guard !progress.isComplete else {
      recordDebug(scope: "canon", message: "canon.extract.already_complete", data: [
        "bookId": bookID, "chapterCount": manifest.chapterCount,
      ])
      return canonStatus(progress)
    }

    var plan = try synchronizeContinuityProjection(bookID: bookID)
    let sourceTitle = bookSourceTitle(bookID: bookID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let timelineAnchor = loadDerivativeTimeline(bookID: bookID).anchorLabel
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceURL = try sourceDirectoryURL(bookID).appendingPathComponent("original.txt")
    guard let text = try? String(contentsOf: sourceURL, encoding: .utf8) else {
      throw InkOSCoreError("原著正文缺失，请重新导入", statusCode: 404)
    }
    let ns = text as NSString

    var plans = planPendingCanonBatches(manifest: manifest, progress: progress)
    if maxBatches > 0, plans.count > maxBatches {
      plans = Array(plans.prefix(maxBatches))
    }
    guard !plans.isEmpty else { return canonStatus(progress) }

    for batch in plans {
      guard let first = batch.chapters.first, let last = batch.chapters.last else { continue }
      let start = first.offset
      let end = last.offset + last.length
      guard start >= 0, end <= ns.length, start < end else {
        throw InkOSCoreError("原著章节偏移越界，请重新导入原著", statusCode: 503)
      }
      let body = ns.substring(with: NSRange(location: start, length: end - start))
      let prompt = canonExtractionPrompt(
        title: sourceTitle.isEmpty ? bookID : sourceTitle,
        batch: batch,
        body: body,
        known: plan.continuity,
        timelineAnchorLabel: timelineAnchor
      )

      var extracted: ContinuityDelta?
      var model = ""
      var lastError: Error?
      for attempt in 1...Self.canonBatchAttempts {
        do {
          let result = try await requestLLM(
            prompt: prompt,
            role: .extraction,
            json: true,
            // A fresh sample on the retry: at the configured temperature the model
            // re-emits the same malformed payload otherwise.
            overrideTemperature: attempt == 1 ? nil : 0.4,
            timeout: 600
          )
          model = result.model
          guard let object = parseJSONObject(result.content) else {
            // Truncation and malformed output need different fixes — raise the token
            // ceiling versus reword the prompt — so they must not share one message.
            // A reasoning model spends part of `max_tokens` thinking before it writes
            // any JSON, so a budget that fits the answer can still cut it off: the
            // first 诡秘之主 batch burned 12 056 reasoning tokens and lost the JSON at
            // character 12 972 of a well-formed object.
            if result.finishReason == "length" {
              throw InkOSCoreError(
                "原著抽取被输出上限截断（已输出 \(result.content.count) 字符，未闭合）。请在设置里提高最大输出 tokens，或改用非推理模型抽取",
                statusCode: 422
              )
            }
            throw InkOSCoreError(
              "原著抽取返回的不是 JSON（finishReason=\(result.finishReason ?? "未知")，输出 \(result.content.count) 字符）",
              statusCode: 422
            )
          }
          // `chapterNumber: 1` supplies the defaults for any chapter field the
          // model omitted; `canonicalizedExtractionDelta` then overrides every
          // one of them, so the value only has to be in range.
          let normalized = try normalizedConsistencyDelta(
            object,
            chapterNumber: 1,
            allowSourceCoordinates: true
          )
          extracted = canonicalizedExtractionDelta(
            normalized,
            sourceRange: (batch.startChapter, batch.endChapter),
            orderSeed: progress.delta.upsert.timeline.count,
            // The prompt defines sourceDay against one global anchor. Defensively
            // discard it when that anchor is not present in the supplied source
            // slice, even if the model emitted a batch-local zero anyway.
            allowSourceDay: !timelineAnchor.isEmpty && body.contains(timelineAnchor)
          )
          break
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          lastError = error
          recordDebug(scope: "canon", message: "canon.extract.batch_failed", level: "warning", data: [
            "bookId": bookID,
            "batch": batch.index,
            "attempt": attempt,
            "error": error.localizedDescription,
          ])
        }
      }

      guard var delta = extracted else {
        // The checkpoint already holds every completed batch, so surfacing the
        // failure here loses only this batch.
        try saveCanonProgress(progress)
        throw InkOSCoreError(
          "原著第\(batch.startChapter)-\(batch.endChapter)章抽取失败：\(lastError?.localizedDescription ?? "未知错误")；已保存前面批次的进度，可再次运行继续",
          statusCode: 502
        )
      }

      let entityMerge = canonicalCanonEntities(
        existing: progress.delta.upsert.entities,
        additions: delta.upsert.entities
      )
      delta.upsert.entities = entityMerge.additions
      let mergedDelta = mergedCanonDelta(progress.delta, delta)
      let completedBatch = SourceCanonBatch(
        index: batch.index,
        startChapter: batch.startChapter,
        endChapter: batch.endChapter,
        characterCount: batch.characterCount,
        canonCount: delta.upsert.immutableCanon.count,
        worldRuleCount: delta.upsert.worldRules.count,
        entityCount: delta.upsert.entities.count,
        knowledgeCount: delta.upsert.knowledgeBoundaries.count,
        timelineCount: delta.upsert.timeline.count,
        hookCount: delta.upsert.hooks.count,
        model: model,
        completedAt: isoTimestamp()
      )

      // Projection first, checkpoint second. If projection validation rejects this
      // batch, the persisted cursor still points at it and a resume cannot skip
      // canon that never landed. If the later checkpoint write fails, re-applying
      // the keyed delta is idempotent.
      plan = try mergeCanonIntoBaseContinuity(
        bookID: bookID,
        delta: delta,
        source: "原著正典抽取（第\(batch.startChapter)-\(batch.endChapter)章）"
      )
      progress.delta = mergedDelta
      progress.nextChapterIndex = Swift.max(progress.nextChapterIndex, batch.endChapter + 1)
      if batch.chapters.contains(where: { $0.index == 0 }) {
        progress.prefaceExtracted = true
      }
      progress.batches.append(completedBatch)
      progress.updatedAt = isoTimestamp()
      try saveCanonProgress(progress)
      recordCanonEntityTypeConflicts(entityMerge.typeConflicts, bookID: bookID, batch: batch.index)
      recordDebug(scope: "canon", message: "canon.extract.batch", data: [
        "bookId": bookID,
        "batch": batch.index,
        "startChapter": batch.startChapter,
        "endChapter": batch.endChapter,
        "characters": batch.characterCount,
        "entities": delta.upsert.entities.count,
        "canon": delta.upsert.immutableCanon.count,
      ])
    }
    return canonStatus(progress)
  }

  /// Extracts the customer's settings text as the authoritative overlay.
  ///
  /// Written to `manualOverlay`, which `synchronizeContinuityProjection` applies
  /// last and with `allowImmutableChanges: true`. That ordering is the point: where
  /// the settings text and the source disagree, the settings text wins.
  @discardableResult
  func extractDerivativeSettingsOverlay(
    bookID: String,
    settingsText: String
  ) async throws -> SourceCanonStatus {
    let trimmed = settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw InkOSCoreError("设定文本为空", statusCode: 400)
    }
    let manifest = try loadSourceManifest(bookID: bookID)
    _ = try validateSourceSearchIndex(bookID: bookID, manifest: manifest)
    var progress = try repairedCanonProgress(bookID: bookID, manifest: manifest)
    let digest = stableTextDigest(trimmed)
    guard progress.settingsDigest != digest else {
      return canonStatus(progress)
    }

    let plan = try synchronizeContinuityProjection(bookID: bookID)
    let knownEntities = plan.continuity.entities
      .prefix(120)
      .map { "\($0.id)｜\($0.name)｜\($0.type)" }
      .joined(separator: "\n")
    let prompt = """
      下面是同人作品的作者设定文本。它的权威性高于原著抽取结果：两者冲突时以它为准。\
      请把其中的客观设定抽成 JSON。

      已登记实体（同一对象请沿用其 id）：
      \(knownEntities.isEmpty ? "（暂无已登记实体）" : knownEntities)

      只输出严格 JSON：
      {
        "upsert": {
          "immutableCanon": [{"id":"CANON-...","category":"character|world|other","statement":"..."}],
          "worldRules": [{"id":"RULE-...","statement":"..."}],
          "entities": [{"id":"ENT-...","name":"...","type":"character|object|location|faction|concept"}],
          "knowledgeBoundaries": [{"factId":"KNOW-...","statement":"...","allowedKnowers":[]}],
          "timeline": [{"id":"TL-...","label":"..."}],
          "hooks": [{"hookId":"HOOK-...","description":"..."}]
        }
      }

      硬性要求：
      1. 不要输出 remove、policy 和任何章节号字段。
      2. 只写设定文本明确写出的内容，不要替作者补设定。
      3. id 稳定可复现，按内容要点构造。

      设定文本：
      \(trimmed)
      """

    let result = try await requestLLM(
      prompt: prompt,
      role: .extraction,
      json: true,
      timeout: 600
    )
    guard let object = parseJSONObject(result.content) else {
      throw InkOSCoreError("设定抽取返回的不是 JSON", statusCode: 422)
    }
    let normalized = try normalizedConsistencyDelta(object, chapterNumber: 1)
    // Ordered after the source timeline so an overlay milestone does not collide
    // with one the extraction pass already placed.
    let overlay = canonicalizedExtractionDelta(
      normalized,
      sourceRange: (1, manifest.chapterCount),
      orderSeed: progress.delta.upsert.timeline.count + 10_000,
      isSourceCanon: false,
      allowSourceDay: false
    )
    _ = try mergeCanonIntoManualOverlay(bookID: bookID, delta: overlay)

    progress.settingsDigest = digest
    progress.updatedAt = isoTimestamp()
    try saveCanonProgress(progress)
    recordDebug(scope: "canon", message: "canon.settings_overlay", data: [
      "bookId": bookID,
      "entities": overlay.upsert.entities.count,
      "canon": overlay.upsert.immutableCanon.count,
      "worldRules": overlay.upsert.worldRules.count,
    ])
    return canonStatus(progress)
  }

  func derivativeCanonStatus(bookID: String) throws -> SourceCanonStatus {
    let manifest = try loadSourceManifest(bookID: bookID)
    _ = try validateSourceSearchIndex(bookID: bookID, manifest: manifest)
    return canonStatus(try repairedCanonProgress(bookID: bookID, manifest: manifest))
  }

  // MARK: - Internals

  /// Repairs legacy checkpoint semantics before status or resume uses them.
  /// Projection replacement lands first; an interruption before the progress write
  /// simply reruns the same keyed, idempotent repair on the next call.
  private func repairedCanonProgress(
    bookID: String,
    manifest: SourceManifest
  ) throws -> SourceCanonProgress {
    var progress = try loadCanonProgress(bookID: bookID, manifest: manifest)
    let entityMerge = canonicalCanonEntities(
      existing: progress.delta.upsert.entities,
      additions: []
    )
    let entitiesChanged = entityMerge.entities != progress.delta.upsert.entities
    let coordinatesChanged = progress.sourceCoordinatesVersion
      != SourceCanonProgress.currentSourceCoordinatesVersion
    guard entitiesChanged || coordinatesChanged else { return progress }

    progress.delta.upsert.entities = entityMerge.entities
    var clearedSourceDays = 0
    if coordinatesChanged {
      let configured = loadDerivativeTimeline(bookID: bookID)
      let anchorLabel = configured.anchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      let matchedAnchor = progress.delta.upsert.timeline.first { milestone in
        guard !anchorLabel.isEmpty else { return false }
        return milestone.label == anchorLabel
          || milestone.label.contains(anchorLabel)
          || anchorLabel.contains(milestone.label)
      }
      let anchorChapter = configured.anchorSourceChapter ?? matchedAnchor?.sourceChapter
      let anchorBatch = anchorChapter.flatMap { chapter in
        progress.batches.first { $0.startChapter <= chapter && chapter <= $0.endChapter }
      }
      progress.delta.upsert.timeline = progress.delta.upsert.timeline.map { item in
        let keepDay = item.sourceChapter.map { chapter in
          guard let anchorBatch else { return false }
          return anchorBatch.startChapter <= chapter && chapter <= anchorBatch.endChapter
        } ?? false
        if item.sourceDay != nil, !keepDay { clearedSourceDays += 1 }
        return LongFormTimelineMilestone(
          id: item.id,
          order: item.order,
          label: item.label,
          earliestChapter: item.earliestChapter,
          latestChapter: item.latestChapter,
          immutable: item.immutable,
          sourceDay: keepDay ? item.sourceDay : nil,
          sourceChapter: item.sourceChapter
        )
      }
      progress.sourceCoordinatesVersion = SourceCanonProgress.currentSourceCoordinatesVersion
    }
    progress.updatedAt = isoTimestamp()
    _ = try replaceCanonBaseContinuity(
      bookID: bookID,
      delta: progress.delta,
      source: "原著正典旧 checkpoint 修复"
    )
    try saveCanonProgress(progress)
    recordCanonEntityTypeConflicts(entityMerge.typeConflicts, bookID: bookID, batch: nil)
    recordDebug(scope: "canon", message: "canon.progress.migrated", data: [
      "bookId": bookID,
      "entitiesDeduplicated": entitiesChanged,
      "sourceDaysCleared": clearedSourceDays,
    ])
    return progress
  }

  private func canonStatus(_ progress: SourceCanonProgress) -> SourceCanonStatus {
    SourceCanonStatus(
      chapterCount: progress.chapterCount,
      extractedChapters: Swift.min(progress.nextChapterIndex - 1, progress.chapterCount),
      batchCount: progress.batches.count,
      isComplete: progress.isComplete,
      canonCount: progress.delta.upsert.immutableCanon.count,
      worldRuleCount: progress.delta.upsert.worldRules.count,
      entityCount: progress.delta.upsert.entities.count,
      knowledgeCount: progress.delta.upsert.knowledgeBoundaries.count,
      timelineCount: progress.delta.upsert.timeline.count,
      hookCount: progress.delta.upsert.hooks.count,
      hasSettingsOverlay: progress.settingsDigest != nil,
      updatedAt: progress.batches.isEmpty && progress.settingsDigest == nil
        ? nil
        : progress.updatedAt
    )
  }

  private func saveCanonProgress(_ progress: SourceCanonProgress) throws {
    let url = try canonProgressURL(progress.bookId)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try atomicWrite(encoder.encode(progress), to: url)
  }

  /// Unions two extraction deltas. Most fact kinds are keyed by their stable IDs;
  /// entities additionally use a normalized name because extraction models often
  /// rename `ENT-*` across batches for the same person or object.
  func mergedCanonDelta(_ base: ContinuityDelta, _ addition: ContinuityDelta) -> ContinuityDelta {
    var merged = base
    merged.upsert.immutableCanon = mergeByKey(
      merged.upsert.immutableCanon, addition.upsert.immutableCanon, key: \.id)
    merged.upsert.worldRules = mergeByKey(
      merged.upsert.worldRules, addition.upsert.worldRules, key: \.id)
    merged.upsert.entities = canonicalCanonEntities(
      existing: merged.upsert.entities,
      additions: addition.upsert.entities
    ).entities
    merged.upsert.knowledgeBoundaries = mergeByKey(
      merged.upsert.knowledgeBoundaries, addition.upsert.knowledgeBoundaries, key: \.factId)
    merged.upsert.timeline = mergeByKey(
      merged.upsert.timeline, addition.upsert.timeline, key: \.id)
    merged.upsert.hooks = mergeByKey(
      merged.upsert.hooks, addition.upsert.hooks, key: \.hookId)
    return merged
  }

  private func mergeByKey<T>(
    _ base: [T],
    _ addition: [T],
    key: KeyPath<T, String>
  ) -> [T] {
    var result = base
    var positions: [String: Int] = [:]
    for (index, item) in result.enumerated() { positions[item[keyPath: key]] = index }
    for item in addition {
      let identity = item[keyPath: key]
      if let index = positions[identity] {
        result[index] = item
      } else {
        positions[identity] = result.count
        result.append(item)
      }
    }
    return result
  }

  private struct CanonEntityTypeConflict {
    let name: String
    let canonicalID: String
    let canonicalType: String
    let discardedID: String
    let discardedType: String
  }

  private struct CanonEntityMerge {
    let entities: [LongFormEntity]
    /// Canonical entities touched by the incoming batch, with their stable IDs.
    let additions: [LongFormEntity]
    let typeConflicts: [CanonEntityTypeConflict]
  }

  /// Collapses same-name source entities without relying on the model to keep an
  /// arbitrary generated ID stable. The first recorded canonical entry owns both
  /// the ID and the type; later evidence can fill missing attributes but cannot
  /// turn an object into a character (or vice versa).
  private func canonicalCanonEntities(
    existing: [LongFormEntity],
    additions: [LongFormEntity]
  ) -> CanonEntityMerge {
    var entities: [LongFormEntity] = []
    var namePositions: [String: Int] = [:]
    var idPositions: [String: Int] = [:]
    var touched: [String: Int] = [:]
    var conflicts: [CanonEntityTypeConflict] = []

    func merge(_ canonical: LongFormEntity, _ candidate: LongFormEntity) -> LongFormEntity {
      var attributes = canonical.attributes
      for (key, value) in candidate.attributes where !value.isEmpty {
        attributes[key] = value
      }
      return LongFormEntity(
        id: canonical.id,
        name: canonical.name,
        type: canonical.type,
        owner: candidate.owner ?? canonical.owner,
        location: candidate.location ?? canonical.location,
        attributes: attributes,
        immutableOwner: canonical.immutableOwner || candidate.immutableOwner,
        immutableLocation: canonical.immutableLocation || candidate.immutableLocation,
        immutableAttributes: Array(Set(canonical.immutableAttributes + candidate.immutableAttributes)).sorted()
      )
    }

    // A model can reuse an ID for an unrelated name. Keep the requested prefix
    // so the remap is inspectable, but never use a random suffix: a later resume
    // must produce the same identity from the same ordered canon evidence.
    func freeEntityID(basedOn requested: String) -> String {
      let base = requested.isEmpty ? "ENT" : requested
      guard idPositions[base] != nil else { return base }
      var suffix = 2
      while idPositions["\(base)-\(suffix)"] != nil {
        suffix += 1
      }
      return "\(base)-\(suffix)"
    }

    func absorb(_ candidate: LongFormEntity, isAddition: Bool) {
      let name = normalizedCanonEntityName(candidate.name)
      // Names are the primary identity for canon. Empty names are not useful
      // identities, so they fall through to the ID-only path instead of merging
      // every malformed nameless model object together.
      if !name.isEmpty, let nameIndex = namePositions[name] {
        let canonical = entities[nameIndex]
        if canonical.type != candidate.type {
          conflicts.append(CanonEntityTypeConflict(
            name: canonical.name,
            canonicalID: canonical.id,
            canonicalType: canonical.type,
            discardedID: candidate.id,
            discardedType: candidate.type
          ))
        }
        entities[nameIndex] = merge(canonical, candidate)
        // Do not overwrite an unrelated holder's ID with an alias to this name.
        // Future different-name evidence using that ID must be remapped too.
        if isAddition { touched[canonical.id] = nameIndex }
        return
      }

      if name.isEmpty, let idIndex = idPositions[candidate.id] {
        let canonical = entities[idIndex]
        if canonical.type != candidate.type {
          conflicts.append(CanonEntityTypeConflict(
            name: canonical.name,
            canonicalID: canonical.id,
            canonicalType: canonical.type,
            discardedID: candidate.id,
            discardedType: candidate.type
          ))
        }
        entities[idIndex] = merge(canonical, candidate)
        if isAddition { touched[canonical.id] = idIndex }
        return
      }

      if idPositions[candidate.id] != nil {
        // The requested ID is already owned by a different name. Preserve both
        // entities and assign the newcomer a deterministic free ID.
        let remappedID = freeEntityID(basedOn: candidate.id)
        let remapped = candidate.reidentified(as: remappedID)
        let newIndex = entities.count
        entities.append(remapped)
        if !name.isEmpty { namePositions[name] = newIndex }
        idPositions[remappedID] = newIndex
        if isAddition { touched[remappedID] = newIndex }
        return
      }

      let newIndex = entities.count
      entities.append(candidate)
      if !name.isEmpty { namePositions[name] = newIndex }
      idPositions[candidate.id] = newIndex
      if isAddition { touched[candidate.id] = newIndex }
    }

    for entity in existing { absorb(entity, isAddition: false) }
    for entity in additions { absorb(entity, isAddition: true) }
    let normalizedAdditions = touched.values.sorted().map { entities[$0] }
    return CanonEntityMerge(
      entities: entities,
      additions: normalizedAdditions,
      typeConflicts: conflicts
    )
  }

  private func normalizedCanonEntityName(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
  }

  private func recordCanonEntityTypeConflicts(
    _ conflicts: [CanonEntityTypeConflict],
    bookID: String,
    batch: Int?
  ) {
    for conflict in conflicts {
      var data: [String: Any] = [
        "bookId": bookID,
        "name": conflict.name,
        "canonicalID": conflict.canonicalID,
        "canonicalType": conflict.canonicalType,
        "discardedID": conflict.discardedID,
        "discardedType": conflict.discardedType,
      ]
      if let batch { data["batch"] = batch }
      recordDebug(
        scope: "canon",
        message: "canon.entity.type_conflict",
        level: "warning",
        data: data
      )
    }
  }

  private func stableTextDigest(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Data(text.utf8) {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
  }
}
