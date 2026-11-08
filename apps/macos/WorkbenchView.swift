import AppKit
import SwiftUI

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
      blue: Double(hex & 255) / 255, opacity: 1)
  }
}
enum Paint {
  static let canvas = Color(hex: 0xF8F6F1), sidebar = Color(hex: 0xEEEAE2),
    ink = Color(hex: 0x2C2925), muted = Color(hex: 0x77716A)
  static let accent = Color(hex: 0xB96949), selection = Color(hex: 0xEFDFD3),
    line = Color(hex: 0xE2DDD5), panel = Color(hex: 0xFBF9F5)
}
struct PrimaryButton: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(
      .vertical, 7
    ).frame(minHeight: 18).foregroundStyle(isEnabled ? Color.white : Paint.muted).background(
      isEnabled
        ? Paint.accent.opacity(configuration.isPressed ? 0.75 : 1) : Paint.line.opacity(0.65),
      in: RoundedRectangle(cornerRadius: 6)
    ).contentShape(Rectangle())
  }
}
struct QuietButton: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
      .foregroundStyle(isEnabled ? Paint.ink : Paint.muted).background(
        !isEnabled
          ? Paint.line.opacity(0.3) : configuration.isPressed ? Paint.selection : Paint.panel,
        in: RoundedRectangle(cornerRadius: 6)
      ).overlay(RoundedRectangle(cornerRadius: 6).stroke(Paint.line, lineWidth: 1)).contentShape(
        Rectangle())
  }
}
struct WorkbenchView: View {
  @EnvironmentObject var m: WorkspaceModel
  @ObservedObject private var language = LanguageSettings.shared
  @AppStorage("workbench.sidebarWidth") private var sidebarWidth = 208.0
  @AppStorage("workbench.inspectorWidth") private var inspectorWidth = 340.0
  @State private var sidebarDragWidth: CGFloat?
  @State private var inspectorDragWidth: CGFloat?
  @FocusState private var searchFocused: Bool
  var body: some View {
    GeometryReader { geometry in
      let width = max(176, min(sidebarDragWidth ?? CGFloat(sidebarWidth), min(360, geometry.size.width - 752)))
      HStack(spacing: 0) {
        sidebar.frame(width: width).island(Paint.sidebar)
        SplitHandle(title: L("Resize sidebar"), width: width, resize: { requestedWidth in
          sidebarDragWidth = max(176, min(requestedWidth, min(360, geometry.size.width - 752)))
        }, commit: {
          if let width = sidebarDragWidth { sidebarWidth = Double(width) }
          sidebarDragWidth = nil
        })
        VStack(spacing: 10) {
          toolbar.island()
          if m.workspace == nil {
            welcome
          } else if m.page == .environments {
            environmentPage.island()
          } else if m.page == .history {
            historyPage.island()
          } else {
            workspacePage
          }
          taskBar.island()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.padding(12).background(Paint.canvas)
      .onChange(of: m.focusSearch) { _, _ in
        DispatchQueue.main.async { searchFocused = true }
      }
      .foregroundStyle(Paint.ink).tint(Paint.accent)
      .alert(
        L("Operation could not be completed"),
        isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })
      ) {
        Button(L("OK")) { m.error = nil }
      } message: {
        Text(L10n.coreText(m.error ?? ""))
      }
      .sheet(item: $m.editor) { p in EnvironmentEditor(initial: p).environmentObject(m) }
      .sheet(item: $m.runArtifact) { a in RunSheet(artifact: a).environmentObject(m) }
      .sheet(isPresented: $m.showIDE) { IDESheet().environmentObject(m) }
      .sheet(isPresented: $m.showLogs) { LogSheet().environmentObject(m) }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("LLVM Workbench").font(.custom("Georgia", size: 18))
        .padding(.horizontal, 20).padding(.top, 37).padding(.bottom, 28)
      Text(L("Workspace")).font(.system(size: 11, weight: .medium)).foregroundStyle(Paint.muted)
        .padding(.horizontal, 20)
      Button(action: m.openPanel) {
        HStack(spacing: 9) {
          Image(systemName: "folder").foregroundStyle(Paint.muted)
          Text(m.workspace?.name ?? L("Open LLVM Source")).font(.system(size: 13, weight: .medium))
            .lineLimit(1)
          Spacer()
          Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(Paint.muted)
        }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity)
          .contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.horizontal, 10).padding(.top, 5)
        .help(L("Open another LLVM workspace"))
      VStack(spacing: 3) {
        nav(.workbench, "rectangle.split.2x1")
        nav(.environments, "slider.horizontal.3")
        nav(.history, "clock.arrow.circlepath")
      }.padding(.horizontal, 10).padding(.top, 18)
      Divider().overlay(Paint.line).padding(.horizontal, 20).padding(.vertical, 20)
      HStack {
        Text(L("Build Environments")).font(.system(size: 11, weight: .medium))
        Spacer()
        Button {
          m.createEnvironment()
        } label: {
          Image(systemName: "plus").font(.system(size: 12))
            .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(m.workspace == nil || m.running)
          .help(L("New Environment")).accessibilityLabel(L("New Environment"))
      }.foregroundStyle(Paint.muted).padding(.leading, 20).padding(.trailing, 12)
      ScrollView {
        LazyVStack(spacing: 3) {
          ForEach(m.workspace?.profiles ?? []) { p in
            Button {
              m.selectProfile(p.id)
            } label: {
              HStack(spacing: 9) {
                Circle().fill(m.profileId == p.id ? Paint.accent : Paint.line)
                  .frame(width: 6, height: 6)
                Text(p.name).font(
                  .system(size: 12, weight: m.profileId == p.id ? .medium : .regular)
                )
                .lineLimit(2)
                Spacer(minLength: 0)
              }.padding(.horizontal, 11).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading).background(
                  m.profileId == p.id ? Paint.selection.opacity(0.55) : Color.clear,
                  in: RoundedRectangle(cornerRadius: 5)
                ).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(m.running)
          }
        }.padding(.horizontal, 10)
      }.padding(.top, 5)
      HStack(spacing: 8) {
        Image(systemName: "globe").font(.system(size: 12))
        Menu {
          LanguagePicker()
        } label: {
          Text(L("Language")).font(.system(size: 11))
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Language"))
        Spacer()
      }.foregroundStyle(Paint.muted).padding(.horizontal, 20).frame(height: 42)
    }.frame(maxHeight: .infinity)
  }
  private func nav(_ page: WorkbenchPage, _ icon: String) -> some View {
    Button {
      m.page = page
      m.search = ""
      if page == .history { Task { await m.refreshHistory() } }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: icon).font(.system(size: 14)).frame(width: 18)
          .foregroundStyle(Paint.muted)
        Text(page.title).font(.system(size: 13, weight: m.page == page ? .medium : .regular))
        Spacer()
      }.frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.vertical, 9).background(
        m.page == page ? Paint.ink.opacity(0.065) : Color.clear,
        in: RoundedRectangle(cornerRadius: 5)
      ).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  private var toolbar: some View {
    HStack(spacing: 10) {
      Text(m.workspace?.name ?? "LLVM Workbench").font(.system(size: 13, weight: .medium))
      Text("/").foregroundStyle(Paint.line)
      Menu {
        ForEach(m.workspace?.profiles ?? []) { p in Button(p.name) { m.selectProfile(p.id) } }
      } label: {
        Text(m.profile?.name ?? L("Choose an environment")).lineLimit(1)
      }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
      Spacer()
      if m.profile != nil {
        Button(action: m.openIDE) { Label(L("Open in IDE…"), systemImage: "curlybraces") }
          .buttonStyle(QuietButton()).disabled(m.running)
      }
      if m.busy { ProgressView().controlSize(.small) }
      Button {
        if let root = m.workspace?.root { Task { await m.open(root) } }
      } label: {
        Image(systemName: "arrow.clockwise")
      }.buttonStyle(.plain).frame(width: 28, height: 28).contentShape(Rectangle())
        .help(L("Refresh environments and artifacts"))
        .accessibilityLabel(L("Refresh environments and artifacts"))
    }.padding(.horizontal, 16).frame(height: 48)
  }
  private var welcome: some View {
    VStack(spacing: 22) {
      Image(systemName: "folder").font(.system(size: 30, weight: .light)).foregroundStyle(
        Paint.muted)
      Text(L("Open LLVM Workspace…")).font(.system(size: 22, weight: .semibold))
      Text(L("Open a source checkout, choose projects and backends, and build the tools you need."))
        .foregroundStyle(Paint.muted)
      Button(L("Open LLVM Workspace…"), action: m.openPanel).buttonStyle(PrimaryButton())
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var workspacePage: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 13) {
        environmentStrip
        if m.configured { BuildSummary().environmentObject(m) }
      }.padding(16).island()
      if m.profile == nil {
        VStack(spacing: 14) {
          Text(L("No build environments yet")).font(.system(size: 18, weight: .medium))
          Text(L("Choose any combination of components from this checkout."))
            .font(.system(size: 13)).foregroundStyle(Paint.muted)
          Button(L("New Environment")) { m.createEnvironment() }.buttonStyle(PrimaryButton())
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !m.configured {
        VStack(spacing: 14) {
          Text(L("Environment saved. Ready to prepare.")).font(.system(size: 18, weight: .medium))
          Text(
            L(
              "Your settings are saved. Prepare the environment to create or regenerate its build files."
            )
          )
          .font(.system(size: 13)).foregroundStyle(Paint.muted)
          .multilineTextAlignment(.center).frame(maxWidth: 440)
          Button(m.running ? m.activityTitle : L("Prepare Environment")) { m.start("configure") }
            .buttonStyle(PrimaryButton()).disabled(m.running)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        if m.category == .tests { testControls }
        GeometryReader { geometry in
          let width = max(280, min(inspectorDragWidth ?? CGFloat(inspectorWidth), min(500, geometry.size.width - 412)))
          HStack(spacing: 0) {
            targetList.frame(maxWidth: .infinity, maxHeight: .infinity).island()
            SplitHandle(title: L("Resize target details"), width: width, direction: -1, resize: { requestedWidth in
              inspectorDragWidth = max(280, min(requestedWidth, min(500, geometry.size.width - 412)))
            }, commit: {
              if let width = inspectorDragWidth { inspectorWidth = Double(width) }
              inspectorDragWidth = nil
            })
            TargetInspector().environmentObject(m).frame(width: width).island()
          }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .onChange(of: m.category) { _, _ in
        m.selectedArtifact = m.filtered.first?.name ?? ""
      }
  }
  private var targetList: some View {
    let targets = m.filtered
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Picker(L("Category"), selection: $m.category) {
          Text(L("Tools")).tag(ArtifactCategory.tools)
          Text(L("Libraries")).tag(ArtifactCategory.libraries)
          Text(L("Tests")).tag(ArtifactCategory.tests)
          Text(L("All")).tag(ArtifactCategory.all)
        }.pickerStyle(.segmented).frame(maxWidth: 215).labelsHidden().controlSize(.small)
        Button {
          m.favoritesOnly.toggle()
        } label: {
          Image(systemName: m.favoritesOnly ? "star.fill" : "star")
            .foregroundStyle(m.favoritesOnly ? Paint.accent : Paint.muted)
        }.buttonStyle(.plain).help(L("Show favorites only")).accessibilityLabel(
          L("Show favorites only"))
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(Paint.muted)
          TextField(L("Search targets…"), text: $m.search).textFieldStyle(.plain).focused(
            $searchFocused)
          if m.search.isEmpty { Text("⌘F").font(.system(size: 9)).foregroundStyle(Paint.muted) }
        }.font(.system(size: 12)).frame(width: 140)
      }.padding(.horizontal, 14).frame(height: 48)
      HStack {
        Text(L("Name / Purpose"))
        Spacer()
        Text(L("Output Status")).frame(width: 100, alignment: .leading)
        Text(L("Last task")).frame(width: 82, alignment: .trailing)
      }.font(.system(size: 10, weight: .medium)).foregroundStyle(Paint.muted)
        .padding(.horizontal, 15).padding(.vertical, 8)
      Divider().overlay(Paint.line)
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(targets) { a in artifactRow(a) }
        }.padding(.vertical, 4)
        if targets.isEmpty {
          Text(m.busy ? L("Loading targets…") : L("No matching targets"))
            .font(.system(size: 12)).foregroundStyle(Paint.muted).padding(24)
        }
      }
      Divider().overlay(Paint.line)
      HStack {
        Text(L("Showing %ld / %ld targets", targets.count, m.categoryArtifacts.count))
        Spacer()
        if m.running { Text(m.activityTitle).foregroundStyle(Paint.accent) }
      }.font(.system(size: 10)).foregroundStyle(Paint.muted)
        .padding(.horizontal, 14).frame(height: 28)
    }
  }
  private var environmentStrip: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(m.profile?.name ?? L("No environment selected"))
          .font(.system(size: 18, weight: .semibold)).lineLimit(1)
        if let p = m.profile {
          Text(
            ([modeName(p.mode)]
              + [p.projects.isEmpty ? "LLVM core" : p.projects.joined(separator: ", ")]
              + [p.backends.joined(separator: ", ")]).joined(separator: "  ·  ")
          )
          .font(.system(size: 11)).foregroundStyle(Paint.muted).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if m.profile != nil {
        if m.pending && m.configured {
          Button(m.running ? m.activityTitle : L("Apply Settings")) { m.start("configure") }
            .buttonStyle(PrimaryButton()).disabled(m.running)
        } else {
          Label(
            m.configured ? L("Configured") : L("Not configured"),
            systemImage: m.configured ? "checkmark" : "circle.dashed"
          )
          .font(.system(size: 11)).foregroundStyle(Paint.muted)
        }
        Button(L("Edit Environment…"), action: m.editEnvironment)
          .buttonStyle(QuietButton()).disabled(m.running)
      }
    }.padding(.bottom, 2)
  }
  private func artifactRow(_ a: Artifact) -> some View {
    Button {
      m.selectedArtifact = a.name
    } label: {
      HStack(spacing: 12) {
        Image(
          systemName: a.kind == "EXECUTABLE"
            ? "terminal" : a.name.hasPrefix("check-") ? "checkmark.square" : "shippingbox"
        ).font(.system(size: 14)).foregroundStyle(Paint.muted).frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 5) {
            Text(a.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            if m.favorites.contains(a.name) {
              Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Paint.accent)
            }
          }
          Text(L10n.coreText(a.description)).font(.system(size: 11)).foregroundStyle(Paint.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 10)
        TargetStatus(artifact: a).environmentObject(m).frame(width: 100, alignment: .leading)
        Text(m.records(for: a.name).first.map { relativeTime(taskDate($0)) } ?? "—")
          .font(.system(size: 10)).foregroundStyle(Paint.muted)
          .frame(width: 82, alignment: .trailing)
      }.padding(.horizontal, 10).padding(.vertical, 9).background(
        m.selectedArtifact == a.name ? Paint.selection.opacity(0.55) : Color.clear,
        in: RoundedRectangle(cornerRadius: 4)
      ).padding(.horizontal, 5).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  private var testControls: some View {
    HStack {
      TextField(L("Choose a regression test file or directory"), text: $m.testPath).textFieldStyle(
        .plain)
      Button(L("Choose…"), action: m.chooseTest).buttonStyle(QuietButton())
      Button(m.running ? m.activityTitle : L("Run Tests")) { m.start("test", test: m.testPath) }
        .buttonStyle(
          PrimaryButton()
        ).disabled(m.running || m.testPath.isEmpty || !m.configured || m.pending)
    }.font(.system(size: 12)).padding(10).background(Paint.panel)
      .overlay(Rectangle().stroke(Paint.line))
  }
  private var environmentPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(L("Environments")).font(.system(size: 20, weight: .semibold))
        Spacer()
        Button(L("New Environment")) { m.createEnvironment() }.buttonStyle(PrimaryButton())
      }
      Divider().overlay(Paint.line)
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(m.workspace?.profiles ?? []) { p in
            LocalizedContent { localization in
              VStack(alignment: .leading, spacing: 10) {
                HStack {
                  Circle().fill(m.profileId == p.id ? Paint.accent : Paint.line)
                    .frame(width: 6, height: 6)
                  Text(p.name).font(.system(size: 15, weight: .semibold))
                  Spacer()
                  Button(localization("Switch")) {
                    m.selectProfile(p.id)
                    m.page = .workbench
                  }.buttonStyle(QuietButton()).disabled(m.running)
                  Button(localization("Duplicate…")) { m.createEnvironment(copy: p) }.buttonStyle(
                    QuietButton()
                  ).disabled(m.running)
                  Button(localization("Edit…")) { m.editor = p }.buttonStyle(QuietButton())
                    .disabled(m.running)
                }
                Text(
                  localization(
                    "%@ · Compile jobs: %ld / Link jobs: 1", localization(modeKey(p.mode)), p.jobs)
                ).font(
                  .system(size: 12)
                )
                .foregroundStyle(Paint.muted)
                Text(localization("Linker: %@", p.linkerTitle))
                  .font(.system(size: 12)).textSelection(.enabled)
                Text(
                  localization(
                    "Projects: %@",
                    p.projects.isEmpty ? "LLVM core" : p.projects.joined(separator: " · "))
                )
                .font(.system(size: 12))
                Text(localization("Backends: %@", p.backends.joined(separator: " · "))).font(
                  .system(size: 12))
                if !p.runtimes.isEmpty {
                  Text(localization("Runtimes: %@", p.runtimes.joined(separator: " · "))).font(
                    .system(size: 12))
                }
                Text(localization("Build Directory")).font(
                  .system(size: 11)
                )
                .foregroundStyle(Paint.muted)
                Text(p.buildDir).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                  Paint.muted
                ).textSelection(.enabled)
              }.padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Paint.line).frame(height: 1) }
            }
          }
        }
      }
      if let file = m.workspace?.profilesFile {
        HStack {
          Text(L("Environment Settings File")).font(.system(size: 11))
          Spacer()
          Button {
            m.reveal(file)
          } label: {
            Label(L("Show in Finder"), systemImage: "folder")
          }.buttonStyle(.plain).font(.system(size: 11))
        }.foregroundStyle(Paint.muted).help(file)
      }
    }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var historyPage: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L("Build History")).font(.system(size: 20, weight: .semibold))
      Divider().overlay(Paint.line)
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(m.history) { record in
            LocalizedContent { localization in
              let date = Date(timeIntervalSince1970: Double(record.started) / 1000)
              let dateText = date.formatted(
                Date.FormatStyle(date: .abbreviated, time: .shortened).locale(localization.locale))
              let statusText = localization.translatedStatus(record.status)
              HStack(spacing: 14) {
                Image(
                  systemName: record.status == "succeeded"
                    ? "checkmark.circle"
                    : record.status == "failed" ? "exclamationmark.circle" : "clock"
                )
                .foregroundStyle(record.status == "failed" ? Paint.accent : Paint.muted)
                VStack(alignment: .leading, spacing: 5) {
                  Text(localization.translatedCoreText(record.title)).font(
                    .system(size: 13, weight: .medium))
                  Text(statusText + " · " + dateText)
                    .font(.system(size: 11)).foregroundStyle(Paint.muted)
                }
                Spacer()
                Button(localization("View Logs")) {
                  NSWorkspace.shared.open(URL(fileURLWithPath: record.logPath))
                }
                .buttonStyle(QuietButton())
              }
              .padding(.vertical, 14)
              .overlay(alignment: .bottom) { Rectangle().fill(Paint.line).frame(height: 1) }
            }
          }
        }
        if m.history.isEmpty {
          Text(L("No tasks yet.")).foregroundStyle(Paint.muted).padding(.top, 20)
        }
      }
    }
    .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var taskBar: some View {
    HStack(spacing: 9) {
      if m.running {
        ProgressView().controlSize(.mini)
      } else {
        Image(systemName: m.job?.status == "failed" ? "exclamationmark.circle" : "circle.fill")
          .font(.system(size: m.job?.status == "failed" ? 12 : 5))
          .foregroundStyle(m.job?.status == "failed" ? Paint.accent : Paint.muted)
      }
      Text(
        m.ideBusy
          ? L(m.idePhase) : m.job == nil && !m.running && !m.startFailed ? L("Ready") : m.taskPhase
      )
      .font(.system(size: 11)).lineLimit(1)
      if let p = m.profile {
        Text("·").foregroundStyle(Paint.line)
        Text(p.buildDir.replacingOccurrences(of: (m.workspace?.root ?? "") + "/", with: ""))
          .font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle).help(
            p.buildDir)
      }
      Spacer()
      if let generator = m.buildCache["CMAKE_GENERATOR"],
        let type = m.buildCache["CMAKE_BUILD_TYPE"]
      {
        Text(generator + " · " + type).font(.system(size: 10)).foregroundStyle(Paint.muted)
      }
      if m.running {
        Button(m.cancellationRequested ? L("Cancelling…") : L("Cancel"), action: m.cancel)
          .buttonStyle(.plain).font(.system(size: 11)).disabled(m.cancellationRequested)
      }
      Button {
        m.showLogs = true
      } label: {
        Label(L("View Logs"), systemImage: "text.alignleft")
      }.buttonStyle(.plain).font(.system(size: 11)).disabled(m.job == nil && !m.starting)
    }.foregroundStyle(Paint.muted).padding(.horizontal, 22).frame(height: 38)
      .background(Color.clear)
  }

}
func modeKey(_ mode: String) -> String {
  mode == "debug" ? "Debug" : mode == "release" ? "Release" : "Development · debug symbols"
}

func modeName(_ mode: String) -> String { L(modeKey(mode)) }

struct EnvironmentEditor: View {
  @EnvironmentObject var m: WorkspaceModel
  @ObservedObject private var language = LanguageSettings.shared
  @Environment(\.dismiss) var dismiss
  @State var profile: Profile
  @State var tab: ComponentTab = .projects
  @State var query = ""
  @State var prepare = true
  @State var advanced = false
  @State var proposedDirectory: String?
  @State var directoryPreviewFinished = false
  init(initial: Profile) { _profile = State(initialValue: initial) }
  private var linkerChoice: Binding<String> {
    Binding(
      get: { ["system", "lld"].contains(profile.linker) ? profile.linker : "custom" },
      set: { profile.linker = $0 == "custom" ? "" : $0 })
  }
  var choices: [String] {
    guard let c = m.workspace?.capabilities else { return [] }
    let all = tab == .projects ? c.projects : tab == .backends ? c.backends : c.runtimes
    return all.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
  }
  func binding(_ name: String) -> Binding<Bool> {
    Binding(
      get: {
        (tab == .projects
          ? profile.projects : tab == .backends ? profile.backends : profile.runtimes)
          .contains(name)
      },
      set: { on in
        if tab == .projects {
          profile.projects.removeAll { $0 == name }
          if on { profile.projects.append(name) }
        } else if tab == .backends {
          profile.backends.removeAll { $0 == name }
          if on { profile.backends.append(name) }
        } else {
          profile.runtimes.removeAll { $0 == name }
          if on { profile.runtimes.append(name) }
        }
      })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(profile.id.isEmpty ? L("New Environment") : L("Edit Environment"))
            .font(.system(size: 20, weight: .semibold))
        }
        Spacer()
      }
      HStack {
        TextField(L("Environment name"), text: $profile.name).textFieldStyle(.roundedBorder)
        Picker(L("Mode"), selection: $profile.mode) {
          Text(L("Development")).tag("dev")
          Text(L("Debug")).tag("debug")
          Text(L("Release")).tag("release")
        }.frame(width: 240)
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Picker(L("Linker"), selection: linkerChoice) {
            Text(L("System default")).tag("system")
            Text("LLD").tag("lld")
            Text(L("Custom path…")).tag("custom")
          }.frame(width: 280)
          if linkerChoice.wrappedValue == "custom" {
            TextField(L("Absolute linker path"), text: $profile.linker)
              .textFieldStyle(.roundedBorder)
          }
        }
        Text(L("LLD must be installed separately. Selecting the lld project only builds it."))
          .font(.system(size: 11)).foregroundStyle(Paint.muted)
      }
      HStack(alignment: .top, spacing: 24) {
        VStack(spacing: 13) {
          Picker(L("Component Type"), selection: $tab) {
            Text(L("Projects")).tag(ComponentTab.projects)
            Text(L("Backends")).tag(ComponentTab.backends)
            Text(L("Runtimes")).tag(ComponentTab.runtimes)
          }.pickerStyle(.segmented)
          TextField(L("Search available components"), text: $query).textFieldStyle(.roundedBorder)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(choices, id: \.self) { name in
                Toggle(isOn: binding(name)) {
                  Text(name).font(.system(size: 14, design: .monospaced))
                }.toggleStyle(.checkbox).padding(11).frame(maxWidth: .infinity, alignment: .leading)
                Divider().overlay(Paint.line)
              }
            }
          }
        }.frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 15) {
          Text(L("Configuration Summary")).font(.system(size: 16, weight: .semibold))
          summary(L("Projects"), profile.projects.isEmpty ? ["LLVM core"] : profile.projects)
          summary(L("Backends"), profile.backends)
          summary(L("Runtimes"), profile.runtimes)
          Divider()
          Text(
            L(
              "Development keeps debug symbols and assertions. Choose Debug for stepping through local variables."
            )
          ).font(.system(size: 12)).foregroundStyle(
            Paint.muted)
          if profile.runtimes.contains("libcxx") {
            Label(L("libc++ Test Environment"), systemImage: "testtube.2").font(
              .system(size: 13, weight: .medium))
            Text(
              L(
                "The compiler, ABI, and unwind runtimes are included. Runtime test dependencies are updated before testing."
              )
            ).font(.system(size: 12))
              .foregroundStyle(Paint.muted)
          }
          Spacer()
        }.frame(width: 245).padding(.leading, 18)
          .overlay(alignment: .leading) { Rectangle().fill(Paint.line).frame(width: 1) }
      }.frame(minHeight: 260)
      VStack(alignment: .leading, spacing: 5) {
        Text(L("Build Directory")).font(.system(size: 12, weight: .medium))
        Text(
          profile.id.isEmpty
            ? (proposedDirectory
              ?? L(
                directoryPreviewFinished ? "Directory assigned on save" : "Choosing a directory…"))
            : profile.buildDir
        )
        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        Text(
          L(
            "Only build files and outputs go here. Your settings are saved separately, so you can delete this directory and prepare again."
          )
        )
        .font(.system(size: 11)).foregroundStyle(Paint.muted)
      }
      DisclosureGroup(L("Toolchain & Parallelism"), isExpanded: $advanced) {
        VStack(alignment: .leading, spacing: 9) {
          HStack {
            Text(L("C compiler")).frame(width: 100, alignment: .leading)
            TextField(L("Automatic"), text: $profile.cc).textFieldStyle(.roundedBorder)
          }
          HStack {
            Text(L("C++ compiler")).frame(width: 100, alignment: .leading)
            TextField(L("Automatic"), text: $profile.cxx).textFieldStyle(.roundedBorder)
          }
          Stepper(
            L("Compile jobs: %ld · Link jobs: 1", profile.jobs), value: $profile.jobs, in: 1...64)
        }.font(.system(size: 12)).padding(.top, 8)
      }
      HStack {
        Toggle(L("Prepare after saving"), isOn: $prepare).font(.system(size: 12))
        Spacer()
        Button(L("Cancel")) { dismiss() }.buttonStyle(QuietButton())
        Button(m.saving ? L("Saving…") : L("Save Environment")) {
          Task { await m.save(profile, prepare: prepare) }
        }
        .buttonStyle(PrimaryButton()).disabled(
          m.saving || profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }.padding(28).frame(width: 840, height: advanced ? 855 : 750).background(Paint.canvas)
      .foregroundStyle(Paint.ink).tint(Paint.accent)
      .task(id: profile.name) {
        guard profile.id.isEmpty, let root = m.workspace?.root,
          let value = try? Core.encode(profile)
        else { return }
        let preview: Profile? = try? await Core.call([
          "action": "preview_profile", "root": root, "profile": value,
        ])
        if !Task.isCancelled {
          proposedDirectory = preview?.buildDir
          directoryPreviewFinished = true
        }
      }
  }
  private func summary(_ title: String, _ values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 11)).foregroundStyle(Paint.muted)
      Text(values.isEmpty ? L("Not enabled") : values.joined(separator: " · ")).font(
        .system(size: 12)
      )
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}
struct RunSheet: View {
  @EnvironmentObject var m: WorkspaceModel
  @ObservedObject private var language = LanguageSettings.shared
  @Environment(\.dismiss) var dismiss
  let artifact: Artifact
  @State var arguments = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(L("Run %@", artifact.name)).font(.system(size: 20, weight: .semibold))
      Text(
        L(
          "Build incrementally, then run. Enter one argument per line; spaces within an argument are preserved."
        )
      ).font(.system(size: 13)).foregroundStyle(Paint.muted)
      TextEditor(text: $arguments).font(.system(size: 13, design: .monospaced)).frame(height: 210)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Paint.line))
      HStack {
        Button(L("Add Input File…")) {
          let p = NSOpenPanel()
          if p.runModal() == .OK, let url = p.url {
            arguments += (arguments.isEmpty ? "" : "\n") + url.path
          }
        }.buttonStyle(QuietButton())
        Spacer()
        Button(L("Cancel")) { dismiss() }.buttonStyle(QuietButton())
        Button(L("Build & Run")) {
          let values = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
          dismiss()
          m.start("run", target: artifact.name, arguments: values)
        }.buttonStyle(PrimaryButton())
      }
    }.padding(28).frame(width: 640).background(Paint.canvas)
  }
}
struct LogSheet: View {
  @EnvironmentObject var m: WorkspaceModel
  @ObservedObject private var language = LanguageSettings.shared
  @Environment(\.dismiss) var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text(L("Task Logs")).font(.system(size: 20, weight: .semibold))
        Text(m.taskPhase).foregroundStyle(Paint.muted)
        Spacer()
        if m.running {
          Button(m.cancellationRequested ? L("Cancelling…") : L("Cancel Task"), action: m.cancel)
            .buttonStyle(
              QuietButton()
            ).disabled(m.cancellationRequested)
        }
        Button(L("Close")) { dismiss() }.buttonStyle(QuietButton())
      }
      ScrollView {
        Text(
          m.job?.lines.joined(separator: "\n")
            ?? (m.starting ? L("Reading settings and starting the task…") : L("No logs yet"))
        ).font(
          .system(size: 11, design: .monospaced)
        ).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(15)
      }.frame(height: 490).background(Color(hex: 0xF0EDE7), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Text(L("Showing the latest 500 lines. Complete logs are saved locally.")).font(
          .system(size: 11)
        ).foregroundStyle(Paint.muted)
        Spacer()
        if let path = m.job?.logPath {
          Button(L("Show Complete Log")) { m.reveal(path) }.buttonStyle(QuietButton())
        }
      }
    }.padding(25).frame(width: 950).background(Paint.canvas).foregroundStyle(Paint.ink)
  }
}
