import SwiftUI

struct NativeWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject var bookSettingDrafts: BookSettingDraftStore

  var body: some View {
    VStack(spacing: 0) {
      nativeNavigationBar

      if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
        NativeErrorBanner(
          message: errorMessage,
          dismiss: { model.errorMessage = nil },
          retry: { Task { await model.selectSection(model.section) } }
        )
      }

      workspace
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 900, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .overlay {
      if model.isMutating {
        NativeLoadingOverlay(title: "正在保存更改")
      }
    }
    .task {
      await model.bootstrap()
    }
  }

  @ViewBuilder
  private var workspace: some View {
    switch model.section {
    case .library, .chapters:
      ReviewWorkspaceView(model: model)
    case .fanqie:
      FanqieWorkspaceView(model: model)
    case .settings:
      SettingsWorkspaceView(model: model, drafts: bookSettingDrafts)
    case .activity:
      ActivityWorkspaceView(model: model)
    }
  }

  private var nativeNavigationBar: some View {
    HStack(spacing: 14) {
      HStack(spacing: 9) {
        Image(systemName: "book.closed.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        Text("MacInkostomo")
          .font(.headline)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)

      Spacer(minLength: 10)

      AdaptiveGlassGroup(spacing: 8) {
        HStack(spacing: 6) {
          navigationButton(
            title: "作品管理",
            systemImage: "books.vertical",
            section: .library,
            shortcut: "1"
          )
          navigationButton(
            title: "番茄在线",
            systemImage: "network",
            section: .fanqie,
            shortcut: "2"
          )
          navigationButton(
            title: "设置",
            systemImage: "slider.horizontal.3",
            section: .settings,
            shortcut: "3"
          )
          navigationButton(
            title: "任务状态",
            systemImage: "clock.arrow.circlepath",
            section: .activity,
            shortcut: "4"
          )
        }
      }

      Spacer(minLength: 10)

      HStack(spacing: 7) {
        if model.isLoading {
          ProgressView()
            .controlSize(.small)
            .help("正在刷新数据")
            .accessibilityLabel("正在刷新数据")
        } else {
          Circle()
            .fill(.green)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
          Text("本地服务")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(minWidth: 76, alignment: .trailing)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(model.isLoading ? "本地服务正在刷新" : "本地服务已连接")
    }
    .padding(.horizontal, 14)
    .frame(height: 52)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  @ViewBuilder
  private func navigationButton(
    title: String,
    systemImage: String,
    section: WorkspaceSection,
    shortcut: KeyEquivalent
  ) -> some View {
    let selected = selectedNavigationSection == section
    NativeActionButton(prominence: selected ? .prominent : .standard) {
      Task { await model.selectSection(section) }
    } label: {
      Label(title, systemImage: systemImage)
        .font(.callout.weight(selected ? .semibold : .regular))
        .frame(minWidth: 82)
    }
    .keyboardShortcut(shortcut, modifiers: .command)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .help("\(title)（Command-\(String(shortcut.character))）")
  }

  private var selectedNavigationSection: WorkspaceSection {
    model.section == .chapters ? .library : model.section
  }
}
