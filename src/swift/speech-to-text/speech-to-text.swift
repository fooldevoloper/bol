import SwiftUI

// Speech-to-text providers are plugins. To add one:
//  1. add a case to `SpeechToTextProviderID`,
//  2. write a `SpeechToTextProvider` in providers/ (its session, settings and settings UI),
//  3. return it from `SpeechToTextProviders.provider(id:)`, and add its settings to
//     `SpeechToTextSettings` if it has any.
// The compiler points at every switch that must handle the new case.

enum SpeechToTextProviderID: String, Codable, CaseIterable, Identifiable {
	case apple, gemini, openai
	var id: String { rawValue }

	init(from decoder: Decoder) throws {
		let raw = try decoder.singleValueContainer().decode(String.self)
		self = SpeechToTextProviderID(rawValue: raw) ?? .apple
	}
}

struct SpeechToTextSettings: Codable, Equatable {
	var provider = SpeechToTextProviderID.apple
	var apple = AppleSpeechToText.Settings()
	var gemini = GeminiSpeechToText.Settings()
	var openai = OpenAISpeechToText.Settings()

	init() {}

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		provider = try c.decodeIfPresent(SpeechToTextProviderID.self, forKey: .provider) ?? .apple
		apple = try c.decodeIfPresent(AppleSpeechToText.Settings.self, forKey: .apple) ?? AppleSpeechToText.Settings()
		gemini =
			try c.decodeIfPresent(GeminiSpeechToText.Settings.self, forKey: .gemini) ?? GeminiSpeechToText.Settings()
		openai =
			try c.decodeIfPresent(OpenAISpeechToText.Settings.self, forKey: .openai) ?? OpenAISpeechToText.Settings()
	}
}

protocol SpeechToTextProvider {
	var id: SpeechToTextProviderID { get }
	var title: String { get }
	var subtitle: String { get }
	/// SF Symbol name.
	var icon: String { get }
	var credential: ProviderCredential { get }
	func makeSession(config: Config) -> SpeechToTextSession
	/// Provider-specific rows for Settings → Listening.
	@MainActor func settingsSection(model: SettingsModel) -> AnyView
}

enum SpeechToTextProviders {
	static func provider(id: SpeechToTextProviderID) -> SpeechToTextProvider {
		switch id {
		case .apple: return AppleSpeechToText()
		case .gemini: return GeminiSpeechToText()
		case .openai: return OpenAISpeechToText()
		}
	}

	static var all: [SpeechToTextProvider] { SpeechToTextProviderID.allCases.map { provider(id: $0) } }

	/// The provider actually used: one whose credential is missing falls back to Apple Speech (built in).
	static func active(config: Config) -> SpeechToTextProvider {
		let chosen = provider(id: config.speechToText.provider)
		return chosen.credential.isSatisfied(by: config) ? chosen : AppleSpeechToText()
	}
}

struct Transcript {
	let text: String
	/// Streaming providers send growing interim text, then a final one per segment.
	let isFinal: Bool
}

/// One utterance. Audio is 16 kHz mono signed 16-bit PCM.
protocol SpeechToTextSession: AnyObject {
	var onTranscript: ((Transcript) -> Void)? { get set }
	/// Why transcription failed, worded for the user (see `ServiceDiagnosis`).
	var onError: ((ServiceProblem) -> Void)? { get set }
	/// Called once, after `flush()` produced its final text (or failed).
	var onFinished: (() -> Void)? { get set }
	/// Whether text arrives while the user is still speaking.
	var isStreamingInterim: Bool { get }

	func start()
	func send(pcm: Data)
	func flush()
	func cancel()
}
