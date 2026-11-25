import AVFoundation
import SwiftUI

/// First-run setup: verifies everything Bol needs before it starts listening.
enum OnboardingStep: Int, CaseIterable, Identifiable {
	case welcome, antigravityCLI, account, microphone, voice, dictation, permissions, autonomy, ready, terms

	var id: Int { rawValue }

	var title: String {
		switch self {
		case .welcome: return "Welcome"
		case .antigravityCLI: return "Antigravity CLI"
		case .account: return "Google account"
		case .microphone: return "Microphone"
		case .voice: return "Voice"
		case .dictation: return "Dictation"
		case .permissions: return "Permissions"
		case .autonomy: return "Autonomy"
		case .ready: return "Ready"
		case .terms: return "Terms"
		}
	}

	var icon: String {
		switch self {
		case .welcome: return "hand.wave"
		case .antigravityCLI: return "terminal"
		case .account: return "person.crop.circle"
		case .microphone: return "mic"
		case .voice: return "speaker.wave.2"
		case .dictation: return "text.cursor"
		case .permissions: return "lock.shield"
		case .autonomy: return "bolt"
		case .ready: return "checkmark.seal"
		case .terms: return "doc.text"
		}
	}
}

enum AntigravityCLICheck: Equatable {
	case checking
	case missing
	/// The installer is running in Terminal; Bol watches for the binary.
	case installing
	case installed(version: String)
}

enum AccountCheck: Equatable {
	case checking
	case signedOut
	/// Sign-in is running in Terminal; Bol watches for the login.
	case signingIn
	case notWorking(reason: String)
	case ready(detail: String?)
}

enum SpeechTest: Equatable {
	case idle
	case connecting
	case listening(heard: String)
	case passed(heard: String)
	case failed(reason: String)
}

final class OnboardingModel: ObservableObject {
	@Published var step = OnboardingStep.welcome {
		didSet { stepChanged(from: oldValue) }
	}
	@Published private(set) var antigravityCLI = AntigravityCLICheck.checking
	@Published private(set) var account = AccountCheck.checking
	@Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
	@Published private(set) var speechTest = SpeechTest.idle
	@Published private(set) var inputLevel: Float = 0
	/// Other dictation apps on this Mac (Wispr Flow, Hex…), found when the dictation step opens.
	@Published private(set) var otherDictationApps: [DictationApp] = []
	/// The box ticked on the Terms step. Agreeing is recorded when setup finishes (see `finish()`).
	@Published var isAgreeingToTerms = false
	/// The dictation recommendation is applied once, the first time the step opens.
	private var hasSuggestedDictation = false
	/// How other dictation apps are found (tests pass their own).
	var findDictationApps: () -> [DictationApp] = { DictationApps.installed() }
	/// Config, API keys, voice samples and permission status are shared with Settings.
	let settings: SettingsModel
	var onFinish: (() -> Void)?

	/// A background watcher for the current step (install, sign-in, permissions); one at a time.
	private var watcher: Task<Void, Never>?
	private var speechSession: SpeechToTextSession?
	/// Made on the first speech test, so an app that never runs setup holds no audio engine.
	private lazy var capture = AudioCapture()
	private var levelTimer: Timer?

	init(settings: SettingsModel) {
		self.settings = settings
	}

	// MARK: Navigation

	var isStepComplete: Bool { isComplete(step: step) }

	func isComplete(step: OnboardingStep) -> Bool {
		switch step {
		// Recommended, never required.
		case .welcome, .dictation, .autonomy, .ready: return true
		case .terms: return isAgreeingToTerms || settings.config.hasAcceptedCurrentTerms
		case .antigravityCLI:
			if case .installed = antigravityCLI { return true }
			return false
		case .account:
			if case .ready = account { return true }
			return false
		case .microphone:
			if case .passed = speechTest { return true }
			return false
		case .voice:
			let provider = TextToSpeechProviders.provider(id: settings.config.textToSpeech.provider)
			switch provider.credential {
			case .none: return true
			case .apiKey(let id): return settings.keyValidation(id: id) == .valid
			}
		case .permissions:
			return MacPermission.allCases.filter { $0.importance == .required }.allSatisfy {
				settings.permissions.isGranted(permission: $0)
			}
		}
	}

	/// Steps the user may move to: every step up to the first incomplete required one.
	func isReachable(step target: OnboardingStep) -> Bool {
		target == step
			|| OnboardingStep.allCases.prefix(while: { $0 != target }).allSatisfy {
				isComplete(step: $0) || $0 == .permissions
			}
	}

	func goBack() {
		guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
		step = previous
	}

	func goForward() {
		guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
			finish()
			return
		}
		step = next
	}

	/// The last step's button: records the agreement (version and time, on this Mac only) and starts Bol.
	func finish() {
		guard isComplete(step: .terms) else { return }  // Bol never starts without the Terms agreed to
		stopWatching()
		stopSpeechTest()
		if !settings.config.hasAcceptedCurrentTerms { settings.config.acceptedTerms = .now() }
		settings.config.hasCompletedOnboarding = true
		onFinish?()
	}

	/// The window closed: stop everything that polls or listens, so a closed setup costs nothing.
	func windowClosed() {
		stopWatching()
		stopSpeechTest()
	}

	/// The window opened again: restart the watcher the open step had, if it was stopped on close.
	func windowShown() {
		guard watcher == nil else { return }
		switch step {
		case .permissions: watchPermissions()
		case .autonomy: watchAutonomy()
		case .account where account == .signingIn: checkAccount()
		case .welcome, .antigravityCLI, .account, .microphone, .voice, .dictation, .ready, .terms: break
		}
	}

	private func stepChanged(from previous: OnboardingStep) {
		guard step != previous else { return }
		stopWatching()
		if previous == .microphone { stopSpeechTest() }
		switch step {
		case .welcome, .voice, .ready, .terms: break
		case .antigravityCLI: checkAntigravityCLI()
		case .account: checkAccount()
		case .microphone: microphone = AVCaptureDevice.authorizationStatus(for: .audio)
		case .dictation: checkDictationApps()
		case .permissions: watchPermissions()
		case .autonomy: watchAutonomy()
		}
	}

	// MARK: Dictation

	/// Bol's dictation is on by default. With another dictation app installed it starts off on a first setup
	/// (both would react to a held key and paste twice); running setup again never changes a choice already made.
	func checkDictationApps() {
		otherDictationApps = findDictationApps()
		guard !hasSuggestedDictation else { return }
		hasSuggestedDictation = true
		if !otherDictationApps.isEmpty, !settings.config.hasCompletedOnboarding {
			settings.config.dictation.isEnabled = false
		}
	}

	/// Whether Bol recommends its own dictation on this Mac.
	var isDictationRecommended: Bool { otherDictationApps.isEmpty }

	// MARK: Antigravity CLI

	func checkAntigravityCLI() {
		antigravityCLI = .checking
		Task { @MainActor in
			antigravityCLI = await AntigravityCLI.version().map { .installed(version: $0) } ?? .missing
		}
	}

	func installAntigravityCLI() {
		Terminal.run(command: AntigravityCLI.installCommand)
		antigravityCLI = .installing
		watch { [weak self] in
			guard let version = await AntigravityCLI.version() else { return false }
			self?.antigravityCLI = .installed(version: version)
			return true
		}
	}

	// MARK: Account

	func checkAccount() {
		account = .checking
		Task { @MainActor in account = await Self.verifyAccount() }
	}

	func signIn() {
		guard AntigravityCLI.executable != nil else {
			step = .antigravityCLI
			return
		}
		Terminal.run(command: AntigravityAuth.loginCommand)
		account = .signingIn
		watch { [weak self] in
			guard await AntigravityAuth.account() != nil else { return false }
			self?.account = await Self.verifyAccount()
			return true
		}
	}

	private static func verifyAccount() async -> AccountCheck {
		guard let account = await AntigravityAuth.account() else { return .signedOut }
		return .ready(detail: account.detail)
	}

	// MARK: Microphone + speech-to-text

	func requestMicrophone() {
		switch AVCaptureDevice.authorizationStatus(for: .audio) {
		case .notDetermined:
			AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
				DispatchQueue.main.async { self?.microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
			}
		case .denied, .restricted, .authorized:
			MacPermission.microphone.openSettings()
			watch { [weak self] in
				let status = AVCaptureDevice.authorizationStatus(for: .audio)
				self?.microphone = status
				return status == .authorized
			}
		@unknown default:
			MacPermission.microphone.openSettings()
		}
	}

	/// Opens the mic and the active speech-to-text provider. Passes once the test sentence comes back.
	func startSpeechTest() {
		stopSpeechTest()
		speechTest = .connecting
		Task { @MainActor in
			guard speechTest == .connecting else { return }
			let provider = SpeechToTextProviders.active(config: settings.config)
			let session = provider.makeSession(config: settings.config)
			var finals: [String] = []
			session.onTranscript = { [weak self, weak session] transcript in
				guard let self, let session, session === self.speechSession else { return }
				if transcript.isFinal { finals.append(transcript.text) }
				let heard = (finals + (transcript.isFinal ? [] : [transcript.text])).joined(separator: " ")
				// Passes the moment the test phrase is recognized, even mid-sentence.
				if Self.isMatchingTestPhrase(heard: heard) {
					self.speechTest = .passed(heard: heard)
					self.stopListening()
				} else {
					self.speechTest = .listening(heard: heard)
				}
			}
			session.onError = { [weak self, weak session] problem in
				guard let self, let session, session === self.speechSession else { return }
				self.speechTest = .failed(reason: "\(problem.title). \(problem.detail)")
				self.stopListening()
			}
			capture.onPCM16k = { [weak session] data in session?.send(pcm: data) }
			do {
				try capture.start()
			} catch {
				speechTest = .failed(reason: "Couldn't open the microphone: \(error.localizedDescription)")
				return
			}
			speechSession = session
			session.start()
			speechTest = .listening(heard: "")
			levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
				Task { @MainActor in
					guard let self else { return }
					self.inputLevel = self.capture.level
				}
			}
			if !session.isStreamingInterim {
				// Batch providers (Gemini / OpenAI) flush automatically after capturing the short test sentence.
				try? await Task.sleep(nanoseconds: 4_500_000_000)
				if session === speechSession {
					capture.stop()
					capture.onPCM16k = nil
					session.flush()
				}
			}
			// Nothing heard in 15 seconds: stop, so the mic isn't held.
			try? await Task.sleep(nanoseconds: 15_000_000_000)
			if session === speechSession, case .listening(let heard) = speechTest {
				speechTest = .failed(
					reason: heard.isEmpty
						? "Didn't hear anything. Check your input device."
						: "That didn't match. Say “\(Self.testPhrase)”")
				stopListening()
			}
		}
	}

	/// What the speech test asks you to say.
	static let testPhrase = "Hello Bol, what time is it?"

	/// Most of the phrase's words were heard, in any order: tolerant of a misheard word
	/// ("Hello bowl, what time is it") but not of unrelated speech.
	static func isMatchingTestPhrase(heard: String) -> Bool {
		func words(text: String) -> Set<String> {
			Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
		}
		let expected = words(text: testPhrase)
		return expected.intersection(words(text: heard)).count * 3 >= expected.count * 2
	}

	func stopSpeechTest() {
		stopListening()
		switch speechTest {
		case .connecting, .listening: speechTest = .idle
		case .idle, .passed, .failed: break
		}
	}

	/// Releases the mic right away (other apps may need it), keeping the result on screen.
	private func stopListening() {
		levelTimer?.invalidate()
		levelTimer = nil
		inputLevel = 0
		capture.stop()
		capture.onPCM16k = nil
		speechSession?.cancel()
		speechSession = nil
	}

	// MARK: Permissions

	private func watchPermissions() {
		settings.refreshPermissions()
		watch { [weak self] in
			self?.settings.refreshPermissions()
			return false  // keep watching while the step is open
		}
	}

	// MARK: Autonomy

	var isComputerUseOn: Bool {
		settings.config.screenAccess != .off && settings.permissions.isGranted(permission: .accessibility)
			&& settings.permissions.isGranted(permission: .screenRecording)
	}

	var isChromeControlOn: Bool { settings.config.isChromeEnabled }

	/// Lets Bol see and operate the screen: screen access on, then whichever grant is missing.
	func turnOnComputerUse() {
		if settings.config.screenAccess == .off { settings.config.screenAccess = .auto }
		let missing = [MacPermission.accessibility, .screenRecording].first {
			!settings.permissions.isGranted(permission: $0)
		}
		missing?.request()
	}

	func turnOnChromeControl() {
		settings.config.isChromeEnabled = true
	}

	private func watchAutonomy() {
		settings.refreshPermissions()
		watch { [weak self] in
			guard let self else { return true }
			self.settings.refreshPermissions()
			return false  // keep watching while the step is open
		}
	}

	// MARK: Previews

	/// Dev-only (`Bol --render-onboarding`): shows a step with given check results, no real checks.
	func setPreviewState(
		step: OnboardingStep, antigravityCLI: AntigravityCLICheck, account: AccountCheck,
		microphone: AVAuthorizationStatus, speechTest: SpeechTest, dictationApps: [DictationApp]? = nil
	) {
		self.antigravityCLI = antigravityCLI
		self.account = account
		self.microphone = microphone
		self.speechTest = speechTest
		self.step = step
		stopWatching()
		if let dictationApps {
			otherDictationApps = dictationApps
			settings.config.dictation.isEnabled = dictationApps.isEmpty
		}
	}

	// MARK: Watching

	/// Re-runs `check` every 2 seconds until it returns true or the step changes.
	private func watch(check: @escaping @MainActor () async -> Bool) {
		stopWatching()
		watcher = Task { @MainActor in
			while !Task.isCancelled {
				try? await Task.sleep(nanoseconds: 2_000_000_000)
				guard !Task.isCancelled else { return }
				if await check() { return }
			}
		}
	}

	private func stopWatching() {
		watcher?.cancel()
		watcher = nil
	}
}
