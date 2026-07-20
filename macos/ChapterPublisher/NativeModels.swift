import Foundation

// MARK: - Shared primitives

enum WorkspaceSection: String, CaseIterable, Identifiable, Codable {
  case library
  case chapters
  case fanqie
  case settings
  case activity

  var id: String { rawValue }
}

enum ModelRole: String, CaseIterable, Identifiable, Codable {
  case chapter
  case review

  var id: String { rawValue }
}

/// A bounded representation for server fields whose schema is intentionally
/// open-ended, such as debug metadata. Secrets are never stored in this type by
/// the workspace model.
enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension KeyedDecodingContainer {
  fileprivate func lossyString(forKey key: Key, default fallback: String = "") -> String {
    if let value = try? decode(String.self, forKey: key) { return value }
    if let value = try? decode(Int.self, forKey: key) { return String(value) }
    if let value = try? decode(Double.self, forKey: key) { return String(value) }
    if let value = try? decode(Bool.self, forKey: key) { return String(value) }
    return fallback
  }

  fileprivate func lossyOptionalString(forKey key: Key) -> String? {
    guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
    let value = lossyString(forKey: key)
    return value.isEmpty ? nil : value
  }

  fileprivate func lossyInt(forKey key: Key, default fallback: Int = 0) -> Int {
    if let value = try? decode(Int.self, forKey: key) { return value }
    if let value = try? decode(Double.self, forKey: key) { return Int(value) }
    if let value = try? decode(String.self, forKey: key), let number = Double(value) {
      return Int(number)
    }
    return fallback
  }
}

// MARK: - Books and chapters

struct BookSummary: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let chapterCount: Int
  let pendingReview: Int
  let approved: Int
  let published: Int
  let revisionRequested: Int
  let rejected: Int
}

struct AvailableBook: Identifiable, Hashable, Sendable {
  let id: String
  var title: String { id }
}

struct VolumeSummary: Codable, Identifiable, Hashable, Sendable {
  let num: Int
  let title: String
  let subtitle: String?
  let start: Int
  let end: Int
  let context: String?
  let chaptersInVolume: Int?
  let isCurrent: Bool?
  let progress: Int?

  var id: Int { num }
  var displayTitle: String {
    guard let subtitle, !subtitle.isEmpty else { return title }
    return "\(title)·\(subtitle)"
  }
}

struct ReviewAttempt: Codable, Hashable, Sendable {
  let pass: Bool?
  let status: String?
  let attempt: Int?
  let model: String?
  let summary: String?
  let issues: [String]?
  let revisionGuidance: String?
  let reviewedAt: String?
  let baseUrl: String?
  let error: String?
  let latencyMs: Int?
}

struct LLMReview: Codable, Hashable, Sendable {
  let status: String
  let model: String?
  let summary: String?
  let issues: [String]?
  let revisionGuidance: String?
  let reviewedAt: String?
  let autoFixed: Bool?
  let rewriteError: String?
  let attempts: [ReviewAttempt]?

  var issueList: [String] { issues ?? [] }
  var isPassed: Bool { status == "passed" }
  var isBusy: Bool {
    ["inkos_writing", "inkos_revising", "reviewing", "fixing"].contains(status)
  }
}

struct RevisionRecord: Codable, Hashable, Sendable {
  let time: String?
  let note: String?
  let type: String?
  let oldContentLength: Int?
  let newContentLength: Int?
  let knowledgeInjected: Bool?
  let knowledgeChars: Int?
  let success: Bool?
  let reviseMode: String?
  let error: String?
}

struct InkOSReviewSync: Codable, Hashable, Sendable {
  let synced: Bool?
  let reason: String?
}

struct ChapterSummary: Codable, Identifiable, Hashable, Sendable {
  let number: Int
  let title: String
  let status: String
  let inkosStatus: String?
  let publisherStatus: String?
  let auditIssues: [String]
  let reviewNote: String?
  let wordCount: Int
  let publishedAt: String?
  let revisionCount: Int
  let updatedAt: String?
  let volume: Int?
  let volumeTitle: String?
  let llmReview: LLMReview?

  var id: Int { number }

  private enum CodingKeys: String, CodingKey {
    case number, title, status, inkosStatus, publisherStatus, auditIssues, reviewNote
    case wordCount, publishedAt, revisionCount, updatedAt, volume, volumeTitle, llmReview
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    number = try values.decode(Int.self, forKey: .number)
    title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
    status = try values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    inkosStatus = try values.decodeIfPresent(String.self, forKey: .inkosStatus)
    publisherStatus = try values.decodeIfPresent(String.self, forKey: .publisherStatus)
    auditIssues = try values.decodeIfPresent([String].self, forKey: .auditIssues) ?? []
    reviewNote = try values.decodeIfPresent(String.self, forKey: .reviewNote)
    wordCount = try values.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
    publishedAt = try values.decodeIfPresent(String.self, forKey: .publishedAt)
    revisionCount = try values.decodeIfPresent(Int.self, forKey: .revisionCount) ?? 0
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    volume = try values.decodeIfPresent(Int.self, forKey: .volume)
    volumeTitle = try values.decodeIfPresent(String.self, forKey: .volumeTitle)
    llmReview = try values.decodeIfPresent(LLMReview.self, forKey: .llmReview)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(number, forKey: .number)
    try values.encode(title, forKey: .title)
    try values.encode(status, forKey: .status)
    try values.encodeIfPresent(inkosStatus, forKey: .inkosStatus)
    try values.encodeIfPresent(publisherStatus, forKey: .publisherStatus)
    try values.encode(auditIssues, forKey: .auditIssues)
    try values.encodeIfPresent(reviewNote, forKey: .reviewNote)
    try values.encode(wordCount, forKey: .wordCount)
    try values.encodeIfPresent(publishedAt, forKey: .publishedAt)
    try values.encode(revisionCount, forKey: .revisionCount)
    try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try values.encodeIfPresent(volume, forKey: .volume)
    try values.encodeIfPresent(volumeTitle, forKey: .volumeTitle)
    try values.encodeIfPresent(llmReview, forKey: .llmReview)
  }
}

struct ChapterListResponse: Codable, Sendable {
  let bookId: String
  let bookTitle: String
  let chapters: [ChapterSummary]
  let volumes: [VolumeSummary]
  let currentVolume: VolumeSummary?
  let nextChapterNum: Int
}

struct ChapterDetail: Codable, Identifiable, Hashable, Sendable {
  let number: Int
  let title: String
  let content: String
  let status: String
  let inkosStatus: String?
  let publisherStatus: String?
  let wordCount: Int
  let auditIssues: [String]
  let lengthWarnings: [String]
  let reviewNote: String?
  let reviewNotes: String?
  let revisionHistory: [RevisionRecord]
  let publishedAt: String?
  let volume: Int?
  let volumeTitle: String?
  let createdAt: String?
  let updatedAt: String?
  let llmReview: LLMReview?
  let inkosReviewSync: InkOSReviewSync?

  var id: Int { number }

  private enum CodingKeys: String, CodingKey {
    case number, title, content, status, inkosStatus, publisherStatus, wordCount
    case auditIssues, lengthWarnings, reviewNote, reviewNotes, revisionHistory
    case publishedAt, volume, volumeTitle, createdAt, updatedAt, llmReview, inkosReviewSync
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    number = try values.decode(Int.self, forKey: .number)
    title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
    content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
    status = try values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    inkosStatus = try values.decodeIfPresent(String.self, forKey: .inkosStatus)
    publisherStatus = try values.decodeIfPresent(String.self, forKey: .publisherStatus)
    wordCount = try values.decodeIfPresent(Int.self, forKey: .wordCount) ?? 0
    auditIssues = try values.decodeIfPresent([String].self, forKey: .auditIssues) ?? []
    lengthWarnings = try values.decodeIfPresent([String].self, forKey: .lengthWarnings) ?? []
    reviewNote = try values.decodeIfPresent(String.self, forKey: .reviewNote)
    reviewNotes = try values.decodeIfPresent(String.self, forKey: .reviewNotes)
    revisionHistory =
      try values.decodeIfPresent([RevisionRecord].self, forKey: .revisionHistory) ?? []
    publishedAt = try values.decodeIfPresent(String.self, forKey: .publishedAt)
    volume = try values.decodeIfPresent(Int.self, forKey: .volume)
    volumeTitle = try values.decodeIfPresent(String.self, forKey: .volumeTitle)
    createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
    llmReview = try values.decodeIfPresent(LLMReview.self, forKey: .llmReview)
    inkosReviewSync = try values.decodeIfPresent(InkOSReviewSync.self, forKey: .inkosReviewSync)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(number, forKey: .number)
    try values.encode(title, forKey: .title)
    try values.encode(content, forKey: .content)
    try values.encode(status, forKey: .status)
    try values.encodeIfPresent(inkosStatus, forKey: .inkosStatus)
    try values.encodeIfPresent(publisherStatus, forKey: .publisherStatus)
    try values.encode(wordCount, forKey: .wordCount)
    try values.encode(auditIssues, forKey: .auditIssues)
    try values.encode(lengthWarnings, forKey: .lengthWarnings)
    try values.encodeIfPresent(reviewNote, forKey: .reviewNote)
    try values.encodeIfPresent(reviewNotes, forKey: .reviewNotes)
    try values.encode(revisionHistory, forKey: .revisionHistory)
    try values.encodeIfPresent(publishedAt, forKey: .publishedAt)
    try values.encodeIfPresent(volume, forKey: .volume)
    try values.encodeIfPresent(volumeTitle, forKey: .volumeTitle)
    try values.encodeIfPresent(createdAt, forKey: .createdAt)
    try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try values.encodeIfPresent(llmReview, forKey: .llmReview)
    try values.encodeIfPresent(inkosReviewSync, forKey: .inkosReviewSync)
  }
}

// MARK: - Workflow jobs and debug data

struct GenerationProgress: Codable, Identifiable, Hashable, Sendable {
  let stage: String
  let eventKey: String?
  let label: String
  let detail: String?
  let at: String?

  var id: String { "\(eventKey ?? stage)#\(at ?? label)" }
}

struct GenerationJob: Codable, Identifiable, Hashable, Sendable {
  let bookId: String
  let chapterNum: Int
  let title: String?
  let phase: String
  let message: String?
  let currentStage: String?
  let stageStartedAt: String?
  let progress: [GenerationProgress]?
  let liveText: String?
  let liveTextTruncated: Bool?
  let liveTextUpdatedAt: String?
  let reviewModel: String?
  let review: ReviewAttempt?
  let llmReview: LLMReview?
  let attempts: [ReviewAttempt]?
  let actualChapterNum: Int?
  let startedAt: String?
  let updatedAt: String?
  let finishedAt: String?
  let error: String?

  var id: String { "\(bookId)#\(chapterNum)#\(startedAt ?? "")" }
  var isActive: Bool { finishedAt == nil }
}

struct CreationJob: Codable, Identifiable, Hashable, Sendable {
  let jobId: String
  let status: String
  let title: String?
  let bookId: String?
  let args: [String]?
  let createdAt: String?
  let updatedAt: String?
  let finishedAt: String?
  let error: String?
  let stdout: String?
  let stderr: String?

  var id: String { jobId }
  var isActive: Bool { finishedAt == nil && !["success", "failed"].contains(status) }
}

struct DebugFile: Codable, Identifiable, Hashable, Sendable {
  let name: String
  let size: Int
  let mtime: String

  var id: String { name }
}

struct DebugFileInfo: Codable, Hashable, Sendable {
  let dir: String
  let eventsFile: String
  let files: [DebugFile]
}

struct DebugEvent: Codable, Identifiable, Equatable, Sendable {
  let ts: String
  let level: String
  let scope: String
  let message: String
  let data: [String: JSONValue]

  var id: String { "\(ts)#\(scope)#\(message)" }

  init(from decoder: Decoder) throws {
    var raw = try [String: JSONValue](from: decoder)
    ts =
      raw.removeValue(forKey: "ts")?.stringValue
      ?? raw.removeValue(forKey: "time")?.stringValue
      ?? ""
    level = raw.removeValue(forKey: "level")?.stringValue ?? "info"
    scope = raw.removeValue(forKey: "scope")?.stringValue ?? "debug"
    message =
      raw.removeValue(forKey: "message")?.stringValue
      ?? raw.removeValue(forKey: "event")?.stringValue
      ?? "未知事件"
    if case .object(let nested)? = raw.removeValue(forKey: "data") {
      data = nested.merging(raw) { nestedValue, _ in nestedValue }
    } else {
      data = raw
    }
  }

  func encode(to encoder: Encoder) throws {
    let payload: [String: JSONValue] = [
      "ts": .string(ts),
      "level": .string(level),
      "scope": .string(scope),
      "message": .string(message),
      "data": .object(data),
    ]
    try payload.encode(to: encoder)
  }
}

extension JSONValue {
  fileprivate var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
}

struct WorkflowJobsResponse: Codable, Sendable {
  let generationJobs: [GenerationJob]
  let creationJobs: [CreationJob]
  let debug: DebugFileInfo
}

struct GenerationJobResponse: Codable, Sendable {
  let job: GenerationJob?
}

struct DebugEventsResponse: Codable, Sendable {
  let events: [DebugEvent]
  let files: DebugFileInfo
}

// MARK: - InkOS model configuration

struct InkOSConfig: Codable, Equatable, Sendable {
  let provider: String
  let model: String
  let reviewModel: String
  let baseUrl: String
  let reviewBaseUrl: String
  let apiFormat: String
  let stream: Bool?
  let temperature: Double?
  let maxTokens: Int?
  let thinkingBudget: Int
  let source: String?
  let hasApiKey: Bool
  let apiKeyPreview: String
  let hasReviewApiKey: Bool
  let reviewApiKeyPreview: String

  /// Deliberately blank even if a future server accidentally returns a key.
  let apiKey: String
  let reviewApiKey: String

  private enum CodingKeys: String, CodingKey {
    case provider, model, reviewModel, baseUrl, reviewBaseUrl, apiFormat, stream
    case temperature, maxTokens, thinkingBudget, source, hasApiKey, apiKeyPreview
    case hasReviewApiKey, reviewApiKeyPreview, apiKey, reviewApiKey
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "openai"
    model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
    reviewModel = try values.decodeIfPresent(String.self, forKey: .reviewModel) ?? ""
    baseUrl = try values.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
    reviewBaseUrl = try values.decodeIfPresent(String.self, forKey: .reviewBaseUrl) ?? ""
    apiFormat = try values.decodeIfPresent(String.self, forKey: .apiFormat) ?? "chat"
    stream = try values.decodeIfPresent(Bool.self, forKey: .stream)
    temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
    maxTokens = try values.decodeIfPresent(Int.self, forKey: .maxTokens)
    thinkingBudget = try values.decodeIfPresent(Int.self, forKey: .thinkingBudget) ?? 0
    source = try values.decodeIfPresent(String.self, forKey: .source)
    hasApiKey = try values.decodeIfPresent(Bool.self, forKey: .hasApiKey) ?? false
    apiKeyPreview = try values.decodeIfPresent(String.self, forKey: .apiKeyPreview) ?? ""
    hasReviewApiKey = try values.decodeIfPresent(Bool.self, forKey: .hasReviewApiKey) ?? false
    reviewApiKeyPreview =
      try values.decodeIfPresent(String.self, forKey: .reviewApiKeyPreview) ?? ""
    apiKey = ""
    reviewApiKey = ""
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(provider, forKey: .provider)
    try values.encode(model, forKey: .model)
    try values.encode(reviewModel, forKey: .reviewModel)
    try values.encode(baseUrl, forKey: .baseUrl)
    try values.encode(reviewBaseUrl, forKey: .reviewBaseUrl)
    try values.encode(apiFormat, forKey: .apiFormat)
    try values.encodeIfPresent(stream, forKey: .stream)
    try values.encodeIfPresent(temperature, forKey: .temperature)
    try values.encodeIfPresent(maxTokens, forKey: .maxTokens)
    try values.encode(thinkingBudget, forKey: .thinkingBudget)
    try values.encodeIfPresent(source, forKey: .source)
    try values.encode(hasApiKey, forKey: .hasApiKey)
    try values.encode(apiKeyPreview, forKey: .apiKeyPreview)
    try values.encode(hasReviewApiKey, forKey: .hasReviewApiKey)
    try values.encode(reviewApiKeyPreview, forKey: .reviewApiKeyPreview)
    try values.encode("", forKey: .apiKey)
    try values.encode("", forKey: .reviewApiKey)
  }
}

struct InkOSConfigUpdate: Encodable, Sendable, CustomStringConvertible {
  let model: String
  let reviewModel: String
  let baseUrl: String
  let reviewBaseUrl: String
  let apiKey: String
  let reviewApiKey: String
  let stream: Bool
  let thinkingBudget: Int
  let temperature: Double?
  let maxTokens: Int?

  init(
    model: String,
    reviewModel: String,
    baseUrl: String,
    reviewBaseUrl: String = "",
    apiKey: String = "",
    reviewApiKey: String = "",
    stream: Bool = false,
    thinkingBudget: Int = 0,
    temperature: Double? = nil,
    maxTokens: Int? = nil
  ) {
    self.model = model
    self.reviewModel = reviewModel
    self.baseUrl = baseUrl
    self.reviewBaseUrl = reviewBaseUrl
    self.apiKey = apiKey
    self.reviewApiKey = reviewApiKey
    self.stream = stream
    self.thinkingBudget = thinkingBudget
    self.temperature = temperature
    self.maxTokens = maxTokens
  }

  var description: String {
    "InkOSConfigUpdate(model: \(model), reviewModel: \(reviewModel), credentials: redacted)"
  }
}

struct InkOSConfigApplyResponse: Codable, Sendable {
  let ok: Bool
  let applied: Int
  let fields: [String]
  let errors: [String]
}

struct ModelEndpointRequest: Encodable, Sendable, CustomStringConvertible {
  let role: ModelRole
  let baseUrl: String?
  let apiKey: String

  var description: String { "ModelEndpointRequest(role: \(role.rawValue), credentials: redacted)" }

  enum CodingKeys: String, CodingKey {
    case role, baseUrl, apiKey
  }
}

struct RemoteModel: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let ownedBy: String?

  enum CodingKeys: String, CodingKey {
    case id
    case ownedBy = "ownedBy"
  }
}

struct ModelCatalogResponse: Codable, Sendable {
  let ok: Bool
  let baseUrl: String
  let models: [RemoteModel]
}

struct ModelTestRequest: Encodable, Sendable, CustomStringConvertible {
  let role: ModelRole
  let model: String
  let baseUrl: String?
  let apiKey: String

  var description: String {
    "ModelTestRequest(role: \(role.rawValue), model: \(model), credentials: redacted)"
  }
}

struct ModelTestResponse: Codable, Sendable {
  let ok: Bool
  let model: String
  let latencyMs: Int?
  let status: Int?
  let error: String?
}

// MARK: - Book settings

struct BookSettingGroup: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let order: Int
}

struct BookSettingFile: Codable, Identifiable, Hashable, Sendable {
  let path: String
  let title: String
  let description: String
  let group: String
  let groupTitle: String
  let groupOrder: Int
  let order: Int
  let managed: Bool

  var id: String { path }
}

struct BookSettingsResponse: Codable, Sendable {
  let storyDir: String
  let groups: [BookSettingGroup]
  let files: [BookSettingFile]
}

struct BookSettingSaveRequest: Encodable, Sendable {
  let file: String
  let content: String
}

struct BookSettingSaveResponse: Codable, Sendable {
  let ok: Bool
  let path: String
  let size: Int
  let backupDir: String?
  let message: String?
}

struct BookSettingsBackup: Codable, Identifiable, Hashable, Sendable {
  let backupId: String
  let timestamp: Int64
  let dir: String
  let time: String

  var id: String { backupId }
}

struct BookSettingsBackupsResponse: Codable, Sendable {
  let backups: [BookSettingsBackup]
}

struct BookSettingsRestoreRequest: Encodable, Sendable {
  let backupId: String
}

struct BookSettingsRestoreResponse: Codable, Sendable {
  let ok: Bool
  let restoredCount: Int
}

// MARK: - Fanqie read-only data

struct FanqieLoginState: Codable, Equatable, Sendable {
  let loggedIn: Bool
  let needRelogin: Bool?
  let reason: String?
}

struct FanqieAccount: Codable, Equatable, Sendable {
  let loggedIn: Bool
  let reason: String?
  let sessionId: String?
  let sessionExpires: String?
  let authorName: String?
  let stateFile: String?
  let error: String?
}

struct FanqieBook: Codable, Identifiable, Hashable, Sendable {
  let bookId: String
  let title: String
  let status: String?
  let chapterCount: Int
  let wordCount: String?
  let updatedAt: String?

  var id: String { bookId }

  private enum CodingKeys: String, CodingKey {
    case bookId, title, status, chapterCount, wordCount, updatedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    bookId = values.lossyString(forKey: .bookId)
    title = values.lossyString(forKey: .title)
    status = values.lossyOptionalString(forKey: .status)
    chapterCount = values.lossyInt(forKey: .chapterCount)
    wordCount = values.lossyOptionalString(forKey: .wordCount)
    updatedAt = values.lossyOptionalString(forKey: .updatedAt)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(bookId, forKey: .bookId)
    try values.encode(title, forKey: .title)
    try values.encodeIfPresent(status, forKey: .status)
    try values.encode(chapterCount, forKey: .chapterCount)
    try values.encodeIfPresent(wordCount, forKey: .wordCount)
    try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

struct FanqieBooksResponse: Codable, Sendable {
  let books: [FanqieBook]
}

struct FanqieChapter: Codable, Identifiable, Hashable, Sendable {
  let chapterId: String
  let number: Int
  let title: String
  let status: String
  let updatedAt: String?
  let wordCount: String?

  var id: String { chapterId }

  private enum CodingKeys: String, CodingKey {
    case chapterId, number, title, status, updatedAt, wordCount
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    chapterId = values.lossyString(forKey: .chapterId)
    number = values.lossyInt(forKey: .number)
    title = values.lossyString(forKey: .title)
    status = values.lossyString(forKey: .status, default: "未知")
    updatedAt = values.lossyOptionalString(forKey: .updatedAt)
    wordCount = values.lossyOptionalString(forKey: .wordCount)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(chapterId, forKey: .chapterId)
    try values.encode(number, forKey: .number)
    try values.encode(title, forKey: .title)
    try values.encode(status, forKey: .status)
    try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
    try values.encodeIfPresent(wordCount, forKey: .wordCount)
  }
}

struct FanqieChaptersResponse: Codable, Sendable {
  let chapters: [FanqieChapter]
}

struct FanqieChapterContent: Codable, Equatable, Sendable {
  let content: String
  let title: String?
  let chapterId: String?
  let number: Int?

  private enum CodingKeys: String, CodingKey {
    case content, title, chapterId, number
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    content = try values.decodeIfPresent(String.self, forKey: .content) ?? ""
    title = values.lossyOptionalString(forKey: .title)
    chapterId = values.lossyOptionalString(forKey: .chapterId)
    number = values.contains(.number) ? values.lossyInt(forKey: .number) : nil
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(content, forKey: .content)
    try values.encodeIfPresent(title, forKey: .title)
    try values.encodeIfPresent(chapterId, forKey: .chapterId)
    try values.encodeIfPresent(number, forKey: .number)
  }
}

struct FanqieLogoutResponse: Codable, Sendable {
  let ok: Bool
  let backupFile: String
  let message: String
}

struct FanqieLoginURLResponse: Codable, Sendable {
  let url: String
  let instructions: String
}

// MARK: - Mutation requests and responses

struct EmptyRequest: Encodable, Sendable {}

struct ApproveChapterRequest: Encodable, Sendable {
  let status = "approved"
}

struct RevisionRequest: Encodable, Sendable {
  let revisionNote: String
  let revisionMode: String
}

struct GenerationRequest: Encodable, Sendable {
  let guidance: String?
}

struct ProcessingResponse: Codable, Sendable {
  let message: String
  let status: String
}

struct ImportBookRequest: Encodable, Sendable {
  let bookId: String
}

struct ImportBookResponse: Codable, Sendable {
  let bookId: String
  let bookTitle: String
  let imported: [ImportedChapter]
}

struct ImportedChapter: Codable, Identifiable, Hashable, Sendable {
  let number: Int
  let title: String
  let wordCount: Int

  var id: Int { number }
}

struct DeleteBookResponse: Codable, Sendable {
  let deleted: String
  let trashedTo: String
}

struct CreateBookRequest: Codable, Sendable {
  var title: String
  var language: String
  var genre: String
  var platform: String
  var targetChapters: Int
  var chapterWords: Int
  var totalWords: String
  var premise: String
  var characters: String
  var worldbuilding: String
  var outline: String
  var volumePlan: String
  var pacing: String
  var style: String
  var constraints: String

  init(
    title: String = "",
    language: String = "zh",
    genre: String = "xuanhuan",
    platform: String = "tomato",
    targetChapters: Int = 200,
    chapterWords: Int = 3000,
    totalWords: String = "",
    premise: String = "",
    characters: String = "",
    worldbuilding: String = "",
    outline: String = "",
    volumePlan: String = "",
    pacing: String = "",
    style: String = "",
    constraints: String = ""
  ) {
    self.title = title
    self.language = language
    self.genre = genre
    self.platform = platform
    self.targetChapters = targetChapters
    self.chapterWords = chapterWords
    self.totalWords = totalWords
    self.premise = premise
    self.characters = characters
    self.worldbuilding = worldbuilding
    self.outline = outline
    self.volumePlan = volumePlan
    self.pacing = pacing
    self.style = style
    self.constraints = constraints
  }
}

struct CreateBookResponse: Codable, Sendable {
  let message: String
  let status: String
  let jobId: String
  let title: String
}

struct CreateBookAssistRequest: Encodable, Sendable {
  let requirements: String
}

struct CreateBookAssistResponse: Codable, Sendable {
  let ok: Bool
  let model: String
  let baseUrl: String
  let payload: CreateBookRequest
}
