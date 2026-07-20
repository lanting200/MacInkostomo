import Foundation

enum APIError: LocalizedError, Equatable, Sendable {
  case invalidPath(String)
  case transport(String)
  case timedOut
  case invalidResponse
  case http(status: Int, message: String, details: [String: JSONValue])
  case decoding(String)
  case encoding(String)

  var errorDescription: String? {
    switch self {
    case .invalidPath(let path):
      return "本地接口路径无效：\(path)"
    case .transport(let message):
      return "本地服务连接失败：\(message)"
    case .timedOut:
      return "本地服务请求超时"
    case .invalidResponse:
      return "本地服务返回了无效响应"
    case .http(let status, let message, _):
      return message.isEmpty ? "本地服务请求失败（HTTP \(status)）" : message
    case .decoding(let message):
      return "本地服务数据格式不匹配：\(message)"
    case .encoding(let message):
      return "请求数据编码失败：\(message)"
    }
  }

  var statusCode: Int? {
    guard case .http(let status, _, _) = self else { return nil }
    return status
  }

  var details: [String: JSONValue] {
    guard case .http(_, _, let details) = self else { return [:] }
    return details
  }
}

/// HTTP client for the loopback Chapter Publisher service. The endpoint is a
/// compile-time constant: callers can inject a URLSession for tests, but never
/// a host or base URL.
final class APIClient: @unchecked Sendable {
  static let shared = APIClient()

  static let defaultTimeout: TimeInterval = 30
  static let longRequestTimeout: TimeInterval = 60
  // Fanqie's Playwright worker has a 600-second server-side ceiling. Keep the
  // client slightly above it so callers receive the server's structured error.
  static let fanqieTimeout: TimeInterval = 620

  private static let scheme = "http"
  private static let host = "127.0.0.1"
  private static let port = 3456
  private static let apiRoot = "/api"

  private let session: URLSession

  init(session: URLSession = APIClient.makeSession()) {
    self.session = session
  }

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = defaultTimeout
    configuration.timeoutIntervalForResource = fanqieTimeout
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = ["Accept": "application/json"]
    return URLSession(configuration: configuration)
  }

  static func path(_ segments: String...) -> String {
    path(segments)
  }

  static func path(_ segments: [String]) -> String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%\\"))
    return "/"
      + segments.map { segment in
        segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
      }.joined(separator: "/")
  }

  func get<Response: Decodable>(
    _ path: String,
    query: [URLQueryItem] = [],
    timeout: TimeInterval = APIClient.defaultTimeout
  ) async throws -> Response {
    try await request(method: "GET", path: path, query: query, timeout: timeout, body: nil)
  }

  func getText(
    _ path: String,
    query: [URLQueryItem] = [],
    timeout: TimeInterval = APIClient.defaultTimeout
  ) async throws -> String {
    let data = try await requestData(
      method: "GET", path: path, query: query, timeout: timeout, body: nil)
    guard let text = String(data: data, encoding: .utf8) else {
      throw APIError.decoding("响应不是 UTF-8 文本")
    }
    return text
  }

  func post<Body: Encodable, Response: Decodable>(
    _ path: String,
    body: Body,
    query: [URLQueryItem] = [],
    timeout: TimeInterval = APIClient.defaultTimeout
  ) async throws -> Response {
    try await request(
      method: "POST", path: path, query: query, timeout: timeout, body: encode(body))
  }

  func patch<Body: Encodable, Response: Decodable>(
    _ path: String,
    body: Body,
    query: [URLQueryItem] = [],
    timeout: TimeInterval = APIClient.defaultTimeout
  ) async throws -> Response {
    try await request(
      method: "PATCH", path: path, query: query, timeout: timeout, body: encode(body))
  }

  func delete<Response: Decodable>(
    _ path: String,
    query: [URLQueryItem] = [],
    timeout: TimeInterval = APIClient.defaultTimeout
  ) async throws -> Response {
    try await request(method: "DELETE", path: path, query: query, timeout: timeout, body: nil)
  }

  func delete<Body: Encodable, Response: Decodable>(
    _ path: String,
    body: Body,
    query: [URLQueryItem] = [],
    timeout: TimeInterval = APIClient.defaultTimeout
  ) async throws -> Response {
    try await request(
      method: "DELETE", path: path, query: query, timeout: timeout, body: encode(body))
  }

  // MARK: Books and chapters

  func fetchBooks() async throws -> [BookSummary] {
    try await get("/books")
  }

  func fetchAvailableBooks() async throws -> [String] {
    try await get("/books/available")
  }

  func fetchChapters(bookID: String) async throws -> ChapterListResponse {
    try await get(Self.path("books", bookID, "chapters"))
  }

  func fetchChapter(bookID: String, number: Int) async throws -> ChapterDetail {
    try await get(Self.path("books", bookID, "chapters", String(number)))
  }

  func approveChapter(bookID: String, number: Int) async throws -> ChapterDetail {
    try await patch(
      Self.path("books", bookID, "chapters", String(number)),
      body: ApproveChapterRequest(),
      timeout: Self.longRequestTimeout
    )
  }

  func reviseChapter(
    bookID: String,
    number: Int,
    note: String,
    mode: String
  ) async throws -> ProcessingResponse {
    try await post(
      Self.path("books", bookID, "chapters", String(number), "revise"),
      body: RevisionRequest(revisionNote: note, revisionMode: mode),
      timeout: Self.longRequestTimeout
    )
  }

  func generateChapter(bookID: String, guidance: String?) async throws -> ProcessingResponse {
    try await post(
      Self.path("books", bookID, "generate"),
      body: GenerationRequest(guidance: guidance),
      timeout: Self.longRequestTimeout
    )
  }

  func fetchGenerationJob(bookID: String, chapterNumber: Int) async throws -> GenerationJobResponse
  {
    try await get(Self.path("books", bookID, "generation", String(chapterNumber)))
  }

  func importBook(id: String) async throws -> ImportBookResponse {
    try await post(
      "/books/import", body: ImportBookRequest(bookId: id), timeout: Self.longRequestTimeout)
  }

  func createBook(_ input: CreateBookRequest) async throws -> CreateBookResponse {
    try await post("/books/create", body: input, timeout: Self.longRequestTimeout)
  }

  func assistCreateBook(requirements: String) async throws -> CreateBookAssistResponse {
    try await post(
      "/books/create/assist",
      body: CreateBookAssistRequest(requirements: requirements),
      timeout: Self.fanqieTimeout
    )
  }

  func fetchCreationJob(id: String) async throws -> CreationJob {
    try await get(Self.path("books", "create", id))
  }

  func deleteBook(id: String) async throws -> DeleteBookResponse {
    try await delete(Self.path("books", id), timeout: Self.longRequestTimeout)
  }

  // MARK: Jobs and debug

  func fetchWorkflowJobs() async throws -> WorkflowJobsResponse {
    try await get("/debug/jobs")
  }

  func fetchDebugEvents(limit: Int = 300) async throws -> DebugEventsResponse {
    try await get("/debug/events", query: [URLQueryItem(name: "limit", value: String(limit))])
  }

  // MARK: InkOS configuration

  func fetchInkOSConfig() async throws -> InkOSConfig {
    try await get("/inkos/config")
  }

  func updateInkOSConfig(_ input: InkOSConfigUpdate) async throws -> InkOSConfigApplyResponse {
    try await post("/inkos/config", body: input, timeout: Self.longRequestTimeout)
  }

  func fetchModels(_ endpoint: ModelEndpointRequest) async throws -> ModelCatalogResponse {
    try await post("/inkos/models/list", body: endpoint, timeout: Self.longRequestTimeout)
  }

  func testModel(_ input: ModelTestRequest) async throws -> ModelTestResponse {
    try await post("/inkos/models/test", body: input, timeout: Self.longRequestTimeout)
  }

  // MARK: Book settings

  func fetchBookSettings(bookID: String) async throws -> BookSettingsResponse {
    try await get(Self.path("books", bookID, "settings"))
  }

  func fetchBookSetting(bookID: String, path: String) async throws -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    return try await getText(Self.path(["books", bookID, "settings"] + components))
  }

  func saveBookSetting(bookID: String, path: String, content: String) async throws
    -> BookSettingSaveResponse
  {
    try await post(
      Self.path("books", bookID, "settings", "safe-edit"),
      body: BookSettingSaveRequest(file: path, content: content),
      timeout: Self.longRequestTimeout
    )
  }

  func fetchBookSettingsBackups(bookID: String) async throws -> BookSettingsBackupsResponse {
    try await get(Self.path("books", bookID, "settings", "backups"))
  }

  func restoreBookSettings(bookID: String, backupID: String) async throws
    -> BookSettingsRestoreResponse
  {
    try await post(
      Self.path("books", bookID, "settings", "restore"),
      body: BookSettingsRestoreRequest(backupId: backupID),
      timeout: Self.longRequestTimeout
    )
  }

  // MARK: Fanqie

  func fetchFanqieLoginState() async throws -> FanqieLoginState {
    try await get("/fanqie/login-state")
  }

  func fetchFanqieAccount() async throws -> FanqieAccount {
    try await get("/fanqie/account", timeout: Self.fanqieTimeout)
  }

  func fetchFanqieBooks() async throws -> FanqieBooksResponse {
    try await get("/fanqie/books", timeout: Self.fanqieTimeout)
  }

  func fetchFanqieChapters(bookID: String, title: String) async throws -> FanqieChaptersResponse {
    try await get(
      Self.path("fanqie", "books", bookID, "chapters"),
      query: [URLQueryItem(name: "title", value: title)],
      timeout: Self.fanqieTimeout
    )
  }

  func fetchFanqieChapterContent(bookID: String, chapterID: String) async throws
    -> FanqieChapterContent
  {
    try await get(
      Self.path("fanqie", "books", bookID, "chapters", chapterID, "content"),
      timeout: Self.fanqieTimeout
    )
  }

  func logoutFanqie() async throws -> FanqieLogoutResponse {
    try await post("/fanqie/logout", body: EmptyRequest())
  }

  func fetchFanqieLoginURL() async throws -> FanqieLoginURLResponse {
    try await get("/fanqie/login-url")
  }

  // MARK: Transport

  private func encode<Body: Encodable>(_ body: Body) throws -> Data {
    do {
      return try JSONEncoder().encode(body)
    } catch {
      throw APIError.encoding(Self.concise(error))
    }
  }

  private func request<Response: Decodable>(
    method: String,
    path: String,
    query: [URLQueryItem],
    timeout: TimeInterval,
    body: Data?
  ) async throws -> Response {
    let data = try await requestData(
      method: method, path: path, query: query, timeout: timeout, body: body)
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw APIError.decoding(Self.concise(error))
    }
  }

  private func requestData(
    method: String,
    path: String,
    query: [URLQueryItem],
    timeout: TimeInterval,
    body: Data?
  ) async throws -> Data {
    let url = try makeURL(path: path, query: query)
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    if let body {
      request.httpBody = body
      request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .timedOut {
      throw APIError.timedOut
    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
      throw CancellationError()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw APIError.transport(Self.concise(error))
    }

    guard let http = response as? HTTPURLResponse else {
      throw APIError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw Self.httpError(status: http.statusCode, data: data)
    }
    return data
  }

  private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
    let decodedSegments = path.split(separator: "/").map {
      String($0).removingPercentEncoding ?? String($0)
    }
    guard path.hasPrefix("/"),
      !path.contains("://"),
      !path.contains("?"),
      !path.contains("#"),
      !path.contains("\\"),
      !path.contains("\0"),
      !decodedSegments.contains("."),
      !decodedSegments.contains("..")
    else {
      throw APIError.invalidPath(path)
    }

    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = Self.host
    components.port = Self.port
    components.percentEncodedPath = Self.apiRoot + path
    if !query.isEmpty { components.queryItems = query }
    guard let url = components.url,
      url.scheme == Self.scheme,
      url.host == Self.host,
      url.port == Self.port
    else {
      throw APIError.invalidPath(path)
    }
    return url
  }

  private static func httpError(status: Int, data: Data) -> APIError {
    guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
      let text = String(data: data.prefix(500), encoding: .utf8) ?? ""
      return .http(status: status, message: text, details: [:])
    }
    let message: String
    if case .string(let value)? = object["error"] {
      message = value
    } else {
      message = "HTTP \(status)"
    }
    var details = object
    details.removeValue(forKey: "error")
    return .http(status: status, message: message, details: details)
  }

  private static func concise(_ error: Error) -> String {
    String(describing: error).replacingOccurrences(of: "\n", with: " ").prefix(500).description
  }
}
