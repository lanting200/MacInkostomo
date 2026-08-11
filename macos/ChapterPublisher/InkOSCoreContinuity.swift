import Foundation

struct ContinuityDeltaItems: Codable, Equatable, Sendable {
  var immutableCanon: [LongFormImmutableCanon] = []
  var worldRules: [LongFormWorldRule] = []
  var entities: [LongFormEntity] = []
  var knowledgeBoundaries: [LongFormKnowledgeBoundary] = []
  var timeline: [LongFormTimelineMilestone] = []
  var hooks: [LongFormHookPlan] = []
}

struct ContinuityDeltaRemovals: Codable, Equatable, Sendable {
  var immutableCanon: [String] = []
  var worldRules: [String] = []
  var entities: [String] = []
  var knowledgeBoundaries: [String] = []
  var timeline: [String] = []
  var hooks: [String] = []
}

struct ContinuityDelta: Codable, Equatable, Sendable {
  var upsert = ContinuityDeltaItems()
  var remove = ContinuityDeltaRemovals()
  var policy: LongFormContinuityPolicy?
}

struct ContinuityChapterProjection: Codable, Equatable, Sendable {
  let chapterNumber: Int
  let fingerprint: String
  let delta: ContinuityDelta
}

struct ContinuityProjection: Codable, Equatable, Sendable {
  let version: Int
  var baseContinuity: LongFormContinuity
  var chapters: [ContinuityChapterProjection]
  var manualOverlay: ContinuityDelta
  var continuity: LongFormContinuity
  var updatedAt: String
}

struct ContinuityCheckpointChapter: Codable, Equatable, Sendable {
  let chapterNumber: Int
  let fingerprint: String
}

struct ContinuityVolumeCheckpoint: Codable, Equatable, Sendable {
  let version: Int
  let bookId: String
  let volumeNumber: Int
  let startChapter: Int
  let endChapter: Int
  let planRevision: Int
  let fingerprint: String
  let chapters: [ContinuityCheckpointChapter]
  let continuity: LongFormContinuity
  let createdAt: String
  let updatedAt: String
}

extension InkOSCore {
  static let continuityProjectionVersion = 1

  func synchronizeContinuityProjection(bookID: String) throws -> LongFormPlanResponse {
    let planURL = try existingBookURL(bookID).appendingPathComponent("long-form-plan.json")
    let current = try readLongFormPlan(at: planURL)
    let projectionURL = try continuityProjectionURL(bookID: bookID)
    let existing = try loadContinuityProjection(at: projectionURL)
    var base = existing?.baseContinuity ?? current.continuity
    base.policy.requireConsistencyDelta = true
    let chapters = try approvedContinuityDeltas(bookID: bookID)
    var projected = base
    for chapter in chapters {
      try applyContinuityDelta(
        chapter.delta,
        to: &projected,
        source: "第\(chapter.chapterNumber)章"
      )
    }
    let overlay = existing?.manualOverlay ?? ContinuityDelta()
    try applyContinuityDelta(overlay, to: &projected, source: "人工连续性覆盖", allowImmutableChanges: true)
    projected.policy.requireConsistencyDelta = true
    projected = try projected.validated(
      targetChapters: current.plan.targetChapters,
      volumeCount: current.constraints.volumeCount
    )

    var response = current
    let planChanged = current.continuity != projected
    if planChanged {
      response = try makeLongFormPlan(
        bookID: bookID,
        constraints: current.constraints,
        continuity: projected,
        revision: current.revision + 1,
        createdAt: current.createdAt
      )
      try atomicWrite(encoder.encode(response), to: planURL)
    }

    let projectionChanged = existing?.baseContinuity != base
      || existing?.chapters != chapters
      || existing?.manualOverlay != overlay
      || existing?.continuity != projected
    if existing == nil || projectionChanged {
      let projection = ContinuityProjection(
        version: Self.continuityProjectionVersion,
        baseContinuity: base,
        chapters: chapters,
        manualOverlay: overlay,
        continuity: projected,
        updatedAt: isoTimestamp()
      )
      try atomicWrite(encoder.encode(projection), to: projectionURL)
    }

    if planChanged || existing == nil || projectionChanged {
      recordDebug(scope: "continuity", message: "continuity.projection.synchronized", data: [
        "bookId": bookID,
        "revision": response.revision,
        "approvedChapterDeltas": chapters.count,
        "planChanged": planChanged,
        "immutableCanon": projected.immutableCanon.count,
        "worldRules": projected.worldRules.count,
        "entities": projected.entities.count,
        "knowledgeBoundaries": projected.knowledgeBoundaries.count,
        "timeline": projected.timeline.count,
        "hooks": projected.hooks.count,
      ])
    }
    try synchronizeVolumeCheckpoints(
      bookID: bookID,
      plan: response,
      base: base,
      chapters: chapters,
      overlay: overlay
    )
    return response
  }

  func continuityProjectionForManualEdit(
    bookID: String,
    current: LongFormPlanResponse,
    requested rawRequested: LongFormContinuity,
    targetChapters: Int,
    volumeCount: Int
  ) throws -> ContinuityProjection {
    let projectionURL = try continuityProjectionURL(bookID: bookID)
    let existing = try loadContinuityProjection(at: projectionURL)
    var base = existing?.baseContinuity ?? current.continuity
    base.policy.requireConsistencyDelta = true
    let chapters = try approvedContinuityDeltas(bookID: bookID)
    var automatic = base
    for chapter in chapters {
      try applyContinuityDelta(
        chapter.delta,
        to: &automatic,
        source: "第\(chapter.chapterNumber)章"
      )
    }
    var requested = rawRequested
    requested.policy.requireConsistencyDelta = true
    requested = try requested.validated(targetChapters: targetChapters, volumeCount: volumeCount)
    let overlay = makeContinuityOverlay(from: automatic, to: requested)
    var verification = automatic
    try applyContinuityDelta(
      overlay,
      to: &verification,
      source: "人工连续性覆盖",
      allowImmutableChanges: true
    )
    verification.policy.requireConsistencyDelta = true
    verification = try verification.validated(
      targetChapters: targetChapters,
      volumeCount: volumeCount
    )
    return ContinuityProjection(
      version: Self.continuityProjectionVersion,
      baseContinuity: base,
      chapters: chapters,
      manualOverlay: overlay,
      continuity: verification,
      updatedAt: isoTimestamp()
    )
  }

  func normalizedConsistencyDelta(
    _ raw: [String: Any],
    chapterNumber: Int
  ) throws -> ContinuityDelta {
    let upsertSource = raw["upsert"] as? [String: Any] ?? raw
    let removeSource = raw["remove"] as? [String: Any] ?? [:]
    var delta = ContinuityDelta()

    delta.upsert.immutableCanon = try anyArray(upsertSource["immutableCanon"]).enumerated().map {
      try normalizedCanon($0.element, chapterNumber: chapterNumber, index: $0.offset)
    }
    delta.upsert.worldRules = try anyArray(upsertSource["worldRules"]).enumerated().map {
      try normalizedWorldRule($0.element, chapterNumber: chapterNumber, index: $0.offset)
    }
    delta.upsert.entities = try anyArray(upsertSource["entities"]).enumerated().map {
      try normalizedEntity($0.element, chapterNumber: chapterNumber, index: $0.offset, defaultType: "character")
    }
    let legacyObjects = try anyArray(upsertSource["objects"]).enumerated().map {
      try normalizedEntity($0.element, chapterNumber: chapterNumber, index: $0.offset, defaultType: "object")
    }
    delta.upsert.entities.append(contentsOf: legacyObjects)

    let knowledgeValues = anyArray(upsertSource["knowledgeBoundaries"]).isEmpty
      ? anyArray(upsertSource["knowledge"])
      : anyArray(upsertSource["knowledgeBoundaries"])
    delta.upsert.knowledgeBoundaries = try knowledgeValues.enumerated().map {
      try normalizedKnowledge($0.element, chapterNumber: chapterNumber, index: $0.offset)
    }
    delta.upsert.timeline = try anyArray(upsertSource["timeline"]).enumerated().map {
      try normalizedTimeline($0.element, chapterNumber: chapterNumber, index: $0.offset)
    }
    delta.upsert.hooks = try anyArray(upsertSource["hooks"]).enumerated().map {
      try normalizedHook($0.element, chapterNumber: chapterNumber, index: $0.offset)
    }

    delta.remove.immutableCanon = removalIDs(removeSource["immutableCanon"], kind: "canon")
    delta.remove.worldRules = removalIDs(removeSource["worldRules"], kind: "rule")
    delta.remove.entities = removalIDs(removeSource["entities"], kind: "entity")
    delta.remove.knowledgeBoundaries = removalIDs(removeSource["knowledgeBoundaries"], kind: "knowledge")
    delta.remove.timeline = removalIDs(removeSource["timeline"], kind: "timeline")
    delta.remove.hooks = removalIDs(removeSource["hooks"], kind: "hook")
    return delta
  }

  func chapterConsistencyDelta(bookID: String, chapterNumber: Int) throws -> ContinuityDelta {
    let url = try existingBookURL(bookID).appendingPathComponent(
      String(format: "story/runtime/chapter-%04d.consistency.json", chapterNumber)
    )
    guard fileManager.fileExists(atPath: url.path) else {
      throw InkOSCoreError("本章缺少 consistencyDelta，请先重新生成或修订后再审核", statusCode: 409)
    }
    let object = try readObject(url)
    guard let rawDelta = object["delta"] as? [String: Any] else {
      throw InkOSCoreError("本章 consistencyDelta 格式错误", statusCode: 422)
    }
    return try normalizedConsistencyDelta(rawDelta, chapterNumber: chapterNumber)
  }

  func validateChapterSequence(
    bookID: String,
    chapterNumber: Int,
    plan: LongFormPlanResponse,
    operation: String
  ) throws {
    guard plan.plan.chapters.contains(where: { $0.number == chapterNumber }) else {
      throw InkOSCoreError("第 \(chapterNumber) 章超出长篇计划范围", statusCode: 409)
    }
    guard plan.continuity.policy.requireContinuousVolumes, chapterNumber > 1 else { return }
    let stateBook = try stateBookObject(bookID: bookID, allowMissing: true)
    let records = try readChapterRecords(bookID: bookID, stateBook: stateBook)
    var byNumber: [Int: String] = [:]
    for record in records {
      guard let number = integer(record["number"]) else { continue }
      byNumber[number] = string(record["status"])
    }
    for required in 1..<chapterNumber {
      guard let status = byNumber[required] else {
        throw InkOSCoreError("连续写作策略已开启：第 \(required) 章缺失，不能\(operation)第 \(chapterNumber) 章", statusCode: 409)
      }
      guard ["approved", "published"].contains(status) else {
        throw InkOSCoreError(
          "连续写作策略已开启：第 \(required) 章尚未通过审核，不能\(operation)第 \(chapterNumber) 章",
          statusCode: 409
        )
      }
    }
  }

  func validateCandidateContinuity(
    bookID: String,
    chapterNumber: Int,
    delta: ContinuityDelta,
    excludingChapter: Int? = nil
  ) throws -> LongFormContinuity {
    let current = try synchronizeContinuityProjection(bookID: bookID)
    let projectionURL = try continuityProjectionURL(bookID: bookID)
    let projection = try loadContinuityProjection(at: projectionURL)
    var before = projection?.baseContinuity ?? current.continuity
    let approved = try approvedContinuityDeltas(bookID: bookID)
      .filter { $0.chapterNumber != excludingChapter }
    for chapter in approved {
      try applyContinuityDelta(
        chapter.delta,
        to: &before,
        source: "第\(chapter.chapterNumber)章"
      )
    }
    try applyContinuityDelta(
      projection?.manualOverlay ?? ContinuityDelta(),
      to: &before,
      source: "人工连续性覆盖",
      allowImmutableChanges: true
    )
    before.policy.requireConsistencyDelta = true

    if !before.policy.allowUnplannedEntities {
      for entity in delta.upsert.entities {
        let known = current.continuity.entities.contains {
          $0.id == entity.id
            || normalizedContinuityName($0.name) == normalizedContinuityName(entity.name)
        }
        if !known {
          throw continuityConflict(
            "第\(chapterNumber)章候选差量",
            "未规划实体 \(entity.name) 被策略禁止；请先在连续性设置中登记"
          )
        }
      }
    }
    try validateRemovalTargets(delta.remove, in: before, chapterNumber: chapterNumber)
    var after = before
    try applyContinuityDelta(
      delta,
      to: &after,
      source: "第\(chapterNumber)章候选差量",
      strictIdentity: true
    )
    after.policy.requireConsistencyDelta = true
    return try after.validated(
      targetChapters: current.plan.targetChapters,
      volumeCount: current.constraints.volumeCount
    )
  }

  /// Merges extracted canon into the projection's `baseContinuity`.
  ///
  /// `baseContinuity` rather than a new field: it is the layer chapter deltas and
  /// the manual overlay are already applied *on top of*, which is exactly where
  /// source canon belongs. Adding a fourth layer would need a projection schema
  /// migration and a matching change in every replay site.
  ///
  /// Idempotent as long as the extraction model keeps its IDs stable — every entry
  /// is keyed, so re-applying the same delta upserts in place. A model swap that
  /// renames IDs for the same facts will add duplicates; that is a re-extraction,
  /// not a resume, and clearing `canon-progress.json` is the way to redo it.
  ///
  /// - Parameter allowImmutableChanges: true because extraction is authoritative
  ///   over the canon it produced. A second pass that revises an immutable fact it
  ///   wrote itself must be able to land, or the pass deadlocks on its own output.
  @discardableResult
  func mergeCanonIntoBaseContinuity(
    bookID: String,
    delta: ContinuityDelta,
    source: String
  ) throws -> LongFormPlanResponse {
    try mutateContinuityProjection(bookID: bookID) { projection, _ in
      try self.applyContinuityDelta(
        delta,
        to: &projection.baseContinuity,
        source: source,
        allowImmutableChanges: true
      )
    }
  }

  /// Removes facts extracted from a replaced original while preserving the layers
  /// that belong to this derivative work: approved chapter deltas, the customer's
  /// manual overlay, and the configured continuity policy.
  @discardableResult
  func clearSourceCanonBaseContinuity(bookID: String) throws -> LongFormPlanResponse {
    try mutateContinuityProjection(bookID: bookID) { projection, _ in
      projection.baseContinuity = LongFormContinuity(
        policy: projection.baseContinuity.policy
      )
    }
  }

  /// Merges a delta into `manualOverlay`, the authoritative layer.
  ///
  /// `synchronizeContinuityProjection` applies the overlay last and with
  /// `allowImmutableChanges: true`, so an entry here outranks both source-extracted
  /// canon and approved chapter deltas. That is what makes it the right home for
  /// the customer's settings text.
  @discardableResult
  func mergeCanonIntoManualOverlay(
    bookID: String,
    delta: ContinuityDelta
  ) throws -> LongFormPlanResponse {
    try mutateContinuityProjection(bookID: bookID) { projection, _ in
      projection.manualOverlay = self.mergedCanonDelta(projection.manualOverlay, delta)
    }
  }

  /// Applies `mutate` to the stored projection, then rebuilds plan and projection.
  ///
  /// Both files are snapshotted first and restored on any failure. Without that, a
  /// delta that passes its own merge but fails the full `validated()` pass would
  /// leave a projection on disk that no later synchronize call can rebuild — the
  /// book's continuity would be permanently unloadable.
  private func mutateContinuityProjection(
    bookID: String,
    _ mutate: (inout ContinuityProjection, LongFormPlanResponse) throws -> Void
  ) throws -> LongFormPlanResponse {
    let current = try synchronizeContinuityProjection(bookID: bookID)
    let projectionURL = try continuityProjectionURL(bookID: bookID)
    let planURL = try existingBookURL(bookID).appendingPathComponent("long-form-plan.json")
    guard var projection = try loadContinuityProjection(at: projectionURL) else {
      throw InkOSCoreError("连续性投影缺失，请先同步长篇规划", statusCode: 503)
    }
    let projectionSnapshot = try? Data(contentsOf: projectionURL)
    let planSnapshot = try? Data(contentsOf: planURL)
    let checkpointSnapshots = (try? snapshotVolumeCheckpoints(bookID: bookID)) ?? [:]

    try mutate(&projection, current)
    projection = ContinuityProjection(
      version: Self.continuityProjectionVersion,
      baseContinuity: projection.baseContinuity,
      chapters: projection.chapters,
      manualOverlay: projection.manualOverlay,
      continuity: projection.continuity,
      updatedAt: isoTimestamp()
    )
    try atomicWrite(encoder.encode(projection), to: projectionURL)
    do {
      return try synchronizeContinuityProjection(bookID: bookID)
    } catch {
      restoreFile(projectionURL, snapshot: projectionSnapshot)
      restoreFile(planURL, snapshot: planSnapshot)
      restoreVolumeCheckpoints(bookID: bookID, snapshots: checkpointSnapshots)
      throw error
    }
  }

  func latestVolumeCheckpointText(bookID: String) throws -> String? {
    let directory = try volumeCheckpointDirectory(bookID: bookID)
    let checkpoints = try directoryContents(directory).compactMap { url -> ContinuityVolumeCheckpoint? in
      guard url.lastPathComponent.hasPrefix("volume-"), url.pathExtension == "json" else { return nil }
      return try? decoder.decode(ContinuityVolumeCheckpoint.self, from: Data(contentsOf: url))
    }
    guard let latest = checkpoints.max(by: { $0.volumeNumber < $1.volumeNumber }) else { return nil }
    return String(data: try encoder.encode(latest), encoding: .utf8)
  }

  /// - Parameter strictIdentity: rejects an entity whose `id` and `name` point at
  ///   two different canon entries. Only the pre-commit validation of a *candidate*
  ///   delta sets this. Replaying deltas that are already committed must stay
  ///   reproducible — chapter 25 of a live book committed such a collision back
  ///   when it merged silently, and throwing on replay would make that book's
  ///   projection permanently unbuildable.
  func applyContinuityDelta(
    _ delta: ContinuityDelta,
    to continuity: inout LongFormContinuity,
    source: String,
    allowImmutableChanges: Bool = false,
    strictIdentity: Bool = false
  ) throws {
    for id in delta.remove.immutableCanon {
      if continuity.immutableCanon.contains(where: { $0.id == id }), !allowImmutableChanges {
        throw continuityConflict(source, "不可变事实 \(id) 不能由章节删除")
      }
      continuity.immutableCanon.removeAll { $0.id == id }
    }
    for id in delta.remove.worldRules {
      if let item = continuity.worldRules.first(where: { $0.id == id }), item.immutable, !allowImmutableChanges {
        throw continuityConflict(source, "不可变世界规则 \(id) 不能由章节删除")
      }
      continuity.worldRules.removeAll { $0.id == id }
    }
    for id in delta.remove.entities {
      if let item = continuity.entities.first(where: { $0.id == id }),
        (item.immutableOwner || item.immutableLocation || !item.immutableAttributes.isEmpty),
        !allowImmutableChanges
      {
        throw continuityConflict(source, "含锁定属性的实体 \(id) 不能由章节删除")
      }
      continuity.entities.removeAll { $0.id == id }
    }
    for id in delta.remove.knowledgeBoundaries {
      continuity.knowledgeBoundaries.removeAll { $0.factId == id }
    }
    for id in delta.remove.timeline {
      if let item = continuity.timeline.first(where: { $0.id == id }), item.immutable, !allowImmutableChanges {
        throw continuityConflict(source, "不可变时间线 \(id) 不能由章节删除")
      }
      continuity.timeline.removeAll { $0.id == id }
    }
    for id in delta.remove.hooks {
      continuity.hooks.removeAll { $0.hookId == id }
    }

    for item in delta.upsert.immutableCanon {
      if let index = continuity.immutableCanon.firstIndex(where: { $0.id == item.id }) {
        if continuity.immutableCanon[index] != item, !allowImmutableChanges {
          throw continuityConflict(source, "不可变事实 \(item.id) 与既有记录冲突")
        }
        continuity.immutableCanon[index] = item
      } else {
        continuity.immutableCanon.append(item)
      }
    }
    for item in delta.upsert.worldRules {
      if let index = continuity.worldRules.firstIndex(where: { $0.id == item.id }) {
        let previous = continuity.worldRules[index]
        if previous != item, previous.immutable, !allowImmutableChanges {
          throw continuityConflict(source, "不可变世界规则 \(item.id) 与既有记录冲突")
        }
        continuity.worldRules[index] = item
      } else {
        continuity.worldRules.append(item)
      }
    }
    for item in delta.upsert.entities {
      let normalizedName = normalizedContinuityName(item.name)
      // ID and name are two independent identity claims and the model can get
      // them to disagree: chapter 27 registered 苏晚晴 under ENT-030, an ID the
      // canon had already given to 黑影软管与水箱旁烟头. Resolve the two matches
      // separately — a single `id || name` predicate with `firstIndex` silently
      // resolved the collision by array position, which surfaced as either a
      // baffling type conflict naming an entity the delta never touched (no
      // repair round could act on it, so the loop deadlocked) or, when the two
      // types happened to agree, a silent rename of the canon entry.
      let idMatch = continuity.entities.firstIndex { $0.id == item.id }
      let nameMatch = continuity.entities.firstIndex {
        normalizedContinuityName($0.name) == normalizedName
      }
      if let idMatch, idMatch != nameMatch {
        let holder = continuity.entities[idMatch]
        if strictIdentity {
          throw entityIDCollision(source, incoming: item, holder: holder, canonicalIndex: nameMatch, in: continuity)
        }
        // Replay of an already-committed delta must stay reproducible, so the
        // name wins as identity and the wrong ID is dropped rather than thrown.
        if let nameMatch {
          try mergeEntity(item, into: &continuity.entities, at: nameMatch, source: source, allowImmutableChanges: allowImmutableChanges)
        } else {
          continuity.entities.append(item.reidentified(as: freeEntityID(basedOn: item.id, in: continuity)))
        }
        continue
      }
      if let index = idMatch ?? nameMatch {
        try mergeEntity(
          item,
          into: &continuity.entities,
          at: index,
          source: source,
          allowImmutableChanges: allowImmutableChanges
        )
      } else {
        continuity.entities.append(item)
      }
    }
    for item in delta.upsert.knowledgeBoundaries {
      if let index = continuity.knowledgeBoundaries.firstIndex(where: { $0.factId == item.factId }) {
        continuity.knowledgeBoundaries[index] = item
      } else {
        continuity.knowledgeBoundaries.append(item)
      }
    }
    for item in delta.upsert.timeline {
      if let index = continuity.timeline.firstIndex(where: { $0.id == item.id }) {
        let previous = continuity.timeline[index]
        if previous != item, previous.immutable, !allowImmutableChanges {
          throw continuityConflict(source, "不可变时间线 \(item.id) 与既有记录冲突")
        }
        continuity.timeline[index] = resolvingTimelineOrderCollision(
          item,
          in: continuity.timeline,
          ignoringIndex: index
        )
      } else {
        continuity.timeline.append(
          resolvingTimelineOrderCollision(item, in: continuity.timeline, ignoringIndex: nil)
        )
      }
    }
    for item in delta.upsert.hooks {
      if let index = continuity.hooks.firstIndex(where: { $0.hookId == item.hookId }) {
        continuity.hooks[index] = item
      } else {
        continuity.hooks.append(item)
      }
    }
    if let policy = delta.policy { continuity.policy = policy }
  }

  func restoreFile(_ url: URL, snapshot: Data?) {
    if let snapshot {
      try? atomicWrite(snapshot, to: url)
    } else {
      try? fileManager.removeItem(at: url)
    }
  }

  func snapshotVolumeCheckpoints(bookID: String) throws -> [String: Data] {
    let directory = try volumeCheckpointDirectory(bookID: bookID)
    var snapshots: [String: Data] = [:]
    for url in try directoryContents(directory) where
      url.lastPathComponent.hasPrefix("volume-")
        && url.lastPathComponent.hasSuffix(".canon.json")
    {
      snapshots[url.lastPathComponent] = try Data(contentsOf: url)
    }
    return snapshots
  }

  func restoreVolumeCheckpoints(bookID: String, snapshots: [String: Data]) {
    guard let directory = try? volumeCheckpointDirectory(bookID: bookID) else { return }
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    if let current = try? directoryContents(directory) {
      for url in current where
        url.lastPathComponent.hasPrefix("volume-")
          && url.lastPathComponent.hasSuffix(".canon.json")
      {
        try? fileManager.removeItem(at: url)
      }
    }
    for (name, data) in snapshots {
      try? atomicWrite(data, to: directory.appendingPathComponent(name))
    }
  }

  private func validateRemovalTargets(
    _ removals: ContinuityDeltaRemovals,
    in continuity: LongFormContinuity,
    chapterNumber: Int
  ) throws {
    let missingCanon = removals.immutableCanon.filter { id in
      !continuity.immutableCanon.contains(where: { $0.id == id })
    }
    let missingRules = removals.worldRules.filter { id in
      !continuity.worldRules.contains(where: { $0.id == id })
    }
    let missingEntities = removals.entities.filter { id in
      !continuity.entities.contains(where: { $0.id == id })
    }
    let missingKnowledge = removals.knowledgeBoundaries.filter { id in
      !continuity.knowledgeBoundaries.contains(where: { $0.factId == id })
    }
    let missingTimeline = removals.timeline.filter { id in
      !continuity.timeline.contains(where: { $0.id == id })
    }
    let missingHooks = removals.hooks.filter { id in
      !continuity.hooks.contains(where: { $0.hookId == id })
    }
    let missing = missingCanon + missingRules + missingEntities + missingKnowledge + missingTimeline + missingHooks
    if let first = missing.first {
      throw continuityConflict("第\(chapterNumber)章候选差量", "删除目标 \(first) 不存在")
    }
  }

  private func synchronizeVolumeCheckpoints(
    bookID: String,
    plan: LongFormPlanResponse,
    base: LongFormContinuity,
    chapters: [ContinuityChapterProjection],
    overlay: ContinuityDelta
  ) throws {
    let directory = try volumeCheckpointDirectory(bookID: bookID)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let managedFiles = try directoryContents(directory).filter {
      $0.lastPathComponent.hasPrefix("volume-") && $0.lastPathComponent.hasSuffix(".canon.json")
    }
    guard plan.continuity.policy.checkpointAtVolumeEnd else {
      for url in managedFiles { try? fileManager.removeItem(at: url) }
      if !managedFiles.isEmpty {
        recordDebug(scope: "continuity", message: "continuity.checkpoints.disabled", data: [
          "bookId": bookID, "removed": managedFiles.count,
        ])
      }
      return
    }

    let committedNumbers = Set(chapters.map(\.chapterNumber))
    var expectedFiles = Set<String>()
    for volume in plan.plan.volumes {
      let required = Set(volume.startChapter...volume.endChapter)
      guard required.isSubset(of: committedNumbers) else { continue }
      let checkpointURL = directory.appendingPathComponent(
        String(format: "volume-%04d.canon.json", volume.number)
      )
      expectedFiles.insert(checkpointURL.lastPathComponent)
      let included = chapters.filter { $0.chapterNumber <= volume.endChapter }
      var snapshot = base
      for chapter in included {
        try applyContinuityDelta(
          chapter.delta,
          to: &snapshot,
          source: "第\(chapter.chapterNumber)章"
        )
      }
      try applyContinuityDelta(
        overlay,
        to: &snapshot,
        source: "人工连续性覆盖",
        allowImmutableChanges: true
      )
      snapshot.policy = plan.continuity.policy
      snapshot = try snapshot.validated(
        targetChapters: plan.plan.targetChapters,
        volumeCount: plan.constraints.volumeCount
      )
      let checkpointChapters = included.map {
        ContinuityCheckpointChapter(chapterNumber: $0.chapterNumber, fingerprint: $0.fingerprint)
      }
      let semantic: [String: Any] = [
        "bookId": bookID,
        "planRevision": plan.revision,
        "volumeNumber": volume.number,
        "startChapter": volume.startChapter,
        "endChapter": volume.endChapter,
        "chapters": checkpointChapters.map {
          ["chapterNumber": $0.chapterNumber, "fingerprint": $0.fingerprint]
        },
        "continuity": try encodedObject(snapshot),
      ]
      let semanticData = try JSONSerialization.data(
        withJSONObject: semantic,
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
      let fingerprint = fnv1aHex(semanticData)
      let existing = try? decoder.decode(
        ContinuityVolumeCheckpoint.self,
        from: Data(contentsOf: checkpointURL)
      )
      guard existing?.fingerprint != fingerprint else { continue }
      let now = isoTimestamp()
      let checkpoint = ContinuityVolumeCheckpoint(
        version: 1,
        bookId: bookID,
        volumeNumber: volume.number,
        startChapter: volume.startChapter,
        endChapter: volume.endChapter,
        planRevision: plan.revision,
        fingerprint: fingerprint,
        chapters: checkpointChapters,
        continuity: snapshot,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now
      )
      try atomicWrite(encoder.encode(checkpoint), to: checkpointURL)
      recordDebug(scope: "continuity", message: "continuity.checkpoint.updated", data: [
        "bookId": bookID,
        "volumeNumber": volume.number,
        "endChapter": volume.endChapter,
        "fingerprint": fingerprint,
      ])
    }

    for url in managedFiles where !expectedFiles.contains(url.lastPathComponent) {
      try? fileManager.removeItem(at: url)
      recordDebug(scope: "continuity", message: "continuity.checkpoint.invalidated", data: [
        "bookId": bookID, "file": url.lastPathComponent,
      ])
    }
  }

  private func volumeCheckpointDirectory(bookID: String) throws -> URL {
    try existingBookURL(bookID)
      .appendingPathComponent("story/runtime/checkpoints", isDirectory: true)
  }

  private func readLongFormPlan(at url: URL) throws -> LongFormPlanResponse {
    guard fileManager.fileExists(atPath: url.path) else {
      throw InkOSCoreError("长篇规划不存在", statusCode: 404)
    }
    do { return try decoder.decode(LongFormPlanResponse.self, from: Data(contentsOf: url)) }
    catch { throw InkOSCoreError("长篇规划格式错误：\(error.localizedDescription)", statusCode: 503) }
  }

  func continuityProjectionURL(bookID: String) throws -> URL {
    try existingBookURL(bookID)
      .appendingPathComponent("story/runtime/continuity-projection.json")
  }

  private func loadContinuityProjection(at url: URL) throws -> ContinuityProjection? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    do {
      let projection = try decoder.decode(ContinuityProjection.self, from: Data(contentsOf: url))
      guard projection.version == Self.continuityProjectionVersion else {
        throw InkOSCoreError("连续性投影版本不受支持", statusCode: 503)
      }
      return projection
    } catch let error as InkOSCoreError {
      throw error
    } catch {
      throw InkOSCoreError("连续性投影格式错误：\(error.localizedDescription)", statusCode: 503)
    }
  }

  private func approvedContinuityDeltas(bookID: String) throws -> [ContinuityChapterProjection] {
    let stateBook = try stateBookObject(bookID: bookID, allowMissing: true)
    let records = try readChapterRecords(bookID: bookID, stateBook: stateBook)
    let runtime = try existingBookURL(bookID).appendingPathComponent("story/runtime", isDirectory: true)
    var result: [ContinuityChapterProjection] = []
    for record in records {
      guard let number = integer(record["number"]),
        ["approved", "published"].contains(string(record["status"]))
      else { continue }
      let url = runtime.appendingPathComponent(String(format: "chapter-%04d.consistency.json", number))
      guard fileManager.fileExists(atPath: url.path) else {
        recordDebug(scope: "continuity", message: "continuity.approved_delta.missing", level: "warning", data: [
          "bookId": bookID, "chapterNumber": number,
        ])
        continue
      }
      let data = try Data(contentsOf: url)
      let object = try readObject(url)
      let rawDelta = object["delta"] as? [String: Any] ?? [:]
      result.append(ContinuityChapterProjection(
        chapterNumber: number,
        fingerprint: fnv1aHex(data),
        delta: try normalizedConsistencyDelta(rawDelta, chapterNumber: number)
      ))
    }
    return result.sorted { $0.chapterNumber < $1.chapterNumber }
  }

  private func makeContinuityOverlay(
    from automatic: LongFormContinuity,
    to requested: LongFormContinuity
  ) -> ContinuityDelta {
    var overlay = ContinuityDelta()
    overlay.upsert.immutableCanon = requested.immutableCanon.filter { item in
      automatic.immutableCanon.first(where: { $0.id == item.id }) != item
    }
    overlay.remove.immutableCanon = automatic.immutableCanon
      .filter { item in !requested.immutableCanon.contains(where: { $0.id == item.id }) }
      .map(\.id)
    overlay.upsert.worldRules = requested.worldRules.filter { item in
      automatic.worldRules.first(where: { $0.id == item.id }) != item
    }
    overlay.remove.worldRules = automatic.worldRules
      .filter { item in !requested.worldRules.contains(where: { $0.id == item.id }) }
      .map(\.id)
    overlay.upsert.entities = requested.entities.filter { item in
      automatic.entities.first(where: { $0.id == item.id }) != item
    }
    overlay.remove.entities = automatic.entities
      .filter { item in !requested.entities.contains(where: { $0.id == item.id }) }
      .map(\.id)
    overlay.upsert.knowledgeBoundaries = requested.knowledgeBoundaries.filter { item in
      automatic.knowledgeBoundaries.first(where: { $0.factId == item.factId }) != item
    }
    overlay.remove.knowledgeBoundaries = automatic.knowledgeBoundaries
      .filter { item in !requested.knowledgeBoundaries.contains(where: { $0.factId == item.factId }) }
      .map(\.factId)
    overlay.upsert.timeline = requested.timeline.filter { item in
      automatic.timeline.first(where: { $0.id == item.id }) != item
    }
    overlay.remove.timeline = automatic.timeline
      .filter { item in !requested.timeline.contains(where: { $0.id == item.id }) }
      .map(\.id)
    overlay.upsert.hooks = requested.hooks.filter { item in
      automatic.hooks.first(where: { $0.hookId == item.hookId }) != item
    }
    overlay.remove.hooks = automatic.hooks
      .filter { item in !requested.hooks.contains(where: { $0.hookId == item.hookId }) }
      .map(\.hookId)
    overlay.policy = requested.policy
    return overlay
  }

  private func normalizedCanon(_ value: Any, chapterNumber: Int, index: Int) throws -> LongFormImmutableCanon {
    let object = value as? [String: Any] ?? [:]
    let statement = normalizedText(object["statement"] ?? object["value"] ?? value)
    guard !statement.isEmpty else { throw malformedDelta("不可变事实", index) }
    let id = normalizedText(object["id"]).continuityNonEmpty ?? stableContinuityID("canon", statement)
    let allowed = Set(["character", "world", "timeline", "entity", "object", "knowledge", "other"])
    let category = normalizedText(object["category"])
    return LongFormImmutableCanon(
      id: id,
      category: allowed.contains(category) ? category : "other",
      statement: statement,
      value: normalizedText(object["value"]).continuityNonEmpty,
      aliases: stringList(object["aliases"])
    )
  }

  private func normalizedWorldRule(_ value: Any, chapterNumber: Int, index: Int) throws -> LongFormWorldRule {
    let object = value as? [String: Any] ?? [:]
    let statement = normalizedText(object["statement"] ?? value)
    guard !statement.isEmpty else { throw malformedDelta("世界规则", index) }
    return LongFormWorldRule(
      id: normalizedText(object["id"]).continuityNonEmpty ?? stableContinuityID("rule", statement),
      statement: statement,
      immutable: (object["immutable"] as? Bool) ?? true
    )
  }

  private func normalizedEntity(
    _ value: Any,
    chapterNumber: Int,
    index: Int,
    defaultType: String
  ) throws -> LongFormEntity {
    let object = value as? [String: Any] ?? [:]
    let name = normalizedText(object["name"] ?? value)
    guard !name.isEmpty else { throw malformedDelta("实体", index) }
    let suppliedType = normalizedText(object["type"]).lowercased()
    let typeAliases = [
      "character": "character", "person": "character", "role": "character",
      "人物": "character", "角色": "character", "生物": "character",
      "object": "object", "item": "object", "resource": "object",
      "物品": "object", "物件": "object", "设备": "object", "资源": "object", "储备": "object",
      "location": "location", "place": "location", "scene": "location",
      "地点": "location", "场所": "location", "区域": "location", "建筑": "location",
      "faction": "faction", "organization": "faction", "group": "faction",
      "组织": "faction", "势力": "faction", "团体": "faction",
      "concept": "concept", "ability": "concept", "phenomenon": "concept", "rule": "concept",
      "概念": "concept", "能力": "concept", "现象": "concept", "规则": "concept",
    ]
    let type: String
    if suppliedType.isEmpty {
      type = defaultType
    } else if let normalized = typeAliases[suppliedType] {
      type = normalized
    } else {
      throw InkOSCoreError(
        "第\(chapterNumber)章 consistencyDelta 第\(index + 1) 个实体“\(name)”的 type=\(suppliedType) 无效，只能使用 character、object、location、faction 或 concept",
        statusCode: 422
      )
    }
    var attributes: [String: String] = [:]
    if let supplied = object["attributes"] as? [String: Any] {
      for (key, raw) in supplied {
        let text = normalizedText(raw)
        if !text.isEmpty { attributes[key] = text }
      }
    } else if let supplied = object["attributes"] as? [String: String] {
      attributes = supplied
    }
    let reserved = Set([
      "id", "name", "type", "owner", "location", "attributes", "immutableOwner",
      "immutableLocation", "immutableAttributes", "保管",
    ])
    for (key, raw) in object where !reserved.contains(key) {
      let text = normalizedText(raw)
      if !text.isEmpty { attributes[key] = text }
    }
    return LongFormEntity(
      id: normalizedText(object["id"]).continuityNonEmpty ?? stableContinuityID("entity", name),
      name: name,
      type: type,
      owner: normalizedText(object["owner"]).continuityNonEmpty,
      location: normalizedText(object["location"] ?? object["保管"]).continuityNonEmpty,
      attributes: attributes,
      immutableOwner: (object["immutableOwner"] as? Bool) ?? false,
      immutableLocation: (object["immutableLocation"] as? Bool) ?? false,
      immutableAttributes: stringList(object["immutableAttributes"])
    )
  }

  private func normalizedKnowledge(_ value: Any, chapterNumber: Int, index: Int) throws -> LongFormKnowledgeBoundary {
    let object = value as? [String: Any] ?? [:]
    let statement = normalizedText(object["statement"] ?? value)
    guard !statement.isEmpty else { throw malformedDelta("知识边界", index) }
    var allowed = stringList(object["allowedKnowers"])
    if allowed.isEmpty, object.isEmpty, let separator = statement.firstIndex(of: "：") {
      let prefix = String(statement[..<separator])
      allowed = prefix.replacingOccurrences(of: "及", with: "、")
        .split(separator: "、")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
    return LongFormKnowledgeBoundary(
      factId: normalizedText(object["factId"] ?? object["id"]).continuityNonEmpty
        ?? stableContinuityID("knowledge", statement),
      statement: statement,
      allowedKnowers: allowed,
      forbiddenKnowers: stringList(object["forbiddenKnowers"]),
      availableFromChapter: integer(object["availableFromChapter"]) ?? chapterNumber,
      revealByChapter: integer(object["revealByChapter"]),
      markers: stringList(object["markers"]).isEmpty ? ["chapter-\(chapterNumber)"] : stringList(object["markers"])
    )
  }

  /// `timeline.order` must be globally unique (see `LongFormContinuity.validated`),
  /// but the model has no view of which orders are already taken, so a collision
  /// used to fail the whole revision round. `order` only carries sort position, so
  /// nudge the incoming milestone to the next free slot instead of rejecting it.
  private func resolvingTimelineOrderCollision(
    _ item: LongFormTimelineMilestone,
    in timeline: [LongFormTimelineMilestone],
    ignoringIndex: Int?
  ) -> LongFormTimelineMilestone {
    var taken = Set<Int>()
    for (index, existing) in timeline.enumerated() where index != ignoringIndex {
      taken.insert(existing.order)
    }
    guard taken.contains(item.order) else { return item }
    var candidate = item.order
    while taken.contains(candidate) { candidate += 1 }
    return LongFormTimelineMilestone(
      id: item.id,
      order: candidate,
      label: item.label,
      earliestChapter: item.earliestChapter,
      latestChapter: item.latestChapter,
      immutable: item.immutable,
      // Carried through: only `order` is being reassigned here. Rebuilding the
      // milestone without these would silently unplace an event from the story
      // clock every time two orders happened to collide.
      sourceDay: item.sourceDay,
      sourceChapter: item.sourceChapter
    )
  }

  private func normalizedTimeline(_ value: Any, chapterNumber: Int, index: Int) throws -> LongFormTimelineMilestone {
    let object = value as? [String: Any] ?? [:]
    let label = normalizedText(object["label"] ?? object["statement"] ?? value)
    guard !label.isEmpty else { throw malformedDelta("时间线", index) }
    return LongFormTimelineMilestone(
      id: normalizedText(object["id"]).continuityNonEmpty ?? stableContinuityID("timeline", label),
      order: integer(object["order"]) ?? chapterNumber * 10_000 + index,
      label: label,
      earliestChapter: integer(object["earliestChapter"]) ?? chapterNumber,
      latestChapter: integer(object["latestChapter"]) ?? chapterNumber,
      immutable: (object["immutable"] as? Bool) ?? true,
      // Both stay nil when the model omits them, which is the honest state: an
      // unplaced event is reported as unplaced rather than guessed onto the axis.
      // This is the only entry point for the source's own clock, so canon
      // extraction depends on it reading these keys.
      sourceDay: integer(object["sourceDay"]),
      sourceChapter: integer(object["sourceChapter"])
    )
  }

  private func normalizedHook(_ value: Any, chapterNumber: Int, index: Int) throws -> LongFormHookPlan {
    let object = value as? [String: Any] ?? [:]
    let description = normalizedText(object["description"] ?? object["statement"] ?? value)
    guard !description.isEmpty else { throw malformedDelta("伏笔", index) }
    return LongFormHookPlan(
      hookId: normalizedText(object["hookId"] ?? object["id"]).continuityNonEmpty
        ?? stableContinuityID("hook", description),
      description: description,
      openFromChapter: integer(object["openFromChapter"]) ?? chapterNumber,
      resolveByChapter: integer(object["resolveByChapter"]),
      requiredVolumeNumber: integer(object["requiredVolumeNumber"])
    )
  }

  private func removalIDs(_ value: Any?, kind: String) -> [String] {
    anyArray(value).compactMap { raw in
      if let text = raw as? String {
        return text.trimmingCharacters(in: .whitespacesAndNewlines).continuityNonEmpty
      }
      guard let object = raw as? [String: Any] else { return nil }
      let exact = normalizedText(
        object["id"] ?? object["factId"] ?? object["hookId"]
      ).continuityNonEmpty
      if let exact { return exact }
      let identity = normalizedText(
        object["name"] ?? object["statement"] ?? object["label"] ?? object["description"]
      )
      return identity.isEmpty ? nil : stableContinuityID(kind, identity)
    }
  }

  private func anyArray(_ value: Any?) -> [Any] {
    if let array = value as? [Any] { return array }
    if let value, !(value is NSNull) { return [value] }
    return []
  }

  private func stringList(_ value: Any?) -> [String] {
    anyArray(value).compactMap { normalizedText($0).continuityNonEmpty }
  }

  /// Flattens one field of model-supplied JSON into text.
  ///
  /// Every value here came from an LLM, so the type is whatever the model felt like
  /// emitting: a string where the schema asked for one, a number, a `null`, or a
  /// nested object it decided to nest one level deeper. Only containers may be
  /// serialized: `data(withJSONObject:)` raises `NSInvalidArgumentException` on a
  /// bare top-level scalar, and that is an ObjC exception, so `try?` does not catch
  /// it — it terminates the process. The old guard validated a *wrapped* value
  /// (`["value": value]`) and then serialized the *bare* one, so a single `null` in
  /// a canon field crashed the whole extraction pass.
  private func normalizedText(_ value: Any?) -> String {
    if let text = value as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let number = value as? NSNumber { return number.stringValue }
    guard let value, !(value is NSNull) else { return "" }
    // Containers only, and the validity check now covers the exact object serialized.
    guard value is [Any] || value is [String: Any],
      JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  private func normalizedContinuityName(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
  }

  private func stableContinuityID(_ kind: String, _ identity: String) -> String {
    "auto-\(kind)-\(fnv1aHex(Data(normalizedContinuityName(identity).utf8)))"
  }

  private func fnv1aHex(_ data: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      hash ^= UInt64(byte)
      hash = hash &* 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  private func malformedDelta(_ label: String, _ index: Int) -> InkOSCoreError {
    InkOSCoreError("consistencyDelta 的\(label)第 \(index + 1) 项缺少有效内容", statusCode: 422)
  }

  private func continuityConflict(_ source: String, _ detail: String) -> InkOSCoreError {
    InkOSCoreError("连续性冲突（\(source)）：\(detail)", statusCode: 409)
  }

  /// Merges an upserted entity into an existing canon slot. Extracted so the
  /// normal path and the ID-collision replay path cannot drift apart.
  private func mergeEntity(
    _ item: LongFormEntity,
    into entities: inout [LongFormEntity],
    at index: Int,
    source: String,
    allowImmutableChanges: Bool
  ) throws {
    let previous = entities[index]
    if previous.type != item.type, !allowImmutableChanges {
      throw continuityConflict(source, "实体 \(previous.name) 的类型不能从 \(previous.type) 改为 \(item.type)")
    }
    if previous.immutableOwner, let owner = item.owner, owner != previous.owner, !allowImmutableChanges {
      throw continuityConflict(source, "实体 \(previous.name) 的归属已锁定")
    }
    if previous.immutableLocation, let location = item.location, location != previous.location,
      !allowImmutableChanges
    {
      throw continuityConflict(source, "实体 \(previous.name) 的位置已锁定")
    }
    for key in previous.immutableAttributes {
      if let value = item.attributes[key], value != previous.attributes[key], !allowImmutableChanges {
        throw continuityConflict(source, "实体 \(previous.name) 的属性 \(key) 已锁定")
      }
    }
    var attributes = previous.attributes
    attributes.merge(item.attributes) { _, new in new }
    entities[index] = LongFormEntity(
      id: previous.id,
      name: item.name,
      type: allowImmutableChanges ? item.type : previous.type,
      owner: item.owner ?? previous.owner,
      location: item.location ?? previous.location,
      attributes: attributes,
      immutableOwner: previous.immutableOwner || item.immutableOwner,
      immutableLocation: previous.immutableLocation || item.immutableLocation,
      immutableAttributes: Array(Set(previous.immutableAttributes + item.immutableAttributes)).sorted()
    )
  }

  /// The message a `[delta]` repair round actually has to act on: which ID was
  /// reused, who already holds it, and the exact ID to write instead. The old
  /// wording named only the *holder* and its type change, so the repairer looked
  /// for an entity its delta never mentioned, concluded nothing needed fixing,
  /// and returned byte-identical JSON until the round budget ran out.
  private func entityIDCollision(
    _ source: String,
    incoming: LongFormEntity,
    holder: LongFormEntity,
    canonicalIndex: Int?,
    in continuity: LongFormContinuity
  ) -> InkOSCoreError {
    var detail = "实体 ID 撞车：你把 \(incoming.name) 登记为 \(incoming.id)，"
    detail += "但 \(incoming.id) 在正典中已属于 \(holder.name)（\(holder.type)）。"
    if let canonicalIndex {
      let canonical = continuity.entities[canonicalIndex]
      detail += "\(incoming.name) 的正确 ID 是 \(canonical.id)（\(canonical.type)）；"
      detail += "请把这一项的 id 改成 \(canonical.id)，name 与 type 保持不变。"
    } else {
      let suggestion = freeEntityID(basedOn: incoming.id, in: continuity)
      detail += "\(incoming.name) 是本章新实体，正典中尚无对应条目；"
      detail += "请改用未被占用的新 ID，例如 \(suggestion)。"
    }
    detail += "不要修改 \(holder.name) 的任何字段，也不要改动正文。"
    return continuityConflict(source, detail)
  }

  /// A collision-free ID derived from what the model asked for, so a repaired or
  /// replayed entity keeps a recognizable prefix instead of an opaque hash.
  private func freeEntityID(basedOn requested: String, in continuity: LongFormContinuity) -> String {
    let taken = Set(continuity.entities.map(\.id))
    let base = requested.isEmpty ? "ENT" : requested
    guard taken.contains(base) else { return base }
    for suffix in 2...999 {
      let candidate = "\(base)-\(suffix)"
      if !taken.contains(candidate) { return candidate }
    }
    return "\(base)-\(UUID().uuidString.prefix(8))"
  }
}

extension LongFormEntity {
  /// Same entity, different ID. Used when a replayed delta's ID is already taken
  /// by an unrelated canon entry and the entity is genuinely new.
  func reidentified(as newID: String) -> LongFormEntity {
    LongFormEntity(
      id: newID,
      name: name,
      type: type,
      owner: owner,
      location: location,
      attributes: attributes,
      immutableOwner: immutableOwner,
      immutableLocation: immutableLocation,
      immutableAttributes: immutableAttributes
    )
  }
}

private extension String {
  var continuityNonEmpty: String? { isEmpty ? nil : self }
}
