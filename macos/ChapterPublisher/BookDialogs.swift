import SwiftUI

struct CreateBookSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var titleFocused: Bool
  @State private var request = CreateBookRequest()
  @State private var requirements = ""
  @State private var isAssisting = false
  @State private var assistCompleted = false
  @State private var isSubmitting = false

  private var canSubmit: Bool {
    !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && request.targetChapters > 0
      && request.chapterWords >= 500
      && !isAssisting
      && !isSubmitting
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

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          dialogSection("快速创建") {
            VStack(alignment: .leading, spacing: 8) {
              ZStack(alignment: .topLeading) {
                if requirements.isEmpty {
                  Text("例如：番茄玄幻，落魄符师修复禁忌古符破局，200 章，每章 3000 字")
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
                  .onChange(of: requirements) { _ in assistCompleted = false }
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
                    || isAssisting || isSubmitting
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
                dialogField("目标章数") {
                  Stepper(value: $request.targetChapters, in: 1...10_000, step: 10) {
                    Text("\(request.targetChapters) 章")
                      .monospacedDigit()
                  }
                }
                dialogField("单章字数") {
                  Stepper(value: $request.chapterWords, in: 500...50_000, step: 100) {
                    Text("\(request.chapterWords) 字")
                      .monospacedDigit()
                  }
                }
              }

              GridRow {
                dialogField("总字数要求") {
                  TextField("例如：60 万字", text: $request.totalWords)
                }
                dialogField("节奏要求") {
                  TextField("例如：前三章强钩子", text: $request.pacing)
                }
              }
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
            createTextArea("禁忌与特别要求", placeholder: "必须规避或持续遵守的内容", text: $request.constraints)
          }
        }
        .padding(20)
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
      titleFocused = true
    }
    .interactiveDismissDisabled(isSubmitting || isAssisting)
  }

  private func submit() {
    guard canSubmit else { return }
    request.title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
    isSubmitting = true
    Task {
      let response = await model.createBook(request)
      isSubmitting = false
      if response != nil {
        dismiss()
      }
    }
  }

  private func assistCreation() {
    let trimmed = requirements.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !isAssisting else { return }
    isAssisting = true
    assistCompleted = false
    Task {
      if let generated = await model.assistCreateBook(requirements: trimmed) {
        request = generated
        assistCompleted = true
      }
      isAssisting = false
    }
  }

  private func createTextArea(
    _ title: String,
    placeholder: String,
    text: Binding<String>,
    minHeight: CGFloat = 68
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
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
