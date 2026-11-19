import Foundation

enum ModelDefaults {
    static func version(of id: String) -> [Int] {
        id.split { !$0.isASCII || !$0.isNumber }.compactMap { Int($0) }
    }

    static func isNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for i in 0..<max(lhs.count, rhs.count) {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func preferred(in models: [String], provider: AIProviderID) -> String? {
        func newest(_ matches: (String) -> Bool) -> String? {
            var best: String?
            for model in models where matches(model.lowercased()) {
                if best == nil || isNewer(version(of: model), than: version(of: best!)) { best = model }
            }
            return best
        }
        switch provider {
        case .anthropic:
            return newest { $0.hasPrefix("claude-haiku-") } ?? models.first
        case .openRouter:
            return newest { $0.hasPrefix("openai/gpt-") && $0.contains("luna") }
                ?? newest { $0.hasPrefix("anthropic/claude-haiku-") } ?? models.first
        case .openAI:
            return newest { $0.contains("luna") } ?? newest { $0.contains("mini") } ?? models.first
        case .openCode, .chatGPT:
            return newest { $0.contains("luna") } ?? models.first
        case .custom:
            return models.first
        }
    }
}
