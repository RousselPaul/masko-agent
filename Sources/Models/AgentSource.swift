import Foundation

enum AgentSource: String, Codable, CaseIterable {
    case claude
    case codexCLI = "codex_cli"
    case codexVSCode = "codex_vscode"
    case codexMCP = "codex_mcp"

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codexCLI, .codexVSCode, .codexMCP: "Codex"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .claude: "Claude"
        case .codexCLI: "Codex CLI"
        case .codexVSCode: "Codex VS Code"
        case .codexMCP: "Codex MCP"
        }
    }

    var processName: String {
        switch self {
        case .claude: "claude"
        case .codexCLI, .codexVSCode, .codexMCP: "codex"
        }
    }

    var processCheckArguments: [String] {
        switch self {
        case .claude:
            return ["-x", processName]
        case .codexCLI, .codexVSCode, .codexMCP:
            // Codex is often launched through a Node wrapper, so the executable
            // name is not reliably just "codex". Match the full command line.
            return ["-f", processName]
        }
    }

    static func fromEventSource(_ value: String?) -> AgentSource {
        switch value {
        case AgentSource.codexCLI.rawValue: .codexCLI
        case AgentSource.codexVSCode.rawValue: .codexVSCode
        case AgentSource.codexMCP.rawValue: .codexMCP
        default: .claude
        }
    }

    static func fromCodexSessionSource(_ value: String?) -> AgentSource? {
        switch value {
        case "cli": .codexCLI
        case "vscode": .codexVSCode
        default: nil
        }
    }
}
