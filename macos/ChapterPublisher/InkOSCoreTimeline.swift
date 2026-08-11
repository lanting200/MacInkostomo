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

    return DerivativeTimelineStatus(
      chapterNumber: chapterNumber,
      storyDay: storyDay,
      elapsedDays: storyDay - timeline.startDayOffset,
      anchorLabel: timeline.anchorLabel,
      startDateLabel: timeline.startDateLabel,
      past: Array(past.suffix(Self.timelineEventListLimit)),
      future: Array(future.prefix(Self.timelineEventListLimit)),
      unplaced: Array(unplaced.prefix(Self.timelineEventListLimit)),
      isConfigured: timeline.isConfigured
    )
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
    var anchor: LongFormTimelineMilestone?
    if let id = timeline.anchorMilestoneID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !id.isEmpty
    {
      anchor = continuity.timeline.first { $0.id == id }
    }
    if anchor == nil {
      let label = timeline.anchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      if !label.isEmpty {
        // Exact label first, then containment, because extraction tends to write a
        // fuller sentence than the customer's shorthand.
        anchor = continuity.timeline.first { $0.label == label }
          ?? continuity.timeline.first { $0.label.contains(label) }
      }
    }
    guard let anchor else { return value }
    value.anchorMilestoneID = anchor.id
    if value.anchorSourceChapter == nil { value.anchorSourceChapter = anchor.sourceChapter }
    return value
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
