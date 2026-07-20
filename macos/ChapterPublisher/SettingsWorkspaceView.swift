import Combine
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

struct SettingsWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject var drafts: BookSettingDraftStore

  private enum SettingsTab: String, CaseIterable, Identifiable {
    case book = "书籍设定"
    case llm = "LLM 设置"

    var id: String { rawValue }
  }

  @State private var tab: SettingsTab = .book
  @State private var editorDraft = ""
  @State private var editorBookID: String?
  @State private var editorPath: String?

  @State private var baseURL = ""
  @State private var apiKey = ""
  @State private var modelName = ""
  @State private var reviewBaseURL = ""
  @State private var reviewAPIKey = ""
  @State private var reviewModelName = ""
  @State private var stream = false
  @State private var thinkingBudget = 0
  @State private var temperature = 0.2
  @State private var chapterModels: [RemoteModel] = []
  @State private var reviewModels: [RemoteModel] = []
  @State private var chapterProbe: ModelTestResponse?
  @State private var reviewProbe: ModelTestResponse?
  @State private var isDiscoveringChapterModels = false
  @State private var isDiscoveringReviewModels = false
  @State private var isProbingChapterModel = false
  @State private var isProbingReviewModel = false
  @State private var chapterDiscoveryRequest = UUID()
  @State private var reviewDiscoveryRequest = UUID()
  @State private var chapterProbeRequest = UUID()
  @State private var reviewProbeRequest = UUID()

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
      loadConfigDraft()
      syncEditorDraft()
    }
    .onChange(of: model.inkOSConfig) { _ in loadConfigDraft() }
    .onChange(of: model.currentBookID) { _ in syncEditorDraft() }
    .onChange(of: model.selectedSettingPath) { _ in syncEditorDraft() }
    .onChange(of: model.selectedSettingContent) { _ in syncEditorDraft() }
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
      if reviewBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reviewModels = []
        reviewProbe = nil
      }
    }
    .onChange(of: reviewBaseURL) { _ in
      reviewModels = []
      reviewProbe = nil
    }
    .onChange(of: apiKey) { _ in
      chapterProbe = nil
      if reviewAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        reviewProbe = nil
      }
    }
    .onChange(of: reviewAPIKey) { _ in reviewProbe = nil }
    .onChange(of: modelName) { _ in chapterProbe = nil }
    .onChange(of: reviewModelName) { _ in reviewProbe = nil }
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
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
  }

  private var bookSettings: some View {
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
                  Label(file.title, systemImage: "doc.text")
                    .tag(Optional(file.path))
                    .help(file.path)
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
    probing: Bool
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
              TextField("模型名称", text: model)
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

  private func loadConfigDraft() {
    guard let config = model.inkOSConfig else { return }
    baseURL = config.baseUrl
    reviewBaseURL = config.reviewBaseUrl
    modelName = config.model
    reviewModelName = config.reviewModel
    stream = config.stream ?? false
    thinkingBudget = config.thinkingBudget
    temperature = config.temperature ?? 0.2
    apiKey = ""
    reviewAPIKey = ""
    chapterModels = []
    reviewModels = []
    chapterProbe = nil
    reviewProbe = nil
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
    if role == .chapter {
      chapterDiscoveryRequest = requestID
      isDiscoveringChapterModels = true
    } else {
      reviewDiscoveryRequest = requestID
      isDiscoveringReviewModels = true
    }
    Task {
      let values = await model.loadModels(
        role: role,
        baseURL: endpoint.baseURL,
        apiKey: endpoint.apiKey
      )
      if role == .chapter {
        guard chapterDiscoveryRequest == requestID else { return }
        isDiscoveringChapterModels = false
        guard endpointMatches(endpoint, role: role) else { return }
        chapterModels = values
        if !values.isEmpty, !values.contains(where: { $0.id == modelName }) {
          modelName = values[0].id
        }
      } else {
        guard reviewDiscoveryRequest == requestID else { return }
        isDiscoveringReviewModels = false
        guard endpointMatches(endpoint, role: role) else { return }
        reviewModels = values
        if !values.isEmpty, !values.contains(where: { $0.id == reviewModelName }) {
          reviewModelName = values[0].id
        }
      }
    }
  }

  private func probeModel(_ role: ModelRole) {
    let endpoint = endpointValues(for: role)
    guard !endpoint.model.isEmpty else { return }
    let requestID = UUID()
    if role == .chapter {
      chapterProbeRequest = requestID
      chapterProbe = nil
      isProbingChapterModel = true
    } else {
      reviewProbeRequest = requestID
      reviewProbe = nil
      isProbingReviewModel = true
    }
    Task {
      let response = await model.testModel(
        role: role,
        model: endpoint.model,
        baseURL: endpoint.baseURL,
        apiKey: endpoint.apiKey
      )
      if role == .chapter {
        guard chapterProbeRequest == requestID else { return }
        isProbingChapterModel = false
        guard endpointMatches(endpoint, role: role) else { return }
        chapterProbe = response
      } else {
        guard reviewProbeRequest == requestID else { return }
        isProbingReviewModel = false
        guard endpointMatches(endpoint, role: role) else { return }
        reviewProbe = response
      }
    }
  }

  private func saveLLMSettings() {
    guard canSaveLLMSettings else { return }
    let update = InkOSConfigUpdate(
      model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
      reviewModel: reviewModelName.trimmingCharacters(in: .whitespacesAndNewlines),
      baseUrl: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      reviewBaseUrl: reviewBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
      apiKey: apiKey,
      reviewApiKey: reviewAPIKey,
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
    return (!chapterChanged || chapterProbe?.ok == true)
      && (!reviewChanged || reviewProbe?.ok == true)
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
