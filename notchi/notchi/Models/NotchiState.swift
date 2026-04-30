import AppKit

enum NotchiTask: String, CaseIterable {
    case idle, working, sleeping, compacting, waiting

    var animationFPS: Double {
        switch self {
        case .compacting: return 6.0
        case .sleeping: return 2.0
        case .idle, .waiting: return 3.0
        case .working: return 4.0
        }
    }

    var loopDuration: Double {
        Double(frameCount) / animationFPS
    }

    var spritePrefix: String { rawValue }

    var bobDuration: Double {
        switch self {
        case .sleeping:   return 4.0
        case .idle, .waiting: return 1.5
        case .working:    return 0.4
        case .compacting: return 0.5
        }
    }

    var bobAmplitude: CGFloat {
        switch self {
        case .sleeping, .compacting: return 0
        case .idle:                  return 1.5
        case .waiting:               return 0.5
        case .working:               return 0.5
        }
    }

    var canWalk: Bool {
        switch self {
        case .sleeping, .compacting, .waiting:
            return false
        case .idle, .working:
            return true
        }
    }

    var displayName: String {
        switch self {
        case .idle:       return "Idle"
        case .working:    return "Working..."
        case .sleeping:   return "Sleeping"
        case .compacting: return "Compacting..."
        case .waiting:    return "Waiting..."
        }
    }

    var walkFrequencyRange: ClosedRange<Double> {
        switch self {
        case .sleeping, .waiting: return 30.0...60.0
        case .idle:               return 8.0...15.0
        case .working:            return 5.0...12.0
        case .compacting:         return 15.0...25.0
        }
    }

    var frameCount: Int {
        switch self {
        case .compacting: return 5
        default: return 6
        }
    }

    var columns: Int {
        switch self {
        case .compacting: return 5
        default: return 6
        }
    }
}

enum NotchiEmotion: String, CaseIterable {
    case neutral, happy, elated, sad, sob

    var swayAmplitude: Double {
        switch self {
        case .neutral: return 0.5
        case .happy:   return 1.0
        case .elated:  return 1.25
        case .sad:     return 0.25
        case .sob:     return 0.15
        }
    }
}

enum NotchiSpriteFamily: String {
    case claude
}

struct NotchiState: Equatable {
    private static let happyIdleLoopDuration = 2.4

    var task: NotchiTask
    var emotion: NotchiEmotion = .neutral
    var spriteFamily: NotchiSpriteFamily = .claude

    /// Resolves the sprite sheet name with fallback chain: exact emotion -> nearby base emotion -> neutral.
    var spriteSheetName: String {
        let name = spriteSheetName(for: emotion)
        if NSImage(named: name) != nil { return name }
        if emotion == .elated {
            let happyName = spriteSheetName(for: .happy)
            if NSImage(named: happyName) != nil { return happyName }
        }
        if emotion == .sob {
            let sadName = spriteSheetName(for: .sad)
            if NSImage(named: sadName) != nil { return sadName }
        }
        return spriteSheetName(for: .neutral)
    }

    private func spriteSheetName(for emotion: NotchiEmotion) -> String {
        "\(spriteFamily.rawValue)_\(task.spritePrefix)_\(emotion.rawValue)"
    }

    var animationFPS: Double {
        Double(frameCount) / loopDuration
    }

    private var loopDuration: Double {
        if task == .idle, emotion == .happy {
            return Self.happyIdleLoopDuration
        }

        return task.loopDuration
    }
    var bobDuration: Double { task.bobDuration }
    var bobAmplitude: CGFloat {
        switch emotion {
        case .sob: return 0
        case .sad: return task.bobAmplitude * 0.5
        case .elated: return task.bobAmplitude * 1.2
        default:   return task.bobAmplitude
        }
    }
    var swayAmplitude: Double { emotion.swayAmplitude }
    var canWalk: Bool { emotion == .sob ? false : task.canWalk }
    var displayName: String { task.displayName }
    var walkFrequencyRange: ClosedRange<Double> { task.walkFrequencyRange }
    var frameCount: Int { inferredFrameCount ?? task.frameCount }
    var columns: Int { inferredFrameCount ?? task.columns }

    private var inferredFrameCount: Int? {
        guard let image = NSImage(named: spriteSheetName), image.size.height > 0 else {
            return nil
        }

        let frameCount = Int((image.size.width / image.size.height).rounded())
        return frameCount > 0 ? frameCount : nil
    }

    static let idle = NotchiState(task: .idle)
    static let working = NotchiState(task: .working)
    static let sleeping = NotchiState(task: .sleeping)
    static let compacting = NotchiState(task: .compacting)
    static let waiting = NotchiState(task: .waiting)
}
