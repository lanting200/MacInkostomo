import SwiftUI

enum NativeLayout {
  static let cornerRadius: CGFloat = 8
  static let compactSpacing: CGFloat = 8
  static let panelSpacing: CGFloat = 12
}

struct AdaptiveGlassSurface<Content: View>: View {
  private let padding: CGFloat
  private let tint: Color?
  private let content: Content

  init(
    padding: CGFloat = 12,
    tint: Color? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.padding = padding
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .modifier(AdaptiveGlassSurfaceModifier(tint: tint))
  }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
  let tint: Color?

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      content.glassEffect(
        tint.map { Glass.regular.tint($0) } ?? .regular,
        in: RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
      )
    } else {
      content
        .background(
          .regularMaterial,
          in: RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
            .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }
  }
}

struct AdaptiveGlassGroup<Content: View>: View {
  private let spacing: CGFloat
  private let content: Content

  init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

enum NativeActionProminence {
  case standard
  case prominent
  case destructive
}

struct NativeActionButton<Label: View>: View {
  let prominence: NativeActionProminence
  let action: () -> Void
  private let label: Label

  init(
    prominence: NativeActionProminence = .standard,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) {
    self.prominence = prominence
    self.action = action
    self.label = label()
  }

  @ViewBuilder
  var body: some View {
    if #available(macOS 26.0, *) {
      switch prominence {
      case .prominent:
        Button(action: action) { label }
          .buttonStyle(.glassProminent)
      case .standard:
        Button(action: action) { label }
          .buttonStyle(.glass)
      case .destructive:
        Button(role: .destructive, action: action) { label }
          .buttonStyle(.glass(.regular.tint(.red.opacity(0.18))))
      }
    } else {
      switch prominence {
      case .prominent:
        Button(action: action) { label }
          .buttonStyle(.borderedProminent)
      case .standard:
        Button(action: action) { label }
          .buttonStyle(.bordered)
      case .destructive:
        Button(role: .destructive, action: action) { label }
          .buttonStyle(.bordered)
          .tint(.red)
      }
    }
  }
}

struct NativeIconButton: View {
  let title: String
  let systemImage: String
  var prominence: NativeActionProminence = .standard
  var disabled = false
  let action: () -> Void

  var body: some View {
    NativeActionButton(prominence: prominence, action: action) {
      Image(systemName: systemImage)
        .frame(width: 18, height: 18)
    }
    .disabled(disabled)
    .help(title)
    .accessibilityLabel(title)
  }
}

struct NativeSectionHeader<Trailing: View>: View {
  let title: String
  var subtitle: String?
  private let trailing: Trailing

  init(
    _ title: String,
    subtitle: String? = nil,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 6)
      trailing
    }
  }
}

extension NativeSectionHeader where Trailing == EmptyView {
  init(_ title: String, subtitle: String? = nil) {
    self.init(title, subtitle: subtitle) { EmptyView() }
  }
}

enum ChapterVisualStatus {
  case pending
  case approved
  case published
  case working
  case failed
  case neutral

  init(rawStatus: String) {
    switch rawStatus {
    case "approved":
      self = .approved
    case "published":
      self = .published
    case "card-generated", "drafting", "auditing", "revising", "revision_requested":
      self = .working
    case "audit-failed", "state-degraded", "rejected", "revision_failed":
      self = .failed
    case "drafted", "audit-passed", "ready-for-review", "pending_review", "imported":
      self = .pending
    default:
      self = .neutral
    }
  }

  var label: String {
    switch self {
    case .pending: "待审"
    case .approved: "已通过"
    case .published: "已发布"
    case .working: "处理中"
    case .failed: "待修改"
    case .neutral: "未知"
    }
  }

  var color: Color {
    switch self {
    case .pending: .orange
    case .approved: .green
    case .published: .purple
    case .working: .blue
    case .failed: .red
    case .neutral: .secondary
    }
  }
}

struct ChapterStatusBadge: View {
  let status: String
  var compact = false

  var body: some View {
    let visualStatus = ChapterVisualStatus(rawStatus: status)
    HStack(spacing: 5) {
      Circle()
        .fill(visualStatus.color)
        .frame(width: 7, height: 7)
      if !compact {
        Text(displayLabel)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
    }
    .foregroundStyle(visualStatus.color)
    .padding(.horizontal, compact ? 5 : 7)
    .frame(height: 22)
    .background(visualStatus.color.opacity(0.11), in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("章节状态：\(displayLabel)")
  }

  private var displayLabel: String {
    switch status {
    case "card-generated": "建卡中"
    case "drafting": "写作中"
    case "auditing": "InkOS 自审中"
    case "revising", "revision_requested": "修改中"
    case "audit-failed": "审核未过"
    case "state-degraded": "状态待修"
    case "rejected", "revision_failed": "待修改"
    case "approved": "已通过"
    case "published": "已发布"
    case "imported": "已导入"
    case "drafted", "audit-passed", "ready-for-review", "pending_review": "待审"
    default: "未知"
    }
  }
}

struct NativeEmptyState: View {
  let title: String
  let detail: String
  let systemImage: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360)
      if let actionTitle, let action {
        NativeActionButton(prominence: .standard, action: action) {
          Text(actionTitle)
        }
        .padding(.top, 2)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct NativeErrorBanner: View {
  let message: String
  let dismiss: () -> Void
  var retry: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if let retry {
        Button("重试", action: retry)
          .buttonStyle(.link)
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("关闭错误提示")
      .accessibilityLabel("关闭错误提示")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(.orange.opacity(0.1))
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
  }
}

struct NativeLoadingOverlay: View {
  var title = "正在处理"

  var body: some View {
    ZStack {
      Color.black.opacity(0.08)
        .ignoresSafeArea()
      AdaptiveGlassSurface(padding: 14) {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text(title)
            .font(.callout.weight(.medium))
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
  }
}

struct NativeSearchField: View {
  let prompt: String
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 30)
    .background(
      .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
