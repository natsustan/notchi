import Foundation
import Darwin
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    let sessionStore = SessionStore.shared

    private var emotionDecayTimer: Task<Void, Never>?
    private var pendingSyncTasks: [ProviderSessionKey: Task<Void, Never>] = [:]
    private var pendingPositionMarks: [ProviderSessionKey: Task<Void, Never>] = [:]
    private var pendingCodexSessionStartTimes: [ProviderSessionKey: Date] = [:]
    private var codexProcessMonitorTask: Task<Void, Never>?
    private var codexProcessMissCounts: [ProviderSessionKey: Int] = [:]
    private var fileWatchers: [ProviderSessionKey: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
    var handleClaudeUsageResumeTrigger: (ClaudeUsageResumeTrigger) -> Void = { trigger in
        ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
    }
    var isCodexProcessAlive: (Int) -> Bool

    private static let syncDebounce: Duration = .milliseconds(100)
    private static let waitingClearGuard: TimeInterval = 2.0
    private static let codexProcessMonitorInterval: Duration = .seconds(2)
    private static let codexProcessMissLimit = 2

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        isCodexProcessAlive = Self.defaultCodexProcessAlive
        startEmotionDecayTimer()
    }

    func handleEvent(_ event: HookEvent) {
        let transcriptPath = ConversationParser.resolvedTranscriptPath(
            for: event.provider,
            sessionId: event.rawSessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath
        )
        let isDone = event.status == "waiting_for_input"

        // WHY: Codex emits SessionStart before there is any user-visible content for a
        // brand new chat. Start watching immediately, but don't surface a blank session
        // until later events give us real prompt/reply/tool content.
        if event.provider == .codex,
           event.event == .sessionStarted,
           sessionStore.session(for: event.sessionKey) == nil {
            pendingCodexSessionStartTimes[event.sessionKey] = Date()
            refreshCodexSessionStartTracking(
                sessionKey: event.sessionKey,
                transcriptPath: transcriptPath,
                isInteractive: event.interactive ?? true
            )

            return
        }

        let sessionStartTimeOverride = pendingSessionStartTimeOverride(for: event)
        let session = sessionStore.process(event, sessionStartTimeOverride: sessionStartTimeOverride)
        refreshCodexProcessMonitoring()

        switch event.event {
        case .userPromptSubmitted:
            if let transcriptPath {
                pendingPositionMarks[event.sessionKey] = Task {
                    await ConversationParser.shared.markCurrentPosition(
                        sessionKey: event.sessionKey,
                        transcriptPath: transcriptPath
                    )
                }
            } else {
                pendingPositionMarks.removeValue(forKey: event.sessionKey)?.cancel()
            }

            if session.isInteractive, let transcriptPath {
                startFileWatcher(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
            }

            if session.isInteractive,
               event.provider.capabilities.supportsPromptEmotionAnalysis,
               let prompt = event.userPrompt {
                Task {
                    let result = await EmotionAnalyzer.shared.analyze(prompt)
                    session.emotionState.recordEmotion(result.emotion, intensity: result.intensity, prompt: prompt)
                }
            }

            if session.isInteractive,
               event.provider.capabilities.supportsUsageResumeTriggers,
               !SessionStore.isLocalSlashCommand(event.userPrompt) {
                handleClaudeUsageResumeTrigger(.userPromptSubmit)
            }

        case .preToolUse:
            if isDone {
                SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            }

        case .permissionRequest:
            if event.provider.capabilities.supportsPermissionPrompts {
                SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            }

        case .postToolUse:
            if let transcriptPath {
                scheduleFileSync(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
            }

        case .sessionStarted:
            if event.provider == .codex {
                // WHY: Existing Codex sessions can emit SessionStart on resume,
                // and we still want to refresh the parser baseline/watcher even
                // though the visible session already exists.
                refreshCodexSessionStartTracking(
                    sessionKey: event.sessionKey,
                    transcriptPath: transcriptPath,
                    isInteractive: session.isInteractive
                )
            }

            if event.provider.capabilities.supportsUsageResumeTriggers {
                handleClaudeUsageResumeTrigger(.sessionStart)
            }

        case .stop:
            SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            stopFileWatcher(sessionKey: event.sessionKey)
            if let transcriptPath {
                scheduleFileSync(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
            }

        case .sessionEnded:
            pendingCodexSessionStartTimes.removeValue(forKey: event.sessionKey)
            stopFileWatcher(sessionKey: event.sessionKey)
            pendingSyncTasks.removeValue(forKey: event.sessionKey)?.cancel()
            pendingPositionMarks.removeValue(forKey: event.sessionKey)?.cancel()
            SoundService.shared.clearCooldown(for: event.sessionKey)
            Task { await ConversationParser.shared.resetState(for: event.sessionKey) }
            if sessionStore.activeSessionCount == 0 {
                logger.info("Global state: idle")
            }
            refreshCodexProcessMonitoring()
            return

        default:
            if isDone && session.task != .idle {
                SoundService.shared.playNotificationSound(sessionKey: event.sessionKey, isInteractive: session.isInteractive)
            }
        }

        session.resetSleepTimer()
    }

    private func scheduleFileSync(sessionKey: ProviderSessionKey, transcriptPath: String) {
        pendingSyncTasks[sessionKey]?.cancel()
        pendingSyncTasks[sessionKey] = Task {
            await pendingPositionMarks[sessionKey]?.value

            try? await Task.sleep(for: Self.syncDebounce)
            guard !Task.isCancelled else { return }

            let result = await ConversationParser.shared.parseIncremental(
                sessionKey: sessionKey,
                transcriptPath: transcriptPath
            )

            applyParsedSessionEvents(result.events, for: sessionKey)

            if !result.messages.isEmpty {
                sessionStore.recordAssistantMessages(result.messages, for: sessionKey)
            }

            reconcileFileSyncResult(
                result,
                for: sessionKey,
                hasActiveWatcher: fileWatchers[sessionKey] != nil
            )

            pendingSyncTasks.removeValue(forKey: sessionKey)
        }
    }

    private func refreshCodexSessionStartTracking(
        sessionKey: ProviderSessionKey,
        transcriptPath: String?,
        isInteractive: Bool
    ) {
        guard let transcriptPath else { return }

        pendingPositionMarks[sessionKey] = Task {
            await ConversationParser.shared.markCurrentPosition(
                sessionKey: sessionKey,
                transcriptPath: transcriptPath
            )
        }

        if isInteractive {
            startFileWatcher(sessionKey: sessionKey, transcriptPath: transcriptPath)
        }
    }

    private func pendingSessionStartTimeOverride(for event: HookEvent) -> Date? {
        guard event.provider == .codex,
              sessionStore.session(for: event.sessionKey) == nil else {
            return nil
        }

        return pendingCodexSessionStartTimes.removeValue(forKey: event.sessionKey)
    }

    func applyParsedSessionEvents(_ events: [ParsedSessionEvent], for sessionKey: ProviderSessionKey) {
        guard !events.isEmpty,
              let session = sessionStore.session(for: sessionKey) else { return }

        for event in events {
            _ = sessionStore.process(
                HookEvent(
                    provider: session.provider,
                    rawSessionId: session.rawSessionId,
                    transcriptPath: nil,
                    cwd: session.cwd,
                    event: event.event,
                    status: event.status,
                    tool: event.tool,
                    toolInput: event.toolInput,
                    toolUseId: event.toolUseId,
                    userPrompt: nil,
                    permissionMode: nil,
                    interactive: session.isInteractive
                )
            )
        }
    }

    func reconcileFileSyncResult(_ result: ParseResult, for sessionKey: ProviderSessionKey, hasActiveWatcher: Bool) {
        guard let session = sessionStore.session(for: sessionKey) else { return }

        if !result.messages.isEmpty,
           session.isInteractive,
           hasActiveWatcher,
           session.task == .idle || session.task == .sleeping {
            session.updateTask(.working)
            session.updateProcessingState(isProcessing: true)
        }

        if result.interrupted && session.task == .working {
            session.updateTask(.idle)
            session.updateProcessingState(isProcessing: false)
        } else if session.task == .waiting,
                  Date().timeIntervalSince(session.lastActivity) > Self.waitingClearGuard {
            session.clearPendingQuestions()
            session.updateTask(.working)
        }
    }

    private func reconcileCodexProcessLiveness() {
        let trackedSessions = sessionStore.sessions.values.filter { $0.isCodexCLIProcessBacked }
        let trackedKeys = Set(trackedSessions.map(\.sessionKey))
        codexProcessMissCounts = codexProcessMissCounts.filter { trackedKeys.contains($0.key) }

        var endedSessions: [SessionData] = []

        for session in trackedSessions {
            guard let processId = session.codexProcessId else { continue }

            if isCodexProcessAlive(processId) {
                codexProcessMissCounts.removeValue(forKey: session.sessionKey)
                continue
            }

            let missCount = (codexProcessMissCounts[session.sessionKey] ?? 0) + 1
            codexProcessMissCounts[session.sessionKey] = missCount

            if missCount >= Self.codexProcessMissLimit {
                endedSessions.append(session)
            }
        }

        for session in endedSessions {
            logger.info(
                "Codex CLI process \(session.codexProcessId ?? -1, privacy: .public) exited; ending session \(session.sessionKey.stableId, privacy: .public)"
            )
            codexProcessMissCounts.removeValue(forKey: session.sessionKey)
            handleEvent(
                HookEvent(
                    provider: .codex,
                    rawSessionId: session.rawSessionId,
                    transcriptPath: nil,
                    cwd: session.cwd,
                    event: .sessionEnded,
                    status: "ended",
                    interactive: session.isInteractive,
                    codexProcessId: session.codexProcessId,
                    codexOrigin: session.codexOrigin
                )
            )
        }

        refreshCodexProcessMonitoring()
    }

    private func startFileWatcher(sessionKey: ProviderSessionKey, transcriptPath: String) {
        stopFileWatcher(sessionKey: sessionKey)

        let fd = open(transcriptPath, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open file for watching: \(transcriptPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleFileSync(sessionKey: sessionKey, transcriptPath: transcriptPath)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[sessionKey] = (source: source, fd: fd)
        logger.debug("Started file watcher for session \(sessionKey.stableId, privacy: .public)")
    }

    private func stopFileWatcher(sessionKey: ProviderSessionKey) {
        guard let watcher = fileWatchers.removeValue(forKey: sessionKey) else { return }
        watcher.source.cancel()
        logger.debug("Stopped file watcher for session \(sessionKey.stableId, privacy: .public)")
    }

    private func startEmotionDecayTimer() {
        emotionDecayTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: EmotionState.decayInterval)
                guard !Task.isCancelled else { return }
                for session in sessionStore.sessions.values {
                    session.emotionState.decayAll()
                }
            }
        }
    }

    private func refreshCodexProcessMonitoring() {
        let shouldMonitor = sessionStore.sessions.values.contains { $0.isCodexCLIProcessBacked }

        if shouldMonitor {
            guard codexProcessMonitorTask == nil else { return }
            codexProcessMonitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.codexProcessMonitorInterval)
                    guard !Task.isCancelled else { return }
                    self?.reconcileCodexProcessLiveness()
                }
            }
        } else {
            codexProcessMonitorTask?.cancel()
            codexProcessMonitorTask = nil
            codexProcessMissCounts.removeAll()
        }
    }

    private nonisolated static func defaultCodexProcessAlive(_ processId: Int) -> Bool {
        guard processId > 0, processId <= Int(Int32.max) else { return false }

        errno = 0
        let result = kill(pid_t(processId), 0)
        return result == 0 || errno == EPERM
    }

    func resetTestingHooks() {
        handleClaudeUsageResumeTrigger = { trigger in
            ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
        }
        isCodexProcessAlive = Self.defaultCodexProcessAlive
        codexProcessMonitorTask?.cancel()
        codexProcessMonitorTask = nil
        codexProcessMissCounts.removeAll()
    }

#if DEBUG
    func reconcileCodexProcessLivenessForTesting() {
        reconcileCodexProcessLiveness()
    }
#endif

}
