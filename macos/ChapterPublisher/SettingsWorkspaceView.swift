import Combine
import Foundation
import SwiftUI

@MainActor
final class BookSettingDraftStore: ObservableObject {
  private struct DraftKey: Hashable {
    let bookID: String
    let path: String
  }

  private struct DraftEntry {
    let original: String
    var content: String
  }

  @Published private var entries: [DraftKey: DraftEntry] = [:]

  func content(bookID: String, path: String, original: String) -> String {
    entries[DraftKey(bookID: bookID, path: path)]?.content ?? original
  }

  func update(bookID: String, path: String, original: String, content: String) {
    let key = DraftKey(bookID: bookID, path: path)
    if content == original {
      entries.removeValue(forKey: key)
    } else if var existing = entries[key] {
      existing.content = content
      entries[key] = existing
    } else {
      entries[key] = DraftEntry(original: original, content: content)
    }
  }

  func isDirty(bookID: String?, path: String?) -> Bool {
    guard let bookID, let path,
      let entry = entries[DraftKey(bookID: bookID, path: path)]
    else { return false }
    return entry.content != entry.original
  }

  func discard(bookID: String, path: String) {
    entries.removeValue(forKey: DraftKey(bookID: bookID, path: path))
  }
}

private enum LongFormContinuitySection: String, CaseIterable, Identifiable {
  case immutableCanon
  case worldRules
  case entities
  case knowledgeBoundaries
  case timeline
  case hooks
  case policy

  var id: String { rawValue }

  var title: String {
    switch self {
    case .immutableCanon: "不可变事实"
    case .worldRules: "世界规则"
    case .entities: "人物与实体"
    case .knowledgeBoundaries: "知识边界"
    case .timeline: "时间线"
    case .hooks: "伏笔计划"
    case .policy: "一致性策略"
    }
  }

  var icon: String {
    switch self {
    case .immutableCanon: "lock.doc"
    case .worldRules: "globe.asia.australia"
    case .entities: "person.2"
    case .knowledgeBoundaries: "eye.trianglebadge.exclamationmark"
    case .timeline: "calendar.badge.clock"
    case .hooks: "point.topleft.down.to.point.bottomright.curvepath"
    case .policy: "switch.2"
    }
  }

  var detail: String {
    switch self {
    case .immutableCanon: "角色、物件、世界与知识中不可被后文改写的事实"
    case .worldRules: "力量体系、社会规则和世界运行边界"
    case .entities: "人物、物件、地点、阵营及其锁定属性"
    case .knowledgeBoundaries: "角色可知、禁知以及信息公开章节"
    case .timeline: "按顺序生效的关键事件及章节窗口"
    case .hooks: "伏笔开启、推进和最迟回收范围"
    case .policy: "跨卷、未规划实体、差量与卷末检查点开关"
    }
  }

  var fieldSummary: String {
    switch self {
    case .immutableCanon:
      "id · category · statement · value? · aliases"
    case .worldRules:
      "id · statement · immutable"
    case .entities:
      "id · name · type · owner? · location? · attributes · immutableOwner · immutableLocation · immutableAttributes"
    case .knowledgeBoundaries:
      "factId · statement · allowedKnowers · forbiddenKnowers · availableFromChapter · revealByChapter? · markers"
    case .timeline:
      "id · order · label · earliestChapter · latestChapter · immutable"
    case .hooks:
      "hookId · description · openFromChapter · resolveByChapter? · requiredVolumeNumber?"
    case .policy:
      "requireContinuousVolumes · allowUnplannedEntities · requireConsistencyDelta · checkpointAtVolumeEnd"
    }
  }
}

private enum LongFormPlanMode: String, CaseIterable, Identifiable {
  case budget = "结构预算"
  case continuity = "连续性"

  var id: String { rawValue }
}

private struct LongFormContinuityDraft: Equatable, Sendable {
  var immutableCanon: String
  var worldRules: String
  var entities: String
  var knowledgeBoundaries: String
  var timeline: String
  var hooks: String
  var policy: LongFormContinuityPolicy

  init(_ continuity: LongFormContinuity = LongFormContinuity()) {
    immutableCanon = Self.prettyJSON(continuity.immutableCanon, fallback: "[]")
    worldRules = Self.prettyJSON(continuity.worldRules, fallback: "[]")
    entities = Self.prettyJSON(continuity.entities, fallback: "[]")
    knowledgeBoundaries = Self.prettyJSON(continuity.knowledgeBoundaries, fallback: "[]")
    timeline = Self.prettyJSON(continuity.timeline, fallback: "[]")
    hooks = Self.prettyJSON(continuity.hooks, fallback: "[]")
    policy = continuity.policy
  }

  func text(for section: LongFormContinuitySection) -> String {
    switch section {
    case .immutableCanon: immutableCanon
    case .worldRules: worldRules
    case .entities: entities
    case .knowledgeBoundaries: knowledgeBoundaries
    case .timeline: timeline
    case .hooks: hooks
    case .policy: Self.prettyJSON(policy, fallback: "{}")
    }
  }

  mutating func setText(_ text: String, for section: LongFormContinuitySection) {
    switch section {
    case .immutableCanon: immutableCanon = text
    case .worldRules: worldRules = text
    case .entities: entities = text
    case .knowledgeBoundaries: knowledgeBoundaries = text
    case .timeline: timeline = text
    case .hooks: hooks = text
    case .policy:
      if let value = try? Self.decode(
        LongFormContinuityPolicy.self, from: text, label: "一致性策略")
      {
        policy = value
      }
    }
  }

  func decoded(targetChapters: Int, volumeCount: Int) throws -> LongFormContinuity {
    let continuity = LongFormContinuity(
      immutableCanon: try Self.decode(
        [LongFormImmutableCanon].self, from: immutableCanon, label: "不可变事实"),
      worldRules: try Self.decode(
        [LongFormWorldRule].self, from: worldRules, label: "世界规则"),
      entities: try Self.decode([LongFormEntity].self, from: entities, label: "人物与实体"),
      knowledgeBoundaries: try Self.decode(
        [LongFormKnowledgeBoundary].self,
        from: knowledgeBoundaries,
        label: "知识边界"
      ),
      timeline: try Self.decode(
        [LongFormTimelineMilestone].self, from: timeline, label: "时间线"),
      hooks: try Self.decode([LongFormHookPlan].self, from: hooks, label: "伏笔计划"),
      policy: policy
    )
    return try continuity.validated(
      targetChapters: targetChapters,
      volumeCount: volumeCount
    )
  }

  func validationMessage(targetChapters: Int, volumeCount: Int) -> String? {
    do {
      _ = try decoded(targetChapters: targetChapters, volumeCount: volumeCount)
      return nil
    } catch let error as LocalizedError {
      return error.errorDescription ?? "连续性 JSON 校验失败"
    } catch {
      return "连续性 JSON 校验失败"
    }
  }

  private static func prettyJSON<Value: Encodable>(_ value: Value, fallback: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
      let text = String(data: data, encoding: .utf8)
    else { return fallback }
    return text
  }

  private static func decode<Value: Decodable>(
    _ type: Value.Type,
    from text: String,
    label: String
  ) throws -> Value {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw LongFormContinuityValidationError(message: "\(label) JSON 不能为空")
    }
    guard let data = trimmed.data(using: .utf8) else {
      throw LongFormContinuityValidationError(message: "\(label)不是有效的 UTF-8 文本")
    }
    do {
      _ = try JSONSerialization.jsonObject(with: data)
    } catch {
      let details = (error as NSError).userInfo["NSDebugDescription"] as? String
      let suffix = details.map { "：\($0)" } ?? ""
      throw LongFormContinuityValidationError(message: "\(label) JSON 语法错误\(suffix)")
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw LongFormContinuityValidationError(
        message: decodingMessage(error, label: label)
      )
    }
  }

  private static func decodingMessage(_ error: Error, label: String) -> String {
    switch error {
    case DecodingError.keyNotFound(let key, let context):
      return "\(label)缺少字段 \(codingPath(context.codingPath + [key]))"
    case DecodingError.typeMismatch(_, let context):
      return "\(label)字段 \(codingPath(context.codingPath)) 类型错误"
    case DecodingError.valueNotFound(_, let context):
      return "\(label)字段 \(codingPath(context.codingPath)) 缺少值"
    case DecodingError.dataCorrupted(let context):
      let path = codingPath(context.codingPath)
      return path.isEmpty ? "\(label) JSON 格式错误" : "\(label)字段 \(path) 格式错误"
    default:
      return "\(label) JSON 格式错误"
    }
  }

  private static func codingPath(_ path: [CodingKey]) -> String {
    path.map { key in
      if let index = key.intValue { return "[\(index)]" }
      return key.stringValue
    }
    .joined(separator: ".")
    .replacingOccurrences(of: ".[", with: "[")
  }
}

struct SettingsWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject var drafts: BookSettingDraftStore

  private enum SettingsTab: String, CaseIterable, Identifiable {
    case book = "书籍设定"
    case llm = "LLM 设置"

    var id: String { rawValue }
  }

  private enum BookSettingsMode: String, CaseIterable, Identifiable {
    case plan = "长篇计划"
    case files = "设定文件"

    var id: String { rawValue }
  }

  @State private var tab: SettingsTab = .book
  @State private var bookSettingsMode: BookSettingsMode = .plan
  @State private var planEditorMode: LongFormPlanMode = .budget
  @State private var editorDraft = ""
  @State private var editorBookID: String?
  @State private var editorPath: String?
  @State private var planDraft = LongFormConstraints()
  @State private var planSpecialConstraints = ""
  @State private var continuityDraft = LongFormContinuityDraft()
  @State private var continuityBaselineDraft = LongFormContinuityDraft()
  @State private var continuityValidationMessage: String?
  @State private var isContinuityValidationPending = false
  @State private var continuityValidationTask: Task<Void, Never>?
  @State private var planDraftBookID: String?
  @State private var planDraftRevision: Int?

  @State private var baseURL = ""
  @State private var apiKey = ""
  @State private var modelName = ""
  @State private var reviewBaseURL = ""
  @State private var reviewAPIKey = ""
  @State private var reviewModelName = ""
  @State private var extractionBaseURL = ""
  @State private var extractionAPIKey = ""
  @State private var extractionModelName = ""
  @State private var stream = false
  @State private var thinkingBudget = 0
  @State private var temperature = 0.2
  @State private var chapterModels: [RemoteModel] = []
  @State private var reviewModels: [RemoteModel] = []
  @State private var extractionModels: [RemoteModel] = []
  @State private var chapterProbe: ModelTestResponse?
  @State private var reviewProbe: ModelTestResponse?
  @State private var extractionProbe: ModelTestResponse?
  @State private var isDiscoveringChapterModels = false
  @State private var isDiscoveringReviewModels = false
  @State private var isDiscoveringExtractionModels = false
  @State private var isProbingChapterModel = false
  @State private var isProbingReviewModel = false
  @State private var isProbingExtractionModel = false
  @State private var chapterDiscoveryRequest = UUID()
  @State private var reviewDiscoveryRequest = UUID()
  @State private var extractionDiscoveryRequest = UUID()
  @State private var chapterProbeRequest = UUID()
  @State private var reviewProbeRequest = UUID()
  @State private var extractionProbeRequest = UUID()

  var body: some View {
    VStack(spacing: 0) {
      settingsToolbar
      Divider()

      switch tab {
      case .book:
        bookSettings
      case .llm:
        llmSettings
      }
    }
    .task {
      if model.inkOSConfig == nil { await model.loadInkOSConfig() }
      if model.bookSettings == nil { await model.loadBookSettings() }
      if model.longFormPlan == nil, !model.isLongFormPlanUnavailable {
        await model.loadLongFormPlan()
      }
      loadConfigDraft()
      syncEditorDraft()
      syncLongFormDraft()
    }
    .onChange(of: model.inkOSConfig) { _ in loadConfigDraft() }
    .onChange(of: model.currentBookID) { _ in
      syncEditorDraft()
      resetLongFormDraft()
    }
    .onChange(of: model.selectedSettingPath) { _ in syncEditorDraft() }
    .onChange(of: model.selectedSettingContent) { _ in syncEditorDraft() }
    .onChange(of: model.longFormPlan) { _ in syncLongFormDraft() }
    .onChange(of: continuityDraft) { _ in scheduleContinuityValidation() }
    .onChange(of: editorDraft) { content in
      guard let editorBookID, let editorPath else { return }
      drafts.update(
        bookID: editorBookID,
        path: editorPath,
        original: model.selectedSettingContent,
        content: content
      )
    }
    .onChange(of: baseURL) { _ in
      chapterModels = []
      chapterProbe = nil
      // A role that left its endpoint blank inherits this one, so its cached
      // list and probe no longer describe what that role would reach.
      if reviewBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reviewModels = []
        reviewProbe = nil
      }
      if extractionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        extractionModels = []
        extractionProbe = nil
      }
    }
    .onChange(of: reviewBaseURL) { _ in
      reviewModels = []
      reviewProbe = nil
    }
    .onChange(of: extractionBaseURL) { _ in
      extractionModels = []
      extractionProbe = nil
    }
    .onChange(of: apiKey) { _ in
      chapterProbe = nil
      if reviewAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reviewProbe = nil
      }
      if extractionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        extractionProbe = nil
      }
    }
    .onChange(of: reviewAPIKey) { _ in reviewProbe = nil }
    .onChange(of: extractionAPIKey) { _ in extractionProbe = nil }
    .onChange(of: modelName) { _ in
      chapterProbe = nil
      // Extraction falls back to the chapter model when its own field is blank.
      if extractionModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        extractionProbe = nil
      }
    }
    .onChange(of: reviewModelName) { _ in reviewProbe = nil }
    .onChange(of: extractionModelName) { _ in extractionProbe = nil }
    .onDisappear {
      continuityValidationTask?.cancel()
      continuityValidationTask = nil
    }
  }

  private var settingsToolbar: some View {
    HStack(spacing: 12) {
      Picker("设置页面", selection: $tab) {
        ForEach(SettingsTab.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 260)

      Spacer()

      Picker("当前作品", selection: selectedBookBinding) {
        Text("选择作品").tag(String?.none)
        ForEach(model.books) { book in
          Text(book.title).tag(Optional(book.id))
        }
      }
      .frame(width: 260)

      NativeIconButton(
        title: "刷新设置",
        systemImage: "arrow.clockwise",
        disabled: model.isLoading
      ) {
        Task {
          await model.loadInkOSConfig()
          await model.loadBookSettings()
          await model.loadLongFormPlan()
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
  }

  private var bookSettings: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Picker("书籍设定视图", selection: $bookSettingsMode) {
          ForEach(BookSettingsMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("书籍设定视图")
        .frame(width: 230)

        if bookSettingsMode == .plan {
          Picker("长篇计划内容", selection: $planEditorMode) {
            ForEach(LongFormPlanMode.allCases) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("长篇计划内容")
          .frame(width: 210)
        }

        Spacer()

        if bookSettingsMode == .plan, let plan = model.longFormPlan {
          Text("版本 \(plan.version) · 修订 \(plan.revision)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceUtilityHeight)

      Divider()

      switch bookSettingsMode {
      case .plan:
        longFormPlanSettings
      case .files:
        bookSettingFiles
      }
    }
  }

  private var bookSettingFiles: some View {
    HSplitView {
      VStack(spacing: 0) {
        NativeSectionHeader(
          "设定文件",
          subtitle: "\(model.bookSettings?.files.count ?? 0) 项"
        )
        .padding(12)
        Divider()

        if model.currentBookID == nil {
          NativeEmptyState(
            title: "选择作品",
            detail: "",
            systemImage: "books.vertical"
          )
        } else if let settings = model.bookSettings, !settings.files.isEmpty {
          List(selection: selectedSettingBinding) {
            ForEach(groupedSettingFiles, id: \.0) { group, files in
              Section(group) {
                ForEach(files) { file in
                  Label {
                    HStack(spacing: 6) {
                      Text(file.title)
                        .lineLimit(1)
                      if file.managed {
                        Image(systemName: "arrow.triangle.2.circlepath")
                          .font(.caption2)
                          .foregroundStyle(.secondary)
                          .accessibilityHidden(true)
                      }
                    }
                  } icon: {
                    Image(systemName: "doc.text")
                  }
                  .tag(Optional(file.path))
                  .help(file.managed ? "\(file.path)（由系统自动重写）" : file.path)
                  .accessibilityLabel(
                    file.managed ? "\(file.title)，由系统自动重写" : file.title
                  )
                }
              }
            }
          }
          .listStyle(.sidebar)
        } else if model.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          NativeEmptyState(
            title: "没有设定文件",
            detail: "",
            systemImage: "doc"
          )
        }
      }
      .frame(minWidth: 230, idealWidth: 280, maxWidth: 340)

      VStack(spacing: 0) {
        if let file = model.selectedSettingFile {
          NativeSectionHeader(
            file.title,
            subtitle: hasDirtyBookSettingDraft ? "\(file.path) · 未保存" : file.path
          ) {
            NativeActionButton(
              prominence: .prominent,
              action: saveBookSetting
            ) {
              Label("保存", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isMutating || editorPath != file.path || !hasDirtyBookSettingDraft)
            .keyboardShortcut("s", modifiers: .command)
          }
          .padding(12)

          if !file.description.isEmpty {
            Text(file.description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.bottom, 8)
          }

          if file.managed {
            managedSettingNotice(for: file.path)
          }
          Divider()

          TextEditor(text: $editorDraft)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(10)
            .accessibilityLabel("\(file.title)内容")
        } else {
          NativeEmptyState(
            title: "选择设定文件",
            detail: "",
            systemImage: "doc.text"
          )
        }
      }
      .frame(minWidth: 480)
    }
  }

  /// Managed runtime files are rewritten after each chapter approval, so an edit
  /// saved here survives only until the next approval. Point the author at the
  /// input that actually persists: the continuity overlay for state and hooks,
  /// the beat plan for the next-chapter focus.
  private func managedSettingNotice(for path: String) -> some View {
    let detail = path == "current_focus.md"
      ? "此文件由系统按下一章节拍卡自动重写，手工修改会被覆盖。要改变下一章的写作目标，请调整该章节拍卡。"
      : "此文件由系统在章节审核通过后自动重写，手工修改会被覆盖。要长期改变连续性事实，请在“长篇计划 · 连续性”中编辑覆盖层。"
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var longFormPlanSettings: some View {
    if model.currentBookID == nil {
      NativeEmptyState(
        title: "选择作品",
        detail: "",
        systemImage: "books.vertical"
      )
    } else if let plan = model.longFormPlan {
      LongFormPlanEditor(
        response: plan,
        chapters: model.chapters,
        draft: $planDraft,
        specialConstraintsText: $planSpecialConstraints,
        continuityDraft: $continuityDraft,
        mode: planEditorMode,
        budgetValidationMessage: longFormPlanValidationMessage,
        continuityValidationMessage: continuityValidationMessage,
        isContinuityValidationPending: isContinuityValidationPending,
        isBudgetDirty: isLongFormBudgetDirty,
        isContinuityDirty: isLongFormContinuityDirty,
        isSaving: model.isMutating,
        saveBudget: saveLongFormBudget,
        saveContinuity: saveLongFormContinuity,
        discardBudget: discardLongFormBudgetDraft,
        discardContinuity: discardLongFormContinuityDraft
      )
    } else if model.isLoading {
      VStack(spacing: 10) {
        ProgressView()
        Text("正在载入长篇计划")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    } else if model.isLongFormPlanUnavailable {
      NativeEmptyState(
        title: "暂无结构化长篇计划",
        detail: "",
        systemImage: "list.bullet.rectangle"
      )
    } else {
      VStack(spacing: 12) {
        NativeEmptyState(
          title: "计划尚未载入",
          detail: "",
          systemImage: "list.bullet.rectangle"
        )
        NativeActionButton {
          Task { await model.loadLongFormPlan() }
        } label: {
          Label("重新载入", systemImage: "arrow.clockwise")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var llmSettings: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        llmRoleSection(
          title: "章节生成",
          role: .chapter,
          baseURL: $baseURL,
          key: $apiKey,
          model: $modelName,
          models: chapterModels,
          probe: chapterProbe,
          discovering: isDiscoveringChapterModels,
          probing: isProbingChapterModel
        )

        Divider()

        llmRoleSection(
          title: "设定与初审",
          role: .review,
          baseURL: $reviewBaseURL,
          key: $reviewAPIKey,
          model: $reviewModelName,
          models: reviewModels,
          probe: reviewProbe,
          discovering: isDiscoveringReviewModels,
          probing: isProbingReviewModel
        )

        Divider()

        llmRoleSection(
          title: "原著抽取（RAG）",
          role: .extraction,
          baseURL: $extractionBaseURL,
          key: $extractionAPIKey,
          model: $extractionModelName,
          models: extractionModels,
          probe: extractionProbe,
          discovering: isDiscoveringExtractionModels,
          probing: isProbingExtractionModel,
          modelPlaceholder: "模型名称，如 claude-sonnet-4-5",
          note: "留空则沿用章节生成的模型与端点。建议选长上下文模型，用于把原著抽成正典设定。"
        )

        Divider()

        HStack(spacing: 22) {
          Toggle("流式输出", isOn: $stream)
          Stepper("思考预算 \(thinkingBudget)", value: $thinkingBudget, in: 0...100_000, step: 128)
            .frame(width: 210)
          VStack(alignment: .leading, spacing: 4) {
            Text("Temperature \(temperature, specifier: "%.1f")")
              .font(.caption)
            Slider(value: $temperature, in: 0...2, step: 0.1)
              .frame(width: 180)
          }
          Spacer()
          NativeActionButton(prominence: .prominent, action: saveLLMSettings) {
            Label("保存并应用", systemImage: "checkmark")
          }
          .disabled(!canSaveLLMSettings)
        }
      }
      .padding(20)
      .frame(maxWidth: 1040, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  private func llmRoleSection(
    title: String,
    role: ModelRole,
    baseURL: Binding<String>,
    key: Binding<String>,
    model: Binding<String>,
    models: [RemoteModel],
    probe: ModelTestResponse?,
    discovering: Bool,
    probing: Bool,
    modelPlaceholder: String = "模型名称",
    note: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      NativeSectionHeader(title) {
        if probing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在测速")
        } else if let probe {
          Label(
            probe.ok ? "\(probe.latencyMs ?? 0) ms" : "测速失败",
            systemImage: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(probe.ok ? .green : .red)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Base URL").frame(width: 92, alignment: .trailing)
          TextField("https://HOST/v1", text: baseURL)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("API Key").frame(width: 92, alignment: .trailing)
          SecureField(keyPlaceholder(for: role), text: key)
            .textFieldStyle(.roundedBorder)
        }
        GridRow {
          Text("模型").frame(width: 92, alignment: .trailing)
          HStack(spacing: 8) {
            if models.isEmpty {
              TextField(modelPlaceholder, text: model)
                .textFieldStyle(.roundedBorder)
            } else {
              Picker("模型", selection: model) {
                ForEach(models) { item in
                  Text(item.id).tag(item.id)
                }
              }
              .labelsHidden()
            }
            NativeIconButton(
              title: "刷新模型列表",
              systemImage: "arrow.triangle.2.circlepath",
              disabled: discovering
            ) {
              discoverModels(role)
            }
            NativeIconButton(
              title: "测速所选模型",
              systemImage: "speedometer",
              disabled: probing
                || model.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
              probeModel(role)
            }
          }
        }
      }

      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var selectedBookBinding: Binding<String?> {
    Binding(
      get: { model.currentBookID },
      set: { id in Task { await model.selectBook(id) } }
    )
  }

  private var selectedSettingBinding: Binding<String?> {
    Binding(
      get: { model.selectedSettingPath },
      set: { path in Task { await model.selectBookSetting(path) } }
    )
  }

  private var groupedSettingFiles: [(String, [BookSettingFile])] {
    let files = model.bookSettings?.files ?? []
    let grouped = Dictionary(grouping: files, by: \.groupTitle)
    return grouped.map { key, value in
      (key, value.sorted { ($0.order, $0.title) < ($1.order, $1.title) })
    }.sorted { left, right in
      let leftOrder = left.1.first?.groupOrder ?? 0
      let rightOrder = right.1.first?.groupOrder ?? 0
      return (leftOrder, left.0) < (rightOrder, right.0)
    }
  }

  private func keyPlaceholder(for role: ModelRole) -> String {
    guard let config = model.inkOSConfig else { return "API Key" }
    switch role {
    case .chapter:
      return config.apiKeyPreview.isEmpty ? "API Key" : "已保存：\(config.apiKeyPreview)"
    case .review:
      return config.reviewApiKeyPreview.isEmpty ? "API Key" : "已保存：\(config.reviewApiKeyPreview)"
    case .extraction:
      return config.extractionApiKeyPreview.isEmpty
        ? "API Key（留空沿用章节生成）"
        : "已保存：\(config.extractionApiKeyPreview)"
    }
  }

  private func syncEditorDraft() {
    guard let bookID = model.currentBookID, let path = model.selectedSettingPath else {
      editorBookID = nil
      editorPath = nil
      editorDraft = ""
      return
    }
    let content = drafts.content(bookID: bookID, path: path, original: model.selectedSettingContent)
    guard editorBookID != bookID || editorPath != path || editorDraft != content else { return }
    editorBookID = bookID
    editorPath = path
    editorDraft = content
  }

  private var normalizedLongFormPlanDraft: LongFormConstraints {
    var normalized = planDraft
    normalized.specialConstraints = LongFormConstraints.lines(from: planSpecialConstraints)
    return normalized
  }

  private var isLongFormBudgetDirty: Bool {
    guard let response = model.longFormPlan,
      planDraftBookID == response.bookId
    else { return false }
    return normalizedLongFormPlanDraft != response.constraints
  }

  private var isLongFormContinuityDirty: Bool {
    guard planDraftBookID == model.longFormPlan?.bookId else { return false }
    return continuityDraft != continuityBaselineDraft
  }

  private var longFormPlanValidationMessage: String? {
    if !(1_000...3_000_000).contains(planDraft.targetTotalWords) {
      return "目标总字数需在 1,000 至 300 万字之间"
    }
    if !(500...20_000).contains(planDraft.targetChapterWords) {
      return "目标章字数需在 500 至 20,000 字之间"
    }
    if !(1...100).contains(planDraft.volumeCount) {
      return "分卷数需在 1 至 100 卷之间"
    }
    let roundedTargetChapters = Int(
      (Double(planDraft.targetTotalWords) / Double(planDraft.targetChapterWords)).rounded()
    )
    if roundedTargetChapters < 1 {
      return "目标总字数不足以形成一章"
    }
    let targetChapters = max(1, roundedTargetChapters)
    if planDraft.volumeCount > targetChapters {
      return "分卷数不能超过推导章节数"
    }
    if !(0...50).contains(planDraft.chapterWordTolerance) {
      return "单章字数容差需在 0% 至 50% 之间"
    }
    let exactMinimum = planDraft.targetTotalWords / targetChapters
    let exactMaximum =
      (planDraft.targetTotalWords + targetChapters - 1) / targetChapters
    let tolerance = planDraft.chapterWordTolerance
    let allowedMinimum =
      (planDraft.targetChapterWords * (100 - tolerance) + 50) / 100
    let allowedMaximum =
      (planDraft.targetChapterWords * (100 + tolerance) + 50) / 100
    if exactMinimum < allowedMinimum || exactMaximum > allowedMaximum {
      return "总字数与目标章字数、容差组合不相容"
    }
    let specialConstraints = LongFormConstraints.lines(from: planSpecialConstraints)
    if specialConstraints.isEmpty {
      return "请至少保留一条特殊约束"
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

  private func syncLongFormDraft() {
    guard let response = model.longFormPlan,
      response.bookId == model.currentBookID
    else { return }
    if planDraftBookID == response.bookId,
      isLongFormBudgetDirty || isLongFormContinuityDirty
    {
      if isLongFormContinuityDirty { scheduleContinuityValidation() }
      return
    }
    adoptLongFormPlan(response)
  }

  private func resetLongFormDraft() {
    planDraft = LongFormConstraints()
    planSpecialConstraints = ""
    continuityDraft = LongFormContinuityDraft()
    continuityBaselineDraft = LongFormContinuityDraft()
    continuityValidationTask?.cancel()
    continuityValidationTask = nil
    continuityValidationMessage = nil
    isContinuityValidationPending = false
    planDraftBookID = nil
    planDraftRevision = nil
  }

  private func adoptLongFormPlan(_ response: LongFormPlanResponse) {
    planDraft = response.constraints
    planSpecialConstraints = response.constraints.specialConstraints.joined(separator: "\n")
    let adoptedContinuity = LongFormContinuityDraft(response.continuity)
    continuityDraft = adoptedContinuity
    continuityBaselineDraft = adoptedContinuity
    continuityValidationTask?.cancel()
    continuityValidationTask = nil
    continuityValidationMessage = nil
    isContinuityValidationPending = false
    planDraftBookID = response.bookId
    planDraftRevision = response.revision
  }

  private func discardLongFormBudgetDraft() {
    guard let response = model.longFormPlan else { return }
    planDraft = response.constraints
    planSpecialConstraints = response.constraints.specialConstraints.joined(separator: "\n")
    planDraftRevision = response.revision
  }

  private func discardLongFormContinuityDraft() {
    guard let response = model.longFormPlan else { return }
    let adoptedContinuity = LongFormContinuityDraft(response.continuity)
    continuityDraft = adoptedContinuity
    continuityBaselineDraft = adoptedContinuity
    continuityValidationTask?.cancel()
    continuityValidationTask = nil
    continuityValidationMessage = nil
    isContinuityValidationPending = false
    planDraftRevision = response.revision
  }

  private func saveLongFormBudget() {
    guard longFormPlanValidationMessage == nil,
      isLongFormBudgetDirty,
      planDraftBookID == model.currentBookID
    else { return }
    let constraints = normalizedLongFormPlanDraft
    let expectedRevision = planDraftRevision
    Task {
      if let response = await model.updateLongFormPlan(
        constraints: constraints,
        expectedRevision: expectedRevision
      ) {
        planDraft = response.constraints
        planSpecialConstraints = response.constraints.specialConstraints.joined(separator: "\n")
        planDraftRevision = response.revision
      }
    }
  }

  private func saveLongFormContinuity() {
    guard let response = model.longFormPlan,
      continuityValidationMessage == nil,
      !isContinuityValidationPending,
      isLongFormContinuityDirty,
      planDraftBookID == model.currentBookID
    else { return }
    let continuity: LongFormContinuity
    do {
      continuity = try continuityDraft.decoded(
        targetChapters: response.plan.targetChapters,
        volumeCount: response.constraints.volumeCount
      )
    } catch let error as LocalizedError {
      continuityValidationMessage = error.errorDescription ?? "连续性 JSON 校验失败"
      return
    } catch {
      continuityValidationMessage = "连续性 JSON 校验失败"
      return
    }
    let expectedRevision = planDraftRevision
    Task {
      if let response = await model.updateLongFormPlan(
        continuity: continuity,
        expectedRevision: expectedRevision
      ) {
        let adoptedContinuity = LongFormContinuityDraft(response.continuity)
        continuityDraft = adoptedContinuity
        continuityBaselineDraft = adoptedContinuity
        continuityValidationMessage = nil
        isContinuityValidationPending = false
        planDraftRevision = response.revision
      }
    }
  }

  private func scheduleContinuityValidation() {
    continuityValidationTask?.cancel()
    continuityValidationTask = nil

    guard isLongFormContinuityDirty,
      let response = model.longFormPlan,
      planDraftBookID == response.bookId
    else {
      continuityValidationMessage = nil
      isContinuityValidationPending = false
      return
    }

    let candidate = continuityDraft
    let targetChapters = response.plan.targetChapters
    let volumeCount = response.constraints.volumeCount
    isContinuityValidationPending = true
    continuityValidationTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled, candidate == continuityDraft else { return }
      let result = await Task.detached(priority: .userInitiated) {
        candidate.validationMessage(
          targetChapters: targetChapters,
          volumeCount: volumeCount
        )
      }.value
      guard !Task.isCancelled, candidate == continuityDraft else { return }
      continuityValidationMessage = result
      isContinuityValidationPending = false
      continuityValidationTask = nil
    }
  }

  private func loadConfigDraft() {
    guard let config = model.inkOSConfig else { return }
    baseURL = config.baseUrl
    reviewBaseURL = config.reviewBaseUrl
    extractionBaseURL = config.extractionBaseUrl
    modelName = config.model
    reviewModelName = config.reviewModel
    extractionModelName = config.extractionModel
    stream = config.stream ?? false
    thinkingBudget = config.thinkingBudget
    temperature = config.temperature ?? 0.2
    apiKey = ""
    reviewAPIKey = ""
    extractionAPIKey = ""
    chapterModels = []
    reviewModels = []
    extractionModels = []
    chapterProbe = nil
    reviewProbe = nil
    extractionProbe = nil
  }

  private func saveBookSetting() {
    guard let editorBookID, let editorPath,
      editorBookID == model.currentBookID,
      editorPath == model.selectedSettingPath
    else { return }
    let content = editorDraft
    Task {
      if await model.saveSelectedBookSetting(content) != nil {
        drafts.discard(bookID: editorBookID, path: editorPath)
        syncEditorDraft()
      }
    }
  }

  private func discoverModels(_ role: ModelRole) {
    let endpoint = endpointValues(for: role)
    let requestID = UUID()
    switch role {
    case .chapter:
      chapterDiscoveryRequest = requestID
      isDiscoveringChapterModels = true
    case .review:
      reviewDiscoveryRequest = requestID
      isDiscoveringReviewModels = true
    case .extraction:
      extractionDiscoveryRequest = requestID
      isDiscoveringExtractionModels = true
    }
    Task {
      let values = await model.loadModels(
        role: role,
        baseURL: endpoint.baseURL,
        apiKey: endpoint.apiKey
      )
      switch role {
      case .chapter:
        guard chapterDiscoveryRequest == requestID else { return }
        isDiscoveringChapterModels = false
        guard endpointMatches(endpoint, role: role) else { return }
        chapterModels = values
        if !values.isEmpty, !values.contains(where: { $0.id == modelName }) {
          modelName = values[0].id
        }
      case .review:
        guard reviewDiscoveryRequest == requestID else { return }
        isDiscoveringReviewModels = false
        guard endpointMatches(endpoint, role: role) else { return }
        reviewModels = values
        if !values.isEmpty, !values.contains(where: { $0.id == reviewModelName }) {
          reviewModelName = values[0].id
        }
      case .extraction:
        guard extractionDiscoveryRequest == requestID else { return }
        isDiscoveringExtractionModels = false
        guard endpointMatches(endpoint, role: role) else { return }
        extractionModels = values
        if !values.isEmpty, !values.contains(where: { $0.id == extractionModelName }) {
          extractionModelName = values[0].id
        }
      }
    }
  }

  private func probeModel(_ role: ModelRole) {
    let endpoint = endpointValues(for: role)
    guard !endpoint.model.isEmpty else { return }
    let requestID = UUID()
    switch role {
    case .chapter:
      chapterProbeRequest = requestID
      chapterProbe = nil
      isProbingChapterModel = true
    case .review:
      reviewProbeRequest = requestID
      reviewProbe = nil
      isProbingReviewModel = true
    case .extraction:
      extractionProbeRequest = requestID
      extractionProbe = nil
      isProbingExtractionModel = true
    }
    Task {
      let response = await model.testModel(
        role: role,
        model: endpoint.model,
        baseURL: endpoint.baseURL,
        apiKey: endpoint.apiKey
      )
      switch role {
      case .chapter:
        guard chapterProbeRequest == requestID else { return }
        isProbingChapterModel = false
        guard endpointMatches(endpoint, role: role) else { return }
        chapterProbe = response
      case .review:
        guard reviewProbeRequest == requestID else { return }
        isProbingReviewModel = false
        guard endpointMatches(endpoint, role: role) else { return }
        reviewProbe = response
      case .extraction:
        guard extractionProbeRequest == requestID else { return }
        isProbingExtractionModel = false
        guard endpointMatches(endpoint, role: role) else { return }
        extractionProbe = response
      }
    }
  }

  private func saveLLMSettings() {
    guard canSaveLLMSettings else { return }
    let update = InkOSConfigUpdate(
      model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
      reviewModel: reviewModelName.trimmingCharacters(in: .whitespacesAndNewlines),
      extractionModel: extractionModelName.trimmingCharacters(in: .whitespacesAndNewlines),
      baseUrl: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      reviewBaseUrl: reviewBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      extractionBaseUrl: extractionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      apiKey: apiKey,
      reviewApiKey: reviewAPIKey,
      extractionApiKey: extractionAPIKey,
      stream: stream,
      thinkingBudget: thinkingBudget,
      temperature: temperature
    )
    Task { _ = await model.saveInkOSConfig(update) }
  }

  private var hasDirtyBookSettingDraft: Bool {
    drafts.isDirty(bookID: editorBookID, path: editorPath)
  }

  private var canSaveLLMSettings: Bool {
    let chapter = endpointValues(for: .chapter)
    let review = endpointValues(for: .review)
    guard !model.isMutating,
      !chapter.baseURL.isEmpty,
      !chapter.model.isEmpty,
      !review.baseURL.isEmpty,
      !review.model.isEmpty
    else { return false }

    guard let config = model.inkOSConfig else {
      return chapterProbe?.ok == true && reviewProbe?.ok == true
    }

    let storedReviewBase =
      config.reviewBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? config.baseUrl
      : config.reviewBaseUrl
    let chapterChanged =
      canonicalEndpoint(chapter.baseURL) != canonicalEndpoint(config.baseUrl)
      || chapter.model != config.model
      || !chapter.apiKey.isEmpty
    let reviewUsesNewPrimaryKey =
      reviewAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let reviewChanged =
      canonicalEndpoint(review.baseURL) != canonicalEndpoint(storedReviewBase)
      || review.model != config.reviewModel
      || !reviewAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || reviewUsesNewPrimaryKey

    // Extraction is optional. While all three fields are blank it inherits the
    // chapter role and never gates saving; the draft values are compared raw
    // rather than through `endpointValues` so an inherited value does not read
    // as an edit. Once the user gives it something of its own it gates like the
    // other roles.
    let extractionModelDraft =
      extractionModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    let extractionBaseDraft =
      extractionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let extractionKeyDraft =
      extractionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let extractionConfigured =
      !extractionModelDraft.isEmpty || !extractionBaseDraft.isEmpty
      || !extractionKeyDraft.isEmpty
    let extractionChanged =
      extractionConfigured
      && (canonicalEndpoint(extractionBaseDraft)
        != canonicalEndpoint(config.extractionBaseUrl)
        || extractionModelDraft != config.extractionModel
        || !extractionKeyDraft.isEmpty)

    return (!chapterChanged || chapterProbe?.ok == true)
      && (!reviewChanged || reviewProbe?.ok == true)
      && (!extractionChanged || extractionProbe?.ok == true)
  }

  private func endpointValues(for role: ModelRole) -> (
    baseURL: String, apiKey: String, model: String
  ) {
    let primaryBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let primaryKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    switch role {
    case .chapter:
      return (primaryBase, primaryKey, modelName.trimmingCharacters(in: .whitespacesAndNewlines))
    case .review:
      let reviewBase = reviewBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      let reviewKey = reviewAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
      return (
        reviewBase.isEmpty ? primaryBase : reviewBase,
        reviewKey.isEmpty ? primaryKey : reviewKey,
        reviewModelName.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    case .extraction:
      let extractionBase = extractionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      let extractionKey = extractionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
      let extractionModel = extractionModelName
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (
        extractionBase.isEmpty ? primaryBase : extractionBase,
        extractionKey.isEmpty ? primaryKey : extractionKey,
        // Blank means "inherit the chapter model", so discovery and the probe
        // target what extraction would actually send.
        extractionModel.isEmpty
          ? modelName.trimmingCharacters(in: .whitespacesAndNewlines)
          : extractionModel
      )
    }
  }

  private func endpointMatches(
    _ expected: (baseURL: String, apiKey: String, model: String),
    role: ModelRole
  ) -> Bool {
    let current = endpointValues(for: role)
    return current.baseURL == expected.baseURL
      && current.apiKey == expected.apiKey
      && current.model == expected.model
  }

  private func canonicalEndpoint(_ value: String) -> String {
    var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while result.hasSuffix("/") { result.removeLast() }
    return result
  }
}

private struct LongFormPlanEditor: View {
  let response: LongFormPlanResponse
  let chapters: [ChapterSummary]
  @Binding var draft: LongFormConstraints
  @Binding var specialConstraintsText: String
  @Binding var continuityDraft: LongFormContinuityDraft
  let mode: LongFormPlanMode
  let budgetValidationMessage: String?
  let continuityValidationMessage: String?
  let isContinuityValidationPending: Bool
  let isBudgetDirty: Bool
  let isContinuityDirty: Bool
  let isSaving: Bool
  let saveBudget: () -> Void
  let saveContinuity: () -> Void
  let discardBudget: () -> Void
  let discardContinuity: () -> Void

  var body: some View {
    Group {
      switch mode {
      case .budget:
        HSplitView {
          constraintsEditor
            .frame(minWidth: 310, idealWidth: 350, maxWidth: 420)
          planOverview
            .frame(minWidth: 520)
        }
      case .continuity:
        LongFormContinuityEditor(
          response: response,
          draft: $continuityDraft,
          validationMessage: continuityValidationMessage,
          isValidationPending: isContinuityValidationPending,
          isDirty: isContinuityDirty,
          isSaving: isSaving,
          save: saveContinuity,
          discard: discardContinuity
        )
      }
    }
  }

  private var constraintsEditor: some View {
    VStack(spacing: 0) {
      NativeSectionHeader(
        "结构约束",
        subtitle: isBudgetDirty ? "修订 \(response.revision) · 未保存" : "修订 \(response.revision)"
      ) {
        if isBudgetDirty {
          Image(systemName: "circle.fill")
            .font(.system(size: 7))
            .foregroundStyle(.orange)
            .accessibilityLabel("有未保存修改")
        }
      }
      .padding(12)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          planNumberField("目标总字数") {
            HStack(spacing: 7) {
              TextField(
                "600000",
                value: $draft.targetTotalWords,
                format: .number.grouping(.never)
              )
              Text("字")
                .foregroundStyle(.secondary)
            }
          }

          planNumberField("分卷数") {
            Stepper(value: $draft.volumeCount, in: 1...100) {
              Text("\(draft.volumeCount) 卷")
                .monospacedDigit()
            }
          }

          planNumberField("目标章字数") {
            Stepper(value: $draft.targetChapterWords, in: 500...20_000, step: 100) {
              Text("\(formatted(draft.targetChapterWords)) 字")
                .monospacedDigit()
            }
          }

          planNumberField("单章容差") {
            Stepper(value: $draft.chapterWordTolerance, in: 0...50) {
              Text("±\(draft.chapterWordTolerance)%")
                .monospacedDigit()
            }
          }

          VStack(alignment: .leading, spacing: 6) {
            Text("特殊约束")
              .font(.callout.weight(.medium))
            ZStack(alignment: .topLeading) {
              if specialConstraintsText.isEmpty {
                Text("人设、结构与内容边界")
                  .font(.callout)
                  .foregroundStyle(.tertiary)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 8)
                  .allowsHitTesting(false)
              }
              TextEditor(text: $specialConstraintsText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(2)
            }
            .frame(minHeight: 150)
            .background(
              .quaternary.opacity(0.35),
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
            }
            .accessibilityLabel("特殊约束")
          }

          if let budgetValidationMessage {
            Label(budgetValidationMessage, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(14)
      }

      Divider()

      HStack(spacing: 10) {
        Button("还原") { discardBudget() }
          .disabled(!isBudgetDirty || isSaving)
        Spacer()
        NativeActionButton(prominence: .prominent, action: saveBudget) {
          Label(isSaving ? "正在保存" : "保存计划", systemImage: "square.and.arrow.down")
        }
        .disabled(!isBudgetDirty || budgetValidationMessage != nil || isSaving)
        .keyboardShortcut("s", modifiers: .command)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceFooterHeight)
      .background(.bar)
    }
  }

  private var planOverview: some View {
    VStack(spacing: 0) {
      NativeSectionHeader(
        "计划与卷进度",
        subtitle: "\(response.plan.volumes.count) 卷 · \(response.plan.chapters.count) 个章节预算"
      ) {
        if isBudgetDirty {
          Label("待重新推导", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .padding(12)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          projectionSummary

          Divider()

          VStack(alignment: .leading, spacing: 12) {
            Text("分卷进度")
              .font(.headline)

            if response.plan.volumes.isEmpty {
              Text("暂无分卷计划")
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
              ForEach(response.plan.volumes) { volume in
                volumeProgressRow(volume)
                if volume.id != response.plan.volumes.last?.id {
                  Divider()
                }
              }
            }
          }
        }
        .padding(16)
        .frame(maxWidth: 980, alignment: .leading)
        .frame(maxWidth: .infinity)
      }

      Divider()

      Color.clear
        .frame(height: NativeLayout.workspaceFooterHeight)
        .background(.bar)
    }
  }

  private var projectionSummary: some View {
    let targetChapters = derivedTargetChapters
    let chapterRange = derivedChapterWordRange
    let writtenWords = chapters.reduce(0) { $0 + max($1.wordCount, 0) }
    let progress = min(Double(writtenWords), Double(max(draft.targetTotalWords, 1)))

    return VStack(alignment: .leading, spacing: 12) {
      Text("全书计划")
        .font(.headline)

      Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
        GridRow {
          planMetric("目标总字数", "\(formatted(draft.targetTotalWords)) 字")
          planMetric("推导章节", "\(targetChapters) 章")
          planMetric(
            "单章范围", "\(formatted(chapterRange.lowerBound))–\(formatted(chapterRange.upperBound)) 字")
        }
        GridRow {
          planMetric("当前章节", "\(chapters.count) 章")
          planMetric("当前字数", "\(formatted(writtenWords)) 字")
          planMetric("计划来源", sourceLabel)
        }
      }

      ProgressView(
        value: progress,
        total: Double(max(draft.targetTotalWords, 1))
      )
      .accessibilityLabel("全书字数进度")
      .accessibilityValue("\(writtenWords) / \(draft.targetTotalWords) 字")
    }
  }

  private func volumeProgressRow(_ volume: LongFormVolumePlan) -> some View {
    let written = chapters.filter {
      (volume.startChapter...volume.endChapter).contains($0.number)
    }
    let writtenWords = written.reduce(0) { $0 + max($1.wordCount, 0) }
    let chapterProgress = min(written.count, max(volume.chapterCount, 0))
    let wordProgress = min(writtenWords, max(volume.targetWords, 0))

    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("第 \(volume.number) 卷")
          .font(.callout.weight(.semibold))
        Text("第 \(volume.startChapter)–\(volume.endChapter) 章")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Text("目标 \(formatted(volume.targetWords)) 字")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 10) {
        ProgressView(
          value: Double(chapterProgress),
          total: Double(max(volume.chapterCount, 1))
        )
        .accessibilityLabel("第 \(volume.number) 卷章节进度")
        Text("\(written.count)/\(volume.chapterCount) 章")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 76, alignment: .trailing)
      }

      HStack(spacing: 10) {
        ProgressView(
          value: Double(wordProgress),
          total: Double(max(volume.targetWords, 1))
        )
        .tint(.green)
        .accessibilityLabel("第 \(volume.number) 卷字数进度")
        Text("\(formatted(writtenWords)) 字")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 76, alignment: .trailing)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func planNumberField<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.callout.weight(.medium))
      content()
    }
  }

  private func planMetric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.weight(.semibold).monospacedDigit())
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var derivedTargetChapters: Int {
    guard draft.targetTotalWords > 0, draft.targetChapterWords > 0 else { return 0 }
    return max(
      1,
      Int((Double(draft.targetTotalWords) / Double(draft.targetChapterWords)).rounded())
    )
  }

  private var derivedChapterWordRange: ClosedRange<Int> {
    let tolerance = min(max(draft.chapterWordTolerance, 0), 100)
    let lower = (draft.targetChapterWords * (100 - tolerance) + 50) / 100
    let upper = (draft.targetChapterWords * (100 + tolerance) + 50) / 100
    return lower...upper
  }

  private var sourceLabel: String {
    switch response.source.lowercased() {
    case "created":
      return "新建计划"
    case "migrated", "legacy", "derived":
      return "旧书推导"
    case "updated":
      return "已编辑计划"
    default:
      return response.source
    }
  }

  private func formatted(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }
}

private struct LongFormContinuityEditor: View {
  let response: LongFormPlanResponse
  @Binding var draft: LongFormContinuityDraft
  let validationMessage: String?
  let isValidationPending: Bool
  let isDirty: Bool
  let isSaving: Bool
  let save: () -> Void
  let discard: () -> Void

  @State private var selection: LongFormContinuitySection = .immutableCanon

  var body: some View {
    HSplitView {
      sectionList
        .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
      jsonEditor
        .frame(minWidth: 560)
    }
  }

  private var sectionList: some View {
    VStack(spacing: 0) {
      NativeSectionHeader(
        "连续性索引",
        subtitle: "\(totalItemCount) 项 · 修订 \(response.revision)"
      )
      .padding(12)

      Divider()

      List(selection: $selection) {
        ForEach(LongFormContinuitySection.allCases) { section in
          HStack(spacing: 9) {
            Image(systemName: section.icon)
              .foregroundStyle(.secondary)
              .frame(width: 18)
            Text(section.title)
              .lineLimit(1)
            Spacer(minLength: 6)
            Text(countLabel(for: section))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .tag(section)
          .help(section.detail)
        }
      }
      .listStyle(.sidebar)

      Divider()

      HStack(spacing: 7) {
        Text("连续性分组")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        Text("\(LongFormContinuitySection.allCases.count) 项")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceFooterHeight)
      .background(.bar)
    }
  }

  private var jsonEditor: some View {
    VStack(spacing: 0) {
      NativeSectionHeader(selection.title, subtitle: selection.detail) {
        if isDirty {
          Label("未保存", systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
        }
      }
      .padding(12)

      Divider()

      if selection == .policy {
        policyEditor
      } else {
        TextEditor(text: selectedText)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(10)
          .accessibilityLabel("\(selection.title) JSON")
      }

      Divider()

      VStack(alignment: .leading, spacing: 7) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("字段")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(selection.fieldSummary)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
          Spacer(minLength: 8)
          Text("\(response.plan.targetChapters) 章 · \(response.constraints.volumeCount) 卷")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
        }

        if isValidationPending {
          HStack(spacing: 7) {
            ProgressView()
              .controlSize(.small)
            Text("正在校验结构")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        } else if let validationMessage {
          Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Label("结构校验通过", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(.quaternary.opacity(0.22))

      Divider()

      HStack(spacing: 10) {
        Button("还原连续性") { discard() }
          .disabled(!isDirty || isSaving)
        Spacer()
        NativeActionButton(prominence: .prominent, action: save) {
          Label(
            isSaving ? "正在保存" : "保存连续性",
            systemImage: "square.and.arrow.down"
          )
        }
        .disabled(!isDirty || validationMessage != nil || isValidationPending || isSaving)
        .keyboardShortcut("s", modifiers: .command)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceFooterHeight)
      .background(.bar)
    }
  }

  private var selectedText: Binding<String> {
    Binding(
      get: { draft.text(for: selection) },
      set: { value in
        var updated = draft
        updated.setText(value, for: selection)
        draft = updated
      }
    )
  }

  private var policyEditor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        policyToggle(
          "跨卷连续",
          detail: "分卷边界连续且不允许跳卷写作",
          keyPath: \.requireContinuousVolumes
        )
        Divider()
        policyToggle(
          "允许未规划实体",
          detail: "正文可引入连续性索引中尚未登记的人物或物件",
          keyPath: \.allowUnplannedEntities
        )
        Divider()
        policyToggle(
          "要求一致性差量",
          detail: "每章结算必须返回时间线、实体、知识与设定变化",
          locked: true,
          keyPath: \.requireConsistencyDelta
        )
        Divider()
        policyToggle(
          "卷末检查点",
          detail: "每卷结束时生成可追溯的 canon checkpoint",
          keyPath: \.checkpointAtVolumeEnd
        )
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  private func policyToggle(
    _ title: String,
    detail: String,
    locked: Bool = false,
    keyPath: WritableKeyPath<LongFormContinuityPolicy, Bool>
  ) -> some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 16)
      if locked {
        Image(systemName: "lock.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("内置连续性投影需要章节差量")
          .accessibilityLabel("系统必需")
      }
      Toggle("", isOn: policyBinding(keyPath))
        .labelsHidden()
        .toggleStyle(.switch)
        .accessibilityLabel(title)
        .frame(width: 52, alignment: .trailing)
        .disabled(locked)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 14)
  }

  private func policyBinding(
    _ keyPath: WritableKeyPath<LongFormContinuityPolicy, Bool>
  ) -> Binding<Bool> {
    Binding(
      get: { draft.policy[keyPath: keyPath] },
      set: { value in
        var updated = draft
        updated.policy[keyPath: keyPath] = value
        draft = updated
      }
    )
  }

  private var totalItemCount: Int {
    response.continuity.immutableCanon.count
      + response.continuity.worldRules.count
      + response.continuity.entities.count
      + response.continuity.knowledgeBoundaries.count
      + response.continuity.timeline.count
      + response.continuity.hooks.count
  }

  private func countLabel(for section: LongFormContinuitySection) -> String {
    let count: Int
    switch section {
    case .immutableCanon:
      count = response.continuity.immutableCanon.count
    case .worldRules:
      count = response.continuity.worldRules.count
    case .entities:
      count = response.continuity.entities.count
    case .knowledgeBoundaries:
      count = response.continuity.knowledgeBoundaries.count
    case .timeline:
      count = response.continuity.timeline.count
    case .hooks:
      count = response.continuity.hooks.count
    case .policy:
      return "4"
    }
    return String(count)
  }
}
