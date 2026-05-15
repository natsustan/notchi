import AppKit
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.ruban.notchi", category: "SoundService")

@MainActor
@Observable
final class SoundService {
    static let shared = SoundService()

    private static let cooldown: TimeInterval = 2.0
    @ObservationIgnored
    private var lastSoundTimes: [ProviderSessionKey: Date] = [:]
    @ObservationIgnored
    private var activeCustomPlayers: [UUID: AVAudioPlayer] = [:]

    private init() {}

    func playNotificationSound(sessionKey: ProviderSessionKey, isInteractive: Bool) {
        guard isInteractive else {
            logger.debug("Non-interactive session, skipping sound")
            return
        }

        let selection = AppSettings.notificationSoundSelection
        guard selection != .system(.none) else {
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
        playSound(selection)
    }

    func clearCooldown(for sessionKey: ProviderSessionKey) {
        lastSoundTimes.removeValue(forKey: sessionKey)
    }

    func previewSound(_ sound: NotificationSound) {
        playSound(.system(sound))
    }

    func previewSound(_ selection: NotificationSoundSelection) {
        playSound(selection)
    }

    private func playSound(_ selection: NotificationSoundSelection) {
        switch selection {
        case .system(let sound):
            guard let soundName = sound.soundName else { return }
            playSystemSound(named: soundName)
        case .custom(let id):
            guard let customSound = AppSettings.customNotificationSounds.first(where: { $0.id == id }),
                  let url = AppSettings.customNotificationSoundURL(for: customSound) else {
                logger.warning("Custom sound not found: \(id.uuidString, privacy: .public)")
                return
            }
            playCustomSound(id: id, url: url)
        }
    }

    private func playSystemSound(named soundName: String) {
        guard let nsSound = NSSound(named: NSSound.Name(soundName)) else {
            logger.warning("Sound not found: \(soundName, privacy: .public)")
            return
        }
        nsSound.play()
        logger.debug("Playing sound: \(soundName, privacy: .public)")
    }

    private func playCustomSound(id: UUID, url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            activeCustomPlayers[id] = player
            player.play()
            logger.debug("Playing custom sound: \(url.lastPathComponent, privacy: .public)")

            let nanoseconds = UInt64((max(player.duration, 0.1) + 0.5) * 1_000_000_000)
            Task { [weak self, weak player] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    guard let self,
                          let player,
                          self.activeCustomPlayers[id] === player else {
                        return
                    }
                    self.activeCustomPlayers[id] = nil
                }
            }
        } catch {
            logger.warning("Failed to play custom sound: \(error.localizedDescription, privacy: .public)")
        }
    }
}
