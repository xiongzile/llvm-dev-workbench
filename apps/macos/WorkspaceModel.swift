import AppKit
import SwiftUI

@MainActor final class WorkspaceModel: ObservableObject {
  @Published var workspace: Workspace?
  @Published var profileId = ""
  @Published var artifacts: [Artifact] = []
  @Published var configured = false
  @Published var pending = false
  @Published var search = ""
  @Published var selectedArtifact = ""
  @Published var category = "工具"
  @Published var page = "工作台"
  @Published var busy = false
  @Published var error: String?
  @Published var job: CoreJob?
  @Published var history: [CoreJob] = []
  @Published var showLogs = false
  @Published var editor: Profile?
  @Published var runArtifact: Artifact?
  @Published var testPath = ""
  @Published var saving = false
  @Published private(set) var starting = false
  @Published private(set) var activeOperation: String?
  @Published private(set) var cancellationRequested = false
  @Published private(set) var startFailed = false
  private var cancellationSent = false
  var running: Bool { starting || job?.status == "running" }
  var activityTitle: String {
    if cancellationRequested { return "取消中…" }
    switch activeOperation {
    case "configure": return "准备中…"
    case "run": return "运行中…"
    case "test": return "测试中…"
    default: return "构建中…"
    }
  }
  var taskPhase: String {
    if running && cancellationRequested { return "正在取消…" }
    if starting { return activityTitle + " 正在准备任务" }
    if job?.status == "running" { return "正在" + (job?.phase ?? "执行任务") }
    if startFailed { return "启动失败" }
    return job?.phase ?? "准备好开始工作"
  }
  var profile: Profile? { workspace?.profiles.first { $0.id == profileId } }
  var selected: Artifact? { artifacts.first { $0.name == selectedArtifact } }
  var filtered: [Artifact] {
    let priorities = ["clang", "llc", "opt", "llvm-mc", "FileCheck"]
    return artifacts.filter { a in
      let matches =
        search.isEmpty || a.name.localizedCaseInsensitiveContains(search)
        || a.description.localizedCaseInsensitiveContains(search)
      let kind =
        page == "测试"
        ? a.name.hasPrefix("check-")
        : category == "工具"
          ? a.kind == "EXECUTABLE"
          : category == "库"
            ? a.kind.contains("LIBRARY") : category == "测试" ? a.name.hasPrefix("check-") : true
      return matches && kind
    }.sorted { a, b in
      let i = priorities.firstIndex(of: a.name) ?? 999
      let j = priorities.firstIndex(of: b.name) ?? 999
      return i == j ? a.name < b.name : i < j
    }
  }
  func openPanel() {
    guard !running else {
      error = "请先等待当前任务结束，或取消任务后再切换工作区。"
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "选择 LLVM 源码目录"
    panel.prompt = "打开工作区"
    if panel.runModal() == .OK, let url = panel.url { Task { await open(url.path) } }
  }
  func open(_ path: String) async {
    busy = true
    defer { busy = false }
    do {
      let snapshot: Workspace = try await Core.call(["action": "inspect", "root": path])
      if workspace?.root != snapshot.root {
        search = ""
        selectedArtifact = ""
        testPath = ""
        category = "工具"
        page = "工作台"
        if !running { job = nil }
      }
      workspace = snapshot
      UserDefaults.standard.set(snapshot.root, forKey: "lastWorkspace")
      if !snapshot.profiles.contains(where: { $0.id == profileId }) {
        profileId =
          UserDefaults.standard.string(forKey: "profile:" + snapshot.root).flatMap { id in
            snapshot.profiles.contains { $0.id == id } ? id : nil
          } ?? snapshot.profiles.first?.id ?? ""
      }
      await refreshArtifacts()
      await refreshHistory()
    } catch { self.error = error.localizedDescription }
  }
  func selectProfile(_ id: String) {
    profileId = id
    if let root = workspace?.root { UserDefaults.standard.set(id, forKey: "profile:" + root) }
    Task { await refreshArtifacts() }
  }
  func refreshArtifacts() async {
    guard let workspace, let profile else {
      artifacts = []
      configured = false
      pending = false
      return
    }
    let id = profile.id
    busy = true
    defer { busy = false }
    do {
      let result: ArtifactResult = try await Core.call([
        "action": "artifacts", "root": workspace.root, "profile_id": id,
      ])
      guard self.profileId == id && self.workspace?.root == workspace.root else { return }
      artifacts = result.artifacts
      configured = result.configured
      pending = result.pending
      if !artifacts.contains(where: { $0.name == selectedArtifact }) {
        selectedArtifact = filtered.first?.name ?? ""
      }
    } catch { self.error = error.localizedDescription }
  }
  func refreshHistory() async {
    guard let root = workspace?.root else { return }
    do { history = try await Core.call(["action": "history", "root": root]) } catch {
      self.error = error.localizedDescription
    }
  }
  func createEnvironment(copy: Profile? = nil) {
    guard let workspace else { return }
    var p = copy ?? workspace.defaultProfile
    if copy != nil {
      p.id = ""
      p.buildDir = ""
      p.name += " 副本"
    }
    editor = p
  }
  func editEnvironment() {
    guard let profile else {
      createEnvironment()
      return
    }
    editor = profile
  }
  func save(_ p: Profile, prepare: Bool) async {
    guard let root = workspace?.root else { return }
    saving = true
    defer { saving = false }
    do {
      let normalized: Profile = try await Core.call([
        "action": "preview_profile", "root": root, "profile": try Core.encode(p),
      ])
      let saved: Profile = try await Core.call([
        "action": "save_profile", "root": root, "profile": try Core.encode(normalized),
      ])
      editor = nil
      profileId = saved.id
      await open(root)
      if prepare { start("configure") }
    } catch { self.error = error.localizedDescription }
  }
  func start(
    _ operation: String, targets: [String] = [], target: String = "", arguments: [String] = [],
    test: String = ""
  ) {
    guard !running, let workspace, let profile else { return }
    // Reserve the UI synchronously, before planning or any async suspension.
    // This covers repeated mouse clicks, keyboard shortcuts, and other entry points.
    activeOperation = operation
    starting = true
    cancellationRequested = false
    cancellationSent = false
    startFailed = false
    job = nil
    error = nil
    Task {
      do {
        let result: OperationStart = try await Core.call([
          "action": "start", "root": workspace.root, "profile_id": profile.id,
          "operation": operation,
          "targets": targets, "target": target, "arguments": arguments, "test_path": test,
        ])
        if cancellationRequested { await requestCancellation(result.id) }
        await poll(result.id)
      } catch {
        starting = false
        activeOperation = nil
        cancellationRequested = false
        startFailed = true
        self.error = error.localizedDescription
      }
    }
  }
  func poll(_ id: String) async {
    while true {
      do {
        let result: CoreJob = try await Core.call(["action": "poll", "id": id])
        job = result
        starting = false
        if result.status == "running" && cancellationRequested && !cancellationSent {
          await requestCancellation(id)
        }
        if result.status != "running" {
          activeOperation = nil
          cancellationRequested = false
          await refreshArtifacts()
          await refreshHistory()
          return
        }
        try await Task.sleep(nanoseconds: 500_000_000)
      } catch {
        self.error = error.localizedDescription
        return
      }
    }
  }
  func cancel() {
    guard running, !cancellationRequested else { return }
    cancellationRequested = true
    // A click during planning is remembered until Core returns the operation ID.
    if let id = job?.id { Task { await requestCancellation(id) } }
  }
  private func requestCancellation(_ id: String) async {
    guard !cancellationSent else { return }
    cancellationSent = true
    do { let _: CoreJob = try await Core.call(["action": "cancel", "id": id]) } catch {
      cancellationSent = false
      cancellationRequested = false
      self.error = error.localizedDescription
    }
  }
  func chooseTest() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.message = "选择源码仓库中的回归测试文件或目录"
    if let root = workspace?.root { panel.directoryURL = URL(fileURLWithPath: root) }
    if panel.runModal() == .OK { testPath = panel.url?.path ?? "" }
  }
  func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
  func openIDE() {
    guard let root = workspace?.root else { return }
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowedContentTypes = [.application]
    panel.message = "选择 IDE，打开 LLVM 源码工程"
    if panel.runModal() == .OK, let app = panel.url {
      NSWorkspace.shared.open(
        [URL(fileURLWithPath: root + "/llvm")], withApplicationAt: app,
        configuration: NSWorkspace.OpenConfiguration())
    }
  }
}
