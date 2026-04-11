import AppKit
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SoundService")

@MainActor
@Observable
final class SoundService {
    static let shared = SoundService()

    private static let cooldown: TimeInterval = 2.0
    @ObservationIgnored
    private var lastSoundTimes: [ProviderSessionKey: Date] = [:]

    private init() {}

    func playNotificationSound(sessionKey: ProviderSessionKey, isInteractive: Bool) {
        guard isInteractive else {
            logger.debug("Non-interactive session, skipping sound")
            return
        }

        let sound = AppSettings.notificationSound
        guard let soundName = sound.soundName else {
            logger.debug("Notification sound disabled")
            return
        }

        if TerminalFocusDetector.isTerminalFocused() {
            logger.debug("Terminal focused, skipping notification sound")
            return
        }

        let now = Date()
        if let lastPlayed = lastSoundTimes[sessionKey],
           now.timeIntervalSince(lastPlayed) < Self.cooldown {
            logger.debug("Sound cooldown active for session \(sessionKey.stableId, privacy: .public)")
            return
        }

        lastSoundTimes[sessionKey] = now
        playSound(named: soundName)
    }

    func clearCooldown(for sessionKey: ProviderSessionKey) {
        lastSoundTimes.removeValue(forKey: sessionKey)
    }

    func previewSound(_ sound: NotificationSound) {
        guard let soundName = sound.soundName else { return }
        playSound(named: soundName)
    }

    private func playSound(named soundName: String) {
        guard let nsSound = NSSound(named: NSSound.Name(soundName)) else {
            logger.warning("Sound not found: \(soundName, privacy: .public)")
            return
        }
        nsSound.play()
        logger.debug("Playing sound: \(soundName, privacy: .public)")
    }
}
