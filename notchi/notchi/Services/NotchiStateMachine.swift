import Foundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "StateMachine")

@MainActor
@Observable
final class NotchiStateMachine {
    static let shared = NotchiStateMachine()

    let sessionStore = SessionStore.shared

    private var sleepTimer: Task<Void, Never>?
    private var pendingSyncTasks: [String: Task<Void, Never>] = [:]
    private var pendingPositionMarks: [String: Task<Void, Never>] = [:]
    private var fileWatchers: [String: (source: DispatchSourceFileSystemObject, fd: Int32)] = [:]

    private static let sleepDelay: Duration = .seconds(300)
    private static let syncDebounce: Duration = .milliseconds(100)

    var currentState: NotchiState {
        sessionStore.effectiveSession?.state ?? .idle
    }

    private init() {
        startSleepTimer()
    }

    func handleEvent(_ event: HookEvent) {
        cancelSleepTimer()

        let session = sessionStore.process(event)
        let isDone = event.status == "waiting_for_input"

        switch event.event {
        case "UserPromptSubmit":
            pendingPositionMarks[event.sessionId] = Task {
                await ConversationParser.shared.markCurrentPosition(
                    sessionId: event.sessionId,
                    cwd: event.cwd
                )
            }
            startFileWatcher(sessionId: event.sessionId, cwd: event.cwd)

        case "PreToolUse":
            if isDone {
                SoundService.shared.playNotificationSound()
            }

        case "PermissionRequest":
            SoundService.shared.playNotificationSound()

        case "PostToolUse":
            scheduleFileSync(sessionId: event.sessionId, cwd: event.cwd)

        case "Stop":
            SoundService.shared.playNotificationSound()
            stopFileWatcher(sessionId: event.sessionId)
            scheduleFileSync(sessionId: event.sessionId, cwd: event.cwd)

        case "SessionEnd":
            stopFileWatcher(sessionId: event.sessionId)
            if sessionStore.activeSessionCount == 0 {
                transitionGlobal(to: .idle)
            }

        default:
            if isDone && session.state != .idle {
                SoundService.shared.playNotificationSound()
            }
        }

        startSleepTimer()
    }

    private func transitionGlobal(to newState: NotchiState) {
        logger.info("Global state: \(newState.task.rawValue, privacy: .public)")
    }

    private func startSleepTimer() {
        sleepTimer = Task {
            try? await Task.sleep(for: Self.sleepDelay)
            guard !Task.isCancelled else { return }

            for session in sessionStore.sessions.values {
                session.updateState(.sleeping)
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = nil
    }

    private func scheduleFileSync(sessionId: String, cwd: String) {
        pendingSyncTasks[sessionId]?.cancel()
        pendingSyncTasks[sessionId] = Task {
            // Wait for position marking to complete first
            await pendingPositionMarks[sessionId]?.value

            try? await Task.sleep(for: Self.syncDebounce)
            guard !Task.isCancelled else { return }

            let messages = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if !messages.isEmpty {
                sessionStore.recordAssistantMessages(messages, for: sessionId)
            }

            pendingSyncTasks.removeValue(forKey: sessionId)
        }
    }

    private func startFileWatcher(sessionId: String, cwd: String) {
        stopFileWatcher(sessionId: sessionId)

        let projectDir = cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        let sessionFile = "\(NSHomeDirectory())/.claude/projects/\(projectDir)/\(sessionId).jsonl"

        let fd = open(sessionFile, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open file for watching: \(sessionFile)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleFileSync(sessionId: sessionId, cwd: cwd)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[sessionId] = (source: source, fd: fd)
        logger.debug("Started file watcher for session \(sessionId)")
    }

    private func stopFileWatcher(sessionId: String) {
        guard let watcher = fileWatchers.removeValue(forKey: sessionId) else { return }
        watcher.source.cancel()
        logger.debug("Stopped file watcher for session \(sessionId)")
    }
}
