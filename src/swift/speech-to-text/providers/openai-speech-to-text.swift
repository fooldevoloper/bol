import SwiftUI

/// OpenAI transcription (gpt-4o-transcribe / gpt-4o-mini-transcribe / whisper-1).
/// Audio is buffered while you speak and uploaded once you stop.
struct OpenAISpeechToText: SpeechToTextProvider {
	struct Settings: Codable, Equatable {
		var model = "gpt-4o-mini-transcribe"
		/// ISO 639-1 code; nil = auto-detect (handles mixed languages).
		var language: String? = nil
	}

	let id = SpeechToTextProviderID.openai
	let title = "OpenAI"
	let subtitle = "Transcribes after you finish speaking"
	let icon = "bolt"
	let credential = ProviderCredential.apiKey(.openai)

	private static let models: [SelectOption] = [
		SelectOption(id: "gpt-4o-transcribe", title: "gpt-4o-transcribe", subtitle: "Most accurate"),
		SelectOption(id: "gpt-4o-mini-transcribe", title: "gpt-4o-mini-transcribe", subtitle: "Faster, cheaper"),
		SelectOption(id: "whisper-1", title: "whisper-1", subtitle: "Classic Whisper"),
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
		OpenAISpeechToTextSession(apiKey: config.apiKeys[.openai], settings: config.speechToText.openai)
	}

	@MainActor func settingsSection(model: SettingsModel) -> AnyView {
		AnyView(
			Group {
				SettingsRow("API key", icon: "key", help: "Shared with the OpenAI voice") {
					KeyField(
						value: model.apiKeyBinding(id: .openai), validation: model.keyValidation(id: .openai)
					) { model.checkKey(id: .openai) }
				}
				SettingsRow("Model", icon: "cpu") {
					Select(
						options: Self.models,
						selection: Binding(root: model, keyPath: \.config.speechToText.openai.model))
				}
				SettingsRow("Language", icon: "character.bubble", help: "Auto-detect handles mixed languages") {
					Select(
						options: Self.languages,
						selection: Binding(root: model, keyPath: \.config.speechToText.openai.language).emptyAsNil,
						isSearchable: true, prompt: "Search languages")
				}
			}
		)
	}
}

final class OpenAISpeechToTextSession: SpeechToTextSession {
	private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
	/// Less than ~0.3 s of audio: nothing worth sending.
	private static let minimumBytes = Constants.micBytesPerSecond * 3 / 10

	var onTranscript: ((Transcript) -> Void)?
	var onError: ((ServiceProblem) -> Void)?
	var onFinished: (() -> Void)?
	let isStreamingInterim = false

	private let apiKey: String?
	private let settings: OpenAISpeechToText.Settings
	/// Guarded by `lock`: audio arrives on the audio queue.
	private var pcm = Data()
	private var isFlushed = false
	private let lock = NSLock()
	private var upload: Task<Void, Never>?

	init(apiKey: String?, settings: OpenAISpeechToText.Settings) {
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
			let result: Result<String?, Error>
			do {
				let (data, response) = try await URLSession.shared.data(for: request)
				result = .success(try Self.parse(data: data, response: response))
			} catch {
				result = .failure(error)
			}
			guard let self, !Task.isCancelled else { return }
			switch result {
			case .success(let text?):
				Log.info(
					message: String(
						format: "stt: openai %@ in %.1fs", self.settings.model, Date().timeIntervalSince(started)))
				self.onTranscript?(Transcript(text: text, isFinal: true))
			case .success(nil):
				break  // silence: no words
			case .failure(let error):
				self.onError?(
					ServiceDiagnosis.connection(error: error, service: "OpenAI")
						?? ServiceProblem(
							title: "OpenAI couldn't transcribe that", detail: error.localizedDescription, fix: .tryAgain
						))
			}
			self.finish()
		}
	}

	private func makeRequest(audio: Data, apiKey: String) -> URLRequest {
		let boundary = "bol-\(UUID().uuidString)"
		var body = Data()
		func field(name: String, value: String) {
			body.append(
				Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
		}
		field(name: "model", value: settings.model)
		field(name: "response_format", value: "json")
		if let language = settings.language { field(name: "language", value: language) }
		field(name: "prompt", value: Constants.speechKeyterms.joined(separator: ", "))
		body.append(
			Data(
				"--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
					.utf8))
		body.append(PCM.wavFile(pcm16kMono: audio))
		body.append(Data("\r\n--\(boundary)--\r\n".utf8))

		var request = URLRequest(url: Self.endpoint)
		request.httpMethod = "POST"
		request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
		request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		request.httpBody = body
		request.timeoutInterval = 30
		return request
	}

	/// The transcript, or nil when nothing was said.
	private static func parse(data: Data, response: URLResponse) throws -> String? {
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		guard status == 200 else {
			let message = (object?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
			throw NSError(domain: "OpenAI", code: status, userInfo: [NSLocalizedDescriptionKey: message])
		}
		let text = (object?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return text.isEmpty ? nil : text
	}

	private func finish() {
		let onFinished = self.onFinished
		self.onFinished = nil
		onFinished?()
	}
}
