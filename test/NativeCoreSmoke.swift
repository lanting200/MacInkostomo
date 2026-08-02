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

private struct AutomatedRevisionStubResponse {
  let content: String
  let stream: Bool
  let statusCode: Int

  init(content: String, stream: Bool, statusCode: Int = 200) {
    self.content = content
    self.stream = stream
    self.statusCode = statusCode
  }
}

private final class AutomatedRevisionLLMProtocol: URLProtocol {
  private static let responseLock = NSLock()
  private static var responses: [AutomatedRevisionStubResponse] = []
  private static var servedCount = 0

  static func configure(_ queuedResponses: [AutomatedRevisionStubResponse]) {
    responseLock.lock()
    responses = queuedResponses
    servedCount = 0
    responseLock.unlock()
  }

  /// Number of requests the core has issued since the last `configure`, so a
  /// test can assert a recovery path did not spend a second full chapter call.
  static func requestCount() -> Int {
    responseLock.lock()
    defer { responseLock.unlock() }
    return servedCount
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1" && request.url?.path.hasSuffix("/chat/completions") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let response = Self.nextResponse()
    guard let response else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    // Transport mismatch is a failure, which makes every fixture's `stream`
    // flag an assertion about how the core calls out. All four intercepted
    // calls — beat batch, chapter write, review, delta repair — stream, so
    // every fixture below is `stream: true`; reverting any call to
    // non-streaming fails here rather than silently regressing. That matters
    // because the reasoning model behind these endpoints sends nothing on a
    // non-streaming request until it stops thinking, and `timeoutInterval`
    // measures inactivity: non-streaming first byte measured 113.9s against
    // 2.4s streamed, and a 300s ceiling took chapter 11 of 《渊雨浩劫》 down
    // six times in a row.
    let requestedStream = request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
    guard requestedStream == response.stream, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    let contentType = response.statusCode == 200 && response.stream
      ? "text/event-stream"
      : "application/json"
    let headers = ["Content-Type": contentType]
    let http = HTTPURLResponse(
      url: url,
      statusCode: response.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    let data: Data
    if response.statusCode != 200 {
      data = try! JSONSerialization.data(withJSONObject: [
        "error": ["message": response.content],
      ])
    } else if response.stream {
      let payload: [String: Any] = [
        "choices": [["delta": ["content": response.content], "finish_reason": "stop"]],
      ]
      let encoded = try! JSONSerialization.data(withJSONObject: payload)
      let line = String(data: encoded, encoding: .utf8)!
      data = Data("data: \(line)\n\ndata: [DONE]\n\n".utf8)
    } else {
      let payload: [String: Any] = [
        "choices": [["message": ["content": response.content], "finish_reason": "stop"]],
      ]
      data = try! JSONSerialization.data(withJSONObject: payload)
    }
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func nextResponse() -> AutomatedRevisionStubResponse? {
    responseLock.lock()
    defer { responseLock.unlock() }
    servedCount += 1
    guard !responses.isEmpty else { return nil }
    return responses.removeFirst()
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
      protagonistProfile: "测试员：谨慎固执，压力下先列清单再行动，累极了会说反话自嘲；缺陷是不肯求助。",
      protagonistReviewed: true,
      worldbuilding: "所有设定均遵循确定性测试规则。",
      outline: "第一卷建立目标，第二卷完成回收。",
      volumePlan: "第一卷1-5章；第二卷6-10章。",
      pacing: "每章推进一个明确目标。",
      style: "第三人称有限视角。",
      constraints: "角色姓名保持一致\n时间线严格递增"
    )

    // LLM 生成的主角性格未经人工确认时，创建必须被拒绝。
    var unreviewed = request
    unreviewed.protagonistReviewed = false
    var unreviewedRejected = false
    do {
      _ = try await core.createBook(unreviewed)
    } catch {
      unreviewedRejected = true
    }
    precondition(unreviewedRejected, "unreviewed protagonist profile must block book creation")

    let creation = try await core.createBook(request)
    precondition(creation.status == "success")

    let books = try await core.fetchBooks()
    precondition(books.count == 1)
    precondition(books[0].title == request.title)

    // 主角性格档案必须落盘并进入章节上下文。
    let protagonistSetting = try await core.fetchBookSetting(bookID: books[0].id, path: "protagonist.md")
    precondition(protagonistSetting.contains("不肯求助"))
    let context = try await core.storyContext(bookID: books[0].id, maxCharacters: 60_000)
    precondition(context.contains("不肯求助"))

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

    try await assertSettingsRestoreKeepsRuntime(core: core, bookID: books[0].id, root: root)

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

    let aliasedEntityTypes = try await core.normalizedConsistencyDelta([
      "upsert": [
        "immutableCanon": [], "worldRules": [],
        "entities": [
          ["id": "alias-item", "name": "应急药箱", "type": "item"],
          ["id": "alias-object-cn", "name": "矿泉水储备", "type": "物品"],
          ["id": "alias-place", "name": "地下车库", "type": "place"],
        ],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
      "remove": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
    ], chapterNumber: 3)
    precondition(aliasedEntityTypes.upsert.entities.map(\.type) == ["object", "object", "location"])

    var invalidEntityTypeRejected = false
    do {
      _ = try await core.normalizedConsistencyDelta([
        "upsert": [
          "immutableCanon": [], "worldRules": [],
          "entities": [["id": "invalid-type", "name": "未知实体", "type": "misc"]],
          "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
        "remove": [
          "immutableCanon": [], "worldRules": [], "entities": [],
          "knowledgeBoundaries": [], "timeline": [], "hooks": [],
        ],
      ], chapterNumber: 3)
    } catch {
      invalidEntityTypeRejected = true
    }
    precondition(invalidEntityTypeRejected, "unknown entity types must not silently become character")

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

    try await core.validateChapterCraft(
      "所有屏幕同时闪出倒计时乱码，他的后颈发麻，耳边像有人翻过一页书。",
      chapterNumber: 1,
      label: "正文"
    )

    try await core.validateChapterCraft(
      String(repeating: "第三章只推进眼前冲突。", count: 40),
      chapterNumber: 3,
      label: "正文",
      openingContext: "第一章所有屏幕同时闪出倒计时乱码。"
    )

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
      protagonistProfile: "记录员：刻板守时，压力下先核对表格再行动；缺陷是过度依赖流程。",
      protagonistReviewed: true,
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

    do {
      let automaticRoot = root.appendingPathComponent("automatic-revision", isDirectory: true)
      let automaticCore = InkOSCore(rootURL: automaticRoot)
      let config: [String: Any] = [
        "provider": "openai",
        "model": "writer-test",
        "reviewModel": "reviewer-test",
        "baseUrl": "http://127.0.0.1:8765/v1",
        "reviewBaseUrl": "http://127.0.0.1:8765/v1",
        "apiKey": "test-key",
        "reviewApiKey": "test-key",
        "stream": false,
        "thinkingBudget": 0,
        "apiFormat": "chat",
      ]
      let configData = try JSONSerialization.data(withJSONObject: config)
      try configData.write(to: automaticRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

      let chapterPayload: [String: Any] = [
        "title": "异常倒数",
        "content": String(repeating: "雨夜窗外浮出异常裂缝，钥匙突然发烫，门后传来倒数声。", count: 39),
        "summary": "主角发现门后的异常倒数。",
        "consistencyDelta": [
          "upsert": [
            "immutableCanon": [], "worldRules": [], "entities": [],
            "knowledgeBoundaries": [], "timeline": [], "hooks": [],
          ],
          "remove": [
            "immutableCanon": [], "worldRules": [], "entities": [],
            "knowledgeBoundaries": [], "timeline": [], "hooks": [],
          ],
        ],
      ]
      let chapterPayloadText = String(data: try JSONSerialization.data(withJSONObject: chapterPayload), encoding: .utf8)!
      let beatResponse = """
        {"beats":[{"number":1,"volumeNumber":1,"goal":"确认门后倒数的来源","openingHook":"钥匙突然发烫","scenes":["走廊发现裂缝"],"requiredEvents":["主角发现异常裂缝"],"forbiddenElements":["不得打开门后世界"],"endingHook":"倒数声突然加快","focusCharacters":["主角"],"newNamedCharacters":0,"timeSpan":"半夜","setback":"钥匙失控发烫","notes":"只推进异常发现"}]}
        """
      let failedReview = """
        {"pass":false,"summary":"初稿存在硬连续性问题","issues":["[hard] 门后倒数声的来源需要在 Delta 中说明"],"revisionGuidance":"补全正文与 consistencyDelta 对异常倒数的来源和影响。"}
        """
      let passedReview = """
        {"pass":true,"summary":"修订稿连续性通过","issues":["[soft] 一致性登记口径：候选Delta使用object，建议统一改回此前通过的item/物品口径"],"revisionGuidance":"将物品实体type统一改回此前审核通过的item。"}
        """
      let repairedDelta = """
        {"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"item-key","name":"发烫钥匙","type":"item"}],"knowledgeBoundaries":[],"timeline":[],"hooks":[{"hookId":"hook-countdown","description":"门后倒数来源待查","openFromChapter":1}]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}
        """
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: beatResponse, stream: true),
        AutomatedRevisionStubResponse(content: chapterPayloadText, stream: true),
        AutomatedRevisionStubResponse(content: failedReview, stream: true),
        AutomatedRevisionStubResponse(content: repairedDelta, stream: true),
        AutomatedRevisionStubResponse(content: passedReview, stream: true),
      ])
      URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
      defer {
        URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
        AutomatedRevisionLLMProtocol.configure([])
      }

      let automaticCreation = try await automaticCore.createBook(CreateBookRequest(
        title: "自动复审测试书",
        language: "zh",
        genre: "xuanhuan",
        platform: "tomato",
        targetChapters: 1,
        chapterWords: 1_000,
        totalWords: "1000",
        targetTotalWords: 1_000,
        volumeCount: 1,
        chapterWordTolerance: 10,
        premise: "验证初审失败后的自动修改闭环。",
        characters: "主角负责追查异常倒数。",
        protagonistProfile: "主角谨慎多疑，压力下会反复确认线索；缺陷是很难信任他人。",
        protagonistReviewed: true,
        worldbuilding: "异常裂缝会在雨夜出现。",
        outline: "第一章发现异常倒数。",
        volumePlan: "第一卷第1章。",
        pacing: "一章只推进异常发现。",
        style: "悬疑叙事。",
        constraints: "必须保留异常倒数。"
      ))
      _ = try await automaticCore.generateChapter(bookID: automaticCreation.title, guidance: nil)

      var completedJob: GenerationJob?
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: automaticCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == false {
          completedJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let completedJob else { preconditionFailure("自动复审任务未在预期时间内完成") }
      precondition(completedJob.phase == "ready-for-review")
      precondition(completedJob.error == nil)
      let automaticallyRevised = try await automaticCore.fetchChapter(
        bookID: automaticCreation.title,
        number: 1
      )
      precondition(automaticallyRevised.status == "pending_review")
      precondition(automaticallyRevised.llmReview?.isPassed == true)
      precondition(automaticallyRevised.llmReview?.autoFixed == true)
      precondition(automaticallyRevised.llmReview?.attempts?.count == 2)
      precondition(automaticallyRevised.llmReview?.craftAdvisoryList.isEmpty == true)
      precondition(automaticallyRevised.llmReview?.revisionGuidance?.isEmpty == true)
      precondition(automaticallyRevised.revisionHistory.count == 1)
      precondition(automaticallyRevised.revisionHistory[0].type == "delta_repair")
      precondition(automaticallyRevised.content == chapterPayload["content"] as? String)
      let repairedConsistency = try await automaticCore.chapterConsistencyDelta(
        bookID: automaticCreation.title,
        chapterNumber: 1
      )
      precondition(repairedConsistency.upsert.entities.first?.type == "object")

      let retainedPayload: [String: Any] = [
        "title": "平静夜归",
        "content": String(repeating: "他沿着街道走回家，吃饭后检查门窗，又把明日的工作安排记在心里。", count: 36),
        "summary": "主角平静度过回家后的夜晚。",
        "consistencyDelta": [
          "upsert": [
            "immutableCanon": [], "worldRules": [], "entities": [],
            "knowledgeBoundaries": [], "timeline": [], "hooks": [],
          ],
          "remove": [
            "immutableCanon": [], "worldRules": [], "entities": [],
            "knowledgeBoundaries": [], "timeline": [], "hooks": [],
          ],
        ],
      ]
      let retainedPayloadText = String(
        data: try JSONSerialization.data(withJSONObject: retainedPayload),
        encoding: .utf8
      )!
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: beatResponse, stream: true),
        AutomatedRevisionStubResponse(content: retainedPayloadText, stream: true),
      ])
      let retainedCreation = try await automaticCore.createBook(CreateBookRequest(
        title: "本地校验草稿保留测试书",
        language: "zh",
        genre: "xuanhuan",
        platform: "tomato",
        targetChapters: 1,
        chapterWords: 1_000,
        totalWords: "1000",
        targetTotalWords: 1_000,
        volumeCount: 1,
        chapterWordTolerance: 10,
        premise: "验证完整草稿未通过本地校验时仍然落盘。",
        characters: "主角正在度过普通的一天。",
        protagonistProfile: "主角谨慎严谨，习惯检查门窗；缺陷是忽略异常。",
        protagonistReviewed: true,
        worldbuilding: "异常会在后续雨夜出现。",
        outline: "第一章应当出现异常征兆。",
        volumePlan: "第一卷第1章。",
        pacing: "一章只推进一个问题。",
        style: "现实叙事。",
        constraints: "必须保留完整草稿。"
      ))
      _ = try await automaticCore.generateChapter(bookID: retainedCreation.title, guidance: nil)

      var retainedJob: GenerationJob?
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: retainedCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == false {
          retainedJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let retainedJob else { preconditionFailure("草稿保留任务未在预期时间内完成") }
      precondition(retainedJob.phase == "revision_failed")
      precondition(retainedJob.error?.contains("核心能力") == true)
      let retainedChapter = try await automaticCore.fetchChapter(
        bookID: retainedCreation.title,
        number: 1
      )
      precondition(retainedChapter.status == "revision_failed")
      precondition(retainedChapter.title == "平静夜归")
      precondition(retainedChapter.content == retainedPayload["content"] as? String)
      precondition(retainedChapter.llmReview?.model == "native-draft-validator")
      precondition(retainedChapter.llmReview?.attempts?.count == 1)

      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: retainedPayloadText, stream: true),
        AutomatedRevisionStubResponse(content: retainedPayloadText, stream: true),
      ])
      _ = try await automaticCore.reviseChapter(
        bookID: retainedCreation.title,
        number: 1,
        note: "保留完整正文，补足开篇异常锚点后重新审核。",
        mode: "rewrite"
      )
      var failedRevisionJob: GenerationJob?
      var sawActiveRevisionJob = false
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: retainedCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == true { sawActiveRevisionJob = true }
        if sawActiveRevisionJob, job?.isActive == false {
          failedRevisionJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let failedRevisionJob else {
        preconditionFailure("本地校验失败修订任务未在预期时间内完成")
      }
      precondition(failedRevisionJob.phase == "revision_failed")
      let failedRevisionChapter = try await automaticCore.fetchChapter(
        bookID: retainedCreation.title,
        number: 1
      )
      precondition(failedRevisionChapter.llmReview?.attempts?.count == 3)
      precondition(failedRevisionChapter.revisionHistory.count == 1)
      precondition(failedRevisionChapter.revisionHistory[0].success == false)
      precondition(failedRevisionChapter.revisionHistory[0].error?.contains("核心能力") == true)

      let pureDeltaReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "只缺少登记",
        issues: ["[hard] 门后倒数声需要在 Delta 中补充 hook 登记。"],
        revisionGuidance: "补充 hook 登记。"
      )
      let acceptsPureDeltaRepair = await automaticCore.shouldAttemptDeltaOnlyRepair(pureDeltaReview)
      precondition(acceptsPureDeltaRepair)
      let conflictingDeltaReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "正文与登记冲突",
        issues: ["[hard] consistencyDelta 与正文事实冲突，且违反不可变设定。"],
        revisionGuidance: "同步修正文与 Delta。"
      )
      let rejectsConflictingDeltaRepair = await automaticCore.shouldAttemptDeltaOnlyRepair(
        conflictingDeltaReview
      )
      precondition(!rejectsConflictingDeltaRepair)
      let typeOnlyDeltaReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "登记类型不一致",
        issues: ["[hard] Delta 实体类型与规范不一致，应统一为 object。"],
        revisionGuidance: "只修正实体类型。"
      )
      let acceptsTypeOnlyDeltaRepair = await automaticCore.shouldAttemptDeltaOnlyRepair(
        typeOnlyDeltaReview
      )
      precondition(acceptsTypeOnlyDeltaRepair)

      let revalidationCreation = try await automaticCore.createBook(CreateBookRequest(
        title: "原稿重校验测试书",
        language: "zh",
        genre: "xuanhuan",
        platform: "tomato",
        targetChapters: 1,
        chapterWords: 1_000,
        totalWords: "1000",
        targetTotalWords: 1_000,
        volumeCount: 1,
        chapterWordTolerance: 10,
        premise: "验证本地失败稿在规则更新后直接复审原文。",
        characters: "主角负责追查雨夜异常。",
        protagonistProfile: "主角谨慎敏锐，会反复核对异常；缺陷是过度怀疑自己的判断。",
        protagonistReviewed: true,
        worldbuilding: "雨夜会出现异常裂缝。",
        outline: "第一章发现异常裂缝。",
        volumePlan: "第一卷第1章。",
        pacing: "一章只推进异常发现。",
        style: "悬疑叙事。",
        constraints: "必须保留异常裂缝。"
      ))
      let revalidationContent = chapterPayload["content"] as! String
      let storedGuidance = "保留已生成的正文，按本地审核意见修改后重新提交审核。"
      let storedFailure: [String: Any] = [
        "status": "failed",
        "model": "native-draft-validator",
        "summary": "旧规则判定失败。",
        "issues": ["[hard] 本地章节规则：旧规则要求重复能力锚点。"],
        "revisionGuidance": storedGuidance,
        "reviewedAt": isoTimestamp(),
        "attempts": [[
          "pass": false,
          "status": "failed",
          "attempt": 1,
          "model": "native-draft-validator",
          "summary": "旧规则判定失败。",
          "issues": ["[hard] 本地章节规则：旧规则要求重复能力锚点。"],
          "revisionGuidance": storedGuidance,
          "reviewedAt": isoTimestamp(),
        ]],
      ]
      try await automaticCore.writeChapter(
        bookID: revalidationCreation.title,
        number: 1,
        title: "原稿复审",
        content: revalidationContent,
        status: "revision_failed",
        llmReview: storedFailure
      )
      try await automaticCore.persistConsistencyDelta(
        bookID: revalidationCreation.title,
        chapterNumber: 1,
        title: "原稿复审",
        summary: "原稿保留测试。",
        delta: chapterPayload["consistencyDelta"] as! [String: Any]
      )
      let simplePassedReview = """
        {"pass":true,"summary":"原稿复审通过","issues":[],"revisionGuidance":""}
        """
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: simplePassedReview, stream: true),
      ])
      _ = try await automaticCore.reviseChapter(
        bookID: revalidationCreation.title,
        number: 1,
        note: storedGuidance,
        mode: "rewrite"
      )
      var revalidationJob: GenerationJob?
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: revalidationCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == false {
          revalidationJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let completedRevalidationJob = revalidationJob else {
        preconditionFailure("原稿重校验任务未完成")
      }
      precondition(completedRevalidationJob.phase == "ready-for-review")
      precondition(completedRevalidationJob.message?.contains("未执行重写") == true)
      let revalidatedChapter = try await automaticCore.fetchChapter(
        bookID: revalidationCreation.title,
        number: 1
      )
      precondition(revalidatedChapter.status == "pending_review")
      precondition(revalidatedChapter.content == revalidationContent)
      precondition(revalidatedChapter.llmReview?.attempts?.map(\.attempt) == [1, 2])
      precondition(revalidatedChapter.revisionHistory.last?.type == "revalidation")

      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: chapterPayloadText, stream: true),
        AutomatedRevisionStubResponse(content: simplePassedReview, stream: true),
      ])
      _ = try await automaticCore.reviseChapter(
        bookID: revalidationCreation.title,
        number: 1,
        note: "只调整措辞并重新审核。",
        mode: "rewrite"
      )
      var appendedHistoryJob: GenerationJob?
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: revalidationCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == false {
          appendedHistoryJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let appendedHistoryJob else { preconditionFailure("历史追加修订任务未完成") }
      precondition(appendedHistoryJob.phase == "ready-for-review")
      let appendedHistoryChapter = try await automaticCore.fetchChapter(
        bookID: revalidationCreation.title,
        number: 1
      )
      precondition(appendedHistoryChapter.llmReview?.attempts?.map(\.attempt) == [1, 2, 3])

      let changedRevisionContent = String(
        repeating: "雨夜窗外的异常裂缝再次亮起，发烫钥匙在掌心刻出新的倒数数字。",
        count: 36
      )
      var changedRevisionPayload = chapterPayload
      changedRevisionPayload["title"] = "倒数变更"
      changedRevisionPayload["content"] = changedRevisionContent
      let changedRevisionPayloadText = String(
        data: try JSONSerialization.data(withJSONObject: changedRevisionPayload),
        encoding: .utf8
      )!
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: changedRevisionPayloadText, stream: true),
        AutomatedRevisionStubResponse(content: failedReview, stream: true),
        AutomatedRevisionStubResponse(content: "第二轮模拟失败", stream: true, statusCode: 400),
      ])
      _ = try await automaticCore.reviseChapter(
        bookID: revalidationCreation.title,
        number: 1,
        note: "验证后一轮异常仍保存完整审核历史。",
        mode: "rewrite"
      )
      var mixedFailureJob: GenerationJob?
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: revalidationCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == false {
          mixedFailureJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let mixedFailureJob else { preconditionFailure("混合失败修订任务未完成") }
      precondition(mixedFailureJob.phase == "revision_failed")
      precondition(mixedFailureJob.error?.contains("第二轮模拟失败") == true)
      precondition(mixedFailureJob.attempts?.map(\.attempt) == [1, 2, 3, 4, 5])
      let mixedFailureChapter = try await automaticCore.fetchChapter(
        bookID: revalidationCreation.title,
        number: 1
      )
      precondition(mixedFailureChapter.status == "revision_failed")
      precondition(mixedFailureChapter.title == "倒数变更")
      precondition(mixedFailureChapter.content == changedRevisionContent)
      precondition(mixedFailureChapter.llmReview?.attempts?.map(\.attempt) == [1, 2, 3, 4, 5])
      precondition(mixedFailureChapter.llmReview?.rewriteError?.contains("第二轮模拟失败") == true)

      // 渊雨浩劫 第五章回归：写作模型返回完整正文，但 JSON 外壳/Delta 损坏。
      // 完整正文必须被保留，只补 Delta，不得重新生成整章。
      let recoverableProse = String(
        repeating: "雨水顺着排水口倒灌回来，他数着货架上剩下的罐头，把最后一箱矿泉水搬进储物间。",
        count: 40
      )
      let brokenShell = "{\"title\":\"现金\",\"content\":\""
        + recoverableProse.replacingOccurrences(of: "\n", with: "\\n")
        + "\",\"summary\":\"主角在断货前抢购物资。\","
        + "\"consistencyDelta\":{\"upsert\":{\"entities\":[{\"id\":\"item-cash\"}],\"source\":\"第5"
      let brokenShellParsed = await automaticCore.parseJSONObject(brokenShell)
      precondition(brokenShellParsed == nil)
      guard let recoveredProse = await automaticCore.recoverCompleteChapterProse(
        from: brokenShell,
        chapterNumber: 5
      ) else { preconditionFailure("损坏外壳中的完整正文未被恢复") }
      precondition(recoveredProse["title"] as? String == "现金")
      precondition(recoveredProse["content"] as? String == recoverableProse)
      precondition(recoveredProse["summary"] as? String == "主角在断货前抢购物资。")
      precondition(recoveredProse["consistencyDelta"] == nil)

      // 正文里模型输出的裸引号不得被当成字段结束。
      let bareQuoteProse = "他抬头说\"水停了\"，随后又补一句\"别开门\"，雨声盖住了回答。"
      let bareQuoteShell = "{\"content\":\"" + bareQuoteProse + "\",\"summary\":\"对话片段。\","
      let bareQuoteParsed = await automaticCore.parseJSONObject(bareQuoteShell)
      precondition(bareQuoteParsed == nil)
      let bareQuoteRecovered = await automaticCore.extractedJSONStringField(
        "content",
        from: bareQuoteShell
      )
      precondition(bareQuoteRecovered == bareQuoteProse)

      // 正文在字符串中途被截断时不得恢复。
      let truncatedShell = "{\"title\":\"现金\",\"content\":\"" + recoverableProse
      let truncatedRecovered = await automaticCore.recoverCompleteChapterProse(
        from: truncatedShell,
        chapterNumber: 5
      )
      precondition(truncatedRecovered == nil)
      // 结束引号后没有任何分隔符时同样无法确认闭合。
      let danglingQuoteRecovered = await automaticCore.extractedJSONStringField(
        "content",
        from: "{\"content\":\"" + recoverableProse + "\""
      )
      precondition(danglingQuoteRecovered == nil)
      // 流式预览仍然可以读到未闭合的正文。
      let previewRecovered = await automaticCore.extractedJSONStringField(
        "content",
        from: truncatedShell,
        requireTerminator: false
      )
      precondition(previewRecovered == recoverableProse)

      // 端到端：第一次损坏外壳 + 完整正文，第二次只补 Delta，总共两次请求。
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: brokenShell, stream: true),
        AutomatedRevisionStubResponse(content: repairedDelta, stream: true),
      ])
      let recoveryCollector = NativeStreamCollector()
      let recoveryPayload = try await automaticCore.requestChapterPayload(
        prompt: "生成第5章",
        chapterNumber: 5,
        requireDelta: true,
        timeout: 60,
        onPartialContent: { partial in
          await recoveryCollector.accept(partial)
        }
      )
      precondition(recoveryPayload.object["title"] as? String == "现金")
      precondition(recoveryPayload.object["content"] as? String == recoverableProse)
      precondition(recoveryPayload.object["summary"] as? String == "主角在断货前抢购物资。")
      let recoveredDelta = recoveryPayload.object["consistencyDelta"] as? [String: Any]
      precondition(recoveredDelta != nil)
      precondition((recoveredDelta?["upsert"] as? [String: Any])?["entities"] != nil)
      precondition(AutomatedRevisionLLMProtocol.requestCount() == 2)
      let recoveryEvents = try await automaticCore.fetchDebugEvents(limit: 5_000).events
      let recoveryMessages = recoveryEvents.suffix(40).map(\.message)
      precondition(recoveryMessages.contains("chapter.invalidJson"))
      precondition(recoveryMessages.contains("chapter.proseRecovered"))
      precondition(recoveryMessages.contains("chapter.deltaRepair.started"))
      precondition(recoveryMessages.contains("chapter.deltaRepair.completed"))

      // Delta 补登失败时必须记下真实原因。三种失败各自可分辨，否则线上只能
      // 从调用方那句“自动补登后仍缺失”反推（第8章就是这么排查的）。
      // 用 400（非 transient）避免触发 requestLLM 的重试退避拖慢测试。
      func deltaRepairFailureReason(
        _ repairResponse: AutomatedRevisionStubResponse,
        chapterNumber: Int
      ) async throws -> (reason: String, object: [String: Any]) {
        AutomatedRevisionLLMProtocol.configure([
          AutomatedRevisionStubResponse(content: brokenShell, stream: true),
          repairResponse,
        ])
        let payload = try await automaticCore.requestChapterPayload(
          prompt: "生成第\(chapterNumber)章",
          chapterNumber: chapterNumber,
          requireDelta: true,
          timeout: 60,
          onPartialContent: { _ in }
        )
        let events = try await automaticCore.fetchDebugEvents(limit: 5_000).events
        guard let failure = events.last(where: { $0.message == "chapter.deltaRepair.failed" })
        else { preconditionFailure("Delta 补登失败未记录事件（第\(chapterNumber)章）") }
        guard case .string(let reason)? = failure.data["reason"] else {
          preconditionFailure("Delta 补登失败事件缺少 reason（第\(chapterNumber)章）")
        }
        return (reason, payload.object)
      }

      let requestFailed = try await deltaRepairFailureReason(
        AutomatedRevisionStubResponse(content: "补登请求失败", stream: true, statusCode: 400),
        chapterNumber: 101
      )
      precondition(requestFailed.reason == "requestFailed")
      // 补登失败不得连带丢掉已恢复的正文。
      precondition(requestFailed.object["content"] as? String == recoverableProse)
      precondition(requestFailed.object["consistencyDelta"] == nil)

      let repairInvalidJSON = try await deltaRepairFailureReason(
        AutomatedRevisionStubResponse(content: "这不是 JSON", stream: true),
        chapterNumber: 102
      )
      precondition(repairInvalidJSON.reason == "invalidJson")
      precondition(repairInvalidJSON.object["content"] as? String == recoverableProse)

      let repairMissingField = try await deltaRepairFailureReason(
        AutomatedRevisionStubResponse(content: "{\"note\":\"没有 delta\"}", stream: true),
        chapterNumber: 103
      )
      precondition(repairMissingField.reason == "missingDeltaField")
      precondition(repairMissingField.object["content"] as? String == recoverableProse)

      // 第8章真实状态回归：正文已恢复落盘，但 Delta 补登失败，因此
      // story/runtime 里没有一致性文件。复校验过去会在读取 Delta 处抛错，
      // 于是 deltaRepairReview 为 nil，整章被重写，恢复出来的正文白扔。
      // 现在缺失的 Delta 按空值起步，复校验能正常复审原文。
      let missingDeltaCreation = try await automaticCore.createBook(CreateBookRequest(
        title: "缺少一致性文件复校验测试书",
        language: "zh",
        genre: "xuanhuan",
        platform: "tomato",
        targetChapters: 1,
        chapterWords: 1_000,
        totalWords: "1000",
        targetTotalWords: 1_000,
        volumeCount: 1,
        chapterWordTolerance: 10,
        premise: "验证没有一致性文件的草稿仍可复审原文。",
        characters: "主角负责追查雨夜异常。",
        protagonistProfile: "主角谨慎敏锐，会反复核对异常；缺陷是过度怀疑自己的判断。",
        protagonistReviewed: true,
        worldbuilding: "雨夜会出现异常裂缝。",
        outline: "第一章发现异常裂缝。",
        volumePlan: "第一卷第1章。",
        pacing: "一章只推进异常发现。",
        style: "悬疑叙事。",
        constraints: "必须保留异常裂缝。"
      ))
      let missingDeltaGuidance = "保留已生成的正文，按本地审核意见修改后重新提交审核。"
      let missingDeltaIssue = "[hard] 本地章节规则：模型未返回 consistencyDelta（自动补登后仍缺失）"
      try await automaticCore.writeChapter(
        bookID: missingDeltaCreation.title,
        number: 1,
        title: "先保哪一样",
        content: chapterPayload["content"] as! String,
        status: "revision_failed",
        llmReview: [
          "status": "failed",
          "model": "native-draft-validator",
          "summary": "本地校验失败：缺少一致性登记。",
          "issues": [missingDeltaIssue],
          "revisionGuidance": missingDeltaGuidance,
          "reviewedAt": isoTimestamp(),
          "attempts": [[
            "pass": false,
            "status": "failed",
            "attempt": 1,
            "model": "native-draft-validator",
            "summary": "本地校验失败：缺少一致性登记。",
            "issues": [missingDeltaIssue],
            "revisionGuidance": missingDeltaGuidance,
            "reviewedAt": isoTimestamp(),
          ]],
        ]
      )
      // 刻意不调 persistConsistencyDelta —— 复现 rawDelta 为 nil 时不写文件的现场。
      do {
        _ = try await automaticCore.chapterConsistencyDelta(
          bookID: missingDeltaCreation.title,
          chapterNumber: 1
        )
        preconditionFailure("测试前置条件错误：本章不应存在一致性文件")
      } catch {}

      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: simplePassedReview, stream: true),
      ])
      _ = try await automaticCore.reviseChapter(
        bookID: missingDeltaCreation.title,
        number: 1,
        note: missingDeltaGuidance,
        mode: "rewrite"
      )
      var missingDeltaJob: GenerationJob?
      for _ in 0..<100 {
        let job = try await automaticCore.fetchGenerationJob(
          bookID: missingDeltaCreation.title,
          chapterNumber: 1
        ).job
        if job?.isActive == false {
          missingDeltaJob = job
          break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      guard let missingDeltaJob else { preconditionFailure("缺少一致性文件的复校验任务未完成") }
      // 复审原文通过，正文未被重写：只消耗了那一次复审请求。
      precondition(missingDeltaJob.phase == "ready-for-review")
      precondition(missingDeltaJob.message?.contains("未执行重写") == true)
      precondition(AutomatedRevisionLLMProtocol.requestCount() == 1)
      let missingDeltaChapter = try await automaticCore.fetchChapter(
        bookID: missingDeltaCreation.title,
        number: 1
      )
      precondition(missingDeltaChapter.status == "pending_review")
      precondition(missingDeltaChapter.content == chapterPayload["content"] as? String)
      let missingDeltaEvents = try await automaticCore.fetchDebugEvents(limit: 5_000).events
      precondition(
        missingDeltaEvents.suffix(40).contains { $0.message == "chapter.delta.missingForRepair" }
      )
    }

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
      // LLM 必须产出主角性格档案，且必须标记为未审核——创建前由人工确认。
      precondition(!assisted.payload.protagonistProfile.isEmpty)
      precondition(assisted.payload.protagonistReviewed == false)
      var reviewedPayload = assisted.payload
      reviewedPayload.protagonistReviewed = true
      let guidedCreation = try await core.createBook(reviewedPayload)
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

  /// A settings backup must not carry `story/runtime`, and restoring one must not
  /// roll it back.
  ///
  /// Backup used to copy all of `story/` and restore replaced the whole
  /// directory, so recovering a text edit deleted the consistency delta of every
  /// chapter approved since the backup — those chapters stay `approved` while
  /// their facts silently leave the continuity index. Asserts on the delta files
  /// directly: the plan alone would not show the loss until the next projection.
  private static func assertSettingsRestoreKeepsRuntime(
    core: InkOSCore,
    bookID: String,
    root: URL
  ) async throws {
    let fileManager = FileManager.default
    let runtime = root
      .appendingPathComponent("book/books/\(bookID)/story/runtime", isDirectory: true)
    let deltaOne = runtime.appendingPathComponent("chapter-0001.consistency.json")
    precondition(
      fileManager.fileExists(atPath: deltaOne.path),
      "前置条件不成立：第 1 章的 consistency delta 应已落盘"
    )

    let rulesBefore = try await core.fetchBookSetting(bookID: bookID, path: "book_rules.md")
    _ = try await core.saveBookSetting(
      bookID: bookID,
      path: "book_rules.md",
      content: rulesBefore + "\n备份点之后要被回滚的一行。\n"
    )
    let backups = try await core.fetchBookSettingsBackups(bookID: bookID)
    guard let newest = backups.backups.first else {
      preconditionFailure("保存设定后应产生备份")
    }

    // The backup itself must already exclude runtime.
    let backedUpRuntime = URL(fileURLWithPath: newest.dir, isDirectory: true)
      .appendingPathComponent("runtime", isDirectory: true)
    precondition(
      !fileManager.fileExists(atPath: backedUpRuntime.path),
      "设定备份不应包含 story/runtime：\(backedUpRuntime.path)"
    )

    // Runtime grows past the backup: a second chapter's delta lands after it.
    let body = String(repeating: "备份点之后写入的正文。", count: 80)
    try await core.writeChapter(
      bookID: bookID,
      number: 2,
      title: "备份点之后",
      content: body,
      status: "pending_review"
    )
    try await core.persistConsistencyDelta(
      bookID: bookID,
      chapterNumber: 2,
      title: "备份点之后",
      summary: "验证恢复设定不回滚 runtime。",
      delta: [
        "upsert": [
          "entities": [[
            "id": "entity-after-backup", "name": "备份后角色", "type": "character",
          ]],
        ],
        "remove": [:],
      ]
    )
    let deltaTwo = runtime.appendingPathComponent("chapter-0002.consistency.json")
    precondition(fileManager.fileExists(atPath: deltaTwo.path))

    let restore = try await core.restoreBookSettings(bookID: bookID, backupID: newest.backupId)
    precondition(restore.ok)

    // The edit rolled back …
    let rulesAfter = try await core.fetchBookSetting(bookID: bookID, path: "book_rules.md")
    precondition(rulesAfter == rulesBefore, "恢复应回滚 book_rules.md 的改动")
    // … and every runtime delta survived, including the one written after it.
    precondition(
      fileManager.fileExists(atPath: deltaOne.path),
      "恢复设定删除了第 1 章的 consistency delta"
    )
    precondition(
      fileManager.fileExists(atPath: deltaTwo.path),
      "恢复设定删除了备份点之后写入的第 2 章 consistency delta"
    )

    // Clean up so the caller's later chapter-2 cases start from a known state.
    try? fileManager.removeItem(at: deltaTwo)
  }
}
