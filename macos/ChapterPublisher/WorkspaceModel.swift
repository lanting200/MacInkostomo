import Combine
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
  @Published var section: WorkspaceSection = .library

  @Published private(set) var books: [BookSummary] = []
  @Published private(set) var availableBooks: [String] = []
  @Published private(set) var currentBookID: String?
  @Published private(set) var chapterContext: ChapterListResponse?
  @Published private(set) var chapters: [ChapterSummary] = []
  @Published private(set) var currentChapterNumber: Int?
  @Published private(set) var currentChapter: ChapterDetail?

  @Published private(set) var inkOSConfig: InkOSConfig?
  @Published private(set) var workflowJobs: WorkflowJobsResponse?
  @Published private(set) var debugEvents: [DebugEvent] = []

  @Published private(set) var bookSettings: BookSettingsResponse?
  @Published private(set) var selectedSettingPath: String?
  @Published var selectedSettingContent = ""
  @Published private(set) var longFormPlan: LongFormPlanResponse?
  @Published private(set) var isLongFormPlanUnavailable = false

  @Published private(set) var fanqieLogin: FanqieLoginState?
  @Published private(set) var fanqieAccount: FanqieAccount?
  @Published private(set) var fanqieBooks: [FanqieBook] = []
  @Published private(set) var selectedFanqieBookID: String?
  @Published private(set) var fanqieChapters: [FanqieChapter] = []
  @Published private(set) var fanqieChapterContent: FanqieChapterContent?

  @Published private(set) var isLoading = false
  @Published private(set) var isMutating = false
  @Published var errorMessage: String?

  /// Progress of the derivative preparation pass: import, canon extraction, and
  /// embedding of an uploaded original.
  ///
  /// Held here rather than in the create sheet because the pass outlives the sheet —
  /// extracting canon from a multi-million-character novel is hundreds of model
  /// calls, and the customer must be able to close the dialog and watch it from the
  /// library. `nil` means no pass has run this launch.
  @Published private(set) var derivativePreparation: DerivativePreparationState?

  var currentBook: BookSummary? {
    guard let currentBookID else { return nil }
    return books.first { $0.id == currentBookID }
  }

  var selectedSettingFile: BookSettingFile? {
    guard let selectedSettingPath else { return nil }
    return bookSettings?.files.first { $0.path == selectedSettingPath }
  }

  var selectedFanqieBook: FanqieBook? {
    guard let selectedFanqieBookID else { return nil }
    return fanqieBooks.first { $0.bookId == selectedFanqieBookID }
  }

  var activeGenerationJobs: [GenerationJob] {
    workflowJobs?.generationJobs.filter(\.isActive) ?? []
  }

  var activeCreationJobs: [CreationJob] {
    workflowJobs?.creationJobs.filter(\.isActive) ?? []
  }

  var isBusy: Bool { isLoading || isMutating }

  private let inkOS: InkOSLibrary
  private var loadingCount = 0
  private var mutationCount = 0

  private var booksToken = UUID()
  private var availableBooksToken = UUID()
  private var chaptersToken = UUID()
  private var chapterToken = UUID()
  private var activityToken = UUID()
  private var configToken = UUID()
  private var settingsToken = UUID()
  private var settingContentToken = UUID()
  private var longFormPlanToken = UUID()
  private var fanqieToken = UUID()
  private var fanqieChaptersToken = UUID()
  private var fanqieContentToken = UUID()
  private var generationWorkflowTask: Task<Void, Never>?
  private var creationPollingTasks: [String: Task<Void, Never>] = [:]

  init(inkOS: InkOSLibrary = .shared) {
    self.inkOS = inkOS
  }

  func bootstrap() async {
    clearError()
    await refreshBooks()
    await restoreIncompleteDerivativePreparation()
    await loadInkOSConfig()
    await refreshActivity()
  }

  func selectSection(_ newSection: WorkspaceSection) async {
    if section != newSection {
      invalidateRequests(for: section)
    }
    section = newSection
    clearError()
    switch newSection {
    case .library:
      await refreshBooks()
    case .chapters:
      if currentBookID == nil {
        await refreshBooks()
      } else {
        await refreshChapters()
      }
    case .fanqie:
      await refreshFanqie()
    case .settings:
      await loadInkOSConfig()
      await loadBookSettings()
      await loadLongFormPlan()
    case .activity:
      await refreshActivity()
    }
  }

  func clearError() {
    errorMessage = nil
  }

  // MARK: - Books and chapters

  func refreshBooks() async {
    let token = UUID()
    booksToken = token
    beginLoading()
    defer { endLoading() }

    do {
      let response = try await inkOS.fetchBooks()
      guard booksToken == token else { return }
      let previousID = currentBookID
      books = response
      let nextID =
        previousID.flatMap { id in response.contains { $0.id == id } ? id : nil }
        ?? response.first?.id

      if nextID != previousID {
        await selectBook(nextID)
      } else if nextID != nil, chapters.isEmpty {
        await refreshChapters()
      }
    } catch is CancellationError {
      return
    } catch {
      guard booksToken == token else { return }
      setError(error)
    }
  }

  func refreshAvailableBooks() async {
    let token = UUID()
    availableBooksToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchAvailableBooks()
      guard availableBooksToken == token else { return }
      availableBooks = response.filter { candidate in
        !books.contains { $0.id == candidate }
      }
    } catch is CancellationError {
      return
    } catch {
      guard availableBooksToken == token else { return }
      setError(error)
    }
  }

  func selectBook(_ id: String?) async {
    guard id == nil || books.contains(where: { $0.id == id }) else {
      errorMessage = "选择的书籍已不存在"
      return
    }
    if currentBookID != id {
      currentBookID = id
      invalidateBookDependentRequests()
      chapterContext = nil
      chapters = []
      currentChapterNumber = nil
      currentChapter = nil
      bookSettings = nil
      selectedSettingPath = nil
      selectedSettingContent = ""
      longFormPlan = nil
      isLongFormPlanUnavailable = false
    }
    guard id != nil else { return }
    await refreshChapters()
    if section == .settings {
      await loadBookSettings()
      await loadLongFormPlan()
    }
  }

  func refreshChapters() async {
    guard let bookID = currentBookID else {
      chapterContext = nil
      chapters = []
      currentChapterNumber = nil
      currentChapter = nil
      return
    }

    let token = UUID()
    chaptersToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchChapters(bookID: bookID)
      guard chaptersToken == token, currentBookID == bookID else { return }
      chapterContext = response
      chapters = response.chapters

      let nextNumber: Int? = {
        if let currentChapterNumber,
          response.chapters.contains(where: { $0.number == currentChapterNumber })
        {
          return currentChapterNumber
        }
        return response.chapters.first(where: { chapter in
          [
            "ready-for-review", "pending_review", "revision_failed", "audit-failed",
            "state-degraded",
          ].contains(chapter.status)
        })?.number ?? response.chapters.first?.number
      }()
      await selectChapter(nextNumber)
    } catch is CancellationError {
      return
    } catch {
      guard chaptersToken == token, currentBookID == bookID else { return }
      setError(error)
    }
  }

  func selectChapter(_ number: Int?) async {
    // A direct selection supersedes any enclosing list refresh that has not
    // committed yet. refreshChapters calls this only after its final commit.
    chaptersToken = UUID()
    guard let bookID = currentBookID, let number else {
      chapterToken = UUID()
      currentChapterNumber = nil
      currentChapter = nil
      return
    }
    guard chapters.contains(where: { $0.number == number }) else {
      errorMessage = "选择的章节已不存在"
      return
    }

    currentChapterNumber = number
    currentChapter = nil
    let token = UUID()
    chapterToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchChapter(bookID: bookID, number: number)
      guard chapterToken == token,
        currentBookID == bookID,
        currentChapterNumber == number
      else { return }
      currentChapter = response
    } catch is CancellationError {
      return
    } catch {
      guard chapterToken == token,
        currentBookID == bookID,
        currentChapterNumber == number
      else { return }
      setError(error)
    }
  }

  @discardableResult
  func approveCurrentChapter() async -> ChapterDetail? {
    guard let bookID = currentBookID, let number = currentChapterNumber else {
      errorMessage = "请先选择章节"
      return nil
    }
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.approveChapter(bookID: bookID, number: number)
      if currentBookID == bookID, currentChapterNumber == number {
        currentChapter = response
      }
      await refreshChapters()
      await refreshBooks()
      await loadLongFormPlan()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  @discardableResult
  func rejectCurrentChapter(note: String, mode: String = "rewrite") async -> ProcessingResponse? {
    guard let bookID = currentBookID, let number = currentChapterNumber else {
      errorMessage = "请先选择章节"
      return nil
    }
    let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedNote.isEmpty else {
      errorMessage = "请填写修改意见"
      return nil
    }
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.reviseChapter(
        bookID: bookID,
        number: number,
        note: trimmedNote,
        mode: mode
      )
      await refreshActivity()
      startGenerationWorkflowTracking()
      await refreshChapters()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  @discardableResult
  func generateNextChapter(guidance: String = "") async -> ProcessingResponse? {
    guard let bookID = currentBookID else {
      errorMessage = "请先选择书籍"
      return nil
    }
    let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.generateChapter(
        bookID: bookID,
        guidance: trimmed.isEmpty ? nil : trimmed
      )
      await refreshActivity()
      startGenerationWorkflowTracking()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  @discardableResult
  func createBook(
    _ request: CreateBookRequest,
    requirements: String = ""
  ) async -> CreateBookResponse? {
    let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      errorMessage = "请填写书名"
      return nil
    }
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.createBook(request)
      CreateBookDraftPersistence.markPending(
        jobID: response.jobId,
        request: request,
        requirements: requirements
      )
      startCreationJobPolling(response.jobId)
      await refreshActivity()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  @discardableResult
  func assistCreateBook(guide: CreateBookGuide) async -> CreateBookAssistResponse? {
    beginMutation()
    defer { endMutation() }
    do {
      return try await inkOS.assistCreateBook(guide: guide)
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  // MARK: Derivative (同人) preparation

  /// Ingests an uploaded original and turns it into canon the pipeline can obey.
  ///
  /// Runs after the book exists, not before: canon is merged into the book's
  /// continuity projection, and the projection is rebuilt from `long-form-plan.json`,
  /// which only exists once the book has been created. The customer-facing order is
  /// unchanged — they attach the file while creating the book and this runs
  /// immediately after — but nothing here can be hoisted ahead of creation.
  ///
  /// `maxCanonBatches` bounds the model calls one invocation makes. Zero means run to
  /// completion, which for a full-length novel is hundreds of calls; the pass is
  /// checkpointed per batch, so a bounded run followed by a resume reaches the same
  /// place. `settingsText` goes into `manualOverlay`, which is applied last, so the
  /// customer's settings outrank the source wherever the two disagree.
  func prepareDerivativeSource(
    bookID: String,
    bookTitle: String,
    sourceURL: URL,
    settingsText: String = "",
    maxCanonBatches: Int = 0,
    embed: Bool = true
  ) async {
    var state = DerivativePreparationState(
      bookID: bookID,
      bookTitle: bookTitle,
      phase: "正在读取原著文件",
      isRunning: true,
      sourceChapterCount: 0,
      canonChaptersDone: 0,
      canonComplete: false,
      entityCount: 0,
      timelineCount: 0,
      embeddedPassages: 0,
      totalPassages: 0,
      failure: nil
    )
    derivativePreparation = state

    do {
      let manifest = try await inkOS.importDerivativeSource(bookID: bookID, from: sourceURL)
      let settings = settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try await inkOS.saveDerivativePreparationIntent(
        bookID: bookID,
        settingsText: settings,
        embedRequested: embed
      )
      state.sourceChapterCount = manifest.chapterCount
      state.overlayComplete = settings.isEmpty
      state.embedRequested = embed
      state.embeddingComplete = !embed
      state.phase = "原著已切分 \(manifest.chapterCount) 章，正在抽取原著设定"
      derivativePreparation = state

      let canon = try await inkOS.extractDerivativeCanon(
        bookID: bookID,
        maxBatches: maxCanonBatches
      )
      state.canonChaptersDone = canon.extractedChapters
      state.canonComplete = canon.isComplete
      state.entityCount = canon.entityCount
      state.timelineCount = canon.timelineCount
      state.phase = canon.isComplete
        ? "原著设定抽取完成"
        : "已抽取原著前 \(canon.extractedChapters) 章设定，可继续抽取"
      derivativePreparation = state

      if !settings.isEmpty {
        state.phase = "正在把你的设定登记为最高优先级"
        derivativePreparation = state
        let overlay = try await inkOS.extractDerivativeSettingsOverlay(
          bookID: bookID,
          settingsText: settings
        )
        state.entityCount = overlay.entityCount
        state.timelineCount = overlay.timelineCount
        state.overlayComplete = true
      }

      if embed {
        state.phase = "正在建立语义检索索引"
        derivativePreparation = state
        // Non-fatal by design: retrieval is lexical-first and works without
        // vectors. An unavailable on-device embedding model must not cost the
        // customer the canon extraction that just succeeded.
        do {
          let embedding = try await inkOS.embedDerivativeSource(bookID: bookID)
          state.embeddedPassages = embedding.embedded
          state.totalPassages = embedding.total
          state.embeddingComplete = !embedding.semanticAvailable || embedding.isComplete
        } catch {
          state.embeddingComplete = false
          state.failure = "语义索引未完成（关键词检索仍可用）：\(errorText(error))"
        }
      }

      state.isRunning = false
      state.phase = state.isComplete ? "原著准备完成" : "原著准备已暂停，可继续处理"
      derivativePreparation = state
      await refreshWorkspaceAfterWorkflowCompletion()
    } catch is CancellationError {
      state.isRunning = false
      state.phase = "原著准备已取消"
      derivativePreparation = state
    } catch {
      state.isRunning = false
      state.phase = "原著准备失败"
      state.failure = errorText(error)
      derivativePreparation = state
      setError(error)
    }
  }

  /// Continues every checkpointed preparation phase, including an overlay or
  /// semantic index that failed after canon extraction had already completed.
  func resumeDerivativePreparation(bookID: String, bookTitle: String, maxBatches: Int = 0) async {
    var state = derivativePreparation ?? DerivativePreparationState(
      bookID: bookID,
      bookTitle: bookTitle,
      phase: "",
      isRunning: false,
      sourceChapterCount: 0,
      canonChaptersDone: 0,
      canonComplete: false,
      entityCount: 0,
      timelineCount: 0,
      embeddedPassages: 0,
      totalPassages: 0,
      failure: nil
    )
    state.bookID = bookID
    state.bookTitle = bookTitle
    state.isRunning = true
    state.failure = nil
    state.phase = "正在读取原著准备进度"
    derivativePreparation = state
    do {
      let snapshot = try await inkOS.derivativePreparationSnapshot(bookID: bookID)
      state.sourceChapterCount = snapshot.canon.chapterCount
      state.canonChaptersDone = snapshot.canon.extractedChapters
      state.canonComplete = snapshot.canon.isComplete
      state.entityCount = snapshot.canon.entityCount
      state.timelineCount = snapshot.canon.timelineCount
      state.overlayComplete = snapshot.overlayComplete
      state.embedRequested = snapshot.intent.embedRequested
      state.embeddingComplete = snapshot.embeddingComplete
      state.embeddedPassages = snapshot.embedding.embedded
      state.totalPassages = snapshot.embedding.total

      state.phase = "正在继续抽取原著设定"
      derivativePreparation = state
      let canon = try await inkOS.extractDerivativeCanon(bookID: bookID, maxBatches: maxBatches)
      state.sourceChapterCount = canon.chapterCount
      state.canonChaptersDone = canon.extractedChapters
      state.canonComplete = canon.isComplete
      state.entityCount = canon.entityCount
      state.timelineCount = canon.timelineCount

      let settings = snapshot.intent.settingsText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !settings.isEmpty, !state.overlayComplete {
        state.phase = "正在把你的设定登记为最高优先级"
        derivativePreparation = state
        let overlay = try await inkOS.extractDerivativeSettingsOverlay(
          bookID: bookID,
          settingsText: settings
        )
        state.entityCount = overlay.entityCount
        state.timelineCount = overlay.timelineCount
        state.overlayComplete = true
      }

      if state.embedRequested, !state.embeddingComplete {
        state.phase = "正在建立语义检索索引"
        derivativePreparation = state
        do {
          let embedding = try await inkOS.embedDerivativeSource(bookID: bookID)
          state.embeddedPassages = embedding.embedded
          state.totalPassages = embedding.total
          state.embeddingComplete = !embedding.semanticAvailable || embedding.isComplete
        } catch {
          state.embeddingComplete = false
          state.failure = "语义索引未完成（关键词检索仍可用）：\(errorText(error))"
        }
      }

      state.isRunning = false
      state.phase = state.isComplete
        ? "原著准备完成"
        : "原著准备已暂停，可继续处理"
      derivativePreparation = state
      await refreshWorkspaceAfterWorkflowCompletion()
    } catch is CancellationError {
      state.isRunning = false
      state.phase = "抽取已取消"
      derivativePreparation = state
    } catch {
      state.isRunning = false
      state.phase = "抽取失败"
      state.failure = errorText(error)
      derivativePreparation = state
      setError(error)
    }
  }

  /// Restores the first unfinished source-preparation job after an app relaunch.
  /// The source, author settings and embedding intent all live in the book workspace,
  /// so this is a read-only scan and does not resume model calls automatically.
  private func restoreIncompleteDerivativePreparation() async {
    guard derivativePreparation?.isRunning != true else { return }
    for book in books {
      guard (try? await inkOS.bookKind(bookID: book.id)) == .derivative,
        let snapshot = try? await inkOS.derivativePreparationSnapshot(bookID: book.id),
        !snapshot.isComplete
      else { continue }

      derivativePreparation = DerivativePreparationState(
        bookID: book.id,
        bookTitle: book.title,
        phase: "原著准备未完成，可继续处理",
        isRunning: false,
        sourceChapterCount: snapshot.canon.chapterCount,
        canonChaptersDone: snapshot.canon.extractedChapters,
        canonComplete: snapshot.canon.isComplete,
        entityCount: snapshot.canon.entityCount,
        timelineCount: snapshot.canon.timelineCount,
        overlayComplete: snapshot.overlayComplete,
        embedRequested: snapshot.intent.embedRequested,
        embeddingComplete: snapshot.embeddingComplete,
        embeddedPassages: snapshot.embedding.embedded,
        totalPassages: snapshot.embedding.total,
        failure: nil
      )
      return
    }
  }

  func clearDerivativePreparation() {
    guard derivativePreparation?.isRunning != true else { return }
    derivativePreparation = nil
  }

  @discardableResult
  func pollCreationJob(
    _ jobID: String,
    interval: TimeInterval = 2,
    maxAttempts: Int = 450
  ) async -> CreationJob? {
    for _ in 0..<maxAttempts {
      do {
        let job = try await inkOS.fetchCreationJob(id: jobID)
        if !job.isActive {
          CreateBookDraftPersistence.reconcile(creationJobs: [job])
          await refreshActivity()
          await refreshWorkspaceAfterWorkflowCompletion()
          return job
        }
      } catch is CancellationError {
        return nil
      } catch {
        setError(error)
        return nil
      }
      do {
        try await Task.sleep(nanoseconds: UInt64(max(0.2, interval) * 1_000_000_000))
      } catch {
        return nil
      }
    }
    errorMessage = "创建任务等待超时，可在任务视图继续查看"
    return nil
  }

  @discardableResult
  func deleteBook(_ id: String) async -> DeleteBookResponse? {
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.deleteBook(id: id)
      if currentBookID == id {
        currentBookID = nil
        invalidateBookDependentRequests()
        chapterContext = nil
        chapters = []
        currentChapterNumber = nil
        currentChapter = nil
        bookSettings = nil
        selectedSettingPath = nil
        selectedSettingContent = ""
      }
      await refreshBooks()
      await refreshAvailableBooks()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  @discardableResult
  func importBook(_ id: String) async -> ImportBookResponse? {
    let selectionAtStart = currentBookID
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.importBook(id: id)
      await refreshBooks()
      await refreshAvailableBooks()
      if currentBookID == selectionAtStart || currentBookID == nil {
        await selectBook(response.bookId)
      }
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  // MARK: - Jobs

  func refreshActivity() async {
    let token = UUID()
    activityToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let jobs = try await inkOS.fetchWorkflowJobs()
      guard activityToken == token else { return }
      CreateBookDraftPersistence.reconcile(creationJobs: jobs.creationJobs)
      workflowJobs = jobs
      resumeWorkflowTrackingFromSnapshot()
      let events = try await inkOS.fetchDebugEvents(limit: 300)
      guard activityToken == token else { return }
      debugEvents = events.events
    } catch is CancellationError {
      return
    } catch {
      guard activityToken == token else { return }
      setError(error)
    }
  }

  func refreshWorkflowJobs() async {
    let token = UUID()
    activityToken = token
    do {
      let jobs = try await inkOS.fetchWorkflowJobs()
      guard activityToken == token else { return }
      CreateBookDraftPersistence.reconcile(creationJobs: jobs.creationJobs)
      workflowJobs = jobs
      resumeWorkflowTrackingFromSnapshot()
    } catch is CancellationError {
      return
    } catch {
      guard activityToken == token else { return }
      setError(error)
    }
  }

  func generationJob(bookID: String, chapterNumber: Int) async -> GenerationJob? {
    do {
      return try await inkOS.fetchGenerationJob(bookID: bookID, chapterNumber: chapterNumber).job
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  private func resumeWorkflowTrackingFromSnapshot() {
    for job in activeCreationJobs {
      startCreationJobPolling(job.jobId)
    }
    if !activeGenerationJobs.isEmpty {
      startGenerationWorkflowTracking()
    }
  }

  private func startCreationJobPolling(_ jobID: String) {
    guard creationPollingTasks[jobID] == nil else { return }
    creationPollingTasks[jobID] = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        if await self.pollCreationJob(jobID) != nil { break }
        do {
          try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
          break
        }
        await self.refreshWorkflowJobs()
        if !self.activeCreationJobs.contains(where: { $0.jobId == jobID }) { break }
      }
      self.creationPollingTasks[jobID] = nil
    }
  }

  private func startGenerationWorkflowTracking() {
    guard generationWorkflowTask == nil else { return }
    generationWorkflowTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.trackGenerationWorkflows()
    }
  }

  private func trackGenerationWorkflows() async {
    var previousActiveJobIDs = Set(activeGenerationJobs.map(\.id))
    var observedActiveJob = !previousActiveJobIDs.isEmpty
    var emptyPollCount = 0

    while !Task.isCancelled {
      do {
        try await Task.sleep(nanoseconds: 2_000_000_000)
      } catch {
        break
      }

      await refreshWorkflowJobs()
      let currentActiveJobIDs = Set(activeGenerationJobs.map(\.id))
      if !previousActiveJobIDs.subtracting(currentActiveJobIDs).isEmpty {
        await refreshWorkspaceAfterWorkflowCompletion()
      }
      previousActiveJobIDs = currentActiveJobIDs

      if currentActiveJobIDs.isEmpty {
        if observedActiveJob {
          break
        }
        emptyPollCount += 1
        if emptyPollCount >= 5 {
          await refreshWorkspaceAfterWorkflowCompletion()
          break
        }
      } else {
        observedActiveJob = true
        emptyPollCount = 0
      }
    }

    generationWorkflowTask = nil
    if !activeGenerationJobs.isEmpty {
      startGenerationWorkflowTracking()
    }
  }

  private func refreshWorkspaceAfterWorkflowCompletion() async {
    let selectedBookID = currentBookID
    await refreshBooks()
    guard currentBookID == selectedBookID, selectedBookID != nil else { return }
    await refreshChapters()
  }

  // MARK: - InkOS configuration

  func loadInkOSConfig() async {
    let token = UUID()
    configToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchInkOSConfig()
      guard configToken == token else { return }
      inkOSConfig = response
    } catch is CancellationError {
      return
    } catch {
      guard configToken == token else { return }
      setError(error)
    }
  }

  @discardableResult
  func saveInkOSConfig(_ update: InkOSConfigUpdate) async -> InkOSConfigApplyResponse? {
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.updateInkOSConfig(update)
      await loadInkOSConfig()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  func loadModels(
    role: ModelRole,
    baseURL: String? = nil,
    apiKey: String = ""
  ) async -> [RemoteModel] {
    do {
      let request = ModelEndpointRequest(role: role, baseUrl: normalized(baseURL), apiKey: apiKey)
      return try await inkOS.fetchModels(request).models
    } catch is CancellationError {
      return []
    } catch {
      setError(error)
      return []
    }
  }

  func testModel(
    role: ModelRole,
    model: String,
    baseURL: String? = nil,
    apiKey: String = ""
  ) async -> ModelTestResponse? {
    do {
      let request = ModelTestRequest(
        role: role,
        model: model,
        baseUrl: normalized(baseURL),
        apiKey: apiKey
      )
      return try await inkOS.testModel(request)
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  // MARK: - Book settings

  func loadBookSettings() async {
    guard let bookID = currentBookID else {
      bookSettings = nil
      selectedSettingPath = nil
      selectedSettingContent = ""
      return
    }
    let token = UUID()
    settingsToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchBookSettings(bookID: bookID)
      guard settingsToken == token, currentBookID == bookID else { return }
      bookSettings = response
      let nextPath =
        selectedSettingPath.flatMap { selected in
          response.files.contains { $0.path == selected } ? selected : nil
        } ?? response.files.first?.path
      await selectBookSetting(nextPath)
    } catch is CancellationError {
      return
    } catch {
      guard settingsToken == token, currentBookID == bookID else { return }
      setError(error)
    }
  }

  func selectBookSetting(_ path: String?) async {
    // Prevent a slower settings-index request from restoring an older file
    // selection after the user has already chosen a file.
    settingsToken = UUID()
    guard let bookID = currentBookID, let path else {
      settingContentToken = UUID()
      selectedSettingPath = nil
      selectedSettingContent = ""
      return
    }
    guard bookSettings?.files.contains(where: { $0.path == path }) == true else {
      errorMessage = "选择的设定文件已不存在"
      return
    }
    selectedSettingPath = path
    selectedSettingContent = ""
    let token = UUID()
    settingContentToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let content = try await inkOS.fetchBookSetting(bookID: bookID, path: path)
      guard settingContentToken == token,
        currentBookID == bookID,
        selectedSettingPath == path
      else { return }
      selectedSettingContent = content
    } catch is CancellationError {
      return
    } catch {
      guard settingContentToken == token,
        currentBookID == bookID,
        selectedSettingPath == path
      else { return }
      setError(error)
    }
  }

  @discardableResult
  func saveSelectedBookSetting(_ content: String) async -> BookSettingSaveResponse? {
    guard let bookID = currentBookID, let path = selectedSettingPath else {
      errorMessage = "请先选择设定文件"
      return nil
    }
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.saveBookSetting(bookID: bookID, path: path, content: content)
      if currentBookID == bookID, selectedSettingPath == path {
        selectedSettingContent = content
      }
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  // MARK: - Structured long-form plan

  func loadLongFormPlan() async {
    guard let bookID = currentBookID else {
      longFormPlan = nil
      isLongFormPlanUnavailable = false
      return
    }
    let token = UUID()
    longFormPlanToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchLongFormPlan(bookID: bookID)
      guard longFormPlanToken == token, currentBookID == bookID else { return }
      longFormPlan = response
      isLongFormPlanUnavailable = false
    } catch is CancellationError {
      return
    } catch let coreError as InkOSCoreError where coreError.statusCode == 404 {
      guard longFormPlanToken == token, currentBookID == bookID else { return }
      longFormPlan = nil
      isLongFormPlanUnavailable = true
    } catch {
      guard longFormPlanToken == token, currentBookID == bookID else { return }
      longFormPlan = nil
      isLongFormPlanUnavailable = false
      setError(error)
    }
  }

  @discardableResult
  func updateLongFormPlan(
    constraints: LongFormConstraints? = nil,
    continuity: LongFormContinuity? = nil,
    expectedRevision: Int?
  ) async -> LongFormPlanResponse? {
    guard let bookID = currentBookID else {
      errorMessage = "请先选择书籍"
      return nil
    }
    guard constraints != nil || continuity != nil else {
      errorMessage = "长篇计划没有需要保存的修改"
      return nil
    }
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.updateLongFormPlan(
        bookID: bookID,
        expectedRevision: expectedRevision,
        constraints: constraints,
        continuity: continuity
      )
      guard currentBookID == bookID else { return nil }
      longFormPlanToken = UUID()
      longFormPlan = response
      isLongFormPlanUnavailable = false
      return response
    } catch is CancellationError {
      return nil
    } catch {
      guard currentBookID == bookID else { return nil }
      setError(error)
      return nil
    }
  }

  // MARK: - Fanqie

  func refreshFanqie(force: Bool = false) async {
    _ = force
    let token = UUID()
    fanqieToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let login = try await inkOS.fetchFanqieLoginState()
      guard fanqieToken == token else { return }
      fanqieLogin = login
      guard login.loggedIn else {
        clearFanqieData()
        return
      }

      let account = try await inkOS.fetchFanqieAccount()
      guard fanqieToken == token else { return }
      fanqieAccount = account
      guard account.loggedIn else {
        fanqieLogin = FanqieLoginState(
          loggedIn: false,
          needRelogin: true,
          reason: account.reason ?? account.error ?? "番茄登录状态已失效"
        )
        clearFanqieData(keepingAccount: true)
        return
      }
      let response = try await inkOS.fetchFanqieBooks()
      guard fanqieToken == token else { return }
      fanqieBooks = response.books

      let nextID =
        selectedFanqieBookID.flatMap { selected in
          response.books.contains { $0.bookId == selected } ? selected : nil
        } ?? response.books.first?.bookId
      await selectFanqieBook(response.books.first { $0.bookId == nextID })
    } catch is CancellationError {
      return
    } catch {
      guard fanqieToken == token else { return }
      setFanqieError(error)
    }
  }

  func completeFanqieLogin(cookies: [FanqieCookie]) async -> Bool {
    beginMutation()
    defer { endMutation() }
    do {
      let account = try await inkOS.saveFanqieCookies(cookies)
      fanqieAccount = account
      fanqieLogin = FanqieLoginState(loggedIn: true, needRelogin: false, reason: nil)
      await refreshFanqie(force: true)
      return fanqieLogin?.loggedIn == true
    } catch is CancellationError {
      return false
    } catch {
      setFanqieError(error)
      return false
    }
  }

  func fetchFanqieCategories(gender: Int) async -> [FanqieCategory] {
    do {
      return try await inkOS.fetchFanqieCategories(gender: gender)
    } catch is CancellationError {
      return []
    } catch {
      setFanqieError(error)
      return []
    }
  }

  func fetchLocalChapters(bookID: String) async -> [ChapterSummary] {
    do {
      return try await inkOS.fetchChapters(bookID: bookID).chapters
    } catch is CancellationError {
      return []
    } catch {
      setError(error)
      return []
    }
  }

  func fetchLocalBookSetting(bookID: String, path: String) async -> String? {
    do {
      return try await inkOS.fetchBookSetting(bookID: bookID, path: path)
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  func generateFanqieAbstract(
    bookID: String,
    source: String,
    protagonistNames: [String]
  ) async -> String? {
    beginMutation()
    defer { endMutation() }
    do {
      return try await inkOS.generateFanqieAbstract(
        bookID: bookID,
        source: source,
        protagonistNames: protagonistNames
      )
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  @discardableResult
  func createFanqieBook(_ input: FanqieCreateBookInput) async -> FanqieMutationResponse? {
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.createFanqieBook(input)
      await refreshFanqie(force: true)
      if let bookID = response.bookId {
        await selectFanqieBook(id: bookID)
      }
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setFanqieError(error)
      return nil
    }
  }

  @discardableResult
  func transferFanqieChapter(
    _ input: FanqieChapterTransferInput,
    replacing: Bool
  ) async -> FanqieMutationResponse? {
    beginMutation()
    defer { endMutation() }
    do {
      let response = replacing
        ? try await inkOS.replaceFanqieChapter(input)
        : try await inkOS.publishFanqieChapter(input)
      guard let remoteBook = fanqieBooks.first(where: { $0.bookId == input.remoteBookId }) else {
        await refreshFanqie(force: true)
        return response
      }
      await selectFanqieBook(remoteBook)
      if let chapterID = response.chapterId,
        let chapter = fanqieChapters.first(where: { $0.chapterId == chapterID })
      {
        await loadFanqieChapterContent(chapter)
      }
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setFanqieError(error)
      return nil
    }
  }

  func selectFanqieBook(_ book: FanqieBook?) async {
    // Manual selection wins over a concurrent background Fanqie refresh.
    fanqieToken = UUID()
    fanqieChaptersToken = UUID()
    fanqieContentToken = UUID()
    selectedFanqieBookID = book?.bookId
    fanqieChapters = []
    fanqieChapterContent = nil
    guard let book else { return }

    let token = UUID()
    fanqieChaptersToken = token
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchFanqieChapters(bookID: book.bookId, title: book.title)
      guard fanqieChaptersToken == token,
        selectedFanqieBookID == book.bookId
      else { return }
      fanqieChapters = response.chapters
    } catch is CancellationError {
      return
    } catch {
      guard fanqieChaptersToken == token,
        selectedFanqieBookID == book.bookId
      else { return }
      setFanqieError(error)
    }
  }

  func selectFanqieBook(id: String?) async {
    await selectFanqieBook(fanqieBooks.first { $0.bookId == id })
  }

  func loadFanqieChapterContent(_ chapter: FanqieChapter) async {
    guard let bookID = selectedFanqieBookID else {
      errorMessage = "请先选择番茄作品"
      return
    }
    let token = UUID()
    fanqieContentToken = token
    fanqieChapterContent = nil
    beginLoading()
    defer { endLoading() }
    do {
      let response = try await inkOS.fetchFanqieChapterContent(
        bookID: bookID,
        chapterID: chapter.chapterId
      )
      guard fanqieContentToken == token,
        selectedFanqieBookID == bookID
      else { return }
      fanqieChapterContent = response
    } catch is CancellationError {
      return
    } catch {
      guard fanqieContentToken == token,
        selectedFanqieBookID == bookID
      else { return }
      setFanqieError(error)
    }
  }

  @discardableResult
  func logoutFanqie() async -> FanqieLogoutResponse? {
    beginMutation()
    defer { endMutation() }
    do {
      let response = try await inkOS.logoutFanqie()
      fanqieToken = UUID()
      fanqieLogin = FanqieLoginState(loggedIn: false, needRelogin: true, reason: response.message)
      clearFanqieData()
      return response
    } catch is CancellationError {
      return nil
    } catch {
      setError(error)
      return nil
    }
  }

  func fanqieLoginURL() async -> FanqieLoginURLResponse? {
    do {
      return try await inkOS.fetchFanqieLoginURL()
    } catch is CancellationError {
      return nil
    } catch {
      setFanqieError(error)
      return nil
    }
  }

  private func setFanqieError(_ error: Error) {
    if let coreError = error as? InkOSCoreError, coreError.statusCode == 401 {
      fanqieLogin = FanqieLoginState(
        loggedIn: false,
        needRelogin: true,
        reason: coreError.errorDescription ?? "番茄登录状态已失效"
      )
      clearFanqieData()
    }
    setError(error)
  }

  private func clearFanqieData(keepingAccount: Bool = false) {
    if !keepingAccount { fanqieAccount = nil }
    fanqieBooks = []
    selectedFanqieBookID = nil
    fanqieChapters = []
    fanqieChapterContent = nil
  }

  // MARK: - State helpers

  private func invalidateBookDependentRequests() {
    chaptersToken = UUID()
    chapterToken = UUID()
    settingsToken = UUID()
    settingContentToken = UUID()
    longFormPlanToken = UUID()
  }

  private func invalidateRequests(for section: WorkspaceSection) {
    switch section {
    case .library:
      availableBooksToken = UUID()
    case .chapters:
      chaptersToken = UUID()
      chapterToken = UUID()
    case .fanqie:
      fanqieToken = UUID()
      fanqieChaptersToken = UUID()
      fanqieContentToken = UUID()
    case .settings:
      configToken = UUID()
      settingsToken = UUID()
      settingContentToken = UUID()
      longFormPlanToken = UUID()
    case .activity:
      activityToken = UUID()
    }
  }

  private func beginLoading() {
    loadingCount += 1
    isLoading = true
  }

  private func endLoading() {
    loadingCount = max(0, loadingCount - 1)
    isLoading = loadingCount > 0
  }

  private func beginMutation() {
    mutationCount += 1
    isMutating = true
    clearError()
  }

  private func endMutation() {
    mutationCount = max(0, mutationCount - 1)
    isMutating = mutationCount > 0
  }

  private func setError(_ error: Error) {
    guard !(error is CancellationError) else { return }
    errorMessage = errorText(error)
  }

  /// The message `setError` would show, for callers that record a failure inline
  /// instead of raising it to the error banner.
  private func errorText(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return error.localizedDescription
  }

  private func normalized(_ value: String?) -> String? {
    guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
      return nil
    }
    return text
  }
}
