import AppKit
import SwiftUI
import WebKit

private enum FanqieTransferMode: String, Identifiable {
  case upload
  case replace

  var id: String { rawValue }
}

struct FanqieWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var selectedChapterID: String?
  @State private var showLogoutConfirmation = false
  @State private var showingLogin = false
  @State private var showingCreateBook = false
  @State private var transferMode: FanqieTransferMode?
  @State private var bookSearch = ""
  @State private var chapterSearch = ""

  var body: some View {
    VStack(spacing: 0) {
      fanqieToolbar
      Divider()

      if model.fanqieLogin == nil, model.isLoading {
        NativeEmptyState(
          title: "正在连接番茄",
          detail: "",
          systemImage: "arrow.triangle.2.circlepath"
        )
      } else if model.fanqieLogin?.loggedIn != true {
        NativeEmptyState(
          title: "番茄账号未连接",
          detail: model.fanqieLogin?.reason ?? "请在应用内登录番茄作者端",
          systemImage: "person.crop.circle.badge.exclamationmark",
          actionTitle: "登录番茄",
          action: { showingLogin = true }
        )
      } else {
        HSplitView {
          bookList
            .frame(minWidth: 220, idealWidth: 270, maxWidth: 340)
          chapterList
            .frame(minWidth: 250, idealWidth: 320, maxWidth: 390)
          chapterContent
            .frame(minWidth: 420)
        }
      }
    }
    // Refresh is driven by WorkspaceModel.selectSection(.fanqie) and by the
    // login/logout/create flows. A duplicate .task here raced the entry
    // refresh, doubled the network chain, and kept the pane on the blocking
    // "正在连接番茄" placeholder much longer.
    .sheet(isPresented: $showingLogin) {
      FanqieLoginSheet(model: model)
    }
    .sheet(isPresented: $showingCreateBook) {
      FanqieCreateBookSheet(model: model)
    }
    .sheet(item: $transferMode) { mode in
      if let book = model.selectedFanqieBook {
        FanqieChapterTransferSheet(
          model: model,
          mode: mode,
          remoteBook: book,
          remoteChapter: mode == .replace ? selectedFanqieChapter : nil
        )
      }
    }
    .confirmationDialog(
      "退出番茄账号？",
      isPresented: $showLogoutConfirmation,
      titleVisibility: .visible
    ) {
      Button("退出账号", role: .destructive) {
        Task {
          _ = await model.logoutFanqie()
          await FanqieWebSessionStore.clear()
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("应用内番茄会话和 Cookie 将被清除。")
    }
  }

  private var fanqieToolbar: some View {
    HStack(spacing: 12) {
      NativeSectionHeader(
        "番茄在线",
        subtitle: model.fanqieAccount?.authorName
          ?? (model.fanqieLogin?.loggedIn == true ? "已连接" : "未连接")
      )
      Spacer()
      NativeIconButton(
        title: "刷新番茄数据",
        systemImage: "arrow.clockwise",
        disabled: model.isLoading
      ) {
        Task { await model.refreshFanqie(force: true) }
      }
      if model.fanqieLogin?.loggedIn == true {
        NativeActionButton(prominence: .prominent) {
          showingCreateBook = true
        } label: {
          Label("创建作品", systemImage: "plus")
        }
        NativeActionButton(prominence: .destructive) {
          showLogoutConfirmation = true
        } label: {
          Label("退出账号", systemImage: "rectangle.portrait.and.arrow.right")
        }
      } else {
        NativeActionButton(prominence: .prominent) {
          showingLogin = true
        } label: {
          Label("登录", systemImage: "person.crop.circle")
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(height: NativeLayout.workspaceHeaderHeight)
  }

  private var bookList: some View {
    VStack(spacing: 0) {
      NativeSectionHeader("作品", subtitle: bookListSubtitle)
        .padding(12)

      if !model.fanqieBooks.isEmpty {
        NativeSearchField(prompt: "搜索作品", text: $bookSearch)
          .padding(.horizontal, 10)
          .padding(.bottom, 8)
      }

      Divider()
      if model.fanqieBooks.isEmpty, !model.isLoading {
        NativeEmptyState(
          title: "没有在线作品",
          detail: "",
          systemImage: "books.vertical",
          actionTitle: "创建作品",
          action: { showingCreateBook = true }
        )
      } else if filteredFanqieBooks.isEmpty {
        NativeEmptyState(
          title: "没有匹配的作品",
          detail: "可按作品名或书号搜索。",
          systemImage: "magnifyingglass"
        )
      } else {
        List(filteredFanqieBooks, selection: selectedBookBinding) { book in
          VStack(alignment: .leading, spacing: 3) {
            Text(book.title)
              .font(.callout.weight(.medium))
              .lineLimit(2)
            HStack(spacing: 7) {
              Text("\(book.chapterCount) 章")
              if let wordCount = book.wordCount, !wordCount.isEmpty {
                Text("\(wordCount) 字")
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .tag(Optional(book.bookId))
        }
        .listStyle(.sidebar)
      }
    }
  }

  private var chapterList: some View {
    VStack(spacing: 0) {
      NativeSectionHeader("章节", subtitle: chapterListSubtitle)
        .padding(12)

      if !model.fanqieChapters.isEmpty {
        NativeSearchField(prompt: "搜索章节", text: $chapterSearch)
          .padding(.horizontal, 10)
          .padding(.bottom, 8)
      }

      Divider()
      if model.selectedFanqieBookID == nil {
        NativeEmptyState(title: "选择作品", detail: "", systemImage: "book")
      } else if model.fanqieChapters.isEmpty, !model.isLoading {
        NativeEmptyState(
          title: "没有在线章节",
          detail: "",
          systemImage: "doc.text",
          actionTitle: "上传章节",
          action: { transferMode = .upload }
        )
      } else if filteredFanqieChapters.isEmpty {
        NativeEmptyState(
          title: "没有匹配的章节",
          detail: "可按章节号、标题或状态搜索。",
          systemImage: "magnifyingglass"
        )
      } else {
        List(filteredFanqieChapters, selection: $selectedChapterID) { chapter in
          Button {
            selectedChapterID = chapter.chapterId
            Task { await model.loadFanqieChapterContent(chapter) }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(chapter.number > 0 ? "第\(chapter.number)章 \(chapter.title)" : chapter.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
              HStack(spacing: 7) {
                Text(chapter.status)
                if let wordCount = chapter.wordCount, !wordCount.isEmpty {
                  Text("\(wordCount) 字")
                }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .tag(Optional(chapter.chapterId))
        }
      }
    }
  }

  private var chapterContent: some View {
    VStack(spacing: 0) {
      NativeSectionHeader(
        model.fanqieChapterContent?.title ?? "正文",
        subtitle: model.fanqieChapterContent?.number.map { "第\($0)章" }
      ) {
        HStack(spacing: 8) {
          NativeActionButton(prominence: .prominent) {
            transferMode = .upload
          } label: {
            Label("上传章节", systemImage: "arrow.up.doc")
          }
          .disabled(model.selectedFanqieBook == nil || model.isMutating)
          NativeActionButton {
            transferMode = .replace
          } label: {
            Label("替换章节", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
          }
          .disabled(selectedFanqieChapter == nil || model.isMutating)
        }
      }
      .padding(12)
      Divider()
      if let content = model.fanqieChapterContent?.content, !content.isEmpty {
        ScrollView {
          Text(content)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
      } else {
        NativeEmptyState(title: "选择在线章节", detail: "", systemImage: "text.book.closed")
      }
    }
  }

  private var selectedFanqieChapter: FanqieChapter? {
    guard let selectedChapterID else { return nil }
    return model.fanqieChapters.first { $0.chapterId == selectedChapterID }
  }

  /// Local filter over the already-loaded page of online books. Matching stays on
  /// the list fields so typing never triggers a network round trip.
  private var filteredFanqieBooks: [FanqieBook] {
    let query = bookSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.fanqieBooks }
    return model.fanqieBooks.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.bookId.localizedCaseInsensitiveContains(query)
        || ($0.status?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private var filteredFanqieChapters: [FanqieChapter] {
    let query = chapterSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.fanqieChapters }
    return model.fanqieChapters.filter {
      String($0.number).contains(query)
        || $0.title.localizedCaseInsensitiveContains(query)
        || $0.status.localizedCaseInsensitiveContains(query)
    }
  }

  private var bookListSubtitle: String {
    let total = model.fanqieBooks.count
    let shown = filteredFanqieBooks.count
    return shown == total ? "\(total) 本" : "\(shown) / \(total) 本"
  }

  private var chapterListSubtitle: String {
    let total = model.fanqieChapters.count
    let shown = filteredFanqieChapters.count
    return shown == total ? "\(total) 章" : "\(shown) / \(total) 章"
  }

  private var selectedBookBinding: Binding<String?> {
    Binding(
      get: { model.selectedFanqieBookID },
      set: { id in
        selectedChapterID = nil
        // A stale keyword from the previous book would filter the incoming
        // chapter list down to an empty "no match" pane.
        chapterSearch = ""
        Task { await model.selectFanqieBook(id: id) }
      }
    )
  }
}

private struct FanqieLoginSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var isVerifying = false
  @State private var webViewID = UUID()
  @State private var verificationRequest = 0

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "person.crop.circle.badge.checkmark")
          .font(.title2)
          .foregroundStyle(.red)
        VStack(alignment: .leading, spacing: 2) {
          Text("登录番茄作者端")
            .font(.title3.weight(.semibold))
          Text(isVerifying ? "正在验证账号" : "番茄官方登录")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        NativeIconButton(title: "重新加载", systemImage: "arrow.clockwise") {
          webViewID = UUID()
        }
      }
      .padding(14)

      Divider()

      if let error = model.errorMessage, !error.isEmpty {
        NativeErrorBanner(message: error, dismiss: model.clearError)
      }

      FanqieLoginWebView(verificationRequest: verificationRequest) { cookies in
        guard !isVerifying else { return }
        isVerifying = true
        Task {
          let success = await model.completeFanqieLogin(cookies: cookies)
          isVerifying = false
          if success { dismiss() }
        }
      }
      .id(webViewID)

      Divider()

      HStack {
        if isVerifying { ProgressView().controlSize(.small) }
        Spacer()
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isVerifying)
        NativeActionButton(prominence: .prominent) {
          model.clearError()
          verificationRequest += 1
        } label: {
          Label(isVerifying ? "正在验证" : "完成登录", systemImage: "checkmark")
        }
        .disabled(isVerifying)
        .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(minWidth: 920, minHeight: 680)
    .onAppear { model.clearError() }
    .interactiveDismissDisabled(isVerifying)
  }
}

private struct FanqieLoginWebView: NSViewRepresentable {
  let verificationRequest: Int
  let onAuthenticated: ([FanqieCookie]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onAuthenticated: onAuthenticated)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.customUserAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    context.coordinator.webView = webView
    context.coordinator.verificationRequest = verificationRequest
    webView.load(URLRequest(url: URL(string: "https://fanqienovel.com/main/writer/login")!))
    context.coordinator.startPolling()
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    guard context.coordinator.verificationRequest != verificationRequest else { return }
    context.coordinator.verificationRequest = verificationRequest
    context.coordinator.captureCookies()
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.stopPolling()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    private let onAuthenticated: ([FanqieCookie]) -> Void
    private var timer: Timer?
    private var lastCompletionAttempt = Date.distantPast
    private var isProbing = false
    var verificationRequest = 0

    init(onAuthenticated: @escaping ([FanqieCookie]) -> Void) {
      self.onAuthenticated = onAuthenticated
    }

    func startPolling() {
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
        self?.probeLogin()
      }
    }

    func stopPolling() {
      timer?.invalidate()
      timer = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      probeLogin()
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil, let requestURL = navigationAction.request.url {
        webView.load(URLRequest(url: requestURL))
      }
      return nil
    }

    private func probeLogin() {
      guard !isProbing,
        let webView,
        webView.url?.host?.lowercased().hasSuffix("fanqienovel.com") == true,
        Date().timeIntervalSince(lastCompletionAttempt) > 3
      else { return }
      isProbing = true
      let script = """
        fetch('/api/author/account/info/v0/', {credentials: 'include'})
          .then(response => response.json())
          .then(payload => JSON.stringify({code: payload.code, hasData: !!payload.data}))
          .catch(() => JSON.stringify({code: -1, hasData: false}));
        """
      webView.evaluateJavaScript(script) { [weak self] result, _ in
        guard let self else { return }
        self.isProbing = false
        guard let raw = result as? String,
          let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (object["code"] as? NSNumber)?.intValue == 0,
          object["hasData"] as? Bool == true
        else { return }
        self.lastCompletionAttempt = Date()
        self.captureCookies()
      }
    }

    func captureCookies() {
      guard let webView else { return }
      lastCompletionAttempt = Date()
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        guard let self else { return }
        let mapped = cookies.compactMap { cookie -> FanqieCookie? in
          guard cookie.domain.lowercased().contains("fanqienovel.com") else { return nil }
          return FanqieCookie(
            name: cookie.name,
            value: cookie.value,
            domain: cookie.domain,
            path: cookie.path,
            expiresAt: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly
          )
        }
        DispatchQueue.main.async { self.onAuthenticated(mapped) }
      }
    }
  }
}

private enum FanqieWebSessionStore {
  @MainActor
  static func clear() async {
    let store = WKWebsiteDataStore.default().httpCookieStore
    let cookies = await withCheckedContinuation { continuation in
      store.getAllCookies { continuation.resume(returning: $0) }
    }
    for cookie in cookies where cookie.domain.lowercased().contains("fanqienovel.com") {
      await withCheckedContinuation { continuation in
        store.delete(cookie) { continuation.resume() }
      }
    }
  }
}

private struct FanqieCreateBookSheet: View {
  @ObservedObject var model: WorkspaceModel
  @Environment(\.dismiss) private var dismiss
  @State private var localBookID = ""
  @State private var title = ""
  @State private var gender = 1
  @State private var categories: [FanqieCategory] = []
  @State private var selectedCategoryIDs = Set<String>()
  @State private var protagonistNames = ""
  @State private var abstract = ""
  @State private var loadingCategories = false
  @State private var loadingPrefill = false
  @State private var generatingAbstract = false
  @State private var submitting = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "plus.square.on.square")
          .font(.title2)
          .foregroundStyle(.red)
        VStack(alignment: .leading, spacing: 2) {
          Text("创建番茄作品")
            .font(.title3.weight(.semibold))
          Text(model.fanqieAccount?.authorName ?? "番茄作者端")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(16)

      Divider()

      if let error = model.errorMessage, !error.isEmpty {
        NativeErrorBanner(message: error, dismiss: model.clearError)
      }

      Form {
        Picker("本地小说", selection: $localBookID) {
          if model.books.isEmpty {
            Text("暂无可用小说").tag("")
          } else {
            ForEach(model.books) { book in
              Text(book.title).tag(book.id)
            }
          }
        }
        .disabled(model.books.isEmpty || loadingPrefill || generatingAbstract)

        TextField("作品名称", text: $title)

        Picker("目标读者", selection: $gender) {
          Text("男频").tag(1)
          Text("女频").tag(0)
        }
        .pickerStyle(.segmented)

        LabeledContent("作品标签") {
          if loadingCategories {
            ProgressView().controlSize(.small)
          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(categoryGroupNames, id: \.self) { group in
                  VStack(alignment: .leading, spacing: 7) {
                    Text(group)
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                      ForEach(categories.filter { $0.group == group }) { category in
                        Toggle(
                          category.name,
                          isOn: Binding(
                            get: { selectedCategoryIDs.contains(category.categoryId) },
                            set: { updateSelection(category, selected: $0) }
                          )
                        )
                        .toggleStyle(.checkbox)
                        .lineLimit(1)
                      }
                    }
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
          }
        }

        TextField("主角姓名（多个用逗号分隔）", text: $protagonistNames)

        LabeledContent("作品简介") {
          VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
              if loadingPrefill {
                ProgressView()
                  .controlSize(.small)
                Text("正在读取小说设定")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              NativeActionButton {
                generateAbstract()
              } label: {
                if generatingAbstract {
                  HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在浓缩")
                  }
                  .accessibilityElement(children: .ignore)
                  .accessibilityLabel("正在浓缩作品简介")
                } else {
                  Label("LLM 一键浓缩", systemImage: "wand.and.stars")
                    .accessibilityLabel("LLM 一键浓缩作品简介")
                }
              }
              .disabled(
                localBookID.isEmpty
                  || abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || loadingPrefill
                  || generatingAbstract
                  || submitting
              )
            }

            TextEditor(text: $abstract)
              .font(.body)
              .scrollContentBackground(.hidden)
              .padding(6)
              .frame(minHeight: 130)
              .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
              .overlay { RoundedRectangle(cornerRadius: 6).stroke(.quaternary) }
              .disabled(loadingPrefill || generatingAbstract)

            Text("\(abstract.count)/500 字")
              .font(.caption.monospacedDigit())
              .foregroundStyle(
                abstract.count < 50 || abstract.count > 500 ? .red : .secondary
              )
          }
        }
      }
      .formStyle(.grouped)
      .disabled(submitting)

      Divider()

      HStack(spacing: 10) {
        if let validationMessage {
          Text(validationMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(submitting)
        NativeActionButton(prominence: .prominent) {
          submit()
        } label: {
          Label(submitting ? "正在创建" : "创建作品", systemImage: "plus")
        }
        .disabled(validationMessage != nil || submitting || loadingCategories)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 700, minHeight: 650)
    .task {
      model.clearError()
      if model.books.isEmpty {
        await model.refreshBooks()
      }
      let preferredBookID = model.currentBookID.flatMap { currentID in
        model.books.contains { $0.id == currentID } ? currentID : nil
      } ?? model.books.first?.id ?? ""
      localBookID = preferredBookID
    }
    .task(id: localBookID) {
      guard !localBookID.isEmpty else { return }
      await loadPrefill(bookID: localBookID)
    }
    .task(id: gender) {
      selectedCategoryIDs.removeAll()
      await loadCategories()
    }
    .interactiveDismissDisabled(submitting || generatingAbstract)
  }

  private var validationMessage: String? {
    if localBookID.isEmpty { return "尚未选择本地小说" }
    if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "作品名称为空" }
    if !selectedCategories.contains(where: { $0.group == "主分类" }) { return "尚未选择主分类" }
    if protagonistList.isEmpty { return "主角姓名为空" }
    if abstract.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 { return "作品简介少于 50 字" }
    if abstract.trimmingCharacters(in: .whitespacesAndNewlines).count > 500 { return "作品简介超过 500 字" }
    return nil
  }

  private var protagonistList: [String] {
    protagonistNames
      .components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var selectedCategories: [FanqieCategory] {
    categories.filter { selectedCategoryIDs.contains($0.categoryId) }
  }

  private var categoryGroupNames: [String] {
    let preferred = ["主分类", "主题", "角色", "情节", "其他"]
    return preferred.filter { group in categories.contains { $0.group == group } }
  }

  private func updateSelection(_ category: FanqieCategory, selected: Bool) {
    if selected {
      for existing in categories where existing.group == category.group {
        selectedCategoryIDs.remove(existing.categoryId)
      }
      selectedCategoryIDs.insert(category.categoryId)
    } else {
      selectedCategoryIDs.remove(category.categoryId)
    }
  }

  private func loadPrefill(bookID: String) async {
    guard let book = model.books.first(where: { $0.id == bookID }) else { return }
    loadingPrefill = true
    title = book.title
    abstract = ""
    protagonistNames = ""

    async let briefRequest = model.fetchLocalBookSetting(bookID: bookID, path: "brief.md")
    async let bibleRequest = model.fetchLocalBookSetting(bookID: bookID, path: "story_bible.md")
    let (brief, bible) = await (briefRequest, bibleRequest)
    guard !Task.isCancelled, localBookID == bookID else { return }

    if let brief {
      let body = brief.components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty { abstract = String(body.prefix(2_000)) }
    }
    if let bible, let inferredName = inferredProtagonistName(from: bible) {
      protagonistNames = inferredName
    }
    loadingPrefill = false
  }

  private func loadCategories() async {
    loadingCategories = true
    categories = await model.fetchFanqieCategories(gender: gender)
    loadingCategories = false
  }

  private func inferredProtagonistName(from bible: String) -> String? {
    let lines = bible.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter {
        !$0.isEmpty
          && !$0.hasPrefix("#")
          && !$0.hasPrefix("【")
          && !$0.hasPrefix("人物关系")
      }
    guard let line = lines.first else { return nil }
    let separators = CharacterSet(charactersIn: "：:")
    let parts = line.components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard let first = parts.first else { return nil }
    let roleLabels: Set<String> = ["主角", "男主", "女主", "主人公"]
    let candidate = roleLabels.contains(first) && parts.count > 1 ? parts[1] : first
    let name = candidate.components(separatedBy: CharacterSet(charactersIn: "，,、。；;（("))[0]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 30 else { return nil }
    return name
  }

  private func generateAbstract() {
    let bookID = localBookID
    let source = abstract
    guard !bookID.isEmpty, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    generatingAbstract = true
    Task {
      let generated = await model.generateFanqieAbstract(
        bookID: bookID,
        source: source,
        protagonistNames: protagonistList
      )
      guard localBookID == bookID else { return }
      if let generated {
        abstract = generated
      }
      generatingAbstract = false
    }
  }

  private func submit() {
    guard validationMessage == nil else { return }
    submitting = true
    let input = FanqieCreateBookInput(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines),
      gender: gender,
      categoryIDs: Array(selectedCategoryIDs).sorted(),
      protagonistNames: protagonistList,
      abstract: abstract.trimmingCharacters(in: .whitespacesAndNewlines),
      coverURI: nil
    )
    Task {
      let response = await model.createFanqieBook(input)
      submitting = false
      if response?.ok == true { dismiss() }
    }
  }
}

private struct FanqieChapterTransferSheet: View {
  @ObservedObject var model: WorkspaceModel
  let mode: FanqieTransferMode
  let remoteBook: FanqieBook
  let remoteChapter: FanqieChapter?

  @Environment(\.dismiss) private var dismiss
  @State private var localBookID = ""
  @State private var localChapterNumber = 0
  @State private var localChapters: [ChapterSummary] = []
  @State private var loadingChapters = false
  @State private var submitting = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: mode == .upload ? "arrow.up.doc" : "arrow.triangle.2.circlepath.doc.on.clipboard")
          .font(.title2)
          .foregroundStyle(.red)
        VStack(alignment: .leading, spacing: 2) {
          Text(mode == .upload ? "上传章节" : "替换在线章节")
            .font(.title3.weight(.semibold))
          Text(remoteBook.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
      }
      .padding(16)

      Divider()

      if let error = model.errorMessage, !error.isEmpty {
        NativeErrorBanner(message: error, dismiss: model.clearError)
      }

      Form {
        if mode == .replace, let remoteChapter {
          LabeledContent("在线目标") {
            Text("第\(remoteChapter.number)章 \(remoteChapter.title)")
              .lineLimit(2)
          }
        }

        Picker("本地小说", selection: $localBookID) {
          ForEach(model.books) { book in
            Text(book.title).tag(book.id)
          }
        }

        Picker("本地章节", selection: $localChapterNumber) {
          ForEach(localChapters) { chapter in
            Text("第\(chapter.number)章 \(chapter.title)").tag(chapter.number)
          }
        }
        .disabled(loadingChapters || localChapters.isEmpty)

        if let selectedLocalChapter {
          LabeledContent("上传内容") {
            VStack(alignment: .leading, spacing: 5) {
              Text("第\(selectedLocalChapter.number)章 \(selectedLocalChapter.title)")
                .font(.callout.weight(.semibold))
              Text("\(selectedLocalChapter.wordCount) 字 · \(ChapterVisualStatus(rawStatus: selectedLocalChapter.status).label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .formStyle(.grouped)
      .disabled(submitting)

      Spacer(minLength: 0)
      Divider()

      HStack(spacing: 10) {
        if loadingChapters { ProgressView().controlSize(.small) }
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(submitting)
        NativeActionButton(prominence: .prominent) {
          submit()
        } label: {
          Label(
            submitting ? "正在提交" : (mode == .upload ? "上传章节" : "替换章节"),
            systemImage: mode == .upload ? "arrow.up.doc" : "arrow.triangle.2.circlepath"
          )
        }
        .disabled(localBookID.isEmpty || localChapterNumber <= 0 || submitting || loadingChapters)
        .keyboardShortcut(.defaultAction)
      }
      .padding(14)
    }
    .frame(minWidth: 620, minHeight: 400)
    .onAppear {
      model.clearError()
      localBookID = model.currentBookID ?? model.books.first?.id ?? ""
      Task { await loadChapters() }
    }
    .onChange(of: localBookID) { _ in
      Task { await loadChapters() }
    }
    .interactiveDismissDisabled(submitting)
  }

  private var selectedLocalChapter: ChapterSummary? {
    localChapters.first { $0.number == localChapterNumber }
  }

  private func loadChapters() async {
    guard !localBookID.isEmpty else {
      localChapters = []
      localChapterNumber = 0
      return
    }
    loadingChapters = true
    localChapters = await model.fetchLocalChapters(bookID: localBookID)
    if !localChapters.contains(where: { $0.number == localChapterNumber }) {
      localChapterNumber = model.currentBookID == localBookID
        ? (model.currentChapterNumber ?? localChapters.last?.number ?? 0)
        : (localChapters.last?.number ?? 0)
    }
    loadingChapters = false
  }

  private func submit() {
    guard localChapterNumber > 0 else { return }
    submitting = true
    let input = FanqieChapterTransferInput(
      localBookId: localBookID,
      localChapterNumber: localChapterNumber,
      remoteBookId: remoteBook.bookId,
      remoteChapterId: mode == .replace ? remoteChapter?.chapterId : nil
    )
    Task {
      let response = await model.transferFanqieChapter(input, replacing: mode == .replace)
      submitting = false
      if response?.ok == true { dismiss() }
    }
  }
}
