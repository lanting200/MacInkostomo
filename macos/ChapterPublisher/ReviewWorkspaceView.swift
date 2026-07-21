import SwiftUI

struct ReviewWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var bookSearch = ""
  @State private var chapterSearch = ""
  @State private var showingCreateBook = false
  @State private var showingImportBook = false
  @State private var deletingBook: BookSummary?
  @State private var showingReject = false
  @State private var showingGenerate = false

  var body: some View {
    HSplitView {
      bookSidebar
        .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)

      chapterSidebar
        .frame(minWidth: 230, idealWidth: 285, maxWidth: 360)

      chapterDetail
        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .underPageBackgroundColor))
    .sheet(isPresented: $showingCreateBook) {
      CreateBookSheet(model: model)
    }
    .sheet(isPresented: $showingImportBook) {
      ImportBookSheet(model: model)
    }
    .sheet(item: $deletingBook) { book in
      DeleteBookSheet(model: model, book: book)
    }
    .sheet(isPresented: $showingReject) {
      RejectChapterSheet(model: model)
    }
    .sheet(isPresented: $showingGenerate) {
      GenerateChapterSheet(model: model)
    }
  }

  private var bookSidebar: some View {
    VStack(spacing: 0) {
      NativeSectionHeader("作品", subtitle: "\(model.books.count) 本") {
        AdaptiveGlassGroup(spacing: 6) {
          HStack(spacing: 5) {
            NativeIconButton(title: "导入本地作品", systemImage: "square.and.arrow.down") {
              showingImportBook = true
            }
            NativeIconButton(title: "新建小说", systemImage: "plus", prominence: .prominent) {
              showingCreateBook = true
            }
            .keyboardShortcut("n", modifiers: .command)
          }
        }
      }
      .padding(.horizontal, 12)
      .frame(height: NativeLayout.workspaceHeaderHeight)

      NativeSearchField(prompt: "搜索作品", text: $bookSearch)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(height: NativeLayout.workspaceUtilityHeight, alignment: .top)

      Divider()

      Group {
        if model.books.isEmpty {
          NativeEmptyState(
            title: "书库为空",
            detail: "新建小说，或导入 InkOS 工作区中的已有作品。",
            systemImage: "books.vertical",
            actionTitle: "新建小说",
            action: { showingCreateBook = true }
          )
        } else if filteredBooks.isEmpty {
          NativeEmptyState(
            title: "没有匹配的作品",
            detail: "调整搜索关键词后重试。",
            systemImage: "magnifyingglass"
          )
        } else {
          List(selection: bookSelection) {
            ForEach(filteredBooks) { book in
              BookSidebarRow(book: book)
                .tag(Optional(book.id))
            }
          }
          .listStyle(.sidebar)
          .scrollContentBackground(.hidden)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      HStack(spacing: 6) {
        NativeIconButton(
          title: "刷新作品",
          systemImage: "arrow.clockwise",
          disabled: model.isLoading
        ) {
          Task { await model.refreshBooks() }
        }
        Spacer()
        NativeIconButton(
          title: "删除所选作品",
          systemImage: "trash",
          prominence: .destructive,
          disabled: selectedBook == nil || model.isMutating
        ) {
          deletingBook = selectedBook
        }
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceFooterHeight)
      .background(.bar)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.38))
  }

  private var chapterSidebar: some View {
    VStack(spacing: 0) {
      NativeSectionHeader(
        selectedBook?.title ?? "章节",
        subtitle: chapterHeaderSubtitle
      ) {
        NativeIconButton(
          title: "刷新章节",
          systemImage: "arrow.clockwise",
          disabled: model.currentBookID == nil || model.isLoading
        ) {
          Task { await model.refreshChapters() }
        }
      }
      .padding(.horizontal, 12)
      .frame(height: NativeLayout.workspaceHeaderHeight)

      NativeSearchField(prompt: "搜索章节", text: $chapterSearch)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .frame(height: NativeLayout.workspaceUtilityHeight, alignment: .top)

      Divider()

      Group {
        if model.currentBookID == nil {
          NativeEmptyState(
            title: "选择作品",
            detail: "从左侧书库选择一本小说查看章节。",
            systemImage: "rectangle.and.hand.point.up.left"
          )
        } else if model.chapters.isEmpty {
          NativeEmptyState(
            title: "还没有章节",
            detail: "从第 1 章开始生成，完成后会自动进入审核流程。",
            systemImage: "doc.badge.plus",
            actionTitle: "生成新章节",
            action: { showingGenerate = true }
          )
        } else if filteredChapters.isEmpty {
          NativeEmptyState(
            title: "没有匹配的章节",
            detail: "可按章节号、标题或状态搜索。",
            systemImage: "magnifyingglass"
          )
        } else {
          List(selection: chapterSelection) {
            ForEach(filteredChapters) { chapter in
              ChapterSidebarRow(chapter: chapter)
                .tag(Optional(chapter.number))
            }
          }
          .listStyle(.sidebar)
          .scrollContentBackground(.hidden)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      HStack(spacing: 8) {
        if let context = model.chapterContext, let currentVolume = context.currentVolume {
          Image(systemName: "bookmark")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("卷\(currentVolume.num) · \(currentVolume.displayTitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(currentVolume.displayTitle)
        } else {
          Text(model.currentBookID == nil ? "尚未选择作品" : "未设置分卷")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceFooterHeight)
      .background(.bar)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.22))
  }

  @ViewBuilder
  private var chapterDetail: some View {
    if let chapter = model.currentChapter {
      ChapterReviewDetail(
        chapter: chapter,
        isMutating: model.isMutating,
        approve: { Task { await model.approveCurrentChapter() } },
        reject: { showingReject = true },
        generate: { showingGenerate = true }
      )
    } else if model.isLoading, model.currentChapterNumber != nil {
      ReviewDetailPlaceholder(title: "章节审核", detail: "正在加载章节") {
        VStack(spacing: 12) {
          ProgressView()
          Text("正在加载章节")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    } else {
      ReviewDetailPlaceholder(
        title: model.currentBookID == nil ? "作品审核工作台" : "章节审核",
        detail: model.currentBookID == nil ? "等待选择作品" : "等待选择章节"
      ) {
        NativeEmptyState(
          title: model.currentBookID == nil ? "作品审核工作台" : "选择章节开始审核",
          detail: model.currentBookID == nil
            ? "左侧管理作品，中间浏览章节，右侧完成正文终审。"
            : "章节正文、初审结论与人工操作会显示在这里。",
          systemImage: "checkmark.seal"
        )
      }
    }
  }

  private var filteredBooks: [BookSummary] {
    let query = bookSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.books }
    return model.books.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.id.localizedCaseInsensitiveContains(query)
    }
  }

  private var filteredChapters: [ChapterSummary] {
    let query = chapterSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.chapters }
    return model.chapters.filter {
      String($0.number).contains(query)
        || $0.title.localizedCaseInsensitiveContains(query)
        || ChapterVisualStatus(rawStatus: $0.status).label.localizedCaseInsensitiveContains(query)
        || $0.status.localizedCaseInsensitiveContains(query)
    }
  }

  private var selectedBook: BookSummary? {
    guard let currentBookID = model.currentBookID else { return nil }
    return model.books.first { $0.id == currentBookID }
  }

  private var chapterHeaderSubtitle: String {
    guard model.currentBookID != nil else { return "选择作品后显示" }
    return "\(model.chapters.count) 章 · 待审 \(selectedBook?.pendingReview ?? 0)"
  }

  private var bookSelection: Binding<String?> {
    Binding(
      get: { model.currentBookID },
      set: { bookID in
        guard bookID != model.currentBookID else { return }
        Task { await model.selectBook(bookID) }
      }
    )
  }

  private var chapterSelection: Binding<Int?> {
    Binding(
      get: { model.currentChapterNumber },
      set: { chapterNumber in
        guard chapterNumber != model.currentChapterNumber else { return }
        Task { await model.selectChapter(chapterNumber) }
      }
    )
  }
}

private struct BookSidebarRow: View {
  let book: BookSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(book.title)
          .font(.callout.weight(.medium))
          .lineLimit(2)
        Spacer(minLength: 4)
        Text("\(book.chapterCount)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 9) {
        statusCount(color: .orange, value: book.pendingReview, label: "待审")
        statusCount(color: .green, value: book.approved, label: "已通过")
        if book.rejected > 0 {
          statusCount(color: .red, value: book.rejected, label: "待修改")
        }
      }
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(book.title)，共 \(book.chapterCount) 章，待审 \(book.pendingReview)，已通过 \(book.approved)，待修改 \(book.rejected)"
    )
  }

  private func statusCount(color: Color, value: Int, label: String) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text("\(value)")
        .monospacedDigit()
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .help("\(label) \(value)")
  }
}

private struct ChapterSidebarRow: View {
  let chapter: ChapterSummary

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ChapterStatusBadge(status: chapter.status, compact: true)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 4) {
        Text("第\(chapter.number)章 \(chapter.title)")
          .font(.callout.weight(.medium))
          .lineLimit(2)
        HStack(spacing: 5) {
          Text("\(chapter.wordCount) 字")
          if chapter.revisionCount > 0 {
            Text("· 修改 \(chapter.revisionCount) 次")
          }
          if let volume = chapter.volume {
            Text("· 卷 \(volume)")
          }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      Spacer(minLength: 3)
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "第 \(chapter.number) 章，\(chapter.title)，\(ChapterVisualStatus(rawStatus: chapter.status).label)，\(chapter.wordCount) 字"
    )
  }
}

private struct ChapterReviewDetail: View {
  let chapter: ChapterDetail
  let isMutating: Bool
  let approve: () -> Void
  let reject: () -> Void
  let generate: () -> Void

  private var canApprove: Bool {
    ["ready-for-review", "audit-passed", "drafted", "pending_review"].contains(chapter.status)
      && chapter.llmReview?.isPassed == true
      && !isMutating
  }

  private var canReject: Bool {
    !isMutating
      && chapter.llmReview?.isBusy != true
      && [
        "ready-for-review", "audit-passed", "drafted", "audit-failed",
        "state-degraded", "rejected", "pending_review", "revision_failed",
      ].contains(chapter.status)
  }

  var body: some View {
    VStack(spacing: 0) {
      ChapterReviewHeader(chapter: chapter)

      NativeChapterTextReader(content: chapter.content)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      HStack(spacing: 8) {
        NativeActionButton(action: generate) {
          Label("生成下一章", systemImage: "wand.and.stars")
        }
        .keyboardShortcut("g", modifiers: .command)
        .disabled(isMutating)
        .help("生成下一章（Command-G）")

        Spacer(minLength: 8)

        NativeActionButton(prominence: .standard, action: reject) {
          Label("驳回修改", systemImage: "arrow.uturn.backward")
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .disabled(!canReject)
        .help(canReject ? "提交修改意见（Command-Shift-Return）" : "当前章节暂不支持驳回")

        NativeActionButton(prominence: .prominent, action: approve) {
          Label("通过", systemImage: "checkmark")
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canApprove)
        .help(canApprove ? "通过终审（Command-Return）" : "初审通过后才能进行人工终审")
      }
      .controlSize(.regular)
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceFooterHeight)
      .background(.bar)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }
}

private struct ReviewDetailPlaceholder<Content: View>: View {
  let title: String
  let detail: String
  private let content: Content

  init(
    title: String,
    detail: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.detail = detail
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceHeaderHeight)

      HStack(spacing: 7) {
        Image(systemName: "checkmark.seal")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceUtilityHeight)

      Divider()

      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      Color.clear
        .frame(height: NativeLayout.workspaceFooterHeight)
        .background(.bar)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }
}

private struct ChapterReviewHeader: View {
  let chapter: ChapterDetail
  @State private var showingReviewDetails = false
  @State private var showingRevisionHistory = false
  @State private var showingInkosWarnings = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("第\(chapter.number)章 \(chapter.title)")
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.tail)
          .help("第\(chapter.number)章 \(chapter.title)")
        Spacer(minLength: 8)
        ChapterStatusBadge(status: chapter.status)
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceHeaderHeight)

      HStack(spacing: 7) {
        Label("章节正文", systemImage: "doc.text")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        Text(chapterMetadata)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if !chapter.revisionHistory.isEmpty {
          ReviewHeaderIconButton(
            title: "查看修改记录（\(chapter.revisionHistory.count) 条）",
            systemImage: "clock.arrow.circlepath",
            color: .secondary
          ) {
            showingRevisionHistory = true
          }
          .popover(isPresented: $showingRevisionHistory, arrowEdge: .bottom) {
            RevisionHistoryPopoverContent(records: chapter.revisionHistory)
          }
        }
        SystemReviewBadge(
          review: chapter.llmReview,
          chapterStatus: chapter.status,
          action: chapter.llmReview == nil ? nil : { showingReviewDetails = true }
        )
        .popover(isPresented: $showingReviewDetails, arrowEdge: .bottom) {
          if let review = chapter.llmReview {
            ReviewStatusPopoverContent(review: review)
          } else {
            EmptyView()
          }
        }
        if hasInkosWarnings {
          ReviewHeaderIconButton(
            title: "查看 InkOS 校验提示（\(inkosWarnings.count) 条）",
            systemImage: "exclamationmark.triangle.fill",
            color: .orange
          ) {
            showingInkosWarnings = true
          }
          .popover(isPresented: $showingInkosWarnings, arrowEdge: .bottom) {
            InkOSWarningsPopoverContent(warnings: inkosWarnings)
          }
        }
      }
      .padding(.horizontal, 14)
      .frame(height: NativeLayout.workspaceUtilityHeight)

      Divider()
    }
  }

  private var chapterMetadata: String {
    var values = ["\(chapter.wordCount) 字"]
    if let volume = chapter.volume {
      values.append("卷 \(volume)")
    }
    if !chapter.revisionHistory.isEmpty {
      values.append("修改 \(chapter.revisionHistory.count) 次")
    }
    return values.joined(separator: " · ")
  }

  private var inkosWarnings: [String] {
    chapter.auditIssues + chapter.lengthWarnings
  }

  private var hasInkosWarnings: Bool {
    !inkosWarnings.isEmpty
  }
}

private struct SystemReviewBadge: View {
  let review: LLMReview?
  let chapterStatus: String
  var action: (() -> Void)?

  @ViewBuilder
  var body: some View {
    let visual = SystemReviewVisual(review: review, chapterStatus: chapterStatus)
    if let action {
      Button(action: action) {
        badgeLabel(visual)
      }
      .buttonStyle(.plain)
      .help(visual.help)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(visual.help)
    } else {
      badgeLabel(visual)
        .help(visual.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(visual.help)
    }
  }

  private func badgeLabel(_ visual: SystemReviewVisual) -> some View {
    HStack(spacing: 4) {
      Image(systemName: visual.systemImage)
        .accessibilityHidden(true)
      Text("初审 \(visual.label)")
        .lineLimit(1)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(visual.color)
    .padding(.horizontal, 7)
    .frame(height: 22)
    .background(visual.color.opacity(0.12), in: Capsule())
  }
}

private struct ReviewHeaderIconButton: View {
  let title: String
  let systemImage: String
  let color: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(color)
        .frame(width: 28, height: 28)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }
}

private struct SystemReviewVisual {
  let label: String
  let help: String
  let systemImage: String
  let color: Color

  init(review: LLMReview?, chapterStatus: String? = nil) {
    guard let review else {
      if let chapterStatus, ["approved", "published"].contains(chapterStatus) {
        label = "历史章节"
        help = "本章已完成审核，旧版系统初审记录未存档"
        systemImage = "archivebox"
      } else {
        label = "未记录"
        help = "系统 LLM 初审记录缺失，需要先完成初审后再人工通过"
        systemImage = "questionmark.circle"
      }
      color = .secondary
      return
    }

    switch review.status {
    case "inkos_writing":
      label = "生成中"
      help = "InkOS 正在生成并自审章节"
      systemImage = "clock.arrow.circlepath"
      color = .blue
    case "inkos_revising":
      label = "修改中"
      help = "InkOS 正在根据修改意见修订章节"
      systemImage = "clock.arrow.circlepath"
      color = .blue
    case "inkos_failed":
      label = "InkOS 未过"
      help = "InkOS 自审未通过，需先修改章节"
      systemImage = "exclamationmark.triangle.fill"
      color = .orange
    case "reviewing":
      label = "审核中"
      help = "系统 LLM 正在初审章节"
      systemImage = "clock.arrow.circlepath"
      color = .blue
    case "fixing":
      label = "自动修改中"
      help = "系统正根据初审意见自动修改章节"
      systemImage = "arrow.triangle.2.circlepath"
      color = .blue
    case "passed":
      label = "通过"
      help = "系统 LLM 初审已通过，可进行人工终审"
      systemImage = "checkmark.seal.fill"
      color = .green
    case "failed":
      label = "未通过"
      help = "系统 LLM 初审未通过，需先修改章节"
      systemImage = "exclamationmark.triangle.fill"
      color = .orange
    case "error":
      label = "异常"
      help = "系统 LLM 初审异常，需先重新修改或检查任务日志"
      systemImage = "xmark.octagon.fill"
      color = .red
    default:
      label = review.status
      help = "系统 LLM 初审状态：\(review.status)"
      systemImage = "questionmark.circle"
      color = .secondary
    }
  }
}

private struct ReviewStatusPopoverContent: View {
  let review: LLMReview

  var body: some View {
    let visual = SystemReviewVisual(review: review)
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: visual.systemImage)
            .foregroundStyle(visual.color)
            .accessibilityHidden(true)
          Text("初审状态")
            .font(.headline)
          Text(visual.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(visual.color)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(visual.color.opacity(0.12), in: Capsule())
          Spacer(minLength: 8)
          if let model = review.model, !model.isEmpty {
            Text(model)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        if let summary = review.summary, !summary.isEmpty {
          Text(summary)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }

        if review.autoFixed == true {
          Label("已根据初审意见自动处理过一次", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if !review.issueList.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 7) {
            Text("需要处理")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            ForEach(Array(review.issueList.enumerated()), id: \.offset) { index, issue in
              HStack(alignment: .top, spacing: 7) {
                Text("\(index + 1).")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(visual.color)
                Text(cleanIssue(issue))
                  .font(.callout)
                  .fixedSize(horizontal: false, vertical: true)
                  .textSelection(.enabled)
              }
            }
          }
        }

        if let guidance = review.revisionGuidance, !guidance.isEmpty {
          DisclosureGroup("修改建议") {
            Text(guidance)
              .font(.callout)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .padding(.top, 6)
          }
        }
      }
    }
    .padding(16)
    .frame(width: 460, height: 360, alignment: .topLeading)
    .accessibilityElement(children: .contain)
  }

  private func cleanIssue(_ issue: String) -> String {
    issue.replacingOccurrences(
      of: #"^\s*\[(critical|warning|info|error)\]\s*"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
  }
}

private struct InkOSWarningsPopoverContent: View {
  let warnings: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("InkOS 校验提示", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundStyle(.orange)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
            HStack(alignment: .top, spacing: 8) {
              Text("\(index + 1).")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
              Text(warning)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
          }
        }
      }
    }
    .padding(16)
    .frame(width: 460, height: 320, alignment: .topLeading)
  }
}

private struct RevisionHistoryPopoverContent: View {
  let records: [RevisionRecord]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("修改记录（\(records.count)）", systemImage: "clock.arrow.circlepath")
        .font(.headline)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(records.enumerated().reversed()), id: \.offset) { _, record in
            VStack(alignment: .leading, spacing: 3) {
              HStack(spacing: 7) {
                Image(systemName: record.success == false ? "xmark.circle" : "clock.arrow.circlepath")
                  .foregroundStyle(record.success == false ? .red : .secondary)
                  .accessibilityHidden(true)
                Text(record.time ?? "时间未知")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              if let note = record.note, !note.isEmpty {
                Text(note)
                  .font(.callout)
                  .textSelection(.enabled)
              }
              if let error = record.error, !error.isEmpty {
                Text(error)
                  .font(.caption)
                  .foregroundStyle(.red)
                  .textSelection(.enabled)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
          }
        }
      }
    }
    .padding(16)
    .frame(width: 460, height: 360, alignment: .topLeading)
  }
}

private struct RejectChapterSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editorFocused: Bool
  @State private var note = ""
  @State private var isSubmitting = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.uturn.backward.circle.fill")
          .font(.title2)
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("提交修改意见")
            .font(.title3.weight(.semibold))
          if let chapter = model.currentChapter {
            Text("第\(chapter.number)章 \(chapter.title)")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
      }
      .padding(16)

      Divider()

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        NativeErrorBanner(message: errorMessage, dismiss: model.clearError)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("明确说明需要修改的问题、预期结果以及必须保留的内容。")
          .font(.callout)
          .foregroundStyle(.secondary)
        TextEditor(text: $note)
          .font(.body)
          .focused($editorFocused)
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
          .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
          .accessibilityLabel("章节修改意见")
      }
      .padding(16)
      .frame(minHeight: 210)

      Divider()

      HStack(spacing: 10) {
        Text("InkOS 将根据意见重写本章，并重新进入审核流程。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSubmitting)
        NativeActionButton(prominence: .prominent) {
          submit()
        } label: {
          Label(isSubmitting ? "正在提交" : "提交修改", systemImage: "paperplane")
        }
        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 560, minHeight: 340)
    .onAppear {
      model.clearError()
      note = suggestedRevisionNote
      editorFocused = true
    }
    .interactiveDismissDisabled(isSubmitting)
  }

  private var suggestedRevisionNote: String {
    guard let review = model.currentChapter?.llmReview else { return "" }
    if let guidance = review.revisionGuidance?.trimmingCharacters(in: .whitespacesAndNewlines),
      !guidance.isEmpty
    {
      return guidance
    }
    return review.issueList
      .map {
        $0.replacingOccurrences(of: #"^\s*\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
      }
      .enumerated()
      .map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")
  }

  private func submit() {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    isSubmitting = true
    Task {
      let response = await model.rejectCurrentChapter(note: trimmed, mode: "rewrite")
      isSubmitting = false
      if response != nil {
        dismiss()
      }
    }
  }
}

private struct GenerateChapterSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editorFocused: Bool
  @State private var guidance = ""
  @State private var isSubmitting = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "wand.and.stars")
          .font(.title2)
          .foregroundStyle(.purple)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("生成新章节")
            .font(.title3.weight(.semibold))
          Text(nextChapterLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(16)

      Divider()

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        NativeErrorBanner(message: errorMessage, dismiss: model.clearError)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("本章方向（可选）")
          .font(.callout.weight(.medium))
        ZStack(alignment: .topLeading) {
          if guidance.isEmpty {
            Text("例如：推进当前冲突，引入关键线索，侧重人物对话")
              .font(.callout)
              .foregroundStyle(.tertiary)
              .padding(10)
              .allowsHitTesting(false)
          }
          TextEditor(text: $guidance)
            .font(.body)
            .focused($editorFocused)
            .scrollContentBackground(.hidden)
            .padding(6)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
        .accessibilityLabel("新章节生成方向")
        Text("InkOS 会遵循作品设定、大纲、分卷和已有剧情。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(16)
      .frame(minHeight: 190)

      Divider()

      HStack(spacing: 10) {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isSubmitting)
        NativeActionButton(prominence: .prominent) {
          submit()
        } label: {
          Label(isSubmitting ? "正在启动" : "开始生成", systemImage: "play.fill")
        }
        .disabled(model.currentBookID == nil || isSubmitting)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 540, minHeight: 320)
    .onAppear {
      model.clearError()
      editorFocused = true
    }
    .interactiveDismissDisabled(isSubmitting)
  }

  private var nextChapterLabel: String {
    if let number = model.chapterContext?.nextChapterNum {
      return "即将生成第 \(number) 章"
    }
    return "根据当前书稿生成下一章"
  }

  private func submit() {
    guard model.currentBookID != nil else { return }
    isSubmitting = true
    let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      let response = await model.generateNextChapter(guidance: trimmed)
      isSubmitting = false
      if response != nil {
        dismiss()
      }
    }
  }
}
