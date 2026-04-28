import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")

struct ClaudeSettingsConfig {
    let apiURL: URL
    let apiKey: String
    let model: String

    nonisolated static let defaultBaseURL = "https://api.anthropic.com"
    nonisolated static let defaultAPIURL = URL(string: "\(defaultBaseURL)/v1/messages")!
    nonisolated static let defaultModel = EmotionAnalysisModel.claudeHaiku45.rawValue

    nonisolated static func load(from settingsURL: URL) -> ClaudeSettingsConfig? {
        let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")
        guard let data = try? Data(contentsOf: settingsURL) else {
            return nil
        }

        do {
            return try parse(from: data)
        } catch {
            logger.error("Failed to parse Claude settings.json: \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func loadFromDefaultLocation() -> ClaudeSettingsConfig? {
        load(from: ClaudeConfigDirectoryResolver.resolve().settingsURL)
    }

    nonisolated static func existsAtDefaultLocation() -> Bool {
        loadFromDefaultLocation() != nil
    }

    nonisolated static func parse(from data: Data) throws -> ClaudeSettingsConfig? {
        let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let env = json?["env"] as? [String: String] ?? [:]

        let baseURL = env["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBaseURL = (baseURL?.isEmpty == false) ? baseURL! : defaultBaseURL

        guard let authToken = env["ANTHROPIC_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !authToken.isEmpty,
              let apiURL = buildMessagesURL(from: resolvedBaseURL) else {
            logger.debug("Claude settings present but missing valid auth token or base URL")
            return nil
        }

        let model = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeSettingsConfig(
            apiURL: apiURL,
            apiKey: authToken,
            model: (model?.isEmpty == false) ? model! : defaultModel
        )
    }

    nonisolated static func buildMessagesURL(from baseURL: String) -> URL? {
        let logger = Logger(subsystem: "com.ruban.notchi", category: "EmotionAnalyzer")
        guard var components = URLComponents(string: baseURL) else {
            logger.error("Invalid ANTHROPIC_BASE_URL: \(baseURL, privacy: .public)")
            return nil
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch true {
        case normalizedPath.isEmpty:
            components.path = "/v1/messages"
        case normalizedPath.hasSuffix("/v1/messages") || normalizedPath == "v1/messages":
            components.path = "/\(normalizedPath)"
        case normalizedPath.hasSuffix("/v1") || normalizedPath == "v1":
            components.path = "/\(normalizedPath)/messages"
        default:
            components.path = "/\(normalizedPath)/v1/messages"
        }

        return components.url
    }
}

enum OpenAISettingsConfig {
    nonisolated static let defaultAPIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
}

private struct HaikuResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let text: String?
    }
}

private struct OpenAIChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}

private struct EmotionResponse: Decodable {
    let emotion: String
    let intensity: Double
}

private struct EmotionAnalysisResponseParser {
    private static let validEmotions: Set<String> = ["happy", "sad", "neutral"]

    static func parse(_ text: String) throws -> (emotion: String, intensity: Double) {
        let jsonString = extractJSON(from: text)
        let emotionResponse = try JSONDecoder().decode(EmotionResponse.self, from: Data(jsonString.utf8))

        let emotion = validEmotions.contains(emotionResponse.emotion) ? emotionResponse.emotion : "neutral"
        let intensity = min(max(emotionResponse.intensity, 0.0), 1.0)

        return (emotion, intensity)
    }

    static func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code blocks: ```json ... ``` or ``` ... ```
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }

        return cleaned
    }
}

private protocol EmotionAnalysisProviding {
    var providerName: String { get }
    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double)
}

private struct ClaudeEmotionAnalysisProvider: EmotionAnalysisProviding {
    let apiURL: URL
    let apiKey: String
    let model: String

    var providerName: String { "Claude" }

    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double) {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 50,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            logger.warning("Claude API returned HTTP \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        let haikuResponse = try JSONDecoder().decode(HaikuResponse.self, from: data)

        guard let text = haikuResponse.content.first?.text else {
            throw URLError(.cannotParseResponse)
        }

        logger.debug("Claude raw response: \(text, privacy: .private)")
        return try EmotionAnalysisResponseParser.parse(text)
    }
}

private struct OpenAIEmotionAnalysisProvider: EmotionAnalysisProviding {
    let apiURL: URL
    let apiKey: String
    let model: String

    var providerName: String { "OpenAI" }

    func analyze(prompt: String, systemPrompt: String) async throws -> (emotion: String, intensity: Double) {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 80,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "emotion_analysis",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "emotion": [
                                "type": "string",
                                "enum": ["happy", "sad", "neutral"]
                            ],
                            "intensity": [
                                "type": "number",
                                "minimum": 0,
                                "maximum": 1
                            ]
                        ],
                        "required": ["emotion", "intensity"]
                    ]
                ]
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            logger.warning("OpenAI API returned HTTP \(httpResponse.statusCode)")
            throw URLError(.badServerResponse)
        }

        let chatResponse = try JSONDecoder().decode(OpenAIChatCompletionResponse.self, from: data)

        guard let text = chatResponse.choices.first?.message.content else {
            throw URLError(.cannotParseResponse)
        }

        logger.debug("OpenAI raw response: \(text, privacy: .private)")
        return try EmotionAnalysisResponseParser.parse(text)
    }
}

@MainActor
final class EmotionAnalyzer {
    static let shared = EmotionAnalyzer()

    private static let systemPrompt = """
        Classify the emotional tone of the user's message into exactly one emotion and an intensity score.
        Emotions: happy, sad, neutral.
        Happy: explicit praise ("great job", "thank you!"), gratitude, celebration, positive profanity ("LETS FUCKING GO").
        Sad: frustration, anger, insults, complaints, feeling stuck, disappointment, negative profanity.
        Neutral: instructions, requests, task descriptions, questions, enthusiasm about work, factual statements. Exclamation marks or urgency about a task do NOT make it happy — only genuine positive sentiment toward the AI or outcome does.
        Default to neutral when unsure. Most coding instructions are neutral regardless of tone.
        Intensity: 0.0 (barely noticeable) to 1.0 (very strong). ALL CAPS text indicates stronger emotion — increase intensity by 0.2-0.3 compared to the same message in lowercase.
        Reply with ONLY valid JSON: {"emotion": "...", "intensity": ...}
        """

    private init() {}

    func analyze(_ prompt: String) async -> (emotion: String, intensity: Double) {
        let start = ContinuousClock.now

        guard let provider = resolveProvider() else {
            logger.info("No emotion analysis configuration available, using neutral fallback")
            return ("neutral", 0.0)
        }

        do {
            let result = try await provider.analyze(prompt: prompt, systemPrompt: Self.systemPrompt)
            let elapsed = ContinuousClock.now - start
            logger.info("\(provider.providerName, privacy: .public) analysis took \(elapsed, privacy: .public)")
            return result
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("\(provider.providerName, privacy: .public) API failed (\(elapsed, privacy: .public)): \(error.localizedDescription)")
            return ("neutral", 0.0)
        }
    }

    private func resolveProvider() -> EmotionAnalysisProviding? {
        switch AppSettings.emotionAnalysisProvider {
        case .claude:
            return resolveClaudeProvider()
        case .openAI:
            return resolveOpenAIProvider()
        }
    }

    private func resolveClaudeProvider() -> ClaudeEmotionAnalysisProvider? {
        if let apiKey = KeychainManager.getAnthropicApiKey(allowInteraction: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            return ClaudeEmotionAnalysisProvider(
                apiURL: ClaudeSettingsConfig.defaultAPIURL,
                apiKey: apiKey,
                model: AppSettings.selectedEmotionAnalysisModel(for: .claude).rawValue
            )
        }

        guard let config = ClaudeSettingsConfig.loadFromDefaultLocation() else {
            return nil
        }

        return ClaudeEmotionAnalysisProvider(
            apiURL: config.apiURL,
            apiKey: config.apiKey,
            model: AppSettings.storedEmotionAnalysisModel(for: .claude)?.rawValue ?? config.model
        )
    }

    private func resolveOpenAIProvider() -> OpenAIEmotionAnalysisProvider? {
        guard let apiKey = KeychainManager.getOpenAIApiKey(allowInteraction: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return nil
        }

        return OpenAIEmotionAnalysisProvider(
            apiURL: OpenAISettingsConfig.defaultAPIURL,
            apiKey: apiKey,
            model: AppSettings.selectedEmotionAnalysisModel(for: .openAI).rawValue
        )
    }
}
