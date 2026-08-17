import Foundation

/// Returns the configured upper bound for automatic rewrite+re-review
/// rounds. Reads from the model config file so the value can be adjusted
/// per-book without a code change. Defaults to 3 when not set; capped at
/// 10 to prevent runaway loops.
private let maxAutoRevisionRoundsFallback = 3

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

  /// Upper bound for the `max_tokens` doubling that follows a reasoning pass which
  /// consumed the whole configured ceiling.
  ///
  /// Bounded rather than unbounded because a model that produces no prose for a
  /// genuine reason — a prompt it will not answer — would otherwise be retried at
  /// ever larger ceilings, and every attempt costs a full reasoning pass. 65 536
  /// covers every measured case: the widest observed reasoning pass on the beat
  /// prompt was 16 383 tokens with roughly 10 000 tokens of JSON still to write.
  static let maxTokensRetryCeiling = 65_536

  enum LLMRole: Sendable {
    case primary
    case review
    /// Canon extraction over an imported original work. See `ModelRole.extraction`.
    case extraction

    /// The public `ModelRole` this maps onto, which owns the config key names.
    var modelRole: ModelRole {
      switch self {
      case .primary: return .chapter
      case .review: return .review
      case .extraction: return .extraction
      }
    }

    init(_ modelRole: ModelRole) {
      switch modelRole {
      case .chapter: self = .primary
      case .review: self = .review
      case .extraction: self = .extraction
      }
    }
  }

  // MARK: - Configuration

  /// Upper bound for automatic rewrite+re-review rounds. Reads
  /// `maxAutoRevisionRounds` from the model config (integer) so the value
  /// can be tuned per-deployment without a code change. Falls back to
  /// `maxAutoRevisionRoundsFallback` (3) when absent or zero; capped at 10.
  private var maxAutoRevisionRounds: Int {
    let raw = (try? loadRawConfig()) ?? [:]
    let n = raw["maxAutoRevisionRounds"] as? Int ?? 0
    return n > 0 ? min(n, 10) : maxAutoRevisionRoundsFallback
  }

  func fetchInkOSConfig() async throws -> InkOSConfig {
    let raw = try loadRawConfig()
    let primaryKey = string(raw["apiKey"])
    let reviewKey = string(raw["reviewApiKey"])
    let extractionKey = string(raw["extractionApiKey"])
    let primaryModel = string(raw["model"], fallback: "gpt-5.6-terra")
    // An unset role model reports the primary one, matching what `requestLLM`
    // falls back to. Endpoints are reported verbatim: blank means "inherit the
    // primary endpoint", and the UI shows that as an empty field.
    return try decodeObject([
      "provider": "openai",
      "model": primaryModel,
      "reviewModel": string(raw["reviewModel"], fallback: primaryModel),
      "extractionModel": string(raw["extractionModel"], fallback: primaryModel),
      "baseUrl": string(raw["baseUrl"]),
      "reviewBaseUrl": string(raw["reviewBaseUrl"]),
      "extractionBaseUrl": string(raw["extractionBaseUrl"]),
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
      "hasExtractionApiKey": !extractionKey.isEmpty,
      "extractionApiKeyPreview": secretPreview(extractionKey),
      "apiKey": "",
      "reviewApiKey": "",
      "extractionApiKey": "",
    ], as: InkOSConfig.self)
  }

  func updateInkOSConfig(_ input: InkOSConfigUpdate) async throws -> InkOSConfigApplyResponse {
    var raw = try loadRawConfig()
    let baseURL = try validatedEndpoint(input.baseUrl, allowEmpty: true, existing: raw)
    let reviewBaseURL = try validatedEndpoint(input.reviewBaseUrl, allowEmpty: true, existing: raw)
    let extractionBaseURL = try validatedEndpoint(
      input.extractionBaseUrl, allowEmpty: true, existing: raw
    )
    raw["provider"] = "openai"
    raw["apiFormat"] = "chat"
    raw["model"] = input.model.trimmingCharacters(in: .whitespacesAndNewlines)
    raw["reviewModel"] = input.reviewModel.trimmingCharacters(in: .whitespacesAndNewlines)
    raw["extractionModel"] = input.extractionModel.trimmingCharacters(in: .whitespacesAndNewlines)
    raw["baseUrl"] = baseURL
    raw["reviewBaseUrl"] = reviewBaseURL
    raw["extractionBaseUrl"] = extractionBaseURL
    raw["stream"] = false
    raw["thinkingBudget"] = 0
    if !input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw["apiKey"] = input.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !input.reviewApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw["reviewApiKey"] = input.reviewApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if !input.extractionApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw["extractionApiKey"] = input.extractionApiKey
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let temperature = input.temperature { raw["temperature"] = temperature }
    if let maxTokens = input.maxTokens { raw["maxTokens"] = maxTokens }
    try writeJSON(raw, to: configURL, privateFile: true)
    recordDebug(scope: "config", message: "llm.config.updated", data: [
      "model": string(raw["model"]), "reviewModel": string(raw["reviewModel"]),
      "extractionModel": string(raw["extractionModel"]),
    ])
    let fields = [
      "model", "reviewModel", "extractionModel", "baseUrl", "reviewBaseUrl",
      "extractionBaseUrl", "stream", "thinkingBudget", "temperature", "maxTokens",
    ]
    return InkOSConfigApplyResponse(ok: true, applied: fields.count, fields: fields, errors: [])
  }

  func fetchModels(_ endpoint: ModelEndpointRequest) async throws -> ModelCatalogResponse {
    let raw = try loadRawConfig()
    let keys = endpoint.role.configKeys
    let configured = endpoint.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // `.nonEmpty` rather than a `fallback:` argument: a saved-but-blank role
    // endpoint is stored as "", and that has to inherit the primary endpoint
    // instead of reaching `validatedEndpoint` as an empty string and throwing.
    let fallback = string(raw[keys.baseURL]).nonEmpty ?? string(raw["baseUrl"])
    let baseURL = try validatedEndpoint(configured.isEmpty ? fallback : configured, existing: raw)
    let suppliedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let storedKey = string(raw[keys.apiKey]).nonEmpty ?? string(raw["apiKey"])
    let key = suppliedKey.isEmpty ? storedKey : suppliedKey
    guard !key.isEmpty else {
      throw InkOSCoreError(
        "请先填写或保存 API Key",
        statusCode: 400,
        origin: .requestConfiguration
      )
    }
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
        role: LLMRole(input.role),
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
    let plan = try validateDerivativePreparationForWriting(
      bookID: bookID,
      plan: await fetchLongFormPlan(bookID: bookID)
    )
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
    if hasActiveGenerationJob(bookID: bookID) {
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
    _ = try validateDerivativePreparationForWriting(
      bookID: bookID,
      plan: await fetchLongFormPlan(bookID: bookID)
    )
    let key = generationKey(bookID, number)
    if hasActiveGenerationJob(bookID: bookID) {
      throw InkOSCoreError("该书已有章节任务正在运行", statusCode: 409)
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
        beat: beat,
        plan: plan
      )
      // Reuse the plan already loaded above — the projection cannot change
      // between prompt construction and the LLM call, and re-reading the
      // file just for `requireConsistencyDelta` is redundant I/O.
      let (parsed, result) = try await requestChapterPayload(
        prompt: prompt,
        chapterNumber: chapterNumber,
        requireDelta: plan.continuity.policy.requireConsistencyDelta,
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
        if plan.continuity.policy.requireConsistencyDelta, suppliedDelta == nil {
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
      if review.protocolFailure {
        let reviewObject = reviewRecord(
          review,
          status: "protocol_error",
          attempts: [initialAttempt]
        )
        try withChapterPersistenceTransaction(bookID: bookID, chapterNumber: chapterNumber) {
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
        }
        generationJobs[key] = try makeGenerationJob(
          bookID: bookID,
          chapterNumber: chapterNumber,
          title: title,
          phase: "revision_failed",
          message: "审核模型响应协议错误，已保留完整草稿，等待重新审核",
          startedAt: startedAt,
          finishedAt: isoTimestamp(),
          error: review.summary,
          liveText: generationJobs[key]?.liveText,
          attempts: [initialAttempt]
        )
        recordDebug(scope: "review", message: "chapter.review.protocol_error", level: "error", data: [
          "bookId": bookID,
          "chapterNumber": chapterNumber,
        ])
        return
      }
      if review.pass {
        let reviewObject = reviewRecord(
          review,
          status: "passed",
          attempts: [initialAttempt]
        )
        try withChapterPersistenceTransaction(bookID: bookID, chapterNumber: chapterNumber) {
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
        }
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
      try withChapterPersistenceTransaction(bookID: bookID, chapterNumber: chapterNumber) {
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
      }
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

    static func stalled(lastTitle: String, lastContent: String) -> RevisionRoundOutcome {
      RevisionRoundOutcome(
        review: nil,
        title: lastTitle,
        content: lastContent,
        error: InkOSCoreError(stallErrorMessage),
        persisted: false
      )
    }

    /// A stall is the model declining to change anything, not a fault of its
    /// own. `finalizeRevisionFailure` matches on this to report the standing
    /// review findings instead, which is what a human actually needs to act on.
    static let stallErrorMessage = "修订输出与原文完全相同，继续重试无意义"
  }

  private func storedNativeReview(_ review: LLMReview?) -> NativeReview? {
    guard let review, !review.isPassed,
      review.isProtocolFailure || !review.issueList.isEmpty
    else { return nil }
    return NativeReview(
      pass: false,
      model: review.model ?? "stored-review",
      summary: review.summary ?? "上一轮审核未通过",
      issues: review.issueList,
      revisionGuidance: review.revisionGuidance ?? "",
      protocolFailure: review.isProtocolFailure,
      advisories: review.craftAdvisoryList
    )
  }

  /// Repair scope for one `[hard]` finding: does fixing it require editing the
  /// chapter text, or only the registered `consistencyDelta`?
  private enum IssueRepairScope {
    case delta
    case prose
  }

  /// Explicit `[delta]` / `[prose]` tag the review prompt asks for. Present only
  /// when the review model honoured the contract, so callers fall back to
  /// `inferredRepairScope` when this returns nil.
  private func taggedRepairScope(_ issue: String) -> IssueRepairScope? {
    let lowered = issue.lowercased()
    // Check prose first: a finding tagged with both is a prose fix, because a
    // rewrite round regenerates the delta anyway while a delta-only repair
    // cannot touch the text.
    if lowered.contains("[prose]") || lowered.contains("[正文]") { return .prose }
    if lowered.contains("[delta]") || lowered.contains("[差量]") { return .delta }
    return nil
  }

  /// Heuristic scope for an untagged finding.
  ///
  /// A delta-gap finding cites the prose as *evidence* for what the delta failed
  /// to register ("正文明确写出伤势，但 ENT-004 的 attributes 为空"). Treating any
  /// mention of 正文 as "the text is wrong" sent those findings to a full
  /// rewrite, which regenerated prose that was already correct — the model
  /// returned near-identical text and the stall detector killed the round. So
  /// 正文 alone no longer forces a rewrite; only phrasing that asks for the text
  /// itself to change does.
  private func inferredRepairScope(_ issue: String) -> IssueRepairScope {
    let lowered = issue.lowercased()
    // Phrasings that put the defect in the text: the prose contradicts an
    // established fact, or the reviewer explicitly asks for the text to change.
    let proseMutationPatterns = [
      #"正文[^。；\n]{0,12}(却|但|仍|还|竟)"#,
      #"正文[^。；\n]{0,8}(应|需|要|得|须)(改|补|删|写|加|减|调)"#,
      #"(改|补|删|加|调)[^。；\n]{0,6}正文"#,
      // 正文 must be the subject of the defect, not the yardstick it is
      // measured against. "正文写错了" is a prose fix; "实体 state 与正文矛盾"
      // is a delta fix, because the text is the source of truth there — so a
      // preceding 与/和/跟 excludes the match.
      #"(?<![与和跟])正文[^。；\n]{0,12}(错|矛盾|不一致|无依据|无源|遗漏了)"#,
      #"在正文(中|里)?(补|加|写|删|改)"#,
      // "the text contradicts an established record" — the number or fact in
      // the prose is the defect, so registering it in the delta would only
      // record the contradiction. Distinct from "prose shows X but the delta
      // failed to register X", where the text is already right.
      #"与(既有|既定|已登记|在案)[^。；\n]{0,10}(冲突|矛盾|不符|不一致)"#,
      #"(与|和)[^。；\n]{0,16}(冲突|矛盾)[^。；\n]{0,8}(应|需|须|改)"#,
    ]
    if proseMutationPatterns.contains(where: {
      lowered.range(of: $0, options: .regularExpression) != nil
    }) {
      return .prose
    }
    // Defects that are inherently about the text, independent of 正文 wording.
    let proseOnlyMarkers = [
      "剧情", "叙事", "字数", "文风", "因果", "自相矛盾",
      "不可变", "违反", "不允许新增", "越界", "时间线错误",
    ]
    if proseOnlyMarkers.contains(where: lowered.contains) { return .prose }
    // Structural craft words that a delta-gap finding also uses incidentally —
    // "章末纱布重新渗血" cites where the evidence sits, it does not complain
    // about the ending. These count only alongside violation phrasing.
    let structuralCraftPatterns = [
      #"(章末|收尾|结尾)[^。；\n]{0,20}(总结|淡出|独白|格言|睡去|违规|不符|应停|未停|收束)"#,
      #"(节拍卡?)[^。；\n]{0,12}(禁止|违反|未覆盖|漏写|不符|超出|范围)"#,
      #"(超出|越出|不在)[^。；\n]{0,12}节拍卡"#,
      // Time/place drift in the text itself: the prose puts a scene outside the
      // window the beat sheet or a prior chapter fixed.
      #"正文[^。；\n]{0,20}(时间|时刻|时序)[^。；\n]{0,12}(超出|不符|错|矛盾|推后|提前)"#,
      #"(时间|时刻|时序)[^。；\n]{0,12}(口径)?[^。；\n]{0,8}不一致"#,
      #"(清单|条目化|备忘录|盘点块)[^。；\n]{0,12}(叙事|承担|铺陈|呈现)"#,
    ]
    if structuralCraftPatterns.contains(where: {
      lowered.range(of: $0, options: .regularExpression) != nil
    }) {
      return .prose
    }
    let deltaMarkers = [
      "delta", "consistencydelta", "差量", "登记", "upsert", "attributes",
      "type字段", "实体分类", "索引分类", "ent-", "tl-", "hook-",
    ]
    let repairMarkers = [
      "缺少", "遗漏", "未登记", "漏登", "缺口", "需要在", "应在", "补充", "补全",
      "登记", "记录", "类型", "type字段", "分类", "字段", "为空", " id", "id ", "统一",
    ]
    if deltaMarkers.contains(where: lowered.contains),
       repairMarkers.contains(where: lowered.contains) {
      return .delta
    }
    return .prose
  }

  private func repairScope(_ issue: String) -> IssueRepairScope {
    taggedRepairScope(issue) ?? inferredRepairScope(issue)
  }

  /// True when every blocking finding can be cleared by rewriting the delta
  /// alone. Erring toward delta-only is cheap and self-correcting: the repair
  /// leaves the prose untouched and a still-failing re-review falls through to
  /// the rewrite loop, whereas a needless rewrite burns a full generate+review
  /// round on text that was already correct.
  func shouldAttemptDeltaOnlyRepair(_ review: NativeReview) -> Bool {
    guard !review.issues.isEmpty else { return false }
    return review.issues.allSatisfy { repairScope($0) == .delta }
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
    // Set after a stalled round so the next one runs with an explicit
    // "you returned identical text" directive and a raised temperature. Only one
    // escalation is attempted; a second stall is a real dead end.
    var stallEscalated = false

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
        if review.protocolFailure {
          finalizeReviewProtocolFailure(
            bookID: bookID,
            chapterNumber: chapter.number,
            title: chapter.title,
            attempts: attempts,
            startedAt: startedAt
          )
          return
        }
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
    // A chapter with no stored delta takes the cheap delta-only repair first no
    // matter how the review worded its findings — rewriting prose that is
    // already correct cannot produce the missing registration, and the stall
    // detector then kills the round. See chapterIsMissingConsistencyDelta.
    let missingDelta = chapterIsMissingConsistencyDelta(
      bookID: bookID,
      chapterNumber: chapter.number
    )
    var wantsDeltaOnlyRepair = missingDelta
      || (deltaRepairReview.map(shouldAttemptDeltaOnlyRepair) ?? false)
    // Delta repair used to get exactly one attempt: a re-review that came back
    // with fresh `[delta]`-only findings still fell through to the rewrite loop,
    // which is the wrong tool by construction. Chapter 27 of 《渊雨浩劫》 spent
    // its whole budget that way — the repair closed the ID collision, the
    // re-review answered with three more delta faults (unclosed hooks, a
    // duplicate hook), and the three rewrite rounds that followed all worked on
    // prose that needed no edit. Two of them returned byte-identical text (the
    // correct answer for a delta-only fault), which the stall detector read as a
    // dead end and escalated to temperature 0.7 with "the text must differ" —
    // so the model padded the chapter to 4052 characters and died on the length
    // ceiling. Keep repairing while the findings stay in delta scope.
    var deltaRepairRounds = 0
    while !stopBeforeRewrite, wantsDeltaOnlyRepair, deltaRepairRounds < maxAutoRevisionRounds {
      deltaRepairRounds += 1
      if missingDelta, deltaRepairRounds == 1 {
        recordDebug(scope: "review", message: "chapter.delta_revision.forced", data: [
          "bookId": bookID,
          "chapterNumber": chapter.number,
          "reason": "本章没有已登记的 consistencyDelta，先只补登记，不重写正文。",
        ])
      }
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
        if review.protocolFailure {
          finalizeReviewProtocolFailure(
            bookID: bookID,
            chapterNumber: chapter.number,
            title: chapter.title,
            attempts: attempts,
            startedAt: startedAt
          )
          return
        }
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
            "deltaRounds": deltaRepairRounds,
          ])
          return
        }
        currentNote = automaticRevisionNote(for: review)
        currentMode = "auto_rewrite"
        // Still delta-only? Repair again rather than rewriting correct prose.
        wantsDeltaOnlyRepair = shouldAttemptDeltaOnlyRepair(review)
        if wantsDeltaOnlyRepair, deltaRepairRounds < maxAutoRevisionRounds {
          recordDebug(scope: "review", message: "chapter.delta_revision.repeated", data: [
            "bookId": bookID,
            "chapterNumber": chapter.number,
            "round": deltaRepairRounds + 1,
            "reason": "复审意见仍全部属于 Delta 范畴，继续只修登记，不重写正文。",
          ])
        }
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
        wantsDeltaOnlyRepair = false
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
        triggerReview: triggerReview,
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
        isAutomaticRound: isAutomaticRound,
        stallEscalated: stallEscalated
      )
      anyRoundPersisted = anyRoundPersisted || outcome.persisted
      let attemptNumber = attempts.count + 1
      if let review = outcome.review {
        attempts.append(reviewAttemptRecord(review, attempt: attemptNumber))
        lastReview = review
        if review.protocolFailure {
          finalizeReviewProtocolFailure(
            bookID: bookID,
            chapterNumber: chapter.number,
            title: outcome.title,
            attempts: attempts,
            startedAt: startedAt
          )
          return
        }
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
        // Failed review: carry this round's findings into the next round,
        // together with a summary of what the previous note asked for, so
        // the model doesn't repeat the same misunderstanding.
        baseChapter = ChapterDetail(from: baseChapter, title: outcome.title, content: outcome.content)
        currentNote = automaticRevisionNote(for: review, priorNote: currentNote, completedRound: round)
        currentMode = "auto_rewrite"
        lastError = nil
      } else {
        // The round threw before yielding a reviewable draft. Record the error
        // as an attempt and, if rounds remain, retry with the error folded into
        // the note so the model knows what to avoid.
        let errorMessage = outcome.error?.localizedDescription ?? "修订轮次异常"
        attempts.append([
          "pass": false,
          "status": "error",
          "attempt": attemptNumber,
          "error": errorMessage,
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
        // Unchanged output used to terminate the whole revision on the spot. That
        // made every deterministic local-rule failure a dead end: at the
        // configured temperature (0.2) restating the same request reproduces the
        // same prose, so chapter 25 of 《渊雨浩劫》 burned a round and died 257
        // characters short of its floor with no way to recover. Escalate once
        // instead — say plainly that nothing changed, name the required edit, and
        // raise the temperature — and only treat a second stall as a real dead end.
        if errorMessage.contains("完全相同") || errorMessage.contains("stalled") {
          if !stallEscalated, round < maxAutoRevisionRounds {
            stallEscalated = true
            recordDebug(scope: "craft", message: "chapter.revision.stallEscalated", data: [
              "bookId": bookID,
              "chapterNumber": chapter.number,
              "round": round,
              "reason": "输出与上一版逐字相同，下一轮改用强化指令并抬高温度重试。",
            ])
            currentMode = "auto_rewrite"
            lastError = nil
            continue
          }
          recordDebug(scope: "craft", message: "chapter.revision.terminated", level: "warning", data: [
            "bookId": bookID,
            "chapterNumber": chapter.number,
            "round": round,
            "escalated": stallEscalated,
            "reason": stallEscalated
              ? "强化指令后输出仍与上一版相同，终止自动重试。"
              : "模型输出停滞且已无剩余轮次，终止自动重试。",
          ])
          break
        }
        // The endpoint rejected the request itself (4xx other than rate
        // limiting, which `requestLLM` already retried and gave up on). Local
        // validators intentionally use HTTP-shaped 4xx codes too, so origin must
        // be explicit: treating every local 409/422 as a remote rejection killed
        // the loop before its corrective note could reach the next round.
        if let coreError = outcome.error as? InkOSCoreError,
           coreError.origin != .local,
           (400...499).contains(coreError.statusCode),
           coreError.statusCode != 429 {
          let reason = coreError.origin == .requestConfiguration
            ? "模型请求配置无效，继续重写正文不会修复配置，终止自动重试。"
            : "请求被服务端拒绝，重试同一调用不会成功，终止自动重试。"
          recordDebug(scope: "craft", message: "chapter.revision.terminated", level: "warning", data: [
            "bookId": bookID,
            "chapterNumber": chapter.number,
            "round": round,
            "statusCode": coreError.statusCode,
            "errorOrigin": coreError.origin == .requestConfiguration ? "requestConfiguration" : "remoteResponse",
            "reason": reason,
          ])
          break
        }
        currentNote = "\(currentNote)\n\n【上一轮修订异常，请修正后重写】\n\(errorMessage)"
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
      triggerReview: triggerReview,
      lastError: lastError,
      anyRoundPersisted: anyRoundPersisted,
      // `maxAutoRevisionRounds > 1` used to sit in this disjunction; it is a
      // constant, so a purely manual revision was always recorded as an
      // automatic fix. A run is automatic when it followed an initial failure,
      // a revalidation/delta lead-in, or reached a second rewrite round.
      automatic: initialReview != nil || automaticLeadIn || completedRewriteRounds > 1,
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

  /// True when the chapter has no usable stored delta at all.
  ///
  /// This is a state fact, not a review finding, so it must not depend on how a
  /// review happened to word its issues. Chapter 23 of 《渊雨浩劫》 deadlocked
  /// precisely there: prose recovery saved the draft, the delta stayed missing,
  /// and because the review text mentioned 正文 the delta-only path was skipped
  /// in favour of a full rewrite. The model then returned the same (already
  /// correct) prose, the stall detector killed the round, and every retry
  /// repeated it. When the delta is absent the cheap repair is the only sane
  /// first move regardless of review wording.
  func chapterIsMissingConsistencyDelta(bookID: String, chapterNumber: Int) -> Bool {
    (try? chapterConsistencyDelta(bookID: bookID, chapterNumber: chapterNumber)) == nil
  }

  private func shouldRevalidateStoredDraft(note: String, review: NativeReview) -> Bool {
    guard review.protocolFailure || review.model == "native-draft-validator" else { return false }
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
      try withChapterPersistenceTransaction(bookID: bookID, chapterNumber: chapter.number) {
        try writeChapter(
          bookID: bookID,
          number: chapter.number,
          title: chapter.title,
          content: chapter.content,
          status: review.pass ? "pending_review" : "revision_failed",
          llmReview: reviewRecord(
            review,
            status: persistedReviewStatus(review),
            attempts: priorAttempts + [
              reviewAttemptRecord(review, attempt: priorAttempts.count + 1),
            ]
          )
        )
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
      }
      didWriteChapter = true
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
        bookID: bookID,
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
      try withChapterPersistenceTransaction(bookID: bookID, chapterNumber: chapter.number) {
        try writeChapter(
          bookID: bookID,
          number: chapter.number,
          title: chapter.title,
          content: chapter.content,
          status: review.pass ? "pending_review" : "revision_failed",
          llmReview: reviewRecord(
            review,
            status: persistedReviewStatus(review),
            autoFixed: true,
            attempts: priorAttempts + [
              reviewAttemptRecord(review, attempt: priorAttempts.count + 1),
            ]
          )
        )
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
      }
      didWriteChapter = true
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
    bookID: String,
    chapterNumber: Int,
    title: String,
    content: String,
    currentDelta: ContinuityDelta,
    findings: String
  ) async throws -> [String: Any] {
    let currentJSON = String(data: try encoder.encode(currentDelta), encoding: .utf8) ?? "{}"
    // The full continuity index the reviewer sees is a ~70 000-character JSON
    // blob, and an ID buried in it is easy to miss: chapter 27 reused ENT-030
    // for 苏晚晴 even though the canon showed ENT-CH26-001. A flat ID → name
    // roster is the one thing this repairer must not have to search for.
    let registry = (try? entityIDRegistryText(bookID: bookID)) ?? "（无法读取，请勿改动任何既有 ID）"
    let prompt = """
      你是 InkOS 一致性登记修复器。正文已经定稿，本次禁止改写正文、标题、剧情、字数或文风，只修复 consistencyDelta。
      根据审核意见校正当前 Delta，保留没有问题的 ID 和字段，只修改审核点名的登记错误；正文未支持的事实不得新增。
      entities.type 最终只能输出五个英文值：character、object、location、faction、concept。审核意见中的 item、物品、物件、设备、资源或储备一律输出 object，地点或场所输出 location，人物输出 character。
      每个实体的 id 必须与下面【正典实体 ID 名册】里同名条目的 ID 完全一致；名册里没有的实体才算新实体，新实体必须使用名册中尚未出现的 ID。绝不能把一个实体登记成名册中另一个实体已占用的 ID。
      remove.hooks 的 id 必须使用下面【未关闭伏笔名册】中的真实 hookId；猜测或自造 ID 会触发"删除目标不存在"校验错误。
      只输出修复后的 consistencyDelta JSON：{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}。

      【审核意见】
      \(findings)

      【正典实体 ID 名册】
      \(registry)

      【未关闭伏笔名册】
      \((try? openHooksRegistryText(bookID: bookID)) ?? "（无法读取，请勿关闭任何伏笔）")

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
    isAutomaticRound: Bool,
    stallEscalated: Bool = false
  ) async -> RevisionRoundOutcome {
    let key = generationKey(bookID, baseChapter.number)
    var latestTitle = baseChapter.title
    var latestContent = baseChapter.content
    var didWriteChapter = false
    // Captured before the round runs. A chapter whose delta was never written is
    // being repaired, so identical prose afterwards means "the text was already
    // correct" rather than "the model stalled" — see the stall check below.
    let deltaWasMissing = chapterIsMissingConsistencyDelta(
      bookID: bookID,
      chapterNumber: baseChapter.number
    )
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
      let gap = minWords - currentCount
      let wordGapInstruction: String
      if currentCount < minWords {
        // Small gaps (<20 chars) are nearly impossible to hit precisely and
        // lead to loops where the model returns identical text. When that close,
        // accept it rather than demanding exact alignment.
        if gap > 0 && gap < 20 {
          wordGapInstruction = "字数 \(currentCount) 已接近下限 \(minWords)（差 \(gap) 字），保持当前长度即可，无需刻意增补。"
        } else {
          wordGapInstruction =
            "还差约 \(gap) 字，需要展开场景或补充细节；" +
            "切勿以凑字符号、空行或重复句子填充。"
        }
      } else if currentCount > ceiling {
        wordGapInstruction =
          "已超出验收上限 \(ceiling) 字约 \(currentCount - ceiling) 字，" +
          "必须精简或将多余剧情移至后续章节。"
      } else if currentCount > maxWords {
        // "建议适当精简" alone let chapter 27 of 《渊雨浩劫》 read this band as
        // "essentially fine" and grow to 4052 while repairing a delta-only
        // defect. The ceiling is a hard local gate, so say so here.
        wordGapInstruction =
          "超出软上限约 \(currentCount - maxWords) 字，建议适当精简；"
          + "无论如何修订，全章不得超过验收上限 \(ceiling) 字，超出即整轮作废，因此严禁扩写。"
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
      let context = try storyContext(bookID: bookID, maxCharacters: 60_000, plan: plan)
      // Include the tail of the preceding chapter so the model can see the
      // continuity anchor it must connect to. Generation prompts have always
      // carried the full previous chapter; revision prompts historically did
      // not, which caused衔接 hard issues that then required another round.
      let previousTail: String
      if baseChapter.number > 1,
         let prevText = try? readChapterText(bookID: bookID, number: baseChapter.number - 1),
         !prevText.isEmpty
      {
        previousTail = String(prevText.suffix(800))
      } else {
        previousTail = ""
      }
      let beatSection = beat.map(beatBriefText)
        ?? "（本章没有节拍卡，按既有正文范围修订，不要扩大本章承载的剧情量）"
      let derivative = try derivativeGenerationSections(
        bookID: bookID,
        chapterNumber: baseChapter.number,
        beat: beat,
        plan: plan,
        fallbackQuery: "\(baseChapter.title)。\(baseChapter.content)"
      )
      // Set when the previous round returned prose byte-identical to its input.
      // Restating the same request produces the same sample, so the retry has to
      // say plainly that nothing changed and name the concrete edit required.
      //
      // The "expand 2–3 scenes" line is conditional on the chapter actually being
      // short, and must stay that way: chapter 27 of 《渊雨浩劫》 sat 6 characters
      // over its soft cap with a delta-only defect, and an unconditional expand
      // instruction at temperature 0.7 took it to 4052 against a 3795 ceiling —
      // three rounds died on a chapter whose prose needed no edit at all.
      let stallLengthDirective = currentCount >= maxWords
        ? "- 本章字数已到上限，绝不可扩写：必须在不增加总字数的前提下改写"
          + "（替换或重写句子、收紧冗余表述），改完后总字数不得超过 \(ceiling) 字；"
        : "- 若问题是字数或密度不足，选定 2–3 个已有场景就地展开（增加动作、对话、环境细节与人物反应），"
          + "不要新增剧情线、不要提前后续章节内容、不要用符号或空行凑数；"
      let stallDirective = stallEscalated
        ? """

          【重要：上一轮你返回的正文与修订前逐字相同，等于没有修改】
          请不要再原样返回。本轮必须产出与上一版不同的正文：
          - 逐条落实上面的修改意见，改动要能在正文里看得见；
          \(stallLengthDirective)
          - 保留已经正确的段落，只改需要改的部分，但整章不得与上一版完全一致。
          """
        : ""
      let prompt = """
        你是 InkOS 章节修订器。请依据修改意见修订完整正文，保持既有设定、人物知识边界、持久物品和前后章因果。
        此前章节与本章既有正文确立的中断、不可用或耗尽状态（断信号、断电、断水、资源耗尽等）有约束力：修订稿使用通信、电力、设施或消耗品之前必须确认其可用；改变状态可用性时必须在正文写出发生的时刻与原因；同章之内不得自相矛盾。
        当前正文 \(currentCount) 字；目标区间 \(minWords)–\(maxWords) 字（参考目标 \(targetWords) 字，验收上限 \(ceiling) 字）。\(wordGapInstruction)
        \(densityInstruction)
        修订只在本章节拍卡范围内进行：不得引入节拍卡禁止清单中的内容，不得把后续章节的剧情提前到本章。
        consistencyDelta 必须完整描述修订后本章的新贡献；旧版本仅由本章产生的记录会自动退出。新增或更新写入 upsert；remove 只用于正文事件明确终止的既有跨章记录。
        修订稿的 Delta 必须覆盖修订后正文的全部事实：原版本已登记且仍然成立的实体与伏笔必须保留，修订不是从零登记；正文出现的每个具名人物、地点、持久物品都必须登记；本章兑现或推翻的既有伏笔必须在 remove.hooks 中按 ID 关闭；不得静默丢弃索引中的既有实体。
        entities.type 只能输出 character、object、location、faction、concept；物品、设备、资源和储备统一写 object，不得写 item 或中文类型名。
        entities 的 id 规则：已在【正典实体 ID 名册】中出现的实体，必须沿用名册里同名条目的 ID；名册中没有的才是新实体，新实体必须使用名册里尚未出现的 ID。把某个实体登记成名册中另一实体已占用的 ID 会导致本章被打回。
        remove.hooks 的 id 规则：必须使用【未关闭伏笔名册】中的真实 hookId；猜测或自造 ID 会触发"删除目标不存在"错误，本章将被打回。
        只输出 JSON：{"title":"章节标题","content":"完整正文","summary":"修订摘要","consistencyDelta":{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"","name":"","type":"character|object|location|faction|concept"}],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}}。
        修订模式：\(mode)
        修改意见：\(note)
        \(stallDirective)

        \(craft)

        【正典实体 ID 名册】
        \(entityIDRegistryText(plan.continuity))

        【未关闭伏笔名册】
        \(openHooksRegistryText(plan.continuity))

        【本章节拍卡】
        \(beatSection)\(derivative.timeline)

        【全书约束与状态】
        \(context)\(derivative.source)
        \(previousTail.isEmpty ? "" : "\n        【上一章结尾（衔接参考，最后800字）】\n        \(previousTail)")

        【原章节】
        第\(baseChapter.number)章 \(baseChapter.title)
        \(baseChapter.content)
        """
      // Reuse the plan loaded at the top of this round instead of triggering
      // another synchronizeContinuityProjection I/O call just to read
      // requireConsistencyDelta — the value cannot change during prompt construction.
      let (parsed, result) = try await requestChapterPayload(
        prompt: prompt,
        chapterNumber: baseChapter.number,
        requireDelta: plan.continuity.policy.requireConsistencyDelta,
        timeout: 600,
        // Raised only for a stall retry: the configured 0.2 is near-deterministic,
        // so the same prompt reproduces the same prose no matter how it is worded.
        temperature: stallEscalated ? 0.7 : nil,
        onPartialContent: { [weak self] partial in
          await self?.updateGenerationLiveText(key: key, rawText: partial)
        }
      )
      let suppliedDelta = parsed["consistencyDelta"] as? [String: Any]
      if plan.continuity.policy.requireConsistencyDelta, suppliedDelta == nil {
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

      // Detect unchanged output: if the model returned exactly the same prose,
      // further retries with the same prompt are futile. Mark as stalled rather
      // than burning more rounds.
      //
      // One exception, and it is the deadlock chapter 23 of 《渊雨浩劫》 hit:
      // when the round starts with no stored delta, identical prose is the
      // *correct* answer — the defect was the missing registration, not the
      // text. Killing the round here discarded the delta the model had just
      // supplied, so every retry repeated the same "内容与修订前完全相同"
      // termination and the chapter could never leave revision_failed. Treat it
      // as a stall only when the delta is still absent afterwards, which is a
      // genuine no-progress round.
      let newCount = proseCount(content)
      let oldCount = proseCount(baseChapter.content)
      let proseUnchanged = newCount == oldCount
        && content.trimmingCharacters(in: .whitespacesAndNewlines)
          == baseChapter.content.trimmingCharacters(in: .whitespacesAndNewlines)
      if proseUnchanged, !(deltaWasMissing && suppliedDelta != nil) {
        recordDebug(scope: "craft", message: "chapter.revision.stalled", level: "warning", data: [
          "bookId": bookID,
          "chapterNumber": baseChapter.number,
          "round": round,
          "reason": "模型返回内容与修订前完全相同，继续重试无意义。",
        ])
        return .stalled(lastTitle: title, lastContent: content)
      }
      if proseUnchanged {
        recordDebug(scope: "craft", message: "chapter.revision.deltaOnlyProgress", data: [
          "bookId": bookID,
          "chapterNumber": baseChapter.number,
          "round": round,
          "reason": "正文与修订前相同，但本轮补回了缺失的 consistencyDelta，按有效进展继续。",
        ])
      }

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
      try withChapterPersistenceTransaction(bookID: bookID, chapterNumber: baseChapter.number) {
        try writeChapter(
          bookID: bookID,
          number: baseChapter.number,
          title: title,
          content: content,
          status: review.pass ? "pending_review" : "revision_failed",
          llmReview: reviewRecord(
            review,
            status: persistedReviewStatus(review),
            autoFixed: isAutomaticRound ? true : nil,
            attempts: priorAttempts + [reviewAttemptRecord(review, attempt: priorAttempts.count + 1)]
          )
        )
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
      }
      didWriteChapter = true
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
  private func finalizeReviewProtocolFailure(
    bookID: String,
    chapterNumber: Int,
    title: String,
    attempts: [[String: Any]],
    startedAt: String
  ) {
    generationJobs[generationKey(bookID, chapterNumber)] = try? makeGenerationJob(
      bookID: bookID,
      chapterNumber: chapterNumber,
      title: title,
      phase: "revision_failed",
      message: "审核模型响应协议错误，正文与一致性登记保持不变",
      startedAt: startedAt,
      finishedAt: isoTimestamp(),
      error: "审核响应不符合协议，请重新提交审核",
      attempts: attempts
    )
    recordDebug(scope: "review", message: "chapter.review.protocol_error.retained", level: "error", data: [
      "bookId": bookID,
      "chapterNumber": chapterNumber,
    ])
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
    /// The finding that opened this revision — the local validator's verdict or
    /// the stored review. Used only to explain a stall, where no round produced
    /// a newer review of its own.
    triggerReview: NativeReview?,
    lastError: Error?,
    anyRoundPersisted: Bool,
    automatic: Bool,
    roundsCompleted: Int
  ) {
    let key = generationKey(bookID, chapter.number)
    // A stall means the model returned the previous text unchanged, so the
    // reason this chapter is still blocked is whatever the last review found —
    // "输出与原文完全相同" is mechanism, not a defect a human can act on. Any
    // other error (transport, JSON, persistence) is itself the news and stays.
    let stalled = lastError?.localizedDescription == RevisionRoundOutcome.stallErrorMessage
    let standingReview = lastReview ?? triggerReview
    let standingIssues = standingReview?.issues.joined(separator: "；").nonEmpty
    let errorText = (stalled ? standingIssues : nil)
      ?? lastError?.localizedDescription
      ?? standingIssues
      ?? "自动修改多轮后仍未通过"
    let review: NativeReview
    if let lastError, !(stalled && standingIssues != nil) {
      review = NativeReview(
        pass: false,
        model: "native-revision-loop",
        summary: anyRoundPersisted ? "最新自动修改轮次发生异常。" : "多轮自动修改均未产出可复审的草稿。",
        issues: ["[hard] 修订异常：\(lastError.localizedDescription)"],
        revisionGuidance: "请根据错误信息修正后重新提交修改。"
      )
    } else if let standingReview {
      review = standingReview
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
      "protocolFailure": review.protocolFailure,
      "craftAdvisories": review.advisories,
      "revisionGuidance": review.revisionGuidance,
      "reviewedAt": isoTimestamp(),
      "attempts": attempts,
    ]
    if let autoFixed { record["autoFixed"] = autoFixed }
    if let rewriteError, !rewriteError.isEmpty { record["rewriteError"] = rewriteError }
    return record
  }

  private func persistedReviewStatus(_ review: NativeReview) -> String {
    if review.protocolFailure { return "protocol_error" }
    return review.pass ? "passed" : "failed"
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
    // Local draft rules are length and craft checks, so clearing them always
    // means editing the text — never a delta-only repair.
    let issue = "[hard][prose] 本地章节规则：\(errorMessage)"
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
      "status": review.protocolFailure ? "protocol_error" : (review.pass ? "passed" : "failed"),
      "attempt": attempt,
      "model": review.model,
      "summary": review.summary,
      "issues": review.issues,
      "protocolFailure": review.protocolFailure,
      "revisionGuidance": review.revisionGuidance,
      "reviewedAt": isoTimestamp(),
    ]
  }

  private func reviewAttemptRecord(_ stored: ReviewAttempt, attempt: Int) -> [String: Any] {
    var record: [String: Any] = ["attempt": attempt]
    if let pass = stored.pass { record["pass"] = pass }
    if let status = stored.status { record["status"] = status }
    if let protocolFailure = stored.protocolFailure { record["protocolFailure"] = protocolFailure }
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

  /// Builds the note fed to the next rewrite round.
  ///
  /// When `priorNote` is provided the model can see what the previous round
  /// was asked to fix and what it produced — without that context, round 2
  /// starts from the same abstract prompt as round 1 and tends to make the
  /// same mistakes. The prior note is capped at 1 200 chars so it does not
  /// crowd out the current guidance.
  private func automaticRevisionNote(
    for review: NativeReview,
    priorNote: String? = nil,
    completedRound: Int = 0
  ) -> String {
    var sections: [String] = []
    if let prior = priorNote?.trimmingCharacters(in: .whitespacesAndNewlines), !prior.isEmpty,
       completedRound > 0
    {
      let capped = prior.count > 1_200 ? "…" + prior.suffix(1_200) : prior
      sections.append(
        "【第 \(completedRound) 轮修改指令（已执行）】\n\(capped)"
      )
      sections.append(
        "第 \(completedRound) 轮修改完成后审核仍未通过（结论：\(review.summary)）。"
          + "请在上一轮修改的基础上继续修正，不要推翻已经正确的部分。"
      )
    } else {
      sections.append("以下是系统初审发现的硬问题。请逐项修正后重写完整正文与 consistencyDelta。")
    }
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
    /// The reviewer failed its response contract, so the prose must be retained
    /// and re-reviewed rather than rewritten on an invented finding.
    var protocolFailure: Bool = false

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
        // These are structural delta faults (missing removal target, locked
        // attribute, illegal type change), so the delta-only repair goes first.
        // Where the prose is the real cause, that repair's re-review still
        // fails and the rewrite loop picks it up — the cheap attempt costs one
        // delta call, while the reverse misclassification costs a full
        // generate+review round on text that needed no edit.
        issues: ["[hard][delta] 连续性差量：\(error.localizedDescription)"],
        revisionGuidance: "修正 consistencyDelta，使其符合连续性策略后重新提交；确认正文本身无需改动。"
      )
    }
    let plan = try synchronizeContinuityProjection(bookID: bookID)
    let reviewBand = plan.chapterWordBand(for: chapterNumber)
    let minWords = reviewBand.minWords
    let maxWords = reviewBand.maxWords
    // The review model must judge length against the same threshold
    // `validateChapterLength` enforces. Telling it `maxWords` was hard while
    // local validation accepted up to the ceiling created a dead band between
    // the two: a draft passed locally, then the review failed it as [hard], and
    // the revision prompt only "suggested" trimming that range.
    let reviewCeiling = maxWords + max(200, maxWords / 10)
    let previous = chapterNumber > 1 ? (try? readChapterText(bookID: bookID, number: chapterNumber - 1)) ?? "" : ""
    let context = try storyContext(bookID: bookID, maxCharacters: 80_000, plan: plan)
    let craft = try craftDirectives(bookID: bookID, chapterNumber: chapterNumber)
    let deltaJSON = String(data: try encoder.encode(candidateDelta), encoding: .utf8) ?? "{}"
    let projectedJSON = String(data: try encoder.encode(projected), encoding: .utf8) ?? "{}"
    let deltaText = String(deltaJSON.prefix(40_000))
    let projectedText = String(projectedJSON.prefix(80_000))
    let beatSection = beat.map(beatBriefText) ?? "（本章无节拍卡，跳过排期与节拍核对）"
    let derivative = try derivativeGenerationSections(
      bookID: bookID,
      chapterNumber: chapterNumber,
      beat: beat,
      plan: plan,
      fallbackQuery: "\(title)。\(content)"
    )
    let prompt = """
      你要同时执行两类审核，并严格区分严重级别。

      第一类：硬连续性（阻断）。审核正文和候选 consistencyDelta 的跨章一致性、人物知情边界、时间地点、伤势、持久物品、世界规则和伏笔生命周期。
      逐项确认正文新增或改变的人物、物品、地点、组织、规则、知识、时间事件和伏笔都登记在 Delta 中；Delta 的每项更新或删除也必须有正文依据。
      entities.type 的唯一规范值是 character、object、location、faction、concept；物品、设备、资源和储备必须是 object。item、物品等输入别名即使会被本地归一化，也不得作为审核建议或输出口径。
      当 allowUnplannedEntities=false 时，正文不得引入审核前索引中不存在的人物、物品、地点、组织或概念。
      节拍卡的禁止清单等同硬约束：正文若出现被本章明令推迟的剧情、人物、物品、能力或结局，记为 hard。
      正文字数目标区间是 \(minWords) 至 \(maxWords) 字，验收上限 \(reviewCeiling) 字。低于 \(minWords) 字或高于 \(reviewCeiling) 字记为 hard；落在 \(maxWords) 与 \(reviewCeiling) 字之间只作为 soft 提醒，不阻断。
      章末必须停在节拍卡声明的选择、反转、倒计时或新信息上。若以总结、氛围淡出、格言独白或"安心睡去"式收尾收束全章，记为 hard。
      正文不得用清单、备忘录、条目化盘点或资料登记块承担叙事。主角本人的账本记录也只能以动作与判断混合的方式呈现，不能以并列条目铺陈，出现记为 hard。
      正文不得以“第28天”“雨季第28天”这类绝对纪日标签开篇、另起段落或在句间替读者报日序，出现记为 hard；“第二天一早”等相对时间过渡，以及角色在对话、台账或物资心算中引用日期不在此限。
      第 1 至 3 章作为开篇段整体必须至少建立一次主角核心能力或金手指锚点：异常征兆、首次显现或章末触发均可。前章已经建立后，当前章无需重复；节拍卡明确禁止能力显现时，以禁止清单为准，不得为了重复锚点提前能力。仅在截至当前章整个开篇段仍完全没有锚点时记为 hard。
      环境状态与资源可用性必须前后一致：此前章节或本章前文确立的中断、不可用或耗尽状态（断信号、断电、断水、封路、资源耗尽、设施损坏等），后文不得在没有恢复、替代或解释的情况下当作可用。同章之内自相矛盾（如先说信号彻底没了、后文又收到群视频）同样记为 hard。
      \(derivative.reviewRule)
      以上任一问题输出前缀 [hard]，并紧跟一个修复范围标签，二者只能选一个：
      [delta]：只需改候选 consistencyDelta 就能消除该问题，正文不必改动一个字。正文写对了、只是没登记进 Delta（如实体 attributes 为空、漏登 upsert、时间线 order 排序错误、删除目标不存在、type 取值不规范）都属于此类；即使你在描述中引用正文作为"应当登记什么"的依据，只要正文本身无需修改，就必须标 [delta]。
      [prose]：必须改动正文才能消除该问题（字数不足或超限、章末收尾方式违规、条目化叙事、节拍卡禁止内容、正文与既有设定直接冲突、正文数字与已登记消耗不符、正文写了无依据的细节）。
      标签决定系统走"只补登记"还是"重写正文"：把只需补登记的问题标成 [prose]，会让系统重写一篇本来正确的正文，属于严重误导。

      第二类：写法质量（不阻断）。依据下方写法内核与本书写法约束检查：
      是否有用总结代替关键场景，是否跳过了本该写出的冲突过程；开场是否为背景综述或履历介绍；对话是否承载了关键分歧和转折；本章必需事件和挫折是否真的在场景里发生；视角是否统一；配角语言是否符合其身份、能否相互区分；承诺的冷幽默是否落地；主角是否只有功能反应而没有一处情感泄底（恐惧、犹豫、疲惫、自嘲等）——配角有人味而主角像机器时尤其要点名。
      这些问题输出前缀 [soft]，并在 revisionGuidance 中给出具体可执行的改法。

      pass 只取决于 [hard]：没有 [hard] 问题时 pass=true，即使存在 [soft] 问题。
      只输出 JSON：
      {"pass":true,"summary":"结论","issues":["[hard][delta] 类型：具体问题","[hard][prose] 类型：具体问题","[soft] 写法：具体问题"],"revisionGuidance":""}
      issues 必须是字符串数组；每项以 [hard] 或 [soft] 开头，[hard] 项必须紧跟 [delta] 或 [prose]；不要返回对象数组。

      \(craft)

      【本章节拍卡】
      \(beatSection)\(derivative.timeline)

      【权威设定】
      \(context)\(derivative.source)

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
    // An unparseable review response must not read as "no issues found". The
    // pass condition below only inspects the decoded issue list, so a `?? [:]`
    // fallback produced an empty list and passed the chapter on a malformed
    // review — the one outcome that must never be silent.
    guard let object = parseJSONObject(result.content) else {
      recordDebug(scope: "review", message: "chapter.review.invalidJson", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "model": result.model,
        "finishReason": result.finishReason ?? "unknown",
        "contentLength": result.content.count,
        "head": String(result.content.prefix(200)),
        "tail": String(result.content.suffix(200)),
      ])
      return NativeReview(
        pass: false,
        model: result.model,
        summary: "审核模型未返回合法 JSON，无法判定本章是否通过。",
        issues: [
          "[protocol] 审核响应异常：模型未返回合法 JSON（finishReason=\(result.finishReason ?? "未知")，输出 \(result.content.count) 字符）",
        ],
        revisionGuidance: "保留当前正文，仅重新提交审核；若持续失败请检查审核模型配置与输出长度上限。",
        protocolFailure: true
      )
    }
    guard let requestedPass = object["pass"] as? Bool else {
      recordDebug(scope: "review", message: "chapter.review.protocol_error", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "reason": "missing_or_invalid_pass",
      ])
      return NativeReview(
        pass: false,
        model: result.model,
        summary: "审核响应缺少有效的 pass 字段，无法判定本章是否通过。",
        issues: ["[protocol] 审核响应的 pass 必须是布尔值。"],
        revisionGuidance: "保留当前正文，仅重新提交审核。",
        protocolFailure: true
      )
    }
    guard let rawIssueValues = object["issues"] as? [Any] else {
      recordDebug(scope: "review", message: "chapter.review.protocol_error", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "reason": "missing_or_invalid_issues",
      ])
      return NativeReview(
        pass: false,
        model: result.model,
        summary: "审核响应缺少合法的 issues 数组，无法判定本章是否通过。",
        issues: ["[protocol] 审核响应的 issues 必须是数组。"],
        revisionGuidance: "保留当前正文，仅重新提交审核。",
        protocolFailure: true
      )
    }
    let allIssues = rawIssueValues.compactMap(reviewIssueText)
    guard allIssues.count == rawIssueValues.count else {
      recordDebug(scope: "review", message: "chapter.review.protocol_error", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "reason": "invalid_issue_item",
      ])
      return NativeReview(
        pass: false,
        model: result.model,
        summary: "审核响应包含无法识别的 issues 条目，无法判定本章是否通过。",
        issues: ["[protocol] issues 中的每一项必须是字符串或带有 detail 的对象。"],
        revisionGuidance: "保留当前正文，仅重新提交审核。",
        protocolFailure: true
      )
    }
    let blocking = allIssues.filter(isBlockingIssue)
    let rawAdvisories = allIssues.filter { !isBlockingIssue($0) }
    let advisories = rawAdvisories.filter { !recommendsNoncanonicalEntityType($0) }
    let rawGuidance = string(object["revisionGuidance"])
    let revisionGuidance = recommendsNoncanonicalEntityType(rawGuidance)
      ? (blocking + advisories).joined(separator: "\n")
      : rawGuidance
    if !advisories.isEmpty {
      recordDebug(scope: "review", message: "chapter.craft_advisories", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "count": advisories.count,
      ])
    }
    if (requestedPass && !blocking.isEmpty) || (!requestedPass && blocking.isEmpty) {
      recordDebug(scope: "review", message: "chapter.review.protocol_error", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "reason": "contradictory_pass_and_issues",
        "pass": requestedPass,
        "blockingCount": blocking.count,
      ])
      return NativeReview(
        pass: false,
        model: result.model,
        summary: "审核响应的 pass 与 issues 相互矛盾，无法判定本章是否通过。",
        issues: ["[protocol] pass 与硬问题列表不一致。"],
        revisionGuidance: "保留当前正文，仅重新提交审核。",
        protocolFailure: true
      )
    }
    // `pass` is decided by the absence of [hard] findings, with one guard: a
    // response that claims failure while listing no findings at all is
    // self-contradictory and fails. The previous second clause
    // (`rawAdvisories.count == allIssues.count`) was just `blocking.isEmpty`
    // restated, so it silently converted that contradiction into a pass.
    return NativeReview(
      pass: blocking.isEmpty && (requestedPass || !allIssues.isEmpty),
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
    beat: ChapterBeat? = nil,
    plan existingPlan: LongFormPlanResponse? = nil
  ) throws -> String {
    // Reuse the caller's plan when available so this function doesn't trigger
    // another synchronizeContinuityProjection I/O round.
    let plan = try existingPlan ?? synchronizeContinuityProjection(bookID: bookID)
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
    // Derivative-only: the story clock and the retrieved original passages. Empty
    // for an original book, so its prompt is unchanged by this feature.
    let derivative = try derivativeGenerationSections(
      bookID: bookID,
      chapterNumber: chapterNumber,
      beat: beat,
      plan: plan,
      fallbackQuery: guidance
    )
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
      entities 的 id 规则：已在【正典实体 ID 名册】中出现的实体，必须沿用名册里同名条目的 ID，一个字符都不能改；名册中没有的实体才是新实体，新实体必须使用名册里尚未出现的 ID。把某个实体登记成名册中另一实体已占用的 ID 会导致本章被打回。
      正文里改变生存账本或后续决策的关键资源（存水量、存粮、燃料、电量等）必须在 entities 或 hooks 中登记，且 Delta 中的每个数字与结论都要与正文严格一致，不得出现正文一个数、Delta 另一个数的矛盾。
      此前章节确立的中断、不可用或耗尽状态（断信号、断电、断水、封路、资源耗尽等）对本章有约束力：使用通信、电力、设施或消耗品之前必须确认其当前可用；本章若要改变某个状态的可用性（如信号短暂恢复），必须在正文写出发生的时刻与原因，并登记进 consistencyDelta 的 worldRules；同章之内不得自相矛盾。
      只输出 JSON：{"title":"章节标题","content":"完整正文","summary":"章节摘要","consistencyDelta":{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"","name":"","type":"character|location|object|faction|concept"}],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}}。
      \(guidance.map { "本章额外要求：\($0)" } ?? "")

      \(craft)

      【本章节拍卡】
      \(beatSection)\(derivative.timeline)

      【正典实体 ID 名册】
      \(entityIDRegistryText(plan.continuity))

      【权威设定与当前状态】
      \(try storyContext(bookID: bookID, maxCharacters: 100_000, plan: plan))\(derivative.source)

      【上一章全文】
      \(previous)
      """
  }

  /// The story clock and retrieved original passages, for derivative books only.
  ///
  /// Returns empty strings for an original book. Derivative entry points first run
  /// `validateDerivativePreparationForWriting`, so a missing or damaged index here
  /// is a pipeline fault and must surface instead of silently producing an original
  /// chapter without source evidence.
  private func derivativeGenerationSections(
    bookID: String,
    chapterNumber: Int,
    beat: ChapterBeat?,
    plan: LongFormPlanResponse,
    fallbackQuery: String? = nil
  ) throws -> (timeline: String, source: String, reviewRule: String) {
    guard bookKind(bookID: bookID) == .derivative else { return ("", "", "") }

    var timelineSection = ""
    let timeline = resolvedDerivativeTimeline(bookID: bookID, continuity: plan.continuity)
    let status = derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: chapterNumber,
      continuity: plan.continuity,
      timeline: timeline
    )
    if let text = derivativeTimelineSection(status) {
      timelineSection = "\n\n【本章的原著时间进度】\n\(text)\n"
        + "以上时间进度与节拍卡同等强制：「尚未发生」的原著事件在本章不得发生，"
        + "也不得被任何人知晓、预言或议论。"
    }

    var sourceSection = ""
    let keys = try derivativeRetrievalKeys(
      bookID: bookID,
      beat: beat,
      narrativeText: fallbackQuery
    )
    let beatQuery = derivativeRetrievalQuery(beat: beat)
    let fallback = fallbackQuery?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Review and revision pass the actual prose as a fallback. Combine it with the
    // beat instead of letting a normal non-empty beat suppress the text being
    // checked; each side gets a bounded share so neither can crowd the other out.
    let queryParts = [beatQuery, fallback]
      .compactMap { value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return boundedDerivativeRetrievalQuery(value)
      }
    let query = queryParts.isEmpty ? nil : queryParts.joined(separator: "。")
    if !keys.isEmpty || query != nil {
      let text = try derivativeSourceContext(
        bookID: bookID,
        keys: keys,
        query: query,
        limit: 8,
        maxCharacters: 6_000,
        maximumSourceChapter: derivativeRetrievalMaximumSourceChapter(
          status: status,
          timeline: timeline
        )
      )
      sourceSection = "\n\n【原著正典检索结果】\n"
        + "以下是从原著原文检索到的相关段落，只作为事实依据，不要照抄其文字或把它当作本章剧情：\n"
        + text
    }
    let reviewRule = """

      同人文额外硬规则：以【本章的原著时间进度】为准。待审正文若让“尚未发生”的原著事件提前发生，或让任何角色提前知晓、预言、议论其信息，必须输出 [hard][prose]；这不是补 Delta 可以修复的问题。原著检索段落只可核对已经发生的事实，不得把原文措辞或未检索到的细节当作本章正典。
      """
    return (timelineSection, sourceSection, reviewRule)
  }

  /// Retrieval keys for the chapter: the canon names the beat actually involves.
  ///
  /// Each key is a single term, and the multi-key search is OR — one whitespace-
  /// joined key would AND the terms instead and typically return nothing, since a
  /// single source paragraph rarely contains every character the chapter features.
  /// Keys are intersected with registered canon entities so a name the derivative
  /// work invented is not searched for in a novel that has never heard of it; an
  /// invented name matches nothing and would only crowd out the real keys.
  func derivativeRetrievalKeys(
    bookID: String,
    beat: ChapterBeat?,
    narrativeText: String? = nil
  ) throws -> [String] {
    let manifest = try loadSourceManifest(bookID: bookID)
    let progress = try loadCanonProgress(bookID: bookID, manifest: manifest)
    // Only entities extracted from the original are valid lexical keys. The full
    // projection also contains author overlay and derivative-chapter entities; an
    // invented protagonist used as the sole key previously suppressed retrieval.
    let canonNames = Set(progress.delta.upsert.entities.map(\.name))
    var keys: [String] = []
    var seen = Set<String>()

    func append(_ name: String) {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard keys.count < 6,
        trimmed.count >= 2,
        canonNames.contains(trimmed),
        !seen.contains(trimmed)
      else { return }
      seen.insert(trimmed)
      keys.append(trimmed)
    }

    if let beat {
      for name in beat.focusCharacters {
        append(name)
      }
    }

    // Beat generators do not always mirror every involved entity into
    // `focusCharacters`: locations, factions and objects usually appear only in
    // the goal, scenes or required events. Search those active beat fields for
    // registered canon names so the source passages relevant to the actual action
    // still reach the writing prompt.
    let activeText = beat.map {
      ([$0.goal, $0.openingHook]
        + $0.scenes
        + $0.requiredEvents
        + [$0.endingHook, $0.setback, $0.notes])
        .joined(separator: "\n")
    } ?? ""
    let retrievalText = [activeText, narrativeText ?? ""].joined(separator: "\n")
    for name in canonNames.sorted() where retrievalText.contains(name) {
      append(name)
      if keys.count >= 6 { break }
    }
    return keys
  }

  /// Keeps semantic queries small while retaining evidence from both ends of a
  /// reviewed chapter. Lexical entity discovery still scans the full prose above.
  func boundedDerivativeRetrievalQuery(_ text: String, limit: Int = 200) -> String {
    guard limit > 1, text.count > limit else { return String(text.prefix(max(0, limit))) }
    let headCount = (limit - 1) / 2
    let tailCount = limit - 1 - headCount
    return String(text.prefix(headCount)) + "…" + String(text.suffix(tailCount))
  }

  /// Free-text side of hybrid retrieval: what the chapter is about, so the semantic
  /// half can surface a passage that never names the keys.
  private func derivativeRetrievalQuery(beat: ChapterBeat?) -> String? {
    guard let beat else { return nil }
    let parts = [beat.goal, beat.openingHook, beat.scenes.first ?? ""]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let query = parts.joined(separator: "。")
    return query.isEmpty ? nil : String(query.prefix(400))
  }

  /// Assembles the authoritative context. Files get reserved shares of the
  /// budget so the continuity index cannot silently push the story bible, hard
  /// rules and style guide out of the prompt as a book grows.
  ///
  /// Pass an already-loaded `plan` to avoid a redundant
  /// `synchronizeContinuityProjection` I/O round when the caller has already
  /// read the projection. The plan is used only for `truncateContinuityIndex`;
  /// when nil it is fetched here as before.
  func storyContext(bookID: String, maxCharacters: Int, plan existingPlan: LongFormPlanResponse? = nil) throws -> String {
    let storyURL = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    // (path, share of the total budget). Shares sum to 0.66; the continuity
    // index and volume checkpoint take the rest.
    // chapter_summaries.md gets a larger share (8 %) because it grows with
    // every chapter: the old 5 % left later chapters with no summary history.
    // story_bible.md trimmed from 12 % to 10 % to keep the total at 0.66.
    let reserved: [(path: String, share: Double)] = [
      ("book_rules.md", 0.08),
      ("story_bible.md", 0.10),
      ("protagonist.md", 0.04),
      ("outline/story_frame.md", 0.04),
      ("outline/volume_map.md", 0.06),
      ("character_matrix.md", 0.06),
      ("current_state.md", 0.05),
      ("object_ledger.md", 0.04),
      ("particle_ledger.md", 0.03),
      ("pending_hooks.md", 0.03),
      ("chapter_summaries.md", 0.08),
      ("current_focus.md", 0.02),
      ("style_guide.md", 0.04),
    ]
    // Reuse the caller's plan to avoid a redundant sync round.
    let plan = try existingPlan ?? synchronizeContinuityProjection(bookID: bookID)
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
    let continuityHead = truncateContinuityIndex(plan.continuity, maxChars: continuityAllowance)
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
    let headerPattern = "^##\\s+第\(chapterNumber)章(?:\\s|$)"
    let replacement = [
      "## 第\(chapterNumber)章 \(title)",
      summary.trimmingCharacters(in: .whitespacesAndNewlines),
      "",
    ]
    let lines = summaries.components(separatedBy: "\n")
    var rewritten: [String] = []
    var inserted = false
    var index = 0
    while index < lines.count {
      let line = lines[index]
      if line.range(of: headerPattern, options: .regularExpression) != nil {
        if !inserted {
          rewritten.append(contentsOf: replacement)
          inserted = true
        }
        index += 1
        while index < lines.count,
          lines[index].range(of: #"^##\s+"#, options: .regularExpression) == nil
        {
          index += 1
        }
        continue
      }
      rewritten.append(line)
      index += 1
    }
    if !inserted {
      while rewritten.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
        rewritten.removeLast()
      }
      rewritten.append(contentsOf: ["", "## 第\(chapterNumber)章 \(title)", replacement[1]])
    }
    summaries = rewritten.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    try atomicWrite(summaries, to: summariesURL)
  }

  func requestLLM(
    prompt: String,
    role: LLMRole,
    json: Bool = false,
    overrideModel: String? = nil,
    overrideBaseURL: String? = nil,
    overrideAPIKey: String? = nil,
    overrideTemperature: Double? = nil,
    timeout: TimeInterval = 300,
    onPartialContent: (@Sendable (String) async -> Void)? = nil
  ) async throws -> LLMResult {
    let raw = try loadRawConfig()
    // Each role reads its own model/endpoint/key triple and falls back to the
    // primary one when the role-specific value is blank, so configuring only a
    // different model name is enough.
    let keys = role.modelRole.configKeys
    let model = overrideModel?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? string(raw[keys.model]).nonEmpty
      ?? string(raw["model"], fallback: "gpt-5.6-terra")
    let configuredBase = overrideBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? string(raw[keys.baseURL]).nonEmpty
      ?? string(raw["baseUrl"])
    let baseURL = try validatedEndpoint(configuredBase, existing: raw)
    let suppliedKey = overrideAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let key = suppliedKey.nonEmpty
      ?? string(raw[keys.apiKey]).nonEmpty
      ?? string(raw["apiKey"])
    guard !key.isEmpty else {
      throw InkOSCoreError(
        "请先在设置中填写模型 API Key",
        statusCode: 400,
        origin: .requestConfiguration
      )
    }
    guard !model.isEmpty else {
      throw InkOSCoreError(
        "请先在设置中选择模型",
        statusCode: 400,
        origin: .requestConfiguration
      )
    }

    let url = try endpointURL(baseURL: baseURL, suffix: "chat/completions")
    var body: [String: Any] = [
      "model": model,
      "stream": onPartialContent != nil,
      "messages": [
        ["role": "system", "content": json ? "只输出严格 JSON，不展示推理过程。" : "按要求直接回答。"],
        ["role": "user", "content": prompt],
      ],
    ]
    // An explicit override wins over the configured value. Retries that need a
    // different sample than the one that just failed raise it — at the configured
    // 0.2 the model is near-deterministic and re-returns identical prose.
    if let overrideTemperature {
      body["temperature"] = overrideTemperature
    } else if let temperature = raw["temperature"] as? NSNumber {
      body["temperature"] = temperature.doubleValue
    }
    // `buildRequest` owns the `max_tokens` key so a retry can raise it.
    let configuredMaxTokens = integer(raw["maxTokens"]).flatMap { $0 > 0 ? $0 : nil }
    if json { body["response_format"] = ["type": "json_object"] }

    func buildRequest(maxTokens: Int?) throws -> URLRequest {
      var body = body
      if let maxTokens {
        body["max_tokens"] = maxTokens
      } else {
        body.removeValue(forKey: "max_tokens")
      }
      var request = URLRequest(url: url, timeoutInterval: timeout)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      if onPartialContent != nil {
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
      }
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      return request
    }
    let started = Date()
    // Transient upstream failures (rate limit, 5xx, network) get up to two
    // retries with backoff. Client errors (4xx) and cancellation propagate
    // immediately — retrying those only burns time.
    let maxAttempts = 3
    // Raised for the next attempt when a reasoning model spends the whole budget
    // thinking. `max_tokens` is a ceiling, not a reservation: a request that only
    // needs 10k tokens costs the same whether the ceiling is 16k or 64k, so
    // raising it on retry has no cost for prompts that were already succeeding.
    // Measured on this exact beat prompt against `deepseek-v4-flash`: the reasoning
    // pass varied between 5 347 and 16 383 tokens across identical requests, so a
    // 16 384 ceiling fails a large fraction of the time and the failure looks
    // random. Retrying at the same ceiling is what burned all three attempts on
    // chapter 1 of 《灰雾之前》.
    var budget = configuredMaxTokens
    // Set when the attempt that just failed would be fixed by a larger ceiling —
    // either no prose at all, or JSON cut off mid-object. The status code alone
    // cannot carry this: an empty completion that did not report `length` is a 502,
    // and so is a dropped connection, but only the first is fixed by more budget.
    var lastAttemptNeedsMoreBudget = false
    for attempt in 1...maxAttempts {
      let request = try buildRequest(maxTokens: budget)
      lastAttemptNeedsMoreBudget = false
      do {
        if let onPartialContent {
          let streamed = try await performLLMStreamingRequest(
            request,
            operation: "chat.completions.stream",
            onPartialContent: onPartialContent
          )
          guard !streamed.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastAttemptNeedsMoreBudget = true
            throw emptyContentError(
              model: model,
              finishReason: streamed.finishReason,
              reasoningCharacters: streamed.reasoningCharacters,
              maxTokens: budget
            )
          }
          if let error = truncatedJSONError(
            model: model,
            json: json,
            finishReason: streamed.finishReason,
            contentCharacters: streamed.content.count,
            reasoningCharacters: streamed.reasoningCharacters,
            maxTokens: budget
          ) {
            lastAttemptNeedsMoreBudget = true
            throw error
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
          lastAttemptNeedsMoreBudget = true
          throw emptyContentError(
            model: model,
            finishReason: (choices.first?["finish_reason"] as? String)?.nonEmpty,
            reasoningCharacters: extractMessageContent(message?["reasoning_content"]).count,
            maxTokens: budget
          )
        }
        if let error = truncatedJSONError(
          model: model,
          json: json,
          finishReason: (choices.first?["finish_reason"] as? String)?.nonEmpty,
          contentCharacters: content.count,
          reasoningCharacters: extractMessageContent(message?["reasoning_content"]).count,
          maxTokens: budget
        ) {
          lastAttemptNeedsMoreBudget = true
          throw error
        }
        return LLMResult(
          content: content,
          model: model,
          baseURL: baseURL,
          latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
          finishReason: (choices.first?["finish_reason"] as? String)?.nonEmpty
        )
      } catch let error as InkOSCoreError {
        // 404 (no relay channel for the configured model) is deliberately absent:
        // the model name will not start existing mid-call, so a retry reproduces it
        // at full cost.
        let transient = [429, 500, 502, 503, 504].contains(error.statusCode)
        // An attempt that produced no prose is retried at a higher ceiling. Retrying
        // at the same ceiling is close to pointless, but a higher one usually
        // succeeds, because the reasoning length varies run to run on an identical
        // prompt: measured 5 347 to 16 383 tokens on the same beat prompt. Doubling
        // here rather than telling the user to change a setting, since the same
        // prompt already succeeded at this ceiling on other attempts — the
        // configured value is not wrong, only too close to the margin.
        //
        // Keyed on emptiness rather than on the 422, because the two empty-content
        // outcomes need the same treatment and only one of them reports `length`.
        // Chapter 1 of 《灰雾之前》 failed three times with `stop` and 11k-14k
        // characters of reasoning, took the transient path, and re-ran at the
        // identical ceiling all three times.
        let raisable = lastAttemptNeedsMoreBudget && budget != nil
        guard transient || raisable, attempt < maxAttempts else { throw error }
        var raisedTo: Int? = nil
        if raisable, let current = budget {
          let raised = Swift.min(current * 2, Self.maxTokensRetryCeiling)
          // Already at the ceiling: doubling changes nothing, so stop rather than
          // spend another full reasoning pass on the identical request.
          guard raised > current else { throw error }
          budget = raised
          raisedTo = raised
        }
        let delaySeconds = attempt == 1 ? 4 : 12
        recordDebug(scope: "llm", message: "request.retry", level: "warning", data: [
          "attempt": attempt,
          "statusCode": error.statusCode,
          "error": error.localizedDescription,
          "retryAfterSeconds": delaySeconds,
          "maxTokensRaisedTo": raisedTo ?? -1,
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
    else {
      throw InkOSCoreError(
        "模型地址格式错误",
        statusCode: 400,
        origin: .requestConfiguration
      )
    }
    let allowInsecure = (existing["allowInsecureHttp"] as? Bool) == true
    let loopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    guard scheme == "https" || (scheme == "http" && (loopback || allowInsecure)) else {
      throw InkOSCoreError(
        "远程模型地址需使用 HTTPS",
        statusCode: 400,
        origin: .requestConfiguration
      )
    }
    components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    return components.string ?? text
  }

  func endpointURL(baseURL: String, suffix: String) throws -> URL {
    guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + suffix) else {
      throw InkOSCoreError(
        "模型地址格式错误",
        statusCode: 400,
        origin: .requestConfiguration
      )
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
  ) async throws -> (content: String, finishReason: String?, reasoningCharacters: Int) {
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
      // Reasoning models bill `reasoning_content` against the same `max_tokens`
      // budget as `content`. Counting it lets the caller tell "the model said
      // nothing" apart from "the model spent the whole budget thinking", which
      // are the same empty string but need opposite handling.
      var reasoningCharacters = 0
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
        reasoningCharacters += extractMessageContent(delta?["reasoning_content"]).count
          + extractMessageContent(message?["reasoning_content"]).count
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
        reasoningCharacters += extractMessageContent(message?["reasoning_content"]).count
        if let reason = choices.first?["finish_reason"] as? String, !reason.isEmpty {
          finishReason = reason
        }
      }
      if !content.isEmpty { await onPartialContent(content) }
      return (content, finishReason, reasoningCharacters)
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
    temperature: Double? = nil,
    onPartialContent: (@Sendable (String) async -> Void)? = nil
  ) async throws -> (object: [String: Any], result: LLMResult) {
    var result = try await requestLLM(
      prompt: prompt,
      role: .primary,
      json: true,
      overrideTemperature: temperature,
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
          overrideTemperature: temperature,
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
    if let object = decodedJSONObject(trimmed) { return object }
    let withoutFence = trimmed
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let object = decodedJSONObject(withoutFence) { return object }
    guard let start = withoutFence.firstIndex(of: "{"),
      let end = withoutFence.lastIndex(of: "}"),
      start < end
    else { return nil }
    return decodedJSONObject(String(withoutFence[start...end]))
  }

  /// Decodes one candidate, retrying once with raw control characters inside
  /// string values escaped. See `escapingRawControlCharacters`.
  private func decodedJSONObject(_ candidate: String) -> [String: Any]? {
    if let data = candidate.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    { return object }
    let repaired = escapingRawControlCharacters(in: candidate)
    guard repaired != candidate, let data = repaired.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Escapes control characters a model left raw inside JSON string values.
  ///
  /// `JSONSerialization` rejects any character in U+0000–U+001F appearing raw
  /// inside a string, which is exactly what a model writing long Chinese prose
  /// emits when it types a real newline instead of `\n`. The response is
  /// otherwise structurally sound, so the whole payload used to be discarded
  /// over a character that carries no meaning: chapter 23 of 《渊雨浩劫》 lost
  /// an 8 148 character draft and then its 4 152 character delta repair this
  /// way, both with `finishReason=stop` and a correctly closed shell.
  ///
  /// The scan tracks whether it sits inside a string so structural whitespace
  /// between tokens is left untouched, and rewrites only the control
  /// characters themselves — no other token is altered.
  private func escapingRawControlCharacters(in text: String) -> String {
    var output = ""
    output.reserveCapacity(text.count)
    var inString = false
    var isEscaped = false
    for character in text {
      if isEscaped {
        output.append(character)
        isEscaped = false
        continue
      }
      if character == "\\" {
        output.append(character)
        // A backslash only escapes its successor inside a string; outside one
        // it cannot legally appear, so it must not mask a structural quote.
        isEscaped = inString
        continue
      }
      if character == "\"" {
        inString.toggle()
        output.append(character)
        continue
      }
      guard inString else {
        output.append(character)
        continue
      }
      switch character {
      case "\n": output.append("\\n")
      case "\r": output.append("\\r")
      case "\t": output.append("\\t")
      default:
        if character.unicodeScalars.count == 1,
          let scalar = character.unicodeScalars.first,
          scalar.value < 0x20
        {
          output.append(String(format: "\\u%04x", scalar.value))
        } else {
          output.append(character)
        }
      }
    }
    return output
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

  /// Separates an empty completion worth retrying from one that is deterministic.
  ///
  /// A reasoning model bills `reasoning_content` against the same `max_tokens`
  /// budget as `content`. When thinking exhausts the budget the relay still
  /// answers 200, carrying `finish_reason: "length"` and an empty `content`.
  /// Retrying spends the same budget on the same prompt and fails identically:
  /// chapter 27 of 《渊雨浩劫》 burned three rounds that way at roughly two
  /// minutes of upstream thinking each, and `deepseek-v4-flash` measured 16381
  /// of 16384 tokens spent on reasoning with zero characters of prose. So a
  /// truncated empty response is reported as a configuration fault that names
  /// the fix, not as a transient upstream failure.
  /// Rejects a JSON answer that stopped at the token ceiling, so the retry can raise
  /// the ceiling instead of handing the caller an unusable fragment.
  ///
  /// Only for `json: true`. Truncated prose is still worth something — the chapter
  /// pipeline reviews and revises it — but truncated JSON cannot be parsed at all, so
  /// returning it makes every caller re-derive "this was cut off" from a failed parse.
  /// The beat planner did exactly that: it read `finishReason == "length"` and halved
  /// its chapter range, which shrinks the *answer* when the fault was that the
  /// reasoning pass had already spent the budget. Chapter 1 of 《灰雾之前》 halved
  /// 1-10 to 1-5 to 1-3, paying a full reasoning pass each time, while every attempt
  /// wrote barely 1-3k characters before hitting the same ceiling.
  private func truncatedJSONError(
    model: String,
    json: Bool,
    finishReason: String?,
    contentCharacters: Int,
    reasoningCharacters: Int,
    maxTokens: Int?
  ) -> InkOSCoreError? {
    guard json, finishReason == "length" else { return nil }
    recordDebug(scope: "llm", message: "response.truncated_json", level: "warning", data: [
      "model": model,
      "contentCharacters": contentCharacters,
      "reasoningCharacters": reasoningCharacters,
      "maxTokens": maxTokens ?? -1,
    ])
    var message = "模型 \(model) 的 JSON 输出在 max_tokens"
    if let maxTokens { message += "（\(maxTokens)）" }
    message += " 处被截断（已写 \(contentCharacters) 字符"
    if reasoningCharacters > 0 { message += "，推理另占 \(reasoningCharacters) 字符" }
    message += "）。"
    message += reasoningCharacters > 0
      ? "该模型是推理模型，reasoning_content 与正文共用同一预算；请在设置中调大「最大 token」，或改用非推理模型。"
      : "请在设置中调大「最大 token」。"
    return InkOSCoreError(message, statusCode: 422)
  }

  private func emptyContentError(
    model: String,
    finishReason: String?,
    reasoningCharacters: Int,
    maxTokens: Int?
  ) -> InkOSCoreError {
    let detail = reasoningCharacters > 0
      ? "，推理过程占用了 \(reasoningCharacters) 字符"
      : ""
    // `finishReason` decides which of two very different faults this is, and the
    // message alone does not carry it: chapter 1 of 《灰雾之前》 failed three times
    // with 11k-14k characters of reasoning, which reads like budget exhaustion but
    // was reported as transient, and there was no way to tell from the log whether
    // the relay had said "length", said "stop", or ended the stream without saying
    // anything. Record the raw fields so the next occurrence is classifiable.
    recordDebug(scope: "llm", message: "response.empty_content", level: "warning", data: [
      "model": model,
      "finishReason": finishReason ?? "(none)",
      "reasoningCharacters": reasoningCharacters,
      "maxTokens": maxTokens ?? -1,
    ])
    guard finishReason == "length" else {
      return InkOSCoreError("模型返回了空内容\(detail)", statusCode: 502)
    }
    var message = "模型 \(model) 没有产出正文\(detail)，输出在 max_tokens"
    if let maxTokens { message += "（\(maxTokens)）" }
    message += " 处被截断。"
    message += reasoningCharacters > 0
      ? "该模型是推理模型，reasoning_content 与正文共用同一预算；请在设置中调大「最大 token」，或改用非推理模型。"
      : "请在设置中调大「最大 token」。"
    // 422 keeps this out of the transient retry set below: the outcome is fixed
    // by the prompt and the budget, so a second attempt only burns time.
    return InkOSCoreError(message, statusCode: 422)
  }

  private func remoteError(data: Data, status: Int, prefix: String) throws -> InkOSCoreError {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let nested = object?["error"] as? [String: Any]
    let message = string(nested?["message"], fallback: string(object?["message"], fallback: "HTTP \(status)"))
    // A relay that has no channel for the configured model name answers 503,
    // which otherwise lands in the transient retry set and costs three attempts
    // plus backoff before surfacing. The model name will not appear mid-call,
    // so report it as a settings fault immediately. Chapter 27 of 《渊雨浩劫》
    // spent its rounds this way after the model was switched to a name the
    // relay does not carry.
    let code = string(nested?["code"], fallback: "")
    let unavailableModel = code == "model_not_found"
      || message.contains("No available channel")
      || message.contains("无可用渠道")
    if unavailableModel {
      return InkOSCoreError(
        "\(prefix)：中转站没有可用于该模型的渠道。请在设置中改用中转站实际提供的模型。原始信息：\(message)",
        statusCode: 404,
        origin: .remoteResponse
      )
    }
    return InkOSCoreError(
      "\(prefix)：\(message)",
      statusCode: status,
      origin: .remoteResponse
    )
  }

  private func secretPreview(_ value: String) -> String {
    guard value.count > 8 else { return value.isEmpty ? "" : "••••" }
    return "\(value.prefix(4))••••\(value.suffix(4))"
  }

  /// Flat `ID | type | name` roster of every canon entity. Deliberately not
  /// truncated: it is small (one short line per entity) and dropping the tail
  /// would hide exactly the recently-introduced entities the next chapter is
  /// most likely to register.
  func entityIDRegistryText(bookID: String) throws -> String {
    entityIDRegistryText(try synchronizeContinuityProjection(bookID: bookID).continuity)
  }

  func entityIDRegistryText(_ continuity: LongFormContinuity) -> String {
    guard !continuity.entities.isEmpty else { return "（正典中暂无实体，本章所有实体都是新实体）" }
    let rows = continuity.entities
      .map { "\($0.id) | \($0.type) | \($0.name)" }
      .joined(separator: "\n")
    return rows + "\n（以上 ID 均已占用；新实体必须使用不在此列表中的新 ID）"
  }

  /// Flat `hookId | openFromChapter | description` roster of every unresolved hook
  /// in the current projection. Given alongside the delta repair and revision
  /// prompts so the model can look up exact IDs instead of guessing variants like
  /// HOOK-CH23-先过江, HOOK-023-先过江, etc.
  func openHooksRegistryText(bookID: String) throws -> String {
    openHooksRegistryText(try synchronizeContinuityProjection(bookID: bookID).continuity)
  }

  func openHooksRegistryText(_ continuity: LongFormContinuity) -> String {
    guard !continuity.hooks.isEmpty else { return "（当前无未关闭伏笔）" }
    // All hooks in the projection are unresolved. Closed hooks are removed from
    // the canon via remove.hooks and never appear here.
    let rows = continuity.hooks.map {
      "\($0.hookId) | 第\($0.openFromChapter)章 | \($0.description.prefix(80))"
    }.joined(separator: "\n")
    return rows + "\n（remove.hooks 中只能使用以上 hookId；不存在的 ID 会触发校验错误）"
  }

  /// Truncate continuity index by structure rather than raw character count.
  /// The full JSON is often too large to fit, but slicing mid-string leaves
  /// malformed JSON and hides the tail of the timeline. This keeps complete
  /// entries, prioritizes recent timeline milestones, and adds a summary hint
  /// when timeline is truncated so the model knows what order values are taken.
  func truncateContinuityIndex(
    _ continuity: LongFormContinuity,
    maxChars: Int
  ) -> String {
    let limit = Swift.max(2, maxChars)
    if let data = try? encoder.encode(continuity),
      let full = String(data: data, encoding: .utf8),
      full.count <= limit
    {
      return full
    }
    let keys = [
      "immutableCanon", "worldRules", "entities",
      "knowledgeBoundaries", "timeline", "hooks",
    ]
    let originalCounts: [String: Int] = [
      "immutableCanon": continuity.immutableCanon.count,
      "worldRules": continuity.worldRules.count,
      "entities": continuity.entities.count,
      "knowledgeBoundaries": continuity.knowledgeBoundaries.count,
      "timeline": continuity.timeline.count,
      "hooks": continuity.hooks.count,
    ]
    var arrays = Dictionary(uniqueKeysWithValues: keys.map { ($0, [[String: Any]]()) })
    var omitted = originalCounts
    var clippedFields = 0

    func clip(_ value: String, to maximum: Int) -> String {
      let singleLine = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard singleLine.count > maximum else { return singleLine }
      clippedFields += 1
      return String(singleLine.prefix(Swift.max(1, maximum - 1))) + "…"
    }

    let policy: [String: Any] = [
      "requireContinuousVolumes": continuity.policy.requireContinuousVolumes,
      "allowUnplannedEntities": continuity.policy.allowUnplannedEntities,
      "requireConsistencyDelta": continuity.policy.requireConsistencyDelta,
      "checkpointAtVolumeEnd": continuity.policy.checkpointAtVolumeEnd,
    ]

    func document() -> [String: Any] {
      let omittedCounts = Dictionary(uniqueKeysWithValues: keys.map { ($0, omitted[$0] ?? 0) })
      var value: [String: Any] = [
        "policy": policy,
        "_truncation": [
          "truncated": omittedCounts.values.contains(where: { $0 > 0 }) || clippedFields > 0,
          "omittedCounts": omittedCounts,
          "clippedFields": clippedFields,
          "note": "条目按完整 JSON 对象保留；实体优先，伏笔按到期顺序，时间线保留最近事件。",
        ] as [String: Any],
      ]
      for key in keys { value[key] = arrays[key] ?? [] }
      return value
    }

    func encodeDocument() -> String {
      guard JSONSerialization.isValidJSONObject(document()),
        let data = try? JSONSerialization.data(
          withJSONObject: document(),
          options: [.sortedKeys, .withoutEscapingSlashes]
        ),
        let text = String(data: data, encoding: .utf8)
      else { return "{}" }
      return text
    }

    func append(_ item: [String: Any], to key: String) {
      arrays[key, default: []].append(item)
      omitted[key, default: 0] = Swift.max(0, omitted[key, default: 0] - 1)
      if encodeDocument().count > limit {
        arrays[key]?.removeLast()
        omitted[key, default: 0] += 1
      }
    }

    // IDs, names and types are the minimum identity contract. Current mutable
    // state is retained in small bounded fields when it fits.
    for entity in continuity.entities.sorted(by: { $0.id < $1.id }) {
      var item: [String: Any] = [
        "id": entity.id,
        "name": clip(entity.name, to: 100),
        "type": entity.type,
      ]
      if let owner = entity.owner { item["owner"] = clip(owner, to: 80) }
      if let location = entity.location { item["location"] = clip(location, to: 80) }
      if !entity.attributes.isEmpty {
        item["attributes"] = Dictionary(uniqueKeysWithValues: entity.attributes.keys.sorted().map {
          ($0, clip(entity.attributes[$0] ?? "", to: 120))
        })
      }
      if entity.immutableOwner { item["immutableOwner"] = true }
      if entity.immutableLocation { item["immutableLocation"] = true }
      if !entity.immutableAttributes.isEmpty {
        item["immutableAttributes"] = entity.immutableAttributes
      }
      append(item, to: "entities")
    }

    let hooks = continuity.hooks.sorted {
      let leftDue = $0.resolveByChapter ?? Int.max
      let rightDue = $1.resolveByChapter ?? Int.max
      if leftDue != rightDue { return leftDue < rightDue }
      if $0.openFromChapter != $1.openFromChapter { return $0.openFromChapter > $1.openFromChapter }
      return $0.hookId < $1.hookId
    }
    for hook in hooks {
      var item: [String: Any] = [
        "hookId": hook.hookId,
        "description": clip(hook.description, to: 220),
        "openFromChapter": hook.openFromChapter,
      ]
      if let value = hook.resolveByChapter { item["resolveByChapter"] = value }
      if let value = hook.requiredVolumeNumber { item["requiredVolumeNumber"] = value }
      append(item, to: "hooks")
    }

    for milestone in continuity.timeline.sorted(by: { $0.order > $1.order }) {
      var item: [String: Any] = [
        "id": milestone.id,
        "order": milestone.order,
        "label": clip(milestone.label, to: 220),
        "earliestChapter": milestone.earliestChapter,
        "latestChapter": milestone.latestChapter,
        "immutable": milestone.immutable,
      ]
      if let value = milestone.sourceDay { item["sourceDay"] = value }
      if let value = milestone.sourceChapter { item["sourceChapter"] = value }
      append(item, to: "timeline")
    }

    for boundary in continuity.knowledgeBoundaries.sorted(by: { $0.factId < $1.factId }) {
      var item: [String: Any] = [
        "factId": boundary.factId,
        "statement": clip(boundary.statement, to: 220),
        "allowedKnowers": boundary.allowedKnowers,
        "forbiddenKnowers": boundary.forbiddenKnowers,
        "availableFromChapter": boundary.availableFromChapter,
      ]
      if let value = boundary.revealByChapter { item["revealByChapter"] = value }
      if !boundary.markers.isEmpty { item["markers"] = boundary.markers }
      append(item, to: "knowledgeBoundaries")
    }

    for rule in continuity.worldRules.sorted(by: { $0.id < $1.id }) {
      append([
        "id": rule.id,
        "statement": clip(rule.statement, to: 240),
        "immutable": rule.immutable,
      ], to: "worldRules")
    }
    for canon in continuity.immutableCanon.sorted(by: { $0.id < $1.id }) {
      var item: [String: Any] = [
        "id": canon.id,
        "category": canon.category,
        "statement": clip(canon.statement, to: 240),
      ]
      if let value = canon.value { item["value"] = clip(value, to: 120) }
      if !canon.aliases.isEmpty { item["aliases"] = canon.aliases }
      append(item, to: "immutableCanon")
    }

    let encoded = encodeDocument()
    if encoded.count <= limit { return encoded }
    // `storyContext` grants at least 2,000 characters, so this is only reachable
    // from a direct diagnostic call with an extremely small budget. Keep the
    // contract that every return value is complete JSON even then.
    let minimal = "{\"_truncation\":{\"truncated\":true}}"
    return minimal.count <= limit ? minimal : "{}"
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
