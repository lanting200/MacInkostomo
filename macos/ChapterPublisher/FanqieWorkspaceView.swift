import AppKit
import SwiftUI

struct FanqieWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @State private var selectedChapterID: String?
  @State private var showLogoutConfirmation = false

  var body: some View {
    VStack(spacing: 0) {
      fanqieToolbar
      Divider()

      if model.fanqieLogin?.loggedIn == false {
        NativeEmptyState(
          title: "番茄账号未连接",
          detail: model.fanqieLogin?.reason ?? "",
          systemImage: "person.crop.circle.badge.exclamationmark",
          actionTitle: "打开登录页",
          action: openLoginPage
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
    .task { await model.refreshFanqie() }
    .confirmationDialog(
      "退出番茄账号？",
      isPresented: $showLogoutConfirmation,
      titleVisibility: .visible
    ) {
      Button("退出账号", role: .destructive) {
        Task { _ = await model.logoutFanqie() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("本地登录状态会备份后清除，再次查看在线作品时需要重新登录。")
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
      NativeActionButton(action: openLoginPage) {
        Label("登录页", systemImage: "safari")
      }
      if model.fanqieLogin?.loggedIn == true {
        NativeActionButton(prominence: .destructive) {
          showLogoutConfirmation = true
        } label: {
          Label("退出账号", systemImage: "rectangle.portrait.and.arrow.right")
        }
      }
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
  }

  private var bookList: some View {
    VStack(spacing: 0) {
      NativeSectionHeader("作品", subtitle: "\(model.fanqieBooks.count) 本")
        .padding(12)
      Divider()
      if model.fanqieBooks.isEmpty, !model.isLoading {
        NativeEmptyState(title: "没有在线作品", detail: "", systemImage: "books.vertical")
      } else {
        List(model.fanqieBooks, selection: selectedBookBinding) { book in
          VStack(alignment: .leading, spacing: 3) {
            Text(book.title)
              .font(.callout.weight(.medium))
              .lineLimit(2)
            Text("\(book.chapterCount) 章")
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
      NativeSectionHeader("章节", subtitle: "\(model.fanqieChapters.count) 章")
        .padding(12)
      Divider()
      if model.selectedFanqieBookID == nil {
        NativeEmptyState(title: "选择作品", detail: "", systemImage: "book")
      } else if model.fanqieChapters.isEmpty, !model.isLoading {
        NativeEmptyState(title: "没有在线章节", detail: "", systemImage: "doc.text")
      } else {
        List(model.fanqieChapters, selection: $selectedChapterID) { chapter in
          Button {
            selectedChapterID = chapter.chapterId
            Task { await model.loadFanqieChapterContent(chapter) }
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(chapter.number > 0 ? "第\(chapter.number)章 \(chapter.title)" : chapter.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
              Text(chapter.status)
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
      )
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

  private var selectedBookBinding: Binding<String?> {
    Binding(
      get: { model.selectedFanqieBookID },
      set: { id in
        selectedChapterID = nil
        Task { await model.selectFanqieBook(id: id) }
      }
    )
  }

  private func openLoginPage() {
    Task {
      guard let response = await model.fanqieLoginURL(),
        let url = URL(string: response.url),
        let scheme = url.scheme?.lowercased(),
        ["http", "https"].contains(scheme),
        url.host != nil
      else {
        model.errorMessage = "番茄登录地址无效"
        return
      }
      NSWorkspace.shared.open(url)
    }
  }
}
