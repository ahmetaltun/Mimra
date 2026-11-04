// ==============================================================================
// Mimra — Sound Feedback Service (P7-01 / F-035, F-056, T-SET-01)
// Optional audio feedback on copy and paste actions via native macOS NSSound.
// ==============================================================================

import AppKit
import Foundation

/// Available native macOS sound effects for user selection.
public enum SoundEffect: String, CaseIterable, Identifiable, Sendable {
    case pop = "Pop"
    case tink = "Tink"
    case purr = "Purr"
    case blow = "Blow"

    public var id: String { rawValue }
    public var displayName: String { rawValue }
}

/// Protocol defining sound playback capabilities for testing and headless verification.
public protocol SoundPlaying: Sendable {
    func playSound(named name: String) -> Bool
}

/// Native AppKit sound player implementation using bundled macOS system sounds.
public final class AppKitSoundPlayer: SoundPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var activeSound: NSSound?

    public init() {}

    public func playSound(named name: String) -> Bool {
        let sound: NSSound?
        if let named = NSSound(named: NSSound.Name(name)) {
            sound = named
        } else {
            let fileUrl = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            sound = NSSound(contentsOf: fileUrl, byReference: true)
        }
        guard let s = sound else {
            return false
        }
        s.volume = 1.0
        lock.lock()
        activeSound = s
        lock.unlock()
        return s.play()
    }
}

/// Observable service providing audio feedback on clipboard and paste operations.
@MainActor
public final class SoundFeedbackService: ObservableObject {
    public static let shared = SoundFeedbackService()

    public static let playSoundsKey = "playSounds"
    public static let soundEffectKey = "soundEffect"

    private let soundPlayer: SoundPlaying
    private let userDefaults: UserDefaults

    @Published public var isEnabled: Bool {
        didSet {
            userDefaults.set(isEnabled, forKey: Self.playSoundsKey)
        }
    }

    @Published public var selectedSound: SoundEffect {
        didSet {
            userDefaults.set(selectedSound.rawValue, forKey: Self.soundEffectKey)
        }
    }

    public init(
        soundPlayer: SoundPlaying = AppKitSoundPlayer(),
        userDefaults: UserDefaults = .standard
    ) {
        self.soundPlayer = soundPlayer
        self.userDefaults = userDefaults
        self.isEnabled = userDefaults.bool(forKey: Self.playSoundsKey)

        let savedSound = userDefaults.string(forKey: Self.soundEffectKey) ?? SoundEffect.pop.rawValue
        self.selectedSound = SoundEffect(rawValue: savedSound) ?? .pop
    }

    /// Plays the configured sound effect if audio feedback is enabled.
    @discardableResult
    public func playFeedbackSound() -> Bool {
        guard isEnabled else { return false }
        return soundPlayer.playSound(named: selectedSound.rawValue)
    }

    /// Manually triggers a playback of the selected sound for settings testing.
    @discardableResult
    public func testSound() -> Bool {
        return soundPlayer.playSound(named: selectedSound.rawValue)
    }
}
