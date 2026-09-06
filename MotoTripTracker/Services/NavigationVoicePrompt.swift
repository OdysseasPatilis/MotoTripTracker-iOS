import AVFoundation
import Foundation

/// Speaks turn-by-turn prompts with a clear English system voice.
/// MapKit maneuver text is English, so we keep speech in English (not a localized accent).
@MainActor
final class NavigationVoicePrompt {
    private let synthesizer = AVSpeechSynthesizer()
    private static let enabledKey = "moto_nav_voice_enabled"

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue {
                stop()
            }
        }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmed.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.preferredEnglishVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private static func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        // Prefer enhanced/premium en-US when the device has it installed.
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en-")
        }
        let enhanced = english.first {
            $0.quality == .enhanced || $0.quality == .premium
        }
        return enhanced
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? AVSpeechSynthesisVoice(language: "en-GB")
            ?? english.first
    }
}
