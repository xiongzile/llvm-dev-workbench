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
    let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LLVM_WORKBENCH_HOME"]!)
    let root = home.appendingPathComponent("checkout")
    for component in ["llvm", "clang"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(component), withIntermediateDirectories: true)
    }
    try """
    cmake_minimum_required(VERSION 3.20)
    project(FeedbackFixture LANGUAGES NONE)
    set(LLVM_ALL_PROJECTS "clang")
    set(LLVM_ALL_TARGETS AArch64 X86)
    set(LLVM_SUPPORTED_RUNTIMES "libcxx")
    add_custom_target(slow COMMAND "${CMAKE_COMMAND}" -E sleep 30)
    add_custom_target(ok COMMAND "${CMAKE_COMMAND}" -E echo "feedback test completed")
    add_custom_target(fail COMMAND "${CMAKE_COMMAND}" -E false)
    """.write(
      to: root.appendingPathComponent("llvm/CMakeLists.txt"), atomically: true, encoding: .utf8)
    let snapshot: Workspace = try await Core.call(["action": "inspect", "root": root.path])
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
    precondition(model.running && model.starting && model.activityTitle == "构建中…")
    precondition(model.taskPhase.contains("构建中"))
    model.start("build", targets: ["ok"])
    try await waitUntil { model.job?.status == "running" }
    precondition(model.error == nil, "Repeat click produced an error")
    model.cancel()
    try await waitUntil { !model.running }
    precondition(model.job?.status == "cancelled")
    await model.refreshHistory()
    precondition(model.history.count == 2, "Repeat click created an extra task")

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
    print("PASS: immediate feedback, duplicate clicks, startup cancellation, failure recovery")
  }
}
