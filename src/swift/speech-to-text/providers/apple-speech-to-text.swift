import AVFoundation
import Speech
import SwiftUI

/// Native macOS speech-to-text using `SFSpeechRecognizer`. Streams interim transcripts while you speak
/// and needs no API key or subscription.
struct AppleSpeechToText: SpeechToTextProvider {
	struct Settings: Codable, Equatable {
		/// BCP-47 locale identifier; nil = system default locale.
		var locale: String? = nil
	}

	let id = SpeechToTextProviderID.apple
	let title = "Apple Speech"
	let subtitle = "Free, live streaming on your Mac (no key)"
	let icon = "waveform"
	let credential = ProviderCredential.none

	private static let locales: [SelectOption] =
		[SelectOption(id: "", title: "System default", subtitle: Locale.current.identifier)]
		+ [
			("en-US", "English (US)"), ("en-GB", "English (UK)"), ("en-IN", "English (India)"),
			("hi-IN", "Hindi"), ("es-ES", "Spanish"), ("fr-FR", "French"), ("de-DE", "German"),
			("ja-JP", "Japanese"), ("ko-KR", "Korean"), ("zh-CN", "Chinese (Simplified)"),
			("pt-BR", "Portuguese"), ("it-IT", "Italian"),
		].map { SelectOption(id: $0.0, title: $0.1, subtitle: $0.0) }

	func makeSession(config: Config) -> SpeechToTextSession {
		AppleSpeechToTextSession(settings: config.speechToText.apple)
	}

	@MainActor func settingsSection(model: SettingsModel) -> AnyView {
		AnyView(
			Group {
				SettingsRow("Language", icon: "character.bubble", help: "macOS Speech Recognition locale") {
					Select(
						options: Self.locales,
						selection: Binding(root: model, keyPath: \.config.speechToText.apple.locale).emptyAsNil,
						isSearchable: true, prompt: "Search languages")
				}
				if !MacPermission.hasSpeechRecognition {
					SettingsRow(
						"Permission", icon: "checkmark.shield",
						help: "macOS requires Speech Recognition permission for Apple Speech"
					) {
						Button("Allow…") { MacPermission.speechRecognition.request() }
					}
				}
			}
		)
	}
}

final class AppleSpeechToTextSession: SpeechToTextSession {
	var onTranscript: ((Transcript) -> Void)?
	var onError: ((ServiceProblem) -> Void)?
	var onFinished: (() -> Void)?
	let isStreamingInterim = true

	private let settings: AppleSpeechToText.Settings
	private let audioFormat = AVAudioFormat(
		commonFormat: .pcmFormatInt16, sampleRate: Constants.micSampleRate, channels: 1, interleaved: true)!
	private let lock = NSLock()

	private var recognizer: SFSpeechRecognizer?
	private var request: SFSpeechAudioBufferRecognitionRequest?
	private var task: SFSpeechRecognitionTask?
	private var pendingBuffers: [AVAudioPCMBuffer] = []
	private var isAuthorized = false
	private var isFlushed = false
	private var isCancelled = false
	private var hasEnded = false
	private var lastText = ""
	private var flushTimeoutWork: DispatchWorkItem?

	init(settings: AppleSpeechToText.Settings) {
		self.settings = settings
	}

	func start() {
		let locale = settings.locale.map(Locale.init(identifier:)) ?? Locale.current
		guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
			fail(
				problem: ServiceDiagnosis.appleSpeechToText(
					reason: "This Mac doesn't support Speech Recognition for \(locale.identifier)."))
			return
		}
		self.recognizer = recognizer

		switch SFSpeechRecognizer.authorizationStatus() {
		case .authorized:
			beginRecognition(recognizer: recognizer)
		case .notDetermined:
			SFSpeechRecognizer.requestAuthorization { [weak self] status in
				DispatchQueue.main.async {
					guard let self, !self.isCancelled, !self.hasEnded else { return }
					if status == .authorized {
						self.beginRecognition(recognizer: recognizer)
					} else {
						self.fail(problem: ServiceDiagnosis.appleSpeechToText(reason: "Permission was denied."))
					}
				}
			}
		case .denied, .restricted:
			fail(problem: ServiceDiagnosis.appleSpeechToText(reason: "Permission is denied or restricted."))
		@unknown default:
			fail(problem: ServiceDiagnosis.appleSpeechToText(reason: "Speech Recognition isn't available."))
		}
	}

	func send(pcm data: Data) {
		guard let buffer = makePCMBuffer(from: data) else { return }
		lock.lock()
		if isCancelled || hasEnded || isFlushed {
			lock.unlock()
			return
		}
		if isAuthorized, let request {
			lock.unlock()
			request.append(buffer)
		} else {
			pendingBuffers.append(buffer)
			lock.unlock()
		}
	}

	func flush() {
		lock.lock()
		if isCancelled || hasEnded {
			lock.unlock()
			return
		}
		isFlushed = true
		let activeRequest = request
		let bufferedOnly = !isAuthorized
		lock.unlock()

		if bufferedOnly {
			// Permission wasn't resolved before user stopped talking.
			finish()
			return
		}
		activeRequest?.endAudio()

		let timeout = DispatchWorkItem { [weak self] in
			guard let self, !self.hasEnded, !self.isCancelled else { return }
			if !self.lastText.isEmpty {
				self.onTranscript?(Transcript(text: self.lastText, isFinal: true))
			}
			self.finish()
		}
		flushTimeoutWork = timeout
		DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
	}

	func cancel() {
		lock.lock()
		isCancelled = true
		pendingBuffers.removeAll()
		let activeTask = task
		let activeRequest = request
		request = nil
		task = nil
		lock.unlock()
		flushTimeoutWork?.cancel()
		onFinished = nil
		activeRequest?.endAudio()
		activeTask?.cancel()
	}

	private func beginRecognition(recognizer: SFSpeechRecognizer) {
		guard recognizer.isAvailable else {
			fail(problem: ServiceDiagnosis.appleSpeechToText(reason: "Apple Speech service is currently unavailable."))
			return
		}

		let req = SFSpeechAudioBufferRecognitionRequest()
		req.shouldReportPartialResults = true
		req.taskHint = .dictation
		req.contextualStrings = Constants.speechKeyterms

		lock.lock()
		if isCancelled || hasEnded {
			lock.unlock()
			return
		}
		request = req
		isAuthorized = true
		let queued = pendingBuffers
		pendingBuffers.removeAll()
		let alreadyFlushed = isFlushed
		lock.unlock()

		for buffer in queued {
			req.append(buffer)
		}
		if alreadyFlushed {
			req.endAudio()
		}

		task = recognizer.recognitionTask(with: req) { [weak self] result, error in
			DispatchQueue.main.async {
				self?.handleResult(result: result, error: error)
			}
		}
	}

	private func handleResult(result: SFSpeechRecognitionResult?, error: Error?) {
		guard !isCancelled, !hasEnded else { return }

		if let result {
			let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty {
				lastText = text
				onTranscript?(Transcript(text: text, isFinal: result.isFinal))
			}
			if result.isFinal {
				finish()
				return
			}
		}

		if let error {
			let nsError = error as NSError
			// 1110 = "No speech detected"; treat silence gracefully instead of reporting an error.
			if nsError.code == 1110 || nsError.code == 203 || nsError.code == 216 {
				if isFlushed { finish() }
				return
			}
			if !lastText.isEmpty && isFlushed {
				onTranscript?(Transcript(text: lastText, isFinal: true))
				finish()
				return
			}
			fail(problem: ServiceDiagnosis.appleSpeechToText(reason: error.localizedDescription))
		}
	}

	private func makePCMBuffer(from data: Data) -> AVAudioPCMBuffer? {
		let frameCount = AVAudioFrameCount(data.count / 2)
		guard frameCount > 0,
			let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount),
			let channelData = buffer.int16ChannelData
		else { return nil }
		buffer.frameLength = frameCount
		data.withUnsafeBytes { raw in
			guard let src = raw.baseAddress else { return }
			memcpy(channelData[0], src, Int(frameCount) * 2)
		}
		return buffer
	}

	private func fail(problem: ServiceProblem) {
		DispatchQueue.main.async { [weak self] in
			guard let self, !self.isCancelled, !self.hasEnded else { return }
			self.onError?(problem)
			self.finish()
		}
	}

	private func finish() {
		flushTimeoutWork?.cancel()
		flushTimeoutWork = nil
		lock.lock()
		if hasEnded {
			lock.unlock()
			return
		}
		hasEnded = true
		let activeTask = task
		task = nil
		request = nil
		lock.unlock()
		activeTask?.finish()
		let callback = onFinished
		onFinished = nil
		callback?()
	}
}
