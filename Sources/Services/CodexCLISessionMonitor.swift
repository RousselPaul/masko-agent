import Foundation

@MainActor
protocol CodexCLISessionMonitorDelegate: AnyObject {
    func codexCLIMonitorDidLoadSnapshot(_ snapshot: CodexSessionSnapshot)
    func codexCLIMonitorDidEmit(_ event: AgentEvent)
}

struct CodexSessionSnapshot {
    let sessionID: String
    let source: AgentSource
    let cwd: String?
    let isTaskActive: Bool
    let lastAssistantMessage: String
    let lastEventAt: Date?
}

@MainActor
final class CodexCLISessionMonitor {
    private let freshnessWindow: TimeInterval = 1800

    private struct SessionFileState {
        var fileOffset: UInt64 = 0
        var pendingData = Data()
        var sessionID: String?
        var source: AgentSource?
        var cwd: String?
        var currentTurnID: String?
        var completedTurnIDs: Set<String> = []
        var lastAssistantMessage = ""
        var lastEventAt: Date?
    }

    weak var delegate: CodexCLISessionMonitorDelegate?

    private let sessionsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/sessions", isDirectory: true)
    private var timer: Timer?
    private var fileStates: [URL: SessionFileState] = [:]
    private var hasCompletedInitialScan = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else { return }
        do {
            let files = try FileManager.default
                .subpathsOfDirectory(atPath: sessionsRoot.path)
                .filter { $0.hasSuffix(".jsonl") }
                .map { sessionsRoot.appendingPathComponent($0) }
                .sorted(by: { $0.path < $1.path })

            for file in files {
                try processFile(file)
            }
            if !hasCompletedInitialScan {
                publishInitialSnapshots()
                hasCompletedInitialScan = true
            }
        } catch {
            print("[masko-desktop] Failed to poll Codex sessions: \(error)")
        }
    }

    private func processFile(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var state = fileStates[file] ?? SessionFileState()
        if state.fileOffset > size {
            state.fileOffset = 0
        }

        try handle.seek(toOffset: state.fileOffset)
        let data = handle.readDataToEndOfFile()
        state.fileOffset = size

        guard !data.isEmpty || !state.pendingData.isEmpty else {
            fileStates[file] = state
            return
        }

        let emitLiveEvents = hasCompletedInitialScan
        var combinedData = state.pendingData
        combinedData.append(data)

        guard let lastNewlineIndex = combinedData.lastIndex(of: 0x0A) else {
            state.pendingData = combinedData
            fileStates[file] = state
            return
        }

        let completeData = combinedData.prefix(through: lastNewlineIndex)
        state.pendingData = Data(combinedData.suffix(from: combinedData.index(after: lastNewlineIndex)))

        let lines = String(decoding: completeData, as: UTF8.self).split(separator: "\n")
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            handleLineObject(object, state: &state, emitLiveEvents: emitLiveEvents)
        }

        fileStates[file] = state
    }

    private func handleLineObject(
        _ object: [String: Any],
        state: inout SessionFileState,
        emitLiveEvents: Bool
    ) {
        if let timestamp = object["timestamp"] as? String {
            state.lastEventAt = Self.parseTimestamp(timestamp)
        }

        guard let type = object["type"] as? String else { return }

        switch type {
        case "session_meta":
            let payload = object["payload"] as? [String: Any] ?? [:]
            guard let source = AgentSource.fromCodexSessionSource(payload["source"] as? String) else { return }
            state.source = source
            state.sessionID = payload["id"] as? String
            state.cwd = payload["cwd"] as? String
            if emitLiveEvents, let sessionID = state.sessionID {
                delegate?.codexCLIMonitorDidEmit(
                    AgentEvent(
                        hookEventName: HookEventType.sessionStart.rawValue,
                        sessionId: sessionID,
                        cwd: state.cwd,
                        source: source.rawValue
                    )
                )
            }

        case "event_msg":
            guard let source = state.source,
                  let sessionID = state.sessionID else { return }
            let payload = object["payload"] as? [String: Any] ?? [:]
            let eventType = payload["type"] as? String ?? ""

            switch eventType {
            case "task_started":
                let turnID = payload["turn_id"] as? String
                guard turnID != state.currentTurnID else { return }
                state.currentTurnID = turnID
                state.lastAssistantMessage = ""
                if emitLiveEvents {
                    delegate?.codexCLIMonitorDidEmit(
                        AgentEvent(
                            hookEventName: HookEventType.userPromptSubmit.rawValue,
                            sessionId: sessionID,
                            cwd: state.cwd,
                            source: source.rawValue
                        )
                    )
                }

            case "agent_message":
                if let message = payload["message"] as? String, !message.isEmpty {
                    state.lastAssistantMessage = message
                }

            case "task_complete":
                let turnID = payload["turn_id"] as? String ?? UUID().uuidString
                guard !state.completedTurnIDs.contains(turnID) else { return }
                state.completedTurnIDs.insert(turnID)
                state.currentTurnID = nil
                let message = (payload["last_agent_message"] as? String) ?? state.lastAssistantMessage
                state.lastAssistantMessage = message
                if emitLiveEvents {
                    delegate?.codexCLIMonitorDidEmit(
                        AgentEvent(
                            hookEventName: HookEventType.stop.rawValue,
                            sessionId: sessionID,
                            cwd: state.cwd,
                            source: source.rawValue,
                            lastAssistantMessage: message
                        )
                    )
                }

            default:
                break
            }

        default:
            break
        }
    }

    private func publishInitialSnapshots() {
        let now = Date()

        for state in fileStates.values {
            guard let source = state.source,
                  let sessionID = state.sessionID else { continue }

            let isRecent: Bool
            if let lastEventAt = state.lastEventAt {
                isRecent = now.timeIntervalSince(lastEventAt) <= freshnessWindow
            } else {
                isRecent = false
            }

            guard isRecent else { continue }

            delegate?.codexCLIMonitorDidLoadSnapshot(
                CodexSessionSnapshot(
                    sessionID: sessionID,
                    source: source,
                    cwd: state.cwd,
                    isTaskActive: state.currentTurnID != nil,
                    lastAssistantMessage: state.lastAssistantMessage,
                    lastEventAt: state.lastEventAt
                )
            )
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
