import Foundation

actor NativeStreamCollector {
  private var updateCount = 0
  private var latest = ""

  func accept(_ text: String) {
    updateCount += 1
    latest = text
  }

  func snapshot() -> (count: Int, latest: String) {
    (updateCount, latest)
  }
}

@main
struct NativeCoreSmoke {
  static func main() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "MacInkostomo-NativeCore-Smoke-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }

    let core = InkOSCore(rootURL: root)
    let fanqieLogin = try await core.fetchFanqieLoginState()
    precondition(!fanqieLogin.loggedIn)
    precondition(fanqieLogin.needRelogin == true)
    let fanqieLogout = try await core.logoutFanqie()
    precondition(fanqieLogout.ok)

    let streamJob = try await core.makeGenerationJob(
      bookID: "stream-contract",
      chapterNumber: 1,
      phase: "writing",
      message: "正在调用写作模型",
      startedAt: isoTimestamp(),
      liveText: "第一段实时正文"
    )
    precondition(streamJob.liveText == "第一段实时正文")
    precondition(streamJob.liveTextTruncated == false)

    let request = CreateBookRequest(
      title: "原生核心测试书",
      language: "zh",
      genre: "xuanhuan",
      platform: "tomato",
      targetChapters: 10,
      chapterWords: 1_000,
      totalWords: "10000",
      targetTotalWords: 10_000,
      volumeCount: 2,
      chapterWordTolerance: 15,
      premise: "测试原生核心直接创建小说，并验证磁盘数据契约。",
      characters: "主角测试员，目标是完成原生迁移。",
      worldbuilding: "所有设定均遵循确定性测试规则。",
      outline: "第一卷建立目标，第二卷完成回收。",
      volumePlan: "第一卷1-5章；第二卷6-10章。",
      pacing: "每章推进一个明确目标。",
      style: "第三人称有限视角。",
      constraints: "角色姓名保持一致\n时间线严格递增"
    )

    let creation = try await core.createBook(request)
    precondition(creation.status == "success")

    let books = try await core.fetchBooks()
    precondition(books.count == 1)
    precondition(books[0].title == request.title)

    let plan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(plan.constraints.targetTotalWords == 10_000)
    precondition(plan.plan.targetChapters == 10)
    precondition(plan.plan.volumes.count == 2)
    precondition(plan.plan.chapters.reduce(0) { $0 + $1.targetWords } == 10_000)

    let settings = try await core.fetchBookSettings(bookID: books[0].id)
    precondition(settings.files.contains { $0.path == "book_rules.md" })
    // Files the core rewrites from the approved-chapter projection must be
    // flagged managed so the settings page can warn before an edit is lost;
    // files it only reads must not be, or the warning becomes noise.
    let managedPaths = Set(settings.files.filter(\.managed).map(\.path))
    precondition(managedPaths == ["current_state.md", "pending_hooks.md", "current_focus.md"])
    precondition(!managedPaths.contains("object_ledger.md"))
    precondition(!managedPaths.contains("chapter_summaries.md"))
    let original = try await core.fetchBookSetting(bookID: books[0].id, path: "book_rules.md")
    let save = try await core.saveBookSetting(
      bookID: books[0].id,
      path: "book_rules.md",
      content: original + "\n新增测试规则。\n"
    )
    precondition(save.ok)
    let backups = try await core.fetchBookSettingsBackups(bookID: books[0].id)
    precondition(backups.backups.count == 1)
    let restore = try await core.restoreBookSettings(
      bookID: books[0].id,
      backupID: backups.backups[0].backupId
    )
    precondition(restore.ok)
    let restored = try await core.fetchBookSetting(bookID: books[0].id, path: "book_rules.md")
    precondition(restored == original)

    let chapterBody = String(repeating: "连续性回归正文。", count: 80)
    try await core.writeChapter(
      bookID: books[0].id,
      number: 1,
      title: "旧格式迁移",
      content: chapterBody,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: books[0].id,
      chapterNumber: 1,
      title: "旧格式迁移",
      summary: "验证旧格式自动迁移。",
      delta: [
        "immutableCanon": [[
          "id": "canon-anchor", "category": "world", "statement": "天空始终为灰色",
        ]],
        "worldRules": [[
          "id": "rule-cost", "statement": "使用能力必须付出代价", "immutable": true,
        ]],
        "entities": [["name": "王阿姨", "desc": "首次出现的邻居"]],
        "objects": [["name": "旧钥匙", "quantity": "1把", "保管": "主角口袋"]],
        "knowledge": ["主角：知晓旧钥匙的来源"],
        "timeline": ["第1日：主角取得旧钥匙"],
        "hooks": ["旧钥匙对应的门尚未出现"],
      ]
    )
    _ = try await core.approveChapter(bookID: books[0].id, number: 1)
    let migratedPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(migratedPlan.continuity.policy.requireConsistencyDelta)
    precondition(migratedPlan.continuity.immutableCanon.count == 1)
    precondition(migratedPlan.continuity.worldRules.count == 1)
    precondition(migratedPlan.continuity.entities.count == 2)
    precondition(migratedPlan.continuity.knowledgeBoundaries.count == 1)
    precondition(migratedPlan.continuity.timeline.count == 1)
    precondition(migratedPlan.continuity.hooks.count == 1)

    let migratedRevision = migratedPlan.revision
    _ = try await core.approveChapter(bookID: books[0].id, number: 1)
    let duplicateApprovalPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(duplicateApprovalPlan.revision == migratedRevision)

    try await core.writeChapter(
      bookID: books[0].id,
      number: 1,
      title: "新格式替换",
      content: chapterBody,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: books[0].id,
      chapterNumber: 1,
      title: "新格式替换",
      summary: "旧章节贡献退出，新贡献等待审核。",
      delta: [
        "upsert": [
          "immutableCanon": [[
            "id": "canon-anchor", "category": "world", "statement": "天空始终为灰色",
          ]],
          "worldRules": [],
          "entities": [[
            "id": "entity-new", "name": "新角色", "type": "character",
            "attributes": ["status": "登场"],
          ]],
          "knowledgeBoundaries": [],
          "timeline": [],
          "hooks": [],
        ],
        "remove": [
          "immutableCanon": [], "worldRules": [], "entities": [],
          "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
      ]
    )
    let pendingRevisionPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(pendingRevisionPlan.continuity.entities.isEmpty)
    precondition(pendingRevisionPlan.continuity.immutableCanon.isEmpty)
    _ = try await core.approveChapter(bookID: books[0].id, number: 1)
    let replacedPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(replacedPlan.continuity.entities.map(\.name) == ["新角色"])
    precondition(replacedPlan.continuity.immutableCanon.map(\.id) == ["canon-anchor"])

    var manualContinuity = replacedPlan.continuity
    manualContinuity.entities.append(LongFormEntity(
      id: "manual-editor-note",
      name: "人工维护角色",
      type: "character",
      attributes: ["source": "settings"]
    ))
    let manuallyUpdated = try await core.updateLongFormPlan(
      bookID: books[0].id,
      expectedRevision: replacedPlan.revision,
      continuity: manualContinuity
    )
    precondition(manuallyUpdated.continuity.entities.contains { $0.id == "manual-editor-note" })

    try await core.writeChapter(
      bookID: books[0].id,
      number: 2,
      title: "覆盖层重放",
      content: chapterBody,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: books[0].id,
      chapterNumber: 2,
      title: "覆盖层重放",
      summary: "加入第二章实体。",
      delta: [
        "upsert": [
          "immutableCanon": [], "worldRules": [],
          "entities": [["id": "entity-two", "name": "第二章角色", "type": "character"]],
          "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
        "remove": [
          "immutableCanon": [], "worldRules": [], "entities": [],
          "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
      ]
    )
    _ = try await core.approveChapter(bookID: books[0].id, number: 2)
    let replayedPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(replayedPlan.continuity.entities.contains { $0.id == "manual-editor-note" })
    precondition(replayedPlan.continuity.entities.contains { $0.id == "entity-two" })
    let projectedContext = try await core.storyContext(bookID: books[0].id, maxCharacters: 20_000)
    precondition(projectedContext.contains("结构化连续性索引"))
    precondition(projectedContext.contains("manual-editor-note"))
    precondition(projectedContext.contains("entity-two"))
    let generationPrompt = try await core.generationPrompt(
      bookID: books[0].id,
      chapterNumber: 3,
      guidance: nil
    )
    precondition(generationPrompt.contains("knowledgeBoundaries"))
    precondition(generationPrompt.contains("manual-editor-note"))

    // Craft governance: the kernel is always present, the per-book rules file is
    // created on demand, and a beat card reaches the generation prompt.
    precondition(generationPrompt.contains("写法内核"))
    precondition(generationPrompt.contains("场景纪律"))
    let craftRules = try await core.craftRulesText(bookID: books[0].id)
    precondition(craftRules.contains("写法约束"))
    let craftRulesFile = root.appendingPathComponent(
      "book/books/\(books[0].id)/story/craft_rules.md"
    )
    precondition(fileManager.fileExists(atPath: craftRulesFile.path))
    let openingDirectives = try await core.craftDirectives(bookID: books[0].id, chapterNumber: 1)
    precondition(openingDirectives.contains("开篇章附加规则"))
    let laterDirectives = try await core.craftDirectives(bookID: books[0].id, chapterNumber: 40)
    precondition(!laterDirectives.contains("开篇章附加规则"))
    precondition(laterDirectives.contains("写法内核"))

    let beatPlanBefore = try await core.fetchChapterBeats(bookID: books[0].id)
    precondition(beatPlanBefore.beats.isEmpty)
    let sampleBeat = ChapterBeat(
      number: 3,
      volumeNumber: 1,
      goal: "让主角在断水的第三天说服邻居交出私藏容器",
      openingHook: "主角敲开对门时，水桶正从门缝里被拖走",
      scenes: ["走廊对峙", "天台清点"],
      requiredEvents: ["主角第一次被公开质疑", "私藏容器被交出但数量不足"],
      forbiddenElements: ["不得进入异界", "不得出现苏晚晴", "不得建成完整净水系统"],
      endingHook: "水位读数比昨天低了一半",
      focusCharacters: ["主角", "王阿姨"],
      newNamedCharacters: 1,
      timeSpan: "半天",
      setback: "交出的容器不足计划的一半"
    )
    let beatBrief = await core.beatBriefText(sampleBeat)
    precondition(beatBrief.contains("本章禁止提前出现或提前解决"))
    precondition(beatBrief.contains("不得进入异界"))
    let beatPrompt = try await core.generationPrompt(
      bookID: books[0].id,
      chapterNumber: 3,
      guidance: nil,
      beat: sampleBeat
    )
    precondition(beatPrompt.contains("不得进入异界"))
    precondition(beatPrompt.contains("必须在正文里被看见发生"))

    // Length enforcement uses the plan range rather than a flat 500 characters.
    let chapterRange = replayedPlan.plan.chapters.first { $0.number == 3 }
    precondition(chapterRange != nil)
    var lengthRejected = false
    do {
      try await core.validateChapterLength(
        String(repeating: "字", count: 600),
        chapterNumber: 3,
        minWords: chapterRange!.minWords,
        maxWords: chapterRange!.maxWords,
        label: "正文"
      )
    } catch {
      lengthRejected = true
    }
    precondition(lengthRejected, "under-length chapter must be rejected against the plan range")

    var overLengthRejected = false
    do {
      try await core.validateChapterLength(
        String(repeating: "字", count: chapterRange!.maxWords * 3),
        chapterNumber: 3,
        minWords: chapterRange!.minWords,
        maxWords: chapterRange!.maxWords,
        label: "正文"
      )
    } catch {
      overLengthRejected = true
    }
    precondition(overLengthRejected, "over-length chapter must be rejected against the plan range")

    try await core.validateChapterLength(
      String(repeating: "字", count: chapterRange!.targetWords),
      chapterNumber: 3,
      minWords: chapterRange!.minWords,
      maxWords: chapterRange!.maxWords,
      label: "正文"
    )

    // A chapter at the plan floor but padded with punctuation must fail the
    // Chinese-character density check even though proseCount passes.
    var paddedRejected = false
    do {
      let padded = String(repeating: "字，", count: (chapterRange!.minWords + 1) / 2)
      try await core.validateChapterLength(
        padded,
        chapterNumber: 3,
        minWords: chapterRange!.minWords,
        maxWords: chapterRange!.maxWords,
        label: "正文"
      )
    } catch {
      paddedRejected = true
    }
    precondition(paddedRejected, "punctuation-padded chapter must fail the density floor")

    // Deterministic craft checks reject ledger blocks, fade-out endings and
    // ability-free openings before the review pass.
    var ledgerRejected = false
    do {
      try await core.validateChapterCraft(
        String(repeating: "字", count: 200)
          + "\n存水：十二升\n存粮：五天\n燃料：两罐\n"
          + String(repeating: "字", count: 200),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      ledgerRejected = true
    }
    precondition(ledgerRejected, "ledger enumeration blocks must be rejected")

    var fadeOutRejected = false
    do {
      try await core.validateChapterCraft(
        String(repeating: "字", count: 400) + "\n他锁好门，躺在行军床上沉沉睡去。",
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      fadeOutRejected = true
    }
    precondition(fadeOutRejected, "fade-out endings must be rejected")

    var anchorRejected = false
    do {
      try await core.validateChapterCraft(
        String(repeating: "字", count: 400),
        chapterNumber: 1,
        label: "正文"
      )
    } catch {
      anchorRejected = true
    }
    precondition(anchorRejected, "opening chapters without an anomaly anchor must be rejected")

    // Dialogue attribution shares the label-colon shape but is prose, so a
    // quoted exchange must not trip the ledger check.
    try await core.validateChapterCraft(
      String(repeating: "字", count: 200)
        + "\n他问：“你听见了？”\n她答：“听见了。”\n他问：“在哪里？”\n"
        + String(repeating: "字", count: 200),
      chapterNumber: 4,
      label: "正文"
    )

    // Runtime state files must reflect approved progress, not the creation-time
    // placeholders.
    await core.refreshRuntimeStateFiles(bookID: books[0].id, plan: replayedPlan)
    let storyRoot = root.appendingPathComponent("book/books/\(books[0].id)/story")
    let refreshedState = try String(
      contentsOf: storyRoot.appendingPathComponent("current_state.md"),
      encoding: .utf8
    )
    precondition(!refreshedState.contains("小说尚未开始"))
    precondition(refreshedState.contains("第 2 章"))
    let refreshedFocus = try String(
      contentsOf: storyRoot.appendingPathComponent("current_focus.md"),
      encoding: .utf8
    )
    precondition(refreshedFocus.contains("第 3 章"))
    let refreshedHooks = try String(
      contentsOf: storyRoot.appendingPathComponent("pending_hooks.md"),
      encoding: .utf8
    )
    precondition(refreshedHooks.contains("伏笔"))

    // Beats after a revised chapter must be dropped so they are replanned.
    _ = try await core.invalidateChapterBeats(bookID: books[0].id, fromChapter: 3)
    let invalidated = try await core.fetchChapterBeats(bookID: books[0].id)
    precondition(!invalidated.beats.contains { $0.number >= 3 })

    try await core.writeChapter(
      bookID: books[0].id,
      number: 3,
      title: "冲突回滚",
      content: chapterBody,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: books[0].id,
      chapterNumber: 3,
      title: "冲突回滚",
      summary: "尝试改写不可变事实。",
      delta: [
        "upsert": [
          "immutableCanon": [[
            "id": "canon-anchor", "category": "world", "statement": "天空突然变为蓝色",
          ]],
          "worldRules": [], "entities": [], "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
        "remove": [
          "immutableCanon": [], "worldRules": [], "entities": [],
          "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
      ]
    )
    do {
      _ = try await core.approveChapter(bookID: books[0].id, number: 3)
      preconditionFailure("不可变连续性冲突应阻止审核通过")
    } catch let error as InkOSCoreError {
      precondition(error.statusCode == 409)
    }
    let rolledBackChapter = try await core.fetchChapter(bookID: books[0].id, number: 3)
    precondition(rolledBackChapter.status == "pending_review")
    let rolledBackPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(rolledBackPlan.continuity.immutableCanon.first?.statement == "天空始终为灰色")
    let projectionURL = root.appendingPathComponent(
      "book/books/\(books[0].id)/story/runtime/continuity-projection.json"
    )
    precondition(fileManager.fileExists(atPath: projectionURL.path))

    let policyRequest = CreateBookRequest(
      title: "策略执行测试书",
      language: "zh",
      genre: "sci-fi",
      platform: "tomato",
      targetChapters: 2,
      chapterWords: 500,
      totalWords: "1000",
      targetTotalWords: 1_000,
      volumeCount: 2,
      chapterWordTolerance: 10,
      premise: "验证连续写作、实体准入和卷末检查点策略。",
      characters: "主角记录员负责验证策略。",
      worldbuilding: "所有策略测试均使用确定性数据。",
      outline: "两章分别完成两卷测试。",
      volumePlan: "第一卷第1章；第二卷第2章。",
      pacing: "每章完成一个策略验证目标。",
      style: "简洁测试叙事。",
      constraints: "必须执行连续性策略"
    )
    let policyCreation = try await core.createBook(policyRequest)
    let policyBookID = policyCreation.title
    var policyPlan = try await core.fetchLongFormPlan(bookID: policyBookID)
    var policyContinuity = policyPlan.continuity
    policyContinuity.entities.append(LongFormEntity(
      id: "planned-observer",
      name: "预登记观察员",
      type: "character",
      attributes: ["role": "策略测试"]
    ))
    policyContinuity.policy.requireContinuousVolumes = true
    policyContinuity.policy.allowUnplannedEntities = false
    policyContinuity.policy.checkpointAtVolumeEnd = true
    policyPlan = try await core.updateLongFormPlan(
      bookID: policyBookID,
      expectedRevision: policyPlan.revision,
      continuity: policyContinuity
    )

    let unplannedDelta = try await core.normalizedConsistencyDelta([
      "upsert": [
        "immutableCanon": [], "worldRules": [],
        "entities": [["id": "unplanned", "name": "未登记角色", "type": "character"]],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
      "remove": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
    ], chapterNumber: 1)
    do {
      _ = try await core.validateCandidateContinuity(
        bookID: policyBookID,
        chapterNumber: 1,
        delta: unplannedDelta
      )
      preconditionFailure("禁止未规划实体策略应拒绝新实体")
    } catch let error as InkOSCoreError {
      precondition(error.statusCode == 409)
    }

    let plannedDeltaRaw: [String: Any] = [
      "upsert": [
        "immutableCanon": [], "worldRules": [],
        "entities": [[
          "id": "planned-observer", "name": "预登记观察员", "type": "character",
          "attributes": ["status": "已进入第一卷"],
        ]],
        "knowledgeBoundaries": [], "timeline": [],
        "hooks": [[
          "hookId": "volume-one-hook", "description": "第一卷遗留问题",
          "openFromChapter": 1, "resolveByChapter": 2,
        ]],
      ],
      "remove": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
    ]
    let plannedDelta = try await core.normalizedConsistencyDelta(plannedDeltaRaw, chapterNumber: 1)
    let plannedProjection = try await core.validateCandidateContinuity(
      bookID: policyBookID,
      chapterNumber: 1,
      delta: plannedDelta
    )
    precondition(
      plannedProjection.entities.first(where: { $0.id == "planned-observer" })?
        .attributes["status"] == "已进入第一卷"
    )

    try await core.writeChapter(
      bookID: policyBookID,
      number: 1,
      title: "第一卷检查点",
      content: chapterBody,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: policyBookID,
      chapterNumber: 1,
      title: "第一卷检查点",
      summary: "第一卷完成。",
      delta: plannedDeltaRaw
    )
    let emptyDeltaRaw: [String: Any] = [
      "upsert": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
      "remove": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
    ]
    try await core.writeChapter(
      bookID: policyBookID,
      number: 2,
      title: "第二卷顺序",
      content: chapterBody,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: policyBookID,
      chapterNumber: 2,
      title: "第二卷顺序",
      summary: "第二卷等待顺序校验。",
      delta: emptyDeltaRaw
    )
    do {
      _ = try await core.approveChapter(bookID: policyBookID, number: 2)
      preconditionFailure("连续分卷策略应阻止越过未审核章节")
    } catch let error as InkOSCoreError {
      precondition(error.statusCode == 409)
    }

    _ = try await core.approveChapter(bookID: policyBookID, number: 1)
    let firstCheckpointURL = root.appendingPathComponent(
      "book/books/\(policyBookID)/story/runtime/checkpoints/volume-0001.canon.json"
    )
    precondition(fileManager.fileExists(atPath: firstCheckpointURL.path))
    let firstCheckpoint = try JSONDecoder().decode(
      ContinuityVolumeCheckpoint.self,
      from: Data(contentsOf: firstCheckpointURL)
    )
    precondition(firstCheckpoint.volumeNumber == 1)
    precondition(firstCheckpoint.chapters.map(\.chapterNumber) == [1])
    precondition(
      firstCheckpoint.continuity.entities.first(where: { $0.id == "planned-observer" })?
        .attributes["status"] == "已进入第一卷"
    )

    try await core.writeChapter(
      bookID: policyBookID,
      number: 1,
      title: "第一卷检查点修订",
      content: chapterBody,
      status: "pending_review"
    )
    _ = try await core.fetchLongFormPlan(bookID: policyBookID)
    precondition(!fileManager.fileExists(atPath: firstCheckpointURL.path))
    try await core.persistConsistencyDelta(
      bookID: policyBookID,
      chapterNumber: 1,
      title: "第一卷检查点修订",
      summary: "第一卷修订完成。",
      delta: plannedDeltaRaw
    )
    _ = try await core.approveChapter(bookID: policyBookID, number: 1)
    precondition(fileManager.fileExists(atPath: firstCheckpointURL.path))
    _ = try await core.approveChapter(bookID: policyBookID, number: 2)
    let secondCheckpointURL = root.appendingPathComponent(
      "book/books/\(policyBookID)/story/runtime/checkpoints/volume-0002.canon.json"
    )
    precondition(fileManager.fileExists(atPath: secondCheckpointURL.path))
    let checkpointContext = try await core.storyContext(bookID: policyBookID, maxCharacters: 40_000)
    precondition(checkpointContext.contains("最近卷末连续性检查点"))
    precondition(checkpointContext.contains("volume-one-hook"))

    var disabledCheckpointContinuity = (try await core.fetchLongFormPlan(bookID: policyBookID)).continuity
    disabledCheckpointContinuity.policy.checkpointAtVolumeEnd = false
    let beforeDisable = try await core.fetchLongFormPlan(bookID: policyBookID)
    _ = try await core.updateLongFormPlan(
      bookID: policyBookID,
      expectedRevision: beforeDisable.revision,
      continuity: disabledCheckpointContinuity
    )
    precondition(!fileManager.fileExists(atPath: firstCheckpointURL.path))
    precondition(!fileManager.fileExists(atPath: secondCheckpointURL.path))
    _ = try await core.deleteBook(id: policyBookID)

    let deleted = try await core.deleteBook(id: books[0].id)
    precondition(deleted.deleted == books[0].id)
    let remainingBooks = try await core.fetchBooks()
    precondition(remainingBooks.isEmpty)

    if let liveRoot = ProcessInfo.processInfo.environment["MACINKOSTOMO_LIVE_ROOT"]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !liveRoot.isEmpty {
      let liveCore = InkOSCore(rootURL: URL(fileURLWithPath: liveRoot, isDirectory: true))
      if ProcessInfo.processInfo.environment["MACINKOSTOMO_FANQIE_SECURITY_PROBE"] == "1" {
        try await liveCore.prepareFanqieMutationSession()
        print("Native Fanqie mutation security probe passed")
        if ProcessInfo.processInfo.environment["MACINKOSTOMO_FANQIE_ONLY"] == "1" {
          print("Native InkOSCore smoke test passed")
          return
        }
      }
      let config = try await liveCore.fetchInkOSConfig()
      let catalog = try await liveCore.fetchModels(
        ModelEndpointRequest(role: .chapter, baseUrl: nil, apiKey: "")
      )
      precondition(catalog.models.contains { $0.id == config.model })
      let probe = try await liveCore.testModel(
        ModelTestRequest(role: .chapter, model: config.model, baseUrl: nil, apiKey: "")
      )
      guard probe.ok else {
        throw InkOSCoreError(probe.error ?? "原生模型探测失败", statusCode: probe.status ?? 502)
      }
      print("Native LLM probe passed: model=\(probe.model), latencyMs=\(probe.latencyMs ?? 0)")

      if let abstractBookID = ProcessInfo.processInfo.environment["MACINKOSTOMO_ABSTRACT_BOOK_ID"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !abstractBookID.isEmpty
      {
        let source = try await liveCore.fetchBookSetting(bookID: abstractBookID, path: "brief.md")
        let generated = try await liveCore.generateFanqieAbstract(
          bookID: abstractBookID,
          source: source,
          protagonistNames: []
        )
        precondition((50...500).contains(generated.count))
        precondition(!generated.contains("\n"))
        print("Native Fanqie abstract probe passed: characters=\(generated.count)")
        if ProcessInfo.processInfo.environment["MACINKOSTOMO_ABSTRACT_ONLY"] == "1" {
          print("Native InkOSCore smoke test passed")
          return
        }
      }

      let streamCollector = NativeStreamCollector()
      let streamResult = try await liveCore.requestLLM(
        prompt: "只输出 JSON：{\"title\":\"流式测试\",\"content\":\"写一段约三百字的雨夜守城场景\",\"summary\":\"测试\",\"consistencyDelta\":{}}。请把 content 扩写完整。",
        role: .primary,
        json: true,
        timeout: 180,
        onPartialContent: { partial in
          await streamCollector.accept(partial)
        }
      )
      let streamSnapshot = await streamCollector.snapshot()
      precondition(streamSnapshot.count > 0)
      precondition(streamSnapshot.latest == streamResult.content)
      precondition(streamResult.content.contains("content"))
      print("Native LLM streaming probe passed: updates=\(streamSnapshot.count)")

      if ProcessInfo.processInfo.environment["MACINKOSTOMO_STREAM_ONLY"] == "1" {
        print("Native InkOSCore smoke test passed")
        return
      }

      var guide = CreateBookGuide()
      guide.title = "问答引导链路测试"
      guide.genre = "xuanhuan"
      guide.platform = "tomato"
      guide.storyPremise = "一个失去力量的守城人发现敌人能够篡改众人的记忆，他必须在没人相信自己的情况下找出真相。"
      guide.protagonistName = "沈砚"
      guide.protagonistProfile = "被革职后独自调查旧案，希望阻止下一次全城记忆重置。"
      guide.targetChapters = 100
      guide.targetChapterWords = 3_000
      guide.volumeCount = 5
      let assisted = try await liveCore.assistCreateBook(guide: guide)
      precondition(!assisted.payload.premise.isEmpty)
      precondition(!assisted.payload.characters.isEmpty)
      precondition(!assisted.payload.worldbuilding.isEmpty)
      precondition(!assisted.payload.outline.isEmpty)
      precondition(!assisted.payload.volumePlan.isEmpty)
      precondition(!assisted.payload.pacing.isEmpty)
      precondition(!assisted.payload.style.isEmpty)
      precondition(assisted.payload.constraints.contains("跨章节与跨分卷"))
      let guidedCreation = try await core.createBook(assisted.payload)
      precondition(guidedCreation.status == "success")
      let guidedPlan = try await core.fetchLongFormPlan(bookID: guidedCreation.title)
      precondition(guidedPlan.plan.targetChapters == 100)
      precondition(guidedPlan.constraints.volumeCount == 5)
      precondition(guidedPlan.constraints.specialConstraints.contains { $0.contains("随机") || $0.contains("临时生成") })
      _ = try await core.deleteBook(id: guidedCreation.title)
      print("Native guided creation probe passed: model=\(assisted.model)")
    }

    print("Native InkOSCore smoke test passed")
  }
}
