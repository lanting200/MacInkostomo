import Foundation

extension InkOSCore {
  // MARK: - Guided creation

  func generateFanqieAbstract(
    bookID: String,
    source rawSource: String,
    protagonistNames: [String]
  ) async throws -> String {
    let book = try stateBookObject(bookID: bookID)
    let title = string(book["title"], fallback: bookID)
    let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else {
      throw InkOSCoreError("请先填写或选择可用于浓缩的原始简介", statusCode: 400)
    }

    let bible = (try? await fetchBookSetting(bookID: bookID, path: "story_bible.md")) ?? ""
    let names = protagonistNames
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "、")
    let prompt = """
    你是头部网文平台的资深责编和投放文案。目标不是完整概括全书，而是让目标读者读完后立刻想点开第一章。
    硬性要求：
    1. 输出 80 至 120 个中文字符，标点计入字数；最终必须在 50 至 500 字范围内。
    2. 开头一句立即亮出主角身份与最强反差、危机或异常处境，不从世界背景慢慢介绍。
    3. 只突出最有辨识度的核心卖点，写清主角要做什么、阻力是什么，以及读者能期待的成长、逆转或爽点。
    4. 结尾留下具体且与主线相关的悬念或更大代价，形成继续阅读的钩子，但不剧透最终答案。
    5. 多用短句和有行动感的动词；避免人物名单、设定堆砌，以及“命运齿轮转动”“一场阴谋悄然展开”等空泛套话。
    6. 使用单段纯文本，不要标题、书名号、引号、Markdown、标签、解释或字数说明。
    7. 所有吸引点必须来自素材，不添加冲突的人物、能力、世界规则和剧情事实。

    作品名：\(title)
    主角：\(names.isEmpty ? "请从素材中识别" : names)
    原始简介：
    \(String(source.prefix(4_000)))

    设定参考：
    \(String(bible.prefix(6_000)))
    """
    let result = try await requestLLM(prompt: prompt, role: .review, timeout: 180)
    let abstract = try normalizedFanqieAbstract(result.content)
    recordDebug(scope: "fanqie", message: "fanqie.abstract.generated", data: [
      "bookId": bookID,
      "characters": abstract.count,
      "model": result.model,
      "latencyMs": result.latencyMilliseconds,
    ])
    return abstract
  }

  func assistCreateBook(guide rawGuide: CreateBookGuide) async throws -> CreateBookAssistResponse {
    let guide = try validatedGuide(rawGuide)
    let prompt = createBookPrompt(guide)
    let result = try await requestLLM(prompt: prompt, role: .review, json: true, timeout: 300)
    let generated = parseJSONObject(result.content) ?? [:]
    let effectiveConstraints = effectiveCreationConstraints(guide.specialConstraints)

    let protagonist = "\(guide.protagonistName)：\(guide.protagonistProfile)"
    var payload: [String: Any] = [
      "title": guide.title,
      "language": guide.language,
      "genre": guide.genre,
      "platform": guide.platform,
      "targetChapters": guide.targetChapters,
      "chapterWords": guide.targetChapterWords,
      "targetChapterWords": guide.targetChapterWords,
      "targetTotalWords": guide.targetTotalWords,
      "totalWords": String(guide.targetTotalWords),
      "volumeCount": guide.volumeCount,
      "chapterWordTolerance": guide.chapterWordTolerance,
      "premise": lockedText(label: "剧情概述", confirmed: guide.storyPremise, generated: string(generated["premise"])),
      "characters": lockedText(label: "主角", confirmed: protagonist, generated: string(generated["characters"])),
      "protagonistProfile": string(
        generated["protagonistProfile"],
        fallback: "\(guide.protagonistName)：\(guide.protagonistProfile)"
      ),
      // LLM 生成的主角性格未经人工确认前不得创建书籍。
      "protagonistReviewed": false,
      "worldbuilding": lockedText(
        label: "世界规则与边界",
        confirmed: guide.worldRules,
        generated: string(
          generated["worldbuilding"],
          fallback: "围绕用户确认的故事构想建立明确的社会规则、能力边界、资源代价和信息边界。"
        )
      ),
      "outline": lockedText(label: "主线方向", confirmed: guide.storyPremise, generated: string(generated["outline"])),
      "volumePlan": string(generated["volumePlan"]),
      "pacing": lockedText(
        label: "开篇与节奏要求",
        confirmed: guide.pacing,
        generated: string(generated["pacing"], fallback: "开篇建立人物目标和核心冲突，每卷完成阶段目标并回收关键伏笔。")
      ),
      "style": string(
        generated["style"],
        fallback: guide.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "语言清晰，人物行动推动剧情，保持稳定叙事视角。"
          : guide.style
      ),
      "constraints": effectiveConstraints.joined(separator: "\n"),
      "specialConstraints": effectiveConstraints,
      // Carried from the guide, not generated: these come from the customer's own
      // answers, and the returned payload is what `createBook` later persists. Left
      // out, a book the customer marked 同人 would be created as 自创 and silently
      // lose every canon and timeline constraint.
      "kind": guide.kind.rawValue,
      "sourceTitle": guide.sourceTitle,
      "timelineAnchorLabel": guide.timelineAnchorLabel,
      "timelineStartDayOffset": guide.timelineStartDayOffset,
      "timelineStartDateLabel": guide.timelineStartDateLabel,
      "creationGuide": try encodedObject(guide),
    ]
    if string(payload["volumePlan"]).isEmpty {
      payload["volumePlan"] = defaultVolumePlan(chapters: guide.targetChapters, volumes: guide.volumeCount)
    }
    let request = try decodeObject(payload, as: CreateBookRequest.self)
    recordDebug(scope: "creation", message: "book.assist.completed", data: [
      "title": guide.title,
      "model": result.model,
      "targetTotalWords": guide.targetTotalWords,
    ])
    return CreateBookAssistResponse(
      ok: true,
      model: result.model,
      baseUrl: result.baseURL,
      guide: guide,
      payload: request
    )
  }

  func createBook(_ rawInput: CreateBookRequest) async throws -> CreateBookResponse {
    var input = rawInput
    input.synchronizeLongFormFields()
    let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw InkOSCoreError("请填写书名", statusCode: 400) }
    input.timelineAnchorLabel = input.timelineAnchorLabel.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if input.kind == .derivative, input.timelineAnchorLabel.isEmpty {
      throw InkOSCoreError("同人小说必须填写原著时间锚点", statusCode: 400)
    }
    let constraints = try validatedConstraints(
      LongFormConstraints(
        targetTotalWords: input.targetTotalWords,
        volumeCount: input.volumeCount,
        targetChapterWords: input.chapterWords,
        chapterWordTolerance: input.chapterWordTolerance,
        specialConstraints: LongFormConstraints.lines(from: input.constraints)
      ),
      requireSpecialConstraints: true
    )
    let bookID = sanitizeBookID(title)
    let bookURL = try safeBookURL(bookID)
    guard !fileManager.fileExists(atPath: bookURL.path) else {
      throw InkOSCoreError("同名小说已经存在", statusCode: 409)
    }
    // The protagonist profile is injected into every chapter prompt, so a
    // machine-written personality must never reach generation unreviewed.
    guard input.protagonistReviewed else {
      throw InkOSCoreError("请先审核并确认主角性格，再创建小说", statusCode: 400)
    }
    guard input.protagonistProfile.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
      throw InkOSCoreError("主角性格档案过短（至少 20 字），请在创建页补充后再创建", statusCode: 400)
    }

    let jobID = UUID().uuidString
    let now = isoTimestamp()
    creationJobs[jobID] = CreationJob(
      jobId: jobID,
      status: "running",
      title: title,
      bookId: bookID,
      args: nil,
      createdAt: now,
      updatedAt: now,
      finishedAt: nil,
      error: nil,
      stdout: nil,
      stderr: nil
    )

    do {
      try createBookFiles(bookID: bookID, input: input, constraints: constraints)
      try mutateState { state in
        var books = state["books"] as? [String: Any] ?? [:]
        books[bookID] = [
          "title": title,
          "chapters": [],
          "createdAt": now,
          "updatedAt": now,
          "creation": ["success": true, "payload": try encodedObject(input)],
          "inkos": [
            "bookId": bookID,
            "genre": input.genre,
            "platform": input.platform,
            "targetChapters": input.derivedTargetChapters,
            "chapterWordCount": input.chapterWords,
          ],
        ]
        state["books"] = books
      }
      creationJobs[jobID] = CreationJob(
        jobId: jobID,
        status: "success",
        title: title,
        bookId: bookID,
        args: nil,
        createdAt: now,
        updatedAt: isoTimestamp(),
        finishedAt: isoTimestamp(),
        error: nil,
        stdout: "原生 InkOSCore 已创建小说工程",
        stderr: ""
      )
      recordDebug(scope: "creation", message: "book.created", data: [
        "bookId": bookID,
        "targetTotalWords": constraints.targetTotalWords,
        "volumeCount": constraints.volumeCount,
      ])
    } catch {
      try? fileManager.removeItem(at: bookURL)
      creationJobs[jobID] = CreationJob(
        jobId: jobID,
        status: "failed",
        title: title,
        bookId: bookID,
        args: nil,
        createdAt: now,
        updatedAt: isoTimestamp(),
        finishedAt: isoTimestamp(),
        error: error.localizedDescription,
        stdout: "",
        stderr: error.localizedDescription
      )
      throw error
    }

    return CreateBookResponse(
      message: "原生 InkOSCore 已创建小说",
      status: "success",
      jobId: jobID,
      title: title,
      bookId: bookID
    )
  }

  // MARK: - Long-form planning

  func fetchLongFormPlan(bookID: String) async throws -> LongFormPlanResponse {
    try synchronizeContinuityProjection(bookID: bookID)
  }

  func updateLongFormPlan(
    bookID: String,
    expectedRevision: Int?,
    constraints: LongFormConstraints? = nil,
    continuity: LongFormContinuity? = nil
  ) async throws -> LongFormPlanResponse {
    let current = try await fetchLongFormPlan(bookID: bookID)
    if let expectedRevision, expectedRevision != current.revision {
      throw InkOSCoreError("长篇规划已被其他操作更新，请刷新后重试", statusCode: 409)
    }
    let nextConstraints = try validatedConstraints(constraints ?? current.constraints)
    let targetChapters = max(1, Int((Double(nextConstraints.targetTotalWords) / Double(nextConstraints.targetChapterWords)).rounded()))
    let manualProjection = try continuity.map {
      try continuityProjectionForManualEdit(
        bookID: bookID,
        current: current,
        requested: $0,
        targetChapters: targetChapters,
        volumeCount: nextConstraints.volumeCount
      )
    }
    let nextContinuity = try (manualProjection?.continuity ?? current.continuity).validated(
      targetChapters: targetChapters,
      volumeCount: nextConstraints.volumeCount
    )
    let next = try makeLongFormPlan(
      bookID: bookID,
      constraints: nextConstraints,
      continuity: nextContinuity,
      revision: current.revision + 1,
      createdAt: current.createdAt
    )
    let url = try existingBookURL(bookID).appendingPathComponent("long-form-plan.json")
    let planSnapshot = try? Data(contentsOf: url)
    let projectionURL = try continuityProjectionURL(bookID: bookID)
    let projectionSnapshot = try? Data(contentsOf: projectionURL)
    let checkpointSnapshots = try snapshotVolumeCheckpoints(bookID: bookID)
    do {
      if let manualProjection {
        try atomicWrite(encoder.encode(manualProjection), to: projectionURL)
      }
      try atomicWrite(encoder.encode(next), to: url)
      let synchronized = try synchronizeContinuityProjection(bookID: bookID)
      recordDebug(scope: "planning", message: "long_form.updated", data: [
        "bookId": bookID,
        "revision": synchronized.revision,
        "manualContinuityOverlay": manualProjection != nil,
      ])
      return synchronized
    } catch {
      restoreFile(projectionURL, snapshot: projectionSnapshot)
      restoreFile(url, snapshot: planSnapshot)
      restoreVolumeCheckpoints(bookID: bookID, snapshots: checkpointSnapshots)
      throw error
    }
  }

  func validatedConstraints(
    _ input: LongFormConstraints,
    requireSpecialConstraints: Bool = false
  ) throws -> LongFormConstraints {
    guard (1_000...3_000_000).contains(input.targetTotalWords) else {
      throw InkOSCoreError("目标总字数需在 1000 至 3000000 之间", statusCode: 400)
    }
    guard (500...20_000).contains(input.targetChapterWords) else {
      throw InkOSCoreError("目标单章字数需在 500 至 20000 之间", statusCode: 400)
    }
    guard (1...100).contains(input.volumeCount) else {
      throw InkOSCoreError("分卷数需在 1 至 100 之间", statusCode: 400)
    }
    guard (0...50).contains(input.chapterWordTolerance) else {
      throw InkOSCoreError("单章字数容差需在 0 至 50 之间", statusCode: 400)
    }
    let special = Array(Set(input.specialConstraints.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty })).sorted()
    if requireSpecialConstraints && special.isEmpty {
      throw InkOSCoreError("请至少填写一条特殊约束", statusCode: 400)
    }
    let chapters = max(1, Int((Double(input.targetTotalWords) / Double(input.targetChapterWords)).rounded()))
    guard chapters <= 10_000, input.volumeCount <= chapters else {
      throw InkOSCoreError("篇幅规划超过 10000 章或分卷数超过章节数", statusCode: 400)
    }
    return LongFormConstraints(
      targetTotalWords: input.targetTotalWords,
      volumeCount: input.volumeCount,
      targetChapterWords: input.targetChapterWords,
      chapterWordTolerance: input.chapterWordTolerance,
      specialConstraints: special
    )
  }

  func makeLongFormPlan(
    bookID: String,
    constraints: LongFormConstraints,
    continuity: LongFormContinuity = LongFormContinuity(),
    revision: Int = 1,
    createdAt: String? = nil
  ) throws -> LongFormPlanResponse {
    let chapterCount = max(1, Int((Double(constraints.targetTotalWords) / Double(constraints.targetChapterWords)).rounded()))
    let baseWords = constraints.targetTotalWords / chapterCount
    let wordRemainder = constraints.targetTotalWords % chapterCount
    // Band and per-chapter target come from different arithmetic: the band from
    // `targetChapterWords ± tolerance`, the target from
    // `targetTotalWords / chapterCount`. When the division is not clean the two
    // disagree, and the generation prompt then states an impossible instruction
    // ("必须落在 3400 至 4600 字，目标 3333 字"). The band is what validation
    // enforces, so the target is clamped into it.
    let (minWords, maxWords) = constraints.derivedChapterWordBand

    var chapters: [[String: Any]] = []
    var volumes: [[String: Any]] = []
    var cursor = 1
    let baseChapterCount = chapterCount / constraints.volumeCount
    let chapterRemainder = chapterCount % constraints.volumeCount
    for volumeNumber in 1...constraints.volumeCount {
      let count = baseChapterCount + (volumeNumber <= chapterRemainder ? 1 : 0)
      let start = cursor
      let end = cursor + count - 1
      var volumeWords = 0
      for chapterNumber in start...end {
        let budgeted = baseWords + (chapterNumber <= wordRemainder ? 1 : 0)
        let target = min(maxWords, max(minWords, budgeted))
        volumeWords += target
        chapters.append([
          "number": chapterNumber,
          "volumeNumber": volumeNumber,
          "targetWords": target,
          "minWords": minWords,
          "maxWords": maxWords,
        ])
      }
      volumes.append([
        "number": volumeNumber,
        "startChapter": start,
        "endChapter": end,
        "chapterCount": count,
        "targetWords": volumeWords,
      ])
      cursor = end + 1
    }

    let now = isoTimestamp()
    let object: [String: Any] = [
      "version": 1,
      "revision": revision,
      "bookId": bookID,
      "constraints": try encodedObject(constraints),
      "plan": [
        "targetChapters": chapterCount,
        "chapterWordRange": ["min": minWords, "max": maxWords],
        "volumes": volumes,
        "chapters": chapters,
      ],
      "continuity": try encodedObject(continuity),
      "source": "native-inkos-core",
      "createdAt": createdAt ?? now,
      "updatedAt": now,
    ]
    return try decodeObject(object, as: LongFormPlanResponse.self)
  }

  private func createBookFiles(
    bookID: String,
    input: CreateBookRequest,
    constraints: LongFormConstraints
  ) throws {
    let bookURL = try safeBookURL(bookID)
    let chaptersURL = bookURL.appendingPathComponent("chapters", isDirectory: true)
    let storyURL = bookURL.appendingPathComponent("story", isDirectory: true)
    let outlineURL = storyURL.appendingPathComponent("outline", isDirectory: true)
    try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outlineURL, withIntermediateDirectories: true)

    let now = isoTimestamp()
    try writeJSON([
      "id": bookID,
      "title": input.title,
      "language": input.language,
      "genre": input.genre,
      "platform": input.platform,
      "status": "active",
      "targetChapters": input.derivedTargetChapters,
      "chapterWordCount": input.chapterWords,
      // Persisted here rather than only in `state.json` because every later
      // chapter has to know whether it owes obedience to an imported original,
      // and `book.json` is the per-book record the pipeline already reads.
      "kind": input.kind.rawValue,
      "sourceTitle": input.sourceTitle,
      "createdAt": now,
      "updatedAt": now,
    ], to: bookURL.appendingPathComponent("book.json"))
    try writeJSON([], to: chaptersURL.appendingPathComponent("index.json"))

    let plan = try makeLongFormPlan(bookID: bookID, constraints: constraints)
    try atomicWrite(encoder.encode(plan), to: bookURL.appendingPathComponent("long-form-plan.json"))

    let files: [String: String] = [
      "author_intent.md": "# 创作简报\n\n\(input.premise)\n\n## 节奏\n\(input.pacing)\n\n## 特殊约束\n\(input.constraints)",
      "brief.md": "# \(input.title)\n\n\(input.premise)",
      "book_rules.md": "# 硬规则\n\n\(input.constraints)\n\n## 世界边界\n\(input.worldbuilding)",
      "story_bible.md": "# 故事圣经\n\n## 人物\n\(input.characters)\n\n## 世界观\n\(input.worldbuilding)",
      "protagonist.md": "# 主角性格\n\n\(input.protagonistProfile)",
      "style_guide.md": "# 文风指南\n\n\(input.style)\n\n## 节奏\n\(input.pacing)",
      "craft_rules.md": InkOSCore.defaultCraftRules,
      "outline/story_frame.md": "# 故事基石\n\n\(input.outline)",
      "outline/volume_map.md": "# 分卷地图\n\n\(input.volumePlan)",
      "current_focus.md": "# 当前聚焦\n\n从第一章建立冲突、人物目标和章末钩子。",
      "current_state.md": "# 当前状态\n\n小说尚未开始，所有角色与世界状态以故事圣经为准。",
      "pending_hooks.md": "# 伏笔池\n",
      "chapter_summaries.md": "# 章节摘要\n",
      "character_matrix.md": "# 人物关系与知识边界\n\n\(input.characters)",
      "object_ledger.md": "# 持久对象账本\n",
      "particle_ledger.md": "# 资源账本\n",
      "emotional_arcs.md": "# 情感弧线\n",
      "subplot_board.md": "# 支线进度\n",
    ]
    for (path, content) in files {
      try atomicWrite(content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", to: storyURL.appendingPathComponent(path))
    }

    // The story clock is written at creation, not on first generation: chapter 1's
    // date is an input the customer gave, and deriving it later from an already
    // written chapter would mean the first chapter was drafted with no clock at all.
    // The anchor milestone id stays nil here — canon extraction assigns ids, so it
    // is resolved by label on first use.
    if input.kind == .derivative {
      let anchor = input.timelineAnchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      let startLabel = input.timelineStartDateLabel.trimmingCharacters(in: .whitespacesAndNewlines)
      try saveDerivativeTimeline(bookID: bookID, DerivativeTimeline(
        anchorLabel: anchor,
        startDayOffset: input.timelineStartDayOffset,
        startDateLabel: startLabel
      ))
    }
  }

  private func validatedGuide(_ raw: CreateBookGuide) throws -> CreateBookGuide {
    var guide = raw
    guide.title = guide.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guide.storyPremise = guide.storyPremise.trimmingCharacters(in: .whitespacesAndNewlines)
    guide.protagonistName = guide.protagonistName.trimmingCharacters(in: .whitespacesAndNewlines)
    guide.protagonistProfile = guide.protagonistProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    guide.worldRules = guide.worldRules.trimmingCharacters(in: .whitespacesAndNewlines)
    guide.pacing = guide.pacing.trimmingCharacters(in: .whitespacesAndNewlines)
    guide.timelineAnchorLabel = guide.timelineAnchorLabel.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !guide.title.isEmpty else { throw InkOSCoreError("请填写书名", statusCode: 400) }
    guard guide.storyPremise.count >= 20 else { throw InkOSCoreError("剧情概述至少填写 20 个字符", statusCode: 400) }
    guard !guide.protagonistName.isEmpty, guide.protagonistProfile.count >= 10 else {
      throw InkOSCoreError("请完整填写主角姓名、起点和目标", statusCode: 400)
    }
    if guide.kind == .derivative, guide.timelineAnchorLabel.isEmpty {
      throw InkOSCoreError("同人小说必须填写原著时间锚点", statusCode: 400)
    }
    guide.synchronizeBudget()
    _ = try validatedConstraints(
      LongFormConstraints(
        targetTotalWords: guide.targetTotalWords,
        volumeCount: guide.volumeCount,
        targetChapterWords: guide.targetChapterWords,
        chapterWordTolerance: guide.chapterWordTolerance,
        specialConstraints: effectiveCreationConstraints(guide.specialConstraints)
      ),
      requireSpecialConstraints: true
    )
    return guide
  }

  private func createBookPrompt(_ guide: CreateBookGuide) -> String {
    let derivative = derivativeCreationSections(guide)
    return """
    你是小说策划编辑。用户只回答了普通作者能够决定的问题，请把这些回答整理成可直接执行的完整长篇小说方案。\(derivative.intro)
    只输出 JSON，字段为 premise、characters、protagonistProfile、worldbuilding、outline、volumePlan、pacing、style。
    所有字段都必须是非空中文字符串。用户确认事实必须原样保留；用户未决定的世界规则、人物关系、节奏和文风由你合理补全。
    protagonistProfile 是主角性格档案，将逐字呈现给用户审核修改，必须写成"一个具体的人"而不是标签堆砌，包含：三个以内具体性格特质；一个真实的缺陷或软肋（会在小事上拖累他的那种）；情绪反应习惯（压力下先做什么、累极了会怎样）；说话方式与口癖；防御机制（如冷幽默）以及他在防什么；与人相处的方式。避免"冷静""果断""善良"这类空泛评语，每条都要落到可观察的行为上。
    characters 是包括主角在内的群像表，与 protagonistProfile 一致但不重复其细节。
    volumePlan 必须覆盖全部 \(guide.volumeCount) 卷并标明每卷章节范围、阶段目标、主要冲突、卷末变化和需要回收的伏笔。
    规划必须维护跨卷因果、角色成长、时间线、知识边界、资源代价和随机小设定的一致性，不要向用户反问。

    书名：\(guide.title)
    题材：\(guide.genre)
    平台：\(guide.platform)
    剧情：\(guide.storyPremise)
    主角：\(guide.protagonistName)；\(guide.protagonistProfile)
    用户补充的世界规则：\(guide.worldRules.isEmpty ? "未指定，请合理推导" : guide.worldRules)
    用户补充的节奏：\(guide.pacing.isEmpty ? "未指定，请根据题材和平台推导" : guide.pacing)
    用户希望的阅读感觉：\(guide.style.isEmpty ? "未指定，请根据题材和平台推导" : guide.style)
    篇幅：\(guide.targetChapters)章，每章\(guide.targetChapterWords)字，共\(guide.targetTotalWords)字，\(guide.volumeCount)卷
    必须遵守的要求：\(effectiveCreationConstraints(guide.specialConstraints).joined(separator: "；"))\(derivative.body)
    """
  }

  /// Derivative-only additions to the creation prompt.
  ///
  /// The plan is written before any chapter exists, so this is the one place a
  /// timeline mistake is cheapest to prevent and most expensive to miss: an outline
  /// that schedules a canon event in the wrong volume will drag every beat card and
  /// every chapter after it off the source timeline. Empty for an original book.
  private func derivativeCreationSections(_ guide: CreateBookGuide) -> (intro: String, body: String) {
    guard guide.kind == .derivative else { return ("", "") }
    let sourceTitle = guide.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let titleText = sourceTitle.isEmpty ? "原著" : "《\(sourceTitle)》"
    let anchor = guide.timelineAnchorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    let startLabel = guide.timelineStartDateLabel.trimmingCharacters(in: .whitespacesAndNewlines)

    let intro = "\n本书是\(titleText)的同人作品，方案必须同时满足两个来源：用户设定决定主角、"
      + "金手指和主线走向；\(titleText)的既有事实、人物关系和事件顺序是不可改写的前提。"
      + "两者冲突时，只允许在\(titleText)没有写死的空白处发挥，不得改写\(titleText)已定的事实。"

    var lines: [String] = ["", "同人方案的硬性要求："]
    lines.append(
      "1. worldbuilding 只写\(titleText)已有的世界规则加上用户设定新增的部分，"
        + "不要发明与\(titleText)冲突的体系；不确定的地方留白，不要猜测。"
    )
    lines.append(
      "2. characters 里的原著人物必须沿用\(titleText)的姓名、身份和关系，"
        + "不要改写他们的既定经历；原创人物要明确标出是原创。"
    )
    if !anchor.isEmpty {
      var timing = "3. 本书开篇的时间点是"
      timing += startLabel.isEmpty ? "「\(anchor)」之前" : "\(startLabel)"
      timing += "，"
      if guide.timelineStartDayOffset < 0 {
        timing += "即原著事件「\(anchor)」发生前约 \(-guide.timelineStartDayOffset) 天。"
          + "outline 和 volumePlan 必须尊重这个起点：在「\(anchor)」发生之前，"
          + "该事件之后的原著剧情、人物状态和已知信息都还不存在，任何人都不知道它会发生。"
      } else if guide.timelineStartDayOffset > 0 {
        timing += "即原著事件「\(anchor)」发生后约 \(guide.timelineStartDayOffset) 天。"
          + "「\(anchor)」之后的原著剧情按原著顺序尚未展开的部分，不得提前发生。"
      } else {
        timing += "即与原著事件「\(anchor)」同期。该事件之后的原著剧情不得提前发生。"
      }
      lines.append(timing)
      lines.append(
        "4. volumePlan 必须写清每一卷与原著时间线的对应关系（这一卷大致处于原著的哪个阶段），"
          + "并保证原著事件按原著顺序出现，不得为了剧情方便把后期事件提前。"
      )
    } else {
      lines.append(
        "3. volumePlan 必须写清每一卷与原著时间线的对应关系，"
          + "并保证原著事件按原著顺序出现，不得把后期事件提前。"
      )
    }
    return (intro, lines.joined(separator: "\n"))
  }

  private func normalizedFanqieAbstract(_ raw: String) throws -> String {
    let lines = raw.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("```") }
    guard !lines.isEmpty else {
      throw InkOSCoreError("模型返回了空简介", statusCode: 502)
    }

    var text = lines.joined()
    for prefix in ["作品简介：", "作品简介:", "简介：", "简介:"] where text.hasPrefix(prefix) {
      text.removeFirst(prefix.count)
      break
    }
    text = text.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "#-*\"'“”‘’"))
    )
    while text.contains("  ") {
      text = text.replacingOccurrences(of: "  ", with: " ")
    }
    if text.count > 500 {
      text = String(text.prefix(500))
    }
    guard text.count >= 50 else {
      throw InkOSCoreError("模型生成的简介少于 50 字，请重试", statusCode: 502)
    }
    return text
  }

  private func lockedText(label: String, confirmed: String, generated: String) -> String {
    let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
    let generated = generated.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !confirmed.isEmpty else { return generated }
    guard !generated.isEmpty else { return confirmed }
    if generated.contains(confirmed) { return generated }
    return "\(confirmed)\n\n\(generated)"
  }

  private func effectiveCreationConstraints(_ userConstraints: [String]) -> [String] {
    let systemConstraints = [
      "跨章节与跨分卷保持人物身份、时间线、因果关系、世界规则和能力边界一致",
      "临时生成的人物、地点、物品、能力和组织必须进入设定记录，后续引用以记录为准",
      "已确认事实的变化必须由正文事件触发，不得静默改写或产生无来源信息",
    ]
    let normalized = userConstraints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var seen = Set<String>()
    return (normalized + systemConstraints).filter { seen.insert($0).inserted }
  }

  private func defaultVolumePlan(chapters: Int, volumes: Int) -> String {
    var cursor = 1
    return (1...volumes).map { volume in
      let count = chapters / volumes + (volume <= chapters % volumes ? 1 : 0)
      let start = cursor
      let end = cursor + count - 1
      cursor = end + 1
      return "第\(volume)卷（第\(start)-\(end)章）：推进阶段目标并完成卷末回收。"
    }.joined(separator: "\n")
  }

  private func sanitizeBookID(_ title: String) -> String {
    sanitizeFilename(title.replacingOccurrences(of: "：", with: "-").replacingOccurrences(of: ":", with: "-"))
  }
}
