import Foundation

/// Typed library facade used by the SwiftUI workspace. Each method calls the
/// native InkOSCore actor directly.
final class InkOSLibrary: @unchecked Sendable {
  static let shared = InkOSLibrary(core: .shared)

  static let defaultTimeout: TimeInterval = 30
  static let longRequestTimeout: TimeInterval = 60
  static let fanqieTimeout: TimeInterval = 620

  private let core: InkOSCore

  init(core: InkOSCore = .shared) {
    self.core = core
  }

  func fetchBooks() async throws -> [BookSummary] {
    try await core.fetchBooks()
  }

  func fetchAvailableBooks() async throws -> [String] {
    try await core.fetchAvailableBooks()
  }

  func fetchChapters(bookID: String) async throws -> ChapterListResponse {
    try await core.fetchChapters(bookID: bookID)
  }

  func fetchChapter(bookID: String, number: Int) async throws -> ChapterDetail {
    try await core.fetchChapter(bookID: bookID, number: number)
  }

  func approveChapter(bookID: String, number: Int) async throws -> ChapterDetail {
    try await core.approveChapter(bookID: bookID, number: number)
  }

  func reviseChapter(
    bookID: String,
    number: Int,
    note: String,
    mode: String
  ) async throws -> ProcessingResponse {
    try await core.reviseChapter(bookID: bookID, number: number, note: note, mode: mode)
  }

  func generateChapter(bookID: String, guidance: String?) async throws -> ProcessingResponse {
    try await core.generateChapter(bookID: bookID, guidance: guidance)
  }

  func fetchGenerationJob(bookID: String, chapterNumber: Int) async throws -> GenerationJobResponse {
    try await core.fetchGenerationJob(bookID: bookID, chapterNumber: chapterNumber)
  }

  func importBook(id: String) async throws -> ImportBookResponse {
    try await core.importBook(id: id)
  }

  func createBook(_ input: CreateBookRequest) async throws -> CreateBookResponse {
    try await core.createBook(input)
  }

  func assistCreateBook(guide: CreateBookGuide) async throws -> CreateBookAssistResponse {
    try await core.assistCreateBook(guide: guide)
  }

  func generateFanqieAbstract(
    bookID: String,
    source: String,
    protagonistNames: [String]
  ) async throws -> String {
    try await core.generateFanqieAbstract(
      bookID: bookID,
      source: source,
      protagonistNames: protagonistNames
    )
  }

  func fetchCreationJob(id: String) async throws -> CreationJob {
    try await core.fetchCreationJob(id: id)
  }

  func deleteBook(id: String) async throws -> DeleteBookResponse {
    try await core.deleteBook(id: id)
  }

  func fetchWorkflowJobs() async throws -> WorkflowJobsResponse {
    try await core.fetchWorkflowJobs()
  }

  func fetchDebugEvents(limit: Int = 300) async throws -> DebugEventsResponse {
    try await core.fetchDebugEvents(limit: limit)
  }

  func fetchInkOSConfig() async throws -> InkOSConfig {
    try await core.fetchInkOSConfig()
  }

  func updateInkOSConfig(_ input: InkOSConfigUpdate) async throws -> InkOSConfigApplyResponse {
    try await core.updateInkOSConfig(input)
  }

  func fetchModels(_ endpoint: ModelEndpointRequest) async throws -> ModelCatalogResponse {
    try await core.fetchModels(endpoint)
  }

  func testModel(_ input: ModelTestRequest) async throws -> ModelTestResponse {
    try await core.testModel(input)
  }

  func fetchBookSettings(bookID: String) async throws -> BookSettingsResponse {
    try await core.fetchBookSettings(bookID: bookID)
  }

  func fetchBookSetting(bookID: String, path: String) async throws -> String {
    try await core.fetchBookSetting(bookID: bookID, path: path)
  }

  func saveBookSetting(bookID: String, path: String, content: String) async throws -> BookSettingSaveResponse {
    try await core.saveBookSetting(bookID: bookID, path: path, content: content)
  }

  func fetchBookSettingsBackups(bookID: String) async throws -> BookSettingsBackupsResponse {
    try await core.fetchBookSettingsBackups(bookID: bookID)
  }

  func restoreBookSettings(bookID: String, backupID: String) async throws -> BookSettingsRestoreResponse {
    try await core.restoreBookSettings(bookID: bookID, backupID: backupID)
  }

  func fetchLongFormPlan(bookID: String) async throws -> LongFormPlanResponse {
    try await core.fetchLongFormPlan(bookID: bookID)
  }

  func fetchChapterBeats(bookID: String) async throws -> ChapterBeatPlan {
    try await core.fetchChapterBeats(bookID: bookID)
  }

  func invalidateChapterBeats(bookID: String, fromChapter: Int) async throws -> ChapterBeatPlan {
    try await core.invalidateChapterBeats(bookID: bookID, fromChapter: fromChapter)
  }

  func updateLongFormPlan(
    bookID: String,
    expectedRevision: Int?,
    constraints: LongFormConstraints? = nil,
    continuity: LongFormContinuity? = nil
  ) async throws -> LongFormPlanResponse {
    try await core.updateLongFormPlan(
      bookID: bookID,
      expectedRevision: expectedRevision,
      constraints: constraints,
      continuity: continuity
    )
  }

  // MARK: Derivative (同人) source retrieval

  func importDerivativeSource(
    bookID: String,
    from fileURL: URL,
    onProgress: (@Sendable (SourceImportProgress) async -> Void)? = nil
  ) async throws -> SourceManifest {
    try await core.importDerivativeSource(
      bookID: bookID,
      from: fileURL,
      onProgress: onProgress
    )
  }

  func stagePendingDerivativeSource(from fileURL: URL) async throws -> PendingDerivativeSource {
    try await core.stagePendingDerivativeSource(from: fileURL)
  }

  func loadPendingDerivativeSource(id: String) async throws -> PendingDerivativeSource {
    try await core.loadPendingDerivativeSource(id: id)
  }

  func pendingDerivativeSourceFileURL(id: String) async throws -> URL {
    try await core.pendingDerivativeSourceFileURL(id: id)
  }

  func removePendingDerivativeSource(id: String) async throws {
    try await core.removePendingDerivativeSource(id: id)
  }

  func derivativeSourceSummary(bookID: String) async throws -> DerivativeSourceSummary {
    try await core.derivativeSourceSummary(bookID: bookID)
  }

  func embedDerivativeSource(
    bookID: String,
    onProgress: (@Sendable (SourceEmbeddingStatus) async -> Void)? = nil
  ) async throws -> SourceEmbeddingStatus {
    try await core.embedDerivativeSource(bookID: bookID, onProgress: onProgress)
  }

  func derivativeSourceEmbeddingStatus(bookID: String) async throws -> SourceEmbeddingStatus {
    try await core.derivativeSourceEmbeddingStatus(bookID: bookID)
  }

  func retrieveDerivativeContext(
    bookID: String,
    keys: [String],
    query: String? = nil,
    limit: Int = 8
  ) async throws -> [SourceRetrievalHit] {
    try await core.retrieveDerivativeContext(
      bookID: bookID,
      keys: keys,
      query: query,
      limit: limit
    )
  }

  // MARK: Derivative (同人) canon extraction

  /// Runs canon extraction over the imported original. `maxBatches` caps the model
  /// calls one invocation makes so the UI can extract incrementally; the pass is
  /// checkpointed and a later call resumes where this one stopped.
  func extractDerivativeCanon(
    bookID: String,
    maxBatches: Int = 0,
    onProgress: (@Sendable (SourceCanonStatus) async -> Void)? = nil
  ) async throws -> SourceCanonStatus {
    try await core.extractDerivativeCanon(
      bookID: bookID,
      maxBatches: maxBatches,
      onProgress: onProgress
    )
  }

  func extractDerivativeSettingsOverlay(
    bookID: String,
    settingsText: String
  ) async throws -> SourceCanonStatus {
    try await core.extractDerivativeSettingsOverlay(
      bookID: bookID,
      settingsText: settingsText
    )
  }

  func derivativeCanonStatus(bookID: String) async throws -> SourceCanonStatus {
    try await core.derivativeCanonStatus(bookID: bookID)
  }

  @discardableResult
  func saveDerivativePreparationIntent(
    bookID: String,
    settingsText: String,
    embedRequested: Bool
  ) async throws -> DerivativePreparationIntent {
    try await core.saveDerivativePreparationIntent(
      bookID: bookID,
      settingsText: settingsText,
      embedRequested: embedRequested
    )
  }

  func derivativePreparationSnapshot(bookID: String) async throws -> DerivativePreparationSnapshot {
    try await core.derivativePreparationSnapshot(bookID: bookID)
  }

  // MARK: Derivative (同人) story clock

  func derivativeTimeline(bookID: String) async throws -> DerivativeTimeline {
    try await core.loadDerivativeTimeline(bookID: bookID)
  }

  @discardableResult
  func saveDerivativeTimeline(
    bookID: String,
    _ timeline: DerivativeTimeline
  ) async throws -> DerivativeTimeline {
    try await core.saveDerivativeTimeline(bookID: bookID, timeline)
  }

  /// Where a chapter sits on the original's clock, and which canon events are
  /// therefore behind it, ahead of it, or unplaced.
  func derivativeTimelineStatus(
    bookID: String,
    chapterNumber: Int
  ) async throws -> DerivativeTimelineStatus {
    try await core.derivativeTimelineStatus(bookID: bookID, chapterNumber: chapterNumber)
  }

  func bookKind(bookID: String) async throws -> BookKind {
    try await core.bookKind(bookID: bookID)
  }

  func fetchFanqieLoginState() async throws -> FanqieLoginState {
    try await core.fetchFanqieLoginState()
  }

  func saveFanqieCookies(_ cookies: [FanqieCookie]) async throws -> FanqieAccount {
    try await core.saveFanqieCookies(cookies)
  }

  func fetchFanqieAccount() async throws -> FanqieAccount {
    try await core.fetchFanqieAccount()
  }

  func fetchFanqieBooks() async throws -> FanqieBooksResponse {
    try await core.fetchFanqieBooks()
  }

  func fetchFanqieChapters(bookID: String, title: String) async throws -> FanqieChaptersResponse {
    try await core.fetchFanqieChapters(bookID: bookID, title: title)
  }

  func fetchFanqieChapterContent(bookID: String, chapterID: String) async throws -> FanqieChapterContent {
    try await core.fetchFanqieChapterContent(bookID: bookID, chapterID: chapterID)
  }

  func logoutFanqie() async throws -> FanqieLogoutResponse {
    try await core.logoutFanqie()
  }

  func fetchFanqieLoginURL() async throws -> FanqieLoginURLResponse {
    try await core.fetchFanqieLoginURL()
  }

  func fetchFanqieCategories(gender: Int) async throws -> [FanqieCategory] {
    try await core.fetchFanqieCategories(gender: gender)
  }

  func createFanqieBook(_ input: FanqieCreateBookInput) async throws -> FanqieMutationResponse {
    try await core.createFanqieBook(input)
  }

  func publishFanqieChapter(_ input: FanqieChapterTransferInput) async throws -> FanqieMutationResponse {
    try await core.publishFanqieChapter(input)
  }

  func replaceFanqieChapter(_ input: FanqieChapterTransferInput) async throws -> FanqieMutationResponse {
    try await core.replaceFanqieChapter(input)
  }
}
