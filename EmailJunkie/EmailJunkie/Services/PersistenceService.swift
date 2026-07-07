import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.EmailJunkie", category: "Persistence")

/// Persistence operations used by `AppState`.
///
/// An in-memory implementation can be substituted in tests so they never
/// touch real disk. Secrets (OAuth tokens, API keys) are **not** stored here —
/// those go through the Keychain in a later milestone.
protocol PersistenceProvider {
    func loadSettings() -> Settings
    func saveSettings(_ settings: Settings)
    func saveSettingsSync(_ settings: Settings) throws

    /// The stored voice profile, or `nil` if the user hasn't learned one yet.
    func loadVoiceProfile() -> VoiceProfile?
    /// Persists the voice profile (replaces any existing one).
    func saveVoiceProfile(_ profile: VoiceProfile)
    /// Removes the stored voice profile.
    func removeVoiceProfile()
}

/// File-based persistence for non-secret application settings.
///
/// Data is stored as JSON in `~/Library/Application Support/EmailJunkie/`.
/// Writes are atomic and happen off the main thread.
final class PersistenceService: PersistenceProvider {

    // MARK: - Singleton

    static let shared = PersistenceService()

    // MARK: - Properties

    private let settingsURL: URL
    private let voiceProfileURL: URL
    private let ioQueue = DispatchQueue(label: "com.tookes.EmailJunkie.persistence", qos: .utility)

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let directory = appSupport.appendingPathComponent("EmailJunkie", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("Settings.json")
        voiceProfileURL = directory.appendingPathComponent("VoiceProfile.json")
    }

    // MARK: - Settings

    func loadSettings() -> Settings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            logger.debug("No settings file, using defaults")
            return .default
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try decoder.decode(Settings.self, from: data)
            return settings.validated()
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription)")
            return .default
        }
    }

    func saveSettings(_ settings: Settings) {
        let validated = settings.validated()
        ioQueue.async { [encoder, settingsURL] in
            do {
                let data = try encoder.encode(validated)
                try data.write(to: settingsURL, options: .atomic)
            } catch {
                logger.error("Failed to save settings: \(error.localizedDescription)")
            }
        }
    }

    func saveSettingsSync(_ settings: Settings) throws {
        let validated = settings.validated()
        do {
            try ioQueue.sync { [encoder, settingsURL] in
                let data = try encoder.encode(validated)
                try data.write(to: settingsURL, options: .atomic)
            }
        } catch {
            logger.error("Failed to save settings (sync): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Voice Profile

    func loadVoiceProfile() -> VoiceProfile? {
        guard FileManager.default.fileExists(atPath: voiceProfileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: voiceProfileURL)
            return try decoder.decode(VoiceProfile.self, from: data)
        } catch {
            logger.error("Failed to load voice profile: \(error.localizedDescription)")
            return nil
        }
    }

    func saveVoiceProfile(_ profile: VoiceProfile) {
        ioQueue.async { [encoder, voiceProfileURL] in
            do {
                let data = try encoder.encode(profile)
                try data.write(to: voiceProfileURL, options: .atomic)
            } catch {
                logger.error("Failed to save voice profile: \(error.localizedDescription)")
            }
        }
    }

    func removeVoiceProfile() {
        ioQueue.async { [voiceProfileURL] in
            try? FileManager.default.removeItem(at: voiceProfileURL)
        }
    }
}
