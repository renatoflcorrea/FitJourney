import Foundation

enum OpenCodeGo {
    static let baseURL = URL(string: "https://opencode.ai/inference/go/openai/v1")!
    static let modelsURL = URL(string: "https://opencode.ai/inference/go/v1/models")!
    static let suggestedModels = ["gpt-6-luna", "claude-haiku-5-5", "glm-5.3-flash", "qwen3.8-flash"]
    static let staticVisionModels: Set<String> = ["gpt-6-luna", "claude-haiku-5-5", "glm-5.3-flash", "qwen3.8-flash", "mimo-v2.6-flash", "deepseek-v4.1-flash"]
    static let visionPrefixes = ["gpt-", "claude-"]
    static let textOnlyModels: Set<String> = ["glm-5.3", "deepseek-v4-pro", "hy3"]
    static let installationIDKey = "coach.openCode.installationID"

    static func isFreeModel(_ model: String) -> Bool { model.lowercased().hasSuffix("-free") }

    static func installationID(defaults: UserDefaults = .standard) -> String {
        if let value = defaults.string(forKey: installationIDKey) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: installationIDKey)
        return value
    }

    static func sessionID(installationID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in installationID.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
