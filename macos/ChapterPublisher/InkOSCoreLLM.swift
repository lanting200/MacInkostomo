import Foundation

extension InkOSCore {
  struct LLMResult: Sendable {
    let content: String
    let model: String
    let baseURL: String
    let latencyMilliseconds: Int
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
      let result = try await requestLLM(
        prompt: prompt,
        role: .primary,
        json: true,
        timeout: 600,
        onPartialContent: { [weak self] partial in
          await self?.updateGenerationLiveText(key: key, rawText: partial)
        }
      )
      let parsed = parseJSONObject(result.content) ?? [:]
      let currentPlan = try synchronizeContinuityProjection(bookID: bookID)
      let suppliedDelta = parsed["consistencyDelta"] as? [String: Any]
      if currentPlan.continuity.policy.requireConsistencyDelta, suppliedDelta == nil {
        throw InkOSCoreError("模型未返回 consistencyDelta", statusCode: 422)
      }
      let rawDelta = suppliedDelta ?? [:]
      let candidateDelta = try normalizedConsistencyDelta(rawDelta, chapterNumber: chapterNumber)
      let title = normalizedChapterTitle(
        string(parsed["title"], fallback: "第\(chapterNumber)章"),
        chapterNumber: chapterNumber
      )
      var content = string(parsed["content"])
      if content.isEmpty { content = result.content }
      content = stripChapterHeading(content)
      try validateChapterLength(
        content,
        chapterNumber: chapterNumber,
        minWords: plan.plan.chapters.first { $0.number == chapterNumber }?.minWords
          ?? plan.constraints.targetChapterWords,
        maxWords: plan.plan.chapters.first { $0.number == chapterNumber }?.maxWords
          ?? plan.constraints.targetChapterWords,
        label: "章节正文"
      )

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
      let reviewObject: [String: Any] = [
        "status": review.pass ? "passed" : "failed",
        "model": review.model,
        "summary": review.summary,
        "issues": review.issues,
        "craftAdvisories": review.advisories,
        "revisionGuidance": review.revisionGuidance,
        "reviewedAt": isoTimestamp(),
      ]
      let status = review.pass ? "pending_review" : "revision_failed"
      try writeChapter(bookID: bookID, number: chapterNumber, title: title, content: content, status: status, llmReview: reviewObject)
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
        phase: review.pass ? "ready-for-review" : "revision_failed",
        message: review.pass ? "章节已交付人工审核" : "一致性审核发现问题",
        startedAt: startedAt,
        finishedAt: finished,
        error: review.pass ? nil : review.issues.joined(separator: "；"),
        liveText: generationJobs[key]?.liveText
      )
      recordDebug(scope: "generation", message: "chapter.completed", data: [
        "bookId": bookID,
        "chapterNumber": chapterNumber,
        "status": status,
        "model": result.model,
      ])
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

  private func performRevision(
    bookID: String,
    chapter: ChapterDetail,
    note: String,
    mode: String,
    startedAt: String
  ) async {
    let key = generationKey(bookID, chapter.number)
    do {
      let plan = try synchronizeContinuityProjection(bookID: bookID)
      let beat = try chapterBeat(bookID: bookID, chapterNumber: chapter.number)
      let chapterPlan = plan.plan.chapters.first { $0.number == chapter.number }
      let minWords = chapterPlan?.minWords ?? plan.constraints.targetChapterWords
      let maxWords = chapterPlan?.maxWords ?? plan.constraints.targetChapterWords
      let craft = try craftDirectives(bookID: bookID, chapterNumber: chapter.number)
      let context = try storyContext(bookID: bookID, maxCharacters: 60_000)
      let beatSection = beat.map(beatBriefText)
        ?? "（本章没有节拍卡，按既有正文范围修订，不要扩大本章承载的剧情量）"
      let prompt = """
        你是 InkOS 章节修订器。请依据修改意见修订完整正文，保持既有设定、人物知识边界、持久物品和前后章因果。
        修订后正文字数必须落在 \(minWords) 至 \(maxWords) 字之间。
        修订只在本章节拍卡范围内进行：不得引入节拍卡禁止清单中的内容，不得把后续章节的剧情提前到本章。
        consistencyDelta 必须完整描述修订后本章的新贡献；旧版本仅由本章产生的记录会自动退出。新增或更新写入 upsert；remove 只用于正文事件明确终止的既有跨章记录。
        只输出 JSON：{"title":"章节标题","content":"完整正文","summary":"修订摘要","consistencyDelta":{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}}。
        修订模式：\(mode)
        修改意见：\(note)

        \(craft)

        【本章节拍卡】
        \(beatSection)

        【全书约束与状态】
        \(context)

        【原章节】
        第\(chapter.number)章 \(chapter.title)
        \(chapter.content)
        """
      let result = try await requestLLM(
        prompt: prompt,
        role: .primary,
        json: true,
        timeout: 600,
        onPartialContent: { [weak self] partial in
          await self?.updateGenerationLiveText(key: key, rawText: partial)
        }
      )
      let parsed = parseJSONObject(result.content) ?? [:]
      let refreshedPlan = try synchronizeContinuityProjection(bookID: bookID)
      let suppliedDelta = parsed["consistencyDelta"] as? [String: Any]
      if refreshedPlan.continuity.policy.requireConsistencyDelta, suppliedDelta == nil {
        throw InkOSCoreError("模型未返回 consistencyDelta", statusCode: 422)
      }
      let rawDelta = suppliedDelta ?? [:]
      let candidateDelta = try normalizedConsistencyDelta(rawDelta, chapterNumber: chapter.number)
      let title = normalizedChapterTitle(
        string(parsed["title"], fallback: chapter.title),
        chapterNumber: chapter.number
      )
      let content = stripChapterHeading(string(parsed["content"], fallback: result.content))
      try validateChapterLength(
        content,
        chapterNumber: chapter.number,
        minWords: minWords,
        maxWords: maxWords,
        label: "修订正文"
      )
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: title,
        phase: "reviewing",
        message: "正在执行修订后一致性审核",
        startedAt: startedAt,
        liveText: generationJobs[key]?.liveText
      )
      recordDebug(scope: "generation", message: "chapter.phase", data: [
        "bookId": bookID, "chapterNumber": chapter.number, "phase": "reviewing",
      ])
      let review = try await reviewChapter(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: title,
        content: content,
        candidateDelta: candidateDelta,
        beat: beat,
        excludingChapter: chapter.number
      )
      let reviewObject: [String: Any] = [
        "status": review.pass ? "passed" : "failed",
        "model": review.model,
        "summary": review.summary,
        "issues": review.issues,
        "craftAdvisories": review.advisories,
        "revisionGuidance": review.revisionGuidance,
        "reviewedAt": isoTimestamp(),
      ]
      try writeChapter(
        bookID: bookID,
        number: chapter.number,
        title: title,
        content: content,
        status: review.pass ? "pending_review" : "revision_failed",
        llmReview: reviewObject
      )
      try persistConsistencyDelta(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: title,
        summary: string(parsed["summary"], fallback: review.summary),
        delta: rawDelta
      )
      try updateStateChapter(bookID: bookID, number: chapter.number) { record in
        var history = record["revisionHistory"] as? [[String: Any]] ?? []
        history.append([
          "time": isoTimestamp(),
          "note": note,
          "type": mode,
          "oldContentLength": proseCount(chapter.content),
          "newContentLength": proseCount(content),
          "success": review.pass,
          "reviseMode": mode,
        ])
        record["revisionHistory"] = history
      }
      _ = try synchronizeContinuityProjection(bookID: bookID)
      // Later beats were planned against the previous version of this chapter,
      // so they must be re-planned once its text changed. This is cache
      // cleanup: the revision itself is already persisted, so a failure here
      // must not report the revision as failed.
      do {
        _ = try await invalidateChapterBeats(bookID: bookID, fromChapter: chapter.number + 1)
      } catch {
        recordDebug(
          scope: "craft", message: "chapter_beats.invalidate_failed", level: "error",
          data: [
            "bookId": bookID,
            "fromChapter": chapter.number + 1,
            "error": error.localizedDescription,
          ])
      }
      let finished = isoTimestamp()
      generationJobs[key] = try makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: title,
        phase: review.pass ? "ready-for-review" : "revision_failed",
        message: review.pass ? "修订完成，等待人工审核" : "修订后仍有一致性问题",
        startedAt: startedAt,
        finishedAt: finished,
        error: review.pass ? nil : review.issues.joined(separator: "；"),
        liveText: generationJobs[key]?.liveText
      )
    } catch {
      generationJobs[key] = try? makeGenerationJob(
        bookID: bookID,
        chapterNumber: chapter.number,
        title: chapter.title,
        phase: "error",
        message: "章节修订失败",
        startedAt: startedAt,
        finishedAt: isoTimestamp(),
        error: error.localizedDescription,
        liveText: generationJobs[key]?.liveText
      )
    }
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
  private func reviewChapter(
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
    let chapterPlan = plan.plan.chapters.first { $0.number == chapterNumber }
    let minWords = chapterPlan?.minWords ?? plan.constraints.targetChapterWords
    let maxWords = chapterPlan?.maxWords ?? plan.constraints.targetChapterWords
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
      当 allowUnplannedEntities=false 时，正文不得引入审核前索引中不存在的人物、物品、地点、组织或概念。
      节拍卡的禁止清单等同硬约束：正文若出现被本章明令推迟的剧情、人物、物品、能力或结局，记为 hard。
      正文字数必须在 \(minWords) 至 \(maxWords) 字之间，超出记为 hard。
      以上任一问题输出前缀 [hard]。

      第二类：写法质量（不阻断）。依据下方写法内核与本书写法约束检查：
      是否有用总结代替关键场景，是否跳过了本该写出的冲突过程；开场是否为背景综述或履历介绍；是否用清单、备忘录、条目化盘点承担叙事；对话是否承载了关键分歧和转折；本章必需事件和挫折是否真的在场景里发生；视角是否统一；章末是否落在钩子上而非总结。
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
    let result = try await requestLLM(prompt: prompt, role: .review, json: true, timeout: 300)
    let object = parseJSONObject(result.content) ?? [:]
    let allIssues = (object["issues"] as? [Any] ?? []).compactMap(reviewIssueText)
    let blocking = allIssues.filter(isBlockingIssue)
    let advisories = allIssues.filter { !isBlockingIssue($0) }
    let requestedPass = (object["pass"] as? Bool) ?? false
    if !advisories.isEmpty {
      recordDebug(scope: "review", message: "chapter.craft_advisories", data: [
        "bookId": bookID, "chapterNumber": chapterNumber, "count": advisories.count,
      ])
    }
    return NativeReview(
      pass: blocking.isEmpty && (requestedPass || advisories.count == allIssues.count),
      model: result.model,
      summary: string(object["summary"], fallback: "审核完成"),
      issues: blocking,
      revisionGuidance: string(object["revisionGuidance"]),
      advisories: advisories
    )
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
    let chapterPlan = plan.plan.chapters.first(where: { $0.number == chapterNumber })
    let targetWords = chapterPlan?.targetWords ?? 3_000
    let minWords = chapterPlan?.minWords ?? targetWords
    let maxWords = chapterPlan?.maxWords ?? targetWords
    let volume = chapterPlan?.volumeNumber ?? 1
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
      正文字数必须落在 \(minWords) 至 \(maxWords) 字之间，目标 \(targetWords) 字。严格遵守权威设定、分卷目标、时间线、人物知识边界、持久物品与特殊约束。
      当前分卷：第\(volume)卷（第\(volumePlan?.startChapter ?? chapterNumber)-\(volumePlan?.endChapter ?? chapterNumber)章）。
      \(volumePolicy)
      \(entityPolicy)
      \(checkpointPolicy)
      本章的写作范围由下面的节拍卡界定：只写节拍卡安排的内容，节拍卡列为禁止提前出现的内容一律不得发生。宁可把一个问题写透，也不要多推进剧情。
      consistencyDelta 必须记录本章新增、更新或删除的事实；新增随机设定必须登记，并与既有事实兼容。
      只输出 JSON：{"title":"章节标题","content":"完整正文","summary":"章节摘要","consistencyDelta":{"upsert":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}}。
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
    // (path, share of the total budget). Shares sum to 0.62; the continuity
    // index and volume checkpoint take the rest.
    let reserved: [(path: String, share: Double)] = [
      ("book_rules.md", 0.08),
      ("story_bible.md", 0.12),
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
    if let onPartialContent {
      let content = try await performLLMStreamingRequest(
        request,
        operation: "chat.completions.stream",
        onPartialContent: onPartialContent
      )
      guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw InkOSCoreError("模型返回了空内容", statusCode: 502)
      }
      return LLMResult(
        content: content,
        model: model,
        baseURL: baseURL,
        latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
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
      latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
    )
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
  ) async throws -> String {
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
      }
      if !content.isEmpty { await onPartialContent(content) }
      return content
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
    guard let marker = rawText.range(
      of: #""content"\s*:\s*""#,
      options: .regularExpression
    ) else { return "" }
    let characters = Array(rawText[marker.upperBound...])
    var output = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\"" { break }
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
    return output
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
