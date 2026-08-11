import SwiftUI

enum NativeLayout {
  static let cornerRadius: CGFloat = 8
  static let cardCornerRadius: CGFloat = 12
  static let compactSpacing: CGFloat = 8
  static let panelSpacing: CGFloat = 12
  static let sidebarWidth: CGFloat = 238
  static let workspaceHeaderHeight: CGFloat = 52
  static let workspaceUtilityHeight: CGFloat = 38
  static let workspaceFooterHeight: CGFloat = 54
}

/// Color tokens lifted from the fanqie writer center production stylesheets.
/// Light mode matches the web values exactly; dark mode keeps the same brand
/// and alpha ladder on a warm dark base.
enum NativeTheme {
  private static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      if appearance.isDarkAppearance {
        return NSColor(fanqieHex: dark, alpha: darkAlpha)
      }
      return NSColor(fanqieHex: light, alpha: lightAlpha)
    })
  }

  /// Fanqie brand orange #FF5F00.
  static let brand = Color(nsColor: NSColor(fanqieHex: 0xFF5F00))
  /// Hover #FF721F.
  static let brandHover = Color(nsColor: NSColor(fanqieHex: 0xFF721F))
  /// Pressed #D24600.
  static let brandPressed = Color(nsColor: NSColor(fanqieHex: 0xD24600))
  /// Selected menu background #FF5F000A (4% alpha; stronger on dark).
  static let brandFaint = adaptive(0xFF5F00, 0xFF5F00, lightAlpha: 0.04, darkAlpha: 0.16)
  /// Tag / countdown capsule background #FF5F0014 (8% alpha).
  static let brandSoft = adaptive(0xFF5F00, 0xFF5F00, lightAlpha: 0.08, darkAlpha: 0.22)
  /// Calendar stamp background #FF5F001F (12% alpha).
  static let brandStamp = adaptive(0xFF5F00, 0xFF5F00, lightAlpha: 0.12, darkAlpha: 0.28)

  /// Page background #F9F9F9 (kept for opaque surfaces such as dialogs).
  static let page = adaptive(0xF9F9F9, 0x161614)
  /// White serial-card background.
  static let card = adaptive(0xFFFFFF, 0x232322)
  /// Serial card at 50% opacity for floating over the glass page.
  static var cardGlass: Color { card.opacity(0.5) }
  /// Hover fill #00000005.
  static let hoverFill = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.02, darkAlpha: 0.05)
  /// Subtle fill #0000000A.
  static let subtleFill = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.09)
  /// Hairline separator.
  static let hairline = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.10)

  /// Frosted chip used for selected controls sitting on clear glass.
  static let chipFill = Color(nsColor: .white).opacity(0.55)
  /// Hover chip on clear glass.
  static let chipHover = Color(nsColor: .white).opacity(0.25)

  /// Primary text (web #000).
  static let textPrimary = Color.primary
  /// Secondary text #000000A3 (64%).
  static let textSecondary = Color.primary.opacity(0.64)
  /// Tertiary text #00000066 (40%).
  static let textTertiary = Color.primary.opacity(0.40)
  /// Placeholder / disabled #0000003D (24%).
  static let textQuaternary = Color.primary.opacity(0.24)
}

extension NSColor {
  convenience init(fanqieHex rgb: UInt32, alpha: Double = 1) {
    self.init(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: alpha
    )
  }
}

extension NSAppearance {
  var isDarkAppearance: Bool {
    bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }
}

/// Clear or regular liquid glass for window chrome (sidebar and content
/// backdrop). An ultra-thin gaussian-blur material diluted to 20% opacity,
/// plus Glass on macOS 26 for liquid-glass refraction. (Refraction strength
/// is not tunable.)
enum NativeGlassKind {
  case clear
  case regular
}

struct NativeGlassChrome: ViewModifier {
  var kind: NativeGlassKind = .clear
  var frost: Double = 0.2

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      switch kind {
      case .clear:
        content
          .background { NativeGlassFrost(opacity: frost) }
          .glassEffect(.clear, in: .rect)
      case .regular:
        content
          .background { NativeGlassFrost(opacity: frost) }
          .glassEffect(.regular, in: .rect)
      }
    } else {
      content.background { NativeGlassFrost(opacity: frost) }
    }
  }
}

private struct NativeGlassFrost: View {
  let opacity: Double

  var body: some View {
    Rectangle()
      .fill(.ultraThinMaterial)
      .opacity(opacity)
  }
}

extension View {
  func nativeGlassChrome(_ kind: NativeGlassKind = .clear, frost: Double = 0.2) -> some View {
    modifier(NativeGlassChrome(kind: kind, frost: frost))
  }
}

/// Vertical navigation item matching the fanqie writer center menu metrics:
/// 14pt PingFang, 44pt row height, 8pt corner radius, selected rows use the
/// brand color at 4% fill with brand-colored text. On macOS 26 the selected
/// row upgrades to an interactive liquid-glass capsule tinted with the brand.
struct NativeSidebarNavItem: View {
  let title: String
  let systemImage: String
  let selected: Bool
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      rowContent
        .padding(.horizontal, 20)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NativeSidebarNavItemChrome(selected: selected, hovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var rowContent: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: selected ? .bold : .semibold))
        .frame(width: 20, alignment: .center)
        .accessibilityHidden(true)
      Text(title)
        .font(.system(size: 14, weight: selected ? .bold : .semibold))
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .foregroundStyle(selected ? NativeTheme.brand : Color.white)
    .shadow(color: .black.opacity(selected ? 0 : 0.7), radius: 2.5, x: 0, y: 1)
  }
}

private struct NativeSidebarNavItemChrome: ViewModifier {
  let selected: Bool
  let hovering: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      if selected {
        content
          .background(
            NativeTheme.chipFill,
            in: RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
          )
          .glassEffect(.clear.interactive(), in: .rect(cornerRadius: NativeLayout.cornerRadius))
      } else {
        content.background {
          if hovering {
            RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
              .fill(NativeTheme.chipHover)
          }
        }
      }
    } else {
      content.background {
        if selected {
          RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
            .fill(NativeTheme.chipFill)
        } else if hovering {
          RoundedRectangle(cornerRadius: NativeLayout.cornerRadius, style: .continuous)
            .fill(NativeTheme.chipHover)
        }
      }
    }
  }
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

/// Fanqie primary button: flat brand-orange fill, white text, 6pt radius.
/// Hover uses #FF721F, pressed #D24600 — the same ladder as the web buttons.
private struct FanqiePrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(
        configuration.isPressed
          ? NativeTheme.brandPressed
          : hovering ? NativeTheme.brandHover : NativeTheme.brand,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.15), value: hovering)
  }
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
    switch prominence {
    case .prominent:
      Button(action: action) { label }
        .buttonStyle(FanqiePrimaryButtonStyle())
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

/// Progress for the 同人 source-ingestion pass.
///
/// The pass is checkpointed per batch, so an incomplete run is a resumable state
/// rather than a failure: the banner keeps the resume affordance visible instead of
/// disappearing, and refuses to be dismissed while work is in flight.
struct DerivativePreparationBanner: View {
  let state: DerivativePreparationState
  let resume: () -> Void
  let dismiss: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      if state.isRunning {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: state.isComplete ? "checkmark.seal.fill" : "pause.circle.fill")
          .foregroundStyle(state.isComplete ? .green : .orange)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("《\(state.bookTitle)》原著导入：\(state.phase)")
          .font(.callout.weight(.semibold))
        if state.sourceChapterCount > 0 {
          ProgressView(value: state.canonProgress)
            .progressViewStyle(.linear)
            .frame(maxWidth: 320)
          Text(detailLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        if let failure = state.failure, !failure.isEmpty {
          Text(failure)
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if !state.isRunning && state.needsResume {
        Button("继续处理", action: resume)
          .buttonStyle(.link)
      }
      if !state.isRunning {
        Button(action: dismiss) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("关闭原著导入提示")
        .accessibilityLabel("关闭原著导入提示")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background((state.isComplete ? Color.green : Color.accentColor).opacity(0.1))
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityElement(children: .contain)
  }

  private var detailLine: String {
    var parts = ["正典 \(state.canonChaptersDone)/\(state.sourceChapterCount) 章"]
    if state.entityCount > 0 { parts.append("实体 \(state.entityCount)") }
    if state.timelineCount > 0 { parts.append("时间线事件 \(state.timelineCount)") }
    if !state.overlayComplete { parts.append("作者设定待登记") }
    if state.totalPassages > 0 {
      parts.append("向量 \(state.embeddedPassages)/\(state.totalPassages)")
    }
    return parts.joined(separator: " · ")
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

/// A TextKit reader keeps glyph layout incremental while the split view resizes.
/// SwiftUI's selectable Text eagerly redraws a complete long chapter on every width change.
struct NativeChapterTextReader: NSViewRepresentable {
  let content: String

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.setAccessibilityLabel("章节正文")

    let textView = NSTextView(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.usesFindBar = true
    textView.allowsUndo = false
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 22, height: 18)
    textView.textContainer?.lineFragmentPadding = 0
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.layoutManager?.allowsNonContiguousLayout = true
    scrollView.documentView = textView

    configure(textView, for: content, coordinator: context.coordinator)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    configure(textView, for: content, coordinator: context.coordinator)
  }

  private func configure(_ textView: NSTextView, for content: String, coordinator: Coordinator) {
    let displayedContent = content.isEmpty ? "本章暂时没有正文。" : content
    guard coordinator.content != content else { return }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 6
    textView.defaultParagraphStyle = paragraphStyle
    textView.font = NSFont(name: "Songti SC", size: 15) ?? .systemFont(ofSize: 15)
    textView.textColor = content.isEmpty ? .secondaryLabelColor : .labelColor
    textView.string = displayedContent
    coordinator.content = content
  }

  final class Coordinator {
    var content: String?
  }
}


/// Gives SwiftUI access to the hosting NSWindow so the chrome can become
/// real glass: with an opaque window, SwiftUI materials only flatten against
/// the window's own background. Clearing the window background lets
/// `.regularMaterial` / `.thinMaterial` blend with the desktop backdrop,
/// which is what produces genuine frosted translucency.
struct WindowAccessor: NSViewRepresentable {
  let configure: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { [weak view] in
      guard let window = view?.window else { return }
      configure(window)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let window = nsView.window else { return }
    configure(window)
  }
}
