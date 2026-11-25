import Foundation

/// User-editable settings, persisted at ~/.bol/config.json.
///
/// Every field declares its default right here: on load, the stored JSON is laid over the
/// defaults, so a missing key (new setting, older file) simply takes its default.
struct Config: Codable, Equatable {
	var apiKeys = APIKeys()
	var textToSpeech = TextToSpeechSettings()
	var speechToText = SpeechToTextSettings()
	/// Hold a key in any app, speak, let go: the text is pasted where you're typing.
	var dictation = DictationSettings()
	/// Bol's global shortcuts (⌘J to talk…), each changeable or off in Settings → Shortcuts.
	var shortcuts = ShortcutSettings()

	var isFollowUpEnabled = true
	var followUpSeconds = 6.0
	/// Unused: pauses no longer end a turn (Enter sends). Kept so existing config files round-trip.
	var endOfSpeechSeconds = 1.4
	/// Show replies in the voice bar without speaking them.
	var isSilentMode = false
	/// What other apps' sound does while Bol listens or speaks.
	var otherAudio = OtherAudioBehavior.lower
	/// What `lower` takes other apps down to: a share of their volume.
	var otherAudioLevel = 0.2

	var isChromeEnabled = true
	var screenAccess = ScreenAccess.auto
	var agentModel = AgentModel.auto
	var agentEffort = AgentEffort.medium
	/// nil = Bol's own workspace (~/.bol/workspace), which keeps its sessions apart from yours.
	var workingDirectory: String? = nil
	/// Download new versions in the background and install them when Bol is idle (Settings → General).
	var isAutoUpdateEnabled = true
	/// The first-run setup was finished (it checks Antigravity CLI, sign-in, the mic and the voice).
	var hasCompletedOnboarding = false
	/// The Terms and Privacy Policy the user agreed to in setup, and when. Kept only on this Mac.
	var acceptedTerms: AcceptedTerms? = nil

	/// Bol starts only once the current Terms are agreed to (see `Constants.termsVersion`).
	var hasAcceptedCurrentTerms: Bool { acceptedTerms?.version == Constants.termsVersion }
}

struct AcceptedTerms: Codable, Equatable {
	let version: String
	/// ISO 8601, e.g. "2026-11-25T13:40:00Z".
	let acceptedAt: String

	static func now() -> AcceptedTerms {
		AcceptedTerms(version: Constants.termsVersion, acceptedAt: ISO8601DateFormatter().string(from: Date()))
	}
}

/// The models Antigravity offers via ACP. Unknown stored values fall back to `auto`.
enum AgentModel: String, Codable, CaseIterable {
	case auto = "default"
	case geminiHydrogen = "gemini-4-hydrogen"
	case geminiFlash = "gemini-3.8-flash"
	case claudeSonnet = "claude-sonnet-4-6"
	case claudeOpus = "claude-opus-4-6-thinking"

	init(from decoder: Decoder) throws {
		self = AgentModel(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .auto
	}

	var title: String {
		switch self {
		case .auto: return "Antigravity default"
		case .geminiHydrogen: return "Gemini 4 Hydrogen"
		case .geminiFlash: return "Gemini 3.8 Flash"
		case .claudeSonnet: return "Claude Sonnet 4.6"
		case .claudeOpus: return "Claude Opus 4.6"
		}
	}

	var subtitle: String {
		switch self {
		case .auto: return "Recommended: follows your Antigravity configuration"
		case .geminiHydrogen: return "Frontier Gemini reasoning at voice speed"
		case .geminiFlash: return "Faster replies for quick tasks"
		case .claudeSonnet: return "Balanced Sonnet via Antigravity"
		case .claudeOpus: return "Most capable reasoning via Antigravity"
		}
	}
}

/// How hard Antigravity thinks before answering. Bol never goes below medium: a voice request is a real task,
/// and lighter thinking gets it wrong. A `low` saved by an older version reads as medium.
enum AgentEffort: String, Codable, CaseIterable {
	case medium, high, xhigh, max

	init(from decoder: Decoder) throws {
		self = AgentEffort(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .medium
	}

	var title: String {
		switch self {
		case .medium: return "Medium"
		case .high: return "High"
		case .xhigh: return "Extra high"
		case .max: return "Max"
		}
	}

	var subtitle: String {
		switch self {
		case .medium: return "Recommended: quick and capable (the minimum)"
		case .high: return "More thorough, slower"
		case .xhigh: return "Deep work on hard tasks"
		case .max: return "Slowest, thinks the longest"
		}
	}
}

/// Other apps' sound while Bol listens or speaks. Lower and mute keep Bol's own voice as it is.
enum OtherAudioBehavior: String, Codable, CaseIterable {
	case lower, mute, pauseMedia, nothing

	var title: String {
		switch self {
		case .lower: return "Lower audio"
		case .mute: return "Mute"
		case .pauseMedia: return "Pause media"
		case .nothing: return "Do nothing"
		}
	}

	var subtitle: String {
		switch self {
		case .lower: return "Turn other apps down"
		case .mute: return "Silence other apps"
		case .pauseMedia: return "Music, Spotify and VLC"
		case .nothing: return "Leave other apps alone"
		}
	}
}

/// Whether the agent may see and operate the screen: screenshots, pointer and keyboard.
/// A stored value that isn't one of these (older builds offered "ask") becomes `auto`.
enum ScreenAccess: String, Codable, CaseIterable {
	case auto, off

	init(from decoder: Decoder) throws {
		self = ScreenAccess(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .auto
	}
}

// MARK: - Persistence

extension Config {
	private static let saveQueue = DispatchQueue(label: "bol.config")

	/// Reads the config at launch (before anything else runs, so this one read is synchronous).
	static func load() -> Config {
		try? FileManager.default.createDirectory(at: Constants.bolDirectory, withIntermediateDirectories: true)
		var config = Config()
		do {
			config = try decoded(data: Data(contentsOf: Constants.configFile))
		} catch CocoaError.fileReadNoSuchFile {
			Log.info(message: "config: none yet, using defaults")
		} catch {
			Log.info(message: "config: unreadable (\(error)), using defaults")
		}
		// Keys found elsewhere are adopted into the config, which is the only place they're read from.
		if config.apiKeys[.openai] == nil {
			config.apiKeys[.openai] = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
		}
		if config.apiKeys[.gemini] == nil {
			config.apiKeys[.gemini] = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
		}
		if config.apiKeys[.noiz] == nil {
			let legacyNoizKeyFile = Constants.bolDirectory.appendingPathComponent("noiz_key")
			config.apiKeys[.noiz] = try? String(contentsOf: legacyNoizKeyFile, encoding: .utf8)
		}
		config.save()  // writes back new defaults and the current shape
		return config
	}

	/// Saves in the background; saves run in order, so the last write wins.
	func save() {
		let config = self
		Self.saveQueue.async {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			do {
				try encoder.encode(config).write(to: Constants.configFile, options: .atomic)
				chmod(Constants.configFile.path, 0o600)
			} catch {
				Log.info(message: "config: save failed: \(error)")
			}
		}
	}

	/// A stored config.json (any version), upgraded and laid over the defaults.
	static func decoded(data: Data) throws -> Config {
		guard let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw CocoaError(.fileReadCorruptFile)
		}
		return try decode(
			stored: ConfigMigration.antigravityKeys(
				stored: ConfigMigration.pasteLastToggle(stored: ConfigMigration.migrated(stored: stored))))
	}

	/// Lays `stored` over the defaults, then decodes.
	private static func decode(stored: [String: Any]) throws -> Config {
		let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] ?? [:]
		let merged = merge(base: defaults, overlay: stored)
		return try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
	}

	private static func merge(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
		var result = base
		for (key, value) in overlay {
			if let nested = value as? [String: Any], let baseNested = base[key] as? [String: Any] {
				result[key] = merge(base: baseNested, overlay: nested)
			} else {
				result[key] = value
			}
		}
		return result
	}
}
