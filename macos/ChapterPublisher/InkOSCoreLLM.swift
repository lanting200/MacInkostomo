import Foundation

/// Maximum number of automatic "rewrite + re-review" rounds after an initial
/// review (or local validation) failure before a chapter is left for manual
/// revision. Each round is a full model rewrite plus an independent re-review.
private let maxAutoRevisionRounds = 2

extension InkOSCore {
  struct LLMResult: Sendable {
    let content: String
    let model: String
    let baseURL: String
    let latencyMilliseconds: Int
    /// Last finish_reason seen on the response ("stop", "length", …). A
    /// truncated stream is otherwise indistinguishable from a complete one.
    let finishReason: String?
  }

  enum LLMRole: Sendable {
    case primary
    case review
  }

  // MARK: - Configuration

  func fetchInkOSConfig() async throws -> InkOSConfig {
    let raw = try loadRawConfig()
    let primaryKey = string(raw["apiKey"])
    let reviewKey = string(raw["reviewApiKey"])
    return try decodeObject([
      "provider": "openai",
      "model": string(raw["model"], fallback: "gpt-5.6-terra"),
      "reviewModel": string(raw["reviewModel"], fallback: string(raw["model"], fallback: "gpt-5.6-terra")),
      "baseUrl": string(raw["baseUrl"]),
      "reviewBaseUrl": string(raw["reviewBaseUrl"]),
      "apiFormat": "chat",
      "stream": (raw["stream"] as? Bool) ?? false,
      "temperature": raw["temperature"] ?? NSNull(),
      "maxTokens": raw["maxTokens"] ?? NSNull(),
      "thinkingBudget": 0,
      "source": "native-inkos-core",
      "hasApiKey": !primaryKey.isEmpty,
      "apiKeyPreview": secretPreview(primaryKey),
      "hasReviewApiKey": !reviewKey.isEmpty,
      "reviewApiKeyPreview": secretPreview(reviewKey),
      "apiKey": "",
      "reviewApiKey": "",
    ], as: InkOSConfig.self)
  }

  func updateInkOSConfig(_ input: InkOSConfigUpdate) async throws -> InkOSConfigApplyResponse {
    var raw = try loadRawConfig()
    let baseURL = try validatedEndpoint(input.baseUrl, allowEmpty: true, existing: raw)
    let reviewBaseURL = try validatedEndpoint(input.reviewBaseUrl, allowEmpty: true, existing: raw)
    raw["provider"] = "openai"
    raw["apiFormat"] = "chat"
    raw["model"] = input.model.trimmingCharacters(in: .whitespacesAndNewlines)
    raw["reviewModel"] = input.reviewModel.trimmingCharacters(in: .whitespacesAndNewlines)
    raw["baseUrl"] = baseURL
    raw["reviewBaseUrl"] = reviewBaseURL
    raw["stream"] = false
    raw["thinkingBudget"] = 0
    if !input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw["apiKey"] = input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !input.reviewApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw["reviewApiKey"] = input.reviewApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let temperature = input.temperature { raw["temperature"] = temperature }
    if let maxTokens = input.maxTokens { raw["maxTokens"] = maxTokens }
    try writeJSON(raw, to: configURL, privateFile: true)
    recordDebug(scope: "config", message: "llm.config.updated", data: [
      "model": string(raw["model"]), "reviewModel": string(raw["reviewModel"]),
    ])
    let fields = [
      "model", "reviewModel", "baseUrl", "reviewBaseUrl", "stream",
      "thinkingBudget", "temperature", "maxTokens",
    ]
    return InkOSConfigApplyResponse(ok: true, applied: fields.count, fields: fields, errors: [])
  }

  func fetchModels(_ endpoint: ModelEndpointRequest) async throws -> ModelCatalogResponse {
    let raw = try loadRawConfig()
    let configured = endpoint.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let fallback = endpoint.role == .review
      ? string(raw["reviewBaseUrl"], fallback: string(raw["baseUrl"]))
      : string(raw["baseUrl"])
    let baseURL = try validatedEndpoint(configured.isEmpty ? fallback : configured, existing: raw)
    let suppliedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedKey = endpoint.role == .review
      ? string(raw["reviewApiKey"], fallback: string(raw["apiKey"]))
      : string(raw["apiKey"])
    let key = suppliedKey.isEmpty ? storedKey : suppliedKey
    guard !key.isEmpty else { throw InkOSCoreError("请先填写或保存 API Key", statusCode: 400) }
    let url = try endpointURL(baseURL: baseURL, suffix: "models")
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await performLLMRequest(request, operation: "models.list")
    guard let http = response as? HTTPURLResponse else { throw InkOSCoreError("模型列表返回格式异常") }
    guard (200..<300).contains(http.statusCode) else {
      throw try remoteError(data: data, status: http.statusCode, prefix: "获取模型列表失败")
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    let models = (object["data"] as? [[String: Any]] ?? []).compactMap { item -> RemoteModel? in
      let id = string(item["id"])
      guard !id.isEmpty else { return nil }
      return RemoteModel(id: id, ownedBy: item["owned_by"] as? String ?? item["ownedBy"] as? String)
    }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    return ModelCatalogResponse(ok: true, baseUrl: baseURL, models: models)
  }

  func testModel(_ input: ModelTestRequest) async throws -> ModelTestResponse {
    let started = Date()
    do {
      let result = try await requestLLM(
        prompt: "只回复 OK",
        role: input.role == .review ? .review : .primary,
        overrideModel: input.model,
        overrideBaseURL: input.baseUrl,
        overrideAPIKey: input.apiKey,
        timeout: 60
      )
      return ModelTestResponse(
        ok: true,
        model: result.model,
        latencyMs: Int(Date().timeIntervalSince(started) * 1000),
        status: 200,
        error: nil
      )
    } catch {
      return ModelTestResponse(
        ok: false,
        model: input.model,
        latencyMs: Int(Date().timeIntervalSince(started) * 1000),
        status: (error as? InkOSCoreError)?.statusCode,
        error: error.localizedDescription
      )
    }
  }

  // MARK: - Generation and revision

  func generateChapter(bookID: String, guidance: String?) async throws -> ProcessingResponse {
    let context = try await fetchChapters(bookID: bookID)
    let plan = try await fetchLongFormPlan(bookID: bookID)
    try validateChapterSequence(
      bookID: bookID,
      chapterNumber: context.nextChapterNum,
      plan: plan,
      operation: "生成"
    )
    if let previous = context.chapters.max(by: { $0.number < $1.number }),
      !["approved", "published"].contains(previous.status)
    {
      throw InkOSCoreError("上一章通过人工审核后才能生成下一章", statusCode: 409)
    }
    let chapterNumber = context.nextChapterNum
    let key = generationKey(bookID, chapterNumber)
    if generationJobs[key]?.isActive == true {
      throw InkOSCoreError("该书已有生成任务正在运行", statusCode: 409)
    }
    let startedAt = isoTimestamp()
    generationJobs[key] = try makeGenerationJob(
      bookID: bookID,
      chapterNumber: chapterNumber,
      phase: "planning",
      message: "原生 InkOSCore 正在组织章节上下文",
      startedAt: startedAt
    )
    recordDebug(scope: "generation", message: "chapter.started", data: [
      "bookId": bookID, "chapterNumber": chapterNumber,
    ])
    Task { await self.performGeneration(bookID: bookID, chapterNumber: chapterNumber, guidance: guidance, startedAt: startedAt) }
    return ProcessingResponse(message: "原生 InkOSCore 正在生成新章节", status: "processing")
  }

  func reviseChapter(
    bookID: String,
    number: Int,
    note: String,
    mode: String
  ) async throws -> ProcessingResponse {
    let chapter = try await fetchChapter(bookID: bookID, number: number)
    let key = generationKey(bookID, number)
    if generationJobs[key]?.isActive == true {
      throw InkOSCoreError("该章节已有任务正在运行", statusCode: 409)
    }
    let startedAt = isoTimestamp()
    generationJobs[key] = try makeGenerationJob(
      bookID: bookID,
      chapterNumber: number,
      title: chapter.title,
      phase: "revising",
      message: "原生 InkOSCore 正在修订章节",
      startedAt: startedAt
    )
    Task { await self.performRevision(bookID: bookID, chapter: chapter, note: note, mode: mode, startedAt: startedAt) }
    return ProcessingResponse(message: "原生 InkOSCore 正在修订章节", status: "processing")
  }

  private func performGeneration(
    bookID: String,
    chapterNumber: Int,
    guidance: String?,
    startedAt: String
  ) async {
    let key = generationKey(bookID, chapterNumber)
    do {
      let plan = try synchronizeContinuityProjection(bookID: bookID)
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapterNumber,
        phase: "beat-planning",
        message: "正在规划本章节拍卡",
        startedAt: startedAt
      )
      recordDebug(scope: "generation", message: "chapter.phase", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "phase": "beat-planning",
      ])
      let beat = try await ensureChapterBeat(
        bookID: bookID,
        chapterNumber: chapterNumber,
        plan: plan
      )
      prefetchUpcomingBeatBatch(bookID: bookID, currentChapter: chapterNumber, plan: plan)
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapterNumber,
        phase: "writing",
        message: "正在调用写作模型",
        startedAt: startedAt
      )
      recordDebug(scope: "generation", message: "chapter.phase", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "phase": "writing",
      ])
      let prompt = try generationPrompt(
        bookID: bookID,
        chapterNumber: chapterNumber,
        guidance: guidance,
        beat: beat
      )
      let currentPlan = try synchronizeContinuityProjection(bookID: bookID)
      let (parsed, result) = try await requestChapterPayload(
        prompt: prompt,
        chapterNumber: chapterNumber,
        requireDelta: currentPlan.continuity.policy.requireConsistencyDelta,
        timeout: 600,
        onPartialContent: { [weak self] partial in
          await self?.updateGenerationLiveText(key: key, rawText: partial)
        }
      )
      let title = normalizedChapterTitle(
        string(parsed["title"], fallback: "第\(chapterNumber)章"),
        chapterNumber: chapterNumber
      )
      var content = string(parsed["content"])
      if content.isEmpty { content = result.content }
      content = stripChapterHeading(content)
      let suppliedDelta = parsed["consistencyDelta"] as? [String: Any]
      let rawDelta = suppliedDelta ?? [:]
      let candidateDelta: ContinuityDelta
      do {
        if currentPlan.continuity.policy.requireConsistencyDelta, suppliedDelta == nil {
          throw InkOSCoreError("模型未返回 consistencyDelta（自动补登后仍缺失）", statusCode: 422)
        }
        candidateDelta = try normalizedConsistencyDelta(rawDelta, chapterNumber: chapterNumber)
        let lengthBand = plan.chapterWordBand(for: chapterNumber)
        try validateChapterLength(
          content,
          chapterNumber: chapterNumber,
          minWords: lengthBand.minWords,
          maxWords: lengthBand.maxWords,
          label: "章节正文"
        )
        try validateChapterCraft(
          content,
          chapterNumber: chapterNumber,
          label: "章节正文",
          openingContext: try openingAbilityAnchorContext(
            bookID: bookID,
            before: chapterNumber
          )
        )
      } catch {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error }
        // A local length/craft violation is a deterministic rule failure: an
        // immediate same-context rewrite rarely fixes it and burns tokens. Retain
        // the full draft and stop for manual review — a human rejection then joins
        // the auto-revision loop (see performRevision). The LLM `[hard]` review
        // failure below is what enters the loop automatically.
        try persistGeneratedDraftForRevision(
          bookID: bookID,
          chapterNumber: chapterNumber,
          title: title,
          content: content,
          summary: string(parsed["summary"], fallback: "草稿未通过本地章节规则"),
          rawDelta: suppliedDelta,
          validationError: error,
          startedAt: startedAt
        )
        return
      }

      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapterNumber,
        title: title,
        phase: "reviewing",
        message: "正在执行一致性与写法审核",
        startedAt: startedAt,
        liveText: generationJobs[key]?.liveText
      )
      recordDebug(scope: "generation", message: "chapter.phase", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "phase": "reviewing",
      ])
      let review = try await reviewChapter(
        bookID: bookID,
        chapterNumber: chapterNumber,
        title: title,
        content: content,
        candidateDelta: candidateDelta,
        beat: beat
      )
      let initialAttempt = reviewAttemptRecord(review, attempt: 1)
      if review.pass {
        let reviewObject = reviewRecord(
          review,
          status: "passed",
          attempts: [initialAttempt]
        )
        try writeChapter(
          bookID: bookID,
          number: chapterNumber,
          title: title,
          content: content,
          status: "pending_review",
          llmReview: reviewObject
        )
        try persistConsistencyDelta(
          bookID: bookID,
          chapterNumber: chapterNumber,
          title: title,
          summary: string(parsed["summary"], fallback: review.summary),
          delta: rawDelta
        )
        let finished = isoTimestamp()
        generationJobs[key] = try makeGenerationJob(
          bookID: bookID,
          chapterNumber: chapterNumber,
          title: title,
          phase: "ready-for-review",
          message: "章节已交付人工审核",
          startedAt: startedAt,
          finishedAt: finished,
          liveText: generationJobs[key]?.liveText
        )
        recordDebug(scope: "generation", message: "chapter.completed", data: [
          "bookId": bookID,
          "chapterNumber": chapterNumber,
          "status": "pending_review",
          "model": result.model,
        ])
        return
      }

      let reviewObject = reviewRecord(
        review,
        status: "fixing",
        autoFixed: false,
        attempts: [initialAttempt]
      )
      try writeChapter(
        bookID: bookID,
        number: chapterNumber,
        title: title,
        content: content,
        status: "revision_failed",
        llmReview: reviewObject
      )
      try persistConsistencyDelta(
        bookID: bookID,
        chapterNumber: chapterNumber,
        title: title,
        summary: string(parsed["summary"], fallback: review.summary),
        delta: rawDelta
      )
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapterNumber,
        title: title,
        phase: "llm_fixing",
        message: "初审发现硬问题，正在自动修改并复审",
        startedAt: startedAt,
        liveText: generationJobs[key]?.liveText
      )
      recordDebug(scope: "review", message: "chapter.auto_revision.started", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "issues": review.issues,
      ])
      let failedChapter = try await fetchChapter(bookID: bookID, number: chapterNumber)
      await performRevision(
        bookID: bookID,
        chapter: failedChapter,
        note: automaticRevisionNote(for: review),
        mode: "auto_rewrite",
        startedAt: startedAt,
        initialReview: review
      )
    } catch {
      let finished = isoTimestamp()
      generationJobs[key] = try? makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapterNumber,
        phase: "error",
        message: "章节生成失败",
        startedAt: startedAt,
        finishedAt: finished,
        error: error.localizedDescription,
        liveText: generationJobs[key]?.liveText
      )
      recordDebug(scope: "generation", message: "chapter.failed", level: "error", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "error": error.localizedDescription,
      ])
    }
  }

  /// Result of a single rewrite+re-review round. `review` is nil when the round
  /// threw before producing a reviewable draft (network/JSON/validation error).
  private struct RevisionRoundOutcome {
    let review: NativeReview?
    let title: String
    let content: String
    let error: Error?
    let persisted: Bool
  }

  private func storedNativeReview(_ review: LLMReview?) -> NativeReview? {
    guard let review, !review.isPassed, !review.issueList.isEmpty else { return nil }
    return NativeReview(
      pass: false,
      model: review.model ?? "stored-review",
      summary: review.summary ?? "上一轮审核未通过",
      issues: review.issueList,
      revisionGuidance: review.revisionGuidance ?? "",
      advisories: review.craftAdvisoryList
    )
  }

  func shouldAttemptDeltaOnlyRepair(_ review: NativeReview) -> Bool {
    guard !review.issues.isEmpty else { return false }
    let deltaMarkers = ["delta", "consistencydelta", "差量", "登记", "type字段", "实体分类", "索引分类"]
    let repairMarkers = ["缺少", "遗漏", "未登记", "需要在", "应在", "补充", "补全", "登记", "记录", "类型", "type字段", "分类", "字段", " id", "id ", "统一"]
    let proseOrConflictMarkers = [
      "正文", "剧情", "叙事", "字数", "文风", "节拍", "因果", "行为", "自相矛盾",
      "冲突", "不可变", "违反", "不允许新增", "越界", "时间线错误",
    ]
    return review.issues.allSatisfy { issue in
      let lowered = issue.lowercased()
      return deltaMarkers.contains(where: lowered.contains)
        && repairMarkers.contains(where: lowered.contains)
        && !proseOrConflictMarkers.contains(where: lowered.contains)
    }
  }

  /// Drives up to `maxAutoRevisionRounds` rewrite+re-review rounds. The first
  /// round uses the caller's note (a human rejection note, or the note derived
  /// from `initialReview` for an automatic fix). Each failed round feeds its own
  /// review findings into the next round's note. Any round that passes finalizes
  /// to `pending_review` and returns; exhausting the rounds finalizes to
  /// `revision_failed` with the full attempt history.
  private func performRevision(
    bookID: String,
    chapter: ChapterDetail,
    note: String,
    mode: String,
    startedAt: String,
    initialReview: NativeReview? = nil
  ) async {
    let key = generationKey(bookID, chapter.number)
    let triggerReview = initialReview ?? storedNativeReview(chapter.llmReview)
    var attempts: [[String: Any]] = initialReview.map {
      [reviewAttemptRecord($0, attempt: 1)]
    } ?? (chapter.llmReview?.attempts ?? []).enumerated().map {
      reviewAttemptRecord($0.element, attempt: $0.offset + 1)
    }
    if initialReview == nil, attempts.isEmpty, let triggerReview {
      attempts = [reviewAttemptRecord(triggerReview, attempt: 1)]
    }
    // Each round rewrites the latest draft, not the original, so successive
    // rounds accumulate improvements instead of restarting from scratch.
    var baseChapter = chapter
    var currentNote = note
    var currentMode = mode
    var lastError: Error?
    var lastReview: NativeReview?
    var automaticLeadIn = false
    var anyRoundPersisted = false
    var stopBeforeRewrite = false
    var completedRewriteRounds = 0

    if let triggerReview, shouldRevalidateStoredDraft(note: note, review: triggerReview) {
      automaticLeadIn = true
      let outcome = await performStoredDraftRevalidation(
        bookID: bookID,
        chapter: chapter,
        note: note,
        startedAt: startedAt,
        priorAttempts: attempts
      )
      anyRoundPersisted = outcome.persisted
      let attemptNumber = attempts.count + 1
      if let review = outcome.review {
        attempts.append(reviewAttemptRecord(review, attempt: attemptNumber))
        lastReview = review
        if review.pass {
          generationJobs[key] = try? makeGenerationJob(
            bookID: bookID,
            chapterNumber: chapter.number,
            title: chapter.title,
            phase: "ready-for-review",
            message: "原正文重新校验通过，未执行重写",
            startedAt: startedAt,
            finishedAt: isoTimestamp(),
            attempts: attempts
          )
          recordDebug(scope: "review", message: "chapter.revalidation.completed", data: [
            "bookId": bookID,
            "chapterNumber": chapter.number,
            "status": "pending_review",
          ])
          return
        }
        currentNote = automaticRevisionNote(for: review)
        currentMode = "auto_rewrite"
      } else {
        attempts.append([
          "pass": false,
          "status": "error",
          "attempt": attemptNumber,
          "error": outcome.error?.localizedDescription ?? "原正文重新校验异常",
          "reviewedAt": isoTimestamp(),
        ])
        lastError = outcome.error
        stopBeforeRewrite = outcome.persisted
        currentNote = "\(note)\n\n【原正文重新校验仍未通过】\n\(outcome.error?.localizedDescription ?? "")"
        currentMode = "auto_rewrite"
      }
    }

    let deltaRepairReview = lastReview ?? (automaticLeadIn ? nil : triggerReview)
    if !stopBeforeRewrite, let deltaRepairReview, shouldAttemptDeltaOnlyRepair(deltaRepairReview) {
      automaticLeadIn = true
      let outcome = await performDeltaOnlyRevision(
        bookID: bookID,
        chapter: chapter,
        note: currentNote,
        startedAt: startedAt,
        priorAttempts: attempts
      )
      anyRoundPersisted = anyRoundPersisted || outcome.persisted
      let attemptNumber = attempts.count + 1
      if let review = outcome.review {
        attempts.append(reviewAttemptRecord(review, attempt: attemptNumber))
        lastReview = review
        if review.pass {
          generationJobs[key] = try? makeGenerationJob(
            bookID: bookID,
            chapterNumber: chapter.number,
            title: chapter.title,
            phase: "ready-for-review",
            message: "一致性登记已修复，正文未重写，等待人工审核",
            startedAt: startedAt,
            finishedAt: isoTimestamp(),
            attempts: attempts
          )
          recordDebug(scope: "review", message: "chapter.delta_revision.completed", data: [
            "bookId": bookID,
            "chapterNumber": chapter.number,
            "status": "pending_review",
          ])
          return
        }
        currentNote = automaticRevisionNote(for: review)
        currentMode = "auto_rewrite"
      } else {
        attempts.append([
          "pass": false,
          "status": "error",
          "attempt": attemptNumber,
          "error": outcome.error?.localizedDescription ?? "Delta 修复异常",
          "reviewedAt": isoTimestamp(),
        ])
        lastError = outcome.error
        stopBeforeRewrite = outcome.persisted
        currentNote = "\(note)\n\n【Delta 单独修复失败，允许重写正文与 Delta】\n\(outcome.error?.localizedDescription ?? "")"
        currentMode = "auto_rewrite"
      }
    }

    if stopBeforeRewrite {
      finalizeRevisionFailure(
        bookID: bookID,
        chapter: baseChapter,
        originalChapter: chapter,
        note: currentNote,
        mode: currentMode,
        attempts: attempts,
        startedAt: startedAt,
        lastReview: lastReview,
        lastError: lastError,
        anyRoundPersisted: anyRoundPersisted,
        automatic: true,
        roundsCompleted: 0
      )
      return
    }

    for round in 1...maxAutoRevisionRounds {
      completedRewriteRounds = round
      // A round is "automatic" when it follows an initial failure or is not the
      // very first manual pass; that drives the UI badge and autoFixed flag.
      let isAutomaticRound = initialReview != nil || automaticLeadIn || round > 1
      let outcome = await performRevisionRound(
        bookID: bookID,
        baseChapter: baseChapter,
        originalContent: chapter.content,
        note: currentNote,
        mode: currentMode,
        round: round,
        startedAt: startedAt,
        priorAttempts: attempts,
        isAutomaticRound: isAutomaticRound
      )
      anyRoundPersisted = anyRoundPersisted || outcome.persisted
      let attemptNumber = attempts.count + 1
      if let review = outcome.review {
        attempts.append(reviewAttemptRecord(review, attempt: attemptNumber))
        lastReview = review
        if review.pass {
          finalizeRevisionSuccess(
            bookID: bookID,
            chapterNumber: chapter.number,
            title: outcome.title,
            attempts: attempts,
            round: round,
            startedAt: startedAt,
            automatic: isAutomaticRound
          )
          return
        }
        // Failed review: carry this round's findings into the next round.
        baseChapter = ChapterDetail(from: baseChapter, title: outcome.title, content: outcome.content)
        currentNote = automaticRevisionNote(for: review)
        currentMode = "auto_rewrite"
        lastError = nil
      } else {
        // The round threw before yielding a reviewable draft. Record the error
        // as an attempt and, if rounds remain, retry with the error folded into
        // the note so the model knows what to avoid.
        attempts.append([
          "pass": false,
          "status": "error",
          "attempt": attemptNumber,
          "error": outcome.error?.localizedDescription ?? "修订轮次异常",
          "reviewedAt": isoTimestamp(),
        ])
        lastError = outcome.error
        if outcome.persisted {
          baseChapter = ChapterDetail(
            from: baseChapter,
            title: outcome.title,
            content: outcome.content
          )
        }
        currentNote = "\(currentNote)\n\n【上一轮修订异常，请修正后重写】\n\(outcome.error?.localizedDescription ?? "")"
        currentMode = "auto_rewrite"
      }

      if outcome.error != nil, outcome.persisted { break }
      if round < maxAutoRevisionRounds {
        generationJobs[key] = try? makeGenerationJob(
          bookID: bookID,
          chapterNumber: chapter.number,
          title: baseChapter.title,
          phase: "llm_fixing",
          message: "第 \(round) 次修改未通过，正在进行第 \(round + 1) 次自动修改",
          startedAt: startedAt,
          revisionRound: round + 1,
          maxRevisionRounds: maxAutoRevisionRounds,
          attempts: attempts
        )
      }
    }

    finalizeRevisionFailure(
      bookID: bookID,
      chapter: baseChapter,
      originalChapter: chapter,
      note: currentNote,
      mode: currentMode,
      attempts: attempts,
      startedAt: startedAt,
      lastReview: lastReview,
      lastError: lastError,
      anyRoundPersisted: anyRoundPersisted,
      automatic: initialReview != nil || automaticLeadIn || maxAutoRevisionRounds > 1,
      roundsCompleted: completedRewriteRounds
    )
  }

  /// The stored delta for a chapter that is being repaired, treating "never
  /// written" as an empty delta rather than a hard error.
  ///
  /// `chapterConsistencyDelta` throws when the runtime file is absent, which is
  /// the right contract for approval and projection — those must not proceed on
  /// a chapter with no registration. Repair is the opposite case: a draft whose
  /// prose was recovered from a torn shell, or whose delta request failed, has
  /// no file yet and is exactly what needs repairing. Throwing there sent the
  /// chapter to a full rewrite and discarded the prose the recovery had just
  /// saved, so both repair entry points start from an empty delta instead.
  private func repairableConsistencyDelta(
    bookID: String,
    chapterNumber: Int,
    operation: String
  ) -> ContinuityDelta {
    do {
      return try chapterConsistencyDelta(bookID: bookID, chapterNumber: chapterNumber)
    } catch {
      recordDebug(scope: "review", message: "chapter.delta.missingForRepair", level: "warning", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "operation": operation,
        "error": error.localizedDescription,
      ])
      return ContinuityDelta()
    }
  }

  private func shouldRevalidateStoredDraft(note: String, review: NativeReview) -> Bool {
    guard review.model == "native-draft-validator" else { return false }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedGuidance = review.revisionGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
    if !storedGuidance.isEmpty, trimmed == storedGuidance { return true }
    let markers = [
      "仅重新校验原文", "仅重新审核原文", "仅复审原文", "只复审原文",
      "不改正文", "无需重写", "保持正文不变", "原文保持不变",
    ]
    return markers.contains(where: trimmed.contains)
  }

  private func performStoredDraftRevalidation(
    bookID: String,
    chapter: ChapterDetail,
    note: String,
    startedAt: String,
    priorAttempts: [[String: Any]]
  ) async -> RevisionRoundOutcome {
    let key = generationKey(bookID, chapter.number)
    var didWriteChapter = false
    do {
      let plan = try synchronizeContinuityProjection(bookID: bookID)
      let band = plan.chapterWordBand(for: chapter.number)
      try validateChapterLength(
        chapter.content,
        chapterNumber: chapter.number,
        minWords: band.minWords,
        maxWords: band.maxWords,
        label: "原章节正文"
      )
      try validateChapterCraft(
        chapter.content,
        chapterNumber: chapter.number,
        label: "原章节正文",
        openingContext: try openingAbilityAnchorContext(
          bookID: bookID,
          before: chapter.number
        )
      )
      let candidateDelta = repairableConsistencyDelta(
        bookID: bookID,
        chapterNumber: chapter.number,
        operation: "revalidation"
      )
      let beat = try chapterBeat(bookID: bookID, chapterNumber: chapter.number)
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        phase: "reviewing",
        message: "本地规则已通过，正在复审原正文",
        startedAt: startedAt,
        attempts: priorAttempts
      )
      recordDebug(scope: "review", message: "chapter.revalidation.started", data: [
        "bookId": bookID,
        "chapterNumber": chapter.number,
      ])
      let review = try await reviewChapter(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        content: chapter.content,
        candidateDelta: candidateDelta,
        beat: beat,
        excludingChapter: chapter.number
      )
      try writeChapter(
        bookID: bookID,
        number: chapter.number,
        title: chapter.title,
        content: chapter.content,
        status: review.pass ? "pending_review" : "revision_failed",
        llmReview: reviewRecord(
          review,
          status: review.pass ? "passed" : "failed",
          attempts: priorAttempts + [
            reviewAttemptRecord(review, attempt: priorAttempts.count + 1),
          ]
        )
      )
      didWriteChapter = true
      try updateStateChapter(bookID: bookID, number: chapter.number) { record in
        var history = record["revisionHistory"] as? [[String: Any]] ?? []
        history.append([
          "time": isoTimestamp(),
          "note": note,
          "type": "revalidation",
          "oldContentLength": proseCount(chapter.content),
          "newContentLength": proseCount(chapter.content),
          "success": review.pass,
          "reviseMode": "revalidation",
        ])
        record["revisionHistory"] = history
      }
      _ = try synchronizeContinuityProjection(bookID: bookID)
      return RevisionRoundOutcome(
        review: review,
        title: chapter.title,
        content: chapter.content,
        error: nil,
        persisted: true
      )
    } catch {
      recordDebug(scope: "review", message: "chapter.revalidation.failed", level: "warning", data: [
        "bookId": bookID,
        "chapterNumber": chapter.number,
        "error": error.localizedDescription,
      ])
      return RevisionRoundOutcome(
        review: nil,
        title: chapter.title,
        content: chapter.content,
        error: error,
        persisted: didWriteChapter
      )
    }
  }

  private func performDeltaOnlyRevision(
    bookID: String,
    chapter: ChapterDetail,
    note: String,
    startedAt: String,
    priorAttempts: [[String: Any]]
  ) async -> RevisionRoundOutcome {
    let key = generationKey(bookID, chapter.number)
    var didWriteChapter = false
    do {
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        phase: "llm_fixing",
        message: "正在只修复一致性登记，不重写正文",
        startedAt: startedAt,
        attempts: priorAttempts
      )
      recordDebug(scope: "review", message: "chapter.delta_revision.started", data: [
        "bookId": bookID,
        "chapterNumber": chapter.number,
      ])
      let currentDelta = repairableConsistencyDelta(
        bookID: bookID,
        chapterNumber: chapter.number,
        operation: "deltaOnlyRepair"
      )
      let repairedRaw = try await requestConsistencyDeltaRepair(
        chapterNumber: chapter.number,
        title: chapter.title,
        content: chapter.content,
        currentDelta: currentDelta,
        findings: note
      )
      let candidateDelta = try normalizedConsistencyDelta(
        repairedRaw,
        chapterNumber: chapter.number
      )
      let beat = try chapterBeat(bookID: bookID, chapterNumber: chapter.number)
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        phase: "reviewing",
        message: "一致性登记已修复，正在复审原正文",
        startedAt: startedAt,
        attempts: priorAttempts
      )
      let review = try await reviewChapter(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        content: chapter.content,
        candidateDelta: candidateDelta,
        beat: beat,
        excludingChapter: chapter.number
      )
      try writeChapter(
        bookID: bookID,
        number: chapter.number,
        title: chapter.title,
        content: chapter.content,
        status: review.pass ? "pending_review" : "revision_failed",
        llmReview: reviewRecord(
          review,
          status: review.pass ? "passed" : "failed",
          autoFixed: true,
          attempts: priorAttempts + [
            reviewAttemptRecord(review, attempt: priorAttempts.count + 1),
          ]
        )
      )
      didWriteChapter = true
      try persistConsistencyDelta(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        summary: review.summary,
        delta: repairedRaw
      )
      try updateStateChapter(bookID: bookID, number: chapter.number) { record in
        var history = record["revisionHistory"] as? [[String: Any]] ?? []
        history.append([
          "time": isoTimestamp(),
          "note": note,
          "type": "delta_repair",
          "oldContentLength": proseCount(chapter.content),
          "newContentLength": proseCount(chapter.content),
          "success": review.pass,
          "reviseMode": "delta_repair",
        ])
        record["revisionHistory"] = history
      }
      _ = try synchronizeContinuityProjection(bookID: bookID)
      return RevisionRoundOutcome(
        review: review,
        title: chapter.title,
        content: chapter.content,
        error: nil,
        persisted: true
      )
    } catch {
      recordDebug(scope: "review", message: "chapter.delta_revision.failed", level: "warning", data: [
        "bookId": bookID,
        "chapterNumber": chapter.number,
        "error": error.localizedDescription,
      ])
      return RevisionRoundOutcome(
        review: nil,
        title: chapter.title,
        content: chapter.content,
        error: error,
        persisted: didWriteChapter
      )
    }
  }

  private func requestConsistencyDeltaRepair(
    chapterNumber: Int,
    title: String,
    content: String,
    currentDelta: ContinuityDelta,
    findings: String
  ) async throws -> [String: Any] {
    let currentJSON = String(data: try encoder.encode(currentDelta), encoding: .utf8) ?? "{}"
    let prompt = """
      你是 InkOS 一致性登记修复器。正文已经定稿，本次禁止改写正文、标题、剧情、字数或文风，只修复 consistencyDelta。
      根据审核意见校正当前 Delta，保留没有问题的 ID 和字段，只修改审核点名的登记错误；正文未支持的事实不得新增。
      entities.type 最终只能输出五个英文值：character、object、location、faction、concept。审核意见中的 item、物品、物件、设备、资源或储备一律输出 object，地点或场所输出 location，人物输出 character。
      只输出修复后的 consistencyDelta JSON：{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}。

      【审核意见】
      \(findings)

      【当前 consistencyDelta】
      \(currentJSON)

      【固定正文】
      第\(chapterNumber)章 \(title)
      \(content)
      """
    // Streamed for the transport, not for a preview — see the beat batch call.
    let result = try await requestLLM(
      prompt: prompt,
      role: .primary,
      json: true,
      timeout: 900,
      onPartialContent: { _ in }
    )
    guard let object = parseJSONObject(result.content) else {
      throw InkOSCoreError("Delta 单独修复未返回合法 JSON", statusCode: 422)
    }
    if let delta = object["consistencyDelta"] as? [String: Any] { return delta }
    if object["upsert"] != nil { return object }
    throw InkOSCoreError("Delta 单独修复未返回 consistencyDelta", statusCode: 422)
  }

  /// One rewrite+re-review round. On success it persists the new draft, delta,
  /// and revision-history entry, and returns the review. Any thrown error is
  /// captured into the outcome (`review == nil`) so the caller's loop can decide
  /// whether to retry or finalize — a single round never aborts the loop.
  private func performRevisionRound(
    bookID: String,
    baseChapter: ChapterDetail,
    originalContent: String,
    note: String,
    mode: String,
    round: Int,
    startedAt: String,
    priorAttempts: [[String: Any]],
    isAutomaticRound: Bool
  ) async -> RevisionRoundOutcome {
    let key = generationKey(bookID, baseChapter.number)
    var latestTitle = baseChapter.title
    var latestContent = baseChapter.content
    var didWriteChapter = false
    do {
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: baseChapter.number,
        title: baseChapter.title,
        phase: isAutomaticRound ? "llm_fixing" : "revising",
        message: isAutomaticRound
          ? "正在进行第 \(round) 次自动修改"
          : "原生 InkOSCore 正在修订章节",
        startedAt: startedAt,
        revisionRound: round,
        maxRevisionRounds: maxAutoRevisionRounds,
        attempts: priorAttempts
      )
      let plan = try synchronizeContinuityProjection(bookID: bookID)
      let beat = try chapterBeat(bookID: bookID, chapterNumber: baseChapter.number)
      let revisionBand = plan.chapterWordBand(for: baseChapter.number)
      let minWords = revisionBand.minWords
      let maxWords = revisionBand.maxWords
      // 计算当前字数、验收上限（与 validateChapterLength 保持一致）和方向提示，
      // 避免模型在"字数不够→字数太多→字数不够"之间反复震荡。
      let currentCount = proseCount(baseChapter.content)
      let ceiling = maxWords + max(200, maxWords / 10)
      let targetWords = (minWords + maxWords) / 2
      let wordGapInstruction: String
      if currentCount < minWords {
        wordGapInstruction =
          "还差约 \(minWords - currentCount) 字，需要展开场景或补充细节；" +
          "切勿以凑字符号、空行或重复句子填充。"
      } else if currentCount > ceiling {
        wordGapInstruction =
          "已超出验收上限 \(ceiling) 字约 \(currentCount - ceiling) 字，" +
          "必须精简或将多余剧情移至后续章节。"
      } else if currentCount > maxWords {
        wordGapInstruction =
          "超出软上限约 \(currentCount - maxWords) 字（验收上限 \(ceiling) 字），建议适当精简。"
      } else {
        wordGapInstruction = "字数已在目标区间，修订以质量为主，保持字数基本不变。"
      }
      // validateChapterLength 还要求中文字符数 >= minWords * 85%。此前 prompt 从不提这条，
      // 模型多次因差几个字的密度不足而整轮报废，必须显式给出当前值和下限。
      let currentBodyCount = bodyWordCount(baseChapter.content)
      let bodyFloor = minWords * 85 / 100
      let densityInstruction = currentBodyCount < bodyFloor
        ? "当前中文字符仅 \(currentBodyCount) 个，低于密度下限 \(bodyFloor) 个（还差 \(bodyFloor - currentBodyCount) 个），"
          + "必须用真实的场景、动作与对话补足，不能靠标点、空行或符号堆砌。"
        : "另需保证中文字符不少于 \(bodyFloor) 个（当前 \(currentBodyCount) 个），标点与空行不计入密度。"
      let craft = try craftDirectives(bookID: bookID, chapterNumber: baseChapter.number)
      let context = try storyContext(bookID: bookID, maxCharacters: 60_000)
      let beatSection = beat.map(beatBriefText)
        ?? "（本章没有节拍卡，按既有正文范围修订，不要扩大本章承载的剧情量）"
      let prompt = """
        你是 InkOS 章节修订器。请依据修改意见修订完整正文，保持既有设定、人物知识边界、持久物品和前后章因果。
        此前章节与本章既有正文确立的中断、不可用或耗尽状态（断信号、断电、断水、资源耗尽等）有约束力：修订稿使用通信、电力、设施或消耗品之前必须确认其可用；改变状态可用性时必须在正文写出发生的时刻与原因；同章之内不得自相矛盾。
        当前正文 \(currentCount) 字；目标区间 \(minWords)–\(maxWords) 字（参考目标 \(targetWords) 字，验收上限 \(ceiling) 字）。\(wordGapInstruction)
        \(densityInstruction)
        修订只在本章节拍卡范围内进行：不得引入节拍卡禁止清单中的内容，不得把后续章节的剧情提前到本章。
        consistencyDelta 必须完整描述修订后本章的新贡献；旧版本仅由本章产生的记录会自动退出。新增或更新写入 upsert；remove 只用于正文事件明确终止的既有跨章记录。
        修订稿的 Delta 必须覆盖修订后正文的全部事实：原版本已登记且仍然成立的实体与伏笔必须保留，修订不是从零登记；正文出现的每个具名人物、地点、持久物品都必须登记；本章兑现或推翻的既有伏笔必须在 remove.hooks 中按 ID 关闭；不得静默丢弃索引中的既有实体。
        entities.type 只能输出 character、object、location、faction、concept；物品、设备、资源和储备统一写 object，不得写 item 或中文类型名。
        只输出 JSON：{"title":"章节标题","content":"完整正文","summary":"修订摘要","consistencyDelta":{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"","name":"","type":"character|object|location|faction|concept"}],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}}。
        修订模式：\(mode)
        修改意见：\(note)

        \(craft)

        【本章节拍卡】
        \(beatSection)

        【全书约束与状态】
        \(context)

        【原章节】
        第\(baseChapter.number)章 \(baseChapter.title)
        \(baseChapter.content)
        """
      let refreshedPlan = try synchronizeContinuityProjection(bookID: bookID)
      let (parsed, result) = try await requestChapterPayload(
        prompt: prompt,
        chapterNumber: baseChapter.number,
        requireDelta: refreshedPlan.continuity.policy.requireConsistencyDelta,
        timeout: 600,
        onPartialContent: { [weak self] partial in
          await self?.updateGenerationLiveText(key: key, rawText: partial)
        }
      )
      let suppliedDelta = parsed["consistencyDelta"] as? [String: Any]
      if refreshedPlan.continuity.policy.requireConsistencyDelta, suppliedDelta == nil {
        throw InkOSCoreError("模型未返回 consistencyDelta（自动补登后仍缺失）", statusCode: 422)
      }
      let rawDelta = suppliedDelta ?? [:]
      let candidateDelta = try normalizedConsistencyDelta(rawDelta, chapterNumber: baseChapter.number)
      let title = normalizedChapterTitle(
        string(parsed["title"], fallback: baseChapter.title),
        chapterNumber: baseChapter.number
      )
      let content = stripChapterHeading(string(parsed["content"], fallback: result.content))
      latestTitle = title
      latestContent = content
      try validateChapterLength(
        content,
        chapterNumber: baseChapter.number,
        minWords: minWords,
        maxWords: maxWords,
        label: "修订正文"
      )
      try validateChapterCraft(
        content,
        chapterNumber: baseChapter.number,
        label: "修订正文",
        openingContext: try openingAbilityAnchorContext(
          bookID: bookID,
          before: baseChapter.number
        )
      )
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: baseChapter.number,
        title: title,
        phase: "reviewing",
        message: "正在执行第 \(round) 次修订后一致性审核",
        startedAt: startedAt,
        revisionRound: round,
        maxRevisionRounds: maxAutoRevisionRounds,
        attempts: priorAttempts
      )
      recordDebug(scope: "generation", message: "chapter.phase", data: [
        "bookId": bookID, "chapterNumber": baseChapter.number, "phase": "reviewing", "round": round,
      ])
      let review = try await reviewChapter(
        bookID: bookID,
        chapterNumber: baseChapter.number,
        title: title,
        content: content,
        candidateDelta: candidateDelta,
        beat: beat,
        excludingChapter: baseChapter.number
      )
      try writeChapter(
        bookID: bookID,
        number: baseChapter.number,
        title: title,
        content: content,
        status: review.pass ? "pending_review" : "revision_failed",
        llmReview: reviewRecord(
          review,
          status: review.pass ? "passed" : "failed",
          autoFixed: isAutomaticRound ? true : nil,
          attempts: priorAttempts + [reviewAttemptRecord(review, attempt: priorAttempts.count + 1)]
        )
      )
      didWriteChapter = true
      try persistConsistencyDelta(
        bookID: bookID,
        chapterNumber: baseChapter.number,
        title: title,
        summary: string(parsed["summary"], fallback: review.summary),
        delta: rawDelta
      )
      try updateStateChapter(bookID: bookID, number: baseChapter.number) { record in
        var history = record["revisionHistory"] as? [[String: Any]] ?? []
        history.append([
          "time": isoTimestamp(),
          "note": note,
          "type": mode,
          "oldContentLength": proseCount(baseChapter.content),
          "newContentLength": proseCount(content),
          "success": review.pass,
          "reviseMode": mode,
          "round": round,
        ])
        record["revisionHistory"] = history
      }
      _ = try synchronizeContinuityProjection(bookID: bookID)
      // Later beats were planned against the previous version of this chapter,
      // so they must be re-planned once its text changed. Cache cleanup only:
      // the draft is already persisted, so a failure here must not fail the round.
      do {
        _ = try await invalidateChapterBeats(bookID: bookID, fromChapter: baseChapter.number + 1)
      } catch {
        recordDebug(
          scope: "craft", message: "chapter_beats.invalidate_failed", level: "error",
          data: [
            "bookId": bookID,
            "fromChapter": baseChapter.number + 1,
            "error": error.localizedDescription,
          ])
      }
      return RevisionRoundOutcome(
        review: review, title: title, content: content, error: nil, persisted: true
      )
    } catch {
      recordDebug(scope: "review", message: "chapter.revision_round.failed", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": baseChapter.number,
        "round": round,
        "error": error.localizedDescription,
      ])
      return RevisionRoundOutcome(
        review: nil,
        title: latestTitle,
        content: latestContent,
        error: error,
        persisted: didWriteChapter
      )
    }
  }

  /// Finalizes a chapter that passed re-review: the round already persisted the
  /// draft, so this only marks the job ready for manual review.
  private func finalizeRevisionSuccess(
    bookID: String,
    chapterNumber: Int,
    title: String,
    attempts: [[String: Any]],
    round: Int,
    startedAt: String,
    automatic: Bool
  ) {
    generationJobs[generationKey(bookID, chapterNumber)] = try? makeGenerationJob(
      bookID: bookID,
      chapterNumber: chapterNumber,
      title: title,
      phase: "ready-for-review",
      message: automatic
        ? "第 \(round) 次自动修改通过，等待人工审核"
        : "修订完成，等待人工审核",
      startedAt: startedAt,
      finishedAt: isoTimestamp(),
      liveText: generationJobs[generationKey(bookID, chapterNumber)]?.liveText,
      revisionRound: round,
      maxRevisionRounds: maxAutoRevisionRounds,
      attempts: attempts
    )
    recordDebug(scope: "review", message: "chapter.auto_revision.completed", data: [
      "bookId": bookID,
      "chapterNumber": chapterNumber,
      "status": "pending_review",
      "rounds": round,
    ])
  }

  /// Finalizes after all rounds failed. The last round that produced a draft
  /// already persisted `revision_failed`; if every round threw before producing
  /// one, this writes the failure record against the best content available so
  /// the chapter still carries the attempt history and a status the UI can act on.
  private func finalizeRevisionFailure(
    bookID: String,
    chapter: ChapterDetail,
    originalChapter: ChapterDetail,
    note: String,
    mode: String,
    attempts: [[String: Any]],
    startedAt: String,
    lastReview: NativeReview?,
    lastError: Error?,
    anyRoundPersisted: Bool,
    automatic: Bool,
    roundsCompleted: Int
  ) {
    let key = generationKey(bookID, chapter.number)
    let errorText = lastError?.localizedDescription
      ?? lastReview?.issues.joined(separator: "；")
      ?? "自动修改多轮后仍未通过"
    let review: NativeReview
    if let lastError {
      review = NativeReview(
        pass: false,
        model: "native-revision-loop",
        summary: anyRoundPersisted ? "最新自动修改轮次发生异常。" : "多轮自动修改均未产出可复审的草稿。",
        issues: ["[hard] 修订异常：\(lastError.localizedDescription)"],
        revisionGuidance: "请根据错误信息修正后重新提交修改。"
      )
    } else if let lastReview {
      review = lastReview
    } else {
      review = NativeReview(
        pass: false,
        model: "native-revision-loop",
        summary: "自动修改结束，但没有得到可复审结果。",
        issues: [],
        revisionGuidance: "请重新提交修改。"
      )
    }
    try? writeChapter(
      bookID: bookID,
      number: chapter.number,
      title: chapter.title,
      content: chapter.content,
      status: "revision_failed",
      llmReview: reviewRecord(
        review,
        status: "failed",
        autoFixed: automatic ? true : nil,
        rewriteError: lastError?.localizedDescription,
        attempts: attempts
      )
    )
    if !anyRoundPersisted {
      try? updateStateChapter(bookID: bookID, number: chapter.number) { record in
        var history = record["revisionHistory"] as? [[String: Any]] ?? []
        history.append([
          "time": isoTimestamp(),
          "note": note,
          "type": mode,
          "oldContentLength": proseCount(originalChapter.content),
          "newContentLength": proseCount(originalChapter.content),
          "success": false,
          "reviseMode": mode,
          "error": errorText,
        ])
        record["revisionHistory"] = history
      }
    }
    let failureMessage: String
    if lastError != nil, roundsCompleted == 0 {
      failureMessage = "复审结果落盘后处理异常，等待人工处理"
    } else if lastError != nil, roundsCompleted < maxAutoRevisionRounds {
      failureMessage = "第 \(roundsCompleted) 次修改落盘后处理异常，等待人工处理"
    } else {
      failureMessage = "已自动修改 \(roundsCompleted) 次仍未通过，等待人工修改"
    }
    generationJobs[key] = try? makeGenerationJob(
      bookID: bookID,
      chapterNumber: chapter.number,
      title: chapter.title,
      phase: "revision_failed",
      message: failureMessage,
      startedAt: startedAt,
      finishedAt: isoTimestamp(),
      error: errorText,
      liveText: generationJobs[key]?.liveText,
      revisionRound: roundsCompleted > 0 ? roundsCompleted : nil,
      maxRevisionRounds: maxAutoRevisionRounds,
      attempts: attempts
    )
    recordDebug(scope: "review", message: "chapter.auto_revision.exhausted", level: "warning", data: [
      "bookId": bookID,
      "chapterNumber": chapter.number,
      "rounds": roundsCompleted,
      "automatic": automatic,
      "error": errorText,
    ])
  }

  private func reviewRecord(
    _ review: NativeReview,
    status: String,
    autoFixed: Bool? = nil,
    rewriteError: String? = nil,
    attempts: [[String: Any]] = []
  ) -> [String: Any] {
    var record: [String: Any] = [
      "status": status,
      "model": review.model,
      "summary": review.summary,
      "issues": review.issues,
      "craftAdvisories": review.advisories,
      "revisionGuidance": review.revisionGuidance,
      "reviewedAt": isoTimestamp(),
      "attempts": attempts,
    ]
    if let autoFixed { record["autoFixed"] = autoFixed }
    if let rewriteError, !rewriteError.isEmpty { record["rewriteError"] = rewriteError }
    return record
  }

  private func persistGeneratedDraftForRevision(
    bookID: String,
    chapterNumber: Int,
    title: String,
    content: String,
    summary: String,
    rawDelta: [String: Any]?,
    validationError: Error,
    startedAt: String
  ) throws {
    let key = generationKey(bookID, chapterNumber)
    let errorMessage = validationError.localizedDescription
    let issue = "[hard] 本地章节规则：\(errorMessage)"
    let review = NativeReview(
      pass: false,
      model: "native-draft-validator",
      summary: "完整草稿已保留，等待修改后复审。",
      issues: [issue],
      revisionGuidance: "保留已生成的正文，按本地审核意见修改后重新提交审核。"
    )
    let reviewObject = reviewRecord(
      review,
      status: "failed",
      autoFixed: false,
      attempts: [reviewAttemptRecord(review, attempt: 1)]
    )
    try writeChapter(
      bookID: bookID,
      number: chapterNumber,
      title: title,
      content: content,
      status: "revision_failed",
      llmReview: reviewObject
    )
    if let rawDelta {
      do {
        try persistConsistencyDelta(
          bookID: bookID,
          chapterNumber: chapterNumber,
          title: title,
          summary: summary,
          delta: rawDelta
        )
      } catch {
        recordDebug(scope: "continuity", message: "chapter.delta_retain_failed", level: "warning", data: [
          "bookId": bookID,
          "chapterNumber": chapterNumber,
          "error": error.localizedDescription,
        ])
      }
    }
    generationJobs[key] = try? makeGenerationJob(
      bookID: bookID,
      chapterNumber: chapterNumber,
      title: title,
      phase: "revision_failed",
      message: "草稿已保留，等待修改",
      startedAt: startedAt,
      finishedAt: isoTimestamp(),
      error: errorMessage,
      liveText: generationJobs[key]?.liveText
    )
    recordDebug(scope: "generation", message: "chapter.validation_failed_retained", level: "warning", data: [
      "bookId": bookID,
      "chapterNumber": chapterNumber,
      "error": errorMessage,
      "status": "revision_failed",
    ])
  }

  private func reviewAttemptRecord(_ review: NativeReview, attempt: Int) -> [String: Any] {
    [
      "pass": review.pass,
      "status": review.pass ? "passed" : "failed",
      "attempt": attempt,
      "model": review.model,
      "summary": review.summary,
      "issues": review.issues,
      "revisionGuidance": review.revisionGuidance,
      "reviewedAt": isoTimestamp(),
    ]
  }

  private func reviewAttemptRecord(_ stored: ReviewAttempt, attempt: Int) -> [String: Any] {
    var record: [String: Any] = ["attempt": attempt]
    if let pass = stored.pass { record["pass"] = pass }
    if let status = stored.status { record["status"] = status }
    if let model = stored.model { record["model"] = model }
    if let summary = stored.summary { record["summary"] = summary }
    if let issues = stored.issues { record["issues"] = issues }
    if let guidance = stored.revisionGuidance { record["revisionGuidance"] = guidance }
    if let reviewedAt = stored.reviewedAt { record["reviewedAt"] = reviewedAt }
    if let baseURL = stored.baseUrl { record["baseUrl"] = baseURL }
    if let error = stored.error { record["error"] = error }
    if let latency = stored.latencyMs { record["latencyMs"] = latency }
    return record
  }

  private func automaticRevisionNote(for review: NativeReview) -> String {
    var sections = ["以下是系统初审发现的硬问题。请逐项修正后重写完整正文与 consistencyDelta。"]
    let guidance = review.revisionGuidance.trimmingCharacters(in: .whitespacesAndNewlines)
    if !guidance.isEmpty { sections.append("【修改方案】\n\(guidance)") }
    if !review.issues.isEmpty {
      sections.append("【必须解决的问题】\n" + review.issues.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
  }

  struct NativeReview: Sendable {
    let pass: Bool
    let model: String
    let summary: String
    let issues: [String]
    let revisionGuidance: String

    /// Craft findings that do not block delivery to manual review. They are
    /// recorded so the human reviewer and any later revision can act on them.
    var advisories: [String] = []
  }

  /// Reviews continuity (blocking) and craft quality (advisory) in one pass.
  /// Only `[hard]` issues fail a chapter: craft findings must not turn every
  /// chapter into `revision_failed`, or the pipeline stalls on taste.
  /// Internal (not private) so drivers can re-review stored chapters when
  /// validating review-rule changes.
  func reviewChapter(
    bookID: String,
    chapterNumber: Int,
    title: String,
    content: String,
    candidateDelta: ContinuityDelta,
    beat: ChapterBeat? = nil,
    excludingChapter: Int? = nil
  ) async throws -> NativeReview {
    let projected: LongFormContinuity
    do {
      projected = try validateCandidateContinuity(
        bookID: bookID,
        chapterNumber: chapterNumber,
        delta: candidateDelta,
        excludingChapter: excludingChapter
      )
    } catch let error as InkOSCoreError where [409, 422].contains(error.statusCode) {
      return NativeReview(
        pass: false,
        model: "native-continuity-validator",
        summary: "候选连续性差量未通过本地规则校验",
        issues: ["[hard] 连续性差量：\(error.localizedDescription)"],
        revisionGuidance: "修正文与 consistencyDelta，使其符合连续性策略后重新提交。"
      )
    }
    let plan = try synchronizeContinuityProjection(bookID: bookID)
    let reviewBand = plan.chapterWordBand(for: chapterNumber)
    let minWords = reviewBand.minWords
    let maxWords = reviewBand.maxWords
    let previous = chapterNumber > 1 ? (try? readChapterText(bookID: bookID, number: chapterNumber - 1)) ?? "" : ""
    let context = try storyContext(bookID: bookID, maxCharacters: 80_000)
    let craft = try craftDirectives(bookID: bookID, chapterNumber: chapterNumber)
    let deltaJSON = String(data: try encoder.encode(candidateDelta), encoding: .utf8) ?? "{}"
    let projectedJSON = String(data: try encoder.encode(projected), encoding: .utf8) ?? "{}"
    let deltaText = String(deltaJSON.prefix(40_000))
    let projectedText = String(projectedJSON.prefix(80_000))
    let beatSection = beat.map(beatBriefText) ?? "（本章无节拍卡，跳过排期与节拍核对）"
    let prompt = """
      你要同时执行两类审核，并严格区分严重级别。

      第一类：硬连续性（阻断）。审核正文和候选 consistencyDelta 的跨章一致性、人物知情边界、时间地点、伤势、持久物品、世界规则和伏笔生命周期。
      逐项确认正文新增或改变的人物、物品、地点、组织、规则、知识、时间事件和伏笔都登记在 Delta 中；Delta 的每项更新或删除也必须有正文依据。
      entities.type 的唯一规范值是 character、object、location、faction、concept；物品、设备、资源和储备必须是 object。item、物品等输入别名即使会被本地归一化，也不得作为审核建议或输出口径。
      当 allowUnplannedEntities=false 时，正文不得引入审核前索引中不存在的人物、物品、地点、组织或概念。
      节拍卡的禁止清单等同硬约束：正文若出现被本章明令推迟的剧情、人物、物品、能力或结局，记为 hard。
      正文字数必须在 \(minWords) 至 \(maxWords) 字之间，超出记为 hard。
      章末必须停在节拍卡声明的选择、反转、倒计时或新信息上。若以总结、氛围淡出、格言独白或"安心睡去"式收尾收束全章，记为 hard。
      正文不得用清单、备忘录、条目化盘点或资料登记块承担叙事。主角本人的账本记录也只能以动作与判断混合的方式呈现，不能以并列条目铺陈，出现记为 hard。
      第 1 至 3 章作为开篇段整体必须至少建立一次主角核心能力或金手指锚点：异常征兆、首次显现或章末触发均可。前章已经建立后，当前章无需重复；节拍卡明确禁止能力显现时，以禁止清单为准，不得为了重复锚点提前能力。仅在截至当前章整个开篇段仍完全没有锚点时记为 hard。
      环境状态与资源可用性必须前后一致：此前章节或本章前文确立的中断、不可用或耗尽状态（断信号、断电、断水、封路、资源耗尽、设施损坏等），后文不得在没有恢复、替代或解释的情况下当作可用。同章之内自相矛盾（如先说信号彻底没了、后文又收到群视频）同样记为 hard。
      以上任一问题输出前缀 [hard]。

      第二类：写法质量（不阻断）。依据下方写法内核与本书写法约束检查：
      是否有用总结代替关键场景，是否跳过了本该写出的冲突过程；开场是否为背景综述或履历介绍；对话是否承载了关键分歧和转折；本章必需事件和挫折是否真的在场景里发生；视角是否统一；配角语言是否符合其身份、能否相互区分；承诺的冷幽默是否落地；主角是否只有功能反应而没有一处情感泄底（恐惧、犹豫、疲惫、自嘲等）——配角有人味而主角像机器时尤其要点名。
      这些问题输出前缀 [soft]，并在 revisionGuidance 中给出具体可执行的改法。

      pass 只取决于 [hard]：没有 [hard] 问题时 pass=true，即使存在 [soft] 问题。
      只输出 JSON：
      {"pass":true,"summary":"结论","issues":["[hard] 类型：具体问题","[soft] 写法：具体问题"],"revisionGuidance":""}
      issues 必须是字符串数组，每项以 [hard] 或 [soft] 开头，不要返回对象数组。

      \(craft)

      【本章节拍卡】
      \(beatSection)

      【权威设定】
      \(context)

      【本章候选 consistencyDelta】
      \(deltaText)

      【应用候选 Delta 后的连续性索引】
      \(projectedText)

      【上一章】
      \(previous)

      【待审章节】
      第\(chapterNumber)章 \(title)
      正文字数：\(proseCount(content))
      \(content)
      """
    // Streamed for the transport, not for a preview — see the note on the beat
    // batch call in InkOSCoreCraft. A reasoning model returns nothing on a
    // non-streaming request until it stops thinking, and `timeoutInterval`
    // measures inactivity, so this call aborted whenever the review took
    // longer than the ceiling. It carries the chapter text, the candidate
    // delta and the post-application continuity index, and it runs on every
    // review round, which makes it the heaviest remaining exposure.
    let result = try await requestLLM(
      prompt: prompt,
      role: .review,
      json: true,
      timeout: 900,
      onPartialContent: { _ in }
    )
    let object = parseJSONObject(result.content) ?? [:]
    let allIssues = (object["issues"] as? [Any] ?? []).compactMap(reviewIssueText)
    let blocking = allIssues.filter(isBlockingIssue)
    let rawAdvisories = allIssues.filter { !isBlockingIssue($0) }
    let advisories = rawAdvisories.filter { !recommendsNoncanonicalEntityType($0) }
    let requestedPass = (object["pass"] as? Bool) ?? false
    let rawGuidance = string(object["revisionGuidance"])
    let revisionGuidance = recommendsNoncanonicalEntityType(rawGuidance)
      ? (blocking + advisories).joined(separator: "\n")
      : rawGuidance
    if !advisories.isEmpty {
      recordDebug(scope: "review", message: "chapter.craft_advisories", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "count": advisories.count,
      ])
    }
    return NativeReview(
      pass: blocking.isEmpty && (requestedPass || rawAdvisories.count == allIssues.count),
      model: result.model,
      summary: string(object["summary"], fallback: "审核完成"),
      issues: blocking,
      revisionGuidance: revisionGuidance,
      advisories: advisories
    )
  }

  private func recommendsNoncanonicalEntityType(_ text: String) -> Bool {
    let compact = text
      .lowercased()
      .replacingOccurrences(of: #"[\s'\"“”‘’]"#, with: "", options: .regularExpression)
    guard compact.contains("item") || compact.contains("物品") else { return false }
    let validWarnings = ["不得写item", "不能写item", "item无效", "item不是规范", "item会被归一"]
    if validWarnings.contains(where: compact.contains) { return false }
    let invalidPatterns = [
      #"(改回|统一为|统一成|type改为|类型改为).{0,24}(item|物品)"#,
      #"此前.{0,20}(通过|采用).{0,12}(item|物品)"#,
      #"口径为.{0,12}(item|物品)"#,
    ]
    return invalidPatterns.contains {
      compact.range(of: $0, options: .regularExpression) != nil
    }
  }

  /// A finding blocks only when it is explicitly hard, or when it carries no
  /// severity marker at all (unmarked findings are treated conservatively).
  private func isBlockingIssue(_ issue: String) -> Bool {
    let lowered = issue.lowercased()
    if lowered.contains("[soft]") || lowered.contains("[advisory]") || lowered.contains("[建议]") {
      return false
    }
    return true
  }

  private func reviewIssueText(_ value: Any) -> String? {
    if let text = value as? String {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }
    guard let object = value as? [String: Any] else { return nil }
    let severity = string(object["severity"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let type = string(object["type"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = string(object["detail"], fallback: string(object["message"]))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !detail.isEmpty else { return nil }
    let prefix = [severity.isEmpty ? nil : "[\(severity)]", type.isEmpty ? nil : type]
      .compactMap { $0 }
      .joined(separator: " ")
    return prefix.isEmpty ? detail : "\(prefix)：\(detail)"
  }

  private func normalizedChapterTitle(_ value: String, chapterNumber: Int) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"^\s*第\s*\d+\s*章[\s：:·—_-]*"#
    let normalized = trimmed.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? "第\(chapterNumber)章" : normalized
  }

  func generationPrompt(
    bookID: String,
    chapterNumber: Int,
    guidance: String?,
    beat: ChapterBeat? = nil
  ) throws -> String {
    let plan = try synchronizeContinuityProjection(bookID: bookID)
    let genBand = plan.chapterWordBand(for: chapterNumber)
    let targetWords = plan.plan.chapters.first(where: { $0.number == chapterNumber })?.targetWords
      ?? genBand.minWords + (genBand.maxWords - genBand.minWords) / 2
    let minWords = genBand.minWords
    let maxWords = genBand.maxWords
    let bodyFloor = minWords * 85 / 100
    let volume = plan.plan.chapters.first(where: { $0.number == chapterNumber })?.volumeNumber ?? 1
    let volumePlan = plan.plan.volumes.first(where: { $0.number == volume })
    let entityPolicy = plan.continuity.policy.allowUnplannedEntities
      ? "允许引入规划外实体，但必须在 consistencyDelta.entities 中完整登记后才能使用。"
      : "禁止引入连续性索引中尚未登记的人物、物品、地点、组织或概念。"
    let volumePolicy = plan.continuity.policy.requireContinuousVolumes
      ? "必须承接前章和第\(volume)卷目标，不得跳章、跳卷或提前使用未来卷信息。"
      : "仍需保持前后因果，但允许按人工安排调整分卷推进顺序。"
    let checkpointPolicy = plan.continuity.policy.checkpointAtVolumeEnd && volumePlan?.endChapter == chapterNumber
      ? "本章是第\(volume)卷卷末，正文与 Delta 必须完整结算本卷状态、未解伏笔和跨卷承接点。"
      : ""
    let previous = chapterNumber > 1 ? (try? readChapterText(bookID: bookID, number: chapterNumber - 1)) ?? "" : ""
    let beatSection = beat.map { beatBriefText($0) }
      ?? "（本章暂无节拍卡，按分卷目标推进单一问题，不要跨越多个阶段目标。）"
    let craft = try craftDirectives(bookID: bookID, chapterNumber: chapterNumber)
    return """
      你是原生 InkOS 长篇小说写作引擎。生成第\(chapterNumber)章完整正文。
      正文字数必须落在 \(minWords) 至 \(maxWords) 字之间，目标 \(targetWords) 字（验收上限 \(maxWords + max(200, maxWords / 10)) 字）。中文字符不得少于 \(bodyFloor) 个，标点、空行与符号不计入密度；内容不足时展开场景与对话，禁止靠符号或空行凑数。严格遵守权威设定、分卷目标、时间线、人物知识边界、持久物品与特殊约束。
      当前分卷：第\(volume)卷（第\(volumePlan?.startChapter ?? chapterNumber)-\(volumePlan?.endChapter ?? chapterNumber)章）。
      \(volumePolicy)
      \(entityPolicy)
      \(checkpointPolicy)
      本章的写作范围由下面的节拍卡界定：只写节拍卡安排的内容，节拍卡列为禁止提前出现的内容一律不得发生。宁可把一个问题写透，也不要多推进剧情。
      consistencyDelta 必须记录本章新增、更新或删除的事实，它是本章对连续性索引的全部贡献而非节选：正文出现的每个具名人物、地点、持久物品、组织、概念都必须登记；本章兑现或推翻的既有伏笔必须在 remove.hooks 中按 ID 关闭；索引中的既有实体不得静默丢弃，本章仍然成立的事实必须保留；新增随机设定必须登记，并与既有事实兼容。
      entities 每一项的 type 只能取五个值之一，必须按对象性质如实归类，禁止一律填 character：
      character 有意识的人物或生物；location 楼层、房间、区域、建筑等场所；object 物品、设备、资源、储备等实体物；faction 组织、势力、团体；concept 能力、规则、现象等抽象概念。例如“201公寓”“储物间”是 location，“电热水器存水”“界务门”这类物件或装置是 object，只有真正的人才是 character。
      正文里改变生存账本或后续决策的关键资源（存水量、存粮、燃料、电量等）必须在 entities 或 hooks 中登记，且 Delta 中的每个数字与结论都要与正文严格一致，不得出现正文一个数、Delta 另一个数的矛盾。
      此前章节确立的中断、不可用或耗尽状态（断信号、断电、断水、封路、资源耗尽等）对本章有约束力：使用通信、电力、设施或消耗品之前必须确认其当前可用；本章若要改变某个状态的可用性（如信号短暂恢复），必须在正文写出发生的时刻与原因，并登记进 consistencyDelta 的 worldRules；同章之内不得自相矛盾。
      只输出 JSON：{"title":"章节标题","content":"完整正文","summary":"章节摘要","consistencyDelta":{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"","name":"","type":"character|location|object|faction|concept"}],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}}。
      \(guidance.map { "本章额外要求：\($0)" } ?? "")

      \(craft)

      【本章节拍卡】
      \(beatSection)

      【权威设定与当前状态】
      \(try storyContext(bookID: bookID, maxCharacters: 100_000))

      【上一章全文】
      \(previous)
      """
  }

  /// Assembles the authoritative context. Files get reserved shares of the
  /// budget so the continuity index cannot silently push the story bible, hard
  /// rules and style guide out of the prompt as a book grows.
  func storyContext(bookID: String, maxCharacters: Int) throws -> String {
    let storyURL = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    // (path, share of the total budget). Shares sum to 0.66; the continuity
    // index and volume checkpoint take the rest.
    let reserved: [(path: String, share: Double)] = [
      ("book_rules.md", 0.08),
      ("story_bible.md", 0.12),
      ("protagonist.md", 0.04),
      ("outline/story_frame.md", 0.04),
      ("outline/volume_map.md", 0.06),
      ("character_matrix.md", 0.06),
      ("current_state.md", 0.05),
      ("object_ledger.md", 0.04),
      ("particle_ledger.md", 0.03),
      ("pending_hooks.md", 0.03),
      ("chapter_summaries.md", 0.05),
      ("current_focus.md", 0.02),
      ("style_guide.md", 0.04),
    ]
    let plan = try synchronizeContinuityProjection(bookID: bookID)
    let continuityData = try encoder.encode(plan.continuity)
    let continuityText = String(data: continuityData, encoding: .utf8) ?? "{}"
    let checkpointText = try latestVolumeCheckpointText(bookID: bookID)

    var sections: [String] = []
    var used = 0
    // First pass: each file takes at most its reserved share.
    var overflow: [(path: String, remainder: String)] = []
    for entry in reserved {
      let url = storyURL.appendingPathComponent(entry.path)
      guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let allowance = Swift.max(400, Int(Double(maxCharacters) * entry.share))
      let head = String(trimmed.prefix(allowance))
      sections.append("【\(entry.path)】\n" + head)
      used += head.count
      if trimmed.count > allowance {
        overflow.append((entry.path, String(trimmed.dropFirst(allowance))))
      }
    }

    let continuityAllowance = Swift.max(2_000, maxCharacters - used - (checkpointText?.count ?? 0))
    let continuityHead = String(continuityText.prefix(continuityAllowance))
    sections.insert("【结构化连续性索引（已审核章节 + 人工覆盖）】\n" + continuityHead, at: 0)
    used += continuityHead.count
    if let checkpointText {
      let allowance = Swift.max(0, maxCharacters - used)
      if allowance > 0 {
        let head = String(checkpointText.prefix(allowance))
        sections.append("【最近卷末连续性检查点】\n" + head)
        used += head.count
      }
    }
    // Second pass: hand leftover budget to files that were truncated.
    for entry in overflow {
      let allowance = maxCharacters - used
      if allowance <= 200 { break }
      let tail = String(entry.remainder.prefix(allowance))
      sections.append("【\(entry.path)·续】\n" + tail)
      used += tail.count
    }
    return sections.joined(separator: "\n\n")
  }

  func persistConsistencyDelta(
    bookID: String,
    chapterNumber: Int,
    title: String,
    summary: String,
    delta: [String: Any]
  ) throws {
    let storyURL = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    let runtimeURL = storyURL.appendingPathComponent("runtime", isDirectory: true)
    try fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
    let normalized = try normalizedConsistencyDelta(delta, chapterNumber: chapterNumber)
    try writeJSON([
      "version": 1,
      "chapterNumber": chapterNumber,
      "title": title,
      "summary": summary,
      "delta": try encodedObject(normalized),
      "committedAt": isoTimestamp(),
    ], to: runtimeURL.appendingPathComponent(String(format: "chapter-%04d.consistency.json", chapterNumber)))
    let summariesURL = storyURL.appendingPathComponent("chapter_summaries.md")
    var summaries = (try? String(contentsOf: summariesURL, encoding: .utf8)) ?? "# 章节摘要\n"
    summaries += "\n## 第\(chapterNumber)章 \(title)\n\(summary)\n"
    try atomicWrite(summaries, to: summariesURL)
  }

  func requestLLM(
    prompt: String,
    role: LLMRole,
    json: Bool = false,
    overrideModel: String? = nil,
    overrideBaseURL: String? = nil,
    overrideAPIKey: String? = nil,
    timeout: TimeInterval = 300,
    onPartialContent: (@Sendable (String) async -> Void)? = nil
  ) async throws -> LLMResult {
    let raw = try loadRawConfig()
    let isReview = role == .review
    let model = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? string(isReview ? raw["reviewModel"] : raw["model"], fallback: string(raw["model"], fallback: "gpt-5.6-terra"))
    let configuredBase = overrideBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? string(isReview ? raw["reviewBaseUrl"] : raw["baseUrl"]).nonEmpty
      ?? string(raw["baseUrl"])
    let baseURL = try validatedEndpoint(configuredBase, existing: raw)
    let suppliedKey = overrideAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let key = suppliedKey.nonEmpty
      ?? string(isReview ? raw["reviewApiKey"] : raw["apiKey"]).nonEmpty
      ?? string(raw["apiKey"])
    guard !key.isEmpty else { throw InkOSCoreError("请先在设置中填写模型 API Key", statusCode: 400) }
    guard !model.isEmpty else { throw InkOSCoreError("请先在设置中选择模型", statusCode: 400) }

    let url = try endpointURL(baseURL: baseURL, suffix: "chat/completions")
    var body: [String: Any] = [
      "model": model,
      "stream": onPartialContent != nil,
      "messages": [
        ["role": "system", "content": json ? "只输出严格 JSON，不展示推理过程。" : "按要求直接回答。"],
        ["role": "user", "content": prompt],
      ],
    ]
    if let temperature = raw["temperature"] as? NSNumber { body["temperature"] = temperature.doubleValue }
    if let maxTokens = integer(raw["maxTokens"]), maxTokens > 0 { body["max_tokens"] = maxTokens }
    if json { body["response_format"] = ["type": "json_object"] }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    if onPartialContent != nil {
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let started = Date()
    // Transient upstream failures (rate limit, 5xx, network) get up to two
    // retries with backoff. Client errors (4xx) and cancellation propagate
    // immediately — retrying those only burns time.
    let maxAttempts = 3
    for attempt in 1...maxAttempts {
      do {
        if let onPartialContent {
          let streamed = try await performLLMStreamingRequest(
            request,
            operation: "chat.completions.stream",
            onPartialContent: onPartialContent
          )
          guard !streamed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InkOSCoreError("模型返回了空内容", statusCode: 502)
          }
          return LLMResult(
            content: streamed.content,
            model: model,
            baseURL: baseURL,
            latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
            finishReason: streamed.finishReason
          )
        }
        let (data, response) = try await performLLMRequest(request, operation: "chat.completions")
        guard let http = response as? HTTPURLResponse else { throw InkOSCoreError("模型返回格式异常") }
        guard (200..<300).contains(http.statusCode) else {
          throw try remoteError(data: data, status: http.statusCode, prefix: "模型请求失败")
        }
        let responseObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let choices = responseObject["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        let content = extractMessageContent(message?["content"])
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw InkOSCoreError("模型返回了空内容", statusCode: 502)
        }
        return LLMResult(
          content: content,
          model: model,
          baseURL: baseURL,
          latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
          finishReason: (choices.first?["finish_reason"] as? String)?.nonEmpty
        )
      } catch let error as InkOSCoreError {
        let transient = [429, 500, 502, 503, 504].contains(error.statusCode)
        guard transient, attempt < maxAttempts else { throw error }
        let delaySeconds = attempt == 1 ? 4 : 12
        recordDebug(scope: "llm", message: "request.retry", level: "warning", data: [
          "attempt": attempt,
          "statusCode": error.statusCode,
          "error": error.localizedDescription,
          "retryAfterSeconds": delaySeconds,
        ])
        try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
      }
    }
    throw InkOSCoreError("模型请求失败", statusCode: 500)
  }

  func loadRawConfig() throws -> [String: Any] {
    guard fileManager.fileExists(atPath: configURL.path) else {
      return [
        "provider": "openai", "model": "gpt-5.6-terra", "reviewModel": "gpt-5.6-terra",
        "baseUrl": "", "reviewBaseUrl": "", "apiKey": "", "reviewApiKey": "",
        "stream": false, "thinkingBudget": 0, "apiFormat": "chat",
      ]
    }
    return try readObject(configURL)
  }

  func validatedEndpoint(
    _ value: String,
    allowEmpty: Bool = false,
    existing: [String: Any]
  ) throws -> String {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty && allowEmpty { return "" }
    guard var components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { throw InkOSCoreError("模型地址格式错误", statusCode: 400) }
    let allowInsecure = (existing["allowInsecureHttp"] as? Bool) == true
    let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    guard scheme == "https" || (scheme == "http" && (loopback || allowInsecure)) else {
      throw InkOSCoreError("远程模型地址需使用 HTTPS", statusCode: 400)
    }
    components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    return components.string ?? text
  }

  func endpointURL(baseURL: String, suffix: String) throws -> URL {
    guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix) else {
      throw InkOSCoreError("模型地址格式错误", statusCode: 400)
    }
    return url
  }

  private func performLLMRequest(
    _ request: URLRequest,
    operation: String
  ) async throws -> (Data, URLResponse) {
    do {
      let result = try await URLSession.shared.data(for: request)
      if let requestedURL = request.url?.absoluteString,
        let finalURL = result.1.url?.absoluteString,
        finalURL != requestedURL
      {
        recordDebug(scope: "llm", message: "network.redirect", data: [
          "operation": operation,
          "requestedURL": requestedURL,
          "finalURL": finalURL,
        ])
      }
      return result
    } catch let error as URLError {
      let failureURL = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        ?? request.url?.absoluteString
        ?? ""
      recordDebug(scope: "llm", message: "network.failed", level: "error", data: [
        "operation": operation,
        "code": error.code.rawValue,
        "failingURL": failureURL,
        "requestedURL": request.url?.absoluteString ?? "",
        "description": error.localizedDescription,
      ])
      if error.code == .timedOut {
        throw InkOSCoreError("模型请求超时（URLError \(error.code.rawValue)）", statusCode: 504)
      }
      throw InkOSCoreError(
        "模型网络请求失败（URLError \(error.code.rawValue)）：\(error.localizedDescription)",
        statusCode: 502
      )
    } catch {
      recordDebug(scope: "llm", message: "network.failed", level: "error", data: [
        "operation": operation,
        "requestedURL": request.url?.absoluteString ?? "",
        "description": error.localizedDescription,
      ])
      throw InkOSCoreError("模型网络请求失败：\(error.localizedDescription)", statusCode: 502)
    }
  }

  private func performLLMStreamingRequest(
    _ request: URLRequest,
    operation: String,
    onPartialContent: @Sendable (String) async -> Void
  ) async throws -> (content: String, finishReason: String?) {
    do {
      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      if let requestedURL = request.url?.absoluteString,
        let finalURL = response.url?.absoluteString,
        finalURL != requestedURL
      {
        recordDebug(scope: "llm", message: "network.redirect", data: [
          "operation": operation,
          "requestedURL": requestedURL,
          "finalURL": finalURL,
        ])
      }
      guard let http = response as? HTTPURLResponse else {
        throw InkOSCoreError("模型返回格式异常")
      }
      guard (200..<300).contains(http.statusCode) else {
        var errorData = Data()
        for try await byte in bytes {
          if errorData.count < 2_000_000 { errorData.append(byte) }
        }
        throw try remoteError(data: errorData, status: http.statusCode, prefix: "模型请求失败")
      }

      var content = ""
      var nonStreamData = Data()
      var finishReason: String? = nil
      var lastEmittedCount = 0
      var lastEmittedAt = Date.distantPast
      for try await line in bytes.lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
          nonStreamData.append(Data(line.utf8))
          nonStreamData.append(0x0A)
          continue
        }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { break }
        guard let data = payload.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { continue }
        let choices = object["choices"] as? [[String: Any]] ?? []
        let delta = choices.first?["delta"] as? [String: Any]
        let message = choices.first?["message"] as? [String: Any]
        if let reason = choices.first?["finish_reason"] as? String, !reason.isEmpty {
          finishReason = reason
        }
        let piece = extractMessageContent(delta?["content"])
          .nonEmpty ?? extractMessageContent(message?["content"])
        if !piece.isEmpty { content += piece }
        let now = Date()
        if content.count - lastEmittedCount >= 64
          || now.timeIntervalSince(lastEmittedAt) >= 0.18
        {
          await onPartialContent(content)
          lastEmittedCount = content.count
          lastEmittedAt = now
        }
      }

      if content.isEmpty, !nonStreamData.isEmpty,
        let object = try? JSONSerialization.jsonObject(with: nonStreamData) as? [String: Any]
      {
        let choices = object["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        content = extractMessageContent(message?["content"])
        if let reason = choices.first?["finish_reason"] as? String, !reason.isEmpty {
          finishReason = reason
        }
      }
      if !content.isEmpty { await onPartialContent(content) }
      return (content, finishReason)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as InkOSCoreError {
      throw error
    } catch let error as URLError {
      let failureURL = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        ?? request.url?.absoluteString
        ?? ""
      recordDebug(scope: "llm", message: "network.failed", level: "error", data: [
        "operation": operation,
        "code": error.code.rawValue,
        "failingURL": failureURL,
        "requestedURL": request.url?.absoluteString ?? "",
        "description": error.localizedDescription,
      ])
      if error.code == .timedOut {
        throw InkOSCoreError("模型请求超时（URLError \(error.code.rawValue)）", statusCode: 504)
      }
      throw InkOSCoreError(
        "模型网络请求失败（URLError \(error.code.rawValue)）：\(error.localizedDescription)",
        statusCode: 502
      )
    } catch {
      recordDebug(scope: "llm", message: "network.failed", level: "error", data: [
        "operation": operation,
        "requestedURL": request.url?.absoluteString ?? "",
        "description": error.localizedDescription,
      ])
      throw InkOSCoreError("模型流式请求失败：\(error.localizedDescription)", statusCode: 502)
    }
  }

  private func updateGenerationLiveText(key: String, rawText: String) {
    guard let job = generationJobs[key] else { return }
    let readable = streamedChapterText(from: rawText)
    guard !readable.isEmpty else { return }
    let limit = 40_000
    let truncated = readable.count > limit
    let visible = truncated ? String(readable.suffix(limit)) : readable
    generationJobs[key] = try? makeGenerationJob(
      bookID: job.bookId,
      chapterNumber: job.chapterNum,
      title: job.title,
      phase: job.phase,
      message: job.message ?? job.phase,
      startedAt: job.startedAt ?? isoTimestamp(),
      finishedAt: job.finishedAt,
      error: job.error,
      liveText: visible,
      liveTextTruncated: truncated
    )
  }

  private func streamedChapterText(from rawText: String) -> String {
    extractedJSONStringField("content", from: rawText, requireTerminator: false) ?? ""
  }

  /// Decodes a single `"field": "…"` pair out of `rawText` without requiring the
  /// enclosing JSON object to parse.
  ///
  /// A model that emits a finished chapter inside a torn JSON shell holds the
  /// only copy of that prose, so this scanner tolerates the shell while staying
  /// strict about the value itself: an unescaped quote closes the field only
  /// when JSON's own terminators follow it (`}`, or `,` before the next
  /// `"key":`). That keeps the bare quotes models write around dialogue from
  /// truncating a chapter mid-sentence.
  ///
  /// `requireTerminator: false` returns whatever decoded so far, which is what
  /// the live streaming preview needs while the field is still arriving.
  func extractedJSONStringField(
    _ field: String,
    from rawText: String,
    requireTerminator: Bool = true
  ) -> String? {
    let pattern = "\"\(NSRegularExpression.escapedPattern(for: field))\"\\s*:\\s*\""
    guard let marker = rawText.range(of: pattern, options: .regularExpression) else { return nil }
    let characters = Array(rawText[marker.upperBound...])
    var output = ""
    var index = 0
    var closed = false
    while index < characters.count {
      let character = characters[index]
      if character == "\"" {
        if closesJSONString(characters, quoteIndex: index) {
          closed = true
          break
        }
        output.append(character)
        index += 1
        continue
      }
      guard character == "\\" else {
        output.append(character)
        index += 1
        continue
      }
      guard index + 1 < characters.count else { break }
      let escaped = characters[index + 1]
      switch escaped {
      case "n": output.append("\n"); index += 2
      case "r": output.append("\r"); index += 2
      case "t": output.append("\t"); index += 2
      case "b": output.append("\u{08}"); index += 2
      case "f": output.append("\u{0C}"); index += 2
      case "\"": output.append("\""); index += 2
      case "\\": output.append("\\"); index += 2
      case "/": output.append("/"); index += 2
      case "u" where index + 5 < characters.count:
        let hex = String(characters[(index + 2)...(index + 5)])
        if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
          output.unicodeScalars.append(scalar)
        }
        index += 6
      default:
        output.append(escaped)
        index += 2
      }
    }
    if requireTerminator, !closed { return nil }
    return output
  }

  /// True when the quote at `quoteIndex` is a real end-of-string quote rather
  /// than one the model left unescaped inside the prose. Requires either the
  /// end of the enclosing object or a value separator followed by the next
  /// object key.
  private func closesJSONString(_ characters: [Character], quoteIndex: Int) -> Bool {
    var index = quoteIndex + 1
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    guard index < characters.count else { return false }
    if characters[index] == "}" { return true }
    guard characters[index] == "," else { return false }
    index += 1
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    guard index < characters.count, characters[index] == "\"" else { return false }
    index += 1
    while index < characters.count, characters[index] != "\"" {
      guard characters[index] != "\\", !characters[index].isNewline else { return false }
      index += 1
    }
    guard index < characters.count else { return false }
    index += 1
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    return index < characters.count && characters[index] == ":"
  }

  /// Rebuilds the prose half of a chapter payload from a response whose JSON
  /// shell is broken but whose `content` string is verifiably closed.
  ///
  /// Only fields that can be confirmed complete are returned. A
  /// `consistencyDelta` sitting in a torn shell is never reused — the caller
  /// re-requests it through the cheap delta-only path — and a missing title or
  /// summary is left absent so the caller's existing fallbacks apply.
  func recoverCompleteChapterProse(
    from rawText: String,
    chapterNumber: Int
  ) -> [String: Any]? {
    guard let content = extractedJSONStringField("content", from: rawText),
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    var object: [String: Any] = ["content": content]
    if let title = extractedJSONStringField("title", from: rawText)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
    {
      object["title"] = title
    }
    if let summary = extractedJSONStringField("summary", from: rawText)?
      .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty
    {
      object["summary"] = summary
    }
    return object
  }

  /// Structured chapter payload with three resilience layers. Previously a
  /// single malformed model output — truncated stream, unescaped control
  /// characters, or a missing consistencyDelta — discarded a full chapter
  /// write with the opaque "模型未返回 consistencyDelta" error and preserved
  /// no evidence of what the model actually emitted.
  ///
  /// Layer 1: unparseable output is logged (finishReason, length, head/tail).
  /// Layer 2: if that output still carries a verifiably closed `content`
  /// string, the prose is recovered as-is and only the lost delta is
  /// re-requested. A finished chapter is the expensive half of the response,
  /// and regenerating it invites the truncation that broke chapter 5 of
  /// 《渊雨浩劫》: the first draft was complete behind a torn shell, the
  /// full retry then ran out of output budget. A full retry with a
  /// strict-format suffix happens only when the prose itself is torn.
  /// Layer 3: a payload that parses but omits a required delta gets one cheap
  /// delta-only completion instead of a full rewrite.
  func requestChapterPayload(
    prompt: String,
    chapterNumber: Int,
    requireDelta: Bool,
    timeout: TimeInterval,
    onPartialContent: (@Sendable (String) async -> Void)? = nil
  ) async throws -> (object: [String: Any], result: LLMResult) {
    var result = try await requestLLM(
      prompt: prompt,
      role: .primary,
      json: true,
      timeout: timeout,
      onPartialContent: onPartialContent
    )
    var parsed = parseJSONObject(result.content)
    var recoveredProse = false
    if parsed == nil {
      recordDebug(scope: "generation", message: "chapter.invalidJson", level: "error", data: [
        "chapterNumber": chapterNumber,
        "finishReason": result.finishReason ?? "unknown",
        "contentLength": result.content.count,
        "head": String(result.content.prefix(200)),
        "tail": String(result.content.suffix(200)),
      ])
      if let recovered = recoverCompleteChapterProse(
        from: result.content,
        chapterNumber: chapterNumber
      ) {
        parsed = recovered
        recoveredProse = true
        recordDebug(scope: "generation", message: "chapter.proseRecovered", data: [
          "chapterNumber": chapterNumber,
          "attempt": 1,
          "contentLength": string(recovered["content"]).count,
          "recoveredTitle": recovered["title"] != nil,
          "recoveredSummary": recovered["summary"] != nil,
        ])
      } else {
        result = try await requestLLM(
          prompt: prompt + """


            严格要求：上次输出不是合法 JSON。本次必须输出严格合法的 JSON：字符串内的换行一律写成 \\n 转义，不得出现未转义的引号或控制字符，整个对象必须以 } 闭合结束。
            """,
          role: .primary,
          json: true,
          timeout: timeout,
          onPartialContent: onPartialContent
        )
        parsed = parseJSONObject(result.content)
        if parsed == nil,
          let recovered = recoverCompleteChapterProse(
            from: result.content,
            chapterNumber: chapterNumber
          )
        {
          parsed = recovered
          recoveredProse = true
          recordDebug(scope: "generation", message: "chapter.proseRecovered", data: [
            "chapterNumber": chapterNumber,
            "attempt": 2,
            "contentLength": string(recovered["content"]).count,
            "recoveredTitle": recovered["title"] != nil,
            "recoveredSummary": recovered["summary"] != nil,
          ])
        }
      }
    }
    guard var object = parsed else {
      throw InkOSCoreError(
        "模型连续两次未返回合法 JSON（finishReason=\(result.finishReason ?? "未知")，输出 \(result.content.count) 字符）。末尾片段：\(String(result.content.suffix(120)))",
        statusCode: 422
      )
    }
    // Recovery deliberately drops the delta that sat in the broken shell, so
    // repair it even when policy would tolerate its absence: the model already
    // wrote one and a delta-only call is cheap.
    if (requireDelta || recoveredProse), object["consistencyDelta"] as? [String: Any] == nil {
      recordDebug(scope: "generation", message: "chapter.deltaRepair.started", data: [
        "chapterNumber": chapterNumber,
      ])
      let repairPrompt = """
        你是 InkOS 一致性登记员。下面是一章已定稿的小说正文，请只为它输出 consistencyDelta 的 JSON：{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}。
        entities 每一项的 type 只能取五个值之一：character 人物或生物；location 场所；object 物品；faction 组织；concept 能力、规则、现象等抽象概念。每个数字与结论都要与正文严格一致。不要输出正文，不要输出解释。
        【章节正文】
        第\(chapterNumber)章
        \(string(object["content"]))
        """
      // Every exit from this branch is logged. The repair used to swallow its
      // failure three ways — a thrown request, an unparseable response, and a
      // parsed object without a delta all produced the same silent nil — which
      // left only the caller's "自动补登后仍缺失" to debug from. That mattered
      // little while the repair ran solely for a parsed payload missing its
      // delta; prose recovery now depends on it for every torn shell, so the
      // reason has to survive.
      do {
        // Streamed for the transport, not for a preview — see the beat batch call.
        let repaired = try await requestLLM(
          prompt: repairPrompt,
          role: .primary,
          json: true,
          timeout: 900,
          onPartialContent: { _ in }
        )
        guard let repairedObject = parseJSONObject(repaired.content) else {
          recordDebug(
            scope: "generation", message: "chapter.deltaRepair.failed", level: "error",
            data: [
              "chapterNumber": chapterNumber,
              "reason": "invalidJson",
              "finishReason": repaired.finishReason ?? "unknown",
              "contentLength": repaired.content.count,
              "head": String(repaired.content.prefix(200)),
              "tail": String(repaired.content.suffix(200)),
            ])
          return (object, result)
        }
        let delta = (repairedObject["consistencyDelta"] as? [String: Any])
          ?? (repairedObject["upsert"] != nil ? repairedObject : nil)
        guard let delta else {
          recordDebug(
            scope: "generation", message: "chapter.deltaRepair.failed", level: "error",
            data: [
              "chapterNumber": chapterNumber,
              "reason": "missingDeltaField",
              "keys": repairedObject.keys.sorted().joined(separator: ","),
            ])
          return (object, result)
        }
        object["consistencyDelta"] = delta
        recordDebug(scope: "generation", message: "chapter.deltaRepair.completed", data: [
          "chapterNumber": chapterNumber,
        ])
      } catch let error as InkOSCoreError {
        recordDebug(
          scope: "generation", message: "chapter.deltaRepair.failed", level: "error",
          data: [
            "chapterNumber": chapterNumber,
            "reason": "requestFailed",
            "statusCode": error.statusCode,
            "error": error.localizedDescription,
          ])
      } catch {
        recordDebug(
          scope: "generation", message: "chapter.deltaRepair.failed", level: "error",
          data: [
            "chapterNumber": chapterNumber,
            "reason": "requestFailed",
            "error": error.localizedDescription,
          ])
      }
    }
    return (object, result)
  }

  func parseJSONObject(_ text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    { return object }
    let withoutFence = trimmed
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = withoutFence.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    { return object }
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
      let data = String(trimmed[start...end]).data(using: .utf8)
    else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func extractMessageContent(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let parts = value as? [[String: Any]] {
      return parts.compactMap { part in
        part["text"] as? String ?? (part["text"] as? [String: Any])?["value"] as? String
      }.joined()
    }
    return ""
  }

  private func remoteError(data: Data, status: Int, prefix: String) throws -> InkOSCoreError {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let nested = object?["error"] as? [String: Any]
    let message = string(nested?["message"], fallback: string(object?["message"], fallback: "HTTP \(status)"))
    return InkOSCoreError("\(prefix)：\(message)", statusCode: status)
  }

  private func secretPreview(_ value: String) -> String {
    guard value.count > 8 else { return value.isEmpty ? "" : "••••" }
    return "\(value.prefix(4))••••\(value.suffix(4))"
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
