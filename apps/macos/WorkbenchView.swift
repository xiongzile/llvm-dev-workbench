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
  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 225)
      VStack(spacing: 0) {
        toolbar
        if m.workspace == nil {
          welcome
        } else if m.page == "环境" {
          environmentPage
        } else if m.page == "历史" {
          historyPage
        } else {
          workspacePage
        }
        taskBar
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Paint.canvas)
    }.foregroundStyle(Paint.ink).tint(Paint.accent)
      .alert(
        "操作未完成", isPresented: Binding(get: { m.error != nil }, set: { if !$0 { m.error = nil } })
      ) {
        Button("知道了") { m.error = nil }
      } message: {
        Text(m.error ?? "")
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
      Text("工作区").font(.system(size: 11, weight: .medium)).foregroundStyle(Paint.muted).padding(
        .horizontal, 22)
      Button(action: m.openPanel) {
        HStack {
          Image(systemName: "folder")
          Text(m.workspace?.name ?? "打开 LLVM 源码").lineLimit(1)
          Spacer()
          Image(systemName: "chevron.down").font(.system(size: 10))
        }.padding(11).frame(maxWidth: .infinity).background(
          Color.white.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)
        ).overlay(RoundedRectangle(cornerRadius: 8).stroke(Paint.line)).contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.horizontal, 15).padding(.top, 9).help("打开其他 LLVM 工作区")
      VStack(spacing: 4) {
        nav("工作台", "house")
        nav("环境", "square.stack.3d.up")
        nav("产物", "shippingbox")
        nav("测试", "testtube.2")
        nav("历史", "clock.arrow.circlepath")
      }.padding(.horizontal, 14).padding(.top, 23)
      Divider().overlay(Paint.line).padding(.horizontal, 20).padding(.vertical, 24)
      Text("构建环境").font(.system(size: 11, weight: .medium)).foregroundStyle(Paint.muted).padding(
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
        Label("新建环境", systemImage: "plus").font(.system(size: 13))
      }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 16).disabled(
        m.workspace == nil)
      HStack(spacing: 8) {
        Image(systemName: "link").font(.system(size: 12))
        Text("本地工作区").font(.system(size: 11))
        Spacer()
      }.foregroundStyle(Paint.muted).padding(20)
    }.frame(maxHeight: .infinity).background(Paint.sidebar)
  }
  private func nav(_ title: String, _ icon: String) -> some View {
    Button {
      m.page = title
      m.search = ""
      if title == "历史" { Task { await m.refreshHistory() } }
    } label: {
      HStack(spacing: 13) {
        Image(systemName: icon).frame(width: 20)
        Text(title).font(.system(size: 15))
        Spacer()
      }.frame(maxWidth: .infinity).padding(.horizontal, 14).padding(.vertical, 11).background(
        m.page == title ? Paint.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8)
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
        Text(m.profile?.name ?? "选择环境").lineLimit(1)
      }.menuStyle(.borderlessButton).fixedSize()
      Spacer()
      if m.busy { ProgressView().controlSize(.small) }
      Button {
        if let root = m.workspace?.root { Task { await m.open(root) } }
      } label: {
        Image(systemName: "arrow.clockwise")
      }.buttonStyle(.plain).help("重新读取环境与产物")
      Button(action: m.openPanel) { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain)
        .help("打开工作区")
    }.padding(.horizontal, 30).frame(height: 56).overlay(alignment: .bottom) {
      Rectangle().fill(Paint.line).frame(height: 1)
    }
  }
  private var welcome: some View {
    VStack(spacing: 22) {
      Image(systemName: "hammer").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(
        Paint.accent)
      Text("从你的 LLVM 开始。").font(.custom("Songti SC", size: 36))
      Text("打开源码仓库，选择项目与后端，构建当前需要的工具。").foregroundStyle(Paint.muted)
      Button("打开 LLVM 工作区…", action: m.openPanel).buttonStyle(PrimaryButton())
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private var workspacePage: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(m.page == "测试" ? "回归测试" : m.page == "产物" ? "工具与产物" : "开发工作台").font(
            .custom("Songti SC", size: 36))
          Text(m.page == "测试" ? "选择测试文件、目录，或构建对应的 check 目标。" : "为当前工作，准备恰好的工具。").font(
            .system(size: 14)
          ).foregroundStyle(Paint.muted)
        }
        Spacer()
        Button("编辑环境…", action: m.editEnvironment).buttonStyle(QuietButton()).disabled(m.running)
      }
      environmentStrip
      if m.page == "测试" { testControls }
      if m.profile == nil {
        VStack(spacing: 16) {
          Text("还没有构建环境").font(.system(size: 20))
          Text("所有组件来自当前 checkout，可自由组合。").foregroundStyle(Paint.muted)
          Button("创建第一个环境") { m.createEnvironment() }.buttonStyle(PrimaryButton())
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !m.configured {
        VStack(spacing: 16) {
          Image(systemName: "slider.horizontal.3").font(.system(size: 32, weight: .light))
            .foregroundStyle(Paint.accent)
          Text("环境已保存，构建目录待准备").font(.system(size: 20))
          Text("配置保存在应用目录。首次使用或清理构建目录后，点击准备即可重新生成构建文件。").foregroundStyle(Paint.muted)
          Button(m.running ? m.activityTitle : "准备环境") { m.start("configure") }.buttonStyle(
            PrimaryButton()
          )
          .disabled(m.running)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              if m.page != "测试" {
                Picker("分类", selection: $m.category) {
                  ForEach(["工具", "库", "测试", "全部"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 280).labelsHidden()
              }
              Spacer()
              Image(systemName: "magnifyingglass").foregroundStyle(Paint.muted)
              TextField("搜索目标…", text: $m.search).textFieldStyle(.plain).frame(width: 150)
            }.padding(16)
            HStack {
              Text("名称 / 用途")
              Spacer()
              Text("产物状态")
            }.font(.system(size: 11)).foregroundStyle(Paint.muted).padding(.horizontal, 18).padding(
              .vertical, 10)
            Divider().overlay(Paint.line)
            ScrollView {
              LazyVStack(spacing: 0) { ForEach(m.filtered) { a in artifactRow(a) } }.padding(
                .vertical, 4)
              if m.filtered.isEmpty {
                Text(m.busy ? "正在读取构建模型…" : "没有匹配的目标").foregroundStyle(Paint.muted).padding(30)
              }
            }
            HStack {
              Text("\(m.filtered.count) 个目标")
              Spacer()
              Text("来自当前构建配置")
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
      Text(m.profile?.name ?? "尚未选择环境").font(.system(size: 15, weight: .semibold)).lineLimit(1)
      Rectangle().fill(Paint.line).frame(width: 1, height: 22)
      Text(modeName(m.profile?.mode ?? "dev")).font(.system(size: 12))
      if let p = m.profile {
        Text("\(p.projects.count) 个项目 · \(p.backends.count) 个后端").font(.system(size: 12))
          .foregroundStyle(Paint.muted)
      }
      Spacer()
      if m.pending && m.configured {
        Button(m.running ? m.activityTitle : "应用配置") { m.start("configure") }.buttonStyle(
          QuietButton()
        ).disabled(
          m.running)
      } else {
        Label(
          m.configured ? "配置已就绪" : "尚未配置",
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
          Text(a.description).font(.system(size: 11)).foregroundStyle(Paint.muted).lineLimit(1)
        }
        Spacer(minLength: 10)
        Text(a.paths.isEmpty ? "构建目标" : a.present ? "已生成" : "未构建").font(.system(size: 11))
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
        Text(a.description).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        if let path = a.paths.first {
          VStack(alignment: .leading, spacing: 6) {
            Text("输出文件").font(.system(size: 11)).foregroundStyle(Paint.muted)
            Text(path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
              .lineLimit(4)
          }
          Text(a.present ? "文件已生成，运行前会先检查并更新构建。" : "此目标尚未生成产物。").font(.system(size: 12))
            .foregroundStyle(Paint.muted)
        }
        Button {
          m.start("build", targets: [a.name])
        } label: {
          HStack {
            if m.running { ProgressView().controlSize(.small) }
            Label(m.running ? m.activityTitle : "构建 \(a.name)", systemImage: "hammer")
          }.frame(maxWidth: .infinity)
        }.buttonStyle(PrimaryButton()).disabled(m.running || m.pending)
        if a.kind == "EXECUTABLE" {
          Button {
            m.runArtifact = a
          } label: {
            Label("运行…", systemImage: "play").frame(maxWidth: .infinity)
          }.buttonStyle(QuietButton()).disabled(m.running || m.pending)
        }
        if a.present, let path = a.paths.first {
          Button {
            m.reveal(path)
          } label: {
            Label("在 Finder 中显示", systemImage: "folder")
          }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Paint.accent)
        }
        Divider().overlay(Paint.line)
        Button(action: m.openIDE) { Label("在 IDE 中打开源码…", systemImage: "arrow.up.right.square") }
          .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Paint.muted)
      } else {
        Text("选择一个目标").font(.system(size: 16))
        Text("查看产物路径及可执行操作。").font(.system(size: 13)).foregroundStyle(Paint.muted)
      }
      Spacer(minLength: 0)
    }.padding(20).frame(maxHeight: .infinity, alignment: .topLeading).background(
      Paint.panel, in: RoundedRectangle(cornerRadius: 13)
    ).overlay(RoundedRectangle(cornerRadius: 13).stroke(Paint.line))
  }
  private var testControls: some View {
    HStack {
      TextField("选择回归测试文件或目录", text: $m.testPath).textFieldStyle(.plain)
      Button("选择…", action: m.chooseTest).buttonStyle(QuietButton())
      Button(m.running ? m.activityTitle : "运行测试") { m.start("test", test: m.testPath) }
        .buttonStyle(
          PrimaryButton()
        ).disabled(m.running || m.testPath.isEmpty || !m.configured || m.pending)
    }.padding(13).background(Paint.panel, in: RoundedRectangle(cornerRadius: 9)).overlay(
      RoundedRectangle(cornerRadius: 9).stroke(Paint.line))
  }
  private var environmentPage: some View {
    VStack(alignment: .leading, spacing: 23) {
      HStack {
        Text("开发环境").font(.custom("Songti SC", size: 36))
        Spacer()
        Button("新建环境") { m.createEnvironment() }.buttonStyle(PrimaryButton())
      }
      Text("配置保存在应用目录，构建产物保存在源码仓库的 build 目录。清理产物后环境仍会保留。")
        .font(.system(size: 13)).foregroundStyle(Paint.muted)
      if let file = m.workspace?.profilesFile {
        HStack {
          Text("环境配置文件").font(.system(size: 11))
          Text(file).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
        }.foregroundStyle(Paint.muted)
      }
      ScrollView {
        VStack(spacing: 14) {
          ForEach(m.workspace?.profiles ?? []) { p in
            VStack(alignment: .leading, spacing: 12) {
              HStack {
                Text(p.name).font(.system(size: 19, weight: .semibold))
                Spacer()
                Button("切换") {
                  m.selectProfile(p.id)
                  m.page = "工作台"
                }.buttonStyle(QuietButton())
                Button("复制…") { m.createEnvironment(copy: p) }.buttonStyle(QuietButton())
                Button("编辑…") { m.editor = p }.buttonStyle(QuietButton()).disabled(m.running)
              }
              Text("\(modeName(p.mode)) · \(p.jobs) 个编译任务 / 1 个链接任务").font(.system(size: 12))
                .foregroundStyle(Paint.muted)
              Text("项目  \(p.projects.isEmpty ? "LLVM core":p.projects.joined(separator:" · "))")
                .font(.system(size: 12))
              Text("后端  \(p.backends.joined(separator:" · "))").font(.system(size: 12))
              if !p.runtimes.isEmpty {
                Text("Runtime  \(p.runtimes.joined(separator:" · "))").font(.system(size: 12))
              }
              Text("构建目录 · 可清理后重新准备").font(.system(size: 11)).foregroundStyle(Paint.muted)
              Text(p.buildDir).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                Paint.muted
              ).textSelection(.enabled)
            }.padding(20).background(Paint.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(
              RoundedRectangle(cornerRadius: 12).stroke(Paint.line))
          }
        }
      }
    }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var historyPage: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("构建记录").font(.custom("Songti SC", size: 36))
      Text("保留任务结果与完整日志，随时回看构建过程。")
        .font(.system(size: 13)).foregroundStyle(Paint.muted)
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(m.history) { record in
            HStack(spacing: 14) {
              Image(
                systemName: record.status == "succeeded"
                  ? "checkmark.circle"
                  : record.status == "failed" ? "exclamationmark.circle" : "clock"
              )
              .foregroundStyle(record.status == "failed" ? Paint.accent : Paint.muted)
              VStack(alignment: .leading, spacing: 5) {
                Text(record.title).font(.system(size: 15, weight: .medium))
                Text(
                  record.status + " · "
                    + Date(timeIntervalSince1970: Double(record.started) / 1000).formatted(
                      date: .abbreviated, time: .shortened)
                )
                .font(.system(size: 11)).foregroundStyle(Paint.muted)
              }
              Spacer()
              Button("查看日志") { NSWorkspace.shared.open(URL(fileURLWithPath: record.logPath)) }
                .buttonStyle(QuietButton())
            }
            .padding(17).background(Paint.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Paint.line))
          }
        }
        if m.history.isEmpty { Text("还没有任务记录。").foregroundStyle(Paint.muted).padding(.top, 20) }
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
            ? "正在执行本地任务，详细进度见日志。"
            : m.job?.status == "failed" ? "任务失败；保留完整日志以便排查。" : "只构建你选择的目标。运行工具前会先更新构建。"
        ).font(.system(size: 11)).foregroundStyle(Paint.muted)
      }
      Spacer()
      if m.running {
        Button(m.cancellationRequested ? "取消中…" : "取消", action: m.cancel).buttonStyle(QuietButton())
          .disabled(m.cancellationRequested)
      }
      Button("查看日志") { m.showLogs = true }.buttonStyle(QuietButton()).disabled(
        m.job == nil && !m.starting)
    }.padding(.horizontal, 22).padding(.vertical, 17).background(Paint.panel).overlay(
      alignment: .top
    ) { Rectangle().fill(Paint.line).frame(height: 1) }
  }
}
func modeName(_ mode: String) -> String {
  mode == "debug" ? "断点调试" : mode == "release" ? "快速验证" : "日常开发 · 带调试符号"
}

struct EnvironmentEditor: View {
  @EnvironmentObject var m: WorkspaceModel
  @Environment(\.dismiss) var dismiss
  @State var profile: Profile
  @State var tab = "项目"
  @State var query = ""
  @State var prepare = true
  @State var advanced = false
  @State var proposedDirectory = ""
  init(initial: Profile) { _profile = State(initialValue: initial) }
  var choices: [String] {
    guard let c = m.workspace?.capabilities else { return [] }
    let all = tab == "项目" ? c.projects : tab == "后端" ? c.backends : c.runtimes
    return all.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
  }
  func binding(_ name: String) -> Binding<Bool> {
    Binding(
      get: {
        (tab == "项目" ? profile.projects : tab == "后端" ? profile.backends : profile.runtimes)
          .contains(name)
      },
      set: { on in
        if tab == "项目" {
          profile.projects.removeAll { $0 == name }
          if on { profile.projects.append(name) }
        } else if tab == "后端" {
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
          Text(profile.id.isEmpty ? "新建开发环境" : "编辑开发环境").font(.custom("Songti SC", size: 28))
          Text("组件来自当前 LLVM checkout，可以自由组合。").font(.system(size: 12)).foregroundStyle(Paint.muted)
        }
        Spacer()
      }
      HStack {
        TextField("环境名称", text: $profile.name).textFieldStyle(.roundedBorder)
        Picker("模式", selection: $profile.mode) {
          Text("日常开发").tag("dev")
          Text("断点调试").tag("debug")
          Text("快速验证").tag("release")
        }.frame(width: 240)
      }
      HStack(alignment: .top, spacing: 24) {
        VStack(spacing: 13) {
          Picker("组件类型", selection: $tab) {
            Text("项目").tag("项目")
            Text("后端").tag("后端")
            Text("Runtime").tag("Runtime")
          }.pickerStyle(.segmented)
          TextField("搜索当前 checkout 的组件", text: $query).textFieldStyle(.roundedBorder)
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
          Text("配置摘要").font(.system(size: 16, weight: .semibold))
          summary("项目", profile.projects.isEmpty ? ["LLVM core"] : profile.projects)
          summary("后端", profile.backends)
          summary("Runtime", profile.runtimes)
          Divider()
          Text("日常模式保留调试符号与断言。要逐步调试局部变量，选择断点调试。").font(.system(size: 12)).foregroundStyle(
            Paint.muted)
          if profile.runtimes.contains("libcxx") {
            Label("libc++ 测试环境", systemImage: "testtube.2").font(.system(size: 13, weight: .medium))
            Text("Core 会补齐编译器、ABI 与 unwind 运行库；执行测试前会更新 runtime 测试依赖。").font(.system(size: 12))
              .foregroundStyle(Paint.muted)
          }
          Spacer()
        }.frame(width: 265).padding(18).background(
          Paint.panel, in: RoundedRectangle(cornerRadius: 10))
      }.frame(minHeight: 260)
      VStack(alignment: .leading, spacing: 5) {
        Text("构建目录").font(.system(size: 12, weight: .medium))
        Text(
          profile.id.isEmpty
            ? (proposedDirectory.isEmpty ? "正在确定目录…" : proposedDirectory) : profile.buildDir
        )
        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2)
        Text("仅存放构建文件和产物。环境配置另存于应用目录，删除此目录后可以重新准备。")
          .font(.system(size: 11)).foregroundStyle(Paint.muted)
      }
      DisclosureGroup("工具链与并行度", isExpanded: $advanced) {
        VStack(alignment: .leading, spacing: 9) {
          HStack {
            Text("C 编译器").frame(width: 80, alignment: .leading)
            TextField("自动检测", text: $profile.cc).textFieldStyle(.roundedBorder)
          }
          HStack {
            Text("C++ 编译器").frame(width: 80, alignment: .leading)
            TextField("自动检测", text: $profile.cxx).textFieldStyle(.roundedBorder)
          }
          Stepper("编译并行度：\(profile.jobs)；链接并行度：1", value: $profile.jobs, in: 1...64)
        }.font(.system(size: 12)).padding(.top, 8)
      }
      HStack {
        Toggle("保存后准备环境", isOn: $prepare).font(.system(size: 12))
        Spacer()
        Button("取消") { dismiss() }.buttonStyle(QuietButton())
        Button(m.saving ? "保存中…" : "保存环境") { Task { await m.save(profile, prepare: prepare) } }
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
        if !Task.isCancelled { proposedDirectory = preview?.buildDir ?? "保存时分配目录" }
      }
  }
  private func summary(_ title: String, _ values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 11)).foregroundStyle(Paint.muted)
      Text(values.isEmpty ? "未启用" : values.joined(separator: " · ")).font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
struct RunSheet: View {
  @EnvironmentObject var m: WorkspaceModel
  @Environment(\.dismiss) var dismiss
  let artifact: Artifact
  @State var arguments = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("运行 \(artifact.name)").font(.custom("Georgia", size: 25))
      Text("先增量构建此工具，再运行。每行填写一个参数；参数中的空格会保留。").font(.system(size: 13)).foregroundStyle(Paint.muted)
      TextEditor(text: $arguments).font(.system(size: 13, design: .monospaced)).frame(height: 210)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Paint.line))
      HStack {
        Button("添加输入文件…") {
          let p = NSOpenPanel()
          if p.runModal() == .OK, let url = p.url {
            arguments += (arguments.isEmpty ? "" : "\n") + url.path
          }
        }.buttonStyle(QuietButton())
        Spacer()
        Button("取消") { dismiss() }.buttonStyle(QuietButton())
        Button("构建并运行") {
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
  @Environment(\.dismiss) var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        Text("任务日志").font(.custom("Songti SC", size: 25))
        Text(m.taskPhase).foregroundStyle(Paint.muted)
        Spacer()
        if m.running {
          Button(m.cancellationRequested ? "取消中…" : "取消任务", action: m.cancel).buttonStyle(
            QuietButton()
          ).disabled(m.cancellationRequested)
        }
        Button("关闭") { dismiss() }.buttonStyle(QuietButton())
      }
      ScrollView {
        Text(m.job?.lines.joined(separator: "\n") ?? (m.starting ? "正在读取构建配置并启动任务…" : "暂无日志")).font(
          .system(size: 11, design: .monospaced)
        ).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(15)
      }.frame(height: 490).background(Color(hex: 0xF0EDE7), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Text("显示最近 500 行，完整日志保存在本机。").font(.system(size: 11)).foregroundStyle(Paint.muted)
        Spacer()
        if let path = m.job?.logPath {
          Button("显示完整日志") { m.reveal(path) }.buttonStyle(QuietButton())
        }
      }
    }.padding(25).frame(width: 950).background(Paint.canvas).foregroundStyle(Paint.ink)
  }
}
