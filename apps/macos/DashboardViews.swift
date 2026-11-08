import AppKit
import SwiftUI

extension View {
  func island(_ color: Color = Paint.panel) -> some View {
    self.background(color, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Paint.line.opacity(0.8)))
      .shadow(color: .black.opacity(0.025), radius: 4, y: 2)
  }
}

struct SplitHandle: View {
  let title: String
  let width: CGFloat
  var direction: CGFloat = 1
  let resize: (CGFloat) -> Void
  let commit: () -> Void
  @State private var startWidth: CGFloat?
  @State private var hovering = false
  var body: some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(hovering ? Paint.accent.opacity(0.65) : Paint.line)
      .frame(width: 3, height: 28)
      .frame(width: 12).frame(maxHeight: .infinity).contentShape(Rectangle())
      .onHover { inside in
        hovering = inside
        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
      }
      .gesture(
        // The handle moves during layout. Local coordinates feed that movement
        // back into the next delta and make both panes oscillate.
        DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
          if startWidth == nil { startWidth = width }
          resize((startWidth ?? width) + direction * value.translation.width)
        }.onEnded { value in
          resize((startWidth ?? width) + direction * value.translation.width)
          commit()
          startWidth = nil
        }
      )
      .accessibilityLabel(title)
      .accessibilityAdjustableAction { direction in
        resize(width + (direction == .increment ? 24 : -24))
        commit()
      }
      .help(title)
  }
}

func taskDuration(_ record: CoreJob) -> String {
  guard let finished = record.finished, finished >= record.started else { return "—" }
  let seconds = Int((finished - record.started) / 1000)
  if seconds < 60 { return L("%ld s", seconds) }
  return L("%ld min %ld s", seconds / 60, seconds % 60)
}
func taskDate(_ record: CoreJob) -> Date {
  Date(timeIntervalSince1970: Double(record.finished ?? record.started) / 1000)
}
func relativeTime(_ date: Date) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.locale = L10n.current.locale
  formatter.unitsStyle = .abbreviated
  return formatter.localizedString(for: date, relativeTo: Date())
}
func taskIcon(_ status: String) -> String {
  switch status {
  case "succeeded": return "checkmark.circle"
  case "failed": return "exclamationmark.triangle"
  case "running": return "arrow.triangle.2.circlepath"
  default: return "minus.circle"
  }
}

struct TargetStatus: View {
  @EnvironmentObject var m: WorkspaceModel
  let artifact: Artifact
  var body: some View {
    let building = m.isBuilding(artifact.name)
    HStack(spacing: 5) {
      Image(
        systemName: building
          ? "arrow.triangle.2.circlepath" : artifact.present ? "checkmark.circle" : "circle.fill"
      )
      .font(.system(size: building || artifact.present ? 10 : 5))
      if building {
        if let progress = m.job?.progress, progress.total > 0 {
          Text(L("Building %ld%%", Int(Double(progress.completed) / Double(progress.total) * 100)))
        } else {
          Text(L("Building…"))
        }
      } else {
        Text(
          artifact.paths.isEmpty
            ? L("Build target") : artifact.present ? L("Built") : L("Not built"))
      }
    }.font(.system(size: 10)).foregroundStyle(building ? Paint.accent : Paint.muted)
      .padding(.horizontal, 7).padding(.vertical, 4)
      .background(building ? Paint.selection : Paint.sidebar.opacity(0.6), in: Capsule())
      .help(
        building
          ? L("Progress counts build steps, not elapsed time.")
          : L("Output presence; building checks whether it is up to date."))
  }
}

struct BuildSummary: View {
  @EnvironmentObject var m: WorkspaceModel
  var body: some View {
    let targets = m.categoryArtifacts
    let building = targets.filter { m.isBuilding($0.name) }.count
    let built = targets.filter { $0.present && !m.isBuilding($0.name) }.count
    let unbuilt = targets.filter { !$0.present && !$0.paths.isEmpty && !m.isBuilding($0.name) }
      .count
    let cmakeVersion = ["MAJOR", "MINOR", "PATCH"].compactMap {
      m.buildCache["CMAKE_CACHE_\($0)_VERSION"]
    }.joined(separator: ".")
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        chip(L("Built %ld", built), "checkmark.circle")
        chip(L("Building %ld", building), "arrow.triangle.2.circlepath", active: building > 0)
        chip(L("Not built %ld", unbuilt), "circle.dashed")
        chip(L("Total %ld", targets.count), "square.stack")
        if !cmakeVersion.isEmpty { chip("CMake " + cmakeVersion, "shippingbox") }
        if let generator = m.buildCache["CMAKE_GENERATOR"] { chip(generator, "bolt") }
        if let version = m.buildCache["CMAKE_PROJECT_VERSION"] {
          chip("LLVM " + version, "square.stack.3d.up")
        }
      }
    }.help(
      L(
        "Counts cover the selected category. Targets without output files are included only in the total."
      ))
  }
  private func chip(_ title: String, _ icon: String, active: Bool = false) -> some View {
    Label(title, systemImage: icon).font(.system(size: 11))
      .foregroundStyle(active ? Paint.accent : Paint.ink)
      .padding(.horizontal, 9).padding(.vertical, 6)
      .background(active ? Paint.selection : Paint.canvas, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Paint.line.opacity(0.6)))
  }
}

struct TargetInspector: View {
  @EnvironmentObject var m: WorkspaceModel
  @State private var excerpt: LogExcerpt?
  @State private var previewError = false
  private var records: [CoreJob] { m.selected.map { m.records(for: $0.name) } ?? [] }
  private var latest: CoreJob? { records.first }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let a = m.selected {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.kind == "EXECUTABLE" ? "terminal" : "shippingbox")
              .font(.system(size: 21)).foregroundStyle(Paint.muted)
            Text(a.name).font(.system(size: 19, weight: .semibold)).lineLimit(3).textSelection(
              .enabled)
            Spacer(minLength: 0)
            Button {
              m.toggleFavorite(a.name)
            } label: {
              Image(systemName: m.favorites.contains(a.name) ? "star.fill" : "star")
                .foregroundStyle(m.favorites.contains(a.name) ? Paint.accent : Paint.muted)
            }.buttonStyle(.plain).help(L("Favorite target")).accessibilityLabel(
              L("Favorite target"))
            Menu {
              Button(L("Copy target name")) { m.copy(a.name) }
              if let path = a.paths.first {
                Button(L("Copy output path")) { m.copy(path) }
                if a.present { Button(L("Show in Finder")) { m.reveal(path) } }
              }
              Button(L("Open in IDE…"), action: m.openIDE).disabled(m.running)
            } label: {
              Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(
              L("Target actions"))
          }
          Text(L10n.coreText(a.description)).font(.system(size: 12)).foregroundStyle(Paint.muted)
          VStack(spacing: 8) {
            Button {
              m.start("build", targets: [a.name])
            } label: {
              HStack {
                Label(
                  m.isBuilding(a.name) ? m.activityTitle : L("Build %@", a.name),
                  systemImage: "hammer")
                Spacer()
                Text("⌘B").font(.system(size: 10)).opacity(0.7)
              }
            }.buttonStyle(PrimaryButton()).disabled(m.running || m.pending)
            if a.kind == "EXECUTABLE" {
              HStack(spacing: 6) {
                Button(action: m.requestRun) {
                  HStack {
                    Label(L("Run…"), systemImage: "play")
                    Spacer()
                    Text("⌘R").font(.system(size: 10)).foregroundStyle(Paint.muted)
                  }
                }.buttonStyle(QuietButton()).disabled(m.running || m.pending)
                Menu {
                  Button(L("Run with arguments…"), action: m.requestRun).disabled(
                    m.running || m.pending)
                  Button(L("Open in IDE…"), action: m.openIDE).disabled(m.running)
                } label: {
                  Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(7)
                .background(Paint.canvas, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(L("Run actions"))
              }
            }
          }
          if let path = a.paths.first {
            Divider().overlay(Paint.line)
            Label(L("Output File"), systemImage: "folder").font(.system(size: 12, weight: .medium))
            HStack(alignment: .top, spacing: 8) {
              Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(
                  horizontal: false, vertical: true)
              Button {
                m.copy(path)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.plain).help(L("Copy output path")).accessibilityLabel(
                L("Copy output path"))
            }.padding(10).background(Paint.canvas, in: RoundedRectangle(cornerRadius: 7))
          }
          Divider().overlay(Paint.line)
          Label(L("Recent tasks"), systemImage: "clock").font(.system(size: 12, weight: .medium))
          if records.isEmpty {
            Text(L("No recorded tasks for this target.")).font(.system(size: 11)).foregroundStyle(
              Paint.muted)
          } else {
            VStack(spacing: 0) {
              ForEach(Array(records.prefix(3))) { record in
                HStack(spacing: 7) {
                  Image(systemName: taskIcon(record.status)).foregroundStyle(
                    record.status == "failed" ? Paint.accent : Paint.muted)
                  Text(L10n.status(record.status)).font(.system(size: 11))
                  Spacer(minLength: 4)
                  Text(relativeTime(taskDate(record))).font(.system(size: 10)).foregroundStyle(
                    Paint.muted)
                  Text(taskDuration(record)).font(.system(size: 10, design: .monospaced)).frame(
                    minWidth: 50, alignment: .trailing)
                  Button {
                    m.openLog(record)
                  } label: {
                    Image(systemName: "ellipsis")
                  }
                  .buttonStyle(.plain).help(L("Show Complete Log"))
                }.padding(.vertical, 8).overlay(alignment: .bottom) {
                  Rectangle().fill(Paint.line).frame(height: 1)
                }
                .help(L10n.coreText(record.title) + " · " + taskDate(record).formatted())
              }
            }
          }
          if let latest {
            logPreview(latest)
          }
        } else {
          Text(L("Select a target")).font(.system(size: 15, weight: .medium))
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
    }.task(id: latest?.id) {
      excerpt = nil
      previewError = false
      guard let record = latest, record.id != m.job?.id else { return }
      do {
        let value: LogExcerpt = try await Core.call([
          "action": "job_log", "root": record.root, "id": record.id,
        ])
        if !Task.isCancelled { excerpt = value }
      } catch { if !Task.isCancelled { previewError = true } }
    }
  }
  private func logPreview(_ record: CoreJob) -> some View {
    let live = record.id == m.job?.id
    let lines = live ? (m.job?.lines ?? []) : (excerpt?.lines ?? [])
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(L("Build log"), systemImage: "doc.text").font(.system(size: 12, weight: .medium))
        Spacer()
        Button(L("Show Complete Log")) { m.openLog(record) }
          .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Paint.accent)
      }
      VStack(alignment: .leading, spacing: 10) {
        ScrollView(.horizontal) {
          Text(
            lines.isEmpty
              ? L(previewError ? "Log preview unavailable" : "No logs yet")
              : lines.suffix(7).joined(separator: "\n")
          )
          .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 105)
        if record.status == "running", let progress = record.progress, progress.total > 0 {
          ProgressView(value: Double(progress.completed), total: Double(progress.total)).tint(
            Paint.accent)
          Text(L("%ld / %ld build steps", Int(progress.completed), Int(progress.total)))
            .font(.system(size: 10)).foregroundStyle(Paint.muted)
        }
        Label(
          L10n.status(record.status) + " · " + taskDuration(record),
          systemImage: taskIcon(record.status)
        )
        .font(.system(size: 11)).foregroundStyle(
          record.status == "failed" ? Paint.accent : Paint.muted)
      }.padding(10).background(Paint.canvas, in: RoundedRectangle(cornerRadius: 7))
    }
  }
}
