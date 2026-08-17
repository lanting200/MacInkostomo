import Foundation

// MARK: - Derivative story clock

/// Positions a derivative book on the original work's timeline.
///
/// Fan fiction drifts in time because nothing in the pipeline knows *when* the story
/// is. Canon reaches the writing model as a flat set of facts with no ordering, so a
/// chapter set before the source protagonist even arrives can still have characters
/// discussing events from source chapter 900 — the model has no way to tell that
/// those facts are not yet true. Continuity checking cannot catch it either: every
/// individual fact is correct, only its date is wrong.
///
/// The fix is a story clock. One canon milestone is the origin, chapter 1 sits a
/// stated number of days from it, each chapter advances by its beat's `storyDays`,
/// and every canon event is then classified as behind the current chapter, ahead of
/// it, or unplaceable. The ahead-of-it list is the load-bearing one: it goes into
/// both the beat prompt and the writing prompt as material no one in the chapter may
/// know yet.
extension InkOSCore {
  /// Chapters whose beats are summed to place a chapter on the clock. Beyond this
  /// the sum is extrapolated from `defaultChapterDays`, so a book with thousands of
  /// chapters does not re-read the whole beat plan for every prompt.
  static let timelineBeatSumLimit = 4_000

  /// Canon events listed in each direction. The prompt has a fixed budget and the
  /// nearest events are the ones a chapter can plausibly collide with; a hundred
  /// distant milestones would crowd out the story bible for no gain.
  static let timelineEventListLimit = 12

  func derivativeTimelineURL(_ bookID: String) throws -> URL {
    try sourceDirectoryURL(bookID).appendingPathComponent("timeline.json")
  }

  /// Whether the book continues an imported original.
  ///
  /// Defaults to `.original` when `book.json` predates the field or is unreadable.
  /// That is the safe direction: an original book merely loses prompt sections it
  /// has no source for, whereas treating an original book as derivative would ask
  /// the writing model to obey canon that does not exist.
  func bookKind(bookID: String) -> BookKind {
    guard let bookURL = try? existingBookURL(bookID),
      let metadata = try? readObject(bookURL.appendingPathComponent("book.json")),
      let raw = metadata["kind"] as? String,
      let kind = BookKind(rawValue: raw)
    else {
      return .original
    }
    return kind
  }

  /// Title of the original work, empty for original books.
  func bookSourceTitle(bookID: String) -> String {
    guard let bookURL = try? existingBookURL(bookID),
      let metadata = try? readObject(bookURL.appendingPathComponent("book.json"))
    else {
      return ""
    }
    return string(metadata["sourceTitle"])
  }

  /// Reads the stored clock, or an unconfigured default when the book has none.
  ///
  /// Returns a value rather than throwing for a missing file: an original book has
  /// no timeline by definition and the prompt builders call this unconditionally.
  func loadDerivativeTimeline(bookID: String) -> DerivativeTimeline {
    guard let url = try? derivativeTimelineURL(bookID),
      let data = try? Data(contentsOf: url),
      let stored = try? decoder.decode(DerivativeTimeline.self, from: data),
      stored.version == DerivativeTimeline.currentVersion
    else {
      return DerivativeTimeline()
    }
    return stored
  }

  @discardableResult
  func saveDerivativeTimeline(
    bookID: String,
    _ timeline: DerivativeTimeline
  ) throws -> DerivativeTimeline {
    var value = timeline
    value.version = DerivativeTimeline.currentVersion
    value.defaultChapterDays = Swift.max(0, Swift.min(365, value.defaultChapterDays))
    value.updatedAt = isoTimestamp()
    let url = try derivativeTimelineURL(bookID)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try atomicWrite(encoder.encode(value), to: url)
    recordDebug(scope: "timeline", message: "timeline.saved", data: [
      "bookId": bookID,
      "anchor": value.anchorLabel,
      "anchorSourceChapter": value.anchorSourceChapter ?? -1,
      "startDayOffset": value.startDayOffset,
    ])
    return value
  }

  /// Day offset of `chapterNumber`'s opening, measured from the anchor.
  ///
  /// Sums the beats already written rather than assuming a fixed rate, because the
  /// beat model is the only thing that knows a chapter covered one night or three
  /// weeks. Chapters with no beat yet — the common case when the clock is consulted
  /// while planning a future window — contribute `defaultChapterDays`.
  func derivativeStoryDay(
    chapterNumber: Int,
    timeline: DerivativeTimeline,
    beats: ChapterBeatPlan?
  ) -> Int {
    guard chapterNumber > 1 else { return timeline.startDayOffset }
    let preceding = chapterNumber - 1
    let counted = Swift.min(preceding, Self.timelineBeatSumLimit)
    var elapsed = 0
    let byNumber = Dictionary(
      (beats?.beats ?? []).map { ($0.number, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for number in 1...Swift.max(1, counted) where number <= preceding {
      elapsed += byNumber[number]?.storyDays ?? timeline.defaultChapterDays
    }
    if preceding > counted {
      elapsed += (preceding - counted) * timeline.defaultChapterDays
    }
    return timeline.startDayOffset + elapsed
  }

  /// Splits canon milestones into what has already happened by `chapterNumber`,
  /// what has not, and what cannot be placed.
  ///
  /// Two axes are used because neither alone is enough. `sourceDay` is exact but
  /// sparse — the original text rarely states elapsed time, so most milestones lack
  /// it. `sourceChapter` is populated for every extracted milestone and monotonic in
  /// source order, but it only fixes an event relative to the anchor's own source
  /// chapter, not to an arbitrary day. So a milestone with a day is compared
  /// directly, and one without is compared by source chapter to establish which side
  /// of the anchor it falls on; when that still does not decide it against the
  /// current story day, the event is reported as unplaced instead of guessed.
  ///
  /// Interpolating a day from the source chapter would remove the unplaced list
  /// entirely and is deliberately not done: source chapters advance at wildly uneven
  /// story rates, so an interpolated date would be fabricated precision, and the
  /// prompt presents these lists as fact.
  func derivativeTimelineStatus(
    bookID: String,
    chapterNumber: Int,
    continuity: LongFormContinuity,
    timeline suppliedTimeline: DerivativeTimeline? = nil,
    beats suppliedBeats: ChapterBeatPlan? = nil
  ) -> DerivativeTimelineStatus {
    let timeline = resolvedAnchor(
      suppliedTimeline ?? loadDerivativeTimeline(bookID: bookID),
      in: continuity
    )
    let beats = suppliedBeats ?? (try? loadChapterBeatPlan(bookID: bookID))
    let storyDay = derivativeStoryDay(
      chapterNumber: chapterNumber,
      timeline: timeline,
      beats: beats
    )

    var past: [DerivativeTimelineEvent] = []
    var future: [DerivativeTimelineEvent] = []
    var unplaced: [DerivativeTimelineEvent] = []

    for milestone in continuity.timeline {
      let event = DerivativeTimelineEvent(
        id: milestone.id,
        label: milestone.label,
        sourceDay: milestone.sourceDay,
        sourceChapter: milestone.sourceChapter,
        dayDelta: milestone.sourceDay.map { $0 - storyDay }
      )
      if let day = milestone.sourceDay {
        if day <= storyDay { past.append(event) } else { future.append(event) }
        continue
      }
      // A milestone with no source chapter did not come from the original work: it is
      // either the customer's own premise (settings overlay) or something an approved
      // chapter established. Neither is a source event, so neither belongs in this
      // gate — reporting the protagonist's own arrival as "a source event you must not
      // reference" is worse than saying nothing, because chapter one *is* that arrival.
      guard let eventChapter = milestone.sourceChapter else { continue }
      // No day: decide by which side of the anchor the source chapter falls on.
      guard let anchorChapter = timeline.anchorSourceChapter else {
        unplaced.append(event)
        continue
      }
      if eventChapter > anchorChapter {
        // After the anchor, so strictly after day 0. Only decidable while the
        // story itself has not yet passed day 0.
        if storyDay <= 0 { future.append(event) } else { unplaced.append(event) }
      } else if eventChapter == anchorChapter {
        // The anchor's own chapter: day 0 exactly. This is a definition, not an
        // interpolation, so it needs no `unplaced` escape hatch. Folding it into the
        // `<` branch below made the anchor event itself — 克莱恩穿越, the single event
        // a 诡秘之主 derivative most needs gated — report as "uncertain whether it has
        // happened" for every chapter before the anchor.
        if storyDay >= 0 { past.append(event) } else { future.append(event) }
      } else {
        // Strictly before the anchor, so at or before day 0 but by an unknown margin.
        if storyDay >= 0 { past.append(event) } else { unplaced.append(event) }
      }
    }

    // Past reads chronologically toward the present; future reads nearest-first,
    // which is the order a writer needs when checking what must not leak.
    past.sort { timelineSortKey($0) < timelineSortKey($1) }
    future.sort { timelineSortKey($0) < timelineSortKey($1) }
    unplaced.sort { timelineSortKey($0) < timelineSortKey($1) }
    let latestPastSourceChapter = past.compactMap(\.sourceChapter).max()

    return DerivativeTimelineStatus(
      chapterNumber: chapterNumber,
      storyDay: storyDay,
      elapsedDays: storyDay - timeline.startDayOffset,
      anchorLabel: timeline.anchorLabel,
      startDateLabel: timeline.startDateLabel,
      latestPastSourceChapter: latestPastSourceChapter,
      past: Array(past.suffix(Self.timelineEventListLimit)),
      future: Array(future.prefix(Self.timelineEventListLimit)),
      unplaced: Array(unplaced.prefix(Self.timelineEventListLimit)),
      isConfigured: timeline.isConfigured
    )
  }

  func resolvedDerivativeTimeline(
    bookID: String,
    continuity: LongFormContinuity
  ) -> DerivativeTimeline {
    resolvedAnchor(loadDerivativeTimeline(bookID: bookID), in: continuity)
  }

  /// Conservative source boundary for RAG quotations at the current story date.
  /// A passage after this chapter can contain an event the timeline section labels
  /// as future, which would leak the answer into the same prompt that forbids it.
  func derivativeRetrievalMaximumSourceChapter(
    status: DerivativeTimelineStatus,
    timeline: DerivativeTimeline
  ) -> Int? {
    guard let anchorChapter = timeline.anchorSourceChapter else { return nil }
    if status.storyDay < 0 {
      // Before the anchor, even its own chapter may narrate the not-yet-happened
      // event. An anchor in the retained index-0 preface therefore produces -1,
      // intentionally matching no indexed chapter rather than leaking the anchor.
      return anchorChapter - 1
    }
    let latestPlaced = status.latestPastSourceChapter ?? anchorChapter
    return Swift.max(anchorChapter, latestPlaced)
  }

  /// Convenience for callers that have not already loaded the plan — the UI, mainly.
  /// The prompt builders pass their own continuity to avoid a second projection sync.
  func derivativeTimelineStatus(
    bookID: String,
    chapterNumber: Int
  ) throws -> DerivativeTimelineStatus {
    let plan = try synchronizeContinuityProjection(bookID: bookID)
    return derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: chapterNumber,
      continuity: plan.continuity
    )
  }

  /// The batch-closing half of the beat prompt: how far the story has moved by the
  /// last chapter of the batch, plus any future events the opening list did not
  /// show.
  ///
  /// Both lists are capped at `timelineEventListLimit`, and a batch that spans
  /// enough story days retires the nearest future events mid-batch, so an event
  /// ranked just beyond the cap at the opening chapter enters the printed list by
  /// the closing chapter. A beat planner that never sees it can schedule it for a
  /// late-batch chapter, where the writing prompt then forbids it — a conflict that
  /// otherwise surfaces only as a failed review after a full chapter write.
  func derivativeBeatClosingSection(
    opening: DerivativeTimelineStatus,
    closing: DerivativeTimelineStatus,
    endChapter: Int
  ) -> String? {
    guard closing.storyDay != opening.storyDay else { return nil }
    var text = "\n\n【本批次终点的原著时间进度】\n第 \(endChapter) 章预计距开篇 "
      + "\(closing.elapsedDays) 天。本批次任何一章都不得触及上面"
      + "「尚未发生」列表中的内容。"
    let shownAtOpening = Set(opening.future.map(\.id))
    let closingOnly = closing.future.filter { !shownAtOpening.contains($0.id) }
    if !closingOnly.isEmpty {
      text += "\n以下原著事件到本批次终点仍然尚未发生，同样绝对不得发生，也不得被任何人知晓、预告或讨论："
      for event in closingOnly {
        text += "\n- \(timelineEventLine(event))"
      }
    }
    return text
  }

  private func timelineSortKey(_ event: DerivativeTimelineEvent) -> (Int, Int, String) {
    (event.sourceDay ?? Int.max, event.sourceChapter ?? Int.max, event.id)
  }

  /// Fills in which canon milestone the axis measures from.
  ///
  /// The customer names the anchor in their own words ("克莱恩穿越") before canon
  /// extraction has run, so no milestone id exists yet to point at. Matching by
  /// label on read keeps the stored config honest about that: it records what the
  /// customer said, and the id/source-chapter binding appears once extraction has
  /// produced something to bind to. Without the binding the source-chapter fallback
  /// has no origin, so every day-less event lands in `unplaced`.
  private func resolvedAnchor(
    _ timeline: DerivativeTimeline,
    in continuity: LongFormContinuity
  ) -> DerivativeTimeline {
    var value = timeline
    // IDs and source chapters are derived bindings, not user input. Discard them
    // before each resolution so a replaced source cannot keep using the old axis.
    value.anchorMilestoneID = nil
    value.anchorSourceChapter = nil
    guard let anchor = matchingSourceTimelineAnchor(
      label: timeline.anchorLabel,
      milestoneID: timeline.anchorMilestoneID,
      in: continuity.timeline
    ) else { return value }
    value.anchorMilestoneID = anchor.id
    value.anchorSourceChapter = anchor.sourceChapter
    return value
  }

  /// How far into the original we look first for a shorthand match.
  ///
  /// A 诡秘-style opening label like `克莱恩穿越` also appears in late reveals
  /// ("发现穿越真相"). Searching the whole book by token count binds the late
  /// event; the customer named the clock origin while creating the book, which
  /// is almost always in the first volume.
  static let timelineAnchorEarlyWindow = 80

  /// Resolves a customer-named origin onto an extracted source milestone.
  ///
  /// Order: stored id, exact label, containment either way, then the last two
  /// characters of the shorthand as a required token (`穿越` / `聚会` / `成神`)
  /// with any leftover prefix as a tie-break. Token search prefers the early
  /// window, then the rest of the book, then the earliest chapter at the best
  /// extra-token score. Overlay milestones without `sourceChapter` never win.
  func matchingSourceTimelineAnchor(
    label: String,
    milestoneID: String? = nil,
    in milestones: [LongFormTimelineMilestone]
  ) -> LongFormTimelineMilestone? {
    let sourceMilestones = milestones.filter { $0.sourceChapter != nil }
    if let id = milestoneID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !id.isEmpty
    {
      if let match = sourceMilestones.first(where: { $0.id == id }) { return match }
    }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let exact = sourceMilestones.first(where: { $0.label == trimmed }) { return exact }
    if let contained = sourceMilestones.first(where: {
      $0.label.contains(trimmed) || trimmed.contains($0.label)
    }) {
      return contained
    }
    return matchingSourceTimelineAnchorByTokens(trimmed, in: sourceMilestones)
  }

  private func matchingSourceTimelineAnchorByTokens(
    _ label: String,
    in milestones: [LongFormTimelineMilestone]
  ) -> LongFormTimelineMilestone? {
    guard let parts = timelineAnchorTokenParts(label) else { return nil }
    let scored = milestones.compactMap { milestone -> (LongFormTimelineMilestone, Int, Int)? in
      guard milestone.label.contains(parts.required),
        let chapter = milestone.sourceChapter
      else { return nil }
      let extras = parts.extras.reduce(0) { $0 + (milestone.label.contains($1) ? 1 : 0) }
      return (milestone, extras, chapter)
    }
    guard !scored.isEmpty else { return nil }
    let early = scored.filter { $0.2 <= Self.timelineAnchorEarlyWindow }
    let pool = early.isEmpty ? scored : early
    let bestExtras = pool.map(\.1).max() ?? 0
    return pool
      .filter { $0.1 == bestExtras }
      .min { lhs, rhs in
        if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
        if lhs.0.order != rhs.0.order { return lhs.0.order < rhs.0.order }
        return lhs.0.label.count < rhs.0.label.count
      }?
      .0
  }

  /// Splits a create-book shorthand into the event verb (last two characters)
  /// and any leftover name/place prefix. `克莱恩穿越` → (`穿越`, [`克莱恩`]).
  private func timelineAnchorTokenParts(_ label: String) -> (required: String, extras: [String])? {
    let separators = CharacterSet.whitespacesAndNewlines
      .union(.punctuationCharacters)
      .union(CharacterSet(charactersIn: "的了在与和之及·—-"))
    let compact = label.unicodeScalars.reduce(into: "") { result, scalar in
      if separators.contains(scalar) {
        if !result.hasSuffix(" ") { result.append(" ") }
      } else {
        result.append(String(Character(scalar)))
      }
    }
    let parts = compact.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.count >= 2 }
    if parts.count >= 2, let last = parts.last {
      return (last, Array(parts.dropLast()))
    }
    let blob = parts.first ?? compact.replacingOccurrences(of: " ", with: "")
    guard blob.count >= 2 else { return nil }
    if blob.count == 2 { return (blob, []) }
    let required = String(blob.suffix(2))
    let extra = String(blob.dropLast(2))
    return (required, extra.count >= 2 ? [extra] : [])
  }

  /// True only when the resolved binding still names a source milestone in the
  /// continuity supplied by the current source projection.
  func hasResolvedDerivativeSourceAnchor(
    _ timeline: DerivativeTimeline,
    continuity: LongFormContinuity
  ) -> Bool {
    guard let id = timeline.anchorMilestoneID,
      let sourceChapter = timeline.anchorSourceChapter
    else { return false }
    return continuity.timeline.contains {
      $0.id == id && $0.sourceChapter == sourceChapter
    }
  }

  /// Renders the clock as a prompt section.
  ///
  /// Returns nil when the book has no configured timeline, so an original book adds
  /// no empty heading and a derivative book whose customer skipped the step is not
  /// given a fabricated date to write against.
  func derivativeTimelineSection(_ status: DerivativeTimelineStatus) -> String? {
    guard status.isConfigured else { return nil }
    var lines: [String] = []

    let dateLabel = status.startDateLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    if status.chapterNumber <= 1, !dateLabel.isEmpty {
      lines.append("本章的故事时间：\(dateLabel)")
    } else if !dateLabel.isEmpty {
      lines.append("开篇时间：\(dateLabel)；本章已距开篇 \(status.elapsedDays) 天")
    } else {
      lines.append("本章已距开篇 \(status.elapsedDays) 天")
    }

    let anchor = status.anchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !anchor.isEmpty {
      let day = status.storyDay
      if day < 0 {
        lines.append("距原著事件「\(anchor)」还有 \(-day) 天，该事件尚未发生。")
      } else if day == 0 {
        lines.append("原著事件「\(anchor)」正好发生在本章当天。")
      } else {
        lines.append("原著事件「\(anchor)」已在 \(day) 天前发生。")
      }
    }

    if !status.past.isEmpty {
      lines.append("")
      lines.append("已经发生的原著事件（可以作为既成事实引用）：")
      lines.append(contentsOf: status.past.map { "- \(timelineEventLine($0))" })
    }

    if !status.future.isEmpty {
      lines.append("")
      lines.append(
        "尚未发生的原著事件（本章绝对不得发生，也不得被任何人知晓、预告或讨论）："
      )
      lines.append(contentsOf: status.future.map { "- \(timelineEventLine($0))" })
    }

    if !status.unplaced.isEmpty {
      lines.append("")
      lines.append("时间点未确定的原著事件（不确定是否已发生，本章不要引用其结果）：")
      lines.append(contentsOf: status.unplaced.map { "- \(timelineEventLine($0))" })
    }

    return lines.joined(separator: "\n")
  }

  private func timelineEventLine(_ event: DerivativeTimelineEvent) -> String {
    var suffix: [String] = []
    if let delta = event.dayDelta {
      if delta < 0 {
        suffix.append("\(-delta) 天前")
      } else if delta == 0 {
        suffix.append("就在今天")
      } else {
        suffix.append("\(delta) 天后")
      }
    }
    if let chapter = event.sourceChapter {
      suffix.append("原著第 \(chapter) 章")
    }
    return suffix.isEmpty ? event.label : "\(event.label)（\(suffix.joined(separator: "，")))"
  }
}
