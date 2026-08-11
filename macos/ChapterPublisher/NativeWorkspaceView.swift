import SwiftUI

struct NativeWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel
  @ObservedObject var bookSettingDrafts: BookSettingDraftStore

  var body: some View {
    // No GlassEffectContainer here: it composites every glass surface in the
    // window above the content, which buried the workspace under the blur.
    // Sidebar and content each carry their own glass in a background layer.
    HStack(spacing: 0) {
      navigationSidebar

      VStack(spacing: 0) {
        if let errorMessage = model.errorMessage, !errorMessage.isEmpty {
          NativeErrorBanner(
            message: errorMessage,
            dismiss: { model.errorMessage = nil },
            retry: { Task { await model.selectSection(model.section) } }
          )
        }

        // Sits at window level, not in the create sheet: the pass runs for minutes
        // on a full-length original and the sheet is gone long before it finishes.
        if let preparation = model.derivativePreparation {
          DerivativePreparationBanner(
            state: preparation,
            resume: {
              Task {
                await model.resumeDerivativePreparation(
                  bookID: preparation.bookID,
                  bookTitle: preparation.bookTitle
                )
              }
            },
            dismiss: model.clearDerivativePreparation
          )
        }

        workspace
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background {
        Color.clear.nativeGlassChrome(.regular)
      }
    }
    .frame(minWidth: 900, minHeight: 620)
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

  /// Full-height glass sidebar. The brand sits at its top below the traffic
  /// lights, left-aligned with the menu item icons; the engine status lives
  /// at the bottom.
  private var navigationSidebar: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 9) {
        Image(systemName: "book.closed.fill")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(NativeTheme.brand)
          .accessibilityHidden(true)
        Text("MacInkostomo")
          .font(.system(size: 16, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
      .padding(.leading, 30)
      .padding(.top, 44)
      .padding(.bottom, 14)

      navigationItem(
        title: "作品管理",
        systemImage: "books.vertical",
        section: .library,
        shortcut: "1"
      )
      navigationItem(
        title: "番茄在线",
        systemImage: "network",
        section: .fanqie,
        shortcut: "2"
      )
      navigationItem(
        title: "设置",
        systemImage: "slider.horizontal.3",
        section: .settings,
        shortcut: "3"
      )
      navigationItem(
        title: "任务状态",
        systemImage: "clock.arrow.circlepath",
        section: .activity,
        shortcut: "4"
      )

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
          Text("内置引擎")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.75))
        }
      }
      .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(model.isLoading ? "内置引擎正在处理" : "内置引擎已就绪")
      .padding(.leading, 30)
      .padding(.bottom, 14)
    }
    .padding(.horizontal, 10)
    .frame(width: NativeLayout.sidebarWidth)
    .frame(maxHeight: .infinity)
    .nativeGlassChrome(.clear, frost: 0.1)
    .overlay(alignment: .trailing) {
      NativeTheme.hairline.frame(width: 1)
    }
  }

  @ViewBuilder
  private func navigationItem(
    title: String,
    systemImage: String,
    section: WorkspaceSection,
    shortcut: KeyEquivalent
  ) -> some View {
    NativeSidebarNavItem(
      title: title,
      systemImage: systemImage,
      selected: selectedNavigationSection == section
    ) {
      Task { await model.selectSection(section) }
    }
    .keyboardShortcut(shortcut, modifiers: .command)
    .help("\(title)（Command-\(String(shortcut.character))）")
  }

  private var selectedNavigationSection: WorkspaceSection {
    model.section == .chapters ? .library : model.section
  }
}
