import Foundation

// Exercises the real Swift presentation model and native Core together, without
// a window or an LLVM build. The fixture is isolated from the user's app state.
@main struct OperationFeedbackTests {
  @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(15)
    while !condition() {
      precondition(Date() < deadline, "Timed out waiting for task state")
      try await Task.sleep(nanoseconds: 30_000_000)
    }
  }

  @MainActor static func main() async throws {
    try LocalizationTests.run()
    let savedLanguage = UserDefaults.standard.string(forKey: L10n.preferenceKey)
    defer {
      if let savedLanguage {
        UserDefaults.standard.set(savedLanguage, forKey: L10n.preferenceKey)
      } else {
        UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
      }
    }
    UserDefaults.standard.set("en", forKey: L10n.preferenceKey)
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LLVM_WORKBENCH_HOME"]!)
    let root = home.appendingPathComponent("checkout")
    for component in ["llvm", "clang"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(component), withIntermediateDirectories: true)
    }
    try """
    cmake_minimum_required(VERSION 3.20)
    project(FeedbackFixture LANGUAGES C)
    file(WRITE "${CMAKE_BINARY_DIR}/ide.c" "int main(void) { return 0; }")
    add_executable(ide-tool "${CMAKE_BINARY_DIR}/ide.c")
    set(LLVM_ALL_PROJECTS "clang")
    set(LLVM_ALL_TARGETS AArch64 X86)
    set(LLVM_SUPPORTED_RUNTIMES "libcxx")
    add_custom_target(slow COMMAND "${CMAKE_COMMAND}" -E sleep 30)
    add_custom_target(ok COMMAND "${CMAKE_COMMAND}" -E echo "feedback test completed")
    add_custom_target(fail COMMAND "${CMAKE_COMMAND}" -E false)
    add_custom_target(llvm-headers COMMAND "${CMAKE_COMMAND}" -P "${CMAKE_SOURCE_DIR}/headers.cmake")
    """.write(
      to: root.appendingPathComponent("llvm/CMakeLists.txt"), atomically: true, encoding: .utf8)
    try """
    if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/fail-headers")
      message(FATAL_ERROR "Header generation failed")
    endif()
    file(WRITE "ide-headers-ready" "ready")
    """.write(to: root.appendingPathComponent("llvm/headers.cmake"), atomically: true, encoding: .utf8)
    let snapshot: Workspace = try await Core.call(["action": "inspect", "root": root.path])
    precondition(snapshot.defaultProfile.linker == "system")
    var lldProfile = snapshot.defaultProfile
    lldProfile.linker = "lld"
    let savedLLD: Profile = try await Core.call([
      "action": "save_profile", "root": root.path, "profile": try Core.encode(lldProfile),
    ])
    let reopened: Workspace = try await Core.call(["action": "inspect", "root": root.path])
    precondition(reopened.profiles.first(where: { $0.id == savedLLD.id })?.linker == "lld")
    let profile: Profile = try await Core.call([
      "action": "save_profile", "root": root.path,
      "profile": try Core.encode(snapshot.defaultProfile),
    ])
    let model = WorkspaceModel()
    model.workspace = try await Core.call(["action": "inspect", "root": root.path])
    model.profileId = profile.id

    model.start("configure")
    precondition(model.running && model.starting && model.job == nil)
    model.start("build", targets: ["ok"])  // Must be ignored before the first await.
    try await waitUntil { !model.running }
    precondition(model.job?.status == "succeeded", model.error ?? "Configure failed")
    await model.refreshHistory()
    precondition(model.history.count == 1, "Duplicate request reached Core")

    model.start("build", targets: ["slow"])
    precondition(model.running && model.starting && model.activityTitle == "Building…")
    precondition(model.isBuilding("slow") && !model.isBuilding("ide-tool"), "Busy state must belong to the requested target")
    precondition(model.taskPhase == "Starting task…")
    UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
    precondition(model.running && model.activityTitle == "构建中…")
    precondition(model.taskPhase == "正在启动任务…")
    precondition(model.profileId == profile.id && model.page == .workbench)
    model.start("build", targets: ["ok"])
    try await waitUntil { model.job?.status == "running" }
    precondition(model.error == nil, "Repeat click produced an error")
    model.cancel()
    try await waitUntil { !model.running }
    precondition(model.job?.status == "cancelled")
    await model.refreshHistory()
    precondition(model.history.count == 2, "Repeat click created an extra task")
    UserDefaults.standard.set("en", forKey: L10n.preferenceKey)

    model.start("build", targets: ["slow"])
    model.cancel()  // Cancel while start is still awaiting a Core operation ID.
    precondition(model.cancellationRequested && model.starting)
    try await waitUntil { !model.running }
    precondition(model.job?.status == "cancelled", "Early cancellation was lost")

    model.start("build", targets: ["missing-target"])
    precondition(model.running)
    try await waitUntil { !model.running }
    precondition(model.error != nil && model.startFailed && !model.starting)
    model.start("build", targets: ["fail"])
    try await waitUntil { !model.running }
    precondition(model.job?.status == "failed" && model.error == nil)
    model.start("build", targets: ["ok"])
    try await waitUntil { !model.running }
    precondition(model.job?.status == "succeeded" && !model.startFailed)
    precondition(model.job?.targets == ["ok"] && model.job?.operation == "build")
    precondition(model.records(for: "ok").first?.status == "succeeded")
    precondition(!model.isBuilding("ok"))
    model.toggleFavorite("ide-tool")
    model.favoritesOnly = true
    precondition(model.filtered.map(\.name) == ["ide-tool"])
    model.toggleFavorite("ide-tool")
    model.favoritesOnly = false
    UserDefaults.standard.removeObject(forKey: "favoriteTargets:" + root.path)
    var fresh = snapshot.defaultProfile
    fresh.name = "IDE fresh"
    let ideProfile: Profile = try await Core.call([
      "action": "save_profile", "root": root.path, "profile": try Core.encode(fresh),
    ])
    await model.open(root.path)
    model.selectProfile(ideProfile.id)
    model.prepareIDE("clion", target: "", arguments: [], installExtensions: false, launch: false)
    precondition(model.running && model.ideBusy)
    model.prepareIDE("vscode", target: "", arguments: [], installExtensions: false, launch: false)
    model.start("build", targets: ["slow"])
    model.selectProfile(profile.id)
    precondition(model.profileId == ideProfile.id)
    try await waitUntil { !model.running }
    precondition(model.error == nil, model.error ?? "IDE preparation failed")
    precondition(model.ideExport?.ide == "clion")
    precondition(model.configured && !model.pending)
    precondition(FileManager.default.fileExists(atPath: ideProfile.buildDir + "/ide-headers-ready"))
    precondition(
      FileManager.default.fileExists(atPath: model.ideExport!.path + "/.idea/workspace.xml"))
    try FileManager.default.removeItem(atPath: ideProfile.buildDir + "/ide-headers-ready")
    model.prepareIDE("clion", target: "", arguments: [], installExtensions: false, launch: false)
    try await waitUntil { !model.running }
    precondition(model.ideExport != nil)
    precondition(FileManager.default.fileExists(atPath: ideProfile.buildDir + "/ide-headers-ready"))
    try "fail".write(to: root.appendingPathComponent("llvm/fail-headers"), atomically: true, encoding: .utf8)
    model.prepareIDE("clion", target: "", arguments: [], installExtensions: false, launch: false)
    try await waitUntil { !model.running }
    precondition(model.job?.status == "failed")
    precondition(model.ideExport == nil, "Do not open an IDE after generated-header preparation fails")
    print(
      "PASS: immediate feedback, duplicate clicks, startup cancellation, failure recovery, IDE auto-prepare, header recovery and failure gating"
    )
  }
}
