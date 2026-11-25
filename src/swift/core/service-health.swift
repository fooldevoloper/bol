import Foundation

/// Something Bol depends on isn't working, worded for the person using Bol: what's wrong and what to do.
struct ServiceProblem: Error, Equatable {
	enum Fix: Equatable {
		case requestSpeechRecognition, useAppleOrOpenAIForListening, signInToAntigravity, installAntigravityCLI,
			checkConnection, tryAgain, none
	}

	let title: String
	let detail: String
	var fix = Fix.none
	var isOutage = false
}

/// Diagnoses external service failures (Antigravity CLI/auth, Google Gemini STT, OpenAI STT, macOS Speech).
enum ServiceDiagnosis {
	static let fallbackHint = "Switch Settings → Listening to Apple Speech to keep talking with no API key."

	static func geminiSpeechToText(status: Int?, error: Error?, serverMessage: String?) -> ServiceProblem {
		if let status {
			switch status {
			case 400, 401, 403:
				return ServiceProblem(
					title: "Gemini didn't accept the API key",
					detail: "Check your Google Gemini API key in Settings → Listening. \(fallbackHint)",
					fix: .useAppleOrOpenAIForListening)
			case 429:
				return ServiceProblem(
					title: "Gemini speech-to-text is rate limited",
					detail: "Wait a moment and try again. \(fallbackHint)",
					fix: .tryAgain)
			case 500...599:
				return ServiceProblem(
					title: "Gemini is having trouble",
					detail: "Google's API failed (HTTP \(status)). Try again shortly. \(fallbackHint)",
					fix: .tryAgain)
			default:
				return ServiceProblem(
					title: "Gemini speech-to-text failed",
					detail: "Google's API returned HTTP \(status). \(fallbackHint)",
					fix: .tryAgain)
			}
		}
		if let problem = connection(error: error, service: "Google Gemini") { return problem }
		if let serverMessage, !serverMessage.isEmpty {
			return ServiceProblem(title: "Gemini couldn't transcribe that", detail: serverMessage, fix: .tryAgain)
		}
		return ServiceProblem(
			title: "Gemini speech-to-text didn't respond",
			detail: "Try again, or \(fallbackHint.prefix(1).lowercased() + fallbackHint.dropFirst())",
			fix: .tryAgain)
	}

	static func appleSpeechToText(reason: String) -> ServiceProblem {
		ServiceProblem(
			title: "Apple Speech isn't ready",
			detail: "\(reason) Allow Speech Recognition in System Settings → Privacy & Security, or use Gemini/OpenAI.",
			fix: .requestSpeechRecognition)
	}

	/// Network-level failures, the same for every service.
	static func connection(error: Error?, service: String) -> ServiceProblem? {
		guard let error = error as? URLError else { return nil }
		switch error.code {
		case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
			return ServiceProblem(
				title: "You're offline", detail: "Bol needs the internet to reach \(service).", fix: .checkConnection)
		case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
			return ServiceProblem(
				title: "Can't reach \(service)",
				detail: "Check your connection, VPN or firewall, then try again.", fix: .checkConnection)
		case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
			.clientCertificateRejected:
			return ServiceProblem(
				title: "Secure connection to \(service) failed",
				detail: "A proxy, VPN or security tool may be intercepting traffic.", fix: .checkConnection)
		case .cancelled:
			return nil
		default:
			return ServiceProblem(
				title: "Couldn't reach \(service)", detail: error.localizedDescription, fix: .checkConnection)
		}
	}
}

/// Checks everything Bol relies on and keeps the results for Settings → Assistant → Health, the menu and launch.
@MainActor final class ServiceHealth: ObservableObject {
	enum Item: String, CaseIterable, Identifiable {
		case antigravityCLI, antigravityAccount, speechToText
		var id: String { rawValue }

		var title: String {
			switch self {
			case .antigravityCLI: return "Antigravity CLI"
			case .antigravityAccount: return "Antigravity sign-in"
			case .speechToText: return "Listening"
			}
		}

		var icon: String {
			switch self {
			case .antigravityCLI: return "terminal"
			case .antigravityAccount: return "person.crop.circle"
			case .speechToText: return "mic"
			}
		}

		var isEssential: Bool { true }
	}

	enum Status: Equatable {
		case unknown, checking
		case ok(String)
		case problem(ServiceProblem)
	}

	static let shared = ServiceHealth()

	@Published private(set) var statuses: [Item: Status] = [:]
	@Published private(set) var checkedAt: Date?
	@Published private(set) var isChecking = false
	/// Called when an essential check newly fails, with that problem (the app shows it once).
	var onNewProblem: ((Item, ServiceProblem) -> Void)?
	/// The current settings, read again for each scheduled recheck.
	var currentConfig: () -> Config = { Config.load() }

	private var recheck: Task<Void, Never>?
	private static let recheckSeconds: UInt64 = 15 * 60

	func status(item: Item) -> Status { statuses[item] ?? .unknown }

	/// The first essential problem, for the menu.
	var essentialProblem: (Item, ServiceProblem)? {
		for item in Item.allCases where item.isEssential {
			if case .problem(let problem) = status(item: item) { return (item, problem) }
		}
		return nil
	}

	func run(config: Config) {
		guard !isChecking else { return }
		isChecking = true
		for item in Item.allCases { statuses[item] = .checking }
		Task { @MainActor in
			let previous = statuses
			await check(config: config)
			isChecking = false
			checkedAt = Date()
			for item in Item.allCases where item.isEssential {
				guard case .problem(let problem) = status(item: item) else { continue }
				if case .problem(let old) = previous[item], old == problem { continue }
				onNewProblem?(item, problem)
			}
			scheduleRecheck()
		}
	}

	/// A live failure (e.g. while listening) updates the matching row without a full check.
	func report(item: Item, problem: ServiceProblem) {
		statuses[item] = .problem(problem)
		scheduleRecheck()
	}

	private func check(config: Config) async {
		guard AntigravityCLI.executable != nil else {
			let problem = ServiceProblem(
				title: "Antigravity CLI isn't installed",
				detail: "Bol thinks with `agy` on this Mac. Install it from Settings → General → Run Setup Again.",
				fix: .installAntigravityCLI)
			statuses = [.antigravityCLI: .problem(problem), .antigravityAccount: .unknown, .speechToText: .unknown]
			return
		}
		statuses[.antigravityCLI] = .ok("Installed")

		if let account = await AntigravityAuth.account() {
			statuses[.antigravityAccount] = .ok(account.detail)
		} else {
			let problem = ServiceProblem(
				title: "Not signed in to Antigravity",
				detail: "Sign in from Settings → Assistant, or run `agy acp --login` in Terminal.",
				fix: .signInToAntigravity)
			statuses[.antigravityAccount] = .problem(problem)
		}

		statuses[.speechToText] = checkSpeechToText(config: config)
	}

	private func checkSpeechToText(config: Config) -> Status {
		let active = SpeechToTextProviders.active(config: config)
		guard active.credential.isSatisfied(by: config) else {
			let keyTitle =
				switch active.credential {
				case .apiKey(let id): id.title
				case .none: ""
				}
			return .problem(
				ServiceProblem(
					title: "\(active.title) needs a \(keyTitle) API key",
					detail: "Add it in Settings → Listening, or switch to Apple Speech.",
					fix: .useAppleOrOpenAIForListening))
		}
		if active.id == .apple, !MacPermission.hasSpeechRecognition {
			return .problem(
				ServiceDiagnosis.appleSpeechToText(reason: "Speech Recognition permission is off or denied."))
		}
		return .ok(active.title)
	}

	private func scheduleRecheck() {
		recheck?.cancel()
		let hasProblem = statuses.values.contains {
			if case .problem = $0 { return true } else { return false }
		}
		guard hasProblem else { return }
		recheck = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: Self.recheckSeconds * 1_000_000_000)
			guard !Task.isCancelled, let self else { return }
			self.run(config: self.currentConfig())
		}
	}
}
