import Foundation

extension InkOSCore {
  /// Subdirectories of `story/` that hold machine-owned runtime state rather
  /// than editable settings: consistency deltas, the continuity projection,
  /// chapter beats and volume checkpoints.
  ///
  /// These are excluded from settings backup and restore. A backup used to copy
  /// all of `story/`, and restore replaced the whole directory, so recovering a
  /// settings edit also rolled `runtime/` back — silently deleting the
  /// consistency deltas of every chapter written since the backup. Those
  /// chapters stay `approved` while their deltas vanish, which drops their facts
  /// from the continuity index and makes re-review fail on "本章缺少
  /// consistencyDelta". Continuity is not a setting; it is derived from approved
  /// chapters and must not travel with a text edit. Manual continuity changes go
  /// through the continuity overlay instead.
  static let nonEditableStorySubdirectories: Set<String> = ["runtime", "snapshots", "state"]

  // MARK: - Story settings

  func fetchBookSettings(bookID: String) async throws -> BookSettingsResponse {
    let storyURL = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    let groups: [[String: Any]] = settingGroups.map { ["id": $0.id, "title": $0.title, "order": $0.order] }
    let files = try markdownFiles(in: storyURL).compactMap { url -> [String: Any]? in
      let relative = relativePath(url, under: storyURL)
      let first = relative.split(separator: "/").first.map(String.init) ?? ""
      guard !Self.nonEditableStorySubdirectories.contains(first) else { return nil }
      let metadata = settingMetadata(relative)
      let group = settingGroups.first(where: { $0.id == metadata.group }) ?? settingGroups.last!
      return [
        "path": relative,
        "title": metadata.title,
        "description": metadata.description,
        "group": group.id,
        "groupTitle": group.title,
        "groupOrder": group.order,
        "order": metadata.order,
        "managed": metadata.managed,
      ]
    }.sorted {
      (integer($0["groupOrder"]) ?? 0, integer($0["order"]) ?? 0, string($0["path"]))
        < (integer($1["groupOrder"]) ?? 0, integer($1["order"]) ?? 0, string($1["path"]))
    }
    return try decodeObject([
      "storyDir": storyURL.path,
      "groups": groups,
      "files": files,
    ], as: BookSettingsResponse.self)
  }

  func fetchBookSetting(bookID: String, path: String) async throws -> String {
    let url = try editableSettingURL(bookID: bookID, path: path)
    guard fileManager.fileExists(atPath: url.path) else {
      throw InkOSCoreError("设定文件不存在", statusCode: 404)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  func saveBookSetting(bookID: String, path: String, content: String) async throws -> BookSettingSaveResponse {
    let url = try editableSettingURL(bookID: bookID, path: path)
    guard fileManager.fileExists(atPath: url.path) else {
      throw InkOSCoreError("设定文件不存在", statusCode: 404)
    }
    let backup = try createSettingsBackup(bookID: bookID)
    do { try atomicWrite(content, to: url) }
    catch {
      _ = try? restoreSettingsBackup(bookID: bookID, backupURL: backup)
      throw InkOSCoreError("保存失败，已恢复修改前设定：\(error.localizedDescription)")
    }
    recordDebug(scope: "settings", message: "story_setting.saved", data: [
      "bookId": bookID, "path": path, "size": content.utf8.count,
    ])
    return BookSettingSaveResponse(
      ok: true,
      path: path,
      size: content.count,
      backupDir: backup.path,
      message: "已保存并创建原子备份"
    )
  }

  func fetchBookSettingsBackups(bookID: String) async throws -> BookSettingsBackupsResponse {
    _ = try existingBookURL(bookID)
    let root = settingsBackupsURL.appendingPathComponent(bookID, isDirectory: true)
    let backups: [BookSettingsBackup] = try directoryContents(root, directoriesOnly: true).compactMap { url in
      guard let timestamp = Int64(url.lastPathComponent) else { return nil }
      return BookSettingsBackup(
        backupId: url.lastPathComponent,
        timestamp: timestamp,
        dir: url.path,
        time: isoTimestamp(Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000))
      )
    }.sorted { $0.timestamp > $1.timestamp }
    return BookSettingsBackupsResponse(backups: backups)
  }

  func restoreBookSettings(bookID: String, backupID: String) async throws -> BookSettingsRestoreResponse {
    guard backupID.allSatisfy(\.isNumber), !backupID.isEmpty else {
      throw InkOSCoreError("备份编号无效", statusCode: 400)
    }
    let backup = settingsBackupsURL.appendingPathComponent(bookID, isDirectory: true)
      .appendingPathComponent(backupID, isDirectory: true)
    guard fileManager.fileExists(atPath: backup.path) else {
      throw InkOSCoreError("备份不存在", statusCode: 404)
    }
    let restored = try restoreSettingsBackup(bookID: bookID, backupURL: backup)
    recordDebug(scope: "settings", message: "story_settings.restored", data: [
      "bookId": bookID, "backupId": backupID, "restoredCount": restored,
    ])
    return BookSettingsRestoreResponse(ok: true, restoredCount: restored)
  }

  private var settingGroups: [(id: String, title: String, order: Int)] {
    [
      ("direction", "创作方向", 10),
      ("canon", "世界与卷纲", 20),
      ("runtime", "当前写作状态", 30),
      ("characters", "角色档案", 40),
      ("other", "其他设定", 90),
    ]
  }

  private func settingMetadata(_ path: String) -> (group: String, order: Int, title: String, description: String, managed: Bool) {
    let known: [String: (String, Int, String, String, Bool)] = [
      "author_intent.md": ("direction", 10, "创作简报", "题材、主角定位、核心卖点与长期写作要求。", false),
      "brief.md": ("direction", 20, "项目简介", "创建时的基础需求。", false),
      "current_focus.md": ("direction", 30, "当前聚焦", "下一章的节拍卡摘要；由已审核进度自动重写。", true),
      "book_rules.md": ("canon", 10, "硬规则", "人物、能力、世界和叙事边界。", false),
      "protagonist.md": ("characters", 10, "主角性格", "主角的性格核心、缺陷、情绪习惯与说话方式；创建时经人工确认，生成章节的必读上下文。", false),
      "story_bible.md": ("canon", 20, "故事圣经", "世界观、力量体系与长期一致性依据。", false),
      "outline/story_frame.md": ("canon", 30, "故事基石", "核心冲突和终局方向。", false),
      "outline/volume_map.md": ("canon", 40, "分卷地图", "每卷范围、目标与回收安排。", false),
      "style_guide.md": ("canon", 50, "文风指南", "叙事视角、语言密度与表达边界。", false),
      "craft_rules.md": ("canon", 55, "写法约束", "场景纪律、信息节奏与禁止写法；系统写法内核始终额外生效。", false),
      "current_state.md": ("runtime", 10, "当前状态", "角色位置、伤势、资源与下一步目标；由已审核进度自动重写。", true),
      "pending_hooks.md": ("runtime", 20, "伏笔池", "伏笔进展与回收方向；由已审核进度自动重写。", true),
      "chapter_summaries.md": ("runtime", 30, "章节摘要", "已写章节的关键变化；每章提交后由系统追加。", false),
      "particle_ledger.md": ("runtime", 40, "资源账本", "资源、证物、伤势与消耗。", false),
      "object_ledger.md": ("runtime", 45, "持久对象账本", "跨章物品的稳定身份与状态。", false),
      "character_matrix.md": ("runtime", 50, "人物关系", "人物关系、立场与知情范围。", false),
      "emotional_arcs.md": ("runtime", 60, "情感弧线", "人物关系和情绪节奏。", false),
      "subplot_board.md": ("runtime", 70, "支线进度", "支线当前阶段和回收安排。", false),
      "audit_drift.md": ("runtime", 80, "审计纠偏", "最近审核对后续章节的提醒。", false),
    ]
    if let item = known[path] { return item }
    if path.hasPrefix("roles/") {
      return ("characters", 100, urlStem(path) + "角色卡", "角色背景、动机、关系和能力边界。", false)
    }
    if path.hasPrefix("outline/") {
      return ("canon", 90, urlStem(path), "故事或分卷规划文件。", false)
    }
    return ("other", 999, urlStem(path), "InkOS 小说设定文件。", false)
  }

  private func markdownFiles(in directory: URL) throws -> [URL] {
    guard let enumerator = fileManager.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }
      .filter { $0.pathExtension.lowercased() == "md" }
  }

  private func editableSettingURL(bookID: String, path: String) throws -> URL {
    let story = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true).standardizedFileURL
    let normalized = path.replacingOccurrences(of: "\\", with: "/")
    let first = normalized.split(separator: "/").first.map(String.init) ?? ""
    guard normalized.hasSuffix(".md"), !Self.nonEditableStorySubdirectories.contains(first) else {
      throw InkOSCoreError("设定路径无效", statusCode: 400)
    }
    let url = story.appendingPathComponent(normalized).standardizedFileURL
    guard url.path.hasPrefix(story.path + "/") else { throw InkOSCoreError("设定路径无效", statusCode: 400) }
    return url
  }

  /// Top-level entries of a `story/` directory that settings backup and restore
  /// own, i.e. everything except the machine-owned runtime state.
  private func editableStoryEntries(in directory: URL) throws -> [URL] {
    try directoryContents(directory).filter {
      !Self.nonEditableStorySubdirectories.contains($0.lastPathComponent)
    }
  }

  private func createSettingsBackup(bookID: String) throws -> URL {
    let story = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    let root = settingsBackupsURL.appendingPathComponent(bookID, isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    var timestamp = Int64(Date().timeIntervalSince1970 * 1000)
    var backup = root.appendingPathComponent(String(timestamp), isDirectory: true)
    while fileManager.fileExists(atPath: backup.path) {
      timestamp += 1
      backup = root.appendingPathComponent(String(timestamp), isDirectory: true)
    }
    try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
    for entry in try editableStoryEntries(in: story) {
      try fileManager.copyItem(
        at: entry,
        to: backup.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
      )
    }
    return backup
  }

  /// Restores the editable settings from a backup, leaving `runtime/` in place.
  ///
  /// Staged into a sibling directory first so a mid-copy failure cannot leave
  /// the book with neither the old nor the new settings. Backups taken before
  /// the exclusion existed still contain a `runtime/` snapshot; it is skipped
  /// on the way back so an old backup cannot resurrect stale continuity.
  @discardableResult
  private func restoreSettingsBackup(bookID: String, backupURL: URL) throws -> Int {
    let story = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    let staging = story.deletingLastPathComponent()
      .appendingPathComponent(".story-restore-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: staging) }
    let incoming = try editableStoryEntries(in: backupURL)
    for entry in incoming {
      try fileManager.copyItem(
        at: entry,
        to: staging.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
      )
    }
    try fileManager.createDirectory(at: story, withIntermediateDirectories: true)
    for entry in try editableStoryEntries(in: story) {
      try fileManager.removeItem(at: entry)
    }
    for entry in try directoryContents(staging) {
      try fileManager.moveItem(
        at: entry,
        to: story.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
      )
    }
    recordDebug(scope: "settings", message: "story_settings.restore.scope", data: [
      "bookId": bookID,
      "restoredEntries": incoming.count,
      "preservedRuntime": Self.nonEditableStorySubdirectories.sorted().joined(separator: ","),
    ])
    return try markdownFiles(in: story).count
  }

  private func relativePath(_ url: URL, under root: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
  }

  private func urlStem(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }
}
