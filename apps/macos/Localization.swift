import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable {
  case system
  case english = "en"
  case simplifiedChinese = "zh-Hans"
}

final class LanguageSettings: ObservableObject {
  static let shared = LanguageSettings()
  @Published var selection: AppLanguage {
    didSet { UserDefaults.standard.set(selection.rawValue, forKey: L10n.preferenceKey) }
  }
  init() {
    selection =
      AppLanguage(rawValue: UserDefaults.standard.string(forKey: L10n.preferenceKey) ?? "")
      ?? .system
  }
  var locale: Locale {
    Locale(identifier: L10n.resolve(selection, preferredLanguages: Locale.preferredLanguages))
  }
}

struct LanguagePicker: View {
  @ObservedObject private var language = LanguageSettings.shared
  var body: some View {
    Picker(L("Language"), selection: $language.selection) {
      Text(L("Follow System")).tag(AppLanguage.system)
      Text("English").tag(AppLanguage.english)
      Text("简体中文").tag(AppLanguage.simplifiedChinese)
    }.pickerStyle(.inline)
  }
}

// Lazy list cells need their own subscription: their data identities do not
// change when the interface language changes.
struct LocalizedContent<Content: View>: View {
  @ObservedObject private var language = LanguageSettings.shared
  @ViewBuilder let content: (L10n) -> Content
  var body: some View {
    content(L10n(language: language.locale.identifier))
  }
}

// Keep navigation and filter identity independent of displayed translations.
enum WorkbenchPage: String, CaseIterable {
  case workbench = "Workbench"
  case environments = "Environments"
  case history = "History"
  var title: String { L(rawValue) }
}
enum ArtifactCategory: String, CaseIterable {
  case tools = "Tools"
  case libraries = "Libraries"
  case tests = "Tests"
  case all = "All"
  var title: String { L(rawValue) }
}
enum ComponentTab: String, CaseIterable {
  case projects = "Projects"
  case backends = "Backends"
  case runtimes = "Runtimes"
  var title: String { L(rawValue) }
}

struct L10n {
  static let preferenceKey = "interfaceLanguage"
  let language: String
  let bundle: Bundle

  static func resolve(_ selection: AppLanguage, preferredLanguages: [String]) -> String {
    if selection != .system { return selection.rawValue }
    for identifier in preferredLanguages {
      let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
      if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
      if code == "en" || code.hasPrefix("en-") { return "en" }
    }
    return "en"
  }

  init(language: String, resources: Bundle = .main) {
    self.language = language
    if let path = resources.path(forResource: language, ofType: "lproj"),
      let localized = Bundle(path: path)
    {
      bundle = localized
    } else {
      bundle = resources
    }
  }

  static var current: L10n {
    let selection =
      AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
    return L10n(language: resolve(selection, preferredLanguages: Locale.preferredLanguages))
  }
  var locale: Locale { Locale(identifier: language) }
  func text(_ key: String, arguments: [CVarArg] = []) -> String {
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
  }
  func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
    text(key, arguments: arguments)
  }

  // Old history uses Chinese phase names. Translate known app-owned metadata only;
  // never translate source paths, environment names, commands, or compiler output.
  static let legacyMetadata = [
    "准备环境": "Preparing environment", "运行工具": "Running tool",
    "运行回归测试": "Running regression tests", "更新测试依赖": "Updating test dependencies",
    "构建工具": "Building tools", "启动": "Starting", "完成": "Completed",
    "已取消": "Cancelled", "失败": "Failed",
  ]
  static func coreText(_ value: String) -> String {
    current.translatedCoreText(value)
  }
  func translatedCoreText(_ value: String) -> String {
    if let key = Self.legacyMetadata[value] { return text(key) }
    // Only match complete error templates emitted by our Core; keep the captured
    // tool, target, or component name verbatim.
    for template in [
      "%@ was not found. Install it or add it to PATH.",
      "Backend %@ is disabled. Enable it before running these tests.",
      "Target '%@' is unavailable. Check enabled projects and prepare the environment.",
      "Unsupported project in this checkout: %@",
      "Unsupported backend in this checkout: %@",
      "Unsupported runtime in this checkout: %@",
      "%@ appears in both projects and runtimes.",
      "Set %@ using the dedicated environment controls.",
      "Linker is not executable: %@",
    ] {
      let parts = template.components(separatedBy: "%@")
      if value.hasPrefix(parts[0]), value.hasSuffix(parts[1]),
        value.count >= parts[0].count + parts[1].count
      {
        let argument = String(value.dropFirst(parts[0].count).dropLast(parts[1].count))
        return text(template, arguments: [argument])
      }
    }
    return text(value)
  }
  static func status(_ value: String) -> String {
    current.translatedStatus(value)
  }
  func translatedStatus(_ value: String) -> String {
    translatedCoreText(
      [
        "succeeded": "Completed", "cancelled": "Cancelled", "failed": "Failed",
        "running": "Running",
      ][value] ?? value)
  }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
  L10n.current.text(key, arguments: arguments)
}
