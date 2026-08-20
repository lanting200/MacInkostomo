import Foundation
import Darwin
import SQLite3

private func passedLLMReviewFixture(_ summary: String = "独立审核通过。") -> [String: Any] {
  let reviewedAt = isoTimestamp()
  return [
    "status": "passed",
    "model": "fixture-review",
    "summary": summary,
    "issues": [],
    "reviewedAt": reviewedAt,
    "attempts": [[
      "pass": true,
      "status": "passed",
      "attempt": 1,
      "model": "fixture-review",
      "summary": summary,
      "issues": [],
      "reviewedAt": reviewedAt,
    ]],
  ]
}

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

actor CanonProgressCollector {
  private var statuses: [SourceCanonStatus] = []

  func accept(_ status: SourceCanonStatus) {
    statuses.append(status)
  }

  func snapshot() -> [SourceCanonStatus] {
    statuses
  }
}

actor ImportProgressCollector {
  private var phases: [SourceImportProgress.Phase] = []

  func accept(_ progress: SourceImportProgress) {
    if phases.last != progress.phase {
      phases.append(progress.phase)
    }
  }

  func snapshot() -> [SourceImportProgress.Phase] {
    phases
  }
}

private struct AutomatedRevisionStubResponse {
  let content: String
  let stream: Bool
  let statusCode: Int
  /// Emitted verbatim as `finish_reason`. `length` plus an empty `content` is how
  /// a relay reports a reasoning model that spent the whole `max_tokens` budget
  /// thinking, which must not be retried.
  let finishReason: String
  /// Emitted as `reasoning_content` alongside an empty `content`.
  let reasoningContent: String
  /// Raw JSON body, bypassing the envelope below. Lets a fixture assert on an
  /// error shape the relay actually sends, such as `model_not_found`.
  let rawBody: String?
  /// Hold this response after the request has been observed. This gives race
  /// tests a deterministic window to invalidate beats while the planner is in
  /// its suspended LLM call.
  let waitForRelease: Bool
  /// Routes concurrent fixtures by their prompt instead of relying on request
  /// arrival order, which is deliberately unspecified once calls overlap.
  let promptContains: String?

  init(
    content: String,
    stream: Bool,
    statusCode: Int = 200,
    finishReason: String = "stop",
    reasoningContent: String = "",
    rawBody: String? = nil,
    waitForRelease: Bool = false,
    promptContains: String? = nil
  ) {
    self.content = content
    self.stream = stream
    self.statusCode = statusCode
    self.finishReason = finishReason
    self.reasoningContent = reasoningContent
    self.rawBody = rawBody
    self.waitForRelease = waitForRelease
    self.promptContains = promptContains
  }
}

private final class AutomatedRevisionLLMProtocol: URLProtocol {
  private static let responseLock = NSLock()
  private static var responses: [AutomatedRevisionStubResponse] = []
  private static var servedCount = 0
  private static var maxTokensSeen: [Int?] = []
  private static var promptsSeen: [String] = []
  private static let releaseCondition = NSCondition()
  private static var blockedResponseReleased = false

  static func configure(_ queuedResponses: [AutomatedRevisionStubResponse]) {
    responseLock.lock()
    responses = queuedResponses
    servedCount = 0
    maxTokensSeen = []
    promptsSeen = []
    responseLock.unlock()
    releaseCondition.lock()
    blockedResponseReleased = false
    releaseCondition.unlock()
  }

  static func releaseBlockedResponse() {
    releaseCondition.lock()
    blockedResponseReleased = true
    releaseCondition.broadcast()
    releaseCondition.unlock()
  }

  /// Number of requests the core has issued since the last `configure`, so a
  /// test can assert a recovery path did not spend a second full chapter call.
  static func requestCount() -> Int {
    responseLock.lock()
    defer { responseLock.unlock() }
    return servedCount
  }

  /// `max_tokens` from each request body, in order.
  ///
  /// The retry that recovers from an empty completion works by *raising* this, so
  /// a test asserting only the request count would pass against a build that
  /// retried at the identical ceiling — which is exactly the bug that burned three
  /// attempts on chapter 1 of 《灰雾之前》.
  static func observedMaxTokens() -> [Int?] {
    responseLock.lock()
    defer { responseLock.unlock() }
    return maxTokensSeen
  }

  static func observedPrompts() -> [String] {
    responseLock.lock()
    defer { responseLock.unlock() }
    return promptsSeen
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1" && request.url?.path.hasSuffix("/chat/completions") == true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let prompt = Self.recordRequest(from: request)
    let response = Self.nextResponse(matching: prompt)
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

    if response.waitForRelease {
      // Returning from `startLoading` lets URLSession start the other concurrent
      // fixture. The previous synchronous wait serialized the test transport
      // itself, so it could never observe two in-flight requests even when the
      // production tasks had already been created together.
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        Self.waitForBlockedResponseRelease()
        self?.deliver(response, url: url)
      }
      return
    }
    deliver(response, url: url)
  }

  private func deliver(_ response: AutomatedRevisionStubResponse, url: URL) {
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
    if let rawBody = response.rawBody {
      data = Data(rawBody.utf8)
    } else if response.statusCode != 200 {
      data = try! JSONSerialization.data(withJSONObject: [
        "error": ["message": response.content],
      ])
    } else if response.stream {
      var delta: [String: Any] = ["content": response.content]
      if !response.reasoningContent.isEmpty {
        delta["reasoning_content"] = response.reasoningContent
      }
      let payload: [String: Any] = [
        "choices": [["delta": delta, "finish_reason": response.finishReason]],
      ]
      let encoded = try! JSONSerialization.data(withJSONObject: payload)
      let line = String(data: encoded, encoding: .utf8)!
      data = Data("data: \(line)\n\ndata: [DONE]\n\n".utf8)
    } else {
      var message: [String: Any] = ["content": response.content]
      if !response.reasoningContent.isEmpty {
        message["reasoning_content"] = response.reasoningContent
      }
      let payload: [String: Any] = [
        "choices": [["message": message, "finish_reason": response.finishReason]],
      ]
      data = try! JSONSerialization.data(withJSONObject: payload)
    }
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func waitForBlockedResponseRelease() {
    releaseCondition.lock()
    while !blockedResponseReleased {
      releaseCondition.wait()
    }
    releaseCondition.unlock()
  }

  private static func nextResponse(matching prompt: String) -> AutomatedRevisionStubResponse? {
    responseLock.lock()
    defer { responseLock.unlock() }
    servedCount += 1
    if let index = responses.firstIndex(where: {
      $0.promptContains.map(prompt.contains) == true
    }) {
      return responses.remove(at: index)
    }
    guard let fallback = responses.firstIndex(where: { $0.promptContains == nil }) else {
      return nil
    }
    return responses.remove(at: fallback)
  }

  /// `URLProtocol` hands back `httpBodyStream` rather than `httpBody` once the
  /// session has taken the request, so the body has to be drained from the stream.
  private static func recordRequest(from request: URLRequest) -> String {
    var body = request.httpBody
    if body == nil, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var collected = Data()
      var buffer = [UInt8](repeating: 0, count: 8_192)
      while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        collected.append(contentsOf: buffer[0..<read])
      }
      body = collected
    }
    let object = body
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let value = object.flatMap { ($0["max_tokens"] as? NSNumber)?.intValue }
    let prompt = (object?["messages"] as? [[String: Any]])?
      .compactMap { $0["content"] as? String }
      .joined(separator: "\n") ?? ""
    responseLock.lock()
    maxTokensSeen.append(value)
    promptsSeen.append(prompt)
    responseLock.unlock()
    return prompt
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

    if ProcessInfo.processInfo.environment["MACINKOSTOMO_DERIVATIVE_ONLY"] == "1" {
      try await assertDerivativeRetrievalWorks(root: root)
      print("Native derivative ingest/retrieval smoke test passed")
      return
    }
    if ProcessInfo.processInfo.environment["MACINKOSTOMO_BEAT_PREFETCH_ONLY"] == "1" {
      try await assertInvalidationFencesInFlightBeatPrefetch(root: root)
      print("Native beat-prefetch invalidation smoke test passed")
      return
    }

    let core = InkOSCore(rootURL: root)
    try await assertExplicitWorkspaceIsIsolated(root: root)
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
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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
    let beatsURL = root.appendingPathComponent(
      "book/books/\(books[0].id)/story/runtime/chapter-beats.json"
    )
    let seededBeats = ChapterBeatPlan(
      bookId: books[0].id,
      beats: (1...4).map {
        ChapterBeat(number: $0, goal: "第\($0)章目标", scenes: ["第\($0)章场景"])
      },
      batches: [ChapterBeatBatch(
        startChapter: 1,
        endChapter: 4,
        volumeNumber: 1,
        planRevision: plan.revision,
        generatedAt: isoTimestamp(),
        model: "fixture"
      )],
      updatedAt: isoTimestamp()
    )
    try JSONEncoder().encode(seededBeats).write(to: beatsURL, options: .atomic)
    _ = try await core.approveChapter(bookID: books[0].id, number: 1)
    let afterFirstApprovalBeats = try await core.fetchChapterBeats(bookID: books[0].id)
    precondition(
      afterFirstApprovalBeats.beats.map(\.number) == [1],
      "首次批准必须保留当前节拍并清除未来节拍：\(afterFirstApprovalBeats.beats.map(\.number))"
    )
    let migratedPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(migratedPlan.continuity.policy.requireConsistencyDelta)
    precondition(migratedPlan.continuity.immutableCanon.count == 1)
    precondition(migratedPlan.continuity.worldRules.count == 1)
    precondition(migratedPlan.continuity.entities.count == 2)
    precondition(migratedPlan.continuity.knowledgeBoundaries.count == 1)
    precondition(migratedPlan.continuity.timeline.count == 1)
    precondition(migratedPlan.continuity.hooks.count == 1)

    let migratedRevision = migratedPlan.revision
    try JSONEncoder().encode(seededBeats).write(to: beatsURL, options: .atomic)
    _ = try await core.approveChapter(bookID: books[0].id, number: 1)
    let duplicateApprovalPlan = try await core.fetchLongFormPlan(bookID: books[0].id)
    precondition(duplicateApprovalPlan.revision == migratedRevision)
    let afterDuplicateApprovalBeats = try await core.fetchChapterBeats(bookID: books[0].id)
    precondition(
      afterDuplicateApprovalBeats.beats.map(\.number) == [1, 2, 3, 4],
      "重复批准必须保持幂等，不得删除未来节拍：\(afterDuplicateApprovalBeats.beats.map(\.number))"
    )

    try await assertSettingsRestoreKeepsRuntime(core: core, bookID: books[0].id, root: root)

    try await core.writeChapter(
      bookID: books[0].id,
      number: 1,
      title: "新格式替换",
      content: chapterBody,
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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
    try JSONEncoder().encode(seededBeats).write(to: beatsURL, options: .atomic)
    _ = try await core.approveChapter(bookID: books[0].id, number: 2)
    let afterSecondApprovalBeats = try await core.fetchChapterBeats(bookID: books[0].id)
    precondition(
      afterSecondApprovalBeats.beats.map(\.number) == [1, 2],
      "新批准必须只保留当前及过去节拍：\(afterSecondApprovalBeats.beats.map(\.number))"
    )
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

    // The approval idempotency fixture above deliberately leaves historical
    // beats in place. Reset this independent craft fixture to its intended empty
    // starting state.
    _ = try await core.invalidateChapterBeats(bookID: books[0].id, fromChapter: 1)
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

    // Deterministic craft checks reject ledger blocks, diary-like absolute day
    // labels, fade-out endings, stacked AI-prose tics, and ability-free openings
    // before the review pass.
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

    var absoluteDayRejected = false
    do {
      try await core.validateChapterCraft(
        "雨季第28天清晨，水声把所有人惊醒。\n" + String(repeating: "字", count: 400),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      absoluteDayRejected = true
    }
    precondition(absoluteDayRejected, "absolute day labels at narration boundaries must be rejected")

    var spacedAbsoluteDayRejected = false
    do {
      try await core.validateChapterCraft(
        "雨季第 28 天清晨，水声把所有人惊醒。\n" + String(repeating: "字", count: 400),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      spacedAbsoluteDayRejected = true
    }
    precondition(spacedAbsoluteDayRejected, "spaced absolute day labels must be rejected")

    var numericDayRejected = false
    do {
      try await core.validateChapterCraft(
        String(repeating: "字", count: 200)
          + "。第28天，走廊尽头的灯终于熄灭。\n"
          + String(repeating: "字", count: 200),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      numericDayRejected = true
    }
    precondition(numericDayRejected, "numeric day labels between sentences must be rejected")

    // Relative scene transitions and dates quoted from an in-story ledger are
    // narrative facts, not narrator-owned absolute day counters.
    try await core.validateChapterCraft(
      "第二天一早，他翻开挂历，看见母亲写的“第5天早7点接”，随即把水壶递过去。\n"
        + String(repeating: "字", count: 300),
      chapterNumber: 4,
      label: "正文"
    )
    try await core.validateChapterCraft(
      "他把挂历推到桌面中央，最下面一行是接水台账：\n第 5 天早 7 点接。\n"
        + String(repeating: "字", count: 300),
      chapterNumber: 4,
      label: "正文"
    )
    var genericRecordRejected = false
    do {
      try await core.validateChapterCraft(
        "她翻开日记，补上一行记录：\n第 5 天，仍然没有人回来。\n"
          + String(repeating: "字", count: 300),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      genericRecordRejected = true
    }
    precondition(genericRecordRejected, "generic record prefixes must not bypass diary-label rejection")

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

    // Tieba / NGA AI-prose tics: stacked 不是……而是…… in narration is a tell;
    // a single use, or the same cadence inside quoted speech, is not.
    var negationCorrectionRejected = false
    do {
      try await core.validateChapterCraft(
        "这不是混乱，而是秩序重新形成前的失控。\n他握紧的不是剑，而是十年的执念。\n"
          + String(repeating: "字", count: 300),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      negationCorrectionRejected = true
    }
    precondition(negationCorrectionRejected, "stacked 不是……而是…… in narration must be rejected")

    try await core.validateChapterCraft(
      "这不是混乱，而是他听错了风声。\n" + String(repeating: "字", count: 300),
      chapterNumber: 4,
      label: "正文"
    )
    try await core.validateChapterCraft(
      "她说：“这不是混乱，而是你想太多。”他又说：“不是怕，而是还没想好。”\n"
        + String(repeating: "字", count: 300),
      chapterNumber: 4,
      label: "正文"
    )

    var atmosphereRejected = false
    do {
      try await core.validateChapterCraft(
        "空气仿佛凝固。他心中暗道：完了。\n" + String(repeating: "字", count: 300),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      atmosphereRejected = true
    }
    precondition(atmosphereRejected, "stacked atmosphere clichés must be rejected")

    var intensifierRejected = false
    do {
      try await core.validateChapterCraft(
        "极其安静，极其缓慢，极其清楚，极其沉重，极其多余。\n"
          + String(repeating: "字", count: 300),
        chapterNumber: 4,
        label: "正文"
      )
    } catch {
      intensifierRejected = true
    }
    precondition(intensifierRejected, "极其 stacking must be rejected")

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
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
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

    // The extraction role backs the RAG model setting. It is optional, so an
    // unset model must inherit the chapter model instead of erroring, and the
    // key must never travel back out of the core.
    do {
      let extractionRoot = root.appendingPathComponent("extraction-role", isDirectory: true)
      let extractionCore = InkOSCore(rootURL: extractionRoot)
      let seedConfig: [String: Any] = [
        "provider": "openai",
        "model": "writer-test",
        "reviewModel": "reviewer-test",
        "baseUrl": "https://example.invalid/v1",
        "reviewBaseUrl": "https://example.invalid/v1",
        "apiKey": "test-key",
        "reviewApiKey": "test-key",
        "stream": false,
        "thinkingBudget": 0,
        "apiFormat": "chat",
      ]
      try JSONSerialization.data(withJSONObject: seedConfig).write(
        to: extractionRoot.appendingPathComponent("data/inkos-config.json"),
        options: .atomic
      )

      let inherited = try await extractionCore.fetchInkOSConfig()
      precondition(
        inherited.extractionModel == "writer-test",
        "an unset extraction model must report the chapter model it falls back to"
      )
      precondition(
        inherited.extractionBaseUrl.isEmpty,
        "an unset extraction endpoint stays blank so the UI shows inheritance"
      )
      precondition(!inherited.hasExtractionApiKey)
      precondition(inherited.extractionApiKeyPreview.isEmpty)
      precondition(
        inherited.contextWindow == InkOSConfig.defaultContextWindow,
        "an unset context window must report 200000"
      )
      precondition(
        inherited.maxTokens == InkOSConfig.defaultMaxTokens,
        "an unset maxTokens must report 16384"
      )

      let applied = try await extractionCore.updateInkOSConfig(
        InkOSConfigUpdate(
          model: "writer-test",
          reviewModel: "reviewer-test",
          extractionModel: "claude-sonnet-4-5",
          baseUrl: "https://example.invalid/v1",
          reviewBaseUrl: "https://example.invalid/v1",
          extractionBaseUrl: "https://extraction.invalid/v1",
          apiKey: "test-key",
          reviewApiKey: "test-key",
          extractionApiKey: "extraction-secret-key"
        )
      )
      precondition(applied.ok)
      precondition(applied.fields.contains("extractionModel"))
      precondition(applied.fields.contains("extractionBaseUrl"))

      let saved = try await extractionCore.fetchInkOSConfig()
      precondition(saved.extractionModel == "claude-sonnet-4-5")
      precondition(saved.extractionBaseUrl == "https://extraction.invalid/v1")
      precondition(saved.hasExtractionApiKey)
      precondition(saved.extractionApiKeyPreview != "extraction-secret-key")
      precondition(!saved.extractionApiKeyPreview.isEmpty)
      precondition(
        saved.extractionApiKey.isEmpty,
        "the extraction key must not be handed back to the UI"
      )
      let encoded = try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(saved)
      ) as? [String: Any] ?? [:]
      precondition(
        (encoded["extractionApiKey"] as? String) == "",
        "the extraction key must encode as an empty string"
      )

      // Clearing the model must blank the model without erasing the stored key,
      // matching how a user turns the separate RAG model back off.
      let cleared = try await extractionCore.updateInkOSConfig(
        InkOSConfigUpdate(
          model: "writer-test",
          reviewModel: "reviewer-test",
          extractionModel: "",
          baseUrl: "https://example.invalid/v1",
          reviewBaseUrl: "https://example.invalid/v1",
          extractionBaseUrl: ""
        )
      )
      precondition(cleared.ok)
      let afterClear = try await extractionCore.fetchInkOSConfig()
      precondition(afterClear.extractionModel.isEmpty)
      precondition(afterClear.extractionBaseUrl.isEmpty)
      precondition(
        afterClear.hasExtractionApiKey,
        "an empty key field must leave the stored key alone"
      )
      print("Extraction model role probe passed")
    }

    try await assertLLMRequestBudgetConfig(root: root)

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

      // Every rewrite round returns the same draft, so the stall detector stops
      // the loop after the escalated retry. Supply one stub per round the loop
      // can legitimately attempt: an exhausted queue puts the transport into its
      // 4s/12s retry backoff, and those late requests then consume the stubs the
      // next test block configures.
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: retainedPayloadText, stream: true),
        AutomatedRevisionStubResponse(content: retainedPayloadText, stream: true),
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
      // A stall reports the standing blocking finding, not the mechanical
      // "output was identical" message, which tells a human nothing actionable.
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

      // A delta-gap finding cites the prose as evidence for what went
      // unregistered. Treating that citation as "the text is wrong" sent these
      // to a full rewrite, which regenerated correct prose until the stall
      // detector killed the round.
      let evidenceCitingDeltaReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "登记缺口",
        issues: [
          "[hard] Delta登记缺口：正文明确写出林骁小臂裂口、章末纱布重新渗血，但 ENT-004 upsert 的 attributes 为空，这一持久人物状态变化未登记进 Delta。",
          "[hard] Delta登记缺口：正文写出药板由34粒降为33粒，但 ENT-006 upsert 的 attributes 为空，实体 state 仍是'余34粒一粒未动'，与正文直接矛盾且未更新。",
        ],
        revisionGuidance: "补全 attributes。"
      )
      let acceptsEvidenceCitingRepair = await automaticCore.shouldAttemptDeltaOnlyRepair(
        evidenceCitingDeltaReview
      )
      precondition(acceptsEvidenceCitingRepair)

      // The mirror case: the prose itself carries a stale number that
      // contradicts the registered record, so only a rewrite can fix it.
      let staleProseReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "正文数字过期",
        issues: [
          "[hard] 资源数额：正文报'八千六百六十七块二'，与已登记事实矛盾——第13章已净减76元，当前应为8591.2元。",
        ],
        revisionGuidance: "改正文数字。"
      )
      let rejectsStaleProseRepair = await automaticCore.shouldAttemptDeltaOnlyRepair(
        staleProseReview
      )
      precondition(!rejectsStaleProseRepair)

      // An explicit tag from the review model wins over any heuristic.
      let taggedProseReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "标签指定改正文",
        issues: ["[hard][prose] 登记：需要补全 ENT-004 的 attributes 登记记录。"],
        revisionGuidance: "改正文。"
      )
      let rejectsTaggedProse = await automaticCore.shouldAttemptDeltaOnlyRepair(taggedProseReview)
      precondition(!rejectsTaggedProse)
      let taggedDeltaReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "标签指定改登记",
        issues: ["[hard][delta] 时间线：TL-064 的 order 排在 TL-065 之前，与正文时序不符。"],
        revisionGuidance: "改 Delta 排序。"
      )
      let acceptsTaggedDelta = await automaticCore.shouldAttemptDeltaOnlyRepair(taggedDeltaReview)
      precondition(acceptsTaggedDelta)

      // A mixed batch still needs the rewrite loop: one prose defect is enough.
      let mixedScopeReview = InkOSCore.NativeReview(
        pass: false,
        model: "reviewer-test",
        summary: "混合范围",
        issues: [
          "[hard][delta] 登记：ENT-006 的 attributes 为空。",
          "[hard][prose] 本地章节规则：正文只有 2293 字，低于计划下限 2550 字。",
        ],
        revisionGuidance: "先扩写再补登记。"
      )
      let rejectsMixedScope = await automaticCore.shouldAttemptDeltaOnlyRepair(mixedScopeReview)
      precondition(!rejectsMixedScope)

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

      // The rewrite must return prose that differs from the stored draft. Feeding
      // back the identical text trips the stall detector, so the round can never
      // reach the passing review this block asserts.
      var rewordedPayload = chapterPayload
      rewordedPayload["content"] = String(
        repeating: "雨声压过巷口，异常裂缝在窗框边缘又亮了一次，钥匙贴着掌心发烫。",
        count: 36
      )
      let rewordedPayloadText = String(
        data: try JSONSerialization.data(withJSONObject: rewordedPayload),
        encoding: .utf8
      )!
      AutomatedRevisionLLMProtocol.configure([
        AutomatedRevisionStubResponse(content: rewordedPayloadText, stream: true),
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

    try await assertEmptyContentRetriesAtRaisedBudget(root: root)
    try await assertEntityIDCollisionIsActionable()
    try await assertDeltaFindingsNeverRouteToRewrite(root: root)
    try await assertLocalLengthMissKeepsRevisionLoopAlive(root: root)
    try await assertDerivativeRetrievalWorks(root: root)
    try await assertCanonExtractionResumesAndOutranks(root: root)
    try await assertDerivativeTimelineGatesCanonEvents(root: root)
    try await assertDerivativeBeatClosingCoversCappedFuture(root: root)
    try await assertDerivativePromptCoverage(root: root)
    try await assertDerivativePreparationGate(root: root)
    try await assertModelNullsDoNotCrashNormalization(root: root)
    try await assertOpenHooksPromptBudgeting(root: root)
    try await assertCompactContinuityContext(root: root)
    try await assertInvalidationFencesInFlightBeatPrefetch(root: root)

    print("Native InkOSCore smoke test passed")
  }

  /// A background prefetch used to resurrect beats after approval or revision
  /// invalidated them: the actor yielded in `requestLLM`, invalidation rewrote
  /// chapter-beats.json, then the late model response loaded that fresh file and
  /// appended its stale batch. Hold the response at that exact suspension point
  /// and prove the invalidation epoch rejects the late commit.
  private static func assertInvalidationFencesInFlightBeatPrefetch(root: URL) async throws {
    let raceRoot = root.appendingPathComponent("beat-prefetch-invalidation", isDirectory: true)
    let core = InkOSCore(rootURL: raceRoot)
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
    try JSONSerialization.data(withJSONObject: config)
      .write(to: raceRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

    let creation = try await core.createBook(CreateBookRequest(
      title: "节拍预取失效测试书",
      language: "zh",
      genre: "sci-fi",
      platform: "tomato",
      targetChapters: 20,
      chapterWords: 1_000,
      totalWords: "20000",
      targetTotalWords: 20_000,
      volumeCount: 1,
      chapterWordTolerance: 10,
      premise: "验证后台节拍预取不会覆盖显式失效操作。",
      characters: "主角负责记录每一批节拍。",
      protagonistProfile: "主角谨慎守序，压力下反复核对记录；缺陷是过度依赖旧计划。",
      protagonistReviewed: true,
      worldbuilding: "测试世界按章节顺序推进。",
      outline: "二十章分成两批推进。",
      volumePlan: "第一卷第1至20章。",
      pacing: "每章推进一个测试目标。",
      style: "简洁叙事。",
      constraints: "不得跳过章节。"
    ))
    let plan = try await core.fetchLongFormPlan(bookID: creation.title)
    let seeded = ChapterBeatPlan(
      bookId: creation.title,
      beats: (1...10).map {
        ChapterBeat(number: $0, goal: "第\($0)章既有目标", scenes: ["第\($0)章既有场景"])
      },
      batches: [ChapterBeatBatch(
        startChapter: 1,
        endChapter: 10,
        volumeNumber: 1,
        planRevision: plan.revision,
        generatedAt: isoTimestamp(),
        model: "fixture"
      )],
      updatedAt: isoTimestamp()
    )
    let beatsURL = raceRoot.appendingPathComponent(
      "book/books/\(creation.title)/story/runtime/chapter-beats.json"
    )
    try JSONEncoder().encode(seeded).write(to: beatsURL, options: .atomic)

    let generatedBeats: [[String: Any]] = (11...20).map { number in
      [
        "number": number,
        "volumeNumber": 1,
        "goal": "第\(number)章预取目标",
        "openingHook": "第\(number)章开场",
        "scenes": ["第\(number)章场景"],
        "requiredEvents": ["完成第\(number)章事件"],
        "forbiddenElements": [],
        "endingHook": "第\(number)章结尾",
        "focusCharacters": ["主角"],
        "newNamedCharacters": 0,
        "timeSpan": "一天",
        "storyDays": 1,
        "setback": "计划受阻",
        "notes": "测试",
      ]
    }
    let response = String(
      data: try JSONSerialization.data(withJSONObject: ["beats": generatedBeats]),
      encoding: .utf8
    )!

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      AutomatedRevisionLLMProtocol.releaseBlockedResponse()
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: response,
        stream: true,
        waitForRelease: true
      ),
    ])

    await core.prefetchUpcomingBeatBatch(
      bookID: creation.title,
      currentChapter: 10,
      plan: plan
    )
    var requestStarted = false
    for _ in 0..<200 {
      if AutomatedRevisionLLMProtocol.requestCount() >= 1 {
        requestStarted = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    precondition(requestStarted, "后台节拍预取未进入模型请求")

    _ = try await core.invalidateChapterBeats(bookID: creation.title, fromChapter: 11)
    AutomatedRevisionLLMProtocol.releaseBlockedResponse()

    var prefetchFinished = false
    for _ in 0..<200 {
      let inFlight = await core.beatPrefetchInFlight
      if inFlight.isEmpty {
        prefetchFinished = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    precondition(prefetchFinished, "后台节拍预取未在预期时间内结束")

    let after = try await core.fetchChapterBeats(bookID: creation.title)
    precondition(
      after.beats.map(\.number) == Array(1...10),
      "失效后的旧预取结果不得写回：\(after.beats.map(\.number))"
    )
    precondition(
      after.batches.count == 1 && after.batches[0].endChapter == 10,
      "失效后的旧批次记录不得写回：\(after.batches)"
    )
    let events = try await core.fetchDebugEvents(limit: 200).events
    precondition(
      events.contains {
        guard $0.message == "chapter_beats.prefetch.failed",
              case .string(let error)? = $0.data["error"]
        else { return false }
        return error.contains("结果已作废")
      },
      "过期预取应记录为可诊断的失败"
    )
    print("Beat prefetch invalidation probe passed: stale response fenced before commit")
  }

  /// `MACINKOSTOMO_WORKSPACE=$(mktemp -d)` is the documented app-level test
  /// boundary. The directory starts empty, so requiring an existing `book/` would
  /// ignore it and fall back to the real Release workspace. It must also suppress
  /// legacy migration, or the isolation directory gets populated with copies of
  /// the customer's actual books before the test even begins.
  private static func assertExplicitWorkspaceIsIsolated(root: URL) async throws {
    let environmentKey = "MACINKOSTOMO_WORKSPACE"
    let previous = getenv(environmentKey).map { String(cString: $0) }
    defer {
      if let previous {
        setenv(environmentKey, previous, 1)
      } else {
        unsetenv(environmentKey)
      }
    }

    let explicit = root.appendingPathComponent("explicit-empty-workspace", isDirectory: true)
    try? FileManager.default.removeItem(at: explicit)
    setenv(environmentKey, explicit.path, 1)
    precondition(
      InkOSCore.resolveWorkspaceRoot() == explicit.standardizedFileURL,
      "显式 MACINKOSTOMO_WORKSPACE 必须接受空目录"
    )

    let isolated = InkOSCore()
    let isolatedRoot = isolated.rootURL
    precondition(isolatedRoot == explicit.standardizedFileURL)
    let books = try await isolated.fetchBooks()
    precondition(books.isEmpty, "显式测试工作区不得迁入真实书库：\(books.map(\.id))")
    precondition(
      FileManager.default.fileExists(atPath: explicit.appendingPathComponent("book/books").path),
      "显式工作区应由核心初始化"
    )
    print("Explicit workspace isolation probe passed")
  }

  /// An entity whose `id` and `name` point at two different canon entries must
  /// fail with a message the `[delta]` repair round can act on, and must never
  /// silently rename the canon entry that already holds the ID.
  ///
  /// Chapter 27 of 《渊雨浩劫》 registered 苏晚晴 under ENT-030, an ID the canon had
  /// already given to 黑影软管与水箱旁烟头. The old `id || name` predicate resolved
  /// that by array position and reported "实体 黑影软管与水箱旁烟头 的类型不能从
  /// object 改为 character" — an entity the delta never mentioned. The repairer
  /// found nothing to fix, returned byte-identical JSON, and the loop burned two
  /// full auto-revision exhaustions (6 rounds) without ever changing the ID.
  /// Chapter 25 hit the same collision between two `location` entries, where no
  /// type change fired at all and the canon entry was quietly renamed instead.
  private static func assertEntityIDCollisionIsActionable() async throws {
    let core = InkOSCore(rootURL: FileManager.default.temporaryDirectory
      .appendingPathComponent("MacInkostomo-EntityID-\(UUID().uuidString)", isDirectory: true))
    var canon = LongFormContinuity()
    canon.entities = [
      LongFormEntity(id: "ENT-030", name: "黑影软管与水箱旁烟头", type: "object"),
      LongFormEntity(id: "ENT-CH26-001", name: "苏晚晴", type: "character"),
    ]

    // The chapter-27 shape: right name, wrong ID, and the ID belongs to an entity
    // of a different type.
    var collision = ContinuityDelta()
    collision.upsert.entities = [
      LongFormEntity(id: "ENT-030", name: "苏晚晴", type: "character")
    ]
    var strict = canon
    var message = ""
    do {
      try await core.applyContinuityDelta(
        collision, to: &strict, source: "第27章候选差量", strictIdentity: true
      )
      preconditionFailure("reused entity ID must be rejected when validating a candidate delta")
    } catch let error as InkOSCoreError {
      message = error.localizedDescription
    }
    // Every fact the repairer needs: the ID it reused, the holder, the right ID.
    precondition(message.contains("ENT-030"), "collision message must name the reused ID: \(message)")
    precondition(message.contains("苏晚晴"), "collision message must name the entity being registered: \(message)")
    precondition(
      message.contains("ENT-CH26-001"),
      "collision message must state the correct ID to use instead: \(message)"
    )
    precondition(
      !message.contains("类型不能从"),
      "collision must not masquerade as a type conflict on the ID holder: \(message)"
    )
    precondition(strict.entities.count == 2, "a rejected delta must not mutate the canon")
    precondition(
      strict.entities.contains { $0.id == "ENT-030" && $0.name == "黑影软管与水箱旁烟头" },
      "the ID holder must keep its name"
    )

    // A genuinely new entity that guessed a taken ID: the message must offer a
    // free ID rather than point at a canon entry that does not exist.
    var newEntity = ContinuityDelta()
    newEntity.upsert.entities = [
      LongFormEntity(id: "ENT-030", name: "铁壳旧渡船", type: "object")
    ]
    var newStrict = canon
    var newMessage = ""
    do {
      try await core.applyContinuityDelta(
        newEntity, to: &newStrict, source: "第27章候选差量", strictIdentity: true
      )
      preconditionFailure("a new entity reusing a taken ID must be rejected")
    } catch let error as InkOSCoreError {
      newMessage = error.localizedDescription
    }
    precondition(newMessage.contains("新实体"), "message must say the entity is new: \(newMessage)")
    precondition(
      !newMessage.contains("正确 ID 是"),
      "no canonical ID exists, so none may be claimed: \(newMessage)"
    )

    // The chapter-25 shape, on the replay path: two `location` entries collide,
    // no type change fires, and the canon entry used to be renamed in place.
    // Replay must stay reproducible for books that already committed such a
    // delta, so the name decides identity and the wrong ID is dropped.
    var replayCanon = LongFormContinuity()
    replayCanon.entities = [
      LongFormEntity(id: "LOC-024-01", name: "江边北岸引桥与主桥", type: "location"),
      LongFormEntity(id: "LOC-CH26-001", name: "下游七公里临时渡口", type: "location"),
    ]
    var replayDelta = ContinuityDelta()
    replayDelta.upsert.entities = [
      LongFormEntity(id: "LOC-024-01", name: "下游七公里临时渡口", type: "location")
    ]
    var replayed = replayCanon
    try await core.applyContinuityDelta(replayDelta, to: &replayed, source: "第25章")
    precondition(replayed.entities.count == 2, "replay must not add a duplicate: \(replayed.entities.count)")
    precondition(
      replayed.entities.contains { $0.id == "LOC-024-01" && $0.name == "江边北岸引桥与主桥" },
      "replay must not rename the ID holder"
    )
    precondition(
      replayed.entities.contains { $0.id == "LOC-CH26-001" && $0.name == "下游七公里临时渡口" },
      "replay must merge into the name match, keeping its own ID"
    )
    print("Entity ID collision probe passed: \(message)")
  }

  /// A review whose blocking findings are all `[delta]` must keep routing to the
  /// delta-only repair, round after round — never to a prose rewrite.
  ///
  /// Chapter 27 of 《渊雨浩劫》 is the case this encodes. Delta repair ran once,
  /// cleared the entity ID collision, and the re-review answered with three
  /// fresh `[hard][delta]` faults (two unclosed hooks, one duplicate). Because
  /// the repair branch was a plain `if` rather than a loop, those findings fell
  /// through to the rewrite loop, which is the wrong tool by construction: the
  /// prose needed no edit, so two rounds returned byte-identical text, the stall
  /// detector read that correct answer as a dead end, escalated to temperature
  /// 0.7 with "the text must differ", and the model padded the chapter from 3456
  /// to 4052 characters until the length ceiling killed it at 422.
  ///
  /// The scope classifier already has its own coverage above; what this asserts
  /// is the routing built on top of it. The request count is the load-bearing
  /// assertion — with the `while` back to an `if`, the seventh stub is consumed
  /// by a rewrite call instead of the second repair.
  private static func assertDeltaFindingsNeverRouteToRewrite(root: URL) async throws {
    let loopRoot = root.appendingPathComponent("delta-repair-loop", isDirectory: true)
    let loopCore = InkOSCore(rootURL: loopRoot)
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
    try JSONSerialization.data(withJSONObject: config)
      .write(to: loopRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

    let emptyDeltaSections: [String: Any] = [
      "immutableCanon": [], "worldRules": [], "entities": [],
      "knowledgeBoundaries": [], "timeline": [], "hooks": [],
    ]
    let chapterContent = String(
      repeating: "雨夜窗外浮出异常裂缝，钥匙突然发烫，门后传来倒数声。",
      count: 39
    )
    let chapterPayload: [String: Any] = [
      "title": "异常倒数",
      "content": chapterContent,
      "summary": "主角发现门后的异常倒数。",
      "consistencyDelta": ["upsert": emptyDeltaSections, "remove": emptyDeltaSections],
    ]
    let chapterPayloadText = String(
      data: try JSONSerialization.data(withJSONObject: chapterPayload),
      encoding: .utf8
    )!
    let beatResponse = """
      {"beats":[{"number":1,"volumeNumber":1,"goal":"确认门后倒数的来源","openingHook":"钥匙突然发烫","scenes":["走廊发现裂缝"],"requiredEvents":["主角发现异常裂缝"],"forbiddenElements":["不得打开门后世界"],"endingHook":"倒数声突然加快","focusCharacters":["主角"],"newNamedCharacters":0,"timeSpan":"半夜","setback":"钥匙失控发烫","notes":"只推进异常发现"}]}
      """
    // Round 1's findings are the shape that first sent chapter 27 into repair.
    let firstDeltaReview = """
      {"pass":false,"summary":"候选连续性差量未通过","issues":["[hard][delta] 实体登记：正文写出钥匙发烫，但候选Delta的upsert.entities为空，未登记该物品。"],"revisionGuidance":"补登发烫钥匙实体；正文无需改动。"}
      """
    let firstRepairedDelta = """
      {"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"item-key","name":"发烫钥匙","type":"item"}],"knowledgeBoundaries":[],"timeline":[],"hooks":[]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}
      """
    // Round 2: fresh, different, still delta-only — the re-review shape that used
    // to fall through. Wording taken from the real chapter-27 hook findings.
    let secondDeltaReview = """
      {"pass":false,"summary":"候选连续性差量未通过","issues":["[hard][delta] 伏笔生命周期：正文已正式抛出门后倒数悬口，但候选Delta的upsert.hooks为空，未登记该伏笔。","[hard][delta] 实体登记口径：发烫钥匙的 attributes 为空，正文写明它已开始发烫。"],"revisionGuidance":"补登 hook 与实体 attributes；正文无需改动。"}
      """
    let secondRepairedDelta = """
      {"upsert":{"immutableCanon":[],"worldRules":[],"entities":[{"id":"item-key","name":"发烫钥匙","type":"item","attributes":{"状态":"持续发烫"}}],"knowledgeBoundaries":[],"timeline":[],"hooks":[{"hookId":"hook-countdown","description":"门后倒数来源待查","openFromChapter":1}]},"remove":{"immutableCanon":[],"worldRules":[],"entities":[],"knowledgeBoundaries":[],"timeline":[],"hooks":[]}}
      """
    let passedReview = """
      {"pass":true,"summary":"登记已补全，正文未改动","issues":[],"revisionGuidance":""}
      """

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }
    // Seven calls, in order: beat batch, chapter write, review 1, repair 1,
    // review 2, repair 2, review 3. Not one chapter rewrite among them.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: beatResponse, stream: true),
      AutomatedRevisionStubResponse(content: chapterPayloadText, stream: true),
      AutomatedRevisionStubResponse(content: firstDeltaReview, stream: true),
      AutomatedRevisionStubResponse(content: firstRepairedDelta, stream: true),
      AutomatedRevisionStubResponse(content: secondDeltaReview, stream: true),
      AutomatedRevisionStubResponse(content: secondRepairedDelta, stream: true),
      AutomatedRevisionStubResponse(content: passedReview, stream: true),
    ])

    let creation = try await loopCore.createBook(CreateBookRequest(
      title: "Delta 连续修复测试书",
      language: "zh",
      genre: "xuanhuan",
      platform: "tomato",
      targetChapters: 1,
      chapterWords: 1_000,
      totalWords: "1000",
      targetTotalWords: 1_000,
      volumeCount: 1,
      chapterWordTolerance: 10,
      premise: "验证连续两轮 Delta 范畴意见都只修登记。",
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
    _ = try await loopCore.generateChapter(bookID: creation.title, guidance: nil)

    var completedJob: GenerationJob?
    for _ in 0..<200 {
      let job = try await loopCore.fetchGenerationJob(
        bookID: creation.title,
        chapterNumber: 1
      ).job
      if job?.isActive == false {
        completedJob = job
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let completedJob else { preconditionFailure("连续 Delta 修复任务未在预期时间内完成") }
    precondition(
      completedJob.phase == "ready-for-review",
      "two delta-only rounds must converge, got \(completedJob.phase) / \(completedJob.error ?? "")"
    )
    let chapter = try await loopCore.fetchChapter(bookID: creation.title, number: 1)
    precondition(chapter.llmReview?.isPassed == true)
    precondition(chapter.llmReview?.attempts?.count == 3, "three reviews: fail, fail, pass")
    // The whole point: the prose the model wrote first is the prose that ships.
    precondition(chapter.content == chapterContent, "delta repair must not touch the prose")
    precondition(
      chapter.revisionHistory.count == 2,
      "both rounds must be delta repairs, got \(chapter.revisionHistory.count)"
    )
    precondition(
      chapter.revisionHistory.allSatisfy { $0.type == "delta_repair" },
      "a [delta]-only re-review must never open a rewrite round: "
        + chapter.revisionHistory.map { $0.type ?? "nil" }.joined(separator: ",")
    )
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 7,
      "expected 7 calls (beat, chapter, 3 reviews, 2 repairs), spent \(AutomatedRevisionLLMProtocol.requestCount())"
    )
    // Round 2's registration is the one that had to survive; a rewrite round
    // would have regenerated the delta from scratch and lost it.
    let repaired = try await loopCore.chapterConsistencyDelta(
      bookID: creation.title,
      chapterNumber: 1
    )
    precondition(repaired.upsert.hooks.first?.hookId == "hook-countdown")
    precondition(repaired.upsert.entities.first?.attributes["状态"] == "持续发烫")
    print("Delta repair loop probe passed: \(chapter.revisionHistory.count) delta rounds, no rewrite")
  }

  /// A local length/craft miss inside a revision round is feedback for the next
  /// round, not an endpoint rejection. Before the re-tag, the round's local 422
  /// hit the loop's 4xx early-exit ("请求被服务端拒绝") and the revision died after
  /// one round — chapter 30 of 《渊雨浩劫》 ping-ponged 4000 → 2415 → 4029 with a
  /// human clicking resubmit each time, because the corrective count/gap never
  /// reached a second round. The loop must continue on a local miss and still
  /// stop on a genuine endpoint 4xx.
  private static func assertLocalLengthMissKeepsRevisionLoopAlive(root: URL) async throws {
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
    let emptyDeltaSections: [String: Any] = [
      "immutableCanon": [], "worldRules": [], "entities": [],
      "knowledgeBoundaries": [], "timeline": [], "hooks": [],
    ]
    // 31 repetitions ≈ 806 characters: under the 850-word floor of a 1 000-word
    // chapter with 10% tolerance. 39 ≈ 1 014: inside the band. Each stub uses a
    // *different* sentence: identical prose would take the stall-escalation path
    // instead of the local length validation this probe exists to exercise. The
    // in-band content must also carry an opening ability anchor (chapters 1-3
    // reject prose without one), so it reuses the anomaly sentence proven by the
    // delta probe above.
    let draftContent = String(
      repeating: "雨夜窗外浮出异常裂缝，钥匙突然发烫，门后传来倒数声。",
      count: 31
    )
    let shortContent = String(
      repeating: "走廊尽头灯管爆裂，黑暗里有人轻声数到第七声。",
      count: 31
    )
    let goodContent = String(
      repeating: "雨夜窗外浮出异常裂缝，钥匙突然发烫，门后传来倒数声。",
      count: 39
    )
    func chapterPayload(_ content: String) throws -> String {
      let payload: [String: Any] = [
        "title": "异常倒数",
        "content": content,
        "summary": "主角发现门后的异常倒数。",
        "consistencyDelta": ["upsert": emptyDeltaSections, "remove": emptyDeltaSections],
      ]
      return String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    }
    let beatResponse = """
      {"beats":[{"number":1,"volumeNumber":1,"goal":"确认门后倒数的来源","openingHook":"钥匙突然发烫","scenes":["走廊发现裂缝"],"requiredEvents":["主角发现异常裂缝"],"forbiddenElements":["不得打开门后世界"],"endingHook":"倒数声突然加快","focusCharacters":["主角"],"newNamedCharacters":0,"timeSpan":"半夜","setback":"钥匙失控发烫","notes":"只推进异常发现"}]}
      """
    let passedReview = """
      {"pass":true,"summary":"字数已落入区间，登记齐全","issues":[],"revisionGuidance":""}
      """

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }

    func makeBook(core: InkOSCore, root: URL, title: String) async throws -> String {
      try JSONSerialization.data(withJSONObject: config)
        .write(to: root.appendingPathComponent("data/inkos-config.json"), options: .atomic)
      let creation = try await core.createBook(CreateBookRequest(
        title: title,
        language: "zh",
        genre: "xuanhuan",
        platform: "tomato",
        targetChapters: 1,
        chapterWords: 1_000,
        totalWords: "1000",
        targetTotalWords: 1_000,
        volumeCount: 1,
        chapterWordTolerance: 10,
        premise: "验证本地字数不达标不会终止自动修订循环。",
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
      return creation.title
    }
    func waitForJob(core: InkOSCore, bookID: String) async throws -> GenerationJob {
      var last: GenerationJob?
      for _ in 0..<600 {
        let job = try await core.fetchGenerationJob(bookID: bookID, chapterNumber: 1).job
        last = job ?? last
        if let job, !job.isActive { return job }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      preconditionFailure(
        "任务未在预期时间内结束，lastPhase=\(last?.phase ?? "nil") error=\(last?.error ?? "none")"
      )
    }

    // Scenario 1: two under-length drafts in a row. The loop must spend a
    // second round folding the count feedback into the note and converge.
    let loopRoot = root.appendingPathComponent("length-miss-loop", isDirectory: true)
    let loopCore = InkOSCore(rootURL: loopRoot)
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: beatResponse, stream: true),
      AutomatedRevisionStubResponse(content: try chapterPayload(draftContent), stream: true),
      AutomatedRevisionStubResponse(content: try chapterPayload(shortContent), stream: true),
      AutomatedRevisionStubResponse(content: try chapterPayload(goodContent), stream: true),
      AutomatedRevisionStubResponse(content: passedReview, stream: true),
    ])
    let loopBook = try await makeBook(core: loopCore, root: loopRoot, title: "字数振荡测试书")
    _ = try await loopCore.generateChapter(bookID: loopBook, guidance: nil)
    let retainedJob = try await waitForJob(core: loopCore, bookID: loopBook)
    precondition(
      retainedJob.phase == "revision_failed",
      "低于下限的首稿必须保留为 revision_failed，得到 \(retainedJob.phase)"
    )
    _ = try await loopCore.reviseChapter(bookID: loopBook, number: 1, note: "扩写到计划区间", mode: "rewrite")
    let loopJob = try await waitForJob(core: loopCore, bookID: loopBook)
    precondition(
      loopJob.phase == "ready-for-review",
      "本地字数不达标不得终止循环，得到 \(loopJob.phase) / \(loopJob.error ?? "")"
    )
    let loopChapter = try await loopCore.fetchChapter(bookID: loopBook, number: 1)
    precondition(loopChapter.content == goodContent, "第二轮正文必须被采用")
    let loopAttempts = loopChapter.llmReview?.attempts ?? []
    precondition(
      loopAttempts.count == 3,
      "本地校验失败 + 收敛复审都要进账本，实际 \(loopAttempts.count)"
    )
    precondition(
      loopAttempts.dropFirst().first?.status == "error",
      "第一轮必须记为本地校验错误而非终止"
    )
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 5,
      "expected 5 calls (beat, draft, 2 rewrites, review), spent \(AutomatedRevisionLLMProtocol.requestCount())"
    )

    // Scenario 2: a genuine endpoint 400 still ends the loop immediately.
    let rejectRoot = root.appendingPathComponent("endpoint-reject-loop", isDirectory: true)
    let rejectCore = InkOSCore(rootURL: rejectRoot)
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: beatResponse, stream: true),
      AutomatedRevisionStubResponse(content: try chapterPayload(shortContent), stream: true),
      AutomatedRevisionStubResponse(content: "Bad Request", stream: true, statusCode: 400),
    ])
    let rejectBook = try await makeBook(core: rejectCore, root: rejectRoot, title: "端点拒绝测试书")
    _ = try await rejectCore.generateChapter(bookID: rejectBook, guidance: nil)
    _ = try await waitForJob(core: rejectCore, bookID: rejectBook)
    _ = try await rejectCore.reviseChapter(bookID: rejectBook, number: 1, note: "扩写到计划区间", mode: "rewrite")
    let rejectJob = try await waitForJob(core: rejectCore, bookID: rejectBook)
    precondition(
      rejectJob.phase == "revision_failed",
      "端点 4xx 必须立即终止循环，得到 \(rejectJob.phase)"
    )
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 3,
      "expected 3 calls (beat, draft, refused rewrite), spent \(AutomatedRevisionLLMProtocol.requestCount())"
    )

    // Scenario 3: request setup is neither a remote response nor a correctable
    // prose fault. A missing key must stop after the first attempted rewrite,
    // even though its typed UI status is also 400.
    let configRoot = root.appendingPathComponent("request-config-loop", isDirectory: true)
    let configCore = InkOSCore(rootURL: configRoot)
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: beatResponse, stream: true),
      AutomatedRevisionStubResponse(content: try chapterPayload(shortContent), stream: true),
    ])
    let configBook = try await makeBook(core: configCore, root: configRoot, title: "请求配置测试书")
    _ = try await configCore.generateChapter(bookID: configBook, guidance: nil)
    _ = try await waitForJob(core: configCore, bookID: configBook)
    var missingKeyConfig = config
    missingKeyConfig["apiKey"] = ""
    try JSONSerialization.data(withJSONObject: missingKeyConfig)
      .write(to: configRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)
    _ = try await configCore.reviseChapter(
      bookID: configBook,
      number: 1,
      note: "扩写到计划区间",
      mode: "rewrite"
    )
    let configJob = try await waitForJob(core: configCore, bookID: configBook)
    precondition(configJob.phase == "revision_failed", "请求配置错误必须终止修订")
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 2,
      "missing API key must not issue or repeat an LLM request"
    )
    print("Revision error-origin probe passed: local retries, config/endpoint 4xx stop")
  }

  /// Derivative (同人) source retrieval: ingest, BM25, semantic embedding, and the
  /// reciprocal-rank fusion of the two.
  ///
  /// The assertions that matter are the retrieval-quality ones, because the whole
  /// point of the hybrid is that each half covers the other's blind spot:
  ///
  /// - A two-character query (渡口) must hit. FTS5 `trigram` never matches a query
  ///   shorter than three characters, so this fails outright without the
  ///   `unicode61` segmented mirror.
  /// - A paraphrase that shares no distinctive term with the target passage must
  ///   hit. BM25 cannot do this by construction; only the embedding can.
  /// - A passage found by both halves must outrank one found by a single half,
  ///   which is what RRF buys over running either engine alone.
  private static func assertDerivativeRetrievalWorks(root: URL) async throws {
    let derivativeRoot = root.appendingPathComponent("derivative", isDirectory: true)
    let core = InkOSCore(rootURL: derivativeRoot)
    let creation = try await core.createBook(CreateBookRequest(
      title: "同人检索测试书",
      language: "zh",
      genre: "fanfic",
      platform: "tomato",
      kind: .derivative,
      sourceTitle: "检索原著",
      timelineAnchorLabel: "渡口开船",
      targetChapters: 2,
      chapterWords: 1_000,
      totalWords: "2000",
      targetTotalWords: 2_000,
      volumeCount: 1,
      chapterWordTolerance: 15,
      premise: "验证原著导入与检索。",
      characters: "主角沿用原著人物。",
      protagonistProfile: "主角谨慎，习惯先确认再行动；缺陷是不肯求助。",
      protagonistReviewed: true,
      worldbuilding: "沿用原著设定。",
      outline: "第一章在原著分歧点介入。",
      volumePlan: "第一卷1-2章。",
      pacing: "一章推进一个目标。",
      style: "第三人称有限视角。",
      constraints: "不得与原著既有事实冲突"
    ))

    // A line beginning with an ordinal act can still be ordinary narration.
    // Volume labels are structural and must not become empty searchable chapters.
    let deceptiveHeadings = """
      第一章 初雨
      雨声把屋檐压得很低。
      第一幕依旧笼在雨里，没有一个人先开口。
      第二幕则只是他的猜测，并非戏剧标题。
      第三幕是多年后的回忆，此刻尚未发生。
      第二章 渡口
      船老大收起跳板，等潮水回落。
      第七卷 倒吊人
      第三章 药铺
      药柜后只剩最后一包纱布。
      """
    let deceptiveSplit = await core.splitSourceChapters(deceptiveHeadings)
    precondition(deceptiveSplit.strategy == .headings)
    precondition(
      deceptiveSplit.chapters.map(\.title) == ["第一章 初雨", "第二章 渡口", "第三章 药铺"],
      "正文幕次或卷标题不得制造伪章节：\(deceptiveSplit.chapters.map(\.title))"
    )
    guard let firstDeceptiveChapter = deceptiveSplit.chapters.first else {
      preconditionFailure("切章回归夹具缺少第一章")
    }
    let deceptiveFirstBody = (deceptiveHeadings as NSString).substring(with: NSRange(
      location: firstDeceptiveChapter.offset,
      length: firstDeceptiveChapter.length
    ))
    precondition(
      deceptiveFirstBody.contains("第一幕依旧")
        && deceptiveFirstBody.contains("第二幕则")
        && deceptiveFirstBody.contains("第三幕是"),
      "正文里的幕次句必须完整留在章节正文"
    )

    // Actual act headings remain supported when the title is visibly delimited,
    // or when the heading consists solely of the ordinal plus 幕.
    let validActHeadings = """
      第一幕：骤雨
      众人从长廊跑进门厅。
      第二幕 转折
      门外的脚步忽然停了。
      第三幕
      天亮前，信终于送到。
      """
    let validActSplit = await core.splitSourceChapters(validActHeadings)
    precondition(
      validActSplit.strategy == .headings && validActSplit.chapters.count == 3,
      "带分隔符的合法幕标题仍应被识别：\(validActSplit.chapters.map(\.title))"
    )

    let decoratedHeadings = """
      ========第一章 初雨========
      雨从傍晚开始下，起初谁也没当回事。林辰把窗户关严，听见远处有人在喊着收衣服。街上的行人加快脚步，伞面被风掀得翻过来。
      【第二章 渡口】
      渡口只剩两条船了，船老大蹲在跳板上抽烟，说明早最多接两批人过江，第三批得等下午的潮水。排在前头的女人抱着孩子问能不能加塞。
      ==========第三章 药==========
      药店老板说三个供货商的电话今天全打不通，柜台后面的货架空了一半。林辰买了二十天的量，付现金的时候手有点抖。
      """
    let decoratedSplit = await core.splitSourceChapters(decoratedHeadings)
    precondition(
      decoratedSplit.strategy == .headings
        && decoratedSplit.chapters.map(\.title) == ["第一章 初雨", "第二章 渡口", "第三章 药"],
      "装饰线或书名号不得进入标题：\(decoratedSplit.chapters.map(\.title))"
    )

    let tocDump = """
      目录
      第一章 初雨
      第 1 页
      第二章 渡口
      第 2 页
      第三章 药
      第 3 页
      第一章 初雨
      雨从傍晚开始下，起初谁也没当回事。林辰把窗户关严，听见远处有人在喊着收衣服。街上的行人加快脚步，伞面被风掀得翻过来，路灯下的水花溅起半尺高。
      第二章 渡口
      渡口只剩两条船了，船老大蹲在跳板上抽烟，说明早最多接两批人过江，第三批得等下午的潮水。排在前头的女人抱着孩子问能不能加塞，船老大摇头。
      第三章 药
      药店老板说三个供货商的电话今天全打不通，柜台后面的货架空了一半。林辰买了二十天的量，付现金的时候手有点抖。老板说这药后面还会缺。
      """
    let tocSplit = await core.splitSourceChapters(tocDump)
    precondition(
      tocSplit.strategy == .headings && tocSplit.chapters.count == 3,
      "目录行必须并入真正的章节而不是变成六个空章：\(tocSplit.chapters.map(\.title))"
    )
    let tocFirstBody = (tocDump as NSString).substring(with: NSRange(
      location: tocSplit.chapters[0].offset,
      length: tocSplit.chapters[0].length
    ))
    precondition(
      tocFirstBody.contains("雨从傍晚") && !tocFirstBody.contains("第 1 页"),
      "目录短正文不得成为第一章"
    )

    // Three chapters of stand-in original prose. Chapter 2 is the retrieval
    // target for both the lexical and the paraphrase query; chapters 1 and 3 are
    // plausible distractors that share topic words but not the answer.
    let original = """
      第一章 雨落

      雨从傍晚开始下，起初谁也没当回事。林辰把窗户关严，听见远处有人在喊着收衣服。
      街上的行人加快脚步，伞面被风掀得翻过来，路灯下的水花溅起半尺高。他站在窗前看了很久。

      第二章 渡口

      渡口只剩两条船了，船老大蹲在跳板上抽烟，说明早最多接两批人过江，第三批得等下午的潮水。
      排在前头的女人抱着孩子问能不能加塞，船老大摇头，说规矩是昨天夜里定下的，谁也改不了。
      林辰把登记的纸条折好塞进内袋，纸条上盖着一枚红戳，写着重核两个字。

      第三章 药

      药店老板说三个供货商的电话今天全打不通，柜台后面的货架空了一半。
      林辰买了二十天的量，付现金的时候手有点抖。老板说这药后面还会缺，让他省着吃。
      """
    let sourceFile = derivativeRoot.appendingPathComponent("original-fixture.txt")
    try Data(original.utf8).write(to: sourceFile, options: .atomic)

    let importProgress = ImportProgressCollector()
    let manifest = try await core.importDerivativeSource(
      bookID: creation.title,
      from: sourceFile,
      onProgress: { progress in
        await importProgress.accept(progress)
      }
    )
    precondition(creation.bookId == creation.title, "创建响应必须带回可导入的 bookId")
    let importPhases = await importProgress.snapshot()
    precondition(
      importPhases.contains(.decoding)
        && importPhases.contains(.splitting)
        && importPhases.contains(.indexing)
        && importPhases.contains(.committing),
      "导入进度必须覆盖解码、切章、索引和提交：\(importPhases)"
    )
    precondition(manifest.splitStrategy == .headings, "three headings must be used as boundaries")
    precondition(manifest.chapterCount == 3, "expected 3 chapters, got \(manifest.chapterCount)")
    precondition(
      manifest.version == SourceManifest.currentVersion && manifest.layoutDigest?.isEmpty == false,
      "current manifests must bind canon progress to exact chapter boundaries"
    )
    precondition(manifest.detectedEncoding.hasPrefix("utf-8"), manifest.detectedEncoding)

    // Re-import of identical bytes must not rebuild: extraction progress is
    // expensive and a stray second import must not discard it.
    let reimported = try await core.importDerivativeSource(bookID: creation.title, from: sourceFile)
    precondition(reimported.ingestedAt == manifest.ingestedAt, "identical bytes must be a no-op")

    let stagingRoot = derivativeRoot.appendingPathComponent("staging-original.txt")
    try Data(original.utf8).write(to: stagingRoot, options: .atomic)
    let staged = try await core.stagePendingDerivativeSource(from: stagingRoot)
    try FileManager.default.removeItem(at: stagingRoot)
    let loadedStaged = try await core.loadPendingDerivativeSource(id: staged.id)
    precondition(loadedStaged.byteCount == original.utf8.count)
    let stagedURL = try await core.pendingDerivativeSourceFileURL(id: staged.id)
    let stagedBytes = try Data(contentsOf: stagedURL)
    precondition(stagedBytes == Data(original.utf8), "暂存必须保留原始字节，而不是依赖用户文件路径")
    try await core.removePendingDerivativeSource(id: staged.id)
    do {
      _ = try await core.loadPendingDerivativeSource(id: staged.id)
      preconditionFailure("删除暂存后不得再读到记录")
    } catch {
      let message = (error as? InkOSCoreError)?.message ?? error.localizedDescription
      precondition(message.contains("暂存"), "失效暂存必须明确要求重选：\(message)")
    }

    let summary = try await core.derivativeSourceSummary(bookID: creation.title)
    precondition(
      summary.bookKind == .derivative
        && summary.hasSource
        && summary.chapterCount == 3,
      "设置页摘要必须反映已导入原著：\(summary)"
    )

    // A canon cursor with the same source bytes but a different chapter layout
    // must lose only its source-owned layer. The author's overlay digest remains
    // valid and the cursor restarts at chapter 1.
    var staleDelta = ContinuityDelta()
    staleDelta.upsert.entities = [LongFormEntity(
      id: "ENT-stale-layout",
      name: "旧切章实体",
      type: "character"
    )]
    _ = try await core.mergeCanonIntoBaseContinuity(
      bookID: creation.title,
      delta: staleDelta,
      source: "切章布局失效测试"
    )
    let staleProgress = SourceCanonProgress(
      version: SourceCanonProgress.currentVersion,
      bookId: creation.title,
      sourceDigest: manifest.sourceDigest,
      sourceLayoutDigest: "obsolete-layout",
      chapterCount: manifest.chapterCount,
      prefaceExtracted: true,
      sourceCoordinatesVersion: SourceCanonProgress.currentSourceCoordinatesVersion,
      nextChapterIndex: manifest.chapterCount + 1,
      batches: [],
      delta: staleDelta,
      settingsDigest: "keep-author-overlay",
      updatedAt: "2026-01-01T00:00:00Z"
    )
    try JSONEncoder().encode(staleProgress).write(
      to: derivativeRoot.appendingPathComponent(
        "book/books/\(creation.title)/source/canon-progress.json"
      ),
      options: .atomic
    )
    let resetStatus = try await core.derivativeCanonStatus(bookID: creation.title)
    precondition(
      resetStatus.extractedChapters == 0 && !resetStatus.isComplete,
      "chapter-layout changes must restart canon extraction: \(resetStatus)"
    )
    let resetPlan = try await core.fetchLongFormPlan(bookID: creation.title)
    precondition(
      !resetPlan.continuity.entities.contains { $0.id == "ENT-stale-layout" },
      "stale source canon must be removed when its layout changes"
    )
    let resetProgress = try await core.loadCanonProgress(bookID: creation.title, manifest: manifest)
    precondition(resetProgress.sourceLayoutDigest == manifest.layoutDigest)
    precondition(resetProgress.settingsDigest == "keep-author-overlay")

    // Vector totals alone used to report this index as complete even after a bad
    // heading left a manifest chapter with no passage. Corrupt one chapter in the
    // temporary fixture and assert that the preparation snapshot rejects it.
    let indexPath = derivativeRoot.appendingPathComponent(
      "book/books/\(creation.title)/source/passages.sqlite"
    ).path
    try executeSQLite(indexPath, sql: "DELETE FROM passages WHERE chapterIndex = 2;")
    var incompleteIndexRejected = false
    do {
      _ = try await core.derivativePreparationSnapshot(bookID: creation.title)
    } catch {
      incompleteIndexRejected = error.localizedDescription.contains("检索索引不完整")
    }
    precondition(incompleteIndexRejected, "缺 passage 的旧索引不得通过写作准备门禁")

    // Selecting the same source again is no longer a no-op when its stored index
    // is incomplete; it deterministically rebuilds all three SQLite tables.
    _ = try await core.importDerivativeSource(bookID: creation.title, from: sourceFile)
    let rebuiltStatus = try await core.derivativeSourceEmbeddingStatus(bookID: creation.title)
    precondition(rebuiltStatus.total >= 3, "same-source re-import must rebuild missing passages")

    // Equal chapter counts and passage keys do not prove that the database belongs
    // to this manifest. A stale source fingerprint must fail the same readiness gate,
    // then a same-source re-import must rebuild it without touching canon progress.
    try executeSQLite(
      indexPath,
      sql: "UPDATE meta SET value = 'stale-source-digest' WHERE key = 'sourceDigest';"
    )
    var staleFingerprintRejected = false
    do {
      _ = try await core.derivativePreparationSnapshot(bookID: creation.title)
    } catch {
      staleFingerprintRejected = error.localizedDescription.contains("索引指纹不一致")
    }
    precondition(
      staleFingerprintRejected,
      "旧索引即使章节数和 passage key 完整，也不得通过 manifest 指纹门禁"
    )
    _ = try await core.importDerivativeSource(bookID: creation.title, from: sourceFile)
    let fingerprintRebuilt = try await core.derivativeSourceEmbeddingStatus(
      bookID: creation.title
    )
    precondition(fingerprintRebuilt.total == rebuiltStatus.total)

    // Commit is deliberately interrupted after the new original and SQLite file
    // land but before manifest.json. The old directory snapshot must restore all
    // three as one generation; fingerprint validation proves the database was not
    // left paired with either the replacement prose or its manifest.
    let replacementText = original.replacingOccurrences(of: "渡口", with: "码头")
    let rollbackFixture = derivativeRoot.appendingPathComponent("rollback-fixture.txt")
    try Data(replacementText.utf8).write(to: rollbackFixture, options: .atomic)
    var stagedCommitFailed = false
    do {
      _ = try await core.importDerivativeSource(
        bookID: creation.title,
        from: rollbackFixture,
        testingFailureAfterInstalledFiles: 2
      )
    } catch {
      stagedCommitFailed = error.localizedDescription.contains("测试故障注入")
    }
    precondition(stagedCommitFailed, "staging 提交故障必须进入回滚路径")
    let sourceDirectory = derivativeRoot.appendingPathComponent(
      "book/books/\(creation.title)/source",
      isDirectory: true
    )
    let restoredManifest = try JSONDecoder().decode(
      SourceManifest.self,
      from: Data(contentsOf: sourceDirectory.appendingPathComponent("manifest.json"))
    )
    let restoredOriginal = try String(
      contentsOf: sourceDirectory.appendingPathComponent("original.txt"),
      encoding: .utf8
    )
    precondition(restoredManifest.sourceDigest == manifest.sourceDigest)
    precondition(restoredOriginal == original)
    _ = try await core.derivativeSourceEmbeddingStatus(bookID: creation.title)
    let transactionDebris = try FileManager.default.contentsOfDirectory(
      at: sourceDirectory.deletingLastPathComponent(),
      includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(".source-import-")
        || $0.lastPathComponent.hasPrefix(".source-rollback-")
    }
    precondition(transactionDebris.isEmpty, "staging/rollback 临时目录必须清理：\(transactionDebris)")

    // A GB18030 novel decoded as UTF-8 yields U+FFFD rather than throwing, so the
    // scorer — not a first-success loop — is what keeps the text intact.
    // 0x0632 is GB_18030_2000. The first implementation used 0x0630 (GB_2312_80),
    // which this SDK does not map to any NSStringEncoding, so the whole GB18030
    // branch was dead and such a file decoded to U+FFFD soup.
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
    )
    precondition(
      String.availableStringEncodings.contains(gb18030),
      "GB18030 must be a usable NSStringEncoding on this SDK"
    )
    let gbData = original.data(using: gb18030)!
    let gbFile = derivativeRoot.appendingPathComponent("original-gb18030.txt")
    try gbData.write(to: gbFile, options: .atomic)
    let gbCore = InkOSCore(rootURL: derivativeRoot)
    let gbDecoded = try await gbCore.decodeSourceText(gbData)
    precondition(gbDecoded.encoding == "gb18030", "expected gb18030, picked \(gbDecoded.encoding)")
    precondition(gbDecoded.text.contains("渡口只剩两条船"), "gb18030 text must decode intact")
    precondition(!gbDecoded.text.contains("\u{FFFD}"), "a correct decode leaves no replacement chars")

    // Lexical half: two characters, which trigram alone cannot match.
    let ferry = try await core.retrieveDerivativeContext(
      bookID: creation.title,
      keys: ["渡口"],
      query: nil,
      limit: 5
    )
    precondition(!ferry.isEmpty, "a two-character key must still retrieve (segmented mirror)")
    precondition(
      ferry.contains { $0.chapterIndex == 2 },
      "渡口 must retrieve chapter 2, got chapters \(ferry.map(\.chapterIndex))"
    )
    // A two-character key is answerable only by `body_seg`, whose stored text is
    // the space-delimited NLTokenizer mirror. Retrieved prose is rendered into the
    // prompt as a canon quotation, so it must come back as written. Asserting only
    // the chapter index is what let the mirror leak: on a real novel the top hit
    // came back as "灰 雾 之上 那 片" with 133 inserted spaces in 232 characters.
    let ferryHit = ferry.first { $0.chapterIndex == 2 }!
    precondition(
      ferryHit.text.contains("渡口只剩两条船"),
      "seg-only hits must return raw prose, not the segmented mirror: \(ferryHit.text.prefix(40))"
    )
    precondition(
      !ferryHit.text.contains("渡口 只"),
      "retrieved text must not carry tokenizer spacing: \(ferryHit.text.prefix(40))"
    )

    // The original is fully indexed before a derivative begins. A timeline-aware
    // caller must be able to keep a later source chapter out of both FTS tables,
    // rather than leaking that future passage into a writing prompt.
    let beforeFerry = try await core.retrieveDerivativeContext(
      bookID: creation.title,
      keys: ["渡口"],
      query: nil,
      limit: 5,
      maximumSourceChapter: 1
    )
    precondition(
      beforeFerry.isEmpty,
      "maximumSourceChapter must exclude lexical hits from future chapter 2: \(beforeFerry.map(\.chapterIndex))"
    )

    // FTS5 operator words and quotes arrive from beat cards; they must be
    // neutralized as phrases rather than parsed as syntax.
    let hostile = try await core.retrieveDerivativeContext(
      bookID: creation.title,
      keys: ["船老大 AND \"跳板", "NOT 渡口"],
      query: nil,
      limit: 5
    )
    precondition(!hostile.isEmpty, "operator-laden keys must not blow up the MATCH expression")

    final class EmbeddingReportBox: @unchecked Sendable {
      var reports: [SourceEmbeddingStatus] = []
    }
    let embeddingReports = EmbeddingReportBox()
    let status = try await core.embedDerivativeSource(bookID: creation.title) { report in
      embeddingReports.reports.append(report)
    }
    if status.semanticAvailable {
      precondition(
        embeddingReports.reports.contains(where: { $0.total > 0 }),
        "embedding must publish coverage before the pass returns, otherwise the banner stays at 0"
      )
      precondition(status.isComplete, "embedding pass must cover every passage: \(status.embedded)/\(status.total)")
      // A second pass is a no-op; `vector IS NULL` is the queue, so a completed
      // index has nothing left to do.
      let again = try await core.embedDerivativeSource(bookID: creation.title)
      precondition(again.embedded == status.embedded, "a completed embedding pass must be idempotent")

      // Semantic half: this paraphrase shares no distinctive term with the target
      // passage — not 渡口, not 船老大, not 两批. BM25 cannot find it.
      let paraphrase = try await core.retrieveDerivativeContext(
        bookID: creation.title,
        keys: [],
        query: "明天早晨过河的班次名额有限，负责摆渡的人不肯通融",
        limit: 3
      )
      precondition(
        paraphrase.first?.chapterIndex == 2,
        "paraphrase must rank chapter 2 first, got \(paraphrase.map { ($0.chapterIndex, $0.score) })"
      )
      precondition(
        paraphrase.allSatisfy { $0.lexicalRank == nil },
        "no key was supplied, so every hit must come from the semantic half alone"
      )

      let beforeFerrySemantic = try await core.retrieveDerivativeContext(
        bookID: creation.title,
        keys: [],
        query: "明天早晨过河的班次名额有限，负责摆渡的人不肯通融",
        limit: 3,
        maximumSourceChapter: 1
      )
      precondition(
        beforeFerrySemantic.allSatisfy { $0.chapterIndex <= 1 },
        "maximumSourceChapter must exclude semantic future passages: \(beforeFerrySemantic.map(\.chapterIndex))"
      )

      // Keys absent from the source must return nothing rather than the semantic
      // half's least-unrelated guesses. A dot product always has a maximum, so
      // without the guard this fills every slot: measured at 8 of 8 for
      // 量子计算机集群 against a real 21k-passage novel, and every one of those
      // passages would be rendered into the prompt as source canon.
      let absent = try await core.retrieveDerivativeContext(
        bookID: creation.title,
        keys: ["量子计算机集群"],
        query: "量子计算机集群的部署方案",
        limit: 5
      )
      precondition(
        absent.isEmpty,
        "keys with no lexical match must return nothing, got \(absent.count) semantic guesses"
      )

      // Fusion: a passage both halves rank must outrank one only a single half
      // found. That ordering is the entire justification for running both.
      let fused = try await core.retrieveDerivativeContext(
        bookID: creation.title,
        keys: ["渡口", "船老大"],
        query: "明早过江的名额只剩两批，规矩不能改",
        limit: 8
      )
      let both = fused.filter { $0.lexicalRank != nil && $0.semanticRank != nil }
      precondition(!both.isEmpty, "the ferry passage must be found by both halves")
      let singleHalfBest = fused
        .filter { $0.lexicalRank == nil || $0.semanticRank == nil }
        .map(\.score)
        .max() ?? 0
      precondition(
        both.map(\.score).min()! > singleHalfBest,
        "RRF must rank dual-half hits above single-half hits"
      )
      print("Derivative retrieval probe passed: semantic on, \(status.embedded)/\(status.total) embedded")
    } else {
      // macOS 13: BM25 must still work on its own rather than the call failing.
      precondition(!ferry.isEmpty, "BM25 must remain usable without the semantic half")
      print("Derivative retrieval probe passed: semantic unavailable, BM25 only")
    }

    _ = try await core.deleteBook(id: creation.title)
  }

  private static func executeSQLite(_ path: String, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
      path,
      &database,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK else {
      defer { sqlite3_close(database) }
      throw InkOSCoreError("测试 SQLite 打开失败", statusCode: 500)
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
      let detail = message.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(message)
      throw InkOSCoreError("测试 SQLite 执行失败：\(detail)", statusCode: 500)
    }
  }

  /// Canon extraction over an imported original: batching, checkpointed resume,
  /// per-batch failure containment, chapter renumbering, and overlay precedence.
  ///
  /// Every assertion here is offline — the extraction model is the stub protocol.
  /// The renumbering case is the one that would otherwise reach a customer: the
  /// model reads *source* chapters and reports `availableFromChapter: 180`, while
  /// `LongFormContinuity.validated` bounds that field by the *derivative* book's
  /// `targetChapters`. Without the rewrite the pass dies on its first knowledge
  /// entry, and the failure looks like a model problem rather than a units bug.
  private static func assertCanonExtractionResumesAndOutranks(root: URL) async throws {
    let canonRoot = root.appendingPathComponent("canon-extract", isDirectory: true)
    let core = InkOSCore(rootURL: canonRoot)
    let fileManager = FileManager.default

    let creation = try await core.createBook(CreateBookRequest(
      title: "正典抽取测试书",
      language: "zh",
      genre: "xuanhuan",
      platform: "tomato",
      kind: .derivative,
      sourceTitle: "测试原著标题",
      timelineAnchorLabel: "序章锚点事件",
      timelineStartDayOffset: -30,
      targetChapters: 2,
      chapterWords: 1_000,
      totalWords: "2000",
      targetTotalWords: 2_000,
      volumeCount: 1,
      chapterWordTolerance: 15,
      premise: "验证原著正典抽取。",
      characters: "主角沿用原著人物。",
      protagonistProfile: "主角谨慎，习惯先确认再行动；缺陷是不肯求助。",
      protagonistReviewed: true,
      worldbuilding: "沿用原著设定。",
      outline: "第一章在原著分歧点介入。",
      volumePlan: "第一卷1-2章。",
      pacing: "一章推进一个目标。",
      style: "第三人称有限视角。",
      constraints: "不得与原著既有事实冲突"
    ))
    let bookID = creation.title

    let config: [String: Any] = [
      "provider": "openai",
      "model": "writer-test",
      "reviewModel": "writer-test",
      "extractionModel": "extraction-test",
      "baseUrl": "http://127.0.0.1:8765/v1",
      "reviewBaseUrl": "http://127.0.0.1:8765/v1",
      "apiKey": "test-key",
      "reviewApiKey": "test-key",
      "stream": false,
      "thinkingBudget": 0,
      "apiFormat": "chat",
    ]
    try JSONSerialization.data(withJSONObject: config)
      .write(to: canonRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

    // Three chapters, each over half the batch budget, so the planner is forced to
    // split them across three calls. A fixture small enough to fit one batch would
    // assert nothing about resume.
    let filler = String(repeating: "他沿着江堤往北走，雨一直没停。", count: 1_800)
    let preface = "作者序言：序章锚点事件发生。" + String(
      repeating: "这段前言应保留供检索和正典抽取，但不占正文章号。",
      count: 12
    )
    let original = preface + "\n\n" + (1...3)
      .map { chapter in
        let anchor = chapter == 2 ? "主线锚点事件在这一章发生。\n\n" : ""
        return "第\(chapter)章 测试\n\n\(anchor)\(filler)"
      }
      .joined(separator: "\n\n")
    let sourceFile = canonRoot.appendingPathComponent("canon-fixture.txt")
    try Data(original.utf8).write(to: sourceFile, options: .atomic)
    let manifest = try await core.importDerivativeSource(bookID: bookID, from: sourceFile)
    precondition(manifest.chapterCount == 3, "expected 3 chapters, got \(manifest.chapterCount)")
    precondition(
      manifest.chapters.contains { $0.index == 0 },
      "章节标题前的前言应保留为可检索的第 0 段"
    )
    _ = try await core.saveDerivativePreparationIntent(
      bookID: bookID,
      settingsText: "林辰改归乙方，渡船每日只发一班。",
      embedRequested: false
    )
    let initialPreparation = try await core.derivativePreparationSnapshot(bookID: bookID)
    precondition(!initialPreparation.isComplete && !initialPreparation.overlayComplete)

    // Numeric chapter planning remains independent from the retained preface.
    // The extraction calls below verify that index 0 is scheduled first.
    let plans = await core.planCanonBatches(chapters: manifest.chapters, from: 1)
    precondition(plans.count == 3, "每章都超过半个预算，应切成 3 批，实际 \(plans.count)")
    precondition(plans[0].chapters.count == 1 && plans[0].index == 1)
    precondition(plans[2].startChapter == 3 && plans[2].endChapter == 3)
    let resumed = await core.planCanonBatches(
      chapters: manifest.chapters,
      from: 3,
      indexOffset: 2
    )
    precondition(resumed.count == 1, "从第 3 章续跑只应剩 1 批")
    precondition(resumed[0].index == 3, "续跑的批次号必须接着 checkpoint，不能从 1 重开")

    // A v1 checkpoint may have advanced its numeric cursor without ever recording
    // the retained index-0 preface. Resume must schedule that preface alone, then
    // jump directly to the cursor instead of reading the skipped chapters again.
    let legacyResume = SourceCanonProgress(
      version: SourceCanonProgress.currentVersion,
      bookId: bookID,
      sourceDigest: manifest.sourceDigest,
      sourceLayoutDigest: manifest.layoutDigest,
      chapterCount: manifest.chapterCount,
      prefaceExtracted: false,
      sourceCoordinatesVersion: SourceCanonProgress.currentSourceCoordinatesVersion,
      nextChapterIndex: 3,
      batches: [],
      delta: ContinuityDelta(),
      settingsDigest: nil,
      updatedAt: "2026-01-01T00:00:00Z"
    )
    let legacyPlans = await core.planPendingCanonBatches(
      manifest: manifest,
      progress: legacyResume
    )
    precondition(
      legacyPlans.count == 2
        && legacyPlans[0].chapters.map(\.index) == [0]
        && legacyPlans[1].chapters.map(\.index) == [3],
      "旧 checkpoint 恢复时卷首必须独立，且正文直接从游标续跑：\(legacyPlans)"
    )

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }

    let prefaceBatch = """
      {"upsert":{
        "entities":[{"id":"ENT-lin","name":"林辰","type":"character"}],
        "timeline":[{"id":"TL-preface-anchor","label":"序章锚点事件发生","sourceDay":0,"sourceChapter":0}]}}
      """
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: prefaceBatch, stream: false),
    ])

    let prefaceOnly = try await core.extractDerivativeCanon(bookID: bookID, maxBatches: 1)
    precondition(
      prefaceOnly.extractedChapters == 0 && !prefaceOnly.isComplete && prefaceOnly.batchCount == 1,
      "卷首抽取只能推进卷首 checkpoint，不能虚增正文章节：\(prefaceOnly)"
    )
    let prefacePrompt = AutomatedRevisionLLMProtocol.observedPrompts().first ?? ""
    precondition(prefacePrompt.contains("序章锚点事件"), "卷首锚点必须进入抽取提示词")
    let afterPreface = try await core.fetchLongFormPlan(bookID: bookID)
    guard let prefaceMilestone = afterPreface.continuity.timeline.first(where: { $0.id == "TL-preface-anchor" })
    else { preconditionFailure("卷首锚点没有进入正典") }
    precondition(
      prefaceMilestone.sourceChapter == 0 && prefaceMilestone.sourceDay == 0,
      "卷首锚点必须保留 sourceChapter=0 与全局 sourceDay：\(prefaceMilestone)"
    )

    // The model answers in *source* chapter numbers throughout: chapter 180 for a
    // knowledge boundary, 240 for a hook, a timeline entry at order 7. All three
    // are out of range for a 2-chapter derivative book. It also gives 林辰 a new
    // ID and a conflicting type: source extraction must retain ENT-lin/character.
    let batchOne = """
      {"upsert":{
        "immutableCanon":[{"id":"CANON-river","category":"world","statement":"江面在雨季会涨"}],
        "worldRules":[{"id":"RULE-ferry","statement":"渡船每日只发两班"}],
        "entities":[
          {"id":"ENT-lin-renamed","name":" 林 辰 ","type":"object","owner":"甲"},
          {"id":"ENT-lin","name":"船老大","type":"character","location":"渡口"}],
        "knowledgeBoundaries":[{"factId":"KNOW-seal","statement":"红戳的含义只有船老大知道",
          "allowedKnowers":["船老大"],"forbiddenKnowers":["船老大","路人"],
          "availableFromChapter":180,"revealByChapter":200}],
        "timeline":[{"id":"TL-flood","label":"江水第一次上涨","order":7,"sourceDay":0,
          "earliestChapter":180,"latestChapter":190}],
        "hooks":[{"hookId":"HOOK-seal","description":"红戳来源未解","openFromChapter":240}]
      }}
      """
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: batchOne, stream: false),
    ])

    // One numeric batch only: the UI extracts incrementally, and the cap is what
    // makes a partial run observable after the preface checkpoint has landed.
    let first = try await core.extractDerivativeCanon(bookID: bookID, maxBatches: 1)
    precondition(first.extractedChapters == 1, "应只抽完第 1 章，实际 \(first.extractedChapters)")
    precondition(!first.isComplete, "3 章里只抽了 1 章，不能报完成")
    precondition(first.entityCount == 2 && first.canonCount == 1)
    precondition(first.batchCount == 2)
    let firstPrompt = AutomatedRevisionLLMProtocol.observedPrompts().first ?? ""
    precondition(firstPrompt.contains("原著《测试原著标题》"), "抽取提示词必须使用原著标题")
    precondition(firstPrompt.contains("序章锚点事件"), "抽取提示词必须说明全局时间锚点")
    precondition(
      firstPrompt.contains("不得把当前批次最早事件重置为第 0 天"),
      "sourceDay 不能在每个批次重新起算"
    )
    precondition(
      firstPrompt.contains("同一人物不得同时出现在 allowedKnowers 和 forbiddenKnowers"),
      "抽取提示必须禁止知情/禁知重叠"
    )

    // Chapter fields must have been rewritten to the derivative book's own units.
    let afterFirst = try await core.fetchLongFormPlan(bookID: bookID)
    guard let knowledge = afterFirst.continuity.knowledgeBoundaries
      .first(where: { $0.factId == "KNOW-seal" })
    else { preconditionFailure("知识边界没有进入正典") }
    precondition(
      knowledge.availableFromChapter == 1,
      "原著章号 180 必须改写为衍生作第 1 章，实际 \(knowledge.availableFromChapter)"
    )
    precondition(knowledge.revealByChapter == nil, "revealByChapter 必须清空")
    precondition(
      knowledge.allowedKnowers == ["船老大"] && knowledge.forbiddenKnowers == ["路人"],
      "抽取必须从禁知列表去掉与知情重叠的人物：allowed=\(knowledge.allowedKnowers) forbidden=\(knowledge.forbiddenKnowers)"
    )
    precondition(
      knowledge.markers.contains("source-chapter-1"),
      "原著出处必须留在 markers 里：\(knowledge.markers)"
    )
    guard let hook = afterFirst.continuity.hooks.first(where: { $0.hookId == "HOOK-seal" })
    else { preconditionFailure("伏笔没有进入正典") }
    precondition(hook.openFromChapter == 1, "伏笔章号必须改写为 1，实际 \(hook.openFromChapter)")
    precondition(hook.resolveByChapter == nil && hook.requiredVolumeNumber == nil)
    guard let milestone = afterFirst.continuity.timeline.first(where: { $0.id == "TL-flood" })
    else { preconditionFailure("时间线没有进入正典") }
    precondition(
      milestone.earliestChapter == 1 && milestone.latestChapter == 1,
      "时间线窗口必须改写为第 1 章"
    )
    precondition(
      milestone.sourceDay == nil,
      "不含全局锚点的批次即使输出 sourceDay 也必须丢弃"
    )
    let linAfterFirst = afterFirst.continuity.entities.filter {
      $0.name == "林辰" || $0.name == " 林 辰 "
    }
    precondition(
      linAfterFirst.count == 1
        && linAfterFirst[0].id == "ENT-lin"
        && linAfterFirst[0].type == "character"
        && linAfterFirst[0].owner == "甲",
      "同名实体必须保留首个 canonical ID/type 并合并新属性：\(linAfterFirst)"
    )
    let boatAfterFirst = afterFirst.continuity.entities.filter { $0.name == "船老大" }
    precondition(
      boatAfterFirst.count == 1
        && boatAfterFirst[0].id == "ENT-lin-2"
        && boatAfterFirst[0].location == "渡口",
      "同 ID、异名实体必须稳定重映射并保留为独立正典：\(boatAfterFirst)"
    )
    let debugURL = canonRoot.appendingPathComponent("data/debug/events.jsonl")
    let debugText = try String(contentsOf: debugURL, encoding: .utf8)
    precondition(
      debugText.contains("canon.entity.type_conflict") && debugText.contains("ENT-lin-renamed"),
      "类型冲突必须记录 warning/debug，不能静默生成第二实体"
    )
    precondition(
      debugText.contains("canon.knowledge.knower_overlap") && debugText.contains("KNOW-seal"),
      "知情/禁知重叠必须记录 warning，不能让整批正典校验失败"
    )

    // A batch that never returns parseable JSON must not roll back the batch that
    // already landed or let a faster later response jump over the gap. Batch 3
    // completes while batch 2 is held, then batch 2 exhausts both retries; the
    // later success must be discarded and requested again on resume.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "这不是 JSON",
        stream: false,
        waitForRelease: true,
        promptContains: "第 2 至 第 2 章"
      ),
      AutomatedRevisionStubResponse(
        content: "还是不是 JSON",
        stream: false,
        waitForRelease: true,
        promptContains: "第 2 至 第 2 章"
      ),
      AutomatedRevisionStubResponse(
        content: """
          {"upsert":{"entities":[{"id":"ENT-too-early","name":"越序实体","type":"character"}]}}
          """,
        stream: false,
        promptContains: "第 3 至 第 3 章"
      ),
    ])
    var batchFailed = false
    do {
      let failedTask = Task { try await core.extractDerivativeCanon(bookID: bookID) }
      for _ in 0..<200 {
        if AutomatedRevisionLLMProtocol.requestCount() >= 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      precondition(
        AutomatedRevisionLLMProtocol.requestCount() >= 2,
        "失败场景也必须并发启动后续批次"
      )
      AutomatedRevisionLLMProtocol.releaseBlockedResponse()
      _ = try await failedTask.value
    } catch {
      batchFailed = true
      let message = (error as? InkOSCoreError)?.message ?? error.localizedDescription
      precondition(
        message.contains("第2-2章") && message.contains("继续"),
        "失败信息要指明是哪一批并说明可续跑：\(message)"
      )
    }
    precondition(batchFailed, "两次都返回非 JSON 时该批必须失败")
    let failedBatchPrompts = AutomatedRevisionLLMProtocol.observedPrompts()
    precondition(
      !failedBatchPrompts.isEmpty && failedBatchPrompts.allSatisfy { $0.contains("ENT-lin｜林辰") },
      "后续批次提示词必须看到前一批刚登记的实体名册"
    )
    let afterFailure = try await core.derivativeCanonStatus(bookID: bookID)
    precondition(
      afterFailure.extractedChapters == 1,
      "失败的一批不能回滚已完成的进度，实际 \(afterFailure.extractedChapters)"
    )
    precondition(afterFailure.batchCount == 2, "越序返回不能追加 batch checkpoint")
    let planAfterFailure = try await core.fetchLongFormPlan(bookID: bookID)
    precondition(
      !planAfterFailure.continuity.entities.contains { $0.name == "越序实体" },
      "后发成功响应不得越过失败批次进入正典"
    )

    // Resume: the remaining two numeric batches complete; neither preface nor
    // chapter 1 is re-read.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: """
          {"upsert":{"entities":[{"id":"ENT-boat","name":"船老大","type":"character"}],
            "timeline":[{"id":"TL-depart","label":"渡船离岸","sourceDay":0,"sourceChapter":2}]}}
          """,
        stream: false,
        waitForRelease: true,
        promptContains: "第 2 至 第 2 章"
      ),
      AutomatedRevisionStubResponse(
        content: """
          {"upsert":{"entities":[{"id":"ENT-shop","name":"药店老板","type":"character"}]}}
          """,
        stream: false,
        waitForRelease: true,
        promptContains: "第 3 至 第 3 章"
      ),
    ])
    let progressCollector = CanonProgressCollector()
    let completeTask = Task {
      try await core.extractDerivativeCanon(
        bookID: bookID,
        onProgress: { status in
          await progressCollector.accept(status)
        }
      )
    }
    var concurrentRequestsObserved = false
    for _ in 0..<200 {
      if AutomatedRevisionLLMProtocol.requestCount() == 2 {
        concurrentRequestsObserved = true
        break
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    AutomatedRevisionLLMProtocol.releaseBlockedResponse()
    let complete = try await completeTask.value
    precondition(
      concurrentRequestsObserved,
      "下一批请求必须在上一批返回前启动，正典抽取才能消除串行等待"
    )
    let progressUpdates = await progressCollector.snapshot()
    precondition(
      progressUpdates.map(\.extractedChapters) == [2, 3],
      "每个有序 checkpoint 都必须立即回调 UI 进度，实际 \(progressUpdates.map(\.extractedChapters))"
    )
    precondition(
      progressUpdates.last == complete,
      "最终进度回调必须与 extractDerivativeCanon 返回状态一致"
    )
    precondition(complete.isComplete, "三批跑完后应报完成")
    precondition(
      complete.extractedChapters == 3,
      "应抽完 3 章，实际 \(complete.extractedChapters)"
    )
    precondition(complete.batchCount == 4, "批次数应为卷首加 3 章，实际 \(complete.batchCount)")
    precondition(complete.entityCount == 3, "三批共 3 个实体，实际 \(complete.entityCount)")
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 2,
      "续跑只该发 2 次请求，已完成的批次不能重跑"
    )
    // Two milestones from two different batches must not collide on `order`.
    let afterResume = try await core.fetchLongFormPlan(bookID: bookID)
    let orders = afterResume.continuity.timeline.map(\.order)
    precondition(Set(orders).count == orders.count, "跨批次的时间线 order 撞车了：\(orders)")
    guard let anchored = afterResume.continuity.timeline.first(where: { $0.id == "TL-depart" })
    else { preconditionFailure("锚点批次的时间线没有进入正典") }
    precondition(
      anchored.sourceDay == nil && anchored.sourceChapter == 2,
      "不含卷首全局锚点的批次必须丢弃 sourceDay，但保留 sourceChapter"
    )
    let boatAfterResume = afterResume.continuity.entities.filter { $0.name == "船老大" }
    precondition(
      boatAfterResume.count == 1 && boatAfterResume[0].id == "ENT-lin-2",
      "后续批次的同名实体必须继续命中已重映射的 canonical ID：\(boatAfterResume)"
    )

    let retrievalKeys = try await core.derivativeRetrievalKeys(
      bookID: bookID,
      beat: ChapterBeat(
        number: 1,
        goal: "林辰去药店老板处确认物资",
        scenes: ["船老大在渡口拦住林辰"],
        requiredEvents: ["药店老板交出清单"],
        focusCharacters: ["林辰"]
      )
    )
    precondition(
      retrievalKeys.contains("林辰")
        && retrievalKeys.contains("船老大")
        && retrievalKeys.contains("药店老板"),
      "检索键必须覆盖 focusCharacters 以及目标/场景/事件里的正典实体：\(retrievalKeys)"
    )

    // A completed pass is a no-op and costs no calls.
    AutomatedRevisionLLMProtocol.configure([])
    let again = try await core.extractDerivativeCanon(bookID: bookID)
    precondition(again.isComplete && again.batchCount == 4)
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 0,
      "已完成的抽取不应再发请求"
    )

    // The settings text is authoritative: it overrides an owner the source set.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: """
          {"upsert":{"entities":[{"id":"ENT-lin","name":"林辰","type":"character","owner":"乙"}],
            "worldRules":[{"id":"RULE-ferry","statement":"渡船每日只发一班"}],
            "timeline":[{"id":"TL-author","label":"主角抵达渡口","sourceDay":99,"sourceChapter":99}]}}
          """,
        stream: false
      ),
    ])
    let overlaid = try await core.extractDerivativeSettingsOverlay(
      bookID: bookID,
      settingsText: "林辰改归乙方，渡船每日只发一班。"
    )
    precondition(overlaid.hasSettingsOverlay, "设定覆盖后状态要标记出来")
    let afterOverlay = try await core.fetchLongFormPlan(bookID: bookID)
    guard let lin = afterOverlay.continuity.entities.first(where: { $0.id == "ENT-lin" })
    else { preconditionFailure("实体丢失") }
    precondition(lin.owner == "乙", "设定文本必须盖过原著抽取，实际 owner=\(lin.owner ?? "nil")")
    guard let rule = afterOverlay.continuity.worldRules.first(where: { $0.id == "RULE-ferry" })
    else { preconditionFailure("世界规则丢失") }
    precondition(rule.statement.contains("一班"), "设定文本的规则必须生效：\(rule.statement)")
    guard let authorMilestone = afterOverlay.continuity.timeline.first(where: { $0.id == "TL-author" })
    else { preconditionFailure("作者设定的时间线没有进入 overlay") }
    precondition(
      authorMilestone.sourceDay == nil && authorMilestone.sourceChapter == nil,
      "作者设定属于衍生作轴，不能伪装成原著事件"
    )
    let completePreparation = try await core.derivativePreparationSnapshot(bookID: bookID)
    precondition(
      completePreparation.isComplete && completePreparation.overlayComplete,
      "正典完成且 overlay 已登记后，持久化准备状态应完整"
    )

    // v1.2 books predate preparation.json. A missing file is recoverable from
    // the source and checkpoint; an existing malformed file is data corruption.
    let preparationURL = canonRoot.appendingPathComponent(
      "book/books/\(bookID)/source/preparation.json"
    )
    let savedPreparation = try Data(contentsOf: preparationURL)
    try fileManager.removeItem(at: preparationURL)
    let legacyPreparation = try await core.derivativePreparationSnapshot(bookID: bookID)
    precondition(
      legacyPreparation.intent.settingsText.isEmpty
        && legacyPreparation.intent.embedRequested
        && legacyPreparation.overlayComplete,
      "旧版缺失 preparation.json 时必须合成可续跑 intent：\(legacyPreparation)"
    )
    try Data("{".utf8).write(to: preparationURL, options: .atomic)
    do {
      _ = try await core.derivativePreparationSnapshot(bookID: bookID)
      preconditionFailure("损坏的 preparation.json 必须报告格式错误")
    } catch let error as InkOSCoreError {
      precondition(
        error.statusCode == 503 && error.message.contains("格式错误"),
        "损坏准备记录应返回可诊断的 503：\(error)"
      )
    }
    try savedPreparation.write(to: preparationURL, options: .atomic)

    // A damaged canon checkpoint must stop preparation with a diagnostic. Treating
    // it as a fresh pass would silently discard a long extraction and duplicate its
    // already-projected facts.
    let canonProgressURL = canonRoot.appendingPathComponent(
      "book/books/\(bookID)/source/canon-progress.json"
    )
    let savedCanonProgress = try Data(contentsOf: canonProgressURL)
    try Data("{".utf8).write(to: canonProgressURL, options: .atomic)
    do {
      _ = try await core.derivativeCanonStatus(bookID: bookID)
      preconditionFailure("损坏的 canon-progress.json 必须报告格式错误")
    } catch let error as InkOSCoreError {
      precondition(
        error.statusCode == 503 && error.message.contains("正典进度格式错误"),
        "损坏正典进度应返回可诊断的 503：\(error)"
      )
    }
    try savedCanonProgress.write(to: canonProgressURL, options: .atomic)

    // The override lives in `manualOverlay`, not in the extracted base: a later
    // re-extraction must not be able to win the owner back.
    let projectionURL = canonRoot.appendingPathComponent(
      "book/books/\(bookID)/story/runtime/continuity-projection.json"
    )
    precondition(fileManager.fileExists(atPath: projectionURL.path), "投影文件缺失")
    let projection = try JSONDecoder().decode(
      ContinuityProjection.self,
      from: Data(contentsOf: projectionURL)
    )
    precondition(
      projection.manualOverlay.upsert.entities.contains { $0.id == "ENT-lin" && $0.owner == "乙" },
      "设定覆盖必须写进 manualOverlay"
    )
    precondition(
      projection.baseContinuity.entities.contains { $0.id == "ENT-lin" && $0.owner == "甲" },
      "原著抽取的值应留在 baseContinuity，由 overlay 在投影时盖掉"
    )

    // Unchanged settings text must not re-issue the call.
    AutomatedRevisionLLMProtocol.configure([])
    _ = try await core.extractDerivativeSettingsOverlay(
      bookID: bookID,
      settingsText: "林辰改归乙方，渡船每日只发一班。"
    )
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 0,
      "设定文本没变时不应重复抽取"
    )

    // Re-importing the same original keeps the checkpoint; different bytes drop it,
    // because the progress describes a source that no longer exists.
    let boundBeforeReplacement = await core.resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: afterOverlay.continuity
    )
    precondition(
      boundBeforeReplacement.anchorMilestoneID == "TL-preface-anchor"
        && boundBeforeReplacement.anchorSourceChapter == 0,
      "原著替换夹具需要先持久化已绑定锚点：\(boundBeforeReplacement)"
    )
    _ = try await core.saveDerivativeTimeline(bookID: bookID, boundBeforeReplacement)
    _ = try await core.importDerivativeSource(bookID: bookID, from: sourceFile)
    let afterSameImport = try await core.derivativeCanonStatus(bookID: bookID)
    precondition(afterSameImport.isComplete, "同字节重导入不应清掉抽取进度")
    let unchangedTimeline = await core.loadDerivativeTimeline(bookID: bookID)
    precondition(
      unchangedTimeline.anchorMilestoneID == "TL-preface-anchor"
        && unchangedTimeline.anchorSourceChapter == 0,
      "同字节重导入不应清除有效锚点"
    )
    let replacement = canonRoot.appendingPathComponent("canon-fixture-2.txt")
    try Data((original + "\n\n第4章 新增\n\n\(filler)").utf8).write(to: replacement, options: .atomic)
    _ = try await core.importDerivativeSource(bookID: bookID, from: replacement)
    let afterReimport = try await core.derivativeCanonStatus(bookID: bookID)
    precondition(
      afterReimport.extractedChapters == 0 && !afterReimport.isComplete,
      "换了原著就必须重抽，实际已抽 \(afterReimport.extractedChapters) 章"
    )
    let afterReplacementPlan = try await core.fetchLongFormPlan(bookID: bookID)
    precondition(
      !afterReplacementPlan.continuity.immutableCanon.contains { $0.id == "CANON-river" },
      "换原著后旧 baseContinuity 正典必须清空"
    )
    precondition(
      afterReplacementPlan.continuity.entities.contains { $0.id == "ENT-lin" && $0.owner == "乙" },
      "换原著只能清 baseContinuity，作者 manualOverlay 必须保留"
    )
    let clearedTimeline = await core.loadDerivativeTimeline(bookID: bookID)
    precondition(
      clearedTimeline.anchorMilestoneID == nil
        && clearedTimeline.anchorSourceChapter == nil
        && clearedTimeline.anchorLabel == "序章锚点事件"
        && clearedTimeline.startDayOffset == -30,
      "换源必须只清派生绑定并保留用户时间轴输入：\(clearedTimeline)"
    )
    var replacementContinuity = LongFormContinuity()
    replacementContinuity.timeline = [
      LongFormTimelineMilestone(
        id: "TL-replacement-anchor",
        order: 1,
        label: "序章锚点事件重新发生",
        earliestChapter: 1,
        latestChapter: 1,
        sourceChapter: 4
      ),
    ]
    let replacementBinding = await core.resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: replacementContinuity
    )
    precondition(
      replacementBinding.anchorMilestoneID == "TL-replacement-anchor"
        && replacementBinding.anchorSourceChapter == 4,
      "清除旧绑定后应按保留的标签绑定新原著：\(replacementBinding)"
    )

    print("Canon extraction probe passed: preface + 3 batches, entity de-dup + resume + overlay precedence")
    _ = try await core.deleteBook(id: bookID)
  }

  /// Context window and max output tokens are shared LLM settings. Missing file
  /// keys must surface as 200 000 / 16 384, persist when saved, shrink story
  /// context on a tight window, and send `max_tokens: 16384` even when the file
  /// never stored the key — omitting it used to leave the request unbounded.
  private static func assertLLMRequestBudgetConfig(root: URL) async throws {
    precondition(
      InkOSCore.resolvedContextWindow([:]) == InkOSConfig.defaultContextWindow
    )
    precondition(InkOSCore.resolvedMaxTokens([:]) == InkOSConfig.defaultMaxTokens)
    precondition(
      InkOSCore.storyContextCharacterBudget(base: 60_000, raw: [:]) == 60_000,
      "a 200k window must keep the historical 60k story-context share"
    )
    let tight: [String: Any] = ["contextWindow": 32_000, "maxTokens": 16_000]
    precondition(
      InkOSCore.storyContextCharacterBudget(base: 100_000, raw: tight) == 9_600,
      "a 32k window with 16k output must cap story context to 60% of remaining input"
    )
    let overflow: [String: Any] = ["contextWindow": 8_192, "maxTokens": 16_384]
    precondition(
      InkOSCore.resolvedMaxTokens(overflow) == 8_192 - 1_024,
      "output must leave prompt room inside the context window"
    )

    let emptyRoot = root.appendingPathComponent("llm-budget-defaults", isDirectory: true)
    let emptyCore = InkOSCore(rootURL: emptyRoot)
    let fetched = try await emptyCore.fetchInkOSConfig()
    precondition(fetched.contextWindow == InkOSConfig.defaultContextWindow)
    precondition(fetched.maxTokens == InkOSConfig.defaultMaxTokens)

    let applied = try await emptyCore.updateInkOSConfig(
      InkOSConfigUpdate(
        model: "writer-test",
        reviewModel: "reviewer-test",
        baseUrl: "https://example.invalid/v1",
        reviewBaseUrl: "https://example.invalid/v1",
        contextWindow: 128_000,
        maxTokens: 8_192
      )
    )
    precondition(applied.ok)
    precondition(applied.fields.contains("contextWindow"))
    precondition(applied.fields.contains("maxTokens"))
    let saved = try await emptyCore.fetchInkOSConfig()
    precondition(saved.contextWindow == 128_000)
    precondition(saved.maxTokens == 8_192)

    let requestRoot = root.appendingPathComponent("llm-budget-default-request", isDirectory: true)
    let requestCore = InkOSCore(rootURL: requestRoot)
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
    try JSONSerialization.data(withJSONObject: config)
      .write(to: requestRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: "{\"ok\":true}", stream: false),
    ])
    _ = try await requestCore.requestLLM(prompt: "只输出 ok", role: .primary, json: true)
    precondition(
      AutomatedRevisionLLMProtocol.observedMaxTokens() == [InkOSConfig.defaultMaxTokens],
      "unset maxTokens must still send 16384, saw \(AutomatedRevisionLLMProtocol.observedMaxTokens())"
    )
    print("LLM request budget config probe passed")
  }

  /// A completion that ran out of budget — no prose at all, or JSON cut off
  /// mid-object — must be retried at a *raised* `max_tokens`, must stop once the
  /// ceiling can rise no further, and must report a message naming the fix. Truncated
  /// prose and transport failures must not raise anything. A model name the relay
  /// carries no channel for must still fail on the first attempt.
  ///
  /// The reasoning pass and the prose share one `max_tokens` budget, and its length
  /// varies run to run: measured 5 347 to 16 383 tokens across identical requests
  /// for the same beat prompt against `deepseek-v4-flash`. So a ceiling near the
  /// margin fails a large fraction of the time and the failure looks random.
  ///
  /// This probe previously asserted the opposite — that an exhausted budget is never
  /// retried — on the reasoning that a retry costs a full upstream reasoning pass
  /// for a deterministic outcome. The premise was wrong: the outcome is not
  /// deterministic, and the same prompt succeeds at a higher ceiling. `max_tokens`
  /// is a ceiling rather than a reservation, so raising it costs nothing on the
  /// requests that were already passing. Chapter 1 of 《灰雾之前》 failed three
  /// straight attempts at an unchanged 16 384 before this changed.
  ///
  /// The `observedMaxTokens` assertions are the real point. A regression that keeps
  /// the retry but drops the raise reproduces that failure exactly while still
  /// passing any count-only check.
  private static func assertEmptyContentRetriesAtRaisedBudget(root: URL) async throws {
    let budgetRoot = root.appendingPathComponent("budget-exhaustion", isDirectory: true)
    let budgetCore = InkOSCore(rootURL: budgetRoot)
    let config: [String: Any] = [
      "provider": "openai",
      "model": "reasoning-test",
      "reviewModel": "reasoning-test",
      "baseUrl": "http://127.0.0.1:8765/v1",
      "reviewBaseUrl": "http://127.0.0.1:8765/v1",
      "apiKey": "test-key",
      "reviewApiKey": "test-key",
      "stream": false,
      "thinkingBudget": 0,
      "maxTokens": 16_384,
      "apiFormat": "chat",
    ]
    try JSONSerialization.data(withJSONObject: config)
      .write(to: budgetRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }

    // Streamed: reasoning deltas arrive, prose never does, stream ends on length.
    // The retry doubles the ceiling and the second attempt succeeds.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "",
        stream: true,
        finishReason: "length",
        reasoningContent: String(repeating: "推理占位。", count: 200)
      ),
      AutomatedRevisionStubResponse(content: "{\"ok\":true}", stream: true),
    ])
    let streamRecovered = try await budgetCore.requestLLM(
      prompt: "写一章正文",
      role: .primary,
      json: true,
      onPartialContent: { _ in }
    )
    precondition(
      streamRecovered.content.contains("ok"),
      "a raised ceiling must recover the call, got: \(streamRecovered.content)"
    )
    precondition(
      AutomatedRevisionLLMProtocol.observedMaxTokens() == [16_384, 32_768],
      "retry must double the ceiling, saw \(AutomatedRevisionLLMProtocol.observedMaxTokens())"
    )

    // Exhausted at every ceiling: the doubling runs out of attempts and the error
    // names both the ceiling it reached and the shared-budget reason.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "", stream: false, finishReason: "length", reasoningContent: "推理占位。"
      ),
      AutomatedRevisionStubResponse(
        content: "", stream: false, finishReason: "length", reasoningContent: "推理占位。"
      ),
      AutomatedRevisionStubResponse(
        content: "", stream: false, finishReason: "length", reasoningContent: "推理占位。"
      ),
    ])
    var exhaustedMessage = ""
    do {
      _ = try await budgetCore.requestLLM(prompt: "写一章正文", role: .primary, json: true)
      preconditionFailure("an empty completion at every ceiling must not succeed")
    } catch {
      exhaustedMessage = error.localizedDescription
    }
    precondition(
      exhaustedMessage.contains("max_tokens"),
      "budget error must name max_tokens, got: \(exhaustedMessage)"
    )
    precondition(
      exhaustedMessage.contains("推理模型"),
      "budget error must explain the shared reasoning budget, got: \(exhaustedMessage)"
    )
    precondition(
      AutomatedRevisionLLMProtocol.observedMaxTokens() == [16_384, 32_768, 65_536],
      "each attempt must raise the ceiling, saw \(AutomatedRevisionLLMProtocol.observedMaxTokens())"
    )

    // Already at the retry ceiling on the first call: doubling cannot help, so the
    // call must fail immediately rather than pay for two more reasoning passes.
    let ceilingRoot = root.appendingPathComponent("budget-at-ceiling", isDirectory: true)
    let ceilingCore = InkOSCore(rootURL: ceilingRoot)
    var ceilingConfig = config
    ceilingConfig["maxTokens"] = InkOSCore.maxTokensRetryCeiling
    try JSONSerialization.data(withJSONObject: ceilingConfig)
      .write(to: ceilingRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "", stream: false, finishReason: "length", reasoningContent: "推理占位。"
      ),
      AutomatedRevisionStubResponse(content: "{\"ok\":true}", stream: false),
    ])
    do {
      _ = try await ceilingCore.requestLLM(prompt: "写一章正文", role: .primary, json: true)
      preconditionFailure("an exhausted budget at the retry ceiling must not succeed")
    } catch {
      // Expected.
    }
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 1,
      "no headroom left must not retry, spent \(AutomatedRevisionLLMProtocol.requestCount()) calls"
    )

    // An empty completion that stopped normally gets the same treatment: it is the
    // shape chapter 1 of 《灰雾之前》 actually failed with, reported as `stop` with
    // 11k-14k characters of reasoning, so keying the raise on `length` alone would
    // leave that case retrying at an unchanged ceiling.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "", stream: false, finishReason: "stop", reasoningContent: "推理占位。"
      ),
      AutomatedRevisionStubResponse(content: "{\"ok\":true}", stream: false, finishReason: "stop"),
    ])
    let recovered = try await budgetCore.requestLLM(prompt: "写一章正文", role: .primary, json: true)
    precondition(recovered.content.contains("ok"))
    precondition(
      AutomatedRevisionLLMProtocol.observedMaxTokens() == [16_384, 32_768],
      "a `stop` with no prose must also raise the ceiling, saw \(AutomatedRevisionLLMProtocol.observedMaxTokens())"
    )

    // JSON cut off at the ceiling is unusable, so it raises and retries rather than
    // being handed back. The beat planner used to receive this and respond by halving
    // its chapter range, which shrinks the answer when the fault is that reasoning
    // already spent the budget: chapter 1 of 《灰雾之前》 went 1-10, 1-5, 1-3, a full
    // reasoning pass each time, never writing more than 3k characters.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "{\"beats\":[{\"number\":1,\"goal\":\"未闭合",
        stream: false,
        finishReason: "length",
        reasoningContent: "推理占位。"
      ),
      AutomatedRevisionStubResponse(content: "{\"ok\":true}", stream: false),
    ])
    let truncatedRecovered = try await budgetCore.requestLLM(
      prompt: "写节拍卡", role: .primary, json: true
    )
    precondition(truncatedRecovered.content.contains("ok"))
    precondition(
      AutomatedRevisionLLMProtocol.observedMaxTokens() == [16_384, 32_768],
      "truncated JSON must raise the ceiling, saw \(AutomatedRevisionLLMProtocol.observedMaxTokens())"
    )

    // Truncated *prose* is still worth reviewing and revising, so it must be returned
    // rather than retried: the chapter pipeline improves a short chapter, and raising
    // the ceiling for it would pay a second full write for text it already has.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "正文写到一半就到顶了", stream: false, finishReason: "length"
      ),
    ])
    let truncatedProse = try await budgetCore.requestLLM(prompt: "写一章正文", role: .primary)
    precondition(truncatedProse.content.contains("到顶"))
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 1,
      "truncated prose must not retry, spent \(AutomatedRevisionLLMProtocol.requestCount()) calls"
    )

    // A genuine transport hiccup keeps its plain retry and must not raise anything:
    // more budget does not fix a dropped connection, and conflating the two would
    // make every transient failure cost a larger upstream call.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: "上游繁忙", stream: false, statusCode: 502),
      AutomatedRevisionStubResponse(content: "{\"ok\":true}", stream: false),
    ])
    let transientRecovered = try await budgetCore.requestLLM(
      prompt: "写一章正文", role: .primary, json: true
    )
    precondition(transientRecovered.content.contains("ok"))
    precondition(
      AutomatedRevisionLLMProtocol.observedMaxTokens() == [16_384, 16_384],
      "a transport failure must retry at the same ceiling, saw \(AutomatedRevisionLLMProtocol.observedMaxTokens())"
    )

    // A model the relay carries no channel for must fail on the first attempt.
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "",
        stream: false,
        statusCode: 503,
        rawBody: """
          {"error":{"code":"model_not_found","message":"No available channel for model reasoning-test under group default (distributor)"}}
          """
      ),
    ])
    var missingModelMessage = ""
    do {
      _ = try await budgetCore.requestLLM(prompt: "写一章正文", role: .primary, json: true)
      preconditionFailure("a model with no relay channel must not succeed")
    } catch {
      missingModelMessage = error.localizedDescription
    }
    precondition(
      missingModelMessage.contains("渠道"),
      "missing-model error must say the relay has no channel, got: \(missingModelMessage)"
    )
    precondition(
      AutomatedRevisionLLMProtocol.requestCount() == 1,
      "missing model must not be retried, spent \(AutomatedRevisionLLMProtocol.requestCount()) calls"
    )
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

  /// The story clock: does a chapter know what day it is, and does that day decide
  /// which canon events it may reference?
  ///
  /// This is the case the whole 同人 feature exists for. A fan fiction opening a year
  /// before the source's inciting event must not let anyone mention that event, and the
  /// only thing standing between the writing model and that mistake is this
  /// classification. The assertions below pin all three buckets, the day summation that
  /// feeds them, and the source-chapter fallback that covers the (common) case of a
  /// source that never states a date.
  /// Prompt integration for derivative writing. The source's second chapter is
  /// deliberately future-only at derivative chapter 1, so the same assertion
  /// covers timeline gating and the RAG upper bound in generation, revision and
  /// independent review prompts.
  private static func assertDerivativePromptCoverage(root: URL) async throws {
    let promptRoot = root.appendingPathComponent("derivative-prompt-coverage", isDirectory: true)
    let core = InkOSCore(rootURL: promptRoot)
    let creation = try await core.createBook(CreateBookRequest(
      title: "同人提示词链路测试书",
      language: "zh",
      genre: "fanfic",
      platform: "tomato",
      kind: .derivative,
      sourceTitle: "提示词原著",
      timelineAnchorLabel: "城门警讯",
      timelineStartDayOffset: -1,
      targetChapters: 1,
      chapterWords: 1_000,
      totalWords: "1000",
      targetTotalWords: 1_000,
      volumeCount: 1,
      chapterWordTolerance: 10,
      premise: "验证同人写作提示词的时间门与检索门。",
      characters: "主角在原著事件前巡查城门。",
      protagonistProfile: "主角谨慎，会在紧张时反复检查城门；缺陷是过度怀疑。",
      protagonistReviewed: true,
      worldbuilding: "城门外有旧驿道。",
      outline: "第一章只巡查城门外。",
      volumePlan: "第一卷第1章。",
      pacing: "一章只推进一次巡查。",
      style: "第三人称有限视角。",
      constraints: "不得提前获知原著城门警讯。"
    ))
    let bookID = creation.title
    let config: [String: Any] = [
      "provider": "openai",
      "model": "writer-test",
      "reviewModel": "review-test",
      "extractionModel": "extraction-test",
      "baseUrl": "http://127.0.0.1:8765/v1",
      "reviewBaseUrl": "http://127.0.0.1:8765/v1",
      "apiKey": "test-key",
      "reviewApiKey": "test-key",
      "stream": false,
      "thinkingBudget": 0,
      "apiFormat": "chat",
    ]
    try JSONSerialization.data(withJSONObject: config)
      .write(to: promptRoot.appendingPathComponent("data/inkos-config.json"), options: .atomic)

    let pastMarker = "已发生独特原文必须注入"
    let futureMarker = "未来独特原文禁止泄漏"
    let original = """
      第一章 城外巡查

      原著守卫沿着城门外的旧驿道巡查，确认吊桥铁链没有松动。\(pastMarker)。

      第二章 警讯

      城门警讯在午夜响起。\(futureMarker)。原著守卫随后才知道密令内容。

      第三章 余波

      警讯之后，城门守军开始核对值夜名册。
      """
    let source = promptRoot.appendingPathComponent("prompt-fixture.txt")
    try Data(original.utf8).write(to: source, options: .atomic)
    let manifest = try await core.importDerivativeSource(bookID: bookID, from: source)
    precondition(manifest.chapterCount == 3)
    _ = try await core.saveDerivativePreparationIntent(
      bookID: bookID,
      settingsText: "衍生故事开篇只允许巡查旧驿道。",
      embedRequested: false
    )

    URLProtocol.registerClass(AutomatedRevisionLLMProtocol.self)
    defer {
      URLProtocol.unregisterClass(AutomatedRevisionLLMProtocol.self)
      AutomatedRevisionLLMProtocol.configure([])
    }

    let canon = """
      {"upsert":{"entities":[{"id":"ENT-guard","name":"原著守卫","type":"character"}],"timeline":[{"id":"TL-gate-alert","label":"城门警讯","sourceDay":0,"sourceChapter":2}]}}
      """
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: canon, stream: false),
    ])
    let canonStatus = try await core.extractDerivativeCanon(bookID: bookID)
    precondition(canonStatus.isComplete, "短源文抽取必须完成")

    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: "{\"upsert\":{}}", stream: false),
    ])
    _ = try await core.extractDerivativeSettingsOverlay(
      bookID: bookID,
      settingsText: "衍生故事开篇只允许巡查旧驿道。"
    )
    let preparation = try await core.derivativePreparationSnapshot(bookID: bookID)
    precondition(preparation.isComplete, "写作前必须完成正典、设定与索引准备：\(preparation)")

    let plan = try await core.fetchLongFormPlan(bookID: bookID)
    var staleTimeline = await core.loadDerivativeTimeline(bookID: bookID)
    staleTimeline.anchorMilestoneID = "TL-overlay-shadow"
    staleTimeline.anchorSourceChapter = 999
    _ = try await core.saveDerivativeTimeline(bookID: bookID, staleTimeline)

    // A stale persisted chapter and a same-name author overlay are not proof that
    // the current original contains the anchor. Preparation is otherwise complete,
    // so this reaches the anchor gate rather than failing an earlier prerequisite.
    let projectionURL = promptRoot.appendingPathComponent(
      "book/books/\(bookID)/story/runtime/continuity-projection.json"
    )
    let planURL = promptRoot.appendingPathComponent("book/books/\(bookID)/long-form-plan.json")
    let savedProjectionData = try Data(contentsOf: projectionURL)
    let savedPlanData = try Data(contentsOf: planURL)
    var overlayOnlyProjection = try JSONDecoder().decode(
      ContinuityProjection.self,
      from: savedProjectionData
    )
    overlayOnlyProjection.baseContinuity.timeline = []
    overlayOnlyProjection.manualOverlay.upsert.timeline = [
      LongFormTimelineMilestone(
        id: "TL-overlay-shadow",
        order: 1,
        label: "城门警讯",
        earliestChapter: 1,
        latestChapter: 1
      ),
    ]
    overlayOnlyProjection.continuity.timeline = overlayOnlyProjection.manualOverlay.upsert.timeline
    try JSONEncoder().encode(overlayOnlyProjection).write(to: projectionURL, options: .atomic)
    do {
      try await core.validateDerivativePreparationForWriting(
        bookID: bookID,
        plan: plan
      )
      preconditionFailure("同名 overlay 与陈旧章号不得通过原著锚点门禁")
    } catch let error as InkOSCoreError {
      precondition(
        error.statusCode == 409 && error.message.contains("时间锚点"),
        "锚点门禁应指出当前原著没有匹配事件：\(error)"
      )
    }
    try savedProjectionData.write(to: projectionURL, options: .atomic)
    try savedPlanData.write(to: planURL, options: .atomic)
    try await core.validateDerivativePreparationForWriting(bookID: bookID, plan: plan)
    let reboundTimeline = await core.resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: plan.continuity
    )
    precondition(
      reboundTimeline.anchorMilestoneID == "TL-gate-alert"
        && reboundTimeline.anchorSourceChapter == 2,
      "陈旧绑定必须按当前原著标签重绑：\(reboundTimeline)"
    )

    let semanticOnlyBeat = ChapterBeat(
      number: 1,
      goal: "陌生人沿旧驿道检查吊桥铁链",
      scenes: ["陌生人在城门外停下检查"],
      requiredEvents: ["确认铁链未松动"],
      endingHook: "远处传来未辨明的风声",
      focusCharacters: ["衍生主角"],
      timeSpan: "半夜",
      setback: "风声让他误判动静",
      notes: "不得出现警讯"
    )
    let semanticOnlyKeys = try await core.derivativeRetrievalKeys(
      bookID: bookID,
      beat: semanticOnlyBeat
    )
    precondition(
      semanticOnlyKeys.isEmpty,
      "本章没有原著实体时应只靠非空 query 触发检索：\(semanticOnlyKeys)"
    )
    let lateEntityText = String(repeating: "衍生角色沿路核对铁链。", count: 80)
      + "直到章末，他才听到原著守卫的脚步声。"
    let lateEntityKeys = try await core.derivativeRetrievalKeys(
      bookID: bookID,
      beat: semanticOnlyBeat,
      narrativeText: lateEntityText
    )
    precondition(
      lateEntityKeys == ["原著守卫"],
      "审阅与修订必须扫描完整正文中的原著实体：\(lateEntityKeys)"
    )
    let boundedLateQuery = await core.boundedDerivativeRetrievalQuery(lateEntityText)
    precondition(
      boundedLateQuery.count == 200
        && boundedLateQuery.hasPrefix("衍生角色")
        && boundedLateQuery.hasSuffix("原著守卫的脚步声。"),
      "语义检索查询应同时保留正文首尾"
    )
    let semanticOnlyPrompt = try await core.generationPrompt(
      bookID: bookID,
      chapterNumber: 1,
      guidance: "沿旧驿道巡查，不得谈及警讯。",
      beat: semanticOnlyBeat,
      plan: plan
    )
    precondition(
      semanticOnlyPrompt.contains("【原著正典检索结果】"),
      "空 lexical key + 非空 query 仍必须触发检索段落"
    )
    precondition(!semanticOnlyPrompt.contains(futureMarker), "语义检索不得越过未来章节上界")

    let beat = ChapterBeat(
      number: 1,
      goal: "原著守卫沿旧驿道检查吊桥铁链",
      scenes: ["原著守卫在城门外停下检查"],
      requiredEvents: ["确认铁链未松动"],
      endingHook: "远处传来未辨明的风声",
      focusCharacters: ["原著守卫"],
      timeSpan: "半夜",
      setback: "风声让他误判动静",
      notes: "不得出现警讯"
    )
    let keys = try await core.derivativeRetrievalKeys(bookID: bookID, beat: beat)
    precondition(keys == ["原著守卫"], "原著实体必须成为词法检索键：\(keys)")
    let timeline = await core.resolvedDerivativeTimeline(bookID: bookID, continuity: plan.continuity)
    let status = await core.derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: 1,
      continuity: plan.continuity,
      timeline: timeline
    )
    let retrievalMaximum = await core.derivativeRetrievalMaximumSourceChapter(
      status: status,
      timeline: timeline
    )
    precondition(retrievalMaximum == 1, "开篇早于第 2 章锚点时，检索必须截止第 1 章")

    let generation = try await core.generationPrompt(
      bookID: bookID,
      chapterNumber: 1,
      guidance: "沿旧驿道巡查，不得谈及警讯。",
      beat: beat,
      plan: plan
    )
    assertDerivativePromptSections(
      generation,
      pastMarker: pastMarker,
      futureMarker: futureMarker,
      label: "生成"
    )

    let emptyDelta: [String: Any] = [
      "upsert": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
      "remove": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
    ]
    let candidateDelta = try await core.normalizedConsistencyDelta(emptyDelta, chapterNumber: 1)
    let draft = String(repeating: "他沿旧驿道摸过湿冷的铁链，手指发麻仍逐节确认，最后听见城墙上有人咳嗽。", count: 29)
      + "直到末段，原著守卫才从驿道另一头现身。"

    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(
        content: "{\"pass\":true,\"summary\":\"通过\",\"issues\":[],\"revisionGuidance\":\"\"}",
        stream: true
      ),
    ])
    _ = try await core.reviewChapter(
      bookID: bookID,
      chapterNumber: 1,
      title: "旧驿道",
      content: draft,
      candidateDelta: candidateDelta,
      beat: beat
    )
    guard let reviewPrompt = AutomatedRevisionLLMProtocol.observedPrompts().first else {
      preconditionFailure("同人审阅必须调用审阅模型")
    }
    assertDerivativePromptSections(
      reviewPrompt,
      pastMarker: pastMarker,
      futureMarker: futureMarker,
      label: "审阅"
    )
    precondition(
      reviewPrompt.contains("必须输出 [hard][prose]"),
      "审阅提示词必须将未来原著事件标成正文级硬问题"
    )

    let storedReview: [String: Any] = [
      "status": "failed",
      "model": "test-review",
      "summary": "需要改写正文",
      "issues": ["[hard][prose] 正文需要调整巡查细节。"],
      "revisionGuidance": "重写正文，但不得提前出现城门警讯。",
      "attempts": [],
    ]
    try await core.writeChapter(
      bookID: bookID,
      number: 1,
      title: "旧驿道",
      content: draft,
      status: "revision_failed",
      llmReview: storedReview
    )
    try await core.persistConsistencyDelta(
      bookID: bookID,
      chapterNumber: 1,
      title: "旧驿道",
      summary: "巡查旧驿道。",
      delta: emptyDelta
    )
    let revisedPayload = """
      {"title":"旧驿道","content":"\(draft)铁链上忽然闪出一行异常乱码；他收回手，没有继续追问城墙上的咳嗽声。","summary":"继续巡查旧驿道。","consistencyDelta":\(String(data: try JSONSerialization.data(withJSONObject: emptyDelta), encoding: .utf8)!)}
      """
    AutomatedRevisionLLMProtocol.configure([
      AutomatedRevisionStubResponse(content: revisedPayload, stream: true),
      AutomatedRevisionStubResponse(
        content: "{\"pass\":true,\"summary\":\"修订通过\",\"issues\":[],\"revisionGuidance\":\"\"}",
        stream: true
      ),
    ])
    _ = try await core.reviseChapter(
      bookID: bookID,
      number: 1,
      note: "重写正文，但不得提前出现城门警讯。",
      mode: "rewrite"
    )
    var revisionJob: GenerationJob?
    for _ in 0..<100 {
      let job = try await core.fetchGenerationJob(bookID: bookID, chapterNumber: 1).job
      if job?.isActive == false {
        revisionJob = job
        break
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    guard let revisionJob else { preconditionFailure("同人自动修订任务未完成") }
    precondition(revisionJob.phase == "ready-for-review", "修订未完成：\(revisionJob)")
    guard let revisionPrompt = AutomatedRevisionLLMProtocol.observedPrompts().first(where: {
      $0.contains("你是 InkOS 章节修订器")
    }) else {
      preconditionFailure("自动修订必须走章节修订器提示词")
    }
    assertDerivativePromptSections(
      revisionPrompt,
      pastMarker: pastMarker,
      futureMarker: futureMarker,
      label: "修订"
    )

    _ = try await core.deleteBook(id: bookID)
    print("Derivative prompt probe passed: generation + revision + review timeline/RAG gates")
  }

  /// Generation, revision and approval all stop before starting work when a
  /// derivative book has not completed source preparation.
  private static func assertDerivativePreparationGate(root: URL) async throws {
    let gateRoot = root.appendingPathComponent("derivative-preparation-gate", isDirectory: true)
    let core = InkOSCore(rootURL: gateRoot)
    let request = CreateBookRequest(
      title: "同人准备门禁测试书",
      language: "zh",
      genre: "fanfic",
      platform: "tomato",
      kind: .derivative,
      sourceTitle: "尚未导入的原著",
      timelineAnchorLabel: "开篇事件",
      timelineStartDayOffset: -10,
      targetChapters: 1,
      chapterWords: 1_000,
      totalWords: "1000",
      targetTotalWords: 1_000,
      volumeCount: 1,
      chapterWordTolerance: 10,
      premise: "验证同人准备完成前不进入章节流水线。",
      characters: "测试主角。",
      protagonistProfile: "测试主角谨慎核对来源；缺陷是过度迟疑，会反复检查每一个细节。",
      protagonistReviewed: true,
      worldbuilding: "沿用原著。",
      outline: "第一章等待原著准备。",
      volumePlan: "第一卷第1章。",
      pacing: "单章单目标。",
      style: "第三人称有限视角。",
      constraints: "必须先完成原著准备。"
    )

    var missingAnchorGuide = CreateBookGuide(request: request)
    missingAnchorGuide.protagonistName = "测试主角"
    missingAnchorGuide.protagonistProfile = request.protagonistProfile
    missingAnchorGuide.storyPremise += "同时核对时间锚点不可缺失。"
    missingAnchorGuide.timelineAnchorLabel = "  "
    do {
      _ = try await core.assistCreateBook(guide: missingAnchorGuide)
      preconditionFailure("同人创建引导不得接受空时间锚点")
    } catch let error as InkOSCoreError {
      precondition(
        error.statusCode == 400 && error.message.contains("时间锚点"),
        "创建引导应明确提示时间锚点：\(error)"
      )
    }

    var missingAnchorRequest = request
    missingAnchorRequest.title = "同人空锚点测试书"
    missingAnchorRequest.timelineAnchorLabel = "\n"
    do {
      _ = try await core.createBook(missingAnchorRequest)
      preconditionFailure("核心建书入口不得接受空时间锚点")
    } catch let error as InkOSCoreError {
      precondition(
        error.statusCode == 400 && error.message.contains("时间锚点"),
        "核心建书应明确提示时间锚点：\(error)"
      )
    }

    let creation = try await core.createBook(request)
    let bookID = creation.title

    var generationBlocked = false
    do {
      _ = try await core.generateChapter(bookID: bookID, guidance: nil)
    } catch {
      generationBlocked = error.localizedDescription.contains("原著")
    }
    precondition(generationBlocked, "缺失原著准备必须阻止生成")
    let generationJob = try await core.fetchGenerationJob(bookID: bookID, chapterNumber: 1)
    precondition(generationJob.job == nil, "门禁必须在创建生成任务前执行")

    let body = String(repeating: "准备门禁测试正文。", count: 120)
    try await core.writeChapter(
      bookID: bookID,
      number: 1,
      title: "等待准备",
      content: body,
      status: "pending_review",
      llmReview: passedLLMReviewFixture()
    )
    let emptyDelta: [String: Any] = [
      "upsert": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
      "remove": [
        "immutableCanon": [], "worldRules": [], "entities": [],
        "knowledgeBoundaries": [], "timeline": [], "hooks": [],
      ],
    ]
    try await core.persistConsistencyDelta(
      bookID: bookID,
      chapterNumber: 1,
      title: "等待准备",
      summary: "门禁测试。",
      delta: emptyDelta
    )

    var revisionBlocked = false
    do {
      _ = try await core.reviseChapter(
        bookID: bookID,
        number: 1,
        note: "测试门禁",
        mode: "manual"
      )
    } catch {
      revisionBlocked = error.localizedDescription.contains("原著")
    }
    precondition(revisionBlocked, "缺失原著准备必须阻止修订")

    var approvalBlocked = false
    do {
      _ = try await core.approveChapter(bookID: bookID, number: 1)
    } catch {
      approvalBlocked = error.localizedDescription.contains("原著")
    }
    precondition(approvalBlocked, "缺失原著准备必须阻止批准")
    let chapter = try await core.fetchChapter(bookID: bookID, number: 1)
    precondition(chapter.status == "pending_review", "门禁失败不得改变章节状态")
    print("Derivative preparation gate probe passed: generate + revise + approve")
  }

  private static func assertDerivativePromptSections(
    _ prompt: String,
    pastMarker: String,
    futureMarker: String,
    label: String
  ) {
    precondition(prompt.contains("【本章的原著时间进度】"), "\(label)提示词缺少原著时间进度")
    precondition(prompt.contains("【原著正典检索结果】"), "\(label)提示词未在空 lexical key + 非空 query 时触发检索")
    precondition(prompt.contains(pastMarker), "\(label)提示词没有注入已发生的原著段落")
    precondition(!prompt.contains(futureMarker), "\(label)提示词泄漏了未来原著段落")
  }

  private static func assertDerivativeTimelineGatesCanonEvents(root: URL) async throws {
    let timelineRoot = root.appendingPathComponent("timeline-gate", isDirectory: true)
    let core = InkOSCore(rootURL: timelineRoot)

    let creation = try await core.createBook(CreateBookRequest(
      title: "时间进度测试书",
      language: "zh",
      genre: "fanfic",
      platform: "tomato",
      kind: .derivative,
      sourceTitle: "测试原著",
      timelineAnchorLabel: "主线事件",
      timelineStartDayOffset: -365,
      timelineStartDateLabel: "第一年春",
      targetChapters: 6,
      chapterWords: 1_000,
      totalWords: "6000",
      targetTotalWords: 6_000,
      volumeCount: 1,
      chapterWordTolerance: 15,
      premise: "验证同人时间进度系统。",
      characters: "主角提前一年进入原著世界。",
      protagonistProfile: "主角谨慎，先观察再行动；缺陷是不肯求助。",
      protagonistReviewed: true,
      worldbuilding: "沿用原著设定。",
      outline: "开篇早于原著主线一年。",
      volumePlan: "第一卷1-6章。",
      pacing: "一章推进一个目标。",
      style: "第三人称有限视角。",
      constraints: "不得提前写出原著尚未发生的事件"
    ))
    let bookID = creation.title

    // Creation must have persisted the clock, and `book.json` must remember this is
    // a 同人 book — without the kind the prompts silently lose every canon section.
    let recordedKind = await core.bookKind(bookID: bookID)
    precondition(recordedKind == .derivative, "同人书必须记为 derivative")
    let stored = await core.loadDerivativeTimeline(bookID: bookID)
    precondition(stored.startDayOffset == -365, "开篇偏移应为 -365，实际 \(stored.startDayOffset)")
    precondition(stored.anchorLabel == "主线事件")
    precondition(stored.startDateLabel == "第一年春")

    // Day summation. Beats override the per-chapter default; a beat without
    // `storyDays` falls back to it. Chapter 1 is always the offset itself.
    var timeline = stored
    timeline.anchorSourceChapter = 100
    timeline.defaultChapterDays = 1
    let beats = ChapterBeatPlan(bookId: bookID, beats: [
      ChapterBeat(number: 1, storyDays: 10),
      ChapterBeat(number: 2, storyDays: 0),
      ChapterBeat(number: 3),
      ChapterBeat(number: 4, storyDays: 30),
    ])
    var storyDays: [Int] = []
    for chapter in 1...6 {
      storyDays.append(
        await core.derivativeStoryDay(chapterNumber: chapter, timeline: timeline, beats: beats)
      )
    }
    // Chapter 1 is the offset itself; 2 adds 10; 3 adds nothing (storyDays 0); 4 adds
    // chapter 3's missing value from the default; 5 adds 30; 6 has no beat at all so it
    // falls back to the default again.
    precondition(
      storyDays == [-365, -355, -355, -354, -324, -323],
      "故事日期累加错了：\(storyDays)"
    )

    // Classification. Four milestones covering every branch: one dated in the past,
    // one dated in the future, one with no day but an earlier source chapter, one
    // with no day and a later source chapter.
    var continuity = LongFormContinuity()
    continuity.timeline = [
      // Same label as the source anchor but no source coordinate: this is an author
      // overlay and must never win label resolution merely because it appears first.
      LongFormTimelineMilestone(
        id: "TL-overlay-anchor", order: 1, label: "主线事件",
        earliestChapter: 1, latestChapter: 1
      ),
      LongFormTimelineMilestone(
        id: "TL-early", order: 1, label: "很早以前的旧事",
        earliestChapter: 1, latestChapter: 1, sourceDay: -400, sourceChapter: 5
      ),
      LongFormTimelineMilestone(
        id: "TL-anchor", order: 2, label: "主线事件",
        earliestChapter: 1, latestChapter: 1, sourceDay: 0, sourceChapter: 100
      ),
      LongFormTimelineMilestone(
        id: "TL-before", order: 3, label: "锚点之前的伏笔",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 60
      ),
      LongFormTimelineMilestone(
        id: "TL-after", order: 4, label: "锚点之后的大战",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 300
      ),
      // Undated, but *in the anchor's own source chapter*. That is day 0 by
      // definition, not an interpolation, so it must be gated as hard as the dated
      // anchor. In production this case was 克莱恩穿越 itself — the one event a 诡秘之主
      // derivative most needs blocked — and it was reported as merely uncertain.
      LongFormTimelineMilestone(
        id: "TL-atanchor", order: 5, label: "锚点同章事件",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 100
      ),
      // No source chapter at all: came from the settings overlay or an approved
      // chapter, so it is not a source event and must not appear in any of the three
      // lists. Production listed the protagonist's own arrival as a source event the
      // chapter must not reference, while chapter one *is* that arrival.
      LongFormTimelineMilestone(
        id: "TL-own", order: 6, label: "主角自己的穿越",
        earliestChapter: 1, latestChapter: 1
      ),
    ]

    let resolvedSourceAnchor = await core.resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: continuity
    )
    let hasResolvedSourceAnchor = await core.hasResolvedDerivativeSourceAnchor(
      resolvedSourceAnchor,
      continuity: continuity
    )
    precondition(
      resolvedSourceAnchor.anchorMilestoneID == "TL-anchor"
        && resolvedSourceAnchor.anchorSourceChapter == 100
        && hasResolvedSourceAnchor,
      "同名 author overlay 不得抢占原著锚点：\(resolvedSourceAnchor)"
    )

    // Creation-time shorthand will not equal the extracted sentence. Token match
    // must bind the opening 穿越, not a late-book 克莱恩+穿越 reveal, and must
    // prefer an event that has 聚会 over an earlier 灰雾-only milestone.
    var shorthandContinuity = LongFormContinuity()
    shorthandContinuity.timeline = [
      LongFormTimelineMilestone(
        id: "TL-WAKE", order: 1,
        label: "周明瑞穿越醒来，发现自己身处陌生房间，窗外有绯红满月",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 1
      ),
      LongFormTimelineMilestone(
        id: "TL-MEMORY", order: 2,
        label: "周明瑞整理克莱恩记忆，得知两天后需参加廷根大学历史系面试",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 3
      ),
      LongFormTimelineMilestone(
        id: "TL-FOG", order: 3,
        label: "周明瑞进行福生玄黄仪式，进入灰雾世界",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 5
      ),
      LongFormTimelineMilestone(
        id: "TL-GATHER", order: 4,
        label: "克莱恩进入灰雾神殿，准备与倒吊人正义聚会",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 33
      ),
      LongFormTimelineMilestone(
        id: "TL-LATE", order: 5,
        label: "克莱恩通过历史片段确认自己是周明瑞，发现穿越真相",
        earliestChapter: 1, latestChapter: 1, sourceChapter: 1169
      ),
    ]
    _ = try await core.saveDerivativeTimeline(
      bookID: bookID,
      DerivativeTimeline(anchorLabel: "克莱恩穿越", startDayOffset: 3)
    )
    let kleinAnchor = await core.resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: shorthandContinuity
    )
    precondition(
      kleinAnchor.anchorMilestoneID == "TL-WAKE" && kleinAnchor.anchorSourceChapter == 1,
      "克莱恩穿越 必须绑到开篇穿越，而不是后文揭示：\(kleinAnchor)"
    )
    _ = try await core.saveDerivativeTimeline(
      bookID: bookID,
      DerivativeTimeline(anchorLabel: "灰雾聚会", startDayOffset: 0)
    )
    let gatheringAnchor = await core.resolvedDerivativeTimeline(
      bookID: bookID,
      continuity: shorthandContinuity
    )
    precondition(
      gatheringAnchor.anchorMilestoneID == "TL-GATHER" && gatheringAnchor.anchorSourceChapter == 33,
      "灰雾聚会 必须优先含“聚会”的事件，而不是更早的灰雾：\(gatheringAnchor)"
    )
    _ = try await core.saveDerivativeTimeline(
      bookID: bookID,
      DerivativeTimeline(
        anchorLabel: "主线事件",
        startDayOffset: -365,
        startDateLabel: "第一年春"
      )
    )

    let opening = await core.derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: 1,
      continuity: continuity,
      timeline: timeline,
      beats: beats
    )
    precondition(opening.isConfigured, "锚点和偏移都填了，状态必须是已配置")
    precondition(opening.storyDay == -365 && opening.elapsedDays == 0)
    let openingPast = opening.past.map { $0.id }
    let openingFuture = opening.future.map { $0.id }
    let openingUnplaced = opening.unplaced.map { $0.id }
    precondition(openingPast == ["TL-early"], "只有 -400 天那条早于开篇：\(openingPast)")
    // The load-bearing one. 主线事件 is the anchor itself and the book opens a year
    // early, so it must be classified as not-yet-happened; if it ever lands in
    // `past` the writing model is free to have characters discuss it.
    precondition(
      openingFuture.contains("TL-anchor"),
      "开篇早于锚点一年，锚点事件必须算作尚未发生：\(openingFuture)"
    )
    // No day, but its source chapter is past the anchor's while the book sits before
    // the anchor, so it is unambiguously ahead.
    precondition(
      openingFuture.contains("TL-after"),
      "原著章号晚于锚点的事件也必须算作尚未发生：\(openingFuture)"
    )
    // No day, earlier source chapter, but the book opens *before* the anchor — so
    // whether it has happened is genuinely unknown and must not be guessed.
    precondition(
      openingUnplaced == ["TL-before"],
      "开篇早于锚点时，锚点之前的无日期事件应报为未确定：\(openingUnplaced)"
    )
    // Same chapter as the anchor means day 0, so it is gated exactly like the dated
    // anchor rather than softened into `unplaced`.
    precondition(
      openingFuture.contains("TL-atanchor"),
      "锚点同章的无日期事件必须硬判为尚未发生：\(openingFuture)"
    )
    // A milestone with no source chapter is not a source event and belongs in no list.
    let allOpeningIDs = openingPast + openingFuture + openingUnplaced
    precondition(
      !allOpeningIDs.contains("TL-own"),
      "没有原著章号的条目不是原著事件，不应进入任何一类：\(allOpeningIDs)"
    )
    precondition(
      opening.past.allSatisfy { ($0.dayDelta ?? 0) <= 0 },
      "已发生事件的 dayDelta 不应为正"
    )

    // Same continuity, but the book now opens *after* the anchor. The dated anchor
    // moves to the past, and the undated pre-anchor event becomes placeable.
    var later = timeline
    later.startDayOffset = 30
    let afterAnchor = await core.derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: 1,
      continuity: continuity,
      timeline: later,
      beats: beats
    )
    let laterPast = afterAnchor.past.map { $0.id }.sorted()
    let laterUnplaced = afterAnchor.unplaced.map { $0.id }
    precondition(
      laterPast == ["TL-anchor", "TL-atanchor", "TL-before", "TL-early"],
      "开篇晚于锚点时，锚点同章及其之前的事件都应算已发生：\(laterPast)"
    )
    // The undated late-source event becomes *uncertain*, not future. Once the book is
    // past the anchor, nothing on file says how many days source chapters 100→300
    // span, so claiming the event is still ahead would be a guess. Reporting it as
    // uncertain still tells the chapter not to cite its results, but it does not forbid
    // a book that has caught up to the source from playing the event out — the failure
    // that matters (referencing an event too early) is fully covered by the
    // before-anchor case above, which is where a 同人 opening a year early lives.
    precondition(
      laterUnplaced == ["TL-after"],
      "开篇晚于锚点后，无日期的后段事件应报为未确定而非硬判未发生：\(laterUnplaced)"
    )
    precondition(afterAnchor.future.isEmpty, "此时没有可确定判为未发生的事件")

    // Prompt lists retain only 12 entries. The RAG chapter boundary must still use
    // every classified event, including an old dated event whose high source chapter
    // falls outside that display slice.
    var denseContinuity = LongFormContinuity()
    denseContinuity.timeline = [
      LongFormTimelineMilestone(
        id: "TL-dense-anchor", order: 1, label: "主线事件",
        earliestChapter: 1, latestChapter: 1, sourceDay: 0, sourceChapter: 100
      ),
      LongFormTimelineMilestone(
        id: "TL-old-late-source", order: 2, label: "后段原著回叙的旧事",
        earliestChapter: 1, latestChapter: 1, sourceDay: -100, sourceChapter: 500
      ),
    ]
    denseContinuity.timeline.append(contentsOf: (1...20).map { offset in
      LongFormTimelineMilestone(
        id: "TL-dense-\(offset)",
        order: offset + 2,
        label: "已发生事件 \(offset)",
        earliestChapter: 1,
        latestChapter: 1,
        sourceDay: offset,
        sourceChapter: 100 + offset
      )
    })
    var denseTimeline = timeline
    denseTimeline.startDayOffset = 30
    let denseStatus = await core.derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: 1,
      continuity: denseContinuity,
      timeline: denseTimeline,
      beats: nil
    )
    precondition(
      denseStatus.past.count == InkOSCore.timelineEventListLimit
        && !denseStatus.past.contains { $0.id == "TL-old-late-source" },
      "回归夹具必须把高章号旧事件截到展示列表之外：\(denseStatus.past.map(\.id))"
    )
    precondition(
      denseStatus.latestPastSourceChapter == 500,
      "未截断分类的最近原著章号应为 500：\(denseStatus.latestPastSourceChapter as Any)"
    )
    let denseRetrievalMaximum = await core.derivativeRetrievalMaximumSourceChapter(
      status: denseStatus,
      timeline: denseTimeline
    )
    precondition(
      denseRetrievalMaximum == 500,
      "RAG 上界不得退回 12 条展示列表中的章号：\(denseRetrievalMaximum as Any)"
    )

    // Without an anchor chapter there is nothing to compare undated events against.
    // They must be reported as unplaced rather than sorted by `order`, which is a
    // sort key the delta merge renumbers, not a clock.
    var anchorless = timeline
    anchorless.anchorSourceChapter = nil
    anchorless.anchorMilestoneID = nil
    anchorless.anchorLabel = ""
    let unanchored = await core.derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: 1,
      continuity: continuity,
      timeline: anchorless,
      beats: beats
    )
    let unanchoredUnplaced = unanchored.unplaced.map { $0.id }.sorted()
    precondition(
      // `TL-own` stays absent even here: no anchor to compare against is a different
      // thing from not being a source event at all.
      unanchoredUnplaced == ["TL-after", "TL-atanchor", "TL-before"],
      "没有锚点章号时，无日期事件必须报为未确定：\(unanchoredUnplaced)"
    )
    precondition(
      unanchored.past.map { $0.id } == ["TL-early"]
        && unanchored.future.map { $0.id } == ["TL-anchor"],
      "有日期的事件不依赖锚点章号，仍应正常分类"
    )

    // The prompt section is what the model actually reads. The forbidden list has to
    // be present and has to name the event; a section that omits it is a silent
    // regression no other assertion here would catch.
    guard let section = await core.derivativeTimelineSection(opening) else {
      preconditionFailure("已配置的时间线必须产出提示词段落")
    }
    precondition(section.contains("主线事件"), "提示词必须点名尚未发生的锚点事件")
    precondition(section.contains("尚未发生"), "提示词必须区分尚未发生的事件")
    precondition(section.contains("第一年春"), "提示词应引用开篇时间称呼")
    let unanchoredSection = await core.derivativeTimelineSection(unanchored)
    precondition(unanchoredSection != nil, "无锚点但有日期事件时仍应产出段落")

    // An original book must get no timeline section at all: it has no source to obey,
    // and a fabricated clock would constrain it for no reason.
    var blank = DerivativeTimeline()
    blank.anchorLabel = ""
    blank.startDayOffset = 0
    let unconfigured = await core.derivativeTimelineStatus(
      bookID: bookID,
      chapterNumber: 1,
      continuity: LongFormContinuity(),
      timeline: blank,
      beats: nil
    )
    precondition(!unconfigured.isConfigured, "空时间线不应报为已配置")
    let unconfiguredSection = await core.derivativeTimelineSection(unconfigured)
    precondition(unconfiguredSection == nil, "未配置时间线时不得输出时间进度段落")

    // Round-trip through disk, including the clamp on `defaultChapterDays`.
    var absurd = timeline
    absurd.defaultChapterDays = 9_999
    _ = try await core.saveDerivativeTimeline(bookID: bookID, absurd)
    let reloaded = await core.loadDerivativeTimeline(bookID: bookID)
    precondition(
      reloaded.defaultChapterDays == 365,
      "每章默认天数应被夹到 365，实际 \(reloaded.defaultChapterDays)"
    )
    precondition(
      reloaded.anchorSourceChapter == 100 && reloaded.startDayOffset == -365,
      "锚点章号和开篇偏移必须原样落盘"
    )

    _ = try await core.deleteBook(id: bookID)
    print("Derivative timeline probe passed: past/future/unplaced gates + day summation")
  }

  /// The beat prompt prints its forbidden list at the batch's opening chapter and
  /// caps it at `timelineEventListLimit`. A batch that retires the nearest future
  /// events mid-batch lets an event ranked beyond the cap enter the writing
  /// prompt's forbidden list without the planner ever seeing it — the planner could
  /// schedule it for a late-batch chapter and the conflict would surface only as a
  /// failed review. The closing section must name exactly those events.
  private static func assertDerivativeBeatClosingCoversCappedFuture(root: URL) async throws {
    let core = InkOSCore(rootURL: root.appendingPathComponent("beat-closing-cap", isDirectory: true))
    let bookID = "beat-closing-cap-fixture"
    let timeline = DerivativeTimeline(anchorLabel: "锚点事件", startDayOffset: 0)
    func milestone(_ day: Int) -> LongFormTimelineMilestone {
      LongFormTimelineMilestone(
        id: "TL-d\(day)", order: day, label: "第\(day)日事件",
        earliestChapter: 1, latestChapter: 1, sourceDay: day, sourceChapter: 100 + day
      )
    }
    // Six one-day beats move the clock from day 0 to day 6 across the batch.
    let beats = ChapterBeatPlan(
      bookId: bookID,
      beats: (1...6).map { ChapterBeat(number: $0, storyDays: 1) }
    )
    var continuity = LongFormContinuity()
    continuity.timeline = (1...17).map(milestone)
    let opening = await core.derivativeTimelineStatus(
      bookID: bookID, chapterNumber: 1, continuity: continuity, timeline: timeline, beats: beats
    )
    let closing = await core.derivativeTimelineStatus(
      bookID: bookID, chapterNumber: 7, continuity: continuity, timeline: timeline, beats: beats
    )
    precondition(opening.storyDay == 0 && closing.storyDay == 6)
    precondition(
      opening.future.count == InkOSCore.timelineEventListLimit,
      "开场禁止清单必须顶到条数上限，否则本探针没有证明任何东西：\(opening.future.count)"
    )

    guard let section = await core.derivativeBeatClosingSection(
      opening: opening, closing: closing, endChapter: 7
    ) else {
      preconditionFailure("批次内日期有推移时必须产出终点段落")
    }
    // The events capped out of the opening list but still future at the closing
    // chapter are exactly the ones the planner would otherwise never see.
    for day in 13...17 {
      precondition(
        section.contains("第\(day)日事件"),
        "终点段落必须点名被上限挤掉的事件：第\(day)日事件"
      )
    }
    // Already printed at the opening or already past: repeating them wastes the
    // budget and reads as a second, contradictory list.
    for day in 1...12 {
      precondition(
        !section.contains("第\(day)日事件"),
        "终点段落不得重复开场已列出的事件：第\(day)日事件"
      )
    }

    // No clock movement, no closing section at all.
    let noMovement = await core.derivativeBeatClosingSection(
      opening: opening, closing: opening, endChapter: 7
    )
    precondition(noMovement == nil, "批次内日期无推移时不得输出终点段落")

    // Fewer events than the cap: the opening list is already complete, so the
    // closing section reports the movement but adds no second forbidden list.
    var small = LongFormContinuity()
    small.timeline = (1...10).map(milestone)
    let smallOpening = await core.derivativeTimelineStatus(
      bookID: bookID, chapterNumber: 1, continuity: small, timeline: timeline, beats: beats
    )
    let smallClosing = await core.derivativeTimelineStatus(
      bookID: bookID, chapterNumber: 7, continuity: small, timeline: timeline, beats: beats
    )
    let smallSection = await core.derivativeBeatClosingSection(
      opening: smallOpening, closing: smallClosing, endChapter: 7
    )
    precondition(smallSection != nil, "日期有推移时即使无新增事件也应有终点段落")
    precondition(
      smallSection?.contains("同样绝对不得发生") == false,
      "开场清单未顶满时不得追加第二份禁止清单"
    )
    print("Derivative beat closing probe passed: capped future events named at batch end")
  }

  /// The beat planner receives a compact, prioritised view of unresolved hooks.
  /// This must never become an unbounded prompt section as a long novel accumulates
  /// hooks, and it must not cut a rendered line in half while enforcing the budget.
  private static func assertOpenHooksPromptBudgeting(root: URL) async throws {
    let core = InkOSCore(rootURL: root.appendingPathComponent("open-hooks-budget", isDirectory: true))
    let longDescription = String(repeating: "伏笔细节", count: 90)
    var hooks: [LongFormHookPlan] = [
      LongFormHookPlan(
        hookId: "HOOK-overdue",
        description: "已到期伏笔。" + longDescription,
        openFromChapter: 1,
        resolveByChapter: 8
      ),
      LongFormHookPlan(
        hookId: "HOOK-near-deadline",
        description: "临近截止伏笔。" + longDescription,
        openFromChapter: 2,
        resolveByChapter: 12
      ),
      LongFormHookPlan(
        hookId: "HOOK-recent",
        description: "最近开启伏笔。" + longDescription,
        openFromChapter: 30
      ),
    ]
    for number in 1...40 {
      hooks.append(LongFormHookPlan(
        hookId: String(format: "HOOK-old-%02d", number),
        description: "旧伏笔 \(number)。" + longDescription,
        openFromChapter: number % 20 + 1
      ))
    }
    let rendered = await core.openHooksText(
      LongFormContinuity(hooks: hooks),
      upTo: 40
    )
    precondition(
      rendered.count <= InkOSCore.chapterBeatOpenHooksMaxCharacters,
      "未回收伏笔必须受总字符预算约束：\(rendered.count)"
    )
    precondition(rendered.contains("HOOK-overdue"), "已到期伏笔必须优先保留")
    precondition(rendered.contains("HOOK-near-deadline"), "临近到期伏笔必须优先保留")
    precondition(rendered.contains("HOOK-recent"), "无截止期时最近开启的伏笔必须优先保留")
    precondition(rendered.contains("已省略"), "超过预算必须明确说明省略数量")
    precondition(rendered.contains("…"), "超长单条伏笔必须单独截断并标记")

    let hookLines = rendered.split(separator: "\n").filter { $0.hasPrefix("- ") }
    precondition(
      hookLines.allSatisfy { $0.hasSuffix("）") },
      "预算裁剪不得截断半条伏笔行：\(hookLines)"
    )
    precondition(
      hookLines.allSatisfy { $0.count <= InkOSCore.chapterBeatOpenHookDescriptionMaxCharacters + 96 },
      "单条伏笔描述必须受独立预算约束：\(hookLines)"
    )
    print("Open hook prompt budget probe passed: prioritised + bounded + whole lines")
  }

  /// Compacting the continuity share must produce complete JSON within its
  /// character budget and keep the policy plus prioritized entity identities.
  private static func assertCompactContinuityContext(root: URL) async throws {
    let core = InkOSCore(rootURL: root.appendingPathComponent("continuity-context-budget"))
    let details = String(repeating: "连续性详情", count: 80)
    let continuity = LongFormContinuity(
      immutableCanon: (1...20).map {
        LongFormImmutableCanon(id: "CANON-\($0)", category: "world", statement: "事实\($0)\(details)")
      },
      worldRules: (1...20).map {
        LongFormWorldRule(id: "RULE-\($0)", statement: "规则\($0)\(details)")
      },
      entities: (1...40).map {
        LongFormEntity(
          id: "ENT-\($0)",
          name: "实体\($0)",
          type: "character",
          attributes: ["状态": details, "位置": "第\($0)处"]
        )
      },
      knowledgeBoundaries: (1...20).map {
        LongFormKnowledgeBoundary(
          factId: "KNOW-\($0)",
          statement: "知识\($0)\(details)",
          allowedKnowers: ["实体\($0)"],
          availableFromChapter: 1
        )
      },
      timeline: (1...30).map {
        LongFormTimelineMilestone(
          id: "TL-\($0)",
          order: $0,
          label: "事件\($0)\(details)",
          earliestChapter: 1,
          latestChapter: 1
        )
      },
      hooks: (1...30).map { (index: Int) in
        LongFormHookPlan(
          hookId: "HOOK-\(index)",
          description: "伏笔\(index)\(details)",
          openFromChapter: 1,
          resolveByChapter: index
        )
      },
      policy: LongFormContinuityPolicy(allowUnplannedEntities: false)
    )
    let budget = 2_000
    let compact = await core.truncateContinuityIndex(continuity, maxChars: budget)
    precondition(compact.count <= budget, "紧凑连续性索引超出预算：\(compact.count)")
    guard let data = compact.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let policy = object["policy"] as? [String: Any],
      let truncation = object["_truncation"] as? [String: Any],
      let omitted = truncation["omittedCounts"] as? [String: Any]
    else {
      preconditionFailure("紧凑连续性索引必须始终是完整 JSON：\(compact)")
    }
    precondition(policy["allowUnplannedEntities"] as? Bool == false, "策略必须始终保留")
    precondition(truncation["truncated"] as? Bool == true, "超预算输入必须标记截断")
    precondition(
      omitted.values.compactMap { $0 as? Int }.contains { $0 > 0 },
      "截断元数据必须报告省略数量：\(omitted)"
    )
    let entities = object["entities"] as? [[String: Any]] ?? []
    precondition(
      !entities.isEmpty && entities.allSatisfy { $0["id"] != nil && $0["name"] != nil },
      "实体身份字段应最优先保留：\(entities)"
    )

    // When the full index fits, compaction must be lossless rather than silently
    // dropping immutable flags, attributes, markers or additional knowers.
    let small = LongFormContinuity(
      entities: [LongFormEntity(
        id: "ENT-full",
        name: "完整实体",
        type: "object",
        owner: "主角",
        location: "旧仓库",
        attributes: [
          "a": "1", "b": "2", "c": "3", "d": "4", "e": "5", "f": "6",
        ],
        immutableOwner: true,
        immutableLocation: true,
        immutableAttributes: ["a", "f"]
      )],
      knowledgeBoundaries: [LongFormKnowledgeBoundary(
        factId: "KNOW-full",
        statement: "完整知识",
        allowedKnowers: (1...8).map { "知情者\($0)" },
        forbiddenKnowers: (1...8).map { "禁知者\($0)" },
        availableFromChapter: 1,
        markers: ["marker-a", "marker-b"]
      )]
    )
    let lossless = await core.truncateContinuityIndex(small, maxChars: 100_000)
    let decoded = try JSONDecoder().decode(LongFormContinuity.self, from: Data(lossless.utf8))
    precondition(decoded == small, "预算充足时连续性索引必须无损：\(lossless)")
    print("Compact continuity context probe passed: parseable + bounded + lossless")
  }

  /// A model-supplied `null` must not terminate the process.
  ///
  /// This is a regression probe for a real production crash: extraction of 诡秘之主
  /// batch 1 returned valid JSON containing `null` in a text field, and normalization
  /// handed that bare `NSNull` to `JSONSerialization.data(withJSONObject:)`, which
  /// raises an ObjC `NSInvalidArgumentException` rather than a Swift error. `try?`
  /// cannot catch it, so the whole pass died with no checkpoint written. Nothing in
  /// this shape is derivative-specific — the same delta path normalizes every
  /// chapter's continuity output for original novels too.
  private static func assertModelNullsDoNotCrashNormalization(root: URL) async throws {
    let core = InkOSCore(rootURL: root)

    // Nulls in optional fields, plus a nested object where a string was asked for.
    // `aliases` is not a reserved entity key, so it goes through the attribute loop —
    // which calls the same flattener on every value the model invented.
    let tolerable: [String: Any] = [
      "upsert": [
        "immutableCanon": [
          ["id": NSNull(), "statement": "灰雾之上存在旧日", "sourceChapter": NSNull()],
        ],
        "entities": [
          ["id": "E-1", "name": "克莱恩", "owner": NSNull(), "aliases": NSNull(), "location": NSNull()],
        ],
        "timeline": [
          [
            "id": "T-nested",
            "label": ["text": "占卜家途径开启"],
            "sourceDay": 12,
            "sourceChapter": 99,
          ],
        ],
      ]
    ]

    // The real assertion is that this returns at all: before the fix the process
    // aborted inside this call with an uncatchable ObjC exception.
    let delta = try await core.normalizedConsistencyDelta(tolerable, chapterNumber: 1)

    let canonStatements = delta.upsert.immutableCanon.map { $0.statement }
    precondition(
      canonStatements == ["灰雾之上存在旧日"],
      "可选字段为 null 不应影响正常条目：\(canonStatements)"
    )
    // A null id falls back to the derived stable id rather than an empty one.
    let canonIDs = delta.upsert.immutableCanon.map { $0.id }
    precondition(
      canonIDs.allSatisfy { !$0.isEmpty },
      "id 为 null 时应回退到派生 id：\(canonIDs)"
    )
    let entityNames = delta.upsert.entities.map { $0.name }
    precondition(entityNames == ["克莱恩"], "实体不应因可选字段为 null 被丢弃：\(entityNames)")
    let entityOwners = delta.upsert.entities.map { $0.owner ?? "nil" }
    precondition(entityOwners == ["nil"], "owner 为 null 应变成 nil 而不是空串：\(entityOwners)")
    // The nested wrapper is unwrapped to its exact prose, and ordinary chapter
    // deltas are not allowed to write source-axis coordinates.
    let labels = delta.upsert.timeline.map { $0.label }
    precondition(
      labels == ["占卜家途径开启"],
      "嵌套对象应解包成精确正文文本：\(labels)"
    )
    precondition(
      delta.upsert.timeline.allSatisfy { $0.sourceDay == nil && $0.sourceChapter == nil },
      "普通章节 Delta 不得污染原著时间坐标：\(delta.upsert.timeline)"
    )

    // A null in a *required* text field is a different contract: it must surface as
    // a catchable Swift error naming the field, so the batch can be retried or
    // reported. Crashing and throwing are both "rejected", but only one is survivable.
    var rejected = false
    do {
      _ = try await core.normalizedConsistencyDelta(
        ["upsert": ["immutableCanon": [["id": "C-null", "statement": NSNull()]]]],
        chapterNumber: 1
      )
    } catch {
      rejected = true
    }
    precondition(rejected, "必填字段为 null 时应抛出可捕获错误")

    print("Model-null normalization probe passed: NSNull tolerated, required nulls throw")
  }
}
