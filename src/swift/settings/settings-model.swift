import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

struct MemoryItem: Identifiable, Hashable {
	/// File name.
	let id: String
	let name: String
	let description: String
	let type: String
	let url: URL
}

enum SampleState: Equatable {
	case idle
	case generating(since: Date)
	case playing(providerTitle: String)
	case done
	case failed(reason: String)

	var isBusy: Bool {
		switch self {
		case .generating, .playing: return true
		case .idle, .done, .failed: return false
		}
	}
}

/// The instructions appended to Claude Code's system prompt.
struct Prompts: Equatable {
	/// The brain's built-in prompt.
	let defaultText: String
	/// The user's edit; nil = the default is used.
	let customText: String?
	var current: String { customText ?? defaultText }
}

enum BrainState: Equatable {
	case ready, restarting
}

final class SettingsModel: ObservableObject {
	@Published var config: Config {
		didSet {
			guard config != oldValue else { return }
			if isPersisting { config.save() }
			onChange?(config)
			savedAt = Date()
			for id in APIKeyID.allCases where oldValue.apiKeys[id] != config.apiKeys[id] {
				scheduleKeyCheck(id: id, delaySeconds: 0.7)
			}
		}
	}
	@Published var savedAt: Date?
	/// The skills Bol can use, as the brain last reported them.
	@Published var skills: [BrainBridge.Skill] = []
	/// MCP servers whose sign-in page is open, waiting for the user.
	@Published var signingIn: Set<String> = []
	/// Recent dictations (the controller's), for Settings → Dictation.
	var dictations = DictationHistory()

	// Voice
	@Published private(set) var keyValidations: [APIKeyID: KeyValidation] = [:]
	@Published private(set) var sample = SampleState.idle
	@Published private(set) var sampleNote: String?

	// Assistant
	@Published var brainState = BrainState.ready
	@Published private(set) var prompts: Prompts?
	@Published private(set) var engine: EngineStatus?
	@Published private(set) var isCheckingEngine = false
	@Published private(set) var permissions = PermissionStatus.current()
	/// The servers in ~/.bol/mcp.json, and how the brain last said they're doing.
	@Published private(set) var mcpEntries: [MCPConfig.Entry] = []
	@Published var mcpReport: MCPStatusReport? {
		didSet { reloadMCPEntries() }  // a report follows every change to the file, by hand too
	}

	// Memory / general
	@Published private(set) var memories: [MemoryItem] = []
	@Published private(set) var isLaunchingAtLogin = SMAppService.mainApp.status == .enabled
	@Published private(set) var launchError: String?

	var onChange: ((Config) -> Void)?
	/// Plays a sample; returns false if Bol is busy talking.
	var onPlaySample:
		((_ text: String, _ onEvent: @escaping (Speaker.Event) -> Void, _ completion: @escaping () -> Void) -> Bool)?
	var onStopSample: (() -> Void)?
	var onNewConversation: (() -> Void)?
	var onEngineReady: (() -> Void)?
	var onRestartBrain: (() -> Void)?
	var onRunSetup: (() -> Void)?
	var onRequestMCPStatus: (() -> Void)?
	var onSignIn: ((String) -> Void)?

	private var keyChecks: [APIKeyID: Task<Void, Never>] = [:]
	private var isSampleStoppedByUser = false
	private var sampleReset: Task<Void, Never>?

	/// Whether changes are written to ~/.bol/config.json. Only the app's own model saves; previews and tests
	/// work on a copy, so they can never overwrite the real settings (and the API keys in them).
	private let isPersisting: Bool

	init(config: Config, isPersisting: Bool = false) {
		self.isPersisting = isPersisting
		self.config = config
		for id in APIKeyID.allCases { checkKey(id: id) }
	}

	// MARK: MCP servers

	/// Starts a server's sign-in: its page opens in the browser.
	func signIn(server name: String) {
		signingIn.insert(name)
		onSignIn?(name)
	}

	func reloadMCPEntries() {
		let entries = MCPConfig.entries()
		if entries != mcpEntries { mcpEntries = entries }
	}

	/// Re-reads the file and asks the brain how the servers are doing.
	func refreshMCP() {
		reloadMCPEntries()
		onRequestMCPStatus?()
	}

	/// Runs a change to mcp.json; the brain notices the file change and applies it live.
	func changeMCP(change: () throws -> Void) throws {
		try change()
		reloadMCPEntries()
	}

	// MARK: API keys

	func keyValidation(id: APIKeyID) -> KeyValidation { keyValidations[id] ?? .missing }

	func apiKeyBinding(id: APIKeyID) -> Binding<String?> {
		Binding(get: { self.config.apiKeys[id] }, set: { self.config.apiKeys[id] = $0 })
	}

	func checkKey(id: APIKeyID) { scheduleKeyCheck(id: id, delaySeconds: 0) }

	/// Debounced while typing; results for a key that has since changed are dropped.
	private func scheduleKeyCheck(id: APIKeyID, delaySeconds: Double) {
		keyChecks[id]?.cancel()
		guard let key = config.apiKeys[id] else {
			keyValidations[id] = .missing
			return
		}
		keyValidations[id] = .checking
		keyChecks[id] = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
			guard !Task.isCancelled else { return }
			let validation = await id.validate(key: key)
			guard let self, !Task.isCancelled, self.config.apiKeys[id] == key else { return }
			self.keyValidations[id] = validation
		}
	}

	// MARK: Play sample

	func toggleSample(text: String) {
		if sample.isBusy {
			isSampleStoppedByUser = true
			onStopSample?()
			return
		}
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		sampleReset?.cancel()
		sampleNote = nil
		isSampleStoppedByUser = false
		sample = .generating(since: Date())
		let isAccepted =
			onPlaySample?(
				trimmed,
				{ [weak self] event in
					DispatchQueue.main.async {
						guard let self else { return }
						switch event {
						case .started(let id):
							self.sample = .playing(providerTitle: TextToSpeechProviders.provider(id: id).title)
						case .fellBack(let reason): self.sampleNote = "\(reason). Played with the macOS voice instead."
						}
					}
				},
				{ [weak self] in
					DispatchQueue.main.async { self?.sampleFinished() }
				}) ?? false
		if !isAccepted {
			sample = .failed(reason: "Bol is talking right now. Try again when it's done.")
			scheduleSampleReset(afterSeconds: 3)
		}
	}

	private func sampleFinished() {
		switch sample {
		case _ where isSampleStoppedByUser:
			sample = .idle
		case .generating:
			sample = .failed(reason: "No audio came back. Check the key and your connection.")
			scheduleSampleReset(afterSeconds: 4)
		case .playing, .idle, .done, .failed:
			sample = .done
			scheduleSampleReset(afterSeconds: 1.6)
		}
	}

	private func scheduleSampleReset(afterSeconds seconds: Double) {
		sampleReset?.cancel()
		sampleReset = Task { @MainActor [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			guard let self, !Task.isCancelled, !self.sample.isBusy else { return }
			self.sample = .idle
		}
	}

	// MARK: Engine (Antigravity CLI + bundled brain)

	func checkEngine() {
		guard !isCheckingEngine else { return }
		isCheckingEngine = true
		Task { @MainActor in
			let status = await EngineStatus.check()
			// Keep the spinner visible briefly so "Check Again" visibly does something.
			try? await Task.sleep(nanoseconds: 350_000_000)
			let didBecomeReady = engine?.isReady != true && status.isReady
			engine = status
			isCheckingEngine = false
			if didBecomeReady { onEngineReady?() }
		}
	}

	// MARK: Instructions (appended to Antigravity's system prompt)

	func loadPrompts() {
		Task { @MainActor in
			prompts = await Task.detached(priority: .userInitiated) {
				Prompts(
					defaultText: Self.readTrimmed(url: Constants.defaultPromptFile) ?? "",
					customText: Self.readTrimmed(url: Constants.promptFile))
			}.value
		}
	}

	/// Saves instructions and restarts the brain so they take effect (the conversation continues).
	func applyPrompt(text: String) {
		guard let defaultText = prompts?.defaultText else { return }
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let isDefault = trimmed.isEmpty || trimmed == defaultText
		prompts = Prompts(defaultText: defaultText, customText: isDefault ? nil : trimmed)
		brainState = .restarting
		savedAt = Date()
		Task { @MainActor in
			await Task.detached(priority: .userInitiated) {
				if isDefault {
					try? FileManager.default.removeItem(at: Constants.promptFile)
				} else {
					try? (trimmed + "\n").write(to: Constants.promptFile, atomically: true, encoding: .utf8)
				}
			}.value
			onRestartBrain?()
		}
	}

	private static func readTrimmed(url: URL) -> String? {
		let text = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(
			in: .whitespacesAndNewlines)
		return text.isEmpty ? nil : text
	}

	// MARK: Permissions

	func refreshPermissions() {
		let status = PermissionStatus.current()
		if status != permissions { permissions = status }
	}

	// MARK: Memories

	func loadMemories() {
		Task { @MainActor in
			let items = await Task.detached(priority: .userInitiated) { Self.readMemories() }.value
			withAnimation(.easeOut(duration: 0.2)) { memories = items }
		}
	}

	func deleteMemory(item: MemoryItem) {
		Task { @MainActor in
			await Task.detached(priority: .userInitiated) {
				try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
				// Drop its line from the MEMORY.md index.
				let index = Constants.memoryIndexFile
				if let text = try? String(contentsOf: index, encoding: .utf8) {
					let kept = text.components(separatedBy: "\n").filter { !$0.contains("(\(item.id))") }
					try? kept.joined(separator: "\n").write(to: index, atomically: true, encoding: .utf8)
				}
			}.value
			loadMemories()
		}
	}

	private static func readMemories() -> [MemoryItem] {
		let fileManager = FileManager.default
		try? fileManager.createDirectory(at: Constants.memoryDirectory, withIntermediateDirectories: true)
		let files =
			(try? fileManager.contentsOfDirectory(at: Constants.memoryDirectory, includingPropertiesForKeys: nil)) ?? []
		return
			files
			.filter { $0.pathExtension == "md" && $0 != Constants.memoryIndexFile }
			.map { url in
				let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
				func field(name: String) -> String {
					guard let range = text.range(of: "(?m)^\\s*\(name):\\s*(.+)$", options: .regularExpression) else {
						return ""
					}
					return String(text[range]).components(separatedBy: ":").dropFirst().joined(separator: ":")
						.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
				}
				let name = field(name: "name")
				return MemoryItem(
					id: url.lastPathComponent,
					name: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name,
					description: field(name: "description"), type: field(name: "type"), url: url)
			}
			.sorted { $0.name < $1.name }
	}

	// MARK: General

	func setLaunchAtLogin(isOn: Bool) {
		launchError = nil
		do {
			if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
		} catch {
			Log.info(message: "launch at login: \(error)")
			launchError = "macOS didn't allow it: \(error.localizedDescription)"
		}
		isLaunchingAtLogin = SMAppService.mainApp.status == .enabled
	}
}
