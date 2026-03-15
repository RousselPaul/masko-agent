import Foundation

struct AgentSession: Identifiable, Codable {
    let id: String // session_id from Claude Code or Codex
    var projectDir: String?
    var projectName: String?
    var agentSource: AgentSource
    var status: Status
    var phase: Phase = .idle
    var eventCount: Int
    var startedAt: Date
    var lastEventAt: Date?
    var lastToolName: String?
    var activeSubagentCount: Int = 0
    var isCompacting: Bool = false
    var terminalPid: Int?
    var shellPid: Int?
    var transcriptPath: String?

    enum Status: String, Codable {
        case active, ended

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = raw == "active" ? .active : .ended
        }
    }

    enum Phase: String, Codable {
        case idle       // After Stop or SessionStart — waiting for user input
        case running    // After UserPromptSubmit or tool use — agent is working
        case compacting // After PreCompact — context compaction in progress
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectDir
        case projectName
        case agentSource
        case status
        case phase
        case eventCount
        case startedAt
        case lastEventAt
        case lastToolName
        case activeSubagentCount
        case isCompacting
        case terminalPid
        case shellPid
        case transcriptPath
    }

    init(
        id: String,
        projectDir: String?,
        projectName: String?,
        agentSource: AgentSource = .claude,
        status: Status,
        phase: Phase = .idle,
        eventCount: Int,
        startedAt: Date,
        lastEventAt: Date?,
        lastToolName: String? = nil,
        activeSubagentCount: Int = 0,
        isCompacting: Bool = false,
        terminalPid: Int? = nil,
        shellPid: Int? = nil,
        transcriptPath: String? = nil
    ) {
        self.id = id
        self.projectDir = projectDir
        self.projectName = projectName
        self.agentSource = agentSource
        self.status = status
        self.phase = phase
        self.eventCount = eventCount
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.lastToolName = lastToolName
        self.activeSubagentCount = activeSubagentCount
        self.isCompacting = isCompacting
        self.terminalPid = terminalPid
        self.shellPid = shellPid
        self.transcriptPath = transcriptPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.projectDir = try container.decodeIfPresent(String.self, forKey: .projectDir)
        self.projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        self.agentSource = try container.decodeIfPresent(AgentSource.self, forKey: .agentSource) ?? .claude
        self.status = try container.decode(Status.self, forKey: .status)
        self.phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        self.eventCount = try container.decode(Int.self, forKey: .eventCount)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.lastEventAt = try container.decodeIfPresent(Date.self, forKey: .lastEventAt)
        self.lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        self.activeSubagentCount = try container.decodeIfPresent(Int.self, forKey: .activeSubagentCount) ?? 0
        self.isCompacting = try container.decodeIfPresent(Bool.self, forKey: .isCompacting) ?? false
        self.terminalPid = try container.decodeIfPresent(Int.self, forKey: .terminalPid)
        self.shellPid = try container.decodeIfPresent(Int.self, forKey: .shellPid)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    }
}

@Observable
final class SessionStore {
    private(set) var sessions: [AgentSession] = []
    private static let filename = "sessions.json"
    private var reconcileTimer: Timer?
    private var interruptWatcherTimer: Timer?

    /// Called when interrupt detection flips a running session to idle.
    /// Wire this to refresh overlay inputs.
    var onPhasesChanged: (() -> Void)?

    init() {
        sessions = LocalStorage.load([AgentSession].self, from: Self.filename) ?? []
        reconcileIfNeeded()
        startReconcileTimer()
        startInterruptWatcher()
    }

    /// Safety net: check every 2 minutes if Claude processes are still alive.
    /// Catches the edge case where SessionEnd hook was never delivered (crash, SIGKILL).
    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.reconcileIfNeeded()
            }
        }
    }

    /// Check every 3 seconds if any running sessions were interrupted.
    /// Claude Code does not fire a hook on user interrupt, but it does write
    /// `[Request interrupted by user]` to the transcript JSONL file.
    private func startInterruptWatcher() {
        interruptWatcherTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkForInterrupts()
            }
        }
    }

    /// Read the tail of each running session's transcript to detect interrupts.
    private func checkForInterrupts() {
        // Collect data needed for background I/O
        let candidates: [(index: Int, id: String, path: String, lastEventAt: Date?)] = sessions.indices.compactMap {
            guard sessions[$0].status == .active,
                  sessions[$0].agentSource == .claude,
                  sessions[$0].phase == .running,
                  let path = sessions[$0].transcriptPath else { return nil }
            return ($0, sessions[$0].id, path, sessions[$0].lastEventAt)
        }
        guard !candidates.isEmpty else { return }

        // File I/O on background queue to avoid blocking main thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let interrupted = candidates.filter {
                Self.transcriptIndicatesInterrupt(path: $0.path, since: $0.lastEventAt)
            }
            guard !interrupted.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                var changed = false
                for candidate in interrupted {
                    // Re-verify index is still valid and session hasn't changed
                    guard candidate.index < self.sessions.count,
                          self.sessions[candidate.index].id == candidate.id,
                          self.sessions[candidate.index].phase == .running else { continue }
                    self.sessions[candidate.index].phase = .idle
                    self.sessions[candidate.index].isCompacting = false
                    changed = true
                    print("[masko-desktop] Interrupt detected for session \(candidate.id) via transcript")
                }
                if changed {
                    self.persist()
                    self.onPhasesChanged?()
                }
            }
        }
    }

    /// Read the last ~4KB of a transcript JSONL file and check if the most recent
    /// non-progress entry is `[Request interrupted by user]`.
    private static func transcriptIndicatesInterrupt(path: String, since lastEventAt: Date?) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return false }
        let readSize = min(UInt64(4096), fileSize)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Walk backwards to find the last meaningful entry (skip "progress" lines)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = obj["type"] as? String ?? ""
            if type == "progress" || type == "file-history-snapshot" || type == "summary" { continue }

            // Check timestamp — only act on entries newer than our last hook event
            if let timestamp = obj["timestamp"] as? String, let lastEventAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var entryDate = formatter.date(from: timestamp)
                if entryDate == nil {
                    // Retry without fractional seconds
                    formatter.formatOptions = [.withInternetDateTime]
                    entryDate = formatter.date(from: timestamp)
                }
                if let entryDate, entryDate <= lastEventAt {
                    return false // This entry is older than our last event — stale
                }
                // If timestamp still can't be parsed, treat as stale to avoid false positives
                if entryDate == nil {
                    return false
                }
            }

            // Check if this is an interrupt entry
            if type == "user",
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]],
               let firstItem = content.first,
               let text = firstItem["text"] as? String,
               text.contains("[Request interrupted by user]"),
               !text.contains("for tool use") {
                return true
            }

            // Found a non-progress, non-interrupt entry — session is not interrupted
            return false
        }
        return false
    }

    /// Invalidate all timers — called on app termination
    func stopTimers() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        interruptWatcherTimer?.invalidate()
        interruptWatcherTimer = nil
    }

    deinit {
        reconcileTimer?.invalidate()
        interruptWatcherTimer?.invalidate()
    }

    // MARK: - Crash Recovery

    /// Check for crashed Claude processes and mark orphaned sessions as ended.
    /// Called on init and when the app comes to foreground.
    func reconcileIfNeeded() {
        guard !activeSessions.isEmpty else { return }

        // Run pgrep on a background thread to avoid blocking the UI
        checkForAgentProcesses { [weak self] processState in
            DispatchQueue.main.async {
                self?.applyReconciliation(processState: processState)
            }
        }
    }

    private func applyReconciliation(processState: [AgentSource: Bool]) {
        guard !activeSessions.isEmpty else { return }

        var changed = false

        // 1. If the owning agent process is gone, end the corresponding sessions.
        for i in sessions.indices where sessions[i].status == .active {
            let hasProcess = processState[sessions[i].agentSource] ?? false
            if !hasProcess {
                sessions[i].status = .ended
                sessions[i].phase = .idle
                sessions[i].activeSubagentCount = 0
                sessions[i].isCompacting = false
                changed = true
            }
        }

        // 2. End stale non-running sessions (no events in 10+ minutes).
        // Running tasks can legitimately go quiet for a long time, especially for Codex.
        let staleThreshold: TimeInterval = 600 // 10 minutes
        let now = Date()
        for i in sessions.indices where sessions[i].status == .active {
            guard sessions[i].phase != .running else { continue }
            if let lastEvent = sessions[i].lastEventAt,
               now.timeIntervalSince(lastEvent) > staleThreshold {
                sessions[i].status = .ended
                sessions[i].phase = .idle
                sessions[i].activeSubagentCount = 0
                sessions[i].isCompacting = false
                changed = true
            }
        }

        if changed {
            persist()
            onPhasesChanged?()
        }
    }

    /// Check if any monitored agent CLI processes are running via pgrep.
    /// Runs on a background thread to avoid blocking the main/UI thread.
    private func checkForAgentProcesses(completion: @escaping ([AgentSource: Bool]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var results: [AgentSource: Bool] = [:]
            for source in AgentSource.allCases {
                if results[source] != nil { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                process.arguments = source.processCheckArguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    results[source] = process.terminationStatus == 0
                } catch {
                    results[source] = false
                }
            }
            completion(results)
        }
    }

    // MARK: - Persistence

    private func persist() {
        LocalStorage.save(sessions, to: Self.filename)
    }

    // MARK: - Computed Properties

    var activeSessions: [AgentSession] {
        sessions.filter { $0.status == .active }
    }

    var runningSessions: [AgentSession] {
        activeSessions.filter { $0.phase == .running }
    }

    var idleSessions: [AgentSession] {
        activeSessions.filter { $0.phase == .idle }
    }

    var activeClaudeSessionCount: Int {
        activeSessions.filter { $0.agentSource == .claude }.count
    }

    var activeCodexSessionCount: Int {
        activeSessions.filter { $0.agentSource != .claude }.count
    }

    var runningClaudeSessionCount: Int {
        runningSessions.filter { $0.agentSource == .claude }.count
    }

    var runningCodexSessionCount: Int {
        runningSessions.filter { $0.agentSource != .claude }.count
    }

    var totalActiveSubagents: Int {
        activeSessions.reduce(0) { $0 + $1.activeSubagentCount }
    }

    var totalCompactCount: Int {
        activeSessions.filter { $0.isCompacting }.count
    }

    // MARK: - Event Recording

    func recordEvent(_ event: AgentEvent) {
        guard let sessionId = event.sessionId, !sessionId.isEmpty else { return }

        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            sessions[index].agentSource = event.agentSource
            sessions[index].eventCount += 1
            sessions[index].lastEventAt = Date()
            if let toolName = event.toolName {
                sessions[index].lastToolName = toolName
            }
            if let path = event.transcriptPath, sessions[index].transcriptPath == nil {
                sessions[index].transcriptPath = path
            }
            if let pid = event.shellPid, sessions[index].shellPid == nil {
                sessions[index].shellPid = pid
            }

            // Reactivate ended sessions when active-work events arrive
            // (handles app restart while Claude Code is mid-session)
            if sessions[index].status == .ended {
                let reactivatingEvents: Set<HookEventType> = [
                    .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
                    .permissionRequest, .preCompact, .subagentStart
                ]
                if let eventType = event.eventType, reactivatingEvents.contains(eventType) {
                    sessions[index].status = .active
                    sessions[index].phase = (eventType == .sessionStart) ? .idle : .running
                    sessions[index].isCompacting = eventType == .preCompact
                    sessions[index].activeSubagentCount = 0
                } else {
                    // Truly stale event (e.g. Stop, SessionEnd) — count it but skip transitions
                    persist()
                    return
                }
            }

            // State machine transitions
            switch event.eventType {
            case .sessionStart:
                sessions[index].status = .active
                sessions[index].phase = .idle
                sessions[index].isCompacting = false
                if let pid = event.terminalPid {
                    sessions[index].terminalPid = pid
                }
                if let pid = event.shellPid {
                    sessions[index].shellPid = pid
                }

            case .userPromptSubmit:
                sessions[index].phase = .running

            case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest:
                // Tool activity confirms agent is working
                sessions[index].phase = .running

            case .preCompact:
                sessions[index].phase = .compacting
                sessions[index].isCompacting = true

            case .stop:
                sessions[index].phase = .idle
                sessions[index].isCompacting = false

            case .sessionEnd:
                sessions[index].status = .ended
                sessions[index].phase = .idle
                sessions[index].activeSubagentCount = 0
                sessions[index].isCompacting = false
                onPhasesChanged?()

            case .subagentStart:
                sessions[index].activeSubagentCount += 1

            case .subagentStop:
                sessions[index].activeSubagentCount = max(0, sessions[index].activeSubagentCount - 1)

            default:
                break
            }
        } else {
            // New session
            let phase: AgentSession.Phase = event.eventType == .userPromptSubmit ? .running : .idle
            var session = AgentSession(
                id: sessionId,
                projectDir: event.cwd,
                projectName: event.projectName,
                agentSource: event.agentSource,
                status: .active,
                phase: phase,
                eventCount: 1,
                startedAt: Date(),
                lastEventAt: Date()
            )
            session.terminalPid = event.terminalPid
            session.shellPid = event.shellPid
            session.transcriptPath = event.transcriptPath
            sessions.insert(session, at: 0)
        }
        persist()
    }

    func upsertCodexSnapshot(_ snapshot: CodexSessionSnapshot) {
        let phase: AgentSession.Phase = snapshot.isTaskActive ? .running : .idle

        if let index = sessions.firstIndex(where: { $0.id == snapshot.sessionID }) {
            sessions[index].agentSource = snapshot.source
            sessions[index].status = .active
            sessions[index].phase = phase
            sessions[index].projectDir = snapshot.cwd
            if let cwd = snapshot.cwd {
                sessions[index].projectName = URL(fileURLWithPath: cwd).lastPathComponent
            }
            sessions[index].lastEventAt = snapshot.lastEventAt ?? sessions[index].lastEventAt
        } else {
            let projectName = snapshot.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            let session = AgentSession(
                id: snapshot.sessionID,
                projectDir: snapshot.cwd,
                projectName: projectName,
                agentSource: snapshot.source,
                status: .active,
                phase: phase,
                eventCount: 0,
                startedAt: snapshot.lastEventAt ?? Date(),
                lastEventAt: snapshot.lastEventAt
            )
            sessions.insert(session, at: 0)
        }

        persist()
        onPhasesChanged?()
    }
}

extension SessionStore {
    var codexSessions: [AgentSession] {
        sessions.filter { $0.agentSource != .claude }
    }

    var codexSessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
    }
}
