import Foundation

/// Craft governance: the always-on writing kernel, the per-book editable craft
/// rules file, the chapter-level beat sheet layer, and regeneration of the
/// runtime state files that describe "where the story stands right now".
extension InkOSCore {
  static let chapterBeatPlanVersion = 1
  static let chapterBeatBatchSize = 10

  /// Non-removable craft rules. The editable per-book file can extend these but
  /// never replace them, because these are the constraints that keep a chapter
  /// from collapsing into summary.
  static let craftKernel = """
    【写法内核·不可关闭】
    1 场景纪律：本章由具体场景构成，每个场景要有地点、在场人物、可被观察的动作和对话。禁止用叙述性总结代替关键场景。禁止出现“两个小时后”“战斗持续了两个多小时，最终对方退去”“接下来的时间他几乎没停”这类把冲突压缩成结论的写法。决定写的冲突就完整写出过程，不打算写的冲突不要在本章提起。
    2 入场：从一个具体时刻、动作或对话切入。禁止以天气综述、世界背景讲解或人物履历开场。人物的身份、职业和特长通过行动、选择、对话和他人反应透出，禁止成段的简历式介绍。
    3 信息节奏：单章新引入的具名人物不得超过节拍卡允许的数量，每个新人物必须有一次能被记住的具体行为或台词。禁止在同一章同时铺开多条新线索。
    4 对话承载：关键的分歧、说服、交易、命令和情绪转折必须落在对话和即时反应上。禁止由旁白替角色下结论，禁止用“他说话不重，却带着压迫感”这类评语代替能产生压迫感的台词本身。
    5 场面完成度：本章主要冲突必须在场景内被看见发生，并且至少包含一次挫折、失败或代价。禁止提出问题后一次到位地解决。
    6 视角：贴近本章视角人物，只写该人物此刻能感知、能推断的内容。不跳入他人内心，不使用全知补述，不提前解释角色尚未知道的事。
    7 时间尺度：本章覆盖的现实时间不得超过节拍卡设定的范围。跨越更长时间必须由节拍卡明确要求。
    8 结尾：章末停在选择、反转、倒计时或新信息上。不做本章总结，不预告下一章，不用格言式独白收尾。
    9 篇幅：正文字数必须落在本章计划区间内。靠场景展开、对话和细节达到字数，禁止靠编号清单、条目化盘点、备忘录正文和资料登记堆字数；此类内容单章合计不超过 200 字。
    10 排期：只写本章节拍卡列出的内容。节拍卡未列出的后续剧情、副本、任务、地点、人物、物品和能力，不得提前出现、提前获得或提前解决。
    """

  /// Extra constraints for the first chapters, where the failure mode is
  /// compressing dozens of chapters of arc into one.
  static let openingCraftKernel = """
    【开篇章附加规则】
    - 本章只允许一条主线动作和一到两个主要场景，用于建立主角的处境、性格和眼前的具体麻烦。
    - 主角的核心能力或金手指最多以异常征兆、首次显现或章末触发的形式出现，禁止在本章内完成“获得能力—使用能力—拿到收益—收益落地”的完整循环。
    - 本章新引入的具名人物不超过三个。
    - 世界规则只透露主角此刻能直接感知的部分，禁止交代后续才会揭示的机制、组织和地理格局。
    - 主角的能力、地位和影响力从零开始建立：他此刻还没有被众人服从的理由，任何号令、组织和话语权都必须先付出代价、遭遇质疑或失败。
    """

  static let defaultCraftRules = """
    # 写法约束

    本文件是本书的写法约束，可在设置页编辑。系统写法内核始终生效，本文件用于叠加本书特有的要求。

    ## 叙事
    - 每章围绕一个可量化的具体问题推进，问题在章内被看见、被尝试、被挫折，不要求章内解决。
    - 群体场面通过两三个有名字的个体反应呈现，不用“有人说”“众人议论”铺满。
    - 专业内容按“遇到问题—现场判断—动手尝试—出现偏差—付出代价后得到部分结果”的顺序写，不做讲座式说明。

    ## 语言
    - 以动作、对话和可感知细节推进，形容词和评语克制。
    - 人物说话符合其身份、处境和情绪，不同角色的语言习惯要能区分。
    - 避免成语堆砌、口号式收尾和对主角的直接夸赞。

    ## 禁止
    - 禁止用清单、表格、备忘录和资料登记块承担叙事功能。
    - 禁止主角在缺少铺垫的情况下获得他人服从、信任和资源。
    - 禁止在同一章里既建立危机又彻底解除危机。
    """

  // MARK: - Craft rules file

  func craftRulesText(bookID: String) throws -> String {
    let url = try existingBookURL(bookID).appendingPathComponent("story/craft_rules.md")
    if !fileManager.fileExists(atPath: url.path) {
      try atomicWrite(Self.defaultCraftRules + "\n", to: url)
      recordDebug(scope: "craft", message: "craft_rules.created", data: ["bookId": bookID])
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? Self.defaultCraftRules
  }

  /// Craft directives injected into generation, revision and review prompts.
  func craftDirectives(bookID: String, chapterNumber: Int, openingChapterLimit: Int = 3) throws -> String {
    var sections = [Self.craftKernel]
    if chapterNumber <= openingChapterLimit { sections.append(Self.openingCraftKernel) }
    let rules = try craftRulesText(bookID: bookID).trimmingCharacters(in: .whitespacesAndNewlines)
    if !rules.isEmpty {
      sections.append("【本书写法约束·设置页可编辑】\n" + String(rules.prefix(8_000)))
    }
    return sections.joined(separator: "\n\n")
  }

  // MARK: - Chapter beat sheets

  func chapterBeatsURL(bookID: String) throws -> URL {
    try existingBookURL(bookID).appendingPathComponent("story/runtime/chapter-beats.json")
  }

  func loadChapterBeatPlan(bookID: String) throws -> ChapterBeatPlan {
    let url = try chapterBeatsURL(bookID: bookID)
    guard fileManager.fileExists(atPath: url.path) else {
      return ChapterBeatPlan(bookId: bookID, updatedAt: isoTimestamp())
    }
    do { return try decoder.decode(ChapterBeatPlan.self, from: Data(contentsOf: url)) }
    catch {
      throw InkOSCoreError("章节节拍卡格式错误：\(error.localizedDescription)", statusCode: 503)
    }
  }

  func fetchChapterBeats(bookID: String) async throws -> ChapterBeatPlan {
    try loadChapterBeatPlan(bookID: bookID)
  }

  func chapterBeat(bookID: String, chapterNumber: Int) throws -> ChapterBeat? {
    try loadChapterBeatPlan(bookID: bookID).beats.first { $0.number == chapterNumber }
  }

  /// Drops beats from `fromChapter` onward so the next generation regenerates
  /// them against the current plan and continuity.
  func invalidateChapterBeats(bookID: String, fromChapter: Int) async throws -> ChapterBeatPlan {
    var plan = try loadChapterBeatPlan(bookID: bookID)
    let removedBeats = plan.beats.filter { $0.number >= fromChapter }.count
    plan.beats.removeAll { $0.number >= fromChapter }
    plan.batches.removeAll { $0.endChapter >= fromChapter }
    plan.updatedAt = isoTimestamp()
    try atomicWrite(encoder.encode(plan), to: try chapterBeatsURL(bookID: bookID))
    recordDebug(scope: "craft", message: "chapter_beats.invalidated", data: [
      "bookId": bookID, "fromChapter": fromChapter, "removedBeats": removedBeats,
    ])
    return plan
  }

  /// Returns the beat sheet for one chapter, generating the whole surrounding
  /// batch if it does not exist yet.
  func ensureChapterBeat(
    bookID: String,
    chapterNumber: Int,
    plan: LongFormPlanResponse
  ) async throws -> ChapterBeat {
    if let existing = try chapterBeat(bookID: bookID, chapterNumber: chapterNumber) {
      return existing
    }
    let range = beatBatchRange(chapterNumber: chapterNumber, plan: plan)
    let generated = try await generateChapterBeatBatch(
      bookID: bookID,
      range: range,
      plan: plan
    )
    guard let beat = generated.beats.first(where: { $0.number == chapterNumber }) else {
      throw InkOSCoreError("节拍卡生成结果缺少第 \(chapterNumber) 章", statusCode: 502)
    }
    return beat
  }

  private func beatBatchRange(
    chapterNumber: Int,
    plan: LongFormPlanResponse
  ) -> (start: Int, end: Int, volume: Int) {
    let chapterPlan = plan.plan.chapters.first { $0.number == chapterNumber }
    let volumeNumber = chapterPlan?.volumeNumber ?? 1
    let volume = plan.plan.volumes.first { $0.number == volumeNumber }
    let volumeStart = volume?.startChapter ?? chapterNumber
    let volumeEnd = volume?.endChapter ?? chapterNumber
    let size = Self.chapterBeatBatchSize
    let offset = (chapterNumber - volumeStart) / size
    let start = volumeStart + offset * size
    let end = min(start + size - 1, volumeEnd)
    return (start, end, volumeNumber)
  }

  private func generateChapterBeatBatch(
    bookID: String,
    range: (start: Int, end: Int, volume: Int),
    plan: LongFormPlanResponse
  ) async throws -> ChapterBeatPlan {
    let prompt = try chapterBeatPrompt(bookID: bookID, range: range, plan: plan)
    let result = try await requestLLM(prompt: prompt, role: .review, json: true, timeout: 300)
    let parsed = parseJSONObject(result.content) ?? [:]
    let rawBeats = parsed["beats"] as? [Any] ?? []
    var beats: [ChapterBeat] = []
    for raw in rawBeats {
      guard let object = raw as? [String: Any], let number = integer(object["number"]),
        number >= range.start, number <= range.end
      else { continue }
      beats.append(normalizedChapterBeat(object, number: number, volumeNumber: range.volume))
    }
    let expected = Set(range.start...range.end)
    let produced = Set(beats.map(\.number))
    guard expected.subtracting(produced).isEmpty else {
      let missing = expected.subtracting(produced).sorted().map(String.init).joined(separator: "、")
      throw InkOSCoreError("节拍卡生成不完整，缺少第 \(missing) 章", statusCode: 502)
    }

    var stored = try loadChapterBeatPlan(bookID: bookID)
    stored.beats.removeAll { $0.number >= range.start && $0.number <= range.end }
    stored.beats.append(contentsOf: beats)
    stored.beats.sort { $0.number < $1.number }
    stored.batches.removeAll { $0.startChapter == range.start && $0.endChapter == range.end }
    stored.batches.append(ChapterBeatBatch(
      startChapter: range.start,
      endChapter: range.end,
      volumeNumber: range.volume,
      planRevision: plan.revision,
      generatedAt: isoTimestamp(),
      model: result.model
    ))
    stored.batches.sort { $0.startChapter < $1.startChapter }
    stored.updatedAt = isoTimestamp()
    let url = try chapterBeatsURL(bookID: bookID)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try atomicWrite(encoder.encode(stored), to: url)
    recordDebug(scope: "craft", message: "chapter_beats.generated", data: [
      "bookId": bookID,
      "startChapter": range.start,
      "endChapter": range.end,
      "volumeNumber": range.volume,
      "model": result.model,
      "latencyMs": result.latencyMilliseconds,
    ])
    return stored
  }

  private func chapterBeatPrompt(
    bookID: String,
    range: (start: Int, end: Int, volume: Int),
    plan: LongFormPlanResponse
  ) throws -> String {
    let volume = plan.plan.volumes.first { $0.number == range.volume }
    let volumeStart = volume?.startChapter ?? range.start
    let volumeEnd = volume?.endChapter ?? range.end
    let volumeChapters = max(1, volumeEnd - volumeStart + 1)
    let progressStart = percentText(range.start - volumeStart, of: volumeChapters)
    let progressEnd = percentText(range.end - volumeStart + 1, of: volumeChapters)
    let targetWords = plan.plan.chapters.first { $0.number == range.start }?.targetWords
      ?? plan.constraints.targetChapterWords

    let storyFrame = try settingText(bookID: bookID, path: "outline/story_frame.md", limit: 6_000)
    let volumeMap = try settingText(bookID: bookID, path: "outline/volume_map.md", limit: 12_000)
    let bible = try settingText(bookID: bookID, path: "story_bible.md", limit: 10_000)
    let styleGuide = try settingText(bookID: bookID, path: "style_guide.md", limit: 4_000)
    let summaries = try recentChapterSummaries(bookID: bookID, limit: 8_000)
    let previousBeats = try previousBeatsText(bookID: bookID, before: range.start, count: 4)
    let openHooks = openHooksText(plan.continuity, upTo: range.end)
    let knownEntities = knownEntitiesText(plan.continuity, limit: 60)

    return """
      你是长篇小说的章节节拍规划编辑。为第 \(range.start) 至 \(range.end) 章各生成一张节拍卡。
      本批次属于第 \(range.volume) 卷（第 \(volumeStart)-\(volumeEnd) 章，共 \(volumeChapters) 章），覆盖本卷进度的 \(progressStart)% 至 \(progressEnd)%。
      每章约 \(targetWords) 字。

      最重要的约束是排期纪律：
      1. 只允许推进分卷地图中排期落在第 \(range.start) 至 \(range.end) 章的内容。分卷地图里排期在第 \(range.end) 章之后的剧情、任务、副本、地点、组织、人物和物品，必须写进对应章节的 forbiddenElements，不得在本批次发生。
      2. 单章只承载一个主要问题。一个副本、一次任务、一场救援或一项工程不能在一章内从开始走到收尾，除非分卷地图明确只给它一章。
      3. 本批次结束时故事的推进量必须与 \(progressEnd)% 的卷内进度相称，不得提前完成本卷阶段目标。
      4. 已在既有章节发生的事不要重复安排；未登记的新人物和新物品要少量、必要且可追溯。

      同样有约束力的是开篇与钩子的排期纪律：
      1. 若本批次覆盖第 1 章，第一章必须给出主角核心能力或金手指的明确锚点——异常征兆、首次显现或章末触发均可，但不得整章回避。核心能力的完整使用循环可以推迟，其存在本身不能推迟到第 4 章之后。
      2. 每章的 endingHook 必须是读者能立刻预期"下一章会发生什么"的具体事件：一个待做的选择、一个刚揭露的反转、一个正在走动的倒计时、一条刚到手的新线索。禁止用氛围描写、情绪总结或主角安心收尾作为 endingHook。
      3. 主角的 setback 必须让他在本章结束时处于比开场更被动或更紧迫的位置，而不是"清点完家底后安心等待"。

      字段含义：
      number 章号；volumeNumber 卷号；goal 本章要解决或推进的一个具体问题；openingHook 开场的具体时刻或动作，不是背景介绍；scenes 本章 1 至 3 个场景，每项写清地点、在场人物和现场冲突；requiredEvents 本章必须在正文里被看见发生的事，2 至 4 条，写成可验证的具体事件；forbiddenElements 本章禁止提前出现或提前解决的内容，3 至 6 条，逐条点名具体剧情、人物、物品或能力；endingHook 章末停留的选择、反转、倒计时或新信息；focusCharacters 本章出场并有作用的人物，含新引入者；newNamedCharacters 本章新引入的具名人物数量；timeSpan 本章覆盖的故事时间跨度；setback 本章必须出现的挫折、代价或失败；notes 给写作模型的补充提醒。

      只输出 JSON：
      {"beats":[{"number":\(range.start),"volumeNumber":\(range.volume),"goal":"","openingHook":"","scenes":[""],"requiredEvents":[""],"forbiddenElements":[""],"endingHook":"","focusCharacters":[""],"newNamedCharacters":0,"timeSpan":"","setback":"","notes":""}]}
      beats 必须按章号升序覆盖第 \(range.start) 至 \(range.end) 章，一章一项，不多不少。所有字符串字段非空。

      【故事基石】
      \(storyFrame)

      【分卷地图】
      \(volumeMap)

      【故事圣经】
      \(bible)

      【文风与节奏】
      \(styleGuide)

      【已写章节摘要】
      \(summaries)

      【上一批次节拍卡】
      \(previousBeats)

      【未回收伏笔】
      \(openHooks)

      【已登记实体】
      \(knownEntities)
      """
  }

  private func normalizedChapterBeat(
    _ object: [String: Any],
    number: Int,
    volumeNumber: Int
  ) -> ChapterBeat {
    ChapterBeat(
      number: number,
      volumeNumber: integer(object["volumeNumber"]) ?? volumeNumber,
      goal: beatText(object["goal"]),
      openingHook: beatText(object["openingHook"]),
      scenes: beatList(object["scenes"], limit: 4),
      requiredEvents: beatList(object["requiredEvents"], limit: 6),
      forbiddenElements: beatList(object["forbiddenElements"], limit: 10),
      endingHook: beatText(object["endingHook"]),
      focusCharacters: beatList(object["focusCharacters"], limit: 12),
      newNamedCharacters: integer(object["newNamedCharacters"]),
      timeSpan: beatText(object["timeSpan"]),
      setback: beatText(object["setback"]),
      notes: beatText(object["notes"])
    )
  }

  private func beatText(_ value: Any?) -> String {
    string(value).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func beatList(_ value: Any?, limit: Int) -> [String] {
    let items: [Any]
    if let array = value as? [Any] { items = array }
    else if let value, !(value is NSNull) { items = [value] }
    else { items = [] }
    return items.map { beatText($0) }.filter { !$0.isEmpty }.prefix(limit).map { $0 }
  }

  /// Human-readable beat card injected into generation and review prompts.
  func beatBriefText(_ beat: ChapterBeat) -> String {
    var lines = ["第\(beat.number)章节拍卡（第\(beat.volumeNumber)卷）"]
    if !beat.goal.isEmpty { lines.append("本章目标：\(beat.goal)") }
    if !beat.openingHook.isEmpty { lines.append("入场点：\(beat.openingHook)") }
    if !beat.timeSpan.isEmpty { lines.append("时间跨度：\(beat.timeSpan)") }
    if !beat.scenes.isEmpty {
      lines.append("场景：")
      lines.append(contentsOf: beat.scenes.enumerated().map { "  \($0.offset + 1). \($0.element)" })
    }
    if !beat.requiredEvents.isEmpty {
      lines.append("必须在正文里被看见发生：")
      lines.append(contentsOf: beat.requiredEvents.map { "  - \($0)" })
    }
    if !beat.setback.isEmpty { lines.append("必须出现的挫折或代价：\(beat.setback)") }
    if !beat.forbiddenElements.isEmpty {
      lines.append("本章禁止提前出现或提前解决：")
      lines.append(contentsOf: beat.forbiddenElements.map { "  - \($0)" })
    }
    if !beat.focusCharacters.isEmpty {
      lines.append("出场人物：\(beat.focusCharacters.joined(separator: "、"))")
    }
    if let count = beat.newNamedCharacters {
      lines.append("新引入具名人物上限：\(count) 个")
    }
    if !beat.endingHook.isEmpty { lines.append("章末停留：\(beat.endingHook)") }
    if !beat.notes.isEmpty { lines.append("补充提醒：\(beat.notes)") }
    return lines.joined(separator: "\n")
  }

  // MARK: - Runtime state regeneration

  /// Rewrites the runtime narrative state files from the approved-chapter
  /// continuity projection so the next chapter reads a true "current state"
  /// instead of the creation-time placeholder.
  func refreshRuntimeStateFiles(bookID: String, plan: LongFormPlanResponse) {
    let storyURL = (try? existingBookURL(bookID))?
      .appendingPathComponent("story", isDirectory: true)
    guard let storyURL else { return }
    let approved = approvedChapterNumbers(bookID: bookID)
    let latest = approved.max() ?? 0
    let next = latest + 1
    let beats = (try? loadChapterBeatPlan(bookID: bookID))?.beats ?? []

    let state = currentStateText(plan: plan, latestChapter: latest, approvedCount: approved.count)
    let hooks = pendingHooksText(plan: plan, latestChapter: latest)
    let focus = currentFocusText(
      plan: plan,
      nextChapter: next,
      beat: beats.first { $0.number == next }
    )
    try? atomicWrite(state, to: storyURL.appendingPathComponent("current_state.md"))
    try? atomicWrite(hooks, to: storyURL.appendingPathComponent("pending_hooks.md"))
    try? atomicWrite(focus, to: storyURL.appendingPathComponent("current_focus.md"))
    recordDebug(scope: "craft", message: "runtime_state.refreshed", data: [
      "bookId": bookID, "latestApprovedChapter": latest, "nextChapter": next,
    ])
  }

  private func approvedChapterNumbers(bookID: String) -> [Int] {
    guard let stateBook = try? stateBookObject(bookID: bookID, allowMissing: true),
      let records = try? readChapterRecords(bookID: bookID, stateBook: stateBook)
    else { return [] }
    return records.compactMap { record in
      guard ["approved", "published"].contains(string(record["status"])) else { return nil }
      return integer(record["number"])
    }
  }

  private func currentStateText(
    plan: LongFormPlanResponse,
    latestChapter: Int,
    approvedCount: Int
  ) -> String {
    var lines = [
      "# 当前状态",
      "",
      "本文件由 InkOSCore 在章节审核通过后自动生成，手工修改会在下次审核后被覆盖。连续性事实的人工调整请在设置页的连续性覆盖中进行。",
      "",
      "## 进度",
    ]
    if latestChapter == 0 {
      lines.append("尚无已审核章节。所有角色与世界状态以故事圣经和硬规则为准。")
    } else {
      let volume = plan.plan.volumes.first {
        latestChapter >= $0.startChapter && latestChapter <= $0.endChapter
      }
      let volumeText = volume.map { "第\($0.number)卷（第\($0.startChapter)-\($0.endChapter)章）" } ?? "未定卷"
      lines.append("已审核 \(approvedCount) 章，最新已审核为第 \(latestChapter) 章，位于\(volumeText)。")
      lines.append("下一章：第 \(latestChapter + 1) 章。")
    }

    let timeline = plan.continuity.timeline
      .sorted { $0.order < $1.order }
      .suffix(6)
    if !timeline.isEmpty {
      lines.append(contentsOf: ["", "## 最近时间线"])
      lines.append(contentsOf: timeline.map { "- 第\($0.earliestChapter)章：\($0.label)" })
    }

    let characters = plan.continuity.entities.filter { $0.type == "character" }.prefix(20)
    if !characters.isEmpty {
      lines.append(contentsOf: ["", "## 在场人物与状态"])
      lines.append(contentsOf: characters.map { entity in
        var parts: [String] = []
        if let location = entity.location { parts.append("位置 \(location)") }
        if let owner = entity.owner { parts.append("归属 \(owner)") }
        let attributes = entity.attributes.sorted { $0.key < $1.key }
          .prefix(4).map { "\($0.key) \($0.value)" }
        parts.append(contentsOf: attributes)
        return "- \(entity.name)：" + (parts.isEmpty ? "无附加状态" : parts.joined(separator: "；"))
      })
    }

    let assets = plan.continuity.entities.filter { $0.type != "character" }.prefix(24)
    if !assets.isEmpty {
      lines.append(contentsOf: ["", "## 物品、地点与组织"])
      lines.append(contentsOf: assets.map { entity in
        var parts = ["类型 \(entity.type)"]
        if let location = entity.location { parts.append("位置 \(location)") }
        let attributes = entity.attributes.sorted { $0.key < $1.key }
          .prefix(4).map { "\($0.key) \($0.value)" }
        parts.append(contentsOf: attributes)
        return "- \(entity.name)：" + parts.joined(separator: "；")
      })
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func pendingHooksText(plan: LongFormPlanResponse, latestChapter: Int) -> String {
    var lines = [
      "# 伏笔池",
      "",
      "本文件由 InkOSCore 在章节审核通过后自动生成，手工修改会在下次审核后被覆盖。",
    ]
    let hooks = plan.continuity.hooks.sorted { $0.openFromChapter < $1.openFromChapter }
    let overdue = hooks.filter { hook in
      guard let deadline = hook.resolveByChapter else { return false }
      return deadline <= latestChapter
    }
    let pending = hooks.filter { hook in
      guard let deadline = hook.resolveByChapter else { return true }
      return deadline > latestChapter
    }
    if !overdue.isEmpty {
      lines.append(contentsOf: ["", "## 已到期需尽快回收"])
      lines.append(contentsOf: overdue.map(hookLine))
    }
    lines.append(contentsOf: ["", "## 未回收"])
    lines.append(contentsOf: pending.isEmpty ? ["当前没有登记的未回收伏笔。"] : pending.map(hookLine))
    return lines.joined(separator: "\n") + "\n"
  }

  private func hookLine(_ hook: LongFormHookPlan) -> String {
    var parts = ["开启于第\(hook.openFromChapter)章"]
    if let deadline = hook.resolveByChapter { parts.append("要求第\(deadline)章前回收") }
    if let volume = hook.requiredVolumeNumber { parts.append("归属第\(volume)卷") }
    return "- \(hook.description)（\(parts.joined(separator: "，"))）"
  }

  private func currentFocusText(
    plan: LongFormPlanResponse,
    nextChapter: Int,
    beat: ChapterBeat?
  ) -> String {
    var lines = [
      "# 当前聚焦",
      "",
      "本文件由 InkOSCore 自动生成，内容来自第 \(nextChapter) 章节拍卡。",
      "",
    ]
    if let beat {
      lines.append(beatBriefText(beat))
    } else {
      let volume = plan.plan.volumes.first {
        nextChapter >= $0.startChapter && nextChapter <= $0.endChapter
      }
      let volumeText = volume.map { "第\($0.number)卷（第\($0.startChapter)-\($0.endChapter)章）" } ?? "未定卷"
      lines.append("第 \(nextChapter) 章节拍卡尚未生成，将在开始生成该章时按批次自动规划。当前所属\(volumeText)。")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Length enforcement

  /// Enforces the per-chapter word window from the long-form plan. The window
  /// itself stays on proseCount, which is the number the plan was budgeted in
  /// and the number the reader sees on the shelf. A second, lower floor checks
  /// Chinese-character density so a chapter cannot reach the window on
  /// punctuation and whitespace: a dialogue-heavy chapter legitimately spends
  /// well under 100% of its count on characters, but under 85% means the prose
  /// is padded rather than written.
  func validateChapterLength(
    _ content: String,
    chapterNumber: Int,
    minWords: Int,
    maxWords: Int,
    label: String
  ) throws {
    let count = proseCount(content)
    let bodyCount = bodyWordCount(content)
    guard count >= 500 else {
      throw InkOSCoreError("模型返回的\(label)过短（\(count) 字）", statusCode: 422)
    }
    // Allow a small margin above the plan window before failing, so a chapter
    // is not rejected for overshooting by a sentence.
    let ceiling = maxWords + max(200, maxWords / 10)
    guard count >= minWords else {
      throw InkOSCoreError(
        "第\(chapterNumber)章\(label)只有 \(count) 字，低于计划下限 \(minWords) 字。需要把节拍卡的场景真正展开，而不是概述。",
        statusCode: 422
      )
    }
    let bodyFloor = minWords * 85 / 100
    guard bodyCount >= bodyFloor else {
      throw InkOSCoreError(
        "第\(chapterNumber)章\(label)共 \(count) 字，但其中只有 \(bodyCount) 个中文字符，低于正文密度下限 \(bodyFloor) 字。本章靠标点、空行或符号凑到了计划字数，需要把场景真正展开。",
        statusCode: 422
      )
    }
    guard count <= ceiling else {
      throw InkOSCoreError(
        "第\(chapterNumber)章\(label)达到 \(count) 字，超过计划上限 \(maxWords) 字。本章承载的剧情量超出排期，应把多余内容留给后续章节。",
        statusCode: 422
      )
    }
  }

  // MARK: - Deterministic craft checks

  /// Local, non-LLM backstop for rules the review model tends to let through as
  /// soft advisories. These checks reject content before it ever reaches the
  /// review pass, so a chapter cannot "pass" while violating its own craft
  /// constraints. Anything semantic (is the ending actually a hook) stays with
  /// the review model's hard rules.
  func validateChapterCraft(
    _ content: String,
    chapterNumber: Int,
    label: String
  ) throws {
    try rejectLedgerBlocks(content, chapterNumber: chapterNumber, label: label)
    try rejectAphoristicEnding(content, chapterNumber: chapterNumber, label: label)
    if chapterNumber <= 3 {
      try requireOpeningAbilityAnchor(content, chapterNumber: chapterNumber, label: label)
    }
  }

  /// Ledger-style narration: three or more consecutive lines that each open
  /// with a `标签：` enumeration. This is the shape the craft rules forbid —
  /// inventory, memo and registration blocks doing narrative work — regardless
  /// of whether the review model flags it.
  private func rejectLedgerBlocks(
    _ content: String,
    chapterNumber: Int,
    label: String
  ) throws {
    var run = 0
    var worst = 0
    for rawLine in content.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      var isLedgerLine = false
      if line.count <= 80,
        let colonMatch = line.range(of: "^[^：:，。\\s]{1,8}[：:]", options: .regularExpression) {
        let content = line[colonMatch.upperBound...].drop(while: { $0 == " " })
        // Dialogue attribution (他说："…") shares the label-colon shape; only
        // unquoted enumeration is a ledger entry.
        let quoteOpeners: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "「", "『"]
        if let first = content.first, !quoteOpeners.contains(first) {
          isLedgerLine = true
        }
      }
      if isLedgerLine {
        run += 1
        worst = max(worst, run)
      } else if !line.isEmpty {
        run = 0
      }
    }
    guard worst < 3 else {
      throw InkOSCoreError(
        "第\(chapterNumber)章\(label)出现 \(worst) 条连续的清单式条目（“标签：内容”）。写法约束禁止用清单、备忘录和条目化盘点承担叙事，请把账本信息改写为动作与判断混合的叙述。",
        statusCode: 422
      )
    }
  }

  /// Aphoristic or fade-out endings: the final line is a summary, a maxim, or
  /// the protagonist settling in to wait, instead of landing on a choice,
  /// reversal, countdown or new information.
  private func rejectAphoristicEnding(
    _ content: String,
    chapterNumber: Int,
    label: String
  ) throws {
    let tail = content.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .suffix(3)
      .joined()
    // Markers must be long enough to be unambiguous: a bare "熬" or "伴着"
    // appears in perfectly hooked endings, so only settled, completed-action
    // fade-outs are listed here. Borderline endings fall through to the
    // review model's hard rule, which is the cheaper failure.
    let fadeOutMarkers = [
      "陪着他入睡", "沉沉睡去", "进入梦乡", "一夜无话", "安然入睡",
      "渐渐平静", "恢复了平静", "一切又归于", "的第一夜", "熬过了这一夜",
      "度过了这一夜"
    ]
    let summaryMarkers = ["这就是", "他终于明白", "从这一天起", "无论如何，生活还要继续"]
    let tailText = String(tail.suffix(80))
    if fadeOutMarkers.contains(where: tailText.contains) || summaryMarkers.contains(where: tailText.contains) {
      throw InkOSCoreError(
        "第\(chapterNumber)章\(label)以总结、氛围淡出或格言式收尾收束全章。章末必须停在选择、反转、倒计时或新信息上，请重写结尾。",
        statusCode: 422
      )
    }
  }

  /// Opening chapters must not dodge the protagonist's core ability entirely.
  /// The review prompt states the rule; this check enforces the cheap part of
  /// it — the text must at least gesture at the abnormal. The word list is
  /// deliberately generic (no book-specific proper nouns) so it only rejects
  /// chapters that contain no anomaly vocabulary at all; the review model
  /// still judges whether the anchor is meaningful.
  private func requireOpeningAbilityAnchor(
    _ content: String,
    chapterNumber: Int,
    label: String
  ) throws {
    let anchors = [
      "异常", "不对", "不该", "不属于",
      "凭空", "多出来", "原本没有", "不在这里", "消失", "出现了", "没有道理"
    ]
    guard anchors.contains(where: content.contains) else {
      throw InkOSCoreError(
        "第\(chapterNumber)章是开篇章，但正文完全没有触及主角核心能力或金手指的任何征兆。开篇章必须以异常征兆、首次显现或章末触发的形式给出能力锚点。",
        statusCode: 422
      )
    }
  }

  // MARK: - Shared helpers

  func settingText(bookID: String, path: String, limit: Int) throws -> String {
    let url = try existingBookURL(bookID)
      .appendingPathComponent("story", isDirectory: true)
      .appendingPathComponent(path)
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "（缺失）" }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "（空）" : String(trimmed.prefix(limit))
  }

  private func recentChapterSummaries(bookID: String, limit: Int) throws -> String {
    let text = try settingText(bookID: bookID, path: "chapter_summaries.md", limit: .max)
    guard text.count > limit else { return text }
    return "（已截断，保留最近内容）\n" + String(text.suffix(limit))
  }

  private func previousBeatsText(bookID: String, before: Int, count: Int) throws -> String {
    let beats = try loadChapterBeatPlan(bookID: bookID).beats
      .filter { $0.number < before }
      .sorted { $0.number < $1.number }
      .suffix(count)
    guard !beats.isEmpty else { return "（无，本批次是首个批次）" }
    return beats.map(beatBriefText).joined(separator: "\n\n")
  }

  private func openHooksText(_ continuity: LongFormContinuity, upTo chapter: Int) -> String {
    let hooks = continuity.hooks.filter { $0.openFromChapter <= chapter }
    guard !hooks.isEmpty else { return "（无）" }
    return hooks.sorted { $0.openFromChapter < $1.openFromChapter }.map(hookLine).joined(separator: "\n")
  }

  private func knownEntitiesText(_ continuity: LongFormContinuity, limit: Int) -> String {
    guard !continuity.entities.isEmpty else { return "（无）" }
    return continuity.entities.prefix(limit)
      .map { "- \($0.name)（\($0.type)）" }
      .joined(separator: "\n")
  }

  private func percentText(_ value: Int, of total: Int) -> String {
    guard total > 0 else { return "0" }
    return String(format: "%.1f", Double(value) / Double(total) * 100)
  }
}
