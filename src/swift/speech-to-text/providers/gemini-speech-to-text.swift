import SwiftUI

/// Google Gemini audio transcription via `generativelanguage.googleapis.com`.
/// Audio is buffered while you speak and uploaded once you stop.
struct GeminiSpeechToText: SpeechToTextProvider {
	struct Settings: Codable, Equatable {
		var model = "gemini-2.5-flash"
		/// ISO 639-1 code; nil = auto-detect.
		var language: String? = nil
	}

	let id = SpeechToTextProviderID.gemini
	let title = "Google Gemini"
	let subtitle = "Fast, multilingual audio transcription (API key)"
	let icon = "sparkles"
	let credential = ProviderCredential.apiKey(.gemini)

	private static let models: [SelectOption] = [
		SelectOption(id: "gemini-2.5-flash", title: "Gemini 2.5 Flash", subtitle: "Recommended: fast and accurate"),
		SelectOption(id: "gemini-2.5-flash-lite", title: "Gemini 2.5 Flash-Lite", subtitle: "Lowest latency"),
		SelectOption(id: "gemini-2.5-pro", title: "Gemini 2.5 Pro", subtitle: "Highest accuracy"),
	]
	private static let languages: [SelectOption] =
		[SelectOption(id: "", title: "Auto-detect", subtitle: "Any language, even mixed")]
		+ [
			("en", "English"), ("hi", "Hindi"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
			("pt", "Portuguese"), ("it", "Italian"), ("nl", "Dutch"), ("ru", "Russian"), ("ja", "Japanese"),
			("ko", "Korean"), ("zh", "Chinese"), ("ar", "Arabic"), ("tr", "Turkish"), ("pl", "Polish"),
			("sv", "Swedish"), ("id", "Indonesian"), ("bn", "Bengali"), ("ta", "Tamil"), ("te", "Telugu"),
			("mr", "Marathi"), ("gu", "Gujarati"), ("ur", "Urdu"),
		].map { SelectOption(id: $0.0, title: $0.1, subtitle: $0.0.uppercased()) }

	func makeSession(config: Config) -> SpeechToTextSession {
		GeminiSpeechToTextSession(apiKey: config.apiKeys[.gemini], settings: config.speechToText.gemini)
	}

	@MainActor func settingsSection(model: SettingsModel) -> AnyView {
		AnyView(
			Group {
				SettingsRow("API key", icon: "key", help: "Google AI Studio key (or GEMINI_API_KEY env)") {
					KeyField(
						value: model.apiKeyBinding(id: .gemini), validation: model.keyValidation(id: .gemini)
					) { model.checkKey(id: .gemini) }
				}
				SettingsRow("Model", icon: "cpu") {
					Select(
						options: Self.models,
						selection: Binding(root: model, keyPath: \.config.speechToText.gemini.model))
				}
				SettingsRow("Language", icon: "character.bubble", help: "Auto-detect handles mixed languages") {
					Select(
						options: Self.languages,
						selection: Binding(root: model, keyPath: \.config.speechToText.gemini.language).emptyAsNil,
						isSearchable: true, prompt: "Search languages")
				}
			}
		)
	}
}

final class GeminiSpeechToTextSession: SpeechToTextSession {
	/// Less than ~0.3 s of audio: nothing worth sending.
	private static let minimumBytes = Constants.micBytesPerSecond * 3 / 10

	var onTranscript: ((Transcript) -> Void)?
	var onError: ((ServiceProblem) -> Void)?
	var onFinished: (() -> Void)?
	let isStreamingInterim = false

	private let apiKey: String?
	private let settings: GeminiSpeechToText.Settings
	private var pcm = Data()
	private var isFlushed = false
	private let lock = NSLock()
	private var upload: Task<Void, Never>?

	init(apiKey: String?, settings: GeminiSpeechToText.Settings) {
		self.apiKey = apiKey
		self.settings = settings
	}

	func start() {}

	func send(pcm data: Data) {
		lock.lock()
		if !isFlushed { pcm.append(data) }
		lock.unlock()
	}

	func cancel() {
		upload?.cancel()
		onFinished = nil
	}

	func flush() {
		lock.lock()
		isFlushed = true
		let audio = pcm
		lock.unlock()
		guard audio.count > Self.minimumBytes, let apiKey else {
			finish()
			return
		}
		let request = makeRequest(audio: audio, apiKey: apiKey)
		upload = Task { @MainActor [weak self] in
			let started = Date()
			do {
				let (data, response) = try await URLSession.shared.data(for: request)
				guard !Task.isCancelled, let self else { return }
				if let text = try Self.parse(data: data, response: response) {
					Log.info(
						message: String(
							format: "stt: gemini %@ in %.1fs", self.settings.model, Date().timeIntervalSince(started)))
					self.onTranscript?(Transcript(text: text, isFinal: true))
				}
			} catch let problem as ServiceProblem {
				guard !Task.isCancelled, let self else { return }
				self.onError?(problem)
			} catch {
				guard !Task.isCancelled, let self else { return }
				self.onError?(ServiceDiagnosis.geminiSpeechToText(status: nil, error: error, serverMessage: nil))
			}
			self?.finish()
		}
	}

	private func makeRequest(audio: Data, apiKey: String) -> URLRequest {
		let endpoint = URL(
			string: "https://generativelanguage.googleapis.com/v1beta/models/\(settings.model):generateContent")!
		let wavBase64 = PCM.wavFile(pcm16kMono: audio).base64EncodedString()
		let keyterms = Constants.speechKeyterms.joined(separator: ", ")
		let langHint = settings.language.map { " The spoken language is \($0)." } ?? ""
		let prompt =
			"Transcribe the audio verbatim.\(langHint) Output only the spoken transcript text with punctuation; if there is no speech, output an empty string. Key terms: \(keyterms)."

		let payload: [String: Any] = [
			"contents": [
				[
					"parts": [
						["text": prompt],
						["inlineData": ["mimeType": "audio/wav", "data": wavBase64]],
					]
				]
			],
			"generationConfig": ["temperature": 0],
		]

		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
		request.timeoutInterval = 30
		return request
	}

	private static func parse(data: Data, response: URLResponse) throws -> String? {
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		guard status == 200 else {
			let msg = (object?["error"] as? [String: Any])?["message"] as? String
			throw ServiceDiagnosis.geminiSpeechToText(status: status, error: nil, serverMessage: msg)
		}
		guard let candidates = object?["candidates"] as? [[String: Any]],
			let content = candidates.first?["content"] as? [String: Any],
			let parts = content["parts"] as? [[String: Any]]
		else { return nil }
		let text = parts.compactMap { $0["text"] as? String }
			.joined()
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text
	}

	private func finish() {
		let onFinished = self.onFinished
		self.onFinished = nil
		onFinished?()
	}
}
