import AppKit
import SwiftUI

@MainActor final class WorkspaceModel: ObservableObject {
  @Published var workspace: Workspace?
  @Published var profileId = ""
  @Published var artifacts: [Artifact] = []
  @Published var configured = false
  @Published var pending = false
  @Published var buildCache: [String: String] = [:]
  @Published private(set) var favorites: Set<String> = []
  @Published var favoritesOnly = false
  @Published var focusSearch = 0
  @Published private(set) var requestedTargets: [String] = []
  @Published var search = ""
  @Published var selectedArtifact = ""
  @Published var category: ArtifactCategory = .tools
  @Published var page: WorkbenchPage = .workbench
  @Published var busy = false
  @Published var error: String?
  @Published var job: CoreJob?
  @Published var history: [CoreJob] = []
  @Published var showLogs = false
  @Published var editor: Profile?
  @Published var runArtifact: Artifact?
  @Published var testPath = ""
  @Published var saving = false
  @Published var showIDE = false
  @Published private(set) var ideBusy = false
  @Published private(set) var idePhase = ""
  @Published var ideExport: IDEExport?
  @Published private(set) var starting = false
  @Published private(set) var activeOperation: String?
  @Published private(set) var cancellationRequested = false
  @Published private(set) var startFailed = false
  private var cancellationSent = false
  var running: Bool { ideBusy || starting || job?.status == "running" }
  var activityTitle: String {
    if cancellationRequested { return L("Cancelling…") }
    if ideBusy { return L(idePhase) }
    switch activeOperation {
    case "configure": return L("Preparing…")
    case "run": return L("Running…")
    case "test": return L("Testing…")
    default: return L("Building…")
    }
  }
  var taskPhase: String {
    if running && cancellationRequested { return L("Cancelling…") }
    if starting { return L("Starting task…") }
    if job?.status == "running" { return L10n.coreText(job?.phase ?? "Running") }
    if startFailed { return L("Could not start") }
    return job.map { L10n.coreText($0.phase) } ?? L("Ready to start")
  }
  var profile: Profile? { workspace?.profiles.first { $0.id == profileId } }
  var selected: Artifact? { artifacts.first { $0.name == selectedArtifact } }
  var categoryArtifacts: [Artifact] {
    artifacts.filter { a in
      switch category {
      case .tools: return a.kind == "EXECUTABLE"
      case .libraries: return a.kind.contains("LIBRARY")
      case .tests: return a.name.hasPrefix("check-")
      case .all: return true
      }
    }
  }
  func records(for name: String) -> [CoreJob] {
    var result = history.filter { $0.profileId == profileId && ($0.targets ?? []).contains(name) }
    if let job, job.profileId == profileId, (job.targets ?? []).contains(name) {
      result.removeAll { $0.id == job.id }
      result.insert(job, at: 0)
    }
    return result.sorted { $0.started > $1.started }
  }
  func isBuilding(_ name: String) -> Bool {
    if starting { return requestedTargets.contains(name) }
    guard let job, job.profileId == profileId, job.status == "running",
      ["Building tools", "Updating test dependencies", "Preparing generated headers"].contains(
        job.phase)
    else { return false }
    return (job.targets ?? []).contains(name)
  }
  func toggleFavorite(_ name: String) {
    if favorites.contains(name) { favorites.remove(name) } else { favorites.insert(name) }
    if let root = workspace?.root {
      UserDefaults.standard.set(favorites.sorted(), forKey: "favoriteTargets:" + root)
    }
  }
  func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
  func openLog(_ record: CoreJob) {
    NSWorkspace.shared.open(URL(fileURLWithPath: record.logPath))
  }
  func requestRun() {
    guard !running, !pending, let selected, selected.kind == "EXECUTABLE" else { return }
    runArtifact = selected
  }
  var filtered: [Artifact] {
    let priorities = ["clang", "llc", "opt", "llvm-mc", "FileCheck"]
    let localization = L10n.current
    return categoryArtifacts.filter { a in
      let matches =
        search.isEmpty || a.name.localizedCaseInsensitiveContains(search)
        || localization.translatedCoreText(a.description).localizedCaseInsensitiveContains(search)
      return matches && (!favoritesOnly || favorites.contains(a.name))
    }.sorted { a, b in
      if favorites.contains(a.name) != favorites.contains(b.name) {
        return favorites.contains(a.name)
      }
      let i = priorities.firstIndex(of: a.name) ?? 999
      let j = priorities.firstIndex(of: b.name) ?? 999
      return i == j ? a.name < b.name : i < j
    }
  }
  func openPanel() {
    guard !running else {
      error = "Wait for the current task to finish or cancel it before switching workspaces."
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = L("Select the LLVM source directory")
    panel.prompt = L("Open Workspace")
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
        category = .tools
        page = .workbench
        if !running { job = nil }
      }
      workspace = snapshot
      favorites = Set(
        UserDefaults.standard.stringArray(forKey: "favoriteTargets:" + snapshot.root) ?? [])
      UserDefaults.standard.set(snapshot.root, forKey: "lastWorkspace")
      if !snapshot.profiles.contains(where: { $0.id == profileId }) {
        profileId =
          UserDefaults.standard.string(forKey: "profile:" + snapshot.root).flatMap { id in
            snapshot.profiles.contains { $0.id == id } ? id : nil
          } ?? snapshot.profiles.first?.id ?? ""
      }
      await refreshArtifacts()
      await refreshHistory()
    } catch { self.error = (error as? CoreFailure)?.message ?? error.localizedDescription }
  }
  func selectProfile(_ id: String) {
    guard !running else { return }
    profileId = id
    if let root = workspace?.root { UserDefaults.standard.set(id, forKey: "profile:" + root) }
    Task { await refreshArtifacts() }
  }
  func refreshArtifacts() async {
    guard let workspace, let profile else {
      artifacts = []
      configured = false
      pending = false
      buildCache = [:]
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
      buildCache = result.cache
      if !artifacts.contains(where: { $0.name == selectedArtifact }) {
        selectedArtifact = filtered.first?.name ?? ""
      }
    } catch { self.error = (error as? CoreFailure)?.message ?? error.localizedDescription }
  }
  func refreshHistory() async {
    guard let root = workspace?.root else { return }
    do { history = try await Core.call(["action": "history", "root": root]) } catch {
      self.error = (error as? CoreFailure)?.message ?? error.localizedDescription
    }
  }
  func createEnvironment(copy: Profile? = nil) {
    guard let workspace else { return }
    var p = copy ?? workspace.defaultProfile
    if copy != nil {
      p.id = ""
      p.buildDir = ""
      p.name = L("%@ copy", p.name)
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
    } catch { self.error = (error as? CoreFailure)?.message ?? error.localizedDescription }
  }
  func start(
    _ operation: String, targets: [String] = [], target: String = "", arguments: [String] = [],
    test: String = ""
  ) {
    guard !running, let workspace, let profile else { return }
    // Reserve the UI synchronously, before planning or any async suspension.
    // This covers repeated mouse clicks, keyboard shortcuts, and other entry points.
    activeOperation = operation
    requestedTargets = operation == "run" ? [target] : targets
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
        self.error = (error as? CoreFailure)?.message ?? error.localizedDescription
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
        self.error = (error as? CoreFailure)?.message ?? error.localizedDescription
        return
      }
    }
  }
  func cancel() {
    guard starting || job?.status == "running", !cancellationRequested else { return }
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
      self.error = (error as? CoreFailure)?.message ?? error.localizedDescription
    }
  }
  func chooseTest() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.message = L("Select a regression test file or directory in the source checkout")
    if let root = workspace?.root { panel.directoryURL = URL(fileURLWithPath: root) }
    if panel.runModal() == .OK { testPath = panel.url?.path ?? "" }
  }
  func reveal(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
  func openIDE() {
    guard !running, profile != nil else { return }
    showIDE = true
  }
  func prepareIDE(
    _ ide: String, target: String, arguments: [String], installExtensions: Bool, launch: Bool = true
  ) {
    guard !running, let workspace, let profile else { return }
    // Reserve immediately; preparation, extension setup, export and launch form one UI action.
    ideBusy = true
    idePhase = "Preparing IDE…"
    error = nil
    ideExport = nil
    Task {
      defer {
        ideBusy = false
        activeOperation = nil
        starting = false
      }
      do {
        let identifier = ide == "clion" ? "com.jetbrains.CLion" : "com.microsoft.VSCode"
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        if launch && app == nil {
          throw CoreFailure(
            message: ide == "clion" ? "CLion is not installed." : "VS Code is not installed.")
        }
        let state: ArtifactResult = try await Core.call([
          "action": "artifacts", "root": workspace.root, "profile_id": profile.id,
        ])
        var operations: [String] = []
        if !state.configured || state.pending
          || !FileManager.default.fileExists(atPath: profile.buildDir + "/compile_commands.json")
        {
          operations.append("configure")
        }
        operations.append("ide_headers")
        if ide == "vscode" && installExtensions { operations.append("ide_extensions") }
        for operation in operations {
          switch operation {
          case "configure": idePhase = "Preparing environment…"
          case "ide_headers": idePhase = "Preparing generated headers…"
          default: idePhase = "Setting up VS Code extensions…"
          }
          activeOperation = operation
          starting = true
          job = nil
          cancellationRequested = false
          cancellationSent = false
          startFailed = false
          let result: OperationStart = try await Core.call([
            "action": "start", "root": workspace.root, "profile_id": profile.id,
            "operation": operation,
          ])
          if cancellationRequested { await requestCancellation(result.id) }
          await poll(result.id)
          guard job?.status == "succeeded" else { return }
        }
        idePhase = "Generating IDE configuration…"
        let result: IDEExport = try await Core.call([
          "action": "ide", "root": workspace.root, "profile_id": profile.id,
          "ide": ide, "target": target, "arguments": arguments,
        ])
        ideExport = result
        if launch, let app {
          idePhase = "Opening IDE…"
          try await NSWorkspace.shared.open(
            [URL(fileURLWithPath: result.path)], withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration())
          showIDE = false
        }
      } catch {
        self.error = (error as? CoreFailure)?.message ?? error.localizedDescription
      }
    }
  }
}
