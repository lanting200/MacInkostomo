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
    requireConsistencyDelta: Bool = false,
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
      Bool.self, forKey: .requireConsistencyDelta) ?? false
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

  private enum CodingKeys: String, CodingKey {
    case id, order, label, earliestChapter, latestChapter, immutable
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    order = try values.decode(Int.self, forKey: .order)
    label = try values.decode(String.self, forKey: .label)
    earliestChapter = try values.decode(Int.self, forKey: .earliestChapter)
    latestChapter = try values.decode(Int.self, forKey: .latestChapter)
    immutable = try values.decodeIfPresent(Bool.self, forKey: .immutable) ?? true
  }
}

struct LongFormHookPlan: Codable, Equatable, Sendable {
  let hookId: String
  let description: String
  let openFromChapter: Int
  let resolveByChapter: Int?
  let requiredVolumeNumber: Int?
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

struct CreateBookRequest: Codable, Equatable, Sendable {
  var title: String
  var language: String
  var genre: String
  var platform: String
  var targetChapters: Int
  var chapterWords: Int
  var totalWords: String
  var targetTotalWords: Int
  var volumeCount: Int
  var chapterWordTolerance: Int
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
    totalWords: String = "600000",
    targetTotalWords: Int = 600_000,
    volumeCount: Int = 6,
    chapterWordTolerance: Int = 15,
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
    self.targetTotalWords = targetTotalWords
    self.volumeCount = volumeCount
    self.chapterWordTolerance = chapterWordTolerance
    self.premise = premise
    self.characters = characters
    self.worldbuilding = worldbuilding
    self.outline = outline
    self.volumePlan = volumePlan
    self.pacing = pacing
    self.style = style
    self.constraints = constraints
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
    case targetTotalWords, totalWordCount, targetWords
    case targetChapterWords
    case volumeCount, targetVolumes
    case chapterWordTolerance, chapterWordTolerancePercent
    case premise, characters, worldbuilding, outline, volumePlan, pacing, style
    case constraints, specialConstraints
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    title = values.lossyString(forKey: .title)
    language = values.lossyString(forKey: .language, default: "zh")
    genre = values.lossyString(forKey: .genre, default: "xuanhuan")
    platform = values.lossyString(forKey: .platform, default: "tomato")
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
    synchronizeLongFormFields()
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    let chapters = derivedTargetChapters
    try values.encode(title, forKey: .title)
    try values.encode(language, forKey: .language)
    try values.encode(genre, forKey: .genre)
    try values.encode(platform, forKey: .platform)
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
    try values.encode(worldbuilding, forKey: .worldbuilding)
    try values.encode(outline, forKey: .outline)
    try values.encode(volumePlan, forKey: .volumePlan)
    try values.encode(pacing, forKey: .pacing)
    try values.encode(style, forKey: .style)
    try values.encode(constraints, forKey: .constraints)
    try values.encode(LongFormConstraints.lines(from: constraints), forKey: .specialConstraints)
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

  static let empty = CreateBookDraftSnapshot(
    request: CreateBookRequest(),
    requirements: "",
    pendingCreationJobID: nil
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
    save(
      CreateBookDraftSnapshot(
        request: request,
        requirements: requirements,
        pendingCreationJobID: jobID
      ),
      defaults: defaults
    )
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
      clear(defaults: defaults)
      return .empty
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
