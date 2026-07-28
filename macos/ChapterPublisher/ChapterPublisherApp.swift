import SwiftUI

@main
struct ChapterPublisherApp: App {
  var body: some Scene {
    WindowGroup("MacInkostomo") {
      ContentView()
        .preferredColorScheme(.light)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1280, height: 820)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}
