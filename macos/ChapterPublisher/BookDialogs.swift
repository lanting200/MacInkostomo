import SwiftUI

struct CreateBookSheet: View {
  private enum GuideStep: Int, CaseIterable, Identifiable {
    case idea
    case length
    case review

    var id: Int { rawValue }

    var title: String {
      switch self {
      case .idea: return "你的故事"
      case .length: return "写作规模"
      case .review: return "确认方案"
      }
    }
  }

  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool
  @State private var request: CreateBookRequest
  @State private var guide: CreateBookGuide
  @State private var requirements: String
  @State private var guideStep: GuideStep
  @State private var pendingCreationJobID: String?
  @State private var draftPersistenceTask: Task<Void, Never>? = nil
  @State private var isAssisting = false
  @State private var assistCompleted = false
  @State private var isSubmitting = false
  @State private var protagonistConfirmed = false
  /// The uploaded original. Held only in view state, never in the persisted draft:
  /// a file path saved across launches can point at a file that has since moved, and
  /// silently importing the wrong bytes is worse than asking again.
  @State private var sourceFileURL: URL?
  @State private var isChoosingSource = false

  init(model: WorkspaceModel) {
    _model = ObservedObject(wrappedValue: model)
    let draft = CreateBookDraftPersistence.load()
    _request = State(initialValue: draft.request)
    _guide = State(initialValue: draft.request.creationGuide ?? CreateBookGuide(request: draft.request))
    _requirements = State(initialValue: draft.requirements)
    _pendingCreationJobID = State(initialValue: draft.pendingCreationJobID)
    let hasGeneratedPlan = !draft.request.outline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.request.volumePlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    _assistCompleted = State(initialValue: hasGeneratedPlan)
    _guideStep = State(initialValue: hasGeneratedPlan ? .review : .idea)
  }

  private var canSubmit: Bool {
    assistCompleted
      && !guide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && protagonistConfirmed
      && request.protagonistProfile.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20
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
    ideaValidationMessage ?? lengthValidationMessage ?? preferenceValidationMessage
  }

  private var ideaValidationMessage: String? {
    if guide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "请填写小说暂定名"
    }
    if guide.kind == .derivative {
      if sourceFileURL == nil {
        return "同人小说需要先上传原著 txt 文件"
      }
      if guide.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请填写原著名称"
      }
      if guide.timelineAnchorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "请填写原著时间锚点"
      }
    }
    if guide.storyPremise.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
      return "请用至少 20 个字讲讲你想写的故事"
    }
    if guide.protagonistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "请填写主角叫什么"
    }
    if guide.protagonistProfile.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 {
      return "请简单说明主角的处境和目标"
    }
    return nil
  }

  private var lengthValidationMessage: String? {
    let input = projectedRequest
    if input.targetTotalWords < 1_000 {
      return "预计总字数至少需要 1,000 字"
    }
    if input.targetTotalWords > 3_000_000 {
      return "预计总字数最高支持 300 万字"
    }
    if !(500...20_000).contains(input.chapterWords) {
      return "每章字数需要在 500 至 20,000 字之间"
    }
    if !(1...100).contains(input.volumeCount) {
      return "分卷数量需要在 1 至 100 卷之间"
    }
    if input.targetTotalWords * 2 < input.chapterWords {
      return "目标总字数不足以形成一章"
    }
    if input.volumeCount > input.derivedTargetChapters {
      return "分卷数量不能超过章节数量"
    }
    if !(0...50).contains(input.chapterWordTolerance) {
      return "单章字数浮动范围需要在 0% 至 50% 之间"
    }
    let chapterCount = input.derivedTargetChapters
    let exactMinimum = input.targetTotalWords / chapterCount
    let exactMaximum = (input.targetTotalWords + chapterCount - 1) / chapterCount
    if exactMinimum < input.chapterWordRange.lowerBound
      || exactMaximum > input.chapterWordRange.upperBound
    {
      return "章数和每章字数组合超出了当前字数范围"
    }
    return nil
  }

  private var preferenceValidationMessage: String? {
    let specialConstraints = guide.specialConstraints
    if specialConstraints.count > 100 {
      return "补充要求最多填写 100 条"
    }
    if specialConstraints.contains(where: { $0.count > 2_000 }) {
      return "每条补充要求最多填写 2,000 个字符"
    }
    if specialConstraints.reduce(0, { $0 + $1.count }) > 20_000 {
      return "补充要求总长度最多为 20,000 个字符"
    }
    return nil
  }

  private var currentStepValidationMessage: String? {
    switch guideStep {
    case .idea: return ideaValidationMessage
    case .length: return lengthValidationMessage
    case .review: return preferenceValidationMessage
    }
  }

  private var synchronizedGuide: CreateBookGuide {
    var value = guide
    value.synchronizeBudget()
    return value
  }

  private var projectedRequest: CreateBookRequest {
    let lockedGuide = synchronizedGuide
    var value = request
    value.title = lockedGuide.title
    value.language = lockedGuide.language
    value.genre = lockedGuide.genre
    value.platform = lockedGuide.platform
    value.targetChapters = lockedGuide.targetChapters
    value.chapterWords = lockedGuide.targetChapterWords
    value.targetTotalWords = lockedGuide.targetTotalWords
    value.totalWords = String(lockedGuide.targetTotalWords)
    value.volumeCount = lockedGuide.volumeCount
    value.chapterWordTolerance = lockedGuide.chapterWordTolerance
    // Without these five the core would write `book.json` as 自创 and drop every
    // canon and timeline constraint the customer just filled in.
    value.kind = lockedGuide.kind
    value.sourceTitle = lockedGuide.sourceTitle
    value.timelineAnchorLabel = lockedGuide.timelineAnchorLabel
    value.timelineStartDayOffset = lockedGuide.timelineStartDayOffset
    value.timelineStartDateLabel = lockedGuide.timelineStartDateLabel
    var mergedConstraints = LongFormConstraints.lines(from: value.constraints)
    mergedConstraints.append(contentsOf: lockedGuide.specialConstraints)
    var seenConstraints = Set<String>()
    value.constraints = mergedConstraints
      .filter { seenConstraints.insert($0).inserted }
      .joined(separator: "\n")
    if value.pacing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      value.pacing = lockedGuide.pacing
    }
    if value.style.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      value.style = lockedGuide.style
    }
    value.creationGuide = lockedGuide
    return value
  }

  private var specialConstraintsText: Binding<String> {
    Binding(
      get: { guide.specialConstraints.joined(separator: "\n") },
      set: { guide.specialConstraints = LongFormConstraints.lines(from: $0) }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      dialogHeader(
        title: "新建小说",
        subtitle: "回答几个问题，由 LLM 整理成完整小说方案",
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
          guideProgress

          switch guideStep {
          case .idea: ideaQuestions
          case .length: lengthQuestions
          case .review: reviewAndSummary
          }

          if let currentStepValidationMessage {
            Label(currentStepValidationMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityLabel("创建引导错误：\(currentStepValidationMessage)")
          }
        }
        .padding(20)
        .disabled(pendingCreationJobID != nil)
      }

      Divider()

      HStack(spacing: 10) {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSubmitting || isAssisting)
        Spacer()
        if guideStep != .idea {
          Button {
            moveBackward()
          } label: {
            Label("上一步", systemImage: "chevron.left")
          }
          .disabled(isSubmitting || isAssisting)
        }
        if guideStep == .review, assistCompleted {
          NativeActionButton(prominence: .prominent) {
            submit()
          } label: {
            Label(isSubmitting ? "正在创建" : "创建小说", systemImage: "plus")
          }
          .disabled(!canSubmit)
          .keyboardShortcut(.defaultAction)
        } else if guideStep != .review {
          NativeActionButton(prominence: .prominent) {
            moveForward()
          } label: {
            Label("下一步", systemImage: "chevron.right")
          }
          .disabled(currentStepValidationMessage != nil || isAssisting || isSubmitting)
          .keyboardShortcut(.defaultAction)
        }
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
    .onChange(of: guide) { _ in
      if !isAssisting {
        if assistCompleted { discardGeneratedPlan() }
        assistCompleted = false
      }
      scheduleDraftPersistence()
    }
    .onChange(of: model.workflowJobs?.creationJobs) { jobs in
      guard let jobs else { return }
      reconcilePendingCreation(with: jobs)
    }
    .onDisappear { persistDraftImmediately() }
    .interactiveDismissDisabled(isSubmitting || isAssisting)
  }

  private var guideProgress: some View {
    HStack(spacing: 10) {
      ForEach(GuideStep.allCases) { step in
        HStack(spacing: 7) {
          Image(systemName: step.rawValue < guideStep.rawValue
            ? "checkmark.circle.fill"
            : "\(step.rawValue + 1).circle.fill")
            .foregroundStyle(step.rawValue <= guideStep.rawValue ? Color.accentColor : .secondary)
          Text(step.title)
            .font(.callout.weight(step == guideStep ? .semibold : .regular))
            .foregroundStyle(step.rawValue <= guideStep.rawValue ? .primary : .secondary)
            .lineLimit(1)
          if step != GuideStep.allCases.last {
            Rectangle()
              .fill(step.rawValue < guideStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
              .frame(minWidth: 24, maxWidth: .infinity, maxHeight: 1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("第 \(guideStep.rawValue + 1) 步，共 \(GuideStep.allCases.count) 步：\(guideStep.title)")
  }

  private var ideaQuestions: some View {
    dialogSection("你想写一个什么故事？") {
      kindPicker
      if guide.kind == .derivative { derivativeSourceFields }
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          dialogField("这本小说暂定叫什么？", required: true) {
            TextField("暂定名也可以", text: $guide.title)
              .focused($titleFocused)
          }
          dialogField("主角叫什么？", required: true) {
            TextField("填写主角姓名", text: $guide.protagonistName)
          }
        }
        GridRow {
          dialogField("它属于哪类故事？", required: true) {
            Picker("故事类型", selection: $guide.genre) {
              Text("玄幻").tag("xuanhuan")
              Text("都市").tag("urban")
              Text("奇幻").tag("fantasy")
              Text("科幻").tag("sci-fi")
              Text("同人").tag("fanfic")
              Text("其他").tag("other")
            }
            .labelsHidden()
          }
          dialogField("准备发到哪里？", required: true) {
            Picker("发布平台", selection: $guide.platform) {
              Text("番茄").tag("tomato")
              Text("起点").tag("qidian")
              Text("晋江").tag("jjwxc")
              Text("其他").tag("other")
            }
            .labelsHidden()
          }
        }
      }
      createTextArea(
        "用自己的话讲讲故事",
        placeholder: "例如：一个被逐出宗门的少年发现自己能修复失传功法，他想查清家族覆灭的真相。",
        text: $guide.storyPremise,
        minHeight: 100,
        required: true
      )
      createTextArea(
        "主角现在是什么处境，最想得到什么？",
        placeholder: "例如：身无分文、修为尽失；他想救回妹妹，并让陷害家族的人付出代价。",
        text: $guide.protagonistProfile,
        minHeight: 82,
        required: true
      )
    }
  }

  private var kindPicker: some View {
    dialogField("这是同人还是自创？", required: true) {
      VStack(alignment: .leading, spacing: 6) {
        Picker("小说类型", selection: $guide.kind) {
          ForEach(BookKind.allCases) { kind in
            Text(kind.label).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(guide.kind.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The 同人 half of step one: which original, where its file is, and where this
  /// book sits on the original's clock. All three feed the core directly — the file
  /// becomes the retrieval index, and the two timeline fields become
  /// `source/timeline.json`, which every later beat card is measured against.
  private var derivativeSourceFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          dialogField("原著叫什么？", required: true) {
            TextField("例如：诡秘之主", text: $guide.sourceTitle)
          }
          dialogField("原著 txt 文件", required: true) {
            HStack(spacing: 8) {
              Text(sourceFileURL?.lastPathComponent ?? "尚未选择")
                .font(.caption)
                .foregroundStyle(sourceFileURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 4)
              Button("选择文件…") { isChoosingSource = true }
                .controlSize(.small)
            }
          }
        }
      }
      Text("建好小说后会自动切分原著、抽取正典与世界设定，并建立检索索引。原著越长，这一步越久，期间可以关掉本窗口。")
        .font(.caption)
        .foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
        GridRow {
          dialogField("以原著哪个事件为时间锚点？", required: true) {
            TextField("例如：克莱恩穿越", text: $guide.timelineAnchorLabel)
          }
          dialogField("本书开篇相对锚点第几天？") {
            HStack(spacing: 6) {
              TextField("天数", value: $guide.timelineStartDayOffset, format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
              Text("天").foregroundStyle(.secondary)
            }
          }
        }
        GridRow {
          dialogField("开篇时间怎么称呼？") {
            TextField("例如：1349 年 4 月", text: $guide.timelineStartDateLabel)
          }
          Color.clear.frame(height: 0)
        }
      }
      Text("负数表示开篇早于锚点事件，正数表示晚于。填 -365 即“锚点事件发生前一年”，此后原著里晚于开篇的事件都会被判定为“尚未发生”，不允许提前写出来。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .fileImporter(
      isPresented: $isChoosingSource,
      allowedContentTypes: [.plainText],
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        sourceFileURL = urls.first
      case .failure(let error):
        model.errorMessage = "无法读取所选文件：\(error.localizedDescription)"
      }
    }
  }

  private var lengthQuestions: some View {
    dialogSection("你准备写多长？") {
      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
        GridRow {
          dialogField("大约写多少章？", required: true) {
            HStack(spacing: 6) {
              TextField("章数", value: $guide.targetChapters, format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
              Text("章").foregroundStyle(.secondary)
              Stepper("调整章数", value: $guide.targetChapters, in: 1...6_000)
                .labelsHidden()
                .fixedSize()
            }
          }
          dialogField("每章大约多少字？", required: true) {
            HStack(spacing: 6) {
              TextField("每章字数", value: $guide.targetChapterWords, format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
              Text("字").foregroundStyle(.secondary)
              Stepper("调整每章字数", value: $guide.targetChapterWords, in: 500...20_000, step: 100)
                .labelsHidden()
                .fixedSize()
            }
          }
        }
        GridRow {
          dialogField("想分成几卷？", required: true) {
            HStack(spacing: 6) {
              TextField("分卷数", value: $guide.volumeCount, format: .number)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
              Text("卷").foregroundStyle(.secondary)
              Stepper(
                "调整分卷数",
                value: $guide.volumeCount,
                in: 1...max(1, min(100, guide.targetChapters))
              )
              .labelsHidden()
              .fixedSize()
            }
          }
          dialogField("预计总字数") {
            Text("\(formatted(synchronizedGuide.targetTotalWords)) 字")
              .font(.body.weight(.semibold).monospacedDigit())
          }
        }
      }

      Divider()

      HStack(spacing: 24) {
        projectionValue("章节数量", value: "\(formatted(guide.targetChapters)) 章")
        projectionValue("平均每卷", value: averageChaptersPerVolume)
        projectionValue("总字数", value: "\(formatted(synchronizedGuide.targetTotalWords)) 字")
      }
      .accessibilityElement(children: .combine)
    }
    .onChange(of: guide.targetChapters) { chapters in
      guide.volumeCount = min(guide.volumeCount, max(1, min(100, chapters)))
    }
  }

  @ViewBuilder
  private var reviewAndSummary: some View {
    if assistCompleted {
      generatedPlanSummary
    } else {
      dialogSection("还有哪些要求是你已经决定的？") {
        createTextArea(
          "必须出现，或者一定不要出现的内容",
          placeholder: "例如：感情线慢热；主角不无代价越级；不写系统流。没有额外要求可以留空。",
          text: specialConstraintsText,
          minHeight: 92
        )
        createTextArea(
          "希望读起来是什么感觉？",
          placeholder: "例如：轻松热血、悬疑压迫、群像成长。留空时由 LLM 根据题材决定。",
          text: $guide.style,
          minHeight: 72
        )

        HStack(spacing: 10) {
          NativeActionButton(prominence: .prominent) {
            assistCreation()
          } label: {
            Label(isAssisting ? "正在整理" : "让 LLM 整理小说方案", systemImage: "wand.and.stars")
          }
          .disabled(validationMessage != nil || isAssisting || isSubmitting || pendingCreationJobID != nil)
          if isAssisting {
            ProgressView().controlSize(.small)
            Text("正在整理人物、世界、主线和分卷")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var generatedPlanSummary: some View {
    dialogSection("LLM 整理结果") {
      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
        GridRow {
          projectionValue("小说", value: request.title)
          projectionValue("规模", value: "\(formatted(request.derivedTargetChapters)) 章 · \(request.volumeCount) 卷")
        }
        GridRow {
          projectionValue("题材", value: genreLabel(request.genre))
          projectionValue("预计总字数", value: "\(formatted(request.targetTotalWords)) 字")
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("主角性格（必审）")
          .font(.callout.weight(.semibold))
        Text("LLM 生成的主角性格会注入之后每一章的写作提示，直接决定主角像不像一个真实的人。请逐字审核、改成你要的样子；确认前无法创建小说。")
          .font(.caption)
          .foregroundStyle(.secondary)
        createTextArea(
          "主角性格档案",
          placeholder: "性格特质、缺陷软肋、情绪习惯、说话方式、防御机制、与人相处模式。",
          text: $request.protagonistProfile,
          minHeight: 120,
          required: true
        )
        Toggle("我已逐字审核并确认主角性格", isOn: $protagonistConfirmed)
          .toggleStyle(.checkbox)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Divider()
      summarySection("故事简介", text: request.premise)
      Divider()
      summarySection("主要人物", text: request.characters)
      Divider()
      summarySection("故事主线", text: request.outline)
      Divider()
      summarySection("分卷安排", text: request.volumePlan)

      DisclosureGroup("世界设定与写作风格") {
        VStack(alignment: .leading, spacing: 12) {
          summarySection("世界设定", text: request.worldbuilding)
          summarySection("节奏", text: request.pacing)
          summarySection("风格", text: request.style)
        }
        .padding(.top, 8)
      }

      HStack(spacing: 10) {
        Button {
          discardGeneratedPlan()
          assistCompleted = false
          guideStep = .idea
        } label: {
          Label("修改回答", systemImage: "pencil")
        }
        Button {
          assistCreation()
        } label: {
          Label("重新整理", systemImage: "arrow.clockwise")
        }
        .disabled(isAssisting || isSubmitting)
      }
    }
  }

  private func summarySection(_ title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.callout.weight(.semibold))
      Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var averageChaptersPerVolume: String {
    let volumes = max(guide.volumeCount, 1)
    let lower = guide.targetChapters / volumes
    let upper = (guide.targetChapters + volumes - 1) / volumes
    return lower == upper ? "\(lower) 章" : "\(lower)–\(upper) 章"
  }

  private func genreLabel(_ genre: String) -> String {
    switch genre {
    case "xuanhuan": return "玄幻"
    case "urban": return "都市"
    case "fantasy": return "奇幻"
    case "sci-fi": return "科幻"
    case "fanfic": return "同人"
    default: return "其他"
    }
  }

  private func moveForward() {
    guard currentStepValidationMessage == nil,
      let next = GuideStep(rawValue: guideStep.rawValue + 1)
    else { return }
    guideStep = next
  }

  private func moveBackward() {
    guard let previous = GuideStep(rawValue: guideStep.rawValue - 1) else { return }
    guideStep = previous
  }

  private func discardGeneratedPlan() {
    request.premise = ""
    request.characters = ""
    request.protagonistProfile = ""
    request.worldbuilding = ""
    request.outline = ""
    request.volumePlan = ""
    request.pacing = ""
    request.style = ""
    request.constraints = ""
    protagonistConfirmed = false
  }

  private func submit() {
    guard canSubmit else { return }
    request = projectedRequest
    request.title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    request.protagonistReviewed = protagonistConfirmed
    request.synchronizeLongFormFields()
    persistDraftImmediately()
    // Read off the request before the success path resets it, and hold the ingestion
    // inputs in locals: the pass is handed to the model and outlives this view.
    let ingestionKind = request.kind
    let ingestionURL = sourceFileURL
    let ingestionTitle = request.title
    let ingestionSettings = derivativeSettingsText
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
          guide = .init()
          requirements = ""
          assistCompleted = false
          protagonistConfirmed = false
          sourceFileURL = nil
          CreateBookDraftPersistence.clear()
          // Only now does the book have a `long-form-plan.json` for canon to merge into.
          if ingestionKind == .derivative, let ingestionURL {
            // `bookId` is optional on the job record. Falling back to the title match
            // beats skipping ingestion, which would leave a 同人 book with no canon at
            // all and no sign of why.
            let resolvedID =
              acceptedJob?.bookId.flatMap { $0.isEmpty ? nil : $0 }
              ?? model.books.first { $0.title == ingestionTitle }?.id
            if let resolvedID {
              Task {
                await model.prepareDerivativeSource(
                  bookID: resolvedID,
                  bookTitle: ingestionTitle,
                  sourceURL: ingestionURL,
                  settingsText: ingestionSettings
                )
              }
            } else {
              model.errorMessage = "小说已创建，但没能定位到它的目录，原著未导入。请在书籍列表中选中它后重新导入原著。"
            }
          }
        } else {
          pendingCreationJobID = CreateBookDraftPersistence.load().pendingCreationJobID
        }
        dismiss()
      }
    }
  }

  /// The customer's own settings, as one block, for `manualOverlay`.
  ///
  /// Deliberately not the whole request: overlay extraction reads this as "what the
  /// customer asked for", and feeding it generated plan text would let the model's own
  /// output outrank the source it was supposed to obey.
  private var derivativeSettingsText: String {
    [guide.storyPremise, guide.protagonistProfile, guide.specialConstraints.joined(separator: "\n")]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private func assistCreation() {
    guard validationMessage == nil, !isAssisting else { return }
    model.clearError()
    persistDraftImmediately()
    isAssisting = true
    assistCompleted = false
    Task {
      if let generated = await model.assistCreateBook(guide: synchronizedGuide) {
        request = generated.payload
        assistCompleted = true
        protagonistConfirmed = false
        guideStep = .review
        persistDraftImmediately()
      }
      isAssisting = false
    }
  }

  private func scheduleDraftPersistence() {
    draftPersistenceTask?.cancel()
    let request = projectedRequest
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
    let request = projectedRequest
    if request == CreateBookRequest(), guide == CreateBookGuide(), pendingCreationJobID == nil {
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
      guide = .init()
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
