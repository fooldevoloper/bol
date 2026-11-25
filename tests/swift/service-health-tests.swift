import Foundation
import Testing

@testable import Bol

@Suite struct ServiceDiagnosisTests {
	@Test func rejectedGeminiKeyAsksToSwitchOrCheckKey() {
		for status in [400, 401, 403] {
			let problem = ServiceDiagnosis.geminiSpeechToText(status: status, error: nil, serverMessage: nil)
			#expect(problem.fix == .useAppleOrOpenAIForListening)
			#expect(problem.detail.contains("Apple Speech"))
		}
	}

	@Test func temporaryTroubleSuggestsTryAgain() {
		for status in [429, 500, 503] {
			let problem = ServiceDiagnosis.geminiSpeechToText(status: status, error: nil, serverMessage: nil)
			#expect(problem.fix == .tryAgain)
		}
	}

	@Test func networkFailuresTalkAboutTheConnection() {
		let offline = ServiceDiagnosis.geminiSpeechToText(
			status: nil, error: URLError(.notConnectedToInternet), serverMessage: nil)
		#expect(offline.title == "You're offline" && offline.fix == .checkConnection)
		let unreachable = ServiceDiagnosis.geminiSpeechToText(
			status: nil, error: URLError(.cannotFindHost), serverMessage: nil)
		#expect(unreachable.title == "Can't reach Google Gemini")
	}

	@Test func serverMessagesPassThrough() {
		let problem = ServiceDiagnosis.geminiSpeechToText(status: nil, error: nil, serverMessage: "audio too short")
		#expect(problem.detail == "audio too short" && problem.fix == .tryAgain)
	}
}

@Suite struct SpeechToTextProviderTests {
	@Test func fallsBackToAppleWhenKeyMissing() {
		var config = Config()
		config.speechToText.provider = .gemini
		config.apiKeys[.gemini] = nil
		#expect(SpeechToTextProviders.active(config: config).id == .apple)
	}

	@Test func usesGeminiAndOpenAIWhenConfigured() {
		var config = Config()
		config.speechToText.provider = .gemini
		config.apiKeys[.gemini] = "AIzaTest"
		#expect(SpeechToTextProviders.active(config: config).id == .gemini)

		config.speechToText.provider = .openai
		config.apiKeys[.openai] = "sk-test"
		#expect(SpeechToTextProviders.active(config: config).id == .openai)
	}

	@Test func legacyClaudeProviderDecodesAsApple() throws {
		let decoded = try JSONDecoder().decode(SpeechToTextSettings.self, from: Data(#"{"provider":"claude"}"#.utf8))
		#expect(decoded.provider == .apple)
	}
}
