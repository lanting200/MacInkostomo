import Foundation

extension InkOSCore {
  // MARK: - Story settings

  func fetchBookSettings(bookID: String) async throws -> BookSettingsResponse {
    let storyURL = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    let groups: [[String: Any]] = settingGroups.map { ["id": $0.id, "title": $0.title, "order": $0.order] }
    let files = try markdownFiles(in: storyURL).compactMap { url -> [String: Any]? in
      let relative = relativePath(url, under: storyURL)
      let first = relative.split(separator: "/").first.map(String.init) ?? ""
      guard !["runtime", "snapshots", "state"].contains(first) else { return nil }
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
      "current_focus.md": ("direction", 30, "当前聚焦", "接下来章节的优先目标。", false),
      "book_rules.md": ("canon", 10, "硬规则", "人物、能力、世界和叙事边界。", false),
      "story_bible.md": ("canon", 20, "故事圣经", "世界观、力量体系与长期一致性依据。", false),
      "outline/story_frame.md": ("canon", 30, "故事基石", "核心冲突和终局方向。", false),
      "outline/volume_map.md": ("canon", 40, "分卷地图", "每卷范围、目标与回收安排。", false),
      "style_guide.md": ("canon", 50, "文风指南", "叙事视角、语言密度与表达边界。", false),
      "craft_rules.md": ("canon", 55, "写法约束", "场景纪律、信息节奏与禁止写法；系统写法内核始终额外生效。", false),
      "current_state.md": ("runtime", 10, "当前状态", "角色位置、伤势、资源与下一步目标。", false),
      "pending_hooks.md": ("runtime", 20, "伏笔池", "伏笔进展与回收方向。", false),
      "chapter_summaries.md": ("runtime", 30, "章节摘要", "已写章节的关键变化。", false),
      "particle_ledger.md": ("runtime", 40, "资源账本", "资源、证物、伤势与消耗。", false),
      "object_ledger.md": ("runtime", 45, "持久对象账本", "跨章物品的稳定身份与状态。", true),
      "character_matrix.md": ("runtime", 50, "人物关系", "人物关系、立场与知情范围。", false),
      "emotional_arcs.md": ("runtime", 60, "情感弧线", "人物关系和情绪节奏。", false),
      "subplot_board.md": ("runtime", 70, "支线进度", "支线当前阶段和回收安排。", false),
      "audit_drift.md": ("runtime", 80, "审计纠偏", "最近审核对后续章节的提醒。", true),
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
    guard normalized.hasSuffix(".md"), !["runtime", "snapshots", "state"].contains(first) else {
      throw InkOSCoreError("设定路径无效", statusCode: 400)
    }
    let url = story.appendingPathComponent(normalized).standardizedFileURL
    guard url.path.hasPrefix(story.path + "/") else { throw InkOSCoreError("设定路径无效", statusCode: 400) }
    return url
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
    try fileManager.copyItem(at: story, to: backup)
    return backup
  }

  @discardableResult
  private func restoreSettingsBackup(bookID: String, backupURL: URL) throws -> Int {
    let story = try existingBookURL(bookID).appendingPathComponent("story", isDirectory: true)
    let temporary = story.deletingLastPathComponent().appendingPathComponent(".story-restore-\(UUID().uuidString)")
    try fileManager.copyItem(at: backupURL, to: temporary)
    if fileManager.fileExists(atPath: story.path) { try fileManager.removeItem(at: story) }
    try fileManager.moveItem(at: temporary, to: story)
    return try markdownFiles(in: story).count
  }

  private func relativePath(_ url: URL, under root: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
  }

  private func urlStem(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }
}
