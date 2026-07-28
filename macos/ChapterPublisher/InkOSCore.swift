import Foundation
import Darwin

struct InkOSCoreError: LocalizedError, Sendable {
  let message: String
  let statusCode: Int

  init(_ message: String, statusCode: Int = 500) {
    self.message = message
    self.statusCode = statusCode
  }

  var errorDescription: String? { message }
}

/// Native InkOS runtime owned by the macOS application. All calls are regular
/// Swift functions; no local HTTP server, port, subprocess, or Node runtime is
/// involved in the application path.
actor InkOSCore {
  static let shared = InkOSCore()

  let rootURL: URL
  let dataURL: URL
  let booksURL: URL
  let stateURL: URL
  let configURL: URL
  let debugDirectoryURL: URL
  let debugEventsURL: URL
  let settingsBackupsURL: URL

  var generationJobs: [String: GenerationJob] = [:]
  var creationJobs: [String: CreationJob] = [:]
  var fanqieCSRFTokenValue: String?
  var fanqieCSRFTokenExpiresAt: Date?

  let fileManager = FileManager.default
  let encoder: JSONEncoder
  let decoder: JSONDecoder

  init(rootURL: URL? = nil) {
    let root = rootURL ?? Self.resolveWorkspaceRoot()
    if rootURL == nil { Self.migrateLegacyWorkspaceIfNeeded(to: root) }
    self.rootURL = root
    dataURL = root.appendingPathComponent("data", isDirectory: true)
    booksURL = root.appendingPathComponent("book/books", isDirectory: true)
    stateURL = root.appendingPathComponent("data/state.json")
    configURL = root.appendingPathComponent("data/inkos-config.json")
    debugDirectoryURL = root.appendingPathComponent("data/debug", isDirectory: true)
    debugEventsURL = root.appendingPathComponent("data/debug/events.jsonl")
    settingsBackupsURL = root.appendingPathComponent("data/settings-backups", isDirectory: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    self.encoder = encoder
    decoder = JSONDecoder()

    try? fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: booksURL, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: debugDirectoryURL, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: settingsBackupsURL, withIntermediateDirectories: true)
  }

  // MARK: - Books

  func fetchBooks() async throws -> [BookSummary] {
    let state = try loadState()
    let registered = (state["books"] as? [String: Any]) ?? [:]
    var ids = Set(registered.keys)
    for url in try directoryContents(booksURL, directoriesOnly: true) {
      ids.insert(url.lastPathComponent)
    }

    return try ids.compactMap { id in
      guard let bookDirectory = try? safeBookURL(id) else { return nil }
      let metadata = (try? readObject(bookDirectory.appendingPathComponent("book.json"))) ?? [:]
      let stateBook = registered[id] as? [String: Any] ?? [:]
      let chapters = try readChapterRecords(bookID: id, stateBook: stateBook)
      let statusCounts = Dictionary(grouping: chapters, by: { string($0["status"], fallback: "unknown") })
        .mapValues(\.count)
      return try decodeObject([
        "id": id,
        "title": string(metadata["title"], fallback: string(stateBook["title"], fallback: id)),
        "chapterCount": chapters.count,
        "pendingReview": (statusCounts["pending_review"] ?? 0) + (statusCounts["ready-for-review"] ?? 0),
        "approved": statusCounts["approved"] ?? 0,
        "published": statusCounts["published"] ?? 0,
        "revisionRequested": (statusCounts["revision_requested"] ?? 0) + (statusCounts["revision_failed"] ?? 0),
        "rejected": statusCounts["rejected"] ?? 0,
      ], as: BookSummary.self)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  func fetchAvailableBooks() async throws -> [String] {
    try directoryContents(booksURL, directoriesOnly: true)
      .map(\.lastPathComponent)
      .filter { (try? validateBookID($0)) != nil }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  func fetchChapters(bookID: String) async throws -> ChapterListResponse {
    let bookDirectory = try existingBookURL(bookID)
    let metadata = (try? readObject(bookDirectory.appendingPathComponent("book.json"))) ?? [:]
    let stateBook = try stateBookObject(bookID: bookID)
    let records = try readChapterRecords(bookID: bookID, stateBook: stateBook)
    let plan = try? readObject(bookDirectory.appendingPathComponent("long-form-plan.json"))
    let volumes = try volumeSummaries(plan: plan, currentChapter: records.compactMap { integer($0["number"]) }.max() ?? 0)
    let summaries: [ChapterSummary] = try records.map { record in
      try decodeObject(record, as: ChapterSummary.self)
    }
    let maxNumber = summaries.map(\.number).max() ?? 0
    let currentVolume = volumes.first { volume in
      let chapter = max(1, maxNumber)
      return chapter >= volume.start && chapter <= volume.end
    }
    return ChapterListResponse(
      bookId: bookID,
      bookTitle: string(metadata["title"], fallback: string(stateBook["title"], fallback: bookID)),
      chapters: summaries,
      volumes: volumes,
      currentVolume: currentVolume,
      nextChapterNum: maxNumber + 1
    )
  }

  func fetchChapter(bookID: String, number: Int) async throws -> ChapterDetail {
    guard number > 0 else { throw InkOSCoreError("章节号无效", statusCode: 400) }
    let stateBook = try stateBookObject(bookID: bookID)
    let records = try readChapterRecords(bookID: bookID, stateBook: stateBook)
    guard var record = records.first(where: { integer($0["number"]) == number }) else {
      throw InkOSCoreError("章节不存在", statusCode: 404)
    }
    let content = try readChapterText(bookID: bookID, number: number)
    record["content"] = content
    record["wordCount"] = proseCount(content)
    record["reviewNotes"] = string(record["reviewNotes"], fallback: string(record["reviewNote"]))
    return try decodeObject(record, as: ChapterDetail.self)
  }

  func approveChapter(bookID: String, number: Int) async throws -> ChapterDetail {
    let bookDirectory = try existingBookURL(bookID)
    let indexURL = bookDirectory.appendingPathComponent("chapters/index.json")
    var index = try readArray(indexURL)
    guard let offset = index.firstIndex(where: { integer($0["number"]) == number }) else {
      throw InkOSCoreError("章节不存在", statusCode: 404)
    }
    let currentPlan = try synchronizeContinuityProjection(bookID: bookID)
    try validateChapterSequence(
      bookID: bookID,
      chapterNumber: number,
      plan: currentPlan,
      operation: "审核"
    )
    let deltaURL = bookDirectory.appendingPathComponent(
      String(format: "story/runtime/chapter-%04d.consistency.json", number)
    )
    if currentPlan.continuity.policy.requireConsistencyDelta,
      !fileManager.fileExists(atPath: deltaURL.path)
    {
      throw InkOSCoreError("本章缺少 consistencyDelta，请先重新生成或修订后再审核", statusCode: 409)
    }
    if fileManager.fileExists(atPath: deltaURL.path) {
      let delta = try chapterConsistencyDelta(bookID: bookID, chapterNumber: number)
      _ = try validateCandidateContinuity(
        bookID: bookID,
        chapterNumber: number,
        delta: delta,
        excludingChapter: number
      )
    }

    let indexSnapshot = try? Data(contentsOf: indexURL)
    let stateSnapshot = try? Data(contentsOf: stateURL)
    let planURL = bookDirectory.appendingPathComponent("long-form-plan.json")
    let planSnapshot = try? Data(contentsOf: planURL)
    let projectionURL = try continuityProjectionURL(bookID: bookID)
    let projectionSnapshot = try? Data(contentsOf: projectionURL)
    let checkpointSnapshots = try snapshotVolumeCheckpoints(bookID: bookID)
    let now = isoTimestamp()
    do {
      index[offset]["status"] = "approved"
      index[offset]["updatedAt"] = now
      try writeJSON(index, to: indexURL)
      try updateStateChapter(bookID: bookID, number: number) { chapter in
        chapter["status"] = "approved"
        chapter["updatedAt"] = now
      }
      _ = try synchronizeContinuityProjection(bookID: bookID)
    } catch {
      restoreFile(indexURL, snapshot: indexSnapshot)
      restoreFile(stateURL, snapshot: stateSnapshot)
      restoreFile(planURL, snapshot: planSnapshot)
      restoreFile(projectionURL, snapshot: projectionSnapshot)
      restoreVolumeCheckpoints(bookID: bookID, snapshots: checkpointSnapshots)
      recordDebug(scope: "continuity", message: "continuity.approval.rolled_back", level: "error", data: [
        "bookId": bookID,
        "chapterNumber": number,
        "error": error.localizedDescription,
      ])
      throw error
    }
    recordDebug(scope: "review", message: "chapter.approved", data: [
      "bookId": bookID, "chapterNumber": number,
    ])
    // Rewrite the runtime narrative state files so the next chapter reads the
    // real post-approval situation instead of the creation-time placeholder.
    if let plan = try? synchronizeContinuityProjection(bookID: bookID) {
      refreshRuntimeStateFiles(bookID: bookID, plan: plan)
    }
    return try await fetchChapter(bookID: bookID, number: number)
  }

  func importBook(id: String) async throws -> ImportBookResponse {
    let bookDirectory = try existingBookURL(id)
    let metadata = (try? readObject(bookDirectory.appendingPathComponent("book.json"))) ?? [:]
    let title = string(metadata["title"], fallback: id)
    let stateBook = try stateBookObject(bookID: id, allowMissing: true)
    let records = try readChapterRecords(bookID: id, stateBook: stateBook)
    let imported: [ImportedChapter] = records.map { record in
      let number = integer(record["number"]) ?? 0
      let content = (try? readChapterText(bookID: id, number: number)) ?? ""
      return ImportedChapter(
        number: number,
        title: string(record["title"]),
        wordCount: proseCount(content)
      )
    }
    try mutateState { state in
      var books = state["books"] as? [String: Any] ?? [:]
      var book = books[id] as? [String: Any] ?? [:]
      book["title"] = title
      book["chapters"] = records
      book["updatedAt"] = isoTimestamp()
      books[id] = book
      state["books"] = books
    }
    return ImportBookResponse(bookId: id, bookTitle: title, imported: imported)
  }

  func deleteBook(id: String) async throws -> DeleteBookResponse {
    let source = try existingBookURL(id)
    let trashRoot = dataURL.appendingPathComponent("deleted-books", isDirectory: true)
    try fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)
    let destination = trashRoot.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(id)")
    try fileManager.moveItem(at: source, to: destination)
    try mutateState { state in
      var books = state["books"] as? [String: Any] ?? [:]
      books.removeValue(forKey: id)
      state["books"] = books
    }
    recordDebug(scope: "library", message: "book.deleted", data: ["bookId": id])
    return DeleteBookResponse(deleted: id, trashedTo: destination.path)
  }

  // MARK: - Jobs and debug

  func fetchGenerationJob(bookID: String, chapterNumber: Int) async throws -> GenerationJobResponse {
    GenerationJobResponse(job: generationJobs[generationKey(bookID, chapterNumber)])
  }

  func fetchCreationJob(id: String) async throws -> CreationJob {
    guard let job = creationJobs[id] else {
      throw InkOSCoreError("创建任务不存在", statusCode: 404)
    }
    return job
  }

  func fetchWorkflowJobs() async throws -> WorkflowJobsResponse {
    WorkflowJobsResponse(
      generationJobs: generationJobs.values.sorted { ($0.startedAt ?? "") > ($1.startedAt ?? "") },
      creationJobs: creationJobs.values.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") },
      debug: try debugFileInfo()
    )
  }

  func fetchDebugEvents(limit: Int = 300) async throws -> DebugEventsResponse {
    let bounded = min(max(limit, 1), 5_000)
    let lines = ((try? String(contentsOf: debugEventsURL, encoding: .utf8)) ?? "")
      .split(separator: "\n", omittingEmptySubsequences: true)
      .suffix(bounded)
    let events = lines.compactMap { line -> DebugEvent? in
      guard let data = String(line).data(using: .utf8) else { return nil }
      return try? decoder.decode(DebugEvent.self, from: data)
    }
    return DebugEventsResponse(events: events, files: try debugFileInfo())
  }

  // MARK: - Storage helpers

  func loadState() throws -> [String: Any] {
    if !fileManager.fileExists(atPath: stateURL.path) {
      let empty: [String: Any] = ["books": [String: Any](), "fanqieMap": [String: Any]()]
      try writeJSON(empty, to: stateURL, privateFile: true)
      return empty
    }
    let state = try readObject(stateURL)
    guard state["books"] is [String: Any] else {
      throw InkOSCoreError("状态文件结构异常：缺少 books 对象", statusCode: 503)
    }
    return state
  }

  func mutateState(_ mutation: (inout [String: Any]) throws -> Void) throws {
    var state = try loadState()
    try mutation(&state)
    try writeJSON(state, to: stateURL, privateFile: true)
  }

  func stateBookObject(bookID: String, allowMissing: Bool = false) throws -> [String: Any] {
    let state = try loadState()
    let books = state["books"] as? [String: Any] ?? [:]
    if let book = books[bookID] as? [String: Any] { return book }
    if allowMissing { return [:] }
    _ = try existingBookURL(bookID)
    return [:]
  }

  func updateStateChapter(
    bookID: String,
    number: Int,
    mutation: (inout [String: Any]) -> Void
  ) throws {
    try mutateState { state in
      var books = state["books"] as? [String: Any] ?? [:]
      var book = books[bookID] as? [String: Any] ?? ["title": bookID]
      var chapters = book["chapters"] as? [[String: Any]] ?? []
      if let index = chapters.firstIndex(where: { integer($0["number"]) == number }) {
        mutation(&chapters[index])
      } else {
        var chapter: [String: Any] = ["number": number]
        mutation(&chapter)
        chapters.append(chapter)
      }
      chapters.sort { (integer($0["number"]) ?? 0) < (integer($1["number"]) ?? 0) }
      book["chapters"] = chapters
      book["updatedAt"] = isoTimestamp()
      books[bookID] = book
      state["books"] = books
    }
  }

  func readChapterRecords(bookID: String, stateBook: [String: Any]) throws -> [[String: Any]] {
    let bookDirectory = try existingBookURL(bookID)
    let indexURL = bookDirectory.appendingPathComponent("chapters/index.json")
    let disk = fileManager.fileExists(atPath: indexURL.path) ? try readArray(indexURL) : []
    let stateChapters = stateBook["chapters"] as? [[String: Any]] ?? []
    var stateByNumber: [Int: [String: Any]] = [:]
    for item in stateChapters {
      guard let number = integer(item["number"]) else { continue }
      stateByNumber[number] = item
    }
    return disk.map { entry in
      let number = integer(entry["number"]) ?? 0
      let publisher = stateByNumber[number] ?? [:]
      var merged = publisher.merging(entry) { publisherValue, diskValue in
        publisherValue is NSNull ? diskValue : publisherValue
      }
      let diskStatus = string(entry["status"], fallback: "pending_review")
      let publisherStatus = string(publisher["status"], fallback: diskStatus)
      merged["status"] = publisherStatus
      merged["inkosStatus"] = diskStatus
      merged["publisherStatus"] = publisherStatus
      merged["auditIssues"] = entry["auditIssues"] as? [String] ?? []
      merged["lengthWarnings"] = entry["lengthWarnings"] as? [String] ?? []
      merged["revisionHistory"] = publisher["revisionHistory"] as? [[String: Any]] ?? []
      merged["revisionCount"] = (merged["revisionHistory"] as? [Any])?.count ?? 0
      if merged["wordCount"] == nil,
        let content = try? readChapterText(bookID: bookID, number: number)
      {
        merged["wordCount"] = proseCount(content)
      }
      return merged
    }.sorted { (integer($0["number"]) ?? 0) < (integer($1["number"]) ?? 0) }
  }

  func readChapterText(bookID: String, number: Int) throws -> String {
    let chaptersURL = try existingBookURL(bookID).appendingPathComponent("chapters", isDirectory: true)
    let prefix = String(format: "%04d_", number)
    guard let file = try directoryContents(chaptersURL).first(where: {
      $0.lastPathComponent.hasPrefix(prefix)
        && ["md", "txt"].contains($0.pathExtension.lowercased())
    }) else {
      let stateBook = try stateBookObject(bookID: bookID, allowMissing: true)
      let stateChapter = (stateBook["chapters"] as? [[String: Any]])?
        .first(where: { integer($0["number"]) == number })
      if let content = stateChapter?["content"] as? String { return content }
      throw InkOSCoreError("章节正文不存在", statusCode: 404)
    }
    return stripChapterHeading(try String(contentsOf: file, encoding: .utf8))
  }

  func writeChapter(
    bookID: String,
    number: Int,
    title: String,
    content: String,
    status: String,
    llmReview: [String: Any]? = nil
  ) throws {
    let bookDirectory = try existingBookURL(bookID)
    let chaptersURL = bookDirectory.appendingPathComponent("chapters", isDirectory: true)
    try fileManager.createDirectory(at: chaptersURL, withIntermediateDirectories: true)
    for old in try directoryContents(chaptersURL) where old.lastPathComponent.hasPrefix(String(format: "%04d_", number)) {
      try? fileManager.removeItem(at: old)
    }
    let safeTitle = sanitizeFilename(title.isEmpty ? "第\(number)章" : title)
    let chapterURL = chaptersURL.appendingPathComponent(String(format: "%04d_%@.md", number, safeTitle))
    try atomicWrite("# 第\(number)章 \(title)\n\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))\n", to: chapterURL)

    let indexURL = chaptersURL.appendingPathComponent("index.json")
    var index = fileManager.fileExists(atPath: indexURL.path) ? try readArray(indexURL) : []
    let now = isoTimestamp()
    var entry: [String: Any] = [
      "number": number,
      "title": title,
      "status": status,
      "wordCount": proseCount(content),
      "createdAt": now,
      "updatedAt": now,
      "auditIssues": [],
      "lengthWarnings": [],
    ]
    if let llmReview { entry["llmReview"] = llmReview }
    if let offset = index.firstIndex(where: { integer($0["number"]) == number }) {
      entry["createdAt"] = index[offset]["createdAt"] ?? now
      index[offset] = index[offset].merging(entry) { _, new in new }
    } else {
      index.append(entry)
    }
    index.sort { (integer($0["number"]) ?? 0) < (integer($1["number"]) ?? 0) }
    try writeJSON(index, to: indexURL)
    try updateStateChapter(bookID: bookID, number: number) { chapter in
      chapter.merge(entry) { _, new in new }
      chapter["content"] = content
      chapter["reviewNotes"] = chapter["reviewNotes"] ?? ""
      chapter["revisionHistory"] = chapter["revisionHistory"] ?? []
    }
  }

  func volumeSummaries(plan: [String: Any]?, currentChapter: Int) throws -> [VolumeSummary] {
    guard let planBody = plan?["plan"] as? [String: Any],
      let volumes = planBody["volumes"] as? [[String: Any]]
    else { return [] }
    return volumes.map { item in
      let number = integer(item["number"]) ?? 0
      let start = integer(item["startChapter"]) ?? 1
      let end = integer(item["endChapter"]) ?? start
      return VolumeSummary(
        num: number,
        title: "第\(number)卷",
        subtitle: nil,
        start: start,
        end: end,
        context: nil,
        chaptersInVolume: integer(item["chapterCount"]),
        isCurrent: currentChapter >= start && currentChapter <= end,
        progress: max(0, min(end, currentChapter) - start + 1)
      )
    }
  }

  func existingBookURL(_ bookID: String) throws -> URL {
    let url = try safeBookURL(bookID)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw InkOSCoreError("书籍不存在", statusCode: 404)
    }
    return url
  }

  func safeBookURL(_ bookID: String) throws -> URL {
    try validateBookID(bookID)
    return booksURL.appendingPathComponent(bookID, isDirectory: true)
  }

  @discardableResult
  func validateBookID(_ bookID: String) throws -> String {
    let trimmed = bookID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
      !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("\0")
    else { throw InkOSCoreError("书籍 ID 非法", statusCode: 400) }
    return trimmed
  }

  func readObject(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InkOSCoreError("数据文件结构错误：\(url.lastPathComponent)", statusCode: 503)
    }
    return object
  }

  func readArray(_ url: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: url)
    guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      throw InkOSCoreError("数据文件结构错误：\(url.lastPathComponent)", statusCode: 503)
    }
    return array
  }

  func writeJSON(_ object: Any, to url: URL, privateFile: Bool = false) throws {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw InkOSCoreError("准备写入的数据不是有效 JSON")
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try atomicWrite(data, to: url)
    if privateFile { try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
  }

  func atomicWrite(_ text: String, to url: URL) throws {
    guard let data = text.data(using: .utf8) else { throw InkOSCoreError("文本编码失败") }
    try atomicWrite(data, to: url)
  }

  func atomicWrite(_ data: Data, to url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .atomic)
    let result = temporary.path.withCString { source in
      url.path.withCString { destination in Darwin.rename(source, destination) }
    }
    guard result == 0 else {
      let code = errno
      try? fileManager.removeItem(at: temporary)
      throw InkOSCoreError("原子写入失败：\(String(cString: strerror(code)))")
    }
  }

  func decodeObject<T: Decodable>(_ object: Any, as type: T.Type) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    do { return try decoder.decode(T.self, from: data) }
    catch { throw InkOSCoreError("原生 InkOS 数据格式错误：\(error.localizedDescription)", statusCode: 503) }
  }

  func encodedObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: encoder.encode(value))
  }

  func directoryContents(_ url: URL, directoriesOnly: Bool = false) throws -> [URL] {
    guard fileManager.fileExists(atPath: url.path) else { return [] }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
    let entries = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    guard directoriesOnly else { return entries.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    return try entries.filter { try $0.resourceValues(forKeys: keys).isDirectory == true }
  }

  func debugFileInfo() throws -> DebugFileInfo {
    let files: [[String: Any]] = try directoryContents(debugDirectoryURL).compactMap { url in
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
        values.isRegularFile != false
      else { return nil }
      return [
        "name": url.lastPathComponent,
        "size": values.fileSize ?? 0,
        "mtime": values.contentModificationDate.map(isoTimestamp) ?? "",
      ]
    }
    return try decodeObject([
      "dir": debugDirectoryURL.path,
      "eventsFile": debugEventsURL.path,
      "files": files,
    ], as: DebugFileInfo.self)
  }

  func recordDebug(scope: String, message: String, level: String = "info", data: [String: Any] = [:]) {
    let event: [String: Any] = [
      "ts": isoTimestamp(), "level": level, "scope": scope, "message": message, "data": data,
    ]
    guard let payload = try? JSONSerialization.data(withJSONObject: event),
      var line = String(data: payload, encoding: .utf8)
    else { return }
    line.append("\n")
    if !fileManager.fileExists(atPath: debugEventsURL.path) {
      try? atomicWrite(line, to: debugEventsURL)
    } else if let handle = try? FileHandle(forWritingTo: debugEventsURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    }
  }

  func generationKey(_ bookID: String, _ chapterNumber: Int) -> String {
    "\(bookID)#\(chapterNumber)"
  }

  func makeGenerationJob(
    bookID: String,
    chapterNumber: Int,
    title: String? = nil,
    phase: String,
    message: String,
    startedAt: String,
    finishedAt: String? = nil,
    error: String? = nil,
    liveText: String? = nil,
    liveTextTruncated: Bool = false
  ) throws -> GenerationJob {
    var object: [String: Any] = [
      "bookId": bookID,
      "chapterNum": chapterNumber,
      "phase": phase,
      "message": message,
      "currentStage": phase,
      "startedAt": startedAt,
      "updatedAt": isoTimestamp(),
      "progress": [],
    ]
    if let title { object["title"] = title }
    if let finishedAt { object["finishedAt"] = finishedAt }
    if let error { object["error"] = error }
    if let liveText {
      object["liveText"] = liveText
      object["liveTextTruncated"] = liveTextTruncated
      object["liveTextUpdatedAt"] = isoTimestamp()
    }
    return try decodeObject(object, as: GenerationJob.self)
  }

  static func resolveWorkspaceRoot() -> URL {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    var candidates = [environment["MACINKOSTOMO_WORKSPACE"]]
#if DEBUG
    candidates.append(environment["CHAPTER_PUBLISHER_ROOT"])
    candidates.append(Bundle.main.object(forInfoDictionaryKey: "ChapterPublisherRoot") as? String)
    candidates.append(fileManager.currentDirectoryPath)
#endif
    let normalizedCandidates = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.contains("$(") }
    for candidate in normalizedCandidates {
      let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
      if fileManager.fileExists(atPath: url.appendingPathComponent("book").path) { return url }
    }
    let support = try? fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return (support ?? fileManager.homeDirectoryForCurrentUser)
      .appendingPathComponent("MacInkostomo", isDirectory: true)
  }

  static func migrateLegacyWorkspaceIfNeeded(to destination: URL) {
    let fileManager = FileManager.default
    let destinationBooks = destination.appendingPathComponent("book/books", isDirectory: true)
    if let entries = try? fileManager.contentsOfDirectory(atPath: destinationBooks.path), !entries.isEmpty {
      return
    }
    let saved = UserDefaults.standard.string(forKey: "MacInkostomoRepositoryRoot")
    let known = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Desktop/openclaw-workspace/chapter-publisher", isDirectory: true).path
    let sources = [saved, known].compactMap { $0 }.map {
      URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
    guard let source = sources.first(where: {
      $0 != destination && fileManager.fileExists(atPath: $0.appendingPathComponent("book/books").path)
    }) else { return }
    try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for component in ["book", "data"] {
      let from = source.appendingPathComponent(component, isDirectory: true)
      let to = destination.appendingPathComponent(component, isDirectory: true)
      guard fileManager.fileExists(atPath: from.path) else { continue }
      if !fileManager.fileExists(atPath: to.path) {
        try? fileManager.copyItem(at: from, to: to)
        continue
      }
      guard let entries = try? fileManager.contentsOfDirectory(
        at: from,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      ) else { continue }
      for entry in entries {
        let target = to.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
        if !fileManager.fileExists(atPath: target.path) {
          try? fileManager.copyItem(at: entry, to: target)
        }
      }
    }
  }
}

func integer(_ value: Any?) -> Int? {
  if let value = value as? Int { return value }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) }
  return nil
}

func string(_ value: Any?, fallback: String = "") -> String {
  if let value = value as? String { return value }
  if let value, !(value is NSNull) { return String(describing: value) }
  return fallback
}

func isoTimestamp(_ date: Date = Date()) -> String {
  ISO8601DateFormatter().string(from: date)
}

func proseCount(_ text: String) -> Int {
  text.unicodeScalars.reduce(into: 0) { count, scalar in
    if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
  }
}

func stripChapterHeading(_ text: String) -> String {
  var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
  if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("# 第") {
    lines.removeFirst()
    while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeFirst() }
  }
  return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func sanitizeFilename(_ value: String) -> String {
  let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
  let components = value.components(separatedBy: invalid)
  let result = components.filter { !$0.isEmpty }.joined(separator: "-")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return String((result.isEmpty ? "untitled" : result).prefix(120))
}
