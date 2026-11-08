import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let _: Bool? = try? Core.sync(["action": "shutdown"])
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
      DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct LLVMWorkbenchApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject var model = WorkspaceModel()
  var body: some Scene {
    WindowGroup("LLVM Workbench") {
      WorkbenchView().environmentObject(model).frame(minWidth: 1080, minHeight: 720)
        .task {
          guard model.workspace == nil else { return }
          let args = CommandLine.arguments
          let path =
            args.firstIndex(of: "--workspace").flatMap {
              args.indices.contains($0 + 1) ? args[$0 + 1] : nil
            } ?? UserDefaults.standard.string(forKey: "lastWorkspace")
          if let path { await model.open(path) }
        }
        .preferredColorScheme(.light)
    }.defaultSize(width: 1380, height: 900).windowStyle(.hiddenTitleBar)
      .commands {
        CommandGroup(replacing: .newItem) {
          Button("打开 LLVM 工作区…") { model.openPanel() }.keyboardShortcut("o")
        }
        CommandMenu("构建") {
          Button("构建所选目标") {
            if let a = model.selected { model.start("build", targets: [a.name]) }
          }.keyboardShortcut("b").disabled(model.running || model.selected == nil)
          Button("取消当前任务") { model.cancel() }.keyboardShortcut(".").disabled(!model.running)
          Button("显示日志") { model.showLogs = true }.keyboardShortcut("l")
        }
      }
  }
}
