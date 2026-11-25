import Foundation
import Testing

@testable import Bol

@Suite struct ConfigTests {
	@Test func migratesTheFlatLayout() throws {
		let legacy = """
			{
			  "bargeInEnabled": false, "bargeInThreshold": 0.3, "claudeInChrome": false, "claudeModel": "opus",
			  "confirmRiskyActions": false, "endOfSpeechSeconds": 1.1, "followUpEnabled": false, "followUpSeconds": 9,
			  "keyterms": ["Bol"], "language": "", "noizApiKey": "noiz-key", "noizEmotion": "{\\"Tenderness\\":0.5}",
			  "noizLanguage": "", "noizModel": "v2", "noizQualityPreset": 5, "noizSpeed": 1.2, "noizVoiceId": "abc",
			  "openaiApiKey": "  ", "screenAccess": "ask", "silentMode": true, "sttModel": "whisper-1",
			  "sttProvider": "openai", "ttsModel": "tts-1", "ttsProvider": "noiz", "ttsVoice": "onyx",
			  "systemVoiceId": "com.apple.voice.premium.en-US.Zoe", "bunPath": "/opt/bun"
			}
			"""
		let config = try Config.decoded(data: Data(legacy.utf8))
		#expect(config.isChromeEnabled == false)
		#expect(config.agentModel == .auto)
		#expect(config.endOfSpeechSeconds == 1.1)
		#expect(config.isFollowUpEnabled == false)
		#expect(config.followUpSeconds == 9)
		#expect(config.isSilentMode == true)
		#expect(config.screenAccess == .auto)  // "ask" is gone
		#expect(config.apiKeys[.noiz] == "noiz-key")
		#expect(config.textToSpeech.provider == .noiz)
		#expect(config.textToSpeech.noiz.voiceId == "abc")
		#expect(config.textToSpeech.noiz.speed == 1.2)
		#expect(config.textToSpeech.noiz.qualityPreset == 5)
		#expect(config.textToSpeech.noiz.model == "v2")
		#expect(config.textToSpeech.noiz.language == nil)
		#expect(config.textToSpeech.noiz.emotion == "{\"Tenderness\":0.5}")
		#expect(config.textToSpeech.openai.model == "tts-1")
		#expect(config.textToSpeech.openai.voice == "onyx")
		#expect(config.textToSpeech.system.voiceId == "com.apple.voice.premium.en-US.Zoe")
		#expect(config.speechToText.provider == .openai)
		#expect(config.speechToText.openai.model == "whisper-1")
		#expect(config.speechToText.openai.language == nil)
	}

	@Test func fillsMissingKeysWithDefaults() throws {
		let config = try Config.decoded(
			data: Data(#"{"isSilentMode": true, "textToSpeech": {"provider": "system"}}"#.utf8))
		#expect(config.isSilentMode == true)
		#expect(config.textToSpeech.provider == .system)
		#expect(config.textToSpeech.openai == OpenAITextToSpeech.Settings())
		#expect(config.isFollowUpEnabled == Config().isFollowUpEnabled)
	}

	@Test func roundTripsTheCurrentLayout() throws {
		var original = Config()
		original.textToSpeech.provider = .noiz
		original.textToSpeech.noiz.emotion = "{\"Joy\":0.4}"
		original.apiKeys[.openai] = "sk-test"
		let data = try JSONEncoder().encode(original)
		#expect(try Config.decoded(data: data) == original)
	}

	@Test func storesOnlyNonEmptyTrimmedKeys() {
		var keys = APIKeys()
		keys[.openai] = "  sk-abc \n"
		#expect(keys[.openai] == "sk-abc")
		keys[.openai] = "   "
		#expect(keys[.openai] == nil)
	}
}

/// The user's real config, if present: it must decode without falling back to defaults.
@Suite struct InstalledConfigTests {
	@Test func decodesTheInstalledConfig() throws {
		let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bol/config.json")
		guard let data = try? Data(contentsOf: url) else { return }
		let config = try Config.decoded(data: data)
		let stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		if let provider = stored["ttsProvider"] as? String {
			#expect(config.textToSpeech.provider.rawValue == provider)
		}
		if let key = stored["openaiApiKey"] as? String, !key.isEmpty {
			#expect(config.apiKeys[.openai] == key)
		}
		if let key = stored["noizApiKey"] as? String, !key.isEmpty {
			#expect(config.apiKeys[.noiz] == key)
		}
	}
}
