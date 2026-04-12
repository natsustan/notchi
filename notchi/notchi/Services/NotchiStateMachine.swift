import Foundation
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
    private var fileWatchers: [ProviderSessionKey: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]
    var handleClaudeUsageResumeTrigger: (ClaudeUsageResumeTrigger) -> Void = { trigger in
        ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
    }

    private static let syncDebounce: Duration = .milliseconds(100)
    private static let waitingClearGuard: TimeInterval = 2.0

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        startEmotionDecayTimer()
    }

    func handleEvent(_ event: HookEvent) {
        let session = sessionStore.process(event)
        let isDone = event.status == "waiting_for_input"
        let transcriptPath = ConversationParser.resolvedTranscriptPath(
            for: event.provider,
            sessionId: event.rawSessionId,
            cwd: event.cwd,
            transcriptPath: event.transcriptPath
        )

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
            if event.provider == .codex, let transcriptPath {
                pendingPositionMarks[event.sessionKey] = Task {
                    await ConversationParser.shared.markCurrentPosition(
                        sessionKey: event.sessionKey,
                        transcriptPath: transcriptPath
                    )
                }

                if session.isInteractive {
                    startFileWatcher(sessionKey: event.sessionKey, transcriptPath: transcriptPath)
                }
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
            stopFileWatcher(sessionKey: event.sessionKey)
            pendingSyncTasks.removeValue(forKey: event.sessionKey)?.cancel()
            pendingPositionMarks.removeValue(forKey: event.sessionKey)?.cancel()
            SoundService.shared.clearCooldown(for: event.sessionKey)
            Task { await ConversationParser.shared.resetState(for: event.sessionKey) }
            if sessionStore.activeSessionCount == 0 {
                logger.info("Global state: idle")
            }
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

    func resetTestingHooks() {
        handleClaudeUsageResumeTrigger = { trigger in
            ClaudeUsageService.shared.handleClaudeResumeTrigger(trigger)
        }
    }

}
