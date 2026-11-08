import Foundation

// Validate the resources in the built bundle, not just the source strings.
enum LocalizationTests {
  @MainActor static func run() throws {
    func table(_ language: String) throws -> [String: String] {
      guard let path = Bundle.main.path(forResource: language, ofType: "lproj") else {
        preconditionFailure("Missing bundled localization: \(language)")
      }
      let data = try Data(
        contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings"))
      return try PropertyListSerialization.propertyList(from: data, format: nil)
        as! [String: String]
    }
    let english = try table("en")
    let chinese = try table("zh-Hans")
    precondition(Set(english.keys) == Set(chinese.keys), "Translation keys differ")
    let placeholders = try NSRegularExpression(pattern: "%[0-9$]*(@|ld)")
    func parameters(_ value: String) -> [String] {
      placeholders.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
        String(value[Range($0.range, in: value)!])
      }
    }
    for (key, text) in english {
      precondition(!chinese[key]!.isEmpty, "Empty translation: \(key)")
      precondition(parameters(text) == parameters(chinese[key]!), "Format arguments differ: \(key)")
      precondition(
        text.range(of: "\\p{Han}", options: .regularExpression) == nil,
        "Chinese in English UI: \(key)")
    }
    precondition(
      L10n.resolve(.system, preferredLanguages: ["fr-FR", "zh-Hant-TW", "en-US"]) == "zh-Hans")
    precondition(L10n.resolve(.system, preferredLanguages: ["en-GB", "zh-Hans"]) == "en")
    precondition(L10n.resolve(.system, preferredLanguages: ["de-DE"]) == "en")
    precondition(L10n.resolve(.english, preferredLanguages: ["zh-Hans"]) == "en")
    let en = L10n(language: "en")
    let zh = L10n(language: "zh-Hans")
    precondition(en.text("Build %@", arguments: ["clang"]) == "Build clang")
    precondition(zh.text("Build %@", arguments: ["clang"]) == "构建 clang")
    precondition(
      en.text("Projects: %ld · Backends: %ld", arguments: [2, 3]) == "Projects: 2 · Backends: 3")
    precondition(zh.text("Projects: %ld · Backends: %ld", arguments: [2, 3]) == "项目：2 · 后端：3")
    precondition(en.text("not-a-translation-key") == "not-a-translation-key")

    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: L10n.preferenceKey)
    defer {
      if let previous {
        defaults.set(previous, forKey: L10n.preferenceKey)
      } else {
        defaults.removeObject(forKey: L10n.preferenceKey)
      }
    }
    let settings = LanguageSettings()
    let model = WorkspaceModel()
    model.page = .history
    model.category = .libraries
    model.profileId = "unchanged-profile"
    model.selectedArtifact = "check-llvm"
    settings.selection = .simplifiedChinese
    precondition(
      LanguageSettings().selection == .simplifiedChinese, "Language selection was not saved")
    precondition(model.page.title == "历史")
    precondition(L10n.coreText("Preparing environment") == "准备环境")
    precondition(
      CoreFailure(message: "Environment name is required.").localizedDescription == "请填写环境名称。")
    precondition(
      L10n.coreText("Backend RISCV is disabled. Enable it before running these tests.")
        == "后端 RISCV 未启用，请先启用后再运行这些测试。")
    settings.selection = .english
    precondition(model.page.title == "History")
    precondition(
      model.category == .libraries && model.profileId == "unchanged-profile"
        && model.selectedArtifact == "check-llvm")
    precondition(L10n.coreText("准备环境") == "Preparing environment", "Old history failed to localize")
    precondition(L10n.status("cancelled") == "Cancelled")
    let path = "/tmp/用户目录/clang"
    precondition(L10n.coreText(path) == path, "User content was translated")
    print(
      "PASS: bundled English/Chinese strings, format arguments, system fallback, saved language, stable selection, legacy history"
    )
  }
}
