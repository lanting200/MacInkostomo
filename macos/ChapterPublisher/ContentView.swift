import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var serverManager: ServerManager
  @StateObject private var workspaceModel = WorkspaceModel()
  @StateObject private var bookSettingDrafts = BookSettingDraftStore()

  var body: some View {
    Group {
      switch serverManager.phase {
      case .idle:
        launchProgress(
          title: "正在准备工作台",
          detail: "正在检查项目目录和运行环境"
        )
      case .starting(let title, let detail):
        launchProgress(title: title, detail: detail)
      case .ready:
        NativeWorkspaceView(model: workspaceModel, bookSettingDrafts: bookSettingDrafts)
      case .failed(let title, let detail):
        failureView(title: title, detail: detail)
      }
    }
    .frame(minWidth: 900, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func launchProgress(title: String, detail: String) -> some View {
    VStack(spacing: 14) {
      ProgressView()
        .controlSize(.large)
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func failureView(title: String, detail: String) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 34))
          .foregroundStyle(.orange)

        Text(title)
          .font(.title2.weight(.semibold))

        Text(detail)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .frame(maxWidth: 680)

        HStack(spacing: 10) {
          Button {
            serverManager.selectRepositoryRoot()
          } label: {
            Label("选择项目目录", systemImage: "folder")
          }
          .controlSize(.large)

          Button {
            serverManager.retry()
          } label: {
            Label("重试", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        }

        if !serverManager.logExcerpt.isEmpty {
          DisclosureGroup("启动日志") {
            ScrollView(.horizontal) {
              Text(serverManager.logExcerpt)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
          }
          .frame(maxWidth: 760)
          .padding(.top, 8)
        }
      }
      .padding(40)
      .frame(maxWidth: .infinity)
    }
  }
}
