import Foundation

private struct FanqieSession: Codable, Sendable {
  var cookies: [FanqieCookie]
  var authorName: String?
  var savedAt: String
  var verifiedAt: String
}

private struct FanqieVolume: Sendable {
  let id: String
  let name: String
}

extension InkOSCore {
  private var fanqieDirectoryURL: URL {
    dataURL.appendingPathComponent("fanqie", isDirectory: true)
  }

  private var fanqieSessionURL: URL {
    fanqieDirectoryURL.appendingPathComponent("session.json")
  }

  func saveFanqieCookies(_ cookies: [FanqieCookie]) async throws -> FanqieAccount {
    invalidateFanqieCSRFToken()
    let usable = cookies.filter { cookie in
      cookie.domain.lowercased().contains("fanqienovel.com")
        && !cookie.name.isEmpty
        && (cookie.expiresAt == nil || cookie.expiresAt! > Date())
    }
    guard !usable.isEmpty else {
      throw InkOSCoreError("登录页没有返回番茄会话，请在登录完成后重试", statusCode: 401)
    }

    let accountObject = try await fanqieAccountObject(cookies: usable)
    let authorName = fanqieString(
      accountObject,
      keys: ["author_name", "name", "pen_name", "toutiao_name"]
    )
    let now = isoTimestamp()
    let session = FanqieSession(
      cookies: usable,
      authorName: authorName,
      savedAt: now,
      verifiedAt: now
    )
    try fileManager.createDirectory(at: fanqieDirectoryURL, withIntermediateDirectories: true)
    try atomicWrite(encoder.encode(session), to: fanqieSessionURL)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fanqieSessionURL.path)
    recordDebug(scope: "fanqie", message: "fanqie.login.completed", data: [
      "authorName": authorName ?? "",
      "cookieCount": usable.count,
      "sessionFile": fanqieSessionURL.path,
    ])
    return makeFanqieAccount(session: session)
  }

  func fetchFanqieLoginState() async throws -> FanqieLoginState {
    guard fileManager.fileExists(atPath: fanqieSessionURL.path) else {
      recordDebug(scope: "fanqie", message: "fanqie.login.required")
      return FanqieLoginState(
        loggedIn: false,
        needRelogin: true,
        reason: "请在应用内登录番茄作者端"
      )
    }
    do {
      _ = try await fetchFanqieAccount()
      return FanqieLoginState(loggedIn: true, needRelogin: false, reason: nil)
    } catch let error as InkOSCoreError where error.statusCode == 401 {
      try? fileManager.removeItem(at: fanqieSessionURL)
      recordDebug(
        scope: "fanqie",
        message: "fanqie.login.expired",
        level: "warning"
      )
      return FanqieLoginState(
        loggedIn: false,
        needRelogin: true,
        reason: error.message
      )
    }
  }

  func fetchFanqieAccount() async throws -> FanqieAccount {
    var session = try loadFanqieSession()
    let object = try await fanqieAccountObject(cookies: session.cookies)
    session.authorName = fanqieString(
      object,
      keys: ["author_name", "name", "pen_name", "toutiao_name"]
    ) ?? session.authorName
    session.verifiedAt = isoTimestamp()
    try atomicWrite(encoder.encode(session), to: fanqieSessionURL)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fanqieSessionURL.path)
    return makeFanqieAccount(session: session)
  }

  func fetchFanqieBooks() async throws -> FanqieBooksResponse {
    let session = try loadFanqieSession()
    var books: [FanqieBook] = []
    var page = 0
    var total = Int.max

    while books.count < total, page < 100 {
      let root = try await fanqieRequest(
        path: "/api/author/book/book_list/v0",
        method: "GET",
        parameters: [
          "page_count": "100",
          "page_index": String(page),
          "image_fmt_list": "270x480",
        ],
        cookies: session.cookies
      )
      let data = fanqieDictionary(root["data"]) ?? [:]
      let rows = fanqieArray(data["book_list"] ?? data["books"] ?? data["list"])
      total = fanqieInt(data, keys: ["total_count", "total", "count"]) ?? rows.count
      for row in rows.compactMap(fanqieDictionary) {
        guard let bookID = fanqieString(row, keys: ["book_id", "bookId", "id"]),
          !bookID.isEmpty
        else { continue }
        let bookTitle = fanqieString(row, keys: ["book_name", "title", "name"]) ?? bookID
        books.append(try decodeObject([
          "bookId": bookID,
          "title": bookTitle,
          "status": fanqieDisplayStatus(row),
          "chapterCount": fanqieInt(row, keys: ["chapter_count", "chapter_num", "item_count"]) ?? 0,
          "wordCount": fanqieNullableString(row, keys: ["word_number", "word_count", "words"]),
          "updatedAt": fanqieNullableString(row, keys: ["update_time", "updated_at", "last_publish_time"]),
        ], as: FanqieBook.self))
      }
      if rows.isEmpty { break }
      page += 1
    }

    let unique = Dictionary(grouping: books, by: \.bookId).compactMap { $0.value.first }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    recordDebug(scope: "fanqie", message: "fanqie.books.fetched", data: ["count": unique.count])
    return FanqieBooksResponse(books: unique)
  }

  func fetchFanqieChapters(bookID: String, title: String) async throws -> FanqieChaptersResponse {
    _ = title
    let session = try loadFanqieSession()
    var chapters: [FanqieChapter] = []
    var page = 0
    var total = Int.max

    while chapters.count < total, page < 200 {
      let root = try await fanqieRequest(
        path: "/api/author/chapter/chapter_list/v1",
        method: "GET",
        parameters: [
          "book_id": bookID,
          "page_count": "100",
          "page_index": String(page),
          "status": "0",
        ],
        cookies: session.cookies
      )
      let data = fanqieDictionary(root["data"]) ?? [:]
      let rows = fanqieArray(data["item_list"] ?? data["chapter_list"] ?? data["list"])
      total = fanqieInt(data, keys: ["total_count", "total", "count"]) ?? rows.count
      for (offset, row) in rows.compactMap(fanqieDictionary).enumerated() {
        guard let chapterID = fanqieString(row, keys: ["item_id", "chapter_id", "chapterId", "id"]),
          !chapterID.isEmpty
        else { continue }
        let rawTitle = fanqieString(row, keys: ["title", "chapter_name", "name"]) ?? "未命名章节"
        let number = fanqieInt(
          row,
          keys: ["chapter_index", "chapter_number", "chapter_num", "order", "serial_number"]
        ) ?? fanqieChapterNumber(from: rawTitle) ?? (page * 100 + offset + 1)
        chapters.append(try decodeObject([
          "chapterId": chapterID,
          "number": number,
          "title": fanqieChapterTitle(rawTitle),
          "status": fanqieDisplayStatus(row),
          "updatedAt": fanqieNullableString(row, keys: ["publish_time", "update_time", "updated_at"]),
          "wordCount": fanqieNullableString(row, keys: ["word_number", "word_count", "words"]),
        ], as: FanqieChapter.self))
      }
      if rows.isEmpty { break }
      page += 1
    }

    let unique = Dictionary(grouping: chapters, by: \.chapterId).compactMap { $0.value.first }
      .sorted { left, right in
        left.number == right.number ? left.chapterId < right.chapterId : left.number < right.number
      }
    recordDebug(scope: "fanqie", message: "fanqie.chapters.fetched", data: [
      "bookId": bookID, "count": unique.count,
    ])
    return FanqieChaptersResponse(chapters: unique)
  }

  func fetchFanqieChapterContent(bookID: String, chapterID: String) async throws -> FanqieChapterContent {
    let session = try loadFanqieSession()
    let root = try await fanqieRequest(
      path: "/api/author/edit_article/v0/",
      method: "GET",
      parameters: ["book_id": bookID, "item_id": chapterID],
      cookies: session.cookies
    )
    let data = fanqieDictionary(root["data"]) ?? [:]
    let rawTitle = fanqieString(data, keys: ["title"]) ?? ""
    return FanqieChapterContent(
      content: fanqiePlainText(fanqieString(data, keys: ["content"]) ?? ""),
      title: fanqieChapterTitle(rawTitle),
      chapterId: chapterID,
      number: fanqieChapterNumber(from: rawTitle)
    )
  }

  func fetchFanqieCategories(gender: Int) async throws -> [FanqieCategory] {
    let session = try loadFanqieSession()
    let root = try await fanqieRequest(
      path: "/api/author/book/category_list/v0/",
      method: "GET",
      parameters: ["gender": String(gender)],
      cookies: session.cookies
    )
    var categories: [FanqieCategory] = []
    collectFanqieCategories(root["data"], into: &categories)
    var seen = Set<String>()
    let unique = categories.filter { !$0.name.isEmpty && seen.insert($0.categoryId).inserted }
    recordDebug(scope: "fanqie", message: "fanqie.categories.fetched", data: [
      "gender": gender, "count": unique.count,
    ])
    return unique
  }

  func createFanqieBook(_ input: FanqieCreateBookInput) async throws -> FanqieMutationResponse {
    let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let abstract = input.abstract.trimmingCharacters(in: .whitespacesAndNewlines)
    let roles = input.protagonistNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !title.isEmpty else { throw InkOSCoreError("请填写作品名称", statusCode: 400) }
    guard !input.categoryIDs.isEmpty else { throw InkOSCoreError("请至少选择一个作品标签", statusCode: 400) }
    guard !roles.isEmpty else { throw InkOSCoreError("请至少填写一个主角姓名", statusCode: 400) }
    guard abstract.count >= 50 else { throw InkOSCoreError("作品简介至少填写 50 个字", statusCode: 400) }
    guard abstract.count <= 500 else { throw InkOSCoreError("作品简介不能超过 500 个字", statusCode: 400) }

    let rolesData = try JSONSerialization.data(withJSONObject: roles)
    let rolesJSON = String(data: rolesData, encoding: .utf8) ?? "[]"
    let session = try loadFanqieSession()
    let root = try await fanqieRequest(
      path: "/api/author/book/create/v0/",
      method: "POST",
      parameters: [
        "book_name": title,
        "roles": rolesJSON,
        "category": input.categoryIDs.joined(separator: ","),
        "gender": String(input.gender),
        "thumb_uri": input.coverURI?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? "novel-static/7107d91219967759d105674fa8393923",
        "abstract": abstract,
        "is_self_pic": input.coverURI?.nilIfEmpty == nil ? "0" : "1",
      ],
      cookies: session.cookies
    )
    let data = fanqieDictionary(root["data"]) ?? [:]
    let bookID = fanqieString(data, keys: ["book_id", "bookId", "id"])
    recordDebug(scope: "fanqie", message: "fanqie.book.created", data: [
      "bookId": bookID ?? "", "title": title,
    ])
    return FanqieMutationResponse(
      ok: true,
      message: "番茄作品创建成功",
      bookId: bookID,
      chapterId: nil
    )
  }

  func publishFanqieChapter(_ input: FanqieChapterTransferInput) async throws -> FanqieMutationResponse {
    guard input.remoteChapterId == nil else {
      return try await replaceFanqieChapter(input)
    }
    let local = try await fetchChapter(bookID: input.localBookId, number: input.localChapterNumber)
    let session = try loadFanqieSession()
    let draftRoot = try await fanqieRequest(
      path: "/api/author/article/new_article/v0/",
      method: "POST",
      parameters: ["book_id": input.remoteBookId, "need_reuse": "1"],
      cookies: session.cookies
    )
    let draft = fanqieDictionary(draftRoot["data"]) ?? [:]
    guard let chapterID = fanqieString(draft, keys: ["item_id", "chapter_id", "id"]),
      !chapterID.isEmpty
    else { throw InkOSCoreError("番茄没有返回新章节编号", statusCode: 502) }
    let volume = try await fanqieVolume(bookID: input.remoteBookId, preferredData: draft, cookies: session.cookies)
    return try await submitFanqieChapter(
      local: local,
      remoteBookID: input.remoteBookId,
      remoteChapterID: chapterID,
      volume: volume,
      cookies: session.cookies,
      event: "fanqie.chapter.uploaded",
      message: "章节已提交番茄审核"
    )
  }

  func replaceFanqieChapter(_ input: FanqieChapterTransferInput) async throws -> FanqieMutationResponse {
    guard let remoteChapterID = input.remoteChapterId, !remoteChapterID.isEmpty else {
      throw InkOSCoreError("请先选择要替换的番茄章节", statusCode: 400)
    }
    let local = try await fetchChapter(bookID: input.localBookId, number: input.localChapterNumber)
    let session = try loadFanqieSession()
    let editRoot = try await fanqieRequest(
      path: "/api/author/edit_article/v0/",
      method: "GET",
      parameters: ["book_id": input.remoteBookId, "item_id": remoteChapterID],
      cookies: session.cookies
    )
    let edit = fanqieDictionary(editRoot["data"]) ?? [:]
    let volume = try await fanqieVolume(bookID: input.remoteBookId, preferredData: edit, cookies: session.cookies)
    return try await submitFanqieChapter(
      local: local,
      remoteBookID: input.remoteBookId,
      remoteChapterID: remoteChapterID,
      volume: volume,
      cookies: session.cookies,
      event: "fanqie.chapter.replaced",
      message: "替换内容已提交番茄审核"
    )
  }

  func logoutFanqie() async throws -> FanqieLogoutResponse {
    invalidateFanqieCSRFToken()
    if fileManager.fileExists(atPath: fanqieSessionURL.path) {
      try fileManager.removeItem(at: fanqieSessionURL)
    }
    recordDebug(scope: "fanqie", message: "fanqie.logout.completed")
    return FanqieLogoutResponse(ok: true, backupFile: "", message: "番茄账号已退出")
  }

  func fetchFanqieLoginURL() async throws -> FanqieLoginURLResponse {
    FanqieLoginURLResponse(
      url: "https://fanqienovel.com/main/writer/login",
      instructions: "在应用内完成番茄作者端登录，登录成功后会自动返回。"
    )
  }

  func prepareFanqieMutationSession() async throws {
    let session = try loadFanqieSession()
    _ = try await fanqieCSRFToken(
      path: "/api/author/book/create/v0/",
      cookies: session.cookies,
      forceRefresh: true
    )
  }

  private func submitFanqieChapter(
    local: ChapterDetail,
    remoteBookID: String,
    remoteChapterID: String,
    volume: FanqieVolume,
    cookies: [FanqieCookie],
    event: String,
    message: String
  ) async throws -> FanqieMutationResponse {
    let title = fanqiePublishTitle(number: local.number, title: local.title)
    let root = try await fanqieRequest(
      path: "/api/author/publish_article/v0/",
      method: "POST",
      parameters: [
        "item_id": remoteChapterID,
        "book_id": remoteBookID,
        "content": fanqieHTML(local.content),
        "timer_status": "0",
        "timer_time": "",
        "need_pay": "0",
        "volume_name": volume.name,
        "volume_id": volume.id,
        "title": title,
        "publish_status": "1",
        "device_platform": "pc",
        "has_chapter_ad": "false",
        "chapter_ad_types": "",
        "timer_chapter_preview": "[]",
      ],
      cookies: cookies
    )
    let data = fanqieDictionary(root["data"]) ?? [:]
    let resultingID = fanqieString(data, keys: ["item_id", "chapter_id", "id"]) ?? remoteChapterID
    recordDebug(scope: "fanqie", message: event, data: [
      "bookId": remoteBookID,
      "chapterId": resultingID,
      "localChapterNumber": local.number,
      "wordCount": local.wordCount,
    ])
    return FanqieMutationResponse(
      ok: true,
      message: message,
      bookId: remoteBookID,
      chapterId: resultingID
    )
  }

  private func fanqieVolume(
    bookID: String,
    preferredData: [String: Any],
    cookies: [FanqieCookie]
  ) async throws -> FanqieVolume {
    if let directID = fanqieString(preferredData, keys: ["volume_id"]), !directID.isEmpty {
      let name = fanqieString(preferredData, keys: ["volume_name"]) ?? "第一卷"
      return FanqieVolume(id: directID, name: name)
    }
    let preferredRows = fanqieArray(preferredData["volume_data"] ?? preferredData["volume_list"])
    if let row = preferredRows.compactMap(fanqieDictionary).last,
      let id = fanqieString(row, keys: ["volume_id", "volumeId", "id"]), !id.isEmpty
    {
      return FanqieVolume(
        id: id,
        name: fanqieString(row, keys: ["volume_name", "volumeName", "name"]) ?? "第一卷"
      )
    }

    let root = try await fanqieRequest(
      path: "/api/author/volume/volume_list/v1",
      method: "GET",
      parameters: ["book_id": bookID],
      cookies: cookies
    )
    let data = fanqieDictionary(root["data"]) ?? [:]
    let rows = fanqieArray(data["volume_list"] ?? data["list"])
    guard let row = rows.compactMap(fanqieDictionary).last,
      let id = fanqieString(row, keys: ["volume_id", "volumeId", "id"]), !id.isEmpty
    else { throw InkOSCoreError("番茄作品没有可用分卷", statusCode: 409) }
    return FanqieVolume(
      id: id,
      name: fanqieString(row, keys: ["volume_name", "volumeName", "name"]) ?? "第一卷"
    )
  }

  private func loadFanqieSession() throws -> FanqieSession {
    guard fileManager.fileExists(atPath: fanqieSessionURL.path) else {
      throw InkOSCoreError("番茄账号尚未登录", statusCode: 401)
    }
    do {
      let session = try decoder.decode(FanqieSession.self, from: Data(contentsOf: fanqieSessionURL))
      guard session.cookies.contains(where: {
        $0.expiresAt == nil || $0.expiresAt! > Date()
      }) else { throw InkOSCoreError("番茄登录已过期，请重新登录", statusCode: 401) }
      return session
    } catch let error as InkOSCoreError {
      throw error
    } catch {
      throw InkOSCoreError("番茄会话文件已损坏，请重新登录", statusCode: 401)
    }
  }

  private func fanqieAccountObject(cookies: [FanqieCookie]) async throws -> [String: Any] {
    let root = try await fanqieRequest(
      path: "/api/author/account/info/v0/",
      method: "GET",
      parameters: [:],
      cookies: cookies
    )
    guard let data = fanqieDictionary(root["data"]) else {
      throw InkOSCoreError("番茄账号信息为空，请重新登录", statusCode: 401)
    }
    return data
  }

  private func makeFanqieAccount(session: FanqieSession) -> FanqieAccount {
    let expiry = session.cookies.compactMap(\.expiresAt).min().map(isoTimestamp)
    return FanqieAccount(
      loggedIn: true,
      reason: nil,
      sessionId: nil,
      sessionExpires: expiry,
      authorName: session.authorName,
      stateFile: fanqieSessionURL.path,
      error: nil
    )
  }

  private func fanqieRequest(
    path: String,
    method: String,
    parameters: [String: String],
    cookies: [FanqieCookie]
  ) async throws -> [String: Any] {
    let started = Date()
    var components = URLComponents()
    components.scheme = "https"
    components.host = "fanqienovel.com"
    components.path = path
    components.queryItems = [
      URLQueryItem(name: "aid", value: "2503"),
      URLQueryItem(name: "app_name", value: "novel_author_web"),
    ]
    if method.uppercased() == "GET" {
      components.queryItems?.append(contentsOf: parameters.sorted(by: { $0.key < $1.key }).map {
        URLQueryItem(name: $0.key, value: $0.value)
      })
    }
    guard let url = components.url else { throw InkOSCoreError("番茄接口地址无效") }

    var request = URLRequest(url: url)
    request.httpMethod = method.uppercased()
    request.timeoutInterval = 60
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue("https://fanqienovel.com", forHTTPHeaderField: "Origin")
    request.setValue("https://fanqienovel.com/main/writer/", forHTTPHeaderField: "Referer")
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    let cookieHeader = fanqieCookieHeader(cookies)
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    if method.uppercased() == "POST" {
      request.setValue(
        "application/x-www-form-urlencoded;charset=UTF-8",
        forHTTPHeaderField: "Content-Type"
      )
      request.httpBody = fanqieFormBody(parameters)
      request.setValue(
        try await fanqieCSRFToken(path: path, cookies: cookies),
        forHTTPHeaderField: "x-secsdk-csrf-token"
      )
    }

    do {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.timeoutIntervalForRequest = 60
      configuration.timeoutIntervalForResource = 90
      let session = URLSession(configuration: configuration)
      defer { session.finishTasksAndInvalidate() }
      var (data, response) = try await session.data(for: request)
      var http = response as? HTTPURLResponse
      var status = http?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        recordDebug(scope: "fanqie", message: "fanqie.request.failed", level: "error", data: [
          "path": path, "method": method, "httpStatus": status,
        ])
        throw InkOSCoreError("番茄接口请求失败（HTTP \(status)）", statusCode: status)
      }

      var root = fanqieJSONDictionary(data)
      if root == nil, method.uppercased() == "POST" {
        invalidateFanqieCSRFToken()
        request.setValue(
          try await fanqieCSRFToken(path: path, cookies: cookies, forceRefresh: true),
          forHTTPHeaderField: "x-secsdk-csrf-token"
        )
        recordDebug(scope: "fanqie", message: "fanqie.request.retry", level: "warning", data: [
          "path": path,
          "method": method,
          "reason": data.isEmpty ? "empty_response" : "invalid_json",
        ])
        (data, response) = try await session.data(for: request)
        http = response as? HTTPURLResponse
        status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
          throw InkOSCoreError("番茄接口请求失败（HTTP \(status)）", statusCode: status)
        }
        root = fanqieJSONDictionary(data)
      }

      guard let root else {
        let redirectedToLogin = http?.url?.path.contains("login") == true
        recordDebug(scope: "fanqie", message: "fanqie.response.invalid", level: "error", data: [
          "path": path,
          "method": method,
          "httpStatus": status,
          "contentType": http?.value(forHTTPHeaderField: "Content-Type") ?? "",
          "bytes": data.count,
        ])
        throw InkOSCoreError(
          redirectedToLogin ? "番茄登录已过期，请重新登录" : "番茄接口返回格式异常，请重试",
          statusCode: redirectedToLogin ? 401 : 502
        )
      }
      let code = fanqieInt(root, keys: ["code"]) ?? -1
      let duration = Int(Date().timeIntervalSince(started) * 1_000)
      recordDebug(scope: "fanqie", message: "fanqie.request.completed", data: [
        "path": path,
        "method": method,
        "httpStatus": status,
        "code": code,
        "durationMs": duration,
        "logId": fanqieString(root, keys: ["log_id", "logId"]) ?? "",
      ])
      guard code == 0 else {
        let message = fanqieString(root, keys: ["message", "msg"]) ?? "番茄接口返回错误（\(code)）"
        let loginError = code == -3 || message.contains("登录")
        recordDebug(scope: "fanqie", message: "fanqie.request.rejected", level: "warning", data: [
          "path": path, "method": method, "code": code, "message": message,
        ])
        throw InkOSCoreError(message, statusCode: loginError ? 401 : 422)
      }
      return root
    } catch let error as InkOSCoreError {
      throw error
    } catch {
      recordDebug(scope: "fanqie", message: "fanqie.request.failed", level: "error", data: [
        "path": path, "method": method, "error": error.localizedDescription,
      ])
      throw InkOSCoreError("连接番茄失败：\(error.localizedDescription)", statusCode: 502)
    }
  }

  private func fanqieFormBody(_ parameters: [String: String]) -> Data {
    let body = parameters.sorted(by: { $0.key < $1.key })
      .map { "\(fanqiePercentEncode($0.key))=\(fanqiePercentEncode($0.value))" }
      .joined(separator: "&")
    return Data(body.utf8)
  }

  private func fanqiePercentEncode(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }

  private func fanqieJSONDictionary(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func fanqieCookieHeader(_ cookies: [FanqieCookie]) -> String {
    cookies
      .filter { $0.expiresAt == nil || $0.expiresAt! > Date() }
      .sorted { $0.name < $1.name }
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")
  }

  private func fanqieCSRFToken(
    path: String,
    cookies: [FanqieCookie],
    forceRefresh: Bool = false
  ) async throws -> String {
    if !forceRefresh,
      let token = fanqieCSRFTokenValue,
      let expiresAt = fanqieCSRFTokenExpiresAt,
      expiresAt > Date().addingTimeInterval(30)
    {
      return token
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "fanqienovel.com"
    components.path = path
    guard let url = components.url else {
      throw InkOSCoreError("番茄安全令牌地址无效", statusCode: 500)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 15
    request.setValue("1", forHTTPHeaderField: "x-secsdk-csrf-request")
    request.setValue("1.2.22", forHTTPHeaderField: "x-secsdk-csrf-version")
    request.setValue(fanqieCookieHeader(cookies), forHTTPHeaderField: "Cookie")
    request.setValue("https://fanqienovel.com", forHTTPHeaderField: "Origin")
    request.setValue("https://fanqienovel.com/main/writer/", forHTTPHeaderField: "Referer")
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InkOSCoreError("番茄安全令牌响应异常", statusCode: 502)
    }
    guard http.statusCode == 200 else {
      throw InkOSCoreError(
        "番茄安全令牌请求失败（HTTP \(http.statusCode)）",
        statusCode: http.statusCode
      )
    }
    guard let header = http.value(forHTTPHeaderField: "x-ware-csrf-token") else {
      throw InkOSCoreError("番茄安全令牌为空，请重新登录", statusCode: 401)
    }
    let fields = header.components(separatedBy: ",")
    guard fields.count >= 2, fields[0] == "0", !fields[1].isEmpty else {
      throw InkOSCoreError("番茄安全令牌校验失败，请重新登录", statusCode: 401)
    }

    let maxAgeMilliseconds = fields.count > 2 ? (Double(fields[2]) ?? 86_400_000) : 86_400_000
    fanqieCSRFTokenValue = fields[1]
    fanqieCSRFTokenExpiresAt = Date().addingTimeInterval(max(60, maxAgeMilliseconds / 1_000))
    recordDebug(scope: "fanqie", message: "fanqie.csrf.refreshed", data: [
      "path": path,
      "maxAgeMs": Int(maxAgeMilliseconds),
    ])
    return fields[1]
  }

  private func invalidateFanqieCSRFToken() {
    fanqieCSRFTokenValue = nil
    fanqieCSRFTokenExpiresAt = nil
  }

  private func fanqieDictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private func fanqieArray(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
  }

  private func fanqieString(_ object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = object[key] as? String, !value.isEmpty { return value }
      if let value = object[key] as? NSNumber { return value.stringValue }
    }
    return nil
  }

  private func fanqieInt(_ object: [String: Any], keys: [String]) -> Int? {
    for key in keys {
      if let value = object[key] as? Int { return value }
      if let value = object[key] as? NSNumber { return value.intValue }
      if let value = object[key] as? String, let number = Int(value) { return number }
    }
    return nil
  }

  private func fanqieNullableString(_ object: [String: Any], keys: [String]) -> Any {
    fanqieString(object, keys: keys) ?? NSNull()
  }

  private func fanqieDisplayStatus(_ object: [String: Any]) -> String {
    if let text = fanqieString(object, keys: ["status_name", "display_status_name", "status_text"]) {
      return text
    }
    guard let status = fanqieInt(object, keys: ["display_status", "article_status", "status"]) else {
      return "未知"
    }
    return "状态 \(status)"
  }

  private func fanqieChapterNumber(from title: String) -> Int? {
    guard let expression = try? NSRegularExpression(pattern: #"第\s*(\d+)\s*章"#),
      let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
      let range = Range(match.range(at: 1), in: title)
    else { return nil }
    return Int(title[range])
  }

  private func fanqieChapterTitle(_ title: String) -> String {
    title.replacingOccurrences(
      of: #"^\s*第\s*\d+\s*章\s*"#,
      with: "",
      options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func fanqiePublishTitle(number: Int, title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if fanqieChapterNumber(from: trimmed) != nil { return trimmed }
    return "第\(number)章 \(trimmed.isEmpty ? "未命名" : trimmed)"
  }

  private func fanqieHTML(_ content: String) -> String {
    var lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
      lines.removeFirst()
    }
    var paragraphs: [String] = []
    var current: [String] = []
    func flush() {
      guard !current.isEmpty else { return }
      paragraphs.append("<p>\(current.map(fanqieEscapeHTML).joined(separator: "<br>"))</p>")
      current.removeAll(keepingCapacity: true)
    }
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { flush() } else { current.append(trimmed) }
    }
    flush()
    return paragraphs.joined()
  }

  private func fanqieEscapeHTML(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private func fanqiePlainText(_ html: String) -> String {
    var value = html
      .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"(?i)</p>"#, with: "\n\n", options: .regularExpression)
      .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    let entities = [
      "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
    ]
    for (entity, replacement) in entities {
      value = value.replacingOccurrences(of: entity, with: replacement)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func collectFanqieCategories(_ value: Any?, into categories: inout [FanqieCategory]) {
    if let object = fanqieDictionary(value) {
      if let id = fanqieString(object, keys: ["category_id", "categoryId", "id"]),
        let name = fanqieString(object, keys: ["name", "category_name", "title"])
      {
        categories.append(FanqieCategory(
          categoryId: id,
          name: name,
          group: fanqieString(object, keys: ["label", "group", "type_name"]) ?? "其他"
        ))
      }
      for child in object.values { collectFanqieCategories(child, into: &categories) }
    } else if let values = value as? [Any] {
      for child in values { collectFanqieCategories(child, into: &categories) }
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
