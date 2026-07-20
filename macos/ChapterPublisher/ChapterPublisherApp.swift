import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var serverManager: ServerManager?

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_ notification: Notification) {
    serverManager?.applicationWillTerminate()
  }
}

@main
struct ChapterPublisherApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var serverManager = ServerManager()

  var body: some Scene {
    WindowGroup("MacInkostomo") {
      ContentView()
        .environmentObject(serverManager)
        .onAppear {
          appDelegate.serverManager = serverManager
          serverManager.startIfNeeded()
        }
    }
    .defaultSize(width: 1280, height: 820)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}
