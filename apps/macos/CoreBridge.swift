import Foundation

struct Profile: Codable, Identifiable, Equatable {
  var id: String
  var name: String
  var buildDir: String
  var projects: [String]
  var backends: [String]
  var runtimes: [String]
  var mode: String
  var jobs: Int
  var cc: String
  var cxx: String
  var definitions: [String: String]
}
struct Capabilities: Decodable {
  let projects: [String]
  let backends: [String]
  let runtimes: [String]
}
struct Workspace: Decodable {
  let root: String
  let name: String
  let profiles: [Profile]
  let capabilities: Capabilities
  let tools: [String: String?]
  let defaultProfile: Profile
  let profilesFile: String
}
struct Artifact: Decodable, Identifiable {
  var id: String { name }
  let name: String
  let kind: String
  let paths: [String]
  let present: Bool
  let description: String
}
struct ArtifactResult: Decodable {
  let artifacts: [Artifact]
  let configured: Bool
  let pending: Bool
  let cache: [String: String]
}
struct OperationStart: Decodable { let id: String }
struct CoreJob: Decodable, Identifiable {
  let id: String
  let root: String
  let profileId: String
  let title: String
  let phase: String
  let status: String
  let started: UInt64
  let finished: UInt64?
  let exitCode: Int?
  let logPath: String
  let lineCount: UInt64
  let lines: [String]
}
struct CoreFailure: LocalizedError {
  let message: String
  var errorDescription: String? { L10n.coreText(message) }
}
enum Core {
  static func sync<T: Decodable>(_ request: [String: Any], as type: T.Type = T.self) throws -> T {
    let input = try JSONSerialization.data(withJSONObject: request)
    let response: String = try String(decoding: input, as: UTF8.self).withCString { pointer in
      guard let result = llvmwb_request(pointer) else {
        throw CoreFailure(message: "No response from the build engine")
      }
      defer { llvmwb_free(result) }
      return String(cString: result)
    }
    let data = Data(response.utf8)
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CoreFailure(message: "Invalid build engine response")
    }
    guard envelope["ok"] as? Bool == true else {
      throw CoreFailure(message: envelope["error"] as? String ?? "Build engine request failed")
    }
    let body = try JSONSerialization.data(
      withJSONObject: envelope["data"] as Any, options: [.fragmentsAllowed])
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: body)
  }
  static func call<T: Decodable>(_ request: [String: Any], as type: T.Type = T.self) async throws
    -> T
  {
    try await Task.detached(priority: .userInitiated) { try sync(request, as: type) }.value
  }
  static func encode(_ profile: Profile) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return try JSONSerialization.jsonObject(with: encoder.encode(profile)) as! [String: Any]
  }
}
