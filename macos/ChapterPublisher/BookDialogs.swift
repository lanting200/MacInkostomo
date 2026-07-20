import SwiftUI

struct CreateBookSheet: View {
  private struct ProjectedVolume: Identifiable {
    let number: Int
    let startChapter: Int
    let endChapter: Int
    let chapterCount: Int
    let targetWords: Int

    var id: Int { number }
  }

  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool
  @State private var request: CreateBookRequest
  @State private var requirements: String
  @State private var pendingCreationJobID: String?
  @State private var draftPersistenceTask: Task<Void, Never>? = nil
  @State private var isAssisting = false
  @State private var assistCompleted = false
  @State private var isSubmitting = false

  init(model: WorkspaceModel) {
    _model = ObservedObject(wrappedValue: model)
    let draft = CreateBookDraftPersistence.load()
    _request = State(initialValue: draft.request)
    _requirements = State(initialValue: draft.requirements)
    _pendingCreationJobID = State(initialValue: draft.pendingCreationJobID)
  }

  private var canSubmit: Bool {
    !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && validationMessage == nil
      && !isAssisting
      && !isSubmitting
      && pendingCreationJobID == nil
  }

  private var pendingCreationJob: CreationJob? {
    guard let pendingCreationJobID else { return nil }
    return model.workflowJobs?.creationJobs.first { $0.jobId == pendingCreationJobID }
  }

  private var validationMessage: String? {
    if request.targetTotalWords < 1_000 {
      return "目标总字数不能少于 1,000 字"
    }
    if request.targetTotalWords > 3_000_000 {
      return "目标总字数上限为 300 万字"
    }
    if !(500...20_000).contains(request.chapterWords) {
      return "目标章字数需在 500 至 20,000 字之间"
    }
    if !(1...100).contains(request.volumeCount) {
      return "分卷数需在 1 至 100 卷之间"
    }
    if request.targetTotalWords * 2 < request.chapterWords {
      return "目标总字数不足以形成一章"
    }
    if request.volumeCount > request.derivedTargetChapters {
      return "分卷数不能超过推导章节数"
    }
    if !(0...50).contains(request.chapterWordTolerance) {
      return "单章字数容差需在 0% 至 50% 之间"
    }
    let chapterCount = request.derivedTargetChapters
    let exactMinimum = request.targetTotalWords / chapterCount
    let exactMaximum = (request.targetTotalWords + chapterCount - 1) / chapterCount
    if exactMinimum < request.chapterWordRange.lowerBound
      || exactMaximum > request.chapterWordRange.upperBound
    {
      return "总字数与目标章字数、容差组合不相容"
    }
    let specialConstraints = LongFormConstraints.lines(from: request.constraints)
    if specialConstraints.isEmpty {
      return "请填写特殊约束；没有额外要求时可填写“无”"
    }
    if specialConstraints.count > 100 {
      return "特殊约束不能超过 100 条"
    }
    if specialConstraints.contains(where: { $0.count > 2_000 }) {
      return "单条特殊约束不能超过 2,000 个字符"
    }
    if specialConstraints.reduce(0, { $0 + $1.count }) > 20_000 {
      return "特殊约束总长度不能超过 20,000 个字符"
    }
    return nil
  }

  var body: some View {
    VStack(spacing: 0) {
      dialogHeader(
        title: "新建小说",
        subtitle: "创建 InkOS 设定、大纲、分卷与写作节奏",
        systemImage: "book.closed.fill"
      )

      Divider()

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        NativeErrorBanner(message: errorMessage, dismiss: model.clearError)
      }

      if let pendingCreationJobID {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          VStack(alignment: .leading, spacing: 2) {
            Text("小说创建任务正在运行")
              .font(.callout.weight(.semibold))
            Text(pendingCreationJob?.title ?? "任务 \(pendingCreationJobID)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          Button("查看任务") {
            dismiss()
            Task { await model.selectSection(.activity) }
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.blue.opacity(0.08))
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          dialogSection("快速创建") {
            VStack(alignment: .leading, spacing: 8) {
              ZStack(alignment: .topLeading) {
                if requirements.isEmpty {
                  Text("例如：番茄玄幻，60 万字，6 卷，单章 3000 字，容差 15%，主角不得降智")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                }
                TextEditor(text: $requirements)
                  .font(.body)
                  .scrollContentBackground(.hidden)
                  .padding(3)
              }
              .frame(minHeight: 70)
              .background(
                .quaternary.opacity(0.35),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .stroke(.quaternary, lineWidth: 1)
              }
              .accessibilityLabel("小说创作需求")

              HStack(spacing: 8) {
                NativeActionButton {
                  assistCreation()
                } label: {
                  Label(isAssisting ? "正在生成" : "生成并填入设定", systemImage: "wand.and.stars")
                }
                .disabled(
                  requirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isAssisting || isSubmitting || pendingCreationJobID != nil
                )

                if isAssisting {
                  ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在生成小说设定")
                } else if assistCompleted {
                  Label("已填入", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                }
              }
            }
          }

          dialogSection("基础信息") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
              GridRow {
                dialogField("书名", required: true) {
                  TextField("例如：道衍封诡录", text: $request.title)
                    .focused($titleFocused)
                }
                dialogField("语言") {
                  Picker("语言", selection: $request.language) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                  }
                  .labelsHidden()
                }
              }

              GridRow {
                dialogField("类型") {
                  TextField("xuanhuan / urban / fanfic", text: $request.genre)
                }
                dialogField("平台") {
                  Picker("平台", selection: $request.platform) {
                    Text("番茄").tag("tomato")
                    Text("起点").tag("qidian")
                    Text("其他").tag("other")
                  }
                  .labelsHidden()
                }
              }

              GridRow {
                dialogField("节奏要求") {
                  TextField("例如：前三章强钩子", text: $request.pacing)
                }
                Color.clear
              }
            }
          }

          dialogSection("长篇结构预算") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
              GridRow {
                dialogField("目标总字数", required: true) {
                  HStack(spacing: 8) {
                    TextField(
                      "600000",
                      value: $request.targetTotalWords,
                      format: .number.grouping(.never)
                    )
                    .frame(minWidth: 120)
                    Text("字")
                      .foregroundStyle(.secondary)
                  }
                }
                dialogField("分卷数", required: true) {
                  Stepper(value: $request.volumeCount, in: 1...100) {
                    Text("\(request.volumeCount) 卷")
                      .monospacedDigit()
                  }
                }
              }

              GridRow {
                dialogField("目标章字数", required: true) {
                  Stepper(value: $request.chapterWords, in: 500...20_000, step: 100) {
                    Text("\(request.chapterWords) 字")
                      .monospacedDigit()
                  }
                }
                dialogField("单章容差", required: true) {
                  Stepper(value: $request.chapterWordTolerance, in: 0...50) {
                    Text("±\(request.chapterWordTolerance)%")
                      .monospacedDigit()
                  }
                }
              }
            }

            longFormProjection

            if let validationMessage {
              Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("结构预算错误：\(validationMessage)")
            }
          }

          dialogSection("故事设定") {
            createTextArea("核心创意", placeholder: "主角、目标、冲突与核心卖点", text: $request.premise)
            createTextArea("主要人物", placeholder: "主角与关键角色的人设、关系和动机", text: $request.characters)
            createTextArea("世界观与规则", placeholder: "世界结构、力量体系、限制与代价", text: $request.worldbuilding)
          }

          dialogSection("结构与风格") {
            createTextArea(
              "主线大纲", placeholder: "主要剧情阶段与终局方向", text: $request.outline, minHeight: 90)
            createTextArea(
              "分卷规划", placeholder: "每卷标题、章节范围和阶段目标", text: $request.volumePlan, minHeight: 90)
            createTextArea("文风要求", placeholder: "叙事视角、语气、节奏与表达偏好", text: $request.style)
            createTextArea(
              "特殊约束",
              placeholder: "必须遵守的人设、结构、内容边界；没有额外要求时填写“无”",
              text: $request.constraints,
              required: true
            )
          }
        }
        .padding(20)
        .disabled(pendingCreationJobID != nil)
      }

      Divider()

      HStack(spacing: 10) {
        Text("创建会启动后台任务，进度可在“任务状态”查看。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSubmitting || isAssisting)
        NativeActionButton(prominence: .prominent) {
          submit()
        } label: {
          Label(isSubmitting ? "正在创建" : "创建小说", systemImage: "plus")
        }
        .disabled(!canSubmit)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 680, idealWidth: 720, minHeight: 560, idealHeight: 680)
    .onAppear {
      model.clearError()
      if pendingCreationJobID == nil { titleFocused = true }
      if let jobs = model.workflowJobs?.creationJobs {
        reconcilePendingCreation(with: jobs)
      } else if pendingCreationJobID != nil {
        Task { await model.refreshWorkflowJobs() }
      }
    }
    .onChange(of: request) { _ in scheduleDraftPersistence() }
    .onChange(of: requirements) { _ in
      assistCompleted = false
      scheduleDraftPersistence()
    }
    .onChange(of: model.workflowJobs?.creationJobs) { jobs in
      guard let jobs else { return }
      reconcilePendingCreation(with: jobs)
    }
    .onDisappear { persistDraftImmediately() }
    .interactiveDismissDisabled(isSubmitting || isAssisting)
  }

  private func submit() {
    guard canSubmit else { return }
    request.title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    request.synchronizeLongFormFields()
    persistDraftImmediately()
    isSubmitting = true
    Task {
      let response = await model.createBook(request, requirements: requirements)
      isSubmitting = false
      if let response {
        let acceptedJob = model.workflowJobs?.creationJobs.first { $0.jobId == response.jobId }
        if acceptedJob?.status.lowercased() == "success" {
          draftPersistenceTask?.cancel()
          draftPersistenceTask = nil
          pendingCreationJobID = nil
          request = .init()
          requirements = ""
          assistCompleted = false
          CreateBookDraftPersistence.clear()
        } else {
          pendingCreationJobID = CreateBookDraftPersistence.load().pendingCreationJobID
        }
        dismiss()
      }
    }
  }

  private func assistCreation() {
    let trimmed = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isAssisting else { return }
    persistDraftImmediately()
    isAssisting = true
    assistCompleted = false
    Task {
      if let generated = await model.assistCreateBook(requirements: trimmed) {
        request = generated
        assistCompleted = true
        persistDraftImmediately()
      }
      isAssisting = false
    }
  }

  private func scheduleDraftPersistence() {
    draftPersistenceTask?.cancel()
    let request = request
    let requirements = requirements
    draftPersistenceTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 200_000_000)
      } catch {
        return
      }
      CreateBookDraftPersistence.saveDraft(request: request, requirements: requirements)
      draftPersistenceTask = nil
    }
  }

  private func persistDraftImmediately() {
    draftPersistenceTask?.cancel()
    draftPersistenceTask = nil
    if request == CreateBookRequest(), requirements.isEmpty, pendingCreationJobID == nil {
      CreateBookDraftPersistence.clear()
    } else {
      CreateBookDraftPersistence.saveDraft(request: request, requirements: requirements)
    }
  }

  private func reconcilePendingCreation(with jobs: [CreationJob]) {
    guard let pendingCreationJobID else { return }
    let job = jobs.first { $0.jobId == pendingCreationJobID }
    let succeeded = job?.status.lowercased() == "success"
    let snapshot = CreateBookDraftPersistence.reconcile(creationJobs: jobs)
    self.pendingCreationJobID = snapshot.pendingCreationJobID
    if succeeded {
      draftPersistenceTask?.cancel()
      draftPersistenceTask = nil
      request = .init()
      requirements = ""
      assistCompleted = false
    }
  }

  private func createTextArea(
    _ title: String,
    placeholder: String,
    text: Binding<String>,
    minHeight: CGFloat = 68,
    required: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 3) {
        Text(title)
        if required {
          Text("必填")
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }
      .font(.callout.weight(.medium))
      ZStack(alignment: .topLeading) {
        if text.wrappedValue.isEmpty {
          Text(placeholder)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }
        TextEditor(text: text)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(2)
      }
      .frame(minHeight: minHeight)
      .background(
        .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(.quaternary, lineWidth: 1)
      }
    }
  }

  private var longFormProjection: some View {
    let chapterRange = request.chapterWordRange
    let chapterCount = request.derivedTargetChapters
    let volumes = projectedVolumes
    let lowerChapterBudget = volumes.map(\.chapterCount).min() ?? 0
    let upperChapterBudget = volumes.map(\.chapterCount).max() ?? 0
    let lowerWordBudget = volumes.map(\.targetWords).min() ?? 0
    let upperWordBudget = volumes.map(\.targetWords).max() ?? 0

    return AdaptiveGlassSurface(padding: 12, tint: .accentColor.opacity(0.08)) {
      VStack(alignment: .leading, spacing: 10) {
        Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
          GridRow {
            projectionValue("推导章节", value: "\(chapterCount) 章")
            projectionValue(
              "每卷章节",
              value: lowerChapterBudget == upperChapterBudget
                ? "\(lowerChapterBudget) 章"
                : "\(lowerChapterBudget)–\(upperChapterBudget) 章"
            )
          }
          GridRow {
            projectionValue(
              "单章范围",
              value: "\(formatted(chapterRange.lowerBound))–\(formatted(chapterRange.upperBound)) 字"
            )
            projectionValue(
              "每卷字数",
              value: lowerWordBudget == upperWordBudget
                ? "\(formatted(lowerWordBudget)) 字"
                : "\(formatted(lowerWordBudget))–\(formatted(upperWordBudget)) 字"
            )
          }
        }

        Divider()

        ScrollView {
          LazyVStack(spacing: 5) {
            ForEach(volumes) { volume in
              HStack(spacing: 10) {
                Text("第 \(volume.number) 卷")
                  .frame(width: 58, alignment: .leading)
                Text("\(volume.startChapter)–\(volume.endChapter) 章")
                  .frame(width: 88, alignment: .leading)
                Text("\(volume.chapterCount) 章")
                  .frame(width: 58, alignment: .trailing)
                Spacer(minLength: 8)
                Text("\(formatted(volume.targetWords)) 字")
                  .frame(minWidth: 88, alignment: .trailing)
              }
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityElement(children: .combine)
            }
          }
        }
        .frame(maxHeight: 140)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "推导 \(chapterCount) 章，每卷 \(lowerChapterBudget) 至 \(upperChapterBudget) 章，单章 \(chapterRange.lowerBound) 至 \(chapterRange.upperBound) 字"
    )
  }

  private func projectionValue(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.weight(.semibold).monospacedDigit())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func formatted(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }

  private var projectedVolumes: [ProjectedVolume] {
    let chapterCount = request.derivedTargetChapters
    guard chapterCount > 0, request.targetTotalWords > 0 else { return [] }
    let volumeCount = min(max(request.volumeCount, 1), chapterCount)
    let chaptersPerVolume = chapterCount / volumeCount
    let extraVolumeChapters = chapterCount % volumeCount
    let wordsPerChapter = request.targetTotalWords / chapterCount
    let extraChapterWords = request.targetTotalWords % chapterCount
    var nextChapter = 1

    return (0..<volumeCount).map { index in
      let count = chaptersPerVolume + (index < extraVolumeChapters ? 1 : 0)
      let start = nextChapter
      let end = start + count - 1
      let extraWords = max(0, min(end, extraChapterWords) - start + 1)
      let words = count * wordsPerChapter + extraWords
      nextChapter = end + 1
      return ProjectedVolume(
        number: index + 1,
        startChapter: start,
        endChapter: end,
        chapterCount: count,
        targetWords: words
      )
    }
  }
}

struct ImportBookSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var selection: String?
  @State private var isImporting = false

  var body: some View {
    VStack(spacing: 0) {
      dialogHeader(
        title: "导入本地作品",
        subtitle: "从 InkOS 工作区导入尚未加入书库的小说",
        systemImage: "square.and.arrow.down"
      )

      Divider()

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        NativeErrorBanner(message: errorMessage, dismiss: model.clearError)
      }

      Group {
        if model.isLoading && model.availableBooks.isEmpty {
          VStack(spacing: 10) {
            ProgressView()
            Text("正在读取本地作品")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.availableBooks.isEmpty {
          NativeEmptyState(
            title: "没有可导入的作品",
            detail: "InkOS 工作区中的小说都已导入，或当前目录还没有作品。",
            systemImage: "tray"
          )
        } else {
          List(model.availableBooks, id: \.self, selection: $selection) { bookID in
            HStack(spacing: 9) {
              Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(bookID)
                .lineLimit(2)
              Spacer()
            }
            .padding(.vertical, 4)
            .tag(bookID)
            .accessibilityLabel("作品：\(bookID)")
          }
          .listStyle(.inset)
        }
      }
      .frame(minHeight: 260)

      Divider()

      HStack(spacing: 10) {
        NativeIconButton(
          title: "刷新可导入作品",
          systemImage: "arrow.clockwise",
          disabled: model.isLoading || isImporting
        ) {
          Task { await model.refreshAvailableBooks() }
        }
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isImporting)
        NativeActionButton(prominence: .prominent) {
          importSelection()
        } label: {
          Label(isImporting ? "正在导入" : "导入", systemImage: "square.and.arrow.down")
        }
        .disabled(selection == nil || isImporting)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 440)
    .task {
      model.clearError()
      await model.refreshAvailableBooks()
    }
    .interactiveDismissDisabled(isImporting)
  }

  private func importSelection() {
    guard let selection else { return }
    isImporting = true
    Task {
      let response = await model.importBook(selection)
      isImporting = false
      if response != nil {
        dismiss()
      }
    }
  }
}

struct DeleteBookSheet: View {
  @ObservedObject var model: WorkspaceModel
  let book: BookSummary
  @Environment(\.dismiss) private var dismiss
  @State private var isDeleting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      dialogHeader(
        title: "删除作品",
        subtitle: "此操作会移除工作台记录",
        systemImage: "trash.fill",
        tint: .red
      )

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        NativeErrorBanner(message: errorMessage, dismiss: model.clearError)
      }

      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.title2)
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 7) {
          Text("确定删除《\(book.title)》？")
            .font(.headline)
          Text("作品目录会移入废纸篓，不会直接抹除。工作台中的章节、状态以及番茄映射将一并移除。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text("\(book.chapterCount) 章")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 10) {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isDeleting)
        NativeActionButton(prominence: .destructive) {
          deleteBook()
        } label: {
          Label(isDeleting ? "正在删除" : "移入废纸篓", systemImage: "trash")
        }
        .disabled(isDeleting)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480)
    .interactiveDismissDisabled(isDeleting)
    .onAppear { model.clearError() }
  }

  private func deleteBook() {
    isDeleting = true
    Task {
      let response = await model.deleteBook(book.id)
      isDeleting = false
      if response != nil {
        dismiss()
      }
    }
  }
}

private func dialogHeader(
  title: String,
  subtitle: String,
  systemImage: String,
  tint: Color = .accentColor
) -> some View {
  HStack(spacing: 11) {
    Image(systemName: systemImage)
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: 24)
      .accessibilityHidden(true)
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.title3.weight(.semibold))
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    Spacer()
  }
  .padding(16)
  .accessibilityElement(children: .combine)
}

private func dialogSection<Content: View>(
  _ title: String,
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: 11) {
    Text(title)
      .font(.headline)
    content()
  }
  .frame(maxWidth: .infinity, alignment: .leading)
}

private func dialogField<Content: View>(
  _ title: String,
  required: Bool = false,
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: 6) {
    HStack(spacing: 3) {
      Text(title)
      if required {
        Text("必填")
          .font(.caption2)
          .foregroundStyle(.red)
      }
    }
    .font(.callout.weight(.medium))
    content()
  }
  .frame(maxWidth: .infinity, alignment: .leading)
}
