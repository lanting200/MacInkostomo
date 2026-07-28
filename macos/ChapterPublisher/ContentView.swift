import SwiftUI

struct ContentView: View {
  @StateObject private var workspaceModel = WorkspaceModel()
  @StateObject private var bookSettingDrafts = BookSettingDraftStore()

  var body: some View {
    NativeWorkspaceView(model: workspaceModel, bookSettingDrafts: bookSettingDrafts)
    .frame(minWidth: 900, minHeight: 620)
    .tint(NativeTheme.brand)
    .background(WindowAccessor { window in
      window.isOpaque = false
      window.backgroundColor = .clear
      window.titlebarAppearsTransparent = true
    })
  }
}
