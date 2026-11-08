import Observation
import SwiftUI

@Observable private final class IDEArgumentDraft {
  var text = ""
}

private struct IDEArgumentEditor: View {
  @Bindable var draft: IDEArgumentDraft

  var body: some View {
    TextEditor(text: $draft.text).font(.system(size: 12, design: .monospaced))
      .frame(height: 65)
      .overlay(RoundedRectangle(cornerRadius: 5).stroke(Paint.line))
  }
}

private struct IDETargetPicker: View {
  let artifacts: [Artifact]
  @Binding var selection: String
  @State private var expanded = false

  var body: some View {
    HStack {
      Text(L("Build / debug target"))
      Spacer()
      Button {
        expanded = true
      } label: {
        HStack(spacing: 12) {
          Text(selection.isEmpty ? L("Source only") : selection).lineLimit(1)
          Spacer(minLength: 8)
          Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
        }.frame(width: 240).contentShape(Rectangle())
      }
      .buttonStyle(QuietButton())
      .accessibilityLabel(L("Build / debug target"))
      .accessibilityValue(selection.isEmpty ? L("Source only") : selection)
      .popover(isPresented: $expanded, arrowEdge: .bottom) {
        // A SwiftUI Picker eagerly creates thousands of menu items even while
        // closed. Only create the target browser when requested, and its rows
        // lazily as they become visible. This uses the existing artifact snapshot.
        IDETargetBrowser(artifacts: artifacts, selection: $selection) {
          expanded = false
        }
      }
    }
  }
}

private struct IDETargetBrowser: View {
  let artifacts: [Artifact]
  @Binding var selection: String
  let close: () -> Void
  @State private var search = ""

  private var matches: [Artifact] {
    artifacts.filter {
      ($0.kind == "EXECUTABLE" || $0.name.hasPrefix("check-"))
        && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TextField(L("Search targets…"), text: $search).textFieldStyle(.roundedBorder)
      row("", title: L("Source only"))
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(matches) { artifact in
            row(artifact.name, title: artifact.name)
          }
          if matches.isEmpty {
            Text(L("No matching targets")).foregroundStyle(Paint.muted).padding(10)
          }
        }
      }
    }.padding(12).frame(width: 380, height: 330)
      .background(Paint.canvas).foregroundStyle(Paint.ink)
  }

  private func row(_ name: String, title: String) -> some View {
    Button {
      selection = name
      close()
    } label: {
      HStack {
        Text(title).lineLimit(1)
        Spacer()
        if selection == name { Image(systemName: "checkmark") }
      }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(
          selection == name ? Paint.selection : Color.clear,
          in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
  }
}

struct IDESheet: View {
  @EnvironmentObject var m: WorkspaceModel
  @Environment(\.dismiss) var dismiss
  @State private var ide = "clion"
  @State private var target = ""
  // Only the editor observes text changes; typing does not refresh the form.
  @State private var arguments = IDEArgumentDraft()
  @State private var installExtensions = true

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(L("Open in IDE")).font(.system(size: 20, weight: .semibold))
      HStack(spacing: 12) {
        choice("clion", "CLion", "CMake · Run · Debug")
        choice("vscode", "VS Code", "clangd · Tasks · LLDB")
      }
      VStack(alignment: .leading, spacing: 12) {
        Text(m.profile?.name ?? "").font(.system(size: 15, weight: .semibold))
        Text(m.profile?.buildDir ?? "").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Paint.muted).textSelection(.enabled)
        if !m.configured || m.pending {
          Label(L("The environment will be prepared before opening."), systemImage: "hammer")
            .font(.system(size: 12)).foregroundStyle(Paint.accent)
        }
        IDETargetPicker(artifacts: m.artifacts, selection: $target)
        if !target.isEmpty {
          Text(L("Program arguments (one per line)")).font(.system(size: 12)).foregroundStyle(
            Paint.muted)
          IDEArgumentEditor(draft: arguments)
          Text(L("Existing IDE run arguments are preserved when reopening.")).font(
            .system(size: 11)
          ).foregroundStyle(Paint.muted)
        }
        if ide == "vscode" {
          Toggle(L("Set up clangd and CodeLLDB extensions"), isOn: $installExtensions)
          Text(L("Uses the official VS Code Marketplace. Already installed extensions are kept."))
            .font(.system(size: 11)).foregroundStyle(Paint.muted)
        }
        if m.profile?.mode == "release" {
          Text(
            L(
              "Release builds have limited debug information. Use a Dev or Debug environment for debugging."
            )
          )
          .font(.system(size: 12)).foregroundStyle(Paint.accent)
        }
      }.padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Paint.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Paint.line).frame(height: 1) }
        .disabled(m.ideBusy)
      HStack {
        if m.ideBusy {
          ProgressView().controlSize(.small)
          Text(L(m.idePhase)).font(.system(size: 12)).foregroundStyle(Paint.muted)
        } else if let result = m.ideExport {
          Button(L("Show generated files")) { m.reveal(result.path) }.buttonStyle(.plain)
        }
        Spacer()
        Button(L("Cancel")) { dismiss() }.buttonStyle(QuietButton()).disabled(m.ideBusy)
        Button(m.ideBusy ? L("Preparing IDE…") : L("Prepare & Open")) {
          m.prepareIDE(
            ide, target: target,
            arguments: arguments.text.split(separator: "\n", omittingEmptySubsequences: true).map(
              String.init),
            installExtensions: installExtensions)
        }.buttonStyle(PrimaryButton()).disabled(m.running)
      }
    }.padding(24).frame(width: 610).background(Paint.canvas).foregroundStyle(Paint.ink).tint(
      Paint.accent
    )
    .interactiveDismissDisabled(m.ideBusy)
    .onAppear { target = m.selected?.kind == "EXECUTABLE" ? m.selectedArtifact : "" }
  }
  private func choice(_ id: String, _ name: String, _ subtitle: String) -> some View {
    Button {
      ide = id
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(name).font(.system(size: 14, weight: .semibold))
          Text(subtitle).font(.system(size: 11)).foregroundStyle(Paint.muted)
        }
        Spacer()
        Image(systemName: ide == id ? "checkmark.circle.fill" : "circle").foregroundStyle(
          ide == id ? Paint.accent : Paint.muted)
      }.padding(12).frame(maxWidth: .infinity).background(
        ide == id ? Paint.selection.opacity(0.5) : Paint.panel,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6).stroke(ide == id ? Paint.accent.opacity(0.6) : Paint.line)
      )
      .contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(m.ideBusy)
  }
}
