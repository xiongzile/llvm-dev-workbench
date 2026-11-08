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
    ink = Color(hex: 0x2C2925), muted = Color(hex: 0x8A8277)
  static let accent = Color(hex: 0xB96949), selection = Color(hex: 0xEFDFD3),
    line = Color(hex: 0xDED7CC), panel = Color(hex: 0xFBF9F5)
}
struct PrimaryButton: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 14, weight: .semibold)).padding(.horizontal, 18).padding(
      .vertical, 10
    ).frame(minHeight: 18).foregroundStyle(isEnabled ? Color.white : Paint.muted).background(
      isEnabled
        ? Paint.accent.opacity(configuration.isPressed ? 0.75 : 1) : Paint.line.opacity(0.65),
      in: RoundedRectangle(cornerRadius: 8)
    ).contentShape(Rectangle())
  }
}
struct QuietButton: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, 8)
      .foregroundStyle(isEnabled ? Paint.ink : Paint.muted).background(
        !isEnabled
          ? Paint.line.opacity(0.3) : configuration.isPressed ? Paint.selection : Paint.panel,
        in: RoundedRectangle(cornerRadius: 7)
      ).overlay(RoundedRectangle(cornerRadius: 7).stroke(Paint.line, lineWidth: 1)).contentShape(
        Rectangle())
  }
}
struct WorkbenchView: View {
  @EnvironmentObject var m: WorkspaceModel
  @ObservedObject private var language = LanguageSettings.shared
  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 240)
      VStack(spacing: 0) {
        toolbar
        if m.workspace == nil {
          welcome
        } else if m.page == .environments {
          environmentPage
        } else if m.page == .history {
          historyPage
        } else {
          workspacePage
        }
        taskBar
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Paint.canvas)
    }.foregroundStyle(Paint.ink).tint(Paint.accent)
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
      .sheet(isPresented: $m.showLogs) { LogSheet().environmentObject(m) }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer().frame(height: 50)
      HStack(spacing: 10) {
        Text("W").font(.custom("Georgia", size: 27)).foregroundStyle(Paint.accent)
        Text("LLVM Workbench").font(.custom("Georgia", size: 17))
      }.padding(.horizontal, 22)
      Divider().overlay(Paint.line).padding(.vertical, 25).padding(.horizontal, 18)
      Text(L("Workspace")).font(.system(size: 11, weight: .medium)).foregroundStyle(Paint.muted)
        .padding(
          .horizontal, 22)
      Button(action: m.openPanel) {
        HStack {
          Image(systemName: "folder")
          Text(m.workspace?.name ?? L("Open LLVM Source")).lineLimit(1)
          Spacer()
          Image(systemName: "chevron.down").font(.system(size: 10))
        }.padding(11).frame(maxWidth: .infinity).background(
          Color.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)
        ).overlay(RoundedRectangle(cornerRadius: 8).stroke(Paint.line)).contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.horizontal, 15).padding(.top, 9).help(
        L("Open another LLVM workspace"))
      VStack(spacing: 4) {
        nav(.workbench, "house")
        nav(.environments, "square.stack.3d.up")
        nav(.artifacts, "shippingbox")
        nav(.tests, "testtube.2")
        nav(.history, "clock.arrow.circlepath")
      }.padding(.horizontal, 14).padding(.top, 23)
      Divider().overlay(Paint.line).padding(.horizontal, 20).padding(.vertical, 24)
      Text(L("Build Environments")).font(.system(size: 11, weight: .medium)).foregroundStyle(
        Paint.muted
      ).padding(
        .horizontal, 22)
      ScrollView {
        VStack(spacing: 5) {
          ForEach(m.workspace?.profiles ?? []) { p in
            Button {
              m.selectProfile(p.id)
            } label: {
              HStack(alignment: .top, spacing: 9) {
                Image(systemName: m.profileId == p.id ? "checkmark.circle.fill" : "circle")
                  .foregroundStyle(m.profileId == p.id ? Paint.accent : Paint.muted)
                VStack(alignment: .leading, spacing: 3) {
                  Text(p.name).font(.system(size: 13)).lineLimit(2)
                }
                Spacer(minLength: 0)
              }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(
                m.profileId == p.id ? Paint.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
              ).contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }.padding(.horizontal, 14)
      }.padding(.top, 10)
      Button {
        m.createEnvironment()
      } label: {
        Label(L("New Environment"), systemImage: "plus").font(.system(size: 13))
      }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 16).disabled(
        m.workspace == nil)
      HStack(spacing: 8) {
        Image(systemName: "globe").font(.system(size: 12))
        Menu {
          LanguagePicker()
        } label: {
          Text(L("Language")).font(.system(size: 11))
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L("Language"))
        Spacer()
      }.foregroundStyle(Paint.muted).padding(20)
    }.frame(maxHeight: .infinity).background(Paint.sidebar)
  }
  private func nav(_ page: WorkbenchPage, _ icon: String) -> some View {
    Button {
      m.page = page
      m.search = ""
      if page == .history { Task { await m.refreshHistory() } }
    } label: {
      HStack(spacing: 13) {
        Image(systemName: icon).frame(width: 20)
        Text(page.title).font(.system(size: 15))
        Spacer()
      }.frame(maxWidth: .infinity).padding(.horizontal, 14).padding(.vertical, 11).background(
        m.page == page ? Paint.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8)
      ).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  private var toolbar: some View {
    HStack(spacing: 14) {
      Image(systemName: "folder")
      Text(m.workspace?.name ?? "LLVM Workbench").font(.system(size: 14, weight: .medium))
      Text("/").foregroundStyle(Paint.line)
      Menu {
        ForEach(m.workspace?.profiles ?? []) { p in Button(p.name) { m.selectProfile(p.id) } }
      } label: {
        Text(m.profile?.name ?? L("Choose an environment")).lineLimit(1)
      }.menuStyle(.borderlessButton).fixedSize()
      Spacer()
      if m.busy { ProgressView().controlSize(.small) }
      Button {
        if let root = m.workspace?.root { Task { await m.open(root) } }
      } label: {
        Image(systemName: "arrow.clockwise")
      }.buttonStyle(.plain).help(L("Refresh environments and artifacts"))
      Button(action: m.openPanel) { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain)
        .help(L("Open Workspace"))
    }.padding(.horizontal, 30).frame(height: 56).overlay(alignment: .bottom) {
      Rectangle().fill(Paint.line).frame(height: 1)
    }
  }
  private var welcome: some View {
    VStack(spacing: 22) {
      Image(systemName: "hammer").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(
        Paint.accent)
      Text(L("Start with your LLVM.")).font(
        .custom(L10n.current.language == "zh-Hans" ? "Songti SC" : "Georgia", size: 36))
      Text(L("Open a source checkout, choose projects and backends, and build the tools you need."))
        .foregroundStyle(Paint.muted)
      Button(L("Open LLVM Workspace…"), action: m.openPanel).buttonStyle(PrimaryButton())
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var workspacePage: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(
            m.page == .tests
              ? L("Regression Tests")
              : m.page == .artifacts ? L("Tools & Artifacts") : L("Your Workbench")
          ).font(
            .custom(L10n.current.language == "zh-Hans" ? "Songti SC" : "Georgia", size: 36))
          Text(
            m.page == .tests
              ? L("Select a test file or directory, or build a check target.")
              : L("The tools you need for the work at hand.")
          ).font(
            .system(size: 14)
          ).foregroundStyle(Paint.muted)
        }
        Spacer()
        Button(L("Edit Environment…"), action: m.editEnvironment).buttonStyle(QuietButton())
          .disabled(m.running)
      }
      environmentStrip
      if m.page == .tests { testControls }
      if m.profile == nil {
        VStack(spacing: 16) {
          Text(L("No build environments yet")).font(.system(size: 20))
          Text(L("Choose any combination of components from this checkout.")).foregroundStyle(
            Paint.muted)
          Button(L("Create Your First Environment")) { m.createEnvironment() }.buttonStyle(
            PrimaryButton())
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !m.configured {
        VStack(spacing: 16) {
          Image(systemName: "slider.horizontal.3").font(.system(size: 32, weight: .light))
            .foregroundStyle(Paint.accent)
          Text(L("Environment saved. Ready to prepare.")).font(.system(size: 20))
          Text(
            L(
              "Your settings are saved. Prepare the environment to create or regenerate its build files."
            )
          ).foregroundStyle(Paint.muted)
          Button(m.running ? m.activityTitle : L("Prepare Environment")) { m.start("configure") }
            .buttonStyle(
              PrimaryButton()
            )
            .disabled(m.running)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              if m.page != .tests {
                Picker(L("Category"), selection: $m.category) {
                  Text(L("Tools")).tag(ArtifactCategory.tools)
                  Text(L("Libraries")).tag(ArtifactCategory.libraries)
                  Text(L("Tests")).tag(ArtifactCategory.tests)
                  Text(L("All")).tag(ArtifactCategory.all)
                }.pickerStyle(.segmented).frame(maxWidth: 330).labelsHidden()
              }
              Spacer()
              Image(systemName: "magnifyingglass").foregroundStyle(Paint.muted)
              TextField(L("Search targets…"), text: $m.search).textFieldStyle(.plain).frame(
                width: 150)
            }.padding(16)
            HStack {
              Text(L("Name / Purpose"))
              Spacer()
              Text(L("Output Status"))
            }.font(.system(size: 11)).foregroundStyle(Paint.muted).padding(.horizontal, 18).padding(
              .vertical, 10)
            Divider().overlay(Paint.line)
            ScrollView {
              LazyVStack(spacing: 0) { ForEach(m.filtered) { a in artifactRow(a) } }.padding(
                .vertical, 4)
              if m.filtered.isEmpty {
                Text(m.busy ? L("Loading targets…") : L("No matching targets")).foregroundStyle(
                  Paint.muted
                ).padding(30)
              }
            }
            HStack {
              Text(L("Targets: %ld", m.filtered.count))
              Spacer()
              Text(L("From the current build configuration"))
            }.font(.system(size: 10)).foregroundStyle(Paint.muted).padding(12)
          }.background(Paint.panel, in: RoundedRectangle(cornerRadius: 13)).overlay(
            RoundedRectangle(cornerRadius: 13).stroke(Paint.line))
          inspector.frame(width: 275)
        }
      }
    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var environmentStrip: some View {
    HStack(spacing: 14) {
      Image(systemName: "square.stack.3d.up").foregroundStyle(Paint.accent)
      Text(m.profile?.name ?? L("No environment selected")).font(
        .system(size: 15, weight: .semibold)
      ).lineLimit(1)
      Rectangle().fill(Paint.line).frame(width: 1, height: 22)
      Text(modeName(m.profile?.mode ?? "dev")).font(.system(size: 12))
      if let p = m.profile {
        Text(L("Projects: %ld · Backends: %ld", p.projects.count, p.backends.count)).font(
          .system(size: 12)
        )
        .foregroundStyle(Paint.muted)
      }
      Spacer()
      if m.pending && m.configured {
        Button(m.running ? m.activityTitle : L("Apply Settings")) { m.start("configure") }
          .buttonStyle(
            QuietButton()
          ).disabled(
            m.running)
      } else {
        Label(
          m.configured ? L("Configured") : L("Not configured"),
          systemImage: m.configured ? "checkmark.circle" : "circle.dashed"
        ).font(.system(size: 12)).foregroundStyle(Paint.muted)
      }
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(
      Paint.panel, in: RoundedRectangle(cornerRadius: 11)
    ).overlay(RoundedRectangle(cornerRadius: 11).stroke(Paint.line))
  }
  private func artifactRow(_ a: Artifact) -> some View {
    Button {
      m.selectedArtifact = a.name
    } label: {
      HStack(spacing: 12) {
        Image(
          systemName: a.kind == "EXECUTABLE"
            ? "terminal" : a.name.hasPrefix("check-") ? "checkmark.square" : "shippingbox"
        ).font(.system(size: 18, weight: .light)).frame(width: 25)
        VStack(alignment: .leading, spacing: 4) {
          Text(a.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
          Text(L10n.coreText(a.description)).font(.system(size: 11)).foregroundStyle(Paint.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 10)
        Text(a.paths.isEmpty ? L("Build target") : a.present ? L("Built") : L("Not built")).font(
          .system(size: 11)
        )
        .foregroundStyle(Paint.muted)
        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Paint.muted)
      }.padding(.horizontal, 14).padding(.vertical, 14).background(
        m.selectedArtifact == a.name ? Paint.selection.opacity(0.55) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      ).overlay(alignment: .leading) {
        if m.selectedArtifact == a.name {
          RoundedRectangle(cornerRadius: 2).fill(Paint.accent).frame(width: 3)
        }
      }.padding(.horizontal, 8).contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
  private var inspector: some View {
    VStack(alignment: .leading, spacing: 19) {
      if let a = m.selected {
        HStack {
          Image(systemName: "gearshape").font(.system(size: 24, weight: .light))
          Text(a.name).font(.custom("Georgia", size: 24)).lineLimit(2)
        }
        Divider().overlay(Paint.line)
        Text(L10n.coreText(a.description)).font(.system(size: 13)).fixedSize(
          horizontal: false, vertical: true)
        if let path = a.paths.first {
          VStack(alignment: .leading, spacing: 6) {
            Text(L("Output File")).font(.system(size: 11)).foregroundStyle(Paint.muted)
            Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .lineLimit(4)
          }
          Text(
            a.present
              ? L("This output exists. Running it checks and updates the build first.")
              : L("This target has not produced an output yet.")
          ).font(.system(size: 12))
            .foregroundStyle(Paint.muted)
        }
        Button {
          m.start("build", targets: [a.name])
        } label: {
          HStack {
            if m.running { ProgressView().controlSize(.small) }
            Label(m.running ? m.activityTitle : L("Build %@", a.name), systemImage: "hammer")
          }.frame(maxWidth: .infinity)
        }.buttonStyle(PrimaryButton()).disabled(m.running || m.pending)
        if a.kind == "EXECUTABLE" {
          Button {
            m.runArtifact = a
          } label: {
            Label(L("Run…"), systemImage: "play").frame(maxWidth: .infinity)
          }.buttonStyle(QuietButton()).disabled(m.running || m.pending)
        }
        if a.present, let path = a.paths.first {
          Button {
            m.reveal(path)
          } label: {
            Label(L("Show in Finder"), systemImage: "folder")
          }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Paint.accent)
        }
        Divider().overlay(Paint.line)
        Button(action: m.openIDE) {
          Label(L("Open Source in IDE…"), systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Paint.muted)
      } else {
        Text(L("Select a target")).font(.system(size: 16))
        Text(L("See its output paths and available actions.")).font(.system(size: 13))
          .foregroundStyle(Paint.muted)
      }
      Spacer(minLength: 0)
    }.padding(20).frame(maxHeight: .infinity, alignment: .topLeading).background(
      Paint.panel, in: RoundedRectangle(cornerRadius: 13)
    ).overlay(RoundedRectangle(cornerRadius: 13).stroke(Paint.line))
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
    }.padding(13).background(Paint.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(
      RoundedRectangle(cornerRadius: 9).stroke(Paint.line))
  }
  private var environmentPage: some View {
    VStack(alignment: .leading, spacing: 23) {
      HStack {
        Text(L("Environments")).font(
          .custom(L10n.current.language == "zh-Hans" ? "Songti SC" : "Georgia", size: 36))
        Spacer()
        Button(L("New Environment")) { m.createEnvironment() }.buttonStyle(PrimaryButton())
      }
      Text(
        L(
          "Settings are saved in the app folder; outputs live in the checkout’s build folder. Cleaning outputs keeps your environments."
        )
      )
      .font(.system(size: 13)).foregroundStyle(Paint.muted)
      if let file = m.workspace?.profilesFile {
        HStack {
          Text(L("Environment Settings File")).font(.system(size: 11))
          Text(file).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }.foregroundStyle(Paint.muted)
      }
      ScrollView {
        VStack(spacing: 14) {
          ForEach(m.workspace?.profiles ?? []) { p in
            LocalizedContent { localization in
              VStack(alignment: .leading, spacing: 12) {
                HStack {
                  Text(p.name).font(.system(size: 19, weight: .semibold))
                  Spacer()
                  Button(localization("Switch")) {
                    m.selectProfile(p.id)
                    m.page = .workbench
                  }.buttonStyle(QuietButton())
                  Button(localization("Duplicate…")) { m.createEnvironment(copy: p) }.buttonStyle(
                    QuietButton())
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
                Text(localization("Build directory · safe to clean and prepare again")).font(
                  .system(size: 11)
                )
                .foregroundStyle(Paint.muted)
                Text(p.buildDir).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                  Paint.muted
                ).textSelection(.enabled)
              }.padding(20).background(Paint.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(
                RoundedRectangle(cornerRadius: 12).stroke(Paint.line))
            }
          }
        }
      }
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var historyPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(L("Build History")).font(
        .custom(L10n.current.language == "zh-Hans" ? "Songti SC" : "Georgia", size: 36))
      Text(L("Review past tasks, their results, and complete logs."))
        .font(.system(size: 13)).foregroundStyle(Paint.muted)
      ScrollView {
        LazyVStack(spacing: 12) {
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
                    .system(size: 15, weight: .medium))
                  Text(statusText + " · " + dateText)
                  .font(.system(size: 11)).foregroundStyle(Paint.muted)
                }
                Spacer()
                Button(localization("View Logs")) {
                  NSWorkspace.shared.open(URL(fileURLWithPath: record.logPath))
                }
                .buttonStyle(QuietButton())
              }
              .padding(17).background(Paint.panel, in: RoundedRectangle(cornerRadius: 9))
              .overlay(RoundedRectangle(cornerRadius: 9).stroke(Paint.line))
            }
          }
        }
        if m.history.isEmpty {
          Text(L("No tasks yet.")).foregroundStyle(Paint.muted).padding(.top, 20)
        }
      }
    }
    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var taskBar: some View {
    HStack(spacing: 14) {
      if m.running {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: m.job?.status == "failed" ? "exclamationmark.circle" : "checkmark.circle")
          .foregroundStyle(Paint.muted)
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(m.taskPhase).font(.system(size: 13, weight: .medium))
        Text(
          m.running
            ? L("A local task is running. See the logs for details.")
            : m.job?.status == "failed"
              ? L("The task failed. Complete logs are available for troubleshooting.")
              : L("Build selected targets. Running a tool updates its build first.")
        ).font(.system(size: 11)).foregroundStyle(Paint.muted)
      }
      Spacer()
      if m.running {
        Button(m.cancellationRequested ? L("Cancelling…") : L("Cancel"), action: m.cancel)
          .buttonStyle(QuietButton())
          .disabled(m.cancellationRequested)
      }
      Button(L("View Logs")) { m.showLogs = true }.buttonStyle(QuietButton()).disabled(
        m.job == nil && !m.starting)
    }.padding(.horizontal, 22).padding(.vertical, 17).background(Paint.panel).overlay(
      alignment: .top
    ) { Rectangle().fill(Paint.line).frame(height: 1) }
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
          Text(profile.id.isEmpty ? L("New Environment") : L("Edit Environment")).font(
            .custom(L10n.current.language == "zh-Hans" ? "Songti SC" : "Georgia", size: 28))
          Text(L("Combine the components available in this LLVM checkout.")).font(.system(size: 12))
            .foregroundStyle(Paint.muted)
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
        }.frame(width: 265).padding(18).background(
          Paint.panel, in: RoundedRectangle(cornerRadius: 10))
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
    }.padding(28).frame(width: 840, height: advanced ? 800 : 695).background(Paint.canvas)
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
      Text(L("Run %@", artifact.name)).font(.custom("Georgia", size: 25))
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
        Text(L("Task Logs")).font(
          .custom(L10n.current.language == "zh-Hans" ? "Songti SC" : "Georgia", size: 25))
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
