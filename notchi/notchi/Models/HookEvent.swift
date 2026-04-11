import Foundation

enum NormalizedAgentEvent: String, CaseIterable, Codable, Sendable {
    case userPromptSubmitted = "UserPromptSubmit"
    case sessionStarted = "SessionStart"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case preCompact = "PreCompact"
    case stop = "Stop"
    case subagentStop = "SubagentStop"
    case sessionEnded = "SessionEnd"

    nonisolated static func claudeEvent(named rawValue: String) -> Self? {
        Self(rawValue: rawValue)
    }

    nonisolated static func codexEvent(named rawValue: String) -> Self? {
        switch rawValue {
        case "SessionStart":
            .sessionStarted
        case "UserPromptSubmit":
            .userPromptSubmitted
        case "PreToolUse":
            .preToolUse
        case "PostToolUse":
            .postToolUse
        case "Stop":
            .stop
        default:
            nil
        }
    }
}

struct AgentHookEnvelope: Decodable, Sendable {
    let provider: AgentProvider
    let sessionId: String
    let transcriptPath: String?
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let userPrompt: String?
    let permissionMode: String?
    let interactive: Bool?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case userPrompt = "user_prompt"
        case permissionMode = "permission_mode"
        case interactive
        case model
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        provider = try container.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .claude
        sessionId = try container.decode(String.self, forKey: .sessionId)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwd = try container.decode(String.self, forKey: .cwd)
        event = try container.decode(String.self, forKey: .event)
        status = try container.decode(String.self, forKey: .status)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        toolInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        userPrompt = try container.decodeIfPresent(String.self, forKey: .userPrompt)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        interactive = try container.decodeIfPresent(Bool.self, forKey: .interactive)
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }
}

struct HookEvent: Sendable {
    let provider: AgentProvider
    let sessionKey: ProviderSessionKey
    let transcriptPath: String?
    let cwd: String
    let event: NormalizedAgentEvent
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let userPrompt: String?
    let permissionMode: String?
    let interactive: Bool?
    let model: String?

    nonisolated var sessionId: String {
        sessionKey.stableId
    }

    nonisolated var rawSessionId: String {
        sessionKey.rawSessionId
    }

    nonisolated init(
        provider: AgentProvider = .claude,
        rawSessionId: String,
        transcriptPath: String?,
        cwd: String,
        event: NormalizedAgentEvent,
        status: String,
        pid: Int? = nil,
        tty: String? = nil,
        tool: String? = nil,
        toolInput: [String: AnyCodable]? = nil,
        toolUseId: String? = nil,
        userPrompt: String? = nil,
        permissionMode: String? = nil,
        interactive: Bool? = nil,
        model: String? = nil
    ) {
        self.provider = provider
        self.sessionKey = ProviderSessionKey(provider: provider, rawSessionId: rawSessionId)
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.userPrompt = userPrompt
        self.permissionMode = permissionMode
        self.interactive = interactive
        self.model = model
    }
}

struct AnyCodable: Decodable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode value"
            )
        }
    }
}
