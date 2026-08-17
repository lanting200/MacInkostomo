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
  /// Source-material extraction for derivative writing: builds the canon bible
  /// out of an imported original work. Separate from `chapter` because the pass
  /// is offline, runs once per book, and reads far more input than it writes —
  /// a different model and context budget than prose generation wants.
  case extraction

  var id: String { rawValue }

  /// Config keys backing this role. A blank role-specific value falls back to
  /// the `chapter` role's, so a user who only wants a different model name can
  /// leave the endpoint and key empty.
  var configKeys: (model: String, baseURL: String, apiKey: String) {
    switch self {
    case .chapter:
      return ("model", "baseUrl", "apiKey")
    case .review:
      return ("reviewModel", "reviewBaseUrl", "reviewApiKey")
    case .extraction:
      return ("extractionModel", "extractionBaseUrl", "extractionApiKey")
    }
  }
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
  let protocolFailure: Bool?
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
  let protocolFailure: Bool?
  /// Craft findings that did not block delivery to manual review.
  let craftAdvisories: [String]?
  let revisionGuidance: String?
  let reviewedAt: String?
  let autoFixed: Bool?
  let rewriteError: String?
  let attempts: [ReviewAttempt]?

  var issueList: [String] { issues ?? [] }
  var craftAdvisoryList: [String] { craftAdvisories ?? [] }
  var isPassed: Bool { status == "passed" }
  var isProtocolFailure: Bool { protocolFailure == true || status == "protocol_error" }
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

  /// Derives a new detail from an existing one, overriding only the fields a
  /// revision round replaces (title, content). Used to make each auto-revision
  /// round rewrite the latest draft rather than the original chapter.
  init(from other: ChapterDetail, title: String, content: String) {
    number = other.number
    self.title = title
    self.content = content
    status = other.status
    inkosStatus = other.inkosStatus
    publisherStatus = other.publisherStatus
    wordCount = other.wordCount
    auditIssues = other.auditIssues
    lengthWarnings = other.lengthWarnings
    reviewNote = other.reviewNote
    reviewNotes = other.reviewNotes
    revisionHistory = other.revisionHistory
    publishedAt = other.publishedAt
    volume = other.volume
    volumeTitle = other.volumeTitle
    createdAt = other.createdAt
    updatedAt = other.updatedAt
    llmReview = other.llmReview
    inkosReviewSync = other.inkosReviewSync
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
  /// 1-based index of the current automatic rewrite round; nil outside an
  /// auto-revision loop (initial writing, manual first pass).
  let revisionRound: Int?
  /// Total automatic rewrite rounds allowed before the chapter falls to manual.
  let maxRevisionRounds: Int?
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
  let extractionModel: String
  let baseUrl: String
  let reviewBaseUrl: String
  let extractionBaseUrl: String
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
  let hasExtractionApiKey: Bool
  let extractionApiKeyPreview: String

  /// Deliberately blank even if a future server accidentally returns a key.
  let apiKey: String
  let reviewApiKey: String
  let extractionApiKey: String

  private enum CodingKeys: String, CodingKey {
    case provider, model, reviewModel, extractionModel, baseUrl, reviewBaseUrl
    case extractionBaseUrl, apiFormat, stream
    case temperature, maxTokens, thinkingBudget, source, hasApiKey, apiKeyPreview
    case hasReviewApiKey, reviewApiKeyPreview, hasExtractionApiKey, extractionApiKeyPreview
    case apiKey, reviewApiKey, extractionApiKey
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "openai"
    model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
    reviewModel = try values.decodeIfPresent(String.self, forKey: .reviewModel) ?? ""
    extractionModel = try values.decodeIfPresent(String.self, forKey: .extractionModel) ?? ""
    baseUrl = try values.decodeIfPresent(String.self, forKey: .baseUrl) ?? ""
    reviewBaseUrl = try values.decodeIfPresent(String.self, forKey: .reviewBaseUrl) ?? ""
    extractionBaseUrl = try values.decodeIfPresent(String.self, forKey: .extractionBaseUrl) ?? ""
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
    hasExtractionApiKey =
      try values.decodeIfPresent(Bool.self, forKey: .hasExtractionApiKey) ?? false
    extractionApiKeyPreview =
      try values.decodeIfPresent(String.self, forKey: .extractionApiKeyPreview) ?? ""
    apiKey = ""
    reviewApiKey = ""
    extractionApiKey = ""
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(provider, forKey: .provider)
    try values.encode(model, forKey: .model)
    try values.encode(reviewModel, forKey: .reviewModel)
    try values.encode(extractionModel, forKey: .extractionModel)
    try values.encode(baseUrl, forKey: .baseUrl)
    try values.encode(reviewBaseUrl, forKey: .reviewBaseUrl)
    try values.encode(extractionBaseUrl, forKey: .extractionBaseUrl)
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
    try values.encode(hasExtractionApiKey, forKey: .hasExtractionApiKey)
    try values.encode(extractionApiKeyPreview, forKey: .extractionApiKeyPreview)
    try values.encode("", forKey: .apiKey)
    try values.encode("", forKey: .reviewApiKey)
    try values.encode("", forKey: .extractionApiKey)
  }
}

struct InkOSConfigUpdate: Encodable, Sendable, CustomStringConvertible {
  let model: String
  let reviewModel: String
  let extractionModel: String
  let baseUrl: String
  let reviewBaseUrl: String
  let extractionBaseUrl: String
  let apiKey: String
  let reviewApiKey: String
  let extractionApiKey: String
  let stream: Bool
  let thinkingBudget: Int
  let temperature: Double?
  let maxTokens: Int?

  init(
    model: String,
    reviewModel: String,
    extractionModel: String = "",
    baseUrl: String,
    reviewBaseUrl: String = "",
    extractionBaseUrl: String = "",
    apiKey: String = "",
    reviewApiKey: String = "",
    extractionApiKey: String = "",
    stream: Bool = false,
    thinkingBudget: Int = 0,
    temperature: Double? = nil,
    maxTokens: Int? = nil
  ) {
    self.model = model
    self.reviewModel = reviewModel
    self.extractionModel = extractionModel
    self.baseUrl = baseUrl
    self.reviewBaseUrl = reviewBaseUrl
    self.extractionBaseUrl = extractionBaseUrl
    self.apiKey = apiKey
    self.reviewApiKey = reviewApiKey
    self.extractionApiKey = extractionApiKey
    self.stream = stream
    self.thinkingBudget = thinkingBudget
    self.temperature = temperature
    self.maxTokens = maxTokens
  }

  var description: String {
    "InkOSConfigUpdate(model: \(model), reviewModel: \(reviewModel), "
      + "extractionModel: \(extractionModel), credentials: redacted)"
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

// MARK: - Structured long-form plan

struct LongFormConstraints: Codable, Equatable, Sendable {
  var targetTotalWords: Int
  var volumeCount: Int
  var targetChapterWords: Int
  var chapterWordTolerance: Int
  var specialConstraints: [String]

  init(
    targetTotalWords: Int = 600_000,
    volumeCount: Int = 6,
    targetChapterWords: Int = 3000,
    chapterWordTolerance: Int = 15,
    specialConstraints: [String] = []
  ) {
    self.targetTotalWords = targetTotalWords
    self.volumeCount = volumeCount
    self.targetChapterWords = targetChapterWords
    self.chapterWordTolerance = chapterWordTolerance
    self.specialConstraints = specialConstraints
  }

  /// Smallest usable width for a chapter word band. A band narrower than this —
  /// `chapterWordTolerance` is user-settable down to 0, which collapses it to a
  /// single point — asks the model to land on an exact character count, which no
  /// draft can reliably hit, so every chapter fails length validation.
  static let minimumChapterWordBandWidth = 300

  /// The single derivation of a chapter's word band from the constraints. Used by
  /// the planner when it writes per-chapter entries and as the fallback for a
  /// chapter with no plan entry, so a plan file and a fallback can never disagree.
  var derivedChapterWordBand: (minWords: Int, maxWords: Int) {
    let target = max(1, targetChapterWords)
    let tolerance = max(0, chapterWordTolerance)
    var low = max(1, Int((Double(target) * Double(100 - tolerance) / 100).rounded()))
    var high = max(low, Int((Double(target) * Double(100 + tolerance) / 100).rounded()))
    let deficit = Self.minimumChapterWordBandWidth - (high - low)
    if deficit > 0 {
      low = max(1, low - deficit / 2)
      high = max(low + Self.minimumChapterWordBandWidth, low)
    }
    return (low, high)
  }

  /// Word band to use when a chapter has no plan entry (chapter number beyond the
  /// planned range, or a plan that has not been generated yet).
  var fallbackChapterWordBand: (minWords: Int, maxWords: Int) { derivedChapterWordBand }

  private enum CodingKeys: String, CodingKey {
    case targetTotalWords, totalWordCount, totalWords
    case volumeCount, targetVolumes
    case targetChapterWords, chapterWords
    case chapterWordTolerance, chapterWordTolerancePercent
    case specialConstraints, constraints
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    targetTotalWords = Self.firstPositiveInt(
      values, keys: [.targetTotalWords, .totalWordCount, .totalWords], fallback: 0)
    volumeCount = Self.firstPositiveInt(
      values, keys: [.volumeCount, .targetVolumes], fallback: 0)
    targetChapterWords = Self.firstPositiveInt(
      values, keys: [.targetChapterWords, .chapterWords], fallback: 0)
    chapterWordTolerance = Self.firstNonnegativeInt(
      values,
      keys: [.chapterWordTolerance, .chapterWordTolerancePercent],
      fallback: 15
    )
    if let list = try? values.decode([String].self, forKey: .specialConstraints) {
      specialConstraints = list
    } else {
      let text = values.lossyString(forKey: .specialConstraints)
      let legacyText = text.isEmpty ? values.lossyString(forKey: .constraints) : text
      specialConstraints = Self.lines(from: legacyText)
    }
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(targetTotalWords, forKey: .targetTotalWords)
    try values.encode(volumeCount, forKey: .volumeCount)
    try values.encode(targetChapterWords, forKey: .targetChapterWords)
    try values.encode(chapterWordTolerance, forKey: .chapterWordTolerance)
    try values.encode(specialConstraints, forKey: .specialConstraints)
  }

  private static func firstPositiveInt(
    _ values: KeyedDecodingContainer<CodingKeys>,
    keys: [CodingKeys],
    fallback: Int
  ) -> Int {
    for key in keys where values.contains(key) {
      let value = values.lossyInt(forKey: key)
      if value > 0 { return value }
    }
    return fallback
  }

  private static func firstNonnegativeInt(
    _ values: KeyedDecodingContainer<CodingKeys>,
    keys: [CodingKeys],
    fallback: Int
  ) -> Int {
    for key in keys where values.contains(key) {
      let value = values.lossyInt(forKey: key, default: -1)
      if value >= 0 { return value }
    }
    return fallback
  }

  static func lines(from text: String) -> [String] {
    text.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}

struct LongFormChapterWordRange: Codable, Equatable, Sendable {
  let min: Int
  let max: Int
}

struct LongFormContinuityPolicy: Codable, Equatable, Sendable {
  var requireContinuousVolumes: Bool
  var allowUnplannedEntities: Bool
  var requireConsistencyDelta: Bool
  var checkpointAtVolumeEnd: Bool

  init(
    requireContinuousVolumes: Bool = true,
    allowUnplannedEntities: Bool = true,
    requireConsistencyDelta: Bool = true,
    checkpointAtVolumeEnd: Bool = true
  ) {
    self.requireContinuousVolumes = requireContinuousVolumes
    self.allowUnplannedEntities = allowUnplannedEntities
    self.requireConsistencyDelta = requireConsistencyDelta
    self.checkpointAtVolumeEnd = checkpointAtVolumeEnd
  }

  private enum CodingKeys: String, CodingKey {
    case requireContinuousVolumes, allowUnplannedEntities
    case requireConsistencyDelta, checkpointAtVolumeEnd
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    requireContinuousVolumes = try values.decodeIfPresent(
      Bool.self, forKey: .requireContinuousVolumes) ?? true
    allowUnplannedEntities = try values.decodeIfPresent(
      Bool.self, forKey: .allowUnplannedEntities) ?? true
    requireConsistencyDelta = try values.decodeIfPresent(
      Bool.self, forKey: .requireConsistencyDelta) ?? true
    checkpointAtVolumeEnd = try values.decodeIfPresent(
      Bool.self, forKey: .checkpointAtVolumeEnd) ?? true
  }
}

struct LongFormImmutableCanon: Codable, Equatable, Sendable {
  let id: String
  let category: String
  let statement: String
  let value: String?
  let aliases: [String]

  private enum CodingKeys: String, CodingKey {
    case id, category, statement, value, aliases
  }

  init(
    id: String,
    category: String = "other",
    statement: String,
    value: String? = nil,
    aliases: [String] = []
  ) {
    self.id = id
    self.category = category
    self.statement = statement
    self.value = value
    self.aliases = aliases
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    category = try values.decodeIfPresent(String.self, forKey: .category) ?? "other"
    statement = try values.decode(String.self, forKey: .statement)
    value = try values.decodeIfPresent(String.self, forKey: .value)
    aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}

struct LongFormWorldRule: Codable, Equatable, Sendable {
  let id: String
  let statement: String
  let immutable: Bool

  private enum CodingKeys: String, CodingKey {
    case id, statement, immutable
  }

  init(id: String, statement: String, immutable: Bool = true) {
    self.id = id
    self.statement = statement
    self.immutable = immutable
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    statement = try values.decode(String.self, forKey: .statement)
    immutable = try values.decodeIfPresent(Bool.self, forKey: .immutable) ?? true
  }
}

struct LongFormEntity: Codable, Equatable, Sendable {
  let id: String
  let name: String
  let type: String
  let owner: String?
  let location: String?
  let attributes: [String: String]
  let immutableOwner: Bool
  let immutableLocation: Bool
  let immutableAttributes: [String]

  private enum CodingKeys: String, CodingKey {
    case id, name, type, owner, location, attributes
    case immutableOwner, immutableLocation, immutableAttributes
  }

  init(
    id: String,
    name: String,
    type: String,
    owner: String? = nil,
    location: String? = nil,
    attributes: [String: String] = [:],
    immutableOwner: Bool = false,
    immutableLocation: Bool = false,
    immutableAttributes: [String] = []
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.owner = owner
    self.location = location
    self.attributes = attributes
    self.immutableOwner = immutableOwner
    self.immutableLocation = immutableLocation
    self.immutableAttributes = immutableAttributes
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    type = try values.decode(String.self, forKey: .type)
    owner = try values.decodeIfPresent(String.self, forKey: .owner)
    location = try values.decodeIfPresent(String.self, forKey: .location)
    attributes = try values.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
    immutableOwner = try values.decodeIfPresent(Bool.self, forKey: .immutableOwner) ?? false
    immutableLocation = try values.decodeIfPresent(Bool.self, forKey: .immutableLocation) ?? false
    immutableAttributes = try values.decodeIfPresent(
      [String].self, forKey: .immutableAttributes) ?? []
  }
}

struct LongFormKnowledgeBoundary: Codable, Equatable, Sendable {
  let factId: String
  let statement: String
  let allowedKnowers: [String]
  let forbiddenKnowers: [String]
  let availableFromChapter: Int
  let revealByChapter: Int?
  let markers: [String]

  private enum CodingKeys: String, CodingKey {
    case factId, statement, allowedKnowers, forbiddenKnowers
    case availableFromChapter, revealByChapter, markers
  }

  init(
    factId: String,
    statement: String,
    allowedKnowers: [String] = [],
    forbiddenKnowers: [String] = [],
    availableFromChapter: Int = 1,
    revealByChapter: Int? = nil,
    markers: [String] = []
  ) {
    self.factId = factId
    self.statement = statement
    self.allowedKnowers = allowedKnowers
    self.forbiddenKnowers = forbiddenKnowers
    self.availableFromChapter = availableFromChapter
    self.revealByChapter = revealByChapter
    self.markers = markers
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    factId = try values.decode(String.self, forKey: .factId)
    statement = try values.decode(String.self, forKey: .statement)
    allowedKnowers = try values.decodeIfPresent([String].self, forKey: .allowedKnowers) ?? []
    forbiddenKnowers = try values.decodeIfPresent([String].self, forKey: .forbiddenKnowers) ?? []
    availableFromChapter = try values.decodeIfPresent(
      Int.self, forKey: .availableFromChapter) ?? 1
    revealByChapter = try values.decodeIfPresent(Int.self, forKey: .revealByChapter)
    markers = try values.decodeIfPresent([String].self, forKey: .markers) ?? []
  }
}

struct LongFormTimelineMilestone: Codable, Equatable, Sendable {
  let id: String
  let order: Int
  let label: String
  let earliestChapter: Int
  let latestChapter: Int
  let immutable: Bool
  /// Position on the shared in-story day axis, relative to the derivative book's
  /// anchor event (see `DerivativeTimeline`). Negative is before the anchor.
  ///
  /// `order` cannot serve this purpose: it is a dense sort key that
  /// `applyContinuityDelta` renumbers on collision, so it carries sequence but no
  /// distance — it cannot answer "has this happened yet at chapter 12". `sourceDay`
  /// is an absolute coordinate that survives renumbering and supports arithmetic.
  /// Nil means unplaced, which is the honest state for a source event whose date
  /// the text never gives; unplaced events are reported separately rather than
  /// being guessed onto the axis.
  let sourceDay: Int?
  /// Chapter of the *original work* this event was extracted from.
  ///
  /// This is the axis that actually works. `sourceDay` needs the text to state
  /// elapsed time and most passages never do, whereas every extracted milestone
  /// comes from a known batch, so this is populated for all of them and is
  /// monotonic in source order. Classifying an event as already-happened or
  /// not-yet falls back to comparing this against the anchor's source chapter
  /// when `sourceDay` is missing on either side.
  let sourceChapter: Int?

  private enum CodingKeys: String, CodingKey {
    case id, order, label, earliestChapter, latestChapter, immutable
    case sourceDay, sourceChapter
  }

  init(
    id: String,
    order: Int,
    label: String,
    earliestChapter: Int,
    latestChapter: Int,
    immutable: Bool = true,
    sourceDay: Int? = nil,
    sourceChapter: Int? = nil
  ) {
    self.sourceDay = sourceDay
    self.sourceChapter = sourceChapter
    self.id = id
    self.order = order
    self.label = label
    self.earliestChapter = earliestChapter
    self.latestChapter = latestChapter
    self.immutable = immutable
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    order = try values.decode(Int.self, forKey: .order)
    label = try values.decode(String.self, forKey: .label)
    earliestChapter = try values.decode(Int.self, forKey: .earliestChapter)
    latestChapter = try values.decode(Int.self, forKey: .latestChapter)
    immutable = try values.decodeIfPresent(Bool.self, forKey: .immutable) ?? true
    sourceDay = try? values.decodeIfPresent(Int.self, forKey: .sourceDay)
    sourceChapter = try? values.decodeIfPresent(Int.self, forKey: .sourceChapter)
  }
}

struct LongFormHookPlan: Codable, Equatable, Sendable {
  let hookId: String
  let description: String
  let openFromChapter: Int
  let resolveByChapter: Int?
  let requiredVolumeNumber: Int?

  init(
    hookId: String,
    description: String,
    openFromChapter: Int,
    resolveByChapter: Int? = nil,
    requiredVolumeNumber: Int? = nil
  ) {
    self.hookId = hookId
    self.description = description
    self.openFromChapter = openFromChapter
    self.resolveByChapter = resolveByChapter
    self.requiredVolumeNumber = requiredVolumeNumber
  }
}

struct LongFormContinuity: Codable, Equatable, Sendable {
  var immutableCanon: [LongFormImmutableCanon]
  var worldRules: [LongFormWorldRule]
  var entities: [LongFormEntity]
  var knowledgeBoundaries: [LongFormKnowledgeBoundary]
  var timeline: [LongFormTimelineMilestone]
  var hooks: [LongFormHookPlan]
  var policy: LongFormContinuityPolicy

  init(
    immutableCanon: [LongFormImmutableCanon] = [],
    worldRules: [LongFormWorldRule] = [],
    entities: [LongFormEntity] = [],
    knowledgeBoundaries: [LongFormKnowledgeBoundary] = [],
    timeline: [LongFormTimelineMilestone] = [],
    hooks: [LongFormHookPlan] = [],
    policy: LongFormContinuityPolicy = LongFormContinuityPolicy()
  ) {
    self.immutableCanon = immutableCanon
    self.worldRules = worldRules
    self.entities = entities
    self.knowledgeBoundaries = knowledgeBoundaries
    self.timeline = timeline
    self.hooks = hooks
    self.policy = policy
  }

  private enum CodingKeys: String, CodingKey {
    case immutableCanon, worldRules, entities, knowledgeBoundaries, timeline, hooks, policy
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    immutableCanon = try values.decodeIfPresent(
      [LongFormImmutableCanon].self, forKey: .immutableCanon) ?? []
    worldRules = try values.decodeIfPresent([LongFormWorldRule].self, forKey: .worldRules) ?? []
    entities = try values.decodeIfPresent([LongFormEntity].self, forKey: .entities) ?? []
    knowledgeBoundaries = try values.decodeIfPresent(
      [LongFormKnowledgeBoundary].self, forKey: .knowledgeBoundaries) ?? []
    timeline = try values.decodeIfPresent(
      [LongFormTimelineMilestone].self, forKey: .timeline) ?? []
    hooks = try values.decodeIfPresent([LongFormHookPlan].self, forKey: .hooks) ?? []
    policy = try values.decodeIfPresent(
      LongFormContinuityPolicy.self, forKey: .policy) ?? LongFormContinuityPolicy()
  }
}

struct LongFormContinuityValidationError: LocalizedError, Equatable, Sendable {
  let message: String

  var errorDescription: String? { message }
}

// MARK: - Chapter beat plan

/// Narrative brief for a single chapter. This is the missing layer between the
/// volume-level goals and the generation prompt: without it the writing model
/// only sees "volume 1 covers chapters 1-234" and compresses dozens of chapters
/// of planned material into one.
struct ChapterBeat: Codable, Identifiable, Equatable, Sendable {
  /// Chapter this brief belongs to.
  var number: Int
  /// Volume the chapter sits in, mirrored from the derived plan.
  var volumeNumber: Int
  /// The single concrete problem the chapter advances.
  var goal: String
  /// Concrete moment or action the chapter opens on, not a background summary.
  var openingHook: String
  /// One to three dramatized scenes, each with place, cast and on-page conflict.
  var scenes: [String]
  /// Events that must be visibly dramatized in the prose.
  var requiredEvents: [String]
  /// Material explicitly reserved for later chapters. This is the field that
  /// stops chapter 1 from consuming the first eighty chapters of the plan.
  var forbiddenElements: [String]
  /// Closing hook, reversal, countdown or new information.
  var endingHook: String
  /// Characters who appear and matter in this chapter.
  var focusCharacters: [String]
  /// Upper bound on newly introduced named characters.
  var newNamedCharacters: Int?
  /// Story time the chapter is allowed to cover.
  var timeSpan: String
  /// Whole in-story days this chapter consumes, as a number the pipeline can add.
  ///
  /// `timeSpan` is free prose ("半天", "三天后") written for the writing model, so
  /// nothing can sum it. Derivative work needs the sum: the chapter's position on
  /// the source timeline is the anchor day plus every preceding chapter's elapsed
  /// days, and that is what decides which canon events have already happened.
  /// Nil means the beat did not say; `DerivativeTimeline` treats it as
  /// `defaultChapterStoryDays` rather than zero, because a chapter that advances
  /// the clock by nothing would freeze the story date forever.
  var storyDays: Int?
  /// Setback, cost or failure the chapter must contain.
  var setback: String
  /// Free-form reminders for the writing model.
  var notes: String

  var id: Int { number }

  init(
    number: Int,
    volumeNumber: Int = 1,
    goal: String = "",
    openingHook: String = "",
    scenes: [String] = [],
    requiredEvents: [String] = [],
    forbiddenElements: [String] = [],
    endingHook: String = "",
    focusCharacters: [String] = [],
    newNamedCharacters: Int? = nil,
    timeSpan: String = "",
    storyDays: Int? = nil,
    setback: String = "",
    notes: String = ""
  ) {
    self.number = number
    self.volumeNumber = volumeNumber
    self.goal = goal
    self.openingHook = openingHook
    self.scenes = scenes
    self.requiredEvents = requiredEvents
    self.forbiddenElements = forbiddenElements
    self.endingHook = endingHook
    self.focusCharacters = focusCharacters
    self.newNamedCharacters = newNamedCharacters
    self.timeSpan = timeSpan
    self.storyDays = storyDays
    self.setback = setback
    self.notes = notes
  }

  private enum CodingKeys: String, CodingKey {
    case number, volumeNumber, goal, openingHook, scenes, requiredEvents
    case forbiddenElements, endingHook, focusCharacters, newNamedCharacters
    case timeSpan, storyDays, setback, notes
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    number = values.lossyInt(forKey: .number)
    volumeNumber = values.lossyInt(forKey: .volumeNumber, default: 1)
    goal = values.lossyString(forKey: .goal)
    openingHook = values.lossyString(forKey: .openingHook)
    scenes = (try? values.decodeIfPresent([String].self, forKey: .scenes)) ?? []
    requiredEvents = (try? values.decodeIfPresent([String].self, forKey: .requiredEvents)) ?? []
    forbiddenElements = (try? values.decodeIfPresent(
      [String].self, forKey: .forbiddenElements)) ?? []
    endingHook = values.lossyString(forKey: .endingHook)
    focusCharacters = (try? values.decodeIfPresent([String].self, forKey: .focusCharacters)) ?? []
    newNamedCharacters = try? values.decodeIfPresent(Int.self, forKey: .newNamedCharacters)
    timeSpan = values.lossyString(forKey: .timeSpan)
    // Not `lossyInt`: that folds a missing key into a default, and nil has to stay
    // distinguishable from an explicit 0. A beat may legitimately say a chapter
    // occupies the same day as the last one ("0"), which is not the same as a beat
    // that never mentioned time at all.
    storyDays = try? values.decodeIfPresent(Int.self, forKey: .storyDays)
    setback = values.lossyString(forKey: .setback)
    notes = values.lossyString(forKey: .notes)
  }

  /// A beat only replaces volume-level guidance when it names both a goal and at
  /// least one scene.
  var isUsable: Bool {
    !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !scenes.isEmpty
  }
}

/// Provenance for one lazily generated window of beats.
struct ChapterBeatBatch: Codable, Equatable, Sendable {
  var startChapter: Int
  var endChapter: Int
  var volumeNumber: Int
  var planRevision: Int
  var generatedAt: String
  var model: String

  init(
    startChapter: Int,
    endChapter: Int,
    volumeNumber: Int,
    planRevision: Int,
    generatedAt: String,
    model: String
  ) {
    self.startChapter = startChapter
    self.endChapter = endChapter
    self.volumeNumber = volumeNumber
    self.planRevision = planRevision
    self.generatedAt = generatedAt
    self.model = model
  }

  private enum CodingKeys: String, CodingKey {
    case startChapter, endChapter, volumeNumber, planRevision, generatedAt, model
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    startChapter = values.lossyInt(forKey: .startChapter)
    endChapter = values.lossyInt(forKey: .endChapter)
    volumeNumber = values.lossyInt(forKey: .volumeNumber, default: 1)
    planRevision = values.lossyInt(forKey: .planRevision)
    generatedAt = values.lossyString(forKey: .generatedAt)
    model = values.lossyString(forKey: .model)
  }
}

/// Persisted chapter beats. Beats are generated lazily in windows so a
/// 700-chapter book never needs a single planning call.
struct ChapterBeatPlan: Codable, Equatable, Sendable {
  var version: Int
  var bookId: String
  var beats: [ChapterBeat]
  var batches: [ChapterBeatBatch]
  var updatedAt: String

  init(
    version: Int = 1,
    bookId: String,
    beats: [ChapterBeat] = [],
    batches: [ChapterBeatBatch] = [],
    updatedAt: String = ""
  ) {
    self.version = version
    self.bookId = bookId
    self.beats = beats
    self.batches = batches
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case version, bookId, beats, batches, updatedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = values.lossyInt(forKey: .version, default: 1)
    bookId = values.lossyString(forKey: .bookId)
    beats = (try? values.decodeIfPresent([ChapterBeat].self, forKey: .beats)) ?? []
    batches = (try? values.decodeIfPresent([ChapterBeatBatch].self, forKey: .batches)) ?? []
    updatedAt = values.lossyString(forKey: .updatedAt)
  }

  func beat(for number: Int) -> ChapterBeat? {
    beats.first { $0.number == number }
  }
}

/// Progress of the derivative preparation pass, for display while it runs.
///
/// Import is fast, canon extraction is not: it is one model call per batch of source
/// text, so a full-length novel takes hundreds. The pass is checkpointed after every
/// batch, which is why this carries `canonComplete` separately from `isRunning` — a
/// pass can stop with usable canon and be resumed later.
struct DerivativePreparationState: Equatable, Sendable {
  var bookID: String
  var bookTitle: String
  /// What the pass is doing right now, in the customer's words.
  var phase: String
  var isRunning: Bool
  var sourceChapterCount: Int
  var canonChaptersDone: Int
  var canonComplete: Bool
  var entityCount: Int
  var timelineCount: Int
  /// The author's settings are a separate overlay pass and must remain resumable
  /// even after canon extraction itself has completed.
  var overlayComplete: Bool = true
  /// Semantic embedding is optional and retrieval still works lexically without it,
  /// so a failure here is reported while retaining the retry affordance.
  var embedRequested: Bool = false
  var embeddingComplete: Bool = true
  var embeddedPassages: Int
  var totalPassages: Int
  var failure: String?

  var canonProgress: Double {
    guard sourceChapterCount > 0 else { return 0 }
    return Swift.min(1, Double(canonChaptersDone) / Double(sourceChapterCount))
  }

  /// Canon fill while chapters are still being extracted; vector fill once the
  /// banner is waiting on the semantic index. Using chapter progress there is
  /// what made a 22 000-passage embed look finished at 0/N.
  var bannerProgress: Double {
    if embedRequested, !embeddingComplete, totalPassages > 0 {
      return Swift.min(1, Double(embeddedPassages) / Double(totalPassages))
    }
    return canonProgress
  }

  var isComplete: Bool {
    canonComplete && overlayComplete && embeddingComplete
  }

  var needsResume: Bool { !isComplete }

  /// Import itself never landed, so resume cannot help — the customer must pick
  /// the original again.
  var needsSourceFile: Bool {
    !isRunning && sourceChapterCount == 0
  }
}

// MARK: - Book kind

/// Whether a book invents its world or continues someone else's.
///
/// This is the one field that changes what the pipeline is allowed to do: a
/// derivative book must obey an imported original, so its beats and prose get the
/// retrieval and timeline sections that an original book has no source for.
enum BookKind: String, Codable, CaseIterable, Identifiable, Sendable {
  /// The customer's settings text is the whole world.
  case original
  /// 同人: an imported original work supplies canon the book cannot contradict.
  case derivative

  var id: String { rawValue }

  var label: String {
    switch self {
    case .original: return "自创小说"
    case .derivative: return "同人小说"
    }
  }

  var summary: String {
    switch self {
    case .original: return "你随便写设定，LLM 补全成完整方案"
    case .derivative: return "上传原著，正典与时间线由原著约束"
    }
  }
}

// MARK: - Derivative timeline

/// Where a derivative book sits on the source work's clock.
///
/// Fan fiction drifts in time because nothing in the pipeline knows *when* the
/// story is. The writing model sees canon as a flat set of facts, so a chapter set
/// before the source protagonist's arrival can still have characters discussing
/// events from source chapter 900. This struct fixes the story to a day axis: one
/// canon milestone is the origin, chapter 1 sits a stated number of days from it,
/// and each chapter advances by its beat's `storyDays`.
///
/// Days rather than dates because the source calendar is fictional and inconsistent
/// — the text says "三天后", not a parseable date. An integer day offset can be
/// summed and compared without parsing anything, and `anchorDateLabel` carries the
/// in-world calendar wording for the prompt to quote.
struct DerivativeTimeline: Codable, Equatable, Sendable {
  var version: Int
  /// `LongFormTimelineMilestone.id` the axis is measured from. Nil until the
  /// customer picks one, in which case the axis is relative to chapter 1 alone and
  /// only elapsed time is reported.
  var anchorMilestoneID: String?
  /// The anchor event in the customer's words, quoted into prompts.
  var anchorLabel: String
  /// Chapter of the *original work* where the anchor event happens.
  ///
  /// This is what makes the timeline usable on a real novel. `sourceDay` requires
  /// the source text to state elapsed time and most of it never does, so a day-only
  /// axis leaves nearly every milestone unplaced. Source chapter order, by contrast,
  /// is chronological in a linearly told novel and is known for every extracted
  /// milestone. With the anchor's chapter known, "has this happened yet" becomes a
  /// chapter comparison that works even when no dates exist anywhere.
  var anchorSourceChapter: Int?
  /// Day offset of chapter 1 from the anchor. Negative means the book opens before
  /// the anchor — the "穿越前一年" case, which is -365.
  var startDayOffset: Int
  /// In-world calendar wording for chapter 1, quoted verbatim into prompts. Free
  /// text because the source calendar is fictional.
  var startDateLabel: String
  /// Days a chapter advances when its beat leaves `storyDays` unset. One rather
  /// than zero: a chapter that advances nothing would freeze the clock forever, and
  /// a serialized chapter almost always covers at least part of a day.
  var defaultChapterDays: Int
  var updatedAt: String

  static let currentVersion = 1

  init(
    version: Int = DerivativeTimeline.currentVersion,
    anchorMilestoneID: String? = nil,
    anchorLabel: String = "",
    anchorSourceChapter: Int? = nil,
    startDayOffset: Int = 0,
    startDateLabel: String = "",
    defaultChapterDays: Int = 1,
    updatedAt: String = ""
  ) {
    self.version = version
    self.anchorMilestoneID = anchorMilestoneID
    self.anchorLabel = anchorLabel
    self.anchorSourceChapter = anchorSourceChapter
    self.startDayOffset = startDayOffset
    self.startDateLabel = startDateLabel
    self.defaultChapterDays = defaultChapterDays
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case version, anchorMilestoneID, anchorLabel, anchorSourceChapter
    case startDayOffset, startDateLabel
    case defaultChapterDays, updatedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = values.lossyInt(forKey: .version, default: DerivativeTimeline.currentVersion)
    anchorMilestoneID = (try? values.decodeIfPresent(String.self, forKey: .anchorMilestoneID))
      .flatMap { $0 }
    anchorLabel = values.lossyString(forKey: .anchorLabel)
    anchorSourceChapter = (try? values.decodeIfPresent(Int.self, forKey: .anchorSourceChapter))
      .flatMap { $0 }
    startDayOffset = values.lossyInt(forKey: .startDayOffset)
    startDateLabel = values.lossyString(forKey: .startDateLabel)
    defaultChapterDays = Swift.max(0, values.lossyInt(forKey: .defaultChapterDays, default: 1))
    updatedAt = values.lossyString(forKey: .updatedAt)
  }

  var isConfigured: Bool {
    !anchorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !startDateLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || anchorSourceChapter != nil
  }

  /// In-story day the given chapter opens on, counted from the anchor.
  ///
  /// Days come from the beats rather than a fixed per-chapter constant because
  /// chapters cover wildly different spans; a beat that skips a month has to move
  /// the clock by a month. Chapters without a beat yet fall back to
  /// `defaultChapterDays`, which keeps the axis monotonic instead of stalling.
  func storyDay(forChapter chapter: Int, beats: [ChapterBeat]) -> Int {
    guard chapter > 1 else { return startDayOffset }
    let byNumber = Dictionary(beats.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    var day = startDayOffset
    for number in 1..<chapter {
      day += byNumber[number]?.storyDays ?? defaultChapterDays
    }
    return day
  }
}

/// One canon event placed relative to the chapter being written.
struct DerivativeTimelineEvent: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let label: String
  /// Day on the shared axis, mirrored from `LongFormTimelineMilestone.sourceDay`.
  let sourceDay: Int?
  /// Source chapter the event was extracted from.
  let sourceChapter: Int?
  /// Days from the current chapter. Negative is past, positive is future, nil when
  /// the event has no day and was placed by source chapter instead.
  let dayDelta: Int?
}

/// The timeline as of one chapter: where the story is, and which canon events are
/// therefore behind it, ahead of it, or unplaced.
///
/// `future` is the load-bearing list. A derivative chapter's most common canon
/// violation is not getting a fact wrong but knowing it too early, and that is only
/// detectable with a story clock.
struct DerivativeTimelineStatus: Codable, Equatable, Sendable {
  let chapterNumber: Int
  /// Day offset from the anchor at the start of this chapter.
  let storyDay: Int
  /// Days since chapter 1 opened.
  let elapsedDays: Int
  let anchorLabel: String
  let startDateLabel: String
  /// Greatest original-work chapter among every event classified as past before
  /// the prompt-facing list is truncated.
  let latestPastSourceChapter: Int?
  /// Canon events at or before `storyDay`, most recent last.
  let past: [DerivativeTimelineEvent]
  /// Canon events after `storyDay`, nearest first. These must not be known to
  /// anyone in the chapter.
  let future: [DerivativeTimelineEvent]
  /// Canon events with no `sourceDay`. Reported rather than guessed onto the axis,
  /// so the writing model knows the ordering is unverified.
  let unplaced: [DerivativeTimelineEvent]
  /// True when a timeline exists and is configured for this book.
  let isConfigured: Bool
}

extension LongFormContinuity {
  func validated(targetChapters: Int, volumeCount: Int) throws -> LongFormContinuity {
    guard targetChapters >= 1, volumeCount >= 1 else {
      throw LongFormContinuityValidationError(message: "长篇计划缺少有效的章节或分卷范围")
    }
    try Self.requireCount(immutableCanon.count, max: 5_000, label: "不可变事实")
    try Self.requireCount(worldRules.count, max: 5_000, label: "世界规则")
    try Self.requireCount(entities.count, max: 10_000, label: "实体")
    try Self.requireCount(knowledgeBoundaries.count, max: 10_000, label: "知识边界")
    try Self.requireCount(timeline.count, max: 10_000, label: "时间线")
    try Self.requireCount(hooks.count, max: 10_000, label: "伏笔")

    try Self.requireUnique(immutableCanon.map(\.id), label: "不可变事实 id")
    try Self.requireUnique(worldRules.map(\.id), label: "世界规则 id")
    try Self.requireUnique(entities.map(\.id), label: "实体 id")
    try Self.requireUnique(knowledgeBoundaries.map(\.factId), label: "知识边界 factId")
    try Self.requireUnique(timeline.map(\.id), label: "时间线 id")
    try Self.requireUnique(timeline.map { String($0.order) }, label: "时间线 order")
    try Self.requireUnique(hooks.map(\.hookId), label: "伏笔 hookId")

    let canonCategories = Set([
      "character", "world", "timeline", "entity", "object", "knowledge", "other",
    ])
    for (index, item) in immutableCanon.enumerated() {
      let label = "不可变事实第 \(index + 1) 项"
      try Self.requireText(item.id, max: 160, label: "\(label).id")
      try Self.requireText(item.statement, max: 2_000, label: "\(label).statement")
      guard canonCategories.contains(item.category) else {
        throw LongFormContinuityValidationError(message: "\(label).category 无效")
      }
      if let value = item.value {
        try Self.requireText(value, max: 1_000, allowEmpty: true, label: "\(label).value")
      }
      try Self.requireCount(item.aliases.count, max: 32, label: "\(label).aliases")
      for alias in item.aliases {
        try Self.requireText(alias, max: 160, label: "\(label).aliases")
      }
    }

    for (index, item) in worldRules.enumerated() {
      let label = "世界规则第 \(index + 1) 项"
      try Self.requireText(item.id, max: 160, label: "\(label).id")
      try Self.requireText(item.statement, max: 2_000, label: "\(label).statement")
    }

    let entityTypes = Set(["character", "object", "location", "faction", "concept"])
    for (index, item) in entities.enumerated() {
      let label = "实体第 \(index + 1) 项"
      try Self.requireText(item.id, max: 160, label: "\(label).id")
      try Self.requireText(item.name, max: 500, label: "\(label).name")
      guard entityTypes.contains(item.type) else {
        throw LongFormContinuityValidationError(message: "\(label).type 无效")
      }
      if let owner = item.owner {
        try Self.requireText(owner, max: 500, allowEmpty: true, label: "\(label).owner")
      }
      if let location = item.location {
        try Self.requireText(location, max: 500, allowEmpty: true, label: "\(label).location")
      }
      for (key, value) in item.attributes {
        try Self.requireText(key, max: 160, label: "\(label).attributes 键")
        try Self.requireText(value, max: 1_000, allowEmpty: true, label: "\(label).attributes.\(key)")
      }
      try Self.requireCount(
        item.immutableAttributes.count, max: 64, label: "\(label).immutableAttributes")
      for attribute in item.immutableAttributes {
        try Self.requireText(attribute, max: 160, label: "\(label).immutableAttributes")
      }
    }

    for (index, item) in knowledgeBoundaries.enumerated() {
      let label = "知识边界第 \(index + 1) 项"
      try Self.requireText(item.factId, max: 160, label: "\(label).factId")
      try Self.requireText(item.statement, max: 2_000, label: "\(label).statement")
      try Self.requireChapter(item.availableFromChapter, max: targetChapters,
        label: "\(label).availableFromChapter")
      if let reveal = item.revealByChapter {
        try Self.requireChapter(reveal, max: targetChapters, label: "\(label).revealByChapter")
        guard reveal >= item.availableFromChapter else {
          throw LongFormContinuityValidationError(
            message: "\(label).revealByChapter 不能早于 availableFromChapter")
        }
      }
      try Self.validateIdentifierList(
        item.allowedKnowers, maxCount: 128, label: "\(label).allowedKnowers")
      try Self.validateIdentifierList(
        item.forbiddenKnowers, maxCount: 128, label: "\(label).forbiddenKnowers")
      try Self.validateIdentifierList(item.markers, maxCount: 32, label: "\(label).markers")
      let allowed = Set(item.allowedKnowers.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      })
      let forbidden = Set(item.forbiddenKnowers.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      })
      let overlap = allowed.intersection(forbidden)
      if let conflictingKnower = overlap.first {
        throw LongFormContinuityValidationError(
          message: "\(label)中 \(conflictingKnower) 不能同时出现在允许与禁止知情列表")
      }
    }

    for (index, item) in timeline.enumerated() {
      let label = "时间线第 \(index + 1) 项"
      try Self.requireText(item.id, max: 160, label: "\(label).id")
      try Self.requireText(item.label, max: 2_000, label: "\(label).label")
      guard item.order >= 0 else {
        throw LongFormContinuityValidationError(message: "\(label).order 不能小于 0")
      }
      try Self.requireChapter(
        item.earliestChapter, max: targetChapters, label: "\(label).earliestChapter")
      try Self.requireChapter(
        item.latestChapter, max: targetChapters, label: "\(label).latestChapter")
      guard item.earliestChapter <= item.latestChapter else {
        throw LongFormContinuityValidationError(message: "\(label)的章节窗口无效")
      }
    }

    for (index, item) in hooks.enumerated() {
      let label = "伏笔第 \(index + 1) 项"
      try Self.requireText(item.hookId, max: 160, label: "\(label).hookId")
      try Self.requireText(item.description, max: 2_000, label: "\(label).description")
      try Self.requireChapter(
        item.openFromChapter, max: targetChapters, label: "\(label).openFromChapter")
      if let resolve = item.resolveByChapter {
        try Self.requireChapter(resolve, max: targetChapters, label: "\(label).resolveByChapter")
        guard resolve >= item.openFromChapter else {
          throw LongFormContinuityValidationError(
            message: "\(label).resolveByChapter 不能早于 openFromChapter")
        }
      }
      if let volume = item.requiredVolumeNumber, !(1...volumeCount).contains(volume) {
        throw LongFormContinuityValidationError(
          message: "\(label).requiredVolumeNumber 需在 1 至 \(volumeCount) 之间")
      }
    }
    return self
  }

  private static func requireCount(_ count: Int, max: Int, label: String) throws {
    if count > max {
      throw LongFormContinuityValidationError(message: "\(label)不能超过 \(max) 条")
    }
  }

  private static func requireUnique(_ values: [String], label: String) throws {
    var seen = Set<String>()
    for value in values {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if seen.contains(normalized) {
        throw LongFormContinuityValidationError(message: "\(label) 重复：\(normalized)")
      }
      seen.insert(normalized)
    }
  }

  private static func requireText(
    _ value: String,
    max: Int,
    allowEmpty: Bool = false,
    label: String
  ) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !allowEmpty && normalized.isEmpty {
      throw LongFormContinuityValidationError(message: "\(label) 不能为空")
    }
    if normalized.count > max {
      throw LongFormContinuityValidationError(message: "\(label)不能超过 \(max) 个字符")
    }
  }

  private static func requireChapter(_ value: Int, max: Int, label: String) throws {
    if !(1...max).contains(value) {
      throw LongFormContinuityValidationError(message: "\(label)需在 1 至 \(max) 之间")
    }
  }

  private static func validateIdentifierList(
    _ values: [String],
    maxCount: Int,
    label: String
  ) throws {
    try requireCount(values.count, max: maxCount, label: label)
    for value in values {
      try requireText(value, max: 160, label: label)
    }
  }
}

struct LongFormVolumePlan: Codable, Identifiable, Equatable, Sendable {
  let number: Int
  let startChapter: Int
  let endChapter: Int
  let chapterCount: Int
  let targetWords: Int

  var id: Int { number }
}

struct LongFormChapterPlan: Codable, Identifiable, Equatable, Sendable {
  let number: Int
  let volumeNumber: Int
  let targetWords: Int
  let minWords: Int
  let maxWords: Int

  var id: Int { number }
}

struct LongFormDerivedPlan: Codable, Equatable, Sendable {
  let targetChapters: Int
  let chapterWordRange: LongFormChapterWordRange
  let volumes: [LongFormVolumePlan]
  let chapters: [LongFormChapterPlan]
}

struct LongFormPlanResponse: Codable, Equatable, Sendable {
  let version: Int
  let revision: Int
  let bookId: String
  let constraints: LongFormConstraints
  let plan: LongFormDerivedPlan
  let continuity: LongFormContinuity
  let source: String
  let createdAt: String?
  let updatedAt: String?

  /// Single source of truth for a chapter's word band. Chapters past the planned
  /// range (or books whose plan predates the chapter) fall back to a real band
  /// derived from the constraints instead of a zero-width `target 至 target`.
  ///
  /// A stored entry narrower than the minimum width is widened here rather than
  /// trusted: plans written before the width floor existed (or with
  /// `chapterWordTolerance` at 0) carry bands no draft can satisfy, and those
  /// files are already on disk.
  func chapterWordBand(for chapterNumber: Int) -> (minWords: Int, maxWords: Int) {
    if let entry = plan.chapters.first(where: { $0.number == chapterNumber }) {
      let low = entry.minWords
      let high = entry.maxWords
      if low > 0, high >= low {
        let deficit = LongFormConstraints.minimumChapterWordBandWidth - (high - low)
        guard deficit > 0 else { return (low, high) }
        let widenedLow = max(1, low - deficit / 2)
        return (widenedLow, max(widenedLow + LongFormConstraints.minimumChapterWordBandWidth, high))
      }
    }
    return constraints.fallbackChapterWordBand
  }

  private enum CodingKeys: String, CodingKey {
    case version, revision, bookId, constraints, plan, continuity, source, createdAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = values.lossyInt(forKey: .version, default: 1)
    revision = values.lossyInt(forKey: .revision)
    bookId = values.lossyString(forKey: .bookId)
    constraints = try values.decode(LongFormConstraints.self, forKey: .constraints)
    plan = try values.decode(LongFormDerivedPlan.self, forKey: .plan)
    continuity = try values.decodeIfPresent(
      LongFormContinuity.self, forKey: .continuity) ?? LongFormContinuity()
    source = values.lossyString(forKey: .source, default: "unknown")
    createdAt = values.lossyOptionalString(forKey: .createdAt)
    updatedAt = values.lossyOptionalString(forKey: .updatedAt)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(version, forKey: .version)
    try values.encode(revision, forKey: .revision)
    try values.encode(bookId, forKey: .bookId)
    try values.encode(constraints, forKey: .constraints)
    try values.encode(plan, forKey: .plan)
    try values.encode(continuity, forKey: .continuity)
    try values.encode(source, forKey: .source)
    try values.encodeIfPresent(createdAt, forKey: .createdAt)
    try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

struct LongFormPlanUpdateRequest: Encodable, Sendable {
  let expectedRevision: Int?
  let constraints: LongFormConstraints?
  let continuity: LongFormContinuity?
}

// MARK: - Fanqie publishing

struct FanqieCookie: Codable, Hashable, Sendable {
  let name: String
  let value: String
  let domain: String
  let path: String
  let expiresAt: Date?
  let isSecure: Bool
  let isHTTPOnly: Bool
}

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

  init(content: String, title: String?, chapterId: String?, number: Int?) {
    self.content = content
    self.title = title
    self.chapterId = chapterId
    self.number = number
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

struct FanqieCategory: Codable, Identifiable, Hashable, Sendable {
  let categoryId: String
  let name: String
  let group: String

  var id: String { categoryId }
}

struct FanqieCreateBookInput: Codable, Equatable, Sendable {
  var title: String
  var gender: Int
  var categoryIDs: [String]
  var protagonistNames: [String]
  var abstract: String
  var coverURI: String?
}

struct FanqieChapterTransferInput: Codable, Equatable, Sendable {
  let localBookId: String
  let localChapterNumber: Int
  let remoteBookId: String
  let remoteChapterId: String?
}

struct FanqieMutationResponse: Codable, Equatable, Sendable {
  let ok: Bool
  let message: String
  let bookId: String?
  let chapterId: String?
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

struct CreateBookGuide: Codable, Equatable, Sendable {
  var title: String = ""
  var language: String = "zh"
  var genre: String = "xuanhuan"
  var platform: String = "tomato"
  /// Original or derivative. Drives which questions the creation sheet asks and
  /// which prompt sections the pipeline adds; nothing else about the flow differs.
  var kind: BookKind = .original
  /// Title of the original work, for derivative books only. Quoted into the
  /// creation prompt so the plan is written against a named canon rather than a
  /// generic "原著".
  var sourceTitle: String = ""
  /// Canon event the story clock is measured from, e.g. 克莱恩穿越.
  var timelineAnchorLabel: String = ""
  /// Chapter 1's position relative to the anchor, in days. Negative opens before it.
  var timelineStartDayOffset: Int = 0
  /// In-world wording for chapter 1's date, quoted verbatim into prompts.
  var timelineStartDateLabel: String = ""
  var storyPremise: String = ""
  var protagonistName: String = ""
  var protagonistProfile: String = ""
  var worldRules: String = ""
  var pacing: String = ""
  var style: String = ""
  var targetChapters: Int = 200
  var targetChapterWords: Int = 3000
  var targetTotalWords: Int = 600_000
  var volumeCount: Int = 6
  var chapterWordTolerance: Int = 15
  var specialConstraints: [String] = []

  init() {}

  init(request: CreateBookRequest) {
    title = request.title
    language = request.language
    genre = request.genre
    platform = request.platform
    kind = request.kind
    sourceTitle = request.sourceTitle
    timelineAnchorLabel = request.timelineAnchorLabel
    timelineStartDayOffset = request.timelineStartDayOffset
    timelineStartDateLabel = request.timelineStartDateLabel
    storyPremise = request.premise
    protagonistName = ""
    protagonistProfile = ""
    worldRules = request.worldbuilding
    pacing = request.pacing
    style = request.style
    targetChapters = request.derivedTargetChapters
    targetChapterWords = request.chapterWords
    targetTotalWords = request.targetTotalWords
    volumeCount = request.volumeCount
    chapterWordTolerance = request.chapterWordTolerance
    specialConstraints = LongFormConstraints.lines(from: request.constraints)
  }

  var exactTargetTotalWords: Int {
    targetChapters * targetChapterWords
  }

  mutating func synchronizeBudget() {
    targetTotalWords = exactTargetTotalWords
  }

  private enum CodingKeys: String, CodingKey {
    case title, language, genre, platform, kind, sourceTitle
    case timelineAnchorLabel, timelineStartDayOffset, timelineStartDateLabel
    case storyPremise, protagonistName, protagonistProfile, worldRules, pacing, style
    case targetChapters, targetChapterWords, targetTotalWords, volumeCount
    case chapterWordTolerance, specialConstraints
  }

  /// Decoded field by field with defaults rather than by the synthesized decoder.
  ///
  /// The creation sheet persists a draft to `UserDefaults`, and
  /// `CreateBookDraftPersistence.load` discards the whole snapshot when decoding
  /// throws. A synthesized decoder ignores property defaults and demands every key,
  /// so adding `kind` here would silently erase any draft saved by an earlier build
  /// — the customer would reopen the sheet to an empty form.
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    title = values.lossyString(forKey: .title)
    language = values.lossyString(forKey: .language, default: "zh")
    genre = values.lossyString(forKey: .genre, default: "xuanhuan")
    platform = values.lossyString(forKey: .platform, default: "tomato")
    kind = (try? values.decodeIfPresent(BookKind.self, forKey: .kind)) .flatMap { $0 } ?? .original
    sourceTitle = values.lossyString(forKey: .sourceTitle)
    timelineAnchorLabel = values.lossyString(forKey: .timelineAnchorLabel)
    timelineStartDayOffset = values.lossyInt(forKey: .timelineStartDayOffset)
    timelineStartDateLabel = values.lossyString(forKey: .timelineStartDateLabel)
    storyPremise = values.lossyString(forKey: .storyPremise)
    protagonistName = values.lossyString(forKey: .protagonistName)
    protagonistProfile = values.lossyString(forKey: .protagonistProfile)
    worldRules = values.lossyString(forKey: .worldRules)
    pacing = values.lossyString(forKey: .pacing)
    style = values.lossyString(forKey: .style)
    targetChapters = values.lossyInt(forKey: .targetChapters, default: 200)
    targetChapterWords = values.lossyInt(forKey: .targetChapterWords, default: 3000)
    targetTotalWords = values.lossyInt(forKey: .targetTotalWords, default: 600_000)
    volumeCount = values.lossyInt(forKey: .volumeCount, default: 6)
    chapterWordTolerance = values.lossyInt(forKey: .chapterWordTolerance, default: 15)
    specialConstraints =
      (try? values.decodeIfPresent([String].self, forKey: .specialConstraints)) .flatMap { $0 } ?? []
  }
}

struct CreateBookRequest: Codable, Equatable, Sendable {
  var title: String
  var language: String
  var genre: String
  var platform: String
  /// Original or derivative. Persisted into `book.json` at creation, which is where
  /// the pipeline reads it from on every later chapter.
  var kind: BookKind
  /// Title of the original work, derivative books only.
  var sourceTitle: String
  /// Canon event chapter 1 is positioned against, derivative books only.
  var timelineAnchorLabel: String
  /// Chapter 1's day offset from the anchor. Negative opens before it.
  var timelineStartDayOffset: Int
  /// In-world wording for chapter 1's date, quoted verbatim into prompts.
  var timelineStartDateLabel: String
  var targetChapters: Int
  var chapterWords: Int
  var totalWords: String
  var targetTotalWords: Int
  var volumeCount: Int
  var chapterWordTolerance: Int
  var premise: String
  var characters: String
  /// LLM-expanded protagonist personality. Lives in story/protagonist.md and is
  /// injected into every chapter prompt, so creation cannot complete until a
  /// human has reviewed it (protagonistReviewed).
  var protagonistProfile: String
  var protagonistReviewed: Bool
  var worldbuilding: String
  var outline: String
  var volumePlan: String
  var pacing: String
  var style: String
  var constraints: String
  var creationGuide: CreateBookGuide?

  init(
    title: String = "",
    language: String = "zh",
    genre: String = "xuanhuan",
    platform: String = "tomato",
    kind: BookKind = .original,
    sourceTitle: String = "",
    timelineAnchorLabel: String = "",
    timelineStartDayOffset: Int = 0,
    timelineStartDateLabel: String = "",
    targetChapters: Int = 200,
    chapterWords: Int = 3000,
    totalWords: String = "600000",
    targetTotalWords: Int = 600_000,
    volumeCount: Int = 6,
    chapterWordTolerance: Int = 15,
    premise: String = "",
    characters: String = "",
    protagonistProfile: String = "",
    protagonistReviewed: Bool = false,
    worldbuilding: String = "",
    outline: String = "",
    volumePlan: String = "",
    pacing: String = "",
    style: String = "",
    constraints: String = "",
    creationGuide: CreateBookGuide? = nil
  ) {
    self.title = title
    self.language = language
    self.genre = genre
    self.platform = platform
    self.kind = kind
    self.sourceTitle = sourceTitle
    self.timelineAnchorLabel = timelineAnchorLabel
    self.timelineStartDayOffset = timelineStartDayOffset
    self.timelineStartDateLabel = timelineStartDateLabel
    self.targetChapters = targetChapters
    self.chapterWords = chapterWords
    self.totalWords = totalWords
    self.targetTotalWords = targetTotalWords
    self.volumeCount = volumeCount
    self.chapterWordTolerance = chapterWordTolerance
    self.premise = premise
    self.characters = characters
    self.protagonistProfile = protagonistProfile
    self.protagonistReviewed = protagonistReviewed
    self.worldbuilding = worldbuilding
    self.outline = outline
    self.volumePlan = volumePlan
    self.pacing = pacing
    self.style = style
    self.constraints = constraints
    self.creationGuide = creationGuide
  }

  var derivedTargetChapters: Int {
    guard targetTotalWords > 0, chapterWords > 0 else { return 0 }
    return max(1, Int((Double(targetTotalWords) / Double(chapterWords)).rounded()))
  }

  var chapterWordRange: ClosedRange<Int> {
    let boundedTolerance = min(max(chapterWordTolerance, 0), 100)
    let lower = (chapterWords * (100 - boundedTolerance) + 50) / 100
    let upper = (chapterWords * (100 + boundedTolerance) + 50) / 100
    return lower...upper
  }

  mutating func synchronizeLongFormFields() {
    targetChapters = derivedTargetChapters
    totalWords = String(targetTotalWords)
    constraints = constraints.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private enum CodingKeys: String, CodingKey {
    case title, language, genre, platform, targetChapters, chapterWords, totalWords
    case kind, sourceTitle
    case timelineAnchorLabel, timelineStartDayOffset, timelineStartDateLabel
    case targetTotalWords, totalWordCount, targetWords
    case targetChapterWords
    case volumeCount, targetVolumes
    case chapterWordTolerance, chapterWordTolerancePercent
    case premise, characters, protagonistProfile, protagonistReviewed, worldbuilding, outline, volumePlan, pacing, style
    case constraints, specialConstraints
    case creationGuide
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    title = values.lossyString(forKey: .title)
    language = values.lossyString(forKey: .language, default: "zh")
    genre = values.lossyString(forKey: .genre, default: "xuanhuan")
    platform = values.lossyString(forKey: .platform, default: "tomato")
    // Absent means a book created before derivative support existed, and those are
    // all original works, so the default is the correct migration.
    kind = (try? values.decodeIfPresent(BookKind.self, forKey: .kind)) ?? .original
    sourceTitle = values.lossyString(forKey: .sourceTitle)
    timelineAnchorLabel = values.lossyString(forKey: .timelineAnchorLabel)
    timelineStartDayOffset = values.lossyInt(forKey: .timelineStartDayOffset)
    timelineStartDateLabel = values.lossyString(forKey: .timelineStartDateLabel)
    targetChapters = values.lossyInt(forKey: .targetChapters, default: 200)
    chapterWords =
      values.contains(.targetChapterWords)
      ? values.lossyInt(forKey: .targetChapterWords, default: 3000)
      : values.lossyInt(forKey: .chapterWords, default: 3000)
    totalWords = values.lossyString(forKey: .totalWords)

    let explicitTotal =
      Self.lossyPositiveInt(values, keys: [.targetTotalWords, .totalWordCount, .targetWords])
    targetTotalWords =
      explicitTotal
      ?? Self.parseLegacyWordCount(totalWords)
      ?? max(1, targetChapters) * max(500, chapterWords)
    targetTotalWords = min(targetTotalWords, 3_000_000)

    volumeCount =
      Self.lossyPositiveInt(values, keys: [.volumeCount, .targetVolumes]) ?? 6
    chapterWordTolerance =
      Self.lossyNonnegativeInt(
        values, keys: [.chapterWordTolerance, .chapterWordTolerancePercent]) ?? 15

    premise = values.lossyString(forKey: .premise)
    characters = values.lossyString(forKey: .characters)
    protagonistProfile = values.lossyString(forKey: .protagonistProfile)
    protagonistReviewed = (try? values.decode(Bool.self, forKey: .protagonistReviewed)) ?? false
    worldbuilding = values.lossyString(forKey: .worldbuilding)
    outline = values.lossyString(forKey: .outline)
    volumePlan = values.lossyString(forKey: .volumePlan)
    pacing = values.lossyString(forKey: .pacing)
    style = values.lossyString(forKey: .style)
    constraints = values.lossyString(forKey: .constraints)
    if constraints.isEmpty,
      let list = try? values.decode([String].self, forKey: .specialConstraints)
    {
      constraints = list.joined(separator: "\n")
    } else if constraints.isEmpty {
      constraints = values.lossyString(forKey: .specialConstraints)
    }
    creationGuide = try? values.decode(CreateBookGuide.self, forKey: .creationGuide)
    synchronizeLongFormFields()
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    let chapters = derivedTargetChapters
    try values.encode(title, forKey: .title)
    try values.encode(language, forKey: .language)
    try values.encode(genre, forKey: .genre)
    try values.encode(platform, forKey: .platform)
    try values.encode(kind, forKey: .kind)
    try values.encode(sourceTitle, forKey: .sourceTitle)
    try values.encode(timelineAnchorLabel, forKey: .timelineAnchorLabel)
    try values.encode(timelineStartDayOffset, forKey: .timelineStartDayOffset)
    try values.encode(timelineStartDateLabel, forKey: .timelineStartDateLabel)
    try values.encode(chapters, forKey: .targetChapters)
    try values.encode(chapterWords, forKey: .chapterWords)
    try values.encode(chapterWords, forKey: .targetChapterWords)
    try values.encode(String(targetTotalWords), forKey: .totalWords)
    try values.encode(targetTotalWords, forKey: .targetTotalWords)
    try values.encode(volumeCount, forKey: .volumeCount)
    try values.encode(chapterWordTolerance, forKey: .chapterWordTolerance)
    try values.encode(chapterWordTolerance, forKey: .chapterWordTolerancePercent)
    try values.encode(premise, forKey: .premise)
    try values.encode(characters, forKey: .characters)
    try values.encode(protagonistProfile, forKey: .protagonistProfile)
    try values.encode(protagonistReviewed, forKey: .protagonistReviewed)
    try values.encode(worldbuilding, forKey: .worldbuilding)
    try values.encode(outline, forKey: .outline)
    try values.encode(volumePlan, forKey: .volumePlan)
    try values.encode(pacing, forKey: .pacing)
    try values.encode(style, forKey: .style)
    try values.encode(constraints, forKey: .constraints)
    try values.encode(LongFormConstraints.lines(from: constraints), forKey: .specialConstraints)
    try values.encodeIfPresent(creationGuide, forKey: .creationGuide)
  }

  private static func lossyPositiveInt(
    _ values: KeyedDecodingContainer<CodingKeys>,
    keys: [CodingKeys]
  ) -> Int? {
    for key in keys where values.contains(key) {
      let value = values.lossyInt(forKey: key)
      if value > 0 { return value }
    }
    return nil
  }

  private static func lossyNonnegativeInt(
    _ values: KeyedDecodingContainer<CodingKeys>,
    keys: [CodingKeys]
  ) -> Int? {
    for key in keys where values.contains(key) {
      let value = values.lossyInt(forKey: key, default: -1)
      if value >= 0 { return value }
    }
    return nil
  }

  private static func parseLegacyWordCount(_ text: String) -> Int? {
    let compact =
      text
      .replacingOccurrences(of: ",", with: "")
      .replacingOccurrences(of: "，", with: "")
      .replacingOccurrences(of: " ", with: "")
      .lowercased()
    guard !compact.isEmpty else { return nil }
    let numberText = compact.prefix { $0.isNumber || $0 == "." }
    guard let number = Double(String(numberText)), number > 0 else { return nil }
    let multiplier: Double
    if compact.contains("亿") {
      multiplier = 100_000_000
    } else if compact.contains("万") || compact.contains("w") {
      multiplier = 10_000
    } else {
      multiplier = 1
    }
    let result = number * multiplier
    guard result <= Double(Int.max) else { return nil }
    return Int(result.rounded())
  }
}

struct CreateBookDraftSnapshot: Codable, Equatable, Sendable {
  var request: CreateBookRequest
  var requirements: String
  var pendingCreationJobID: String?
  /// Workspace-owned copy of the selected original. Unlike a user file path, this
  /// id still resolves after a relaunch.
  var pendingSourceID: String?
  /// Book that was created but whose staged original has not yet been ingested.
  var pendingIngestionBookID: String?

  static let empty = CreateBookDraftSnapshot(
    request: CreateBookRequest(),
    requirements: "",
    pendingCreationJobID: nil,
    pendingSourceID: nil,
    pendingIngestionBookID: nil
  )
}

enum CreateBookDraftPersistence {
  private static let defaultsKey = "MacInkostomo.createBookDraft.v1"

  static func load(defaults: UserDefaults = .standard) -> CreateBookDraftSnapshot {
    guard let data = defaults.data(forKey: defaultsKey) else { return .empty }
    do {
      return try JSONDecoder().decode(CreateBookDraftSnapshot.self, from: data)
    } catch {
      defaults.removeObject(forKey: defaultsKey)
      return .empty
    }
  }

  static func saveDraft(
    request: CreateBookRequest,
    requirements: String,
    defaults: UserDefaults = .standard
  ) {
    var snapshot = load(defaults: defaults)
    snapshot.request = request
    snapshot.requirements = requirements
    save(snapshot, defaults: defaults)
  }

  static func markPending(
    jobID: String,
    request: CreateBookRequest,
    requirements: String,
    defaults: UserDefaults = .standard
  ) {
    var snapshot = load(defaults: defaults)
    snapshot.request = request
    snapshot.requirements = requirements
    snapshot.pendingCreationJobID = jobID
    save(snapshot, defaults: defaults)
  }

  static func savePendingSourceID(
    _ id: String?,
    defaults: UserDefaults = .standard
  ) {
    var snapshot = load(defaults: defaults)
    snapshot.pendingSourceID = id
    save(snapshot, defaults: defaults)
  }

  static func markPendingIngestion(
    bookID: String,
    sourceID: String,
    request: CreateBookRequest,
    requirements: String,
    defaults: UserDefaults = .standard
  ) {
    var snapshot = load(defaults: defaults)
    snapshot.request = request
    snapshot.requirements = requirements
    snapshot.pendingCreationJobID = nil
    snapshot.pendingIngestionBookID = bookID
    snapshot.pendingSourceID = sourceID
    save(snapshot, defaults: defaults)
  }

  @discardableResult
  static func reconcile(
    creationJobs: [CreationJob],
    defaults: UserDefaults = .standard
  ) -> CreateBookDraftSnapshot {
    var snapshot = load(defaults: defaults)
    guard let jobID = snapshot.pendingCreationJobID else { return snapshot }
    guard let job = creationJobs.first(where: { $0.jobId == jobID }) else {
      snapshot.pendingCreationJobID = nil
      save(snapshot, defaults: defaults)
      return snapshot
    }

    if job.status.lowercased() == "success" {
      snapshot.pendingCreationJobID = nil
      if snapshot.pendingSourceID == nil, snapshot.pendingIngestionBookID == nil {
        clear(defaults: defaults)
        return .empty
      }
      save(snapshot, defaults: defaults)
      return snapshot
    }
    if !job.isActive {
      snapshot.pendingCreationJobID = nil
      save(snapshot, defaults: defaults)
    }
    return snapshot
  }

  static func clear(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: defaultsKey)
  }

  private static func save(
    _ snapshot: CreateBookDraftSnapshot,
    defaults: UserDefaults
  ) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: defaultsKey)
  }
}

struct CreateBookResponse: Codable, Sendable {
  let message: String
  let status: String
  let jobId: String
  let title: String
  let bookId: String
}

struct CreateBookAssistRequest: Encodable, Sendable {
  let guide: CreateBookGuide
}

struct CreateBookAssistResponse: Codable, Sendable {
  let ok: Bool
  let model: String
  let baseUrl: String
  let guide: CreateBookGuide?
  let payload: CreateBookRequest
}
