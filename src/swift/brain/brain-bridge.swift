import Foundation

/// Runs the bundled brain (Antigravity ACP) and exchanges JSON lines with it.
/// The protocol mirrors src/typescript/protocol.ts.
final class BrainBridge {
	/// `job` is set when the event comes from a background job rather than the conversation.
	enum Event {
		case ready
		case tool(name: String, summary: String, job: String?)
		/// `isDelegated`: the thread's turn only handed the request to a task, so the reply is an acknowledgement.
		case result(text: String, isError: Bool, job: String?, isDelegated: Bool)
		/// The turn stopped by an interrupt has ended; it carries no answer.
		case interrupted
		/// The conversation has nothing left to do, as of request number `seq`.
		case idle(seq: Int)
		/// The brain wants the Mac operated (a click, a screenshot…); answer with `controlResult`.
		case control(id: String, action: ControlAction)
		/// How the MCP servers are doing (sent as they connect, when mcp.json changes, or on request).
		case mcpStatus(MCPStatusReport)
		case screen(reason: String, job: String?)
		/// A task started, was messaged, finished or stopped.
		case task(job: String, name: String, status: TaskStatus)
		/// The skills Bol can use (the user's Claude Code skills, plugins' and projects').
		case skills([Skill])
		/// An MCP server's sign-in page was opened in the browser (`url`), or couldn't be (`error`).
		case mcpSignIn(name: String, url: String?, error: String?)
		/// The sign-in ended: the server's status now (connected, failed, needs-auth when it timed out…).
		case mcpSignInDone(name: String, status: String)
		/// The brain process restarted: running tasks were lost.
		case restarted
	}

	struct Skill: Decodable, Equatable, Identifiable {
		let name: String
		let description: String
		let argumentHint: String?
		var id: String { name }
	}

	/// Where a task is: it runs on its own, and can be messaged again once it's done.
	enum TaskStatus: String, Decodable {
		case running, done, failed, stopped
	}

	/// The settings the brain reads at startup; changing any of them restarts it.
	private struct LaunchSettings: Equatable {
		let workingDirectory: String
		let agentModel: AgentModel
		let agentEffort: AgentEffort
		let isChromeEnabled: Bool
		let screenAccess: ScreenAccess

		init(config: Config) {
			workingDirectory = config.workingDirectory ?? Constants.workspaceDirectory.path
			agentModel = config.agentModel
			agentEffort = config.agentEffort
			isChromeEnabled = config.isChromeEnabled
			screenAccess = config.screenAccess
		}

		func environment(agy: URL) -> [String: String] {
			var env = Shell.environment
			env["BOL_AGY_PATH"] = agy.path
			env["BOL_CWD"] = workingDirectory
			env["BOL_MODEL"] = agentModel.rawValue
			env["BOL_EFFORT"] = agentEffort.rawValue
			env["BOL_CHROME"] = isChromeEnabled ? "1" : "0"
			env["BOL_SCREEN"] = screenAccess.rawValue
			return env
		}
	}

	private static let encoder = JSONEncoder()
	private static let decoder = JSONDecoder()

	var onEvent: ((Event) -> Void)?
	private var settings: LaunchSettings
	private var process: Process?
	private var stdin: FileHandle?
	private var buffer = Data()
	private var restartCount = 0

	init(config: Config) { settings = LaunchSettings(config: config) }

	func start() {
		guard process == nil else { return }
		guard let executable = BrainBundle.brainExecutable else {
			Log.info(message: "brain: bol-brain not found in the app bundle")
			onEvent?(
				.result(
					text: "My brain is missing from the app. Reinstall Bol.", isError: true, job: nil,
					isDelegated: false))
			return
		}
		guard let agy = AntigravityCLI.executable else {
			Log.info(message: "brain: Antigravity CLI not installed")
			onEvent?(
				.result(
					text: "Antigravity CLI isn't installed. Open Bol's setup to install it.", isError: true, job: nil,
					isDelegated: false))
			return
		}
		let process = Process()
		process.executableURL = executable
		process.currentDirectoryURL = executable.deletingLastPathComponent()
		process.environment = settings.environment(agy: agy)

		let inPipe = Pipe()
		let outPipe = Pipe()
		let errPipe = Pipe()
		process.standardInput = inPipe
		process.standardOutput = outPipe
		process.standardError = errPipe
		// At end of file the handler is called again and again with no data, so it must remove itself.
		outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			guard !data.isEmpty else {
				handle.readabilityHandler = nil
				return
			}
			DispatchQueue.main.async { self?.consume(data: data) }
		}
		errPipe.fileHandleForReading.readabilityHandler = { handle in
			let data = handle.availableData
			guard !data.isEmpty else {
				handle.readabilityHandler = nil
				return
			}
			Log.info(
				message:
					"brain stderr: \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))"
			)
		}
		process.terminationHandler = { [weak self] stopped in
			DispatchQueue.main.async { self?.processExited(process: stopped) }
		}
		buffer.removeAll()  // a partial line from a previous brain
		do {
			try process.run()
			self.process = process
			stdin = inPipe.fileHandleForWriting
			Log.info(message: "brain: started \(executable.path)")
		} catch {
			Log.info(message: "brain: failed to start \(error)")
		}
	}

	/// Applies new settings; restarts the brain (resuming the same session) if they changed.
	/// Returns whether it restarted.
	func update(config: Config) -> Bool {
		let newSettings = LaunchSettings(config: config)
		guard newSettings != settings else { return false }
		settings = newSettings
		guard process != nil else { return false }
		Log.info(message: "brain: settings changed, restarting")
		restart()
		return true
	}

	func restart() {
		stop()
		start()
		onEvent?(.restarted)
	}

	func stop() {
		let running = process
		process = nil  // first, so its termination isn't treated as a crash
		try? stdin?.close()
		stdin = nil
		running?.terminate()
	}

	/// `seq` numbers the request, so a late `idle` for an earlier one can be told apart.
	func say(text: String, seq: Int) { send(command: .say(text: text, seq: seq)) }
	/// A follow-up for a task (from the Threads window); a finished task picks up its session again.
	func message(task job: String, text: String) { send(command: .messageTask(job: job, text: text)) }
	func stop(task job: String) { send(command: .stopTask(job: job)) }
	/// Starts an MCP server's sign-in; the brain opens its page in the browser.
	func signIn(server name: String) { send(command: .mcpSignIn(name: name)) }
	/// The user deleted this thread: the brain lets go of it and its tasks (a new one starts if it was current).
	func forget(thread sessionId: String) { send(command: .forgetThread(sessionId: sessionId)) }
	/// Asks for an `mcpStatus` event.
	func requestMCPStatus() { send(command: .mcpStatus) }
	func controlResult(id: String, result: ControlResult) {
		send(command: .controlResult(id: id, text: result.text, isError: result.isError, images: result.imagePaths))
	}
	func interrupt() { send(command: .interrupt) }
	func reset() { send(command: .reset) }
	/// Makes an earlier thread the conversation again.
	func continueConversation(sessionId: String) { send(command: .continueSession(sessionId: sessionId)) }

	// MARK: Protocol

	private enum Command: Encodable {
		case say(text: String, seq: Int)
		case messageTask(job: String, text: String)
		case stopTask(job: String)
		case mcpSignIn(name: String)
		case forgetThread(sessionId: String)
		case interrupt
		case reset
		case continueSession(sessionId: String)
		case controlResult(id: String, text: String, isError: Bool, images: [String])
		case mcpStatus

		private enum Key: String, CodingKey {
			case type, text, job, seq, id, isError, images, sessionId, name
		}

		func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: Key.self)
			switch self {
			case .say(let text, let seq):
				try container.encode("say", forKey: .type)
				try container.encode(text, forKey: .text)
				try container.encode(seq, forKey: .seq)
			case .messageTask(let job, let text):
				try container.encode("messageTask", forKey: .type)
				try container.encode(job, forKey: .job)
				try container.encode(text, forKey: .text)
			case .stopTask(let job):
				try container.encode("stopTask", forKey: .type)
				try container.encode(job, forKey: .job)
			case .mcpSignIn(let name):
				try container.encode("mcpSignIn", forKey: .type)
				try container.encode(name, forKey: .name)
			case .forgetThread(let sessionId):
				try container.encode("forgetThread", forKey: .type)
				try container.encode(sessionId, forKey: .sessionId)
			case .interrupt:
				try container.encode("interrupt", forKey: .type)
			case .reset:
				try container.encode("reset", forKey: .type)
			case .continueSession(let sessionId):
				try container.encode("continue", forKey: .type)
				try container.encode(sessionId, forKey: .sessionId)
			case .mcpStatus:
				try container.encode("mcpStatus", forKey: .type)
			case .controlResult(let id, let text, let isError, let images):
				try container.encode("controlResult", forKey: .type)
				try container.encode(id, forKey: .id)
				try container.encode(text, forKey: .text)
				try container.encode(isError, forKey: .isError)
				try container.encode(images, forKey: .images)
			}
		}
	}

	/// Every message the brain sends. Decoding fails on unknown types or missing fields.
	private enum Message: Decodable {
		case ready
		case tool(name: String, summary: String, job: String?)
		case text(String)
		case result(text: String, isError: Bool, job: String?, isDelegated: Bool)
		case interrupted
		case idle(seq: Int)
		case control(id: String, action: ControlAction)
		case mcpStatus(MCPStatusReport)
		case screen(reason: String, job: String?)
		case task(job: String, name: String, status: TaskStatus)
		case skills([Skill])
		case mcpSignIn(name: String, url: String?, error: String?)
		case mcpSignInDone(name: String, status: String)
		case log(String)

		private enum Kind: String, Decodable {
			case ready, tool, text, result, idle, control, mcpStatus, screen, task, skills, mcpSignIn,
				mcpSignInDone, log
		}
		private enum Key: String, CodingKey {
			case type, name, summary, text, isError, isInterrupted, isDelegated, id, reason, msg, job, seq,
				action, servers,
				problems, status, skills, url, error
		}

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: Key.self)
			let job = try c.decodeIfPresent(String.self, forKey: .job)
			switch try c.decode(Kind.self, forKey: .type) {
			case .ready: self = .ready
			case .tool:
				self = .tool(
					name: try c.decode(String.self, forKey: .name),
					summary: try c.decode(String.self, forKey: .summary),
					job: job)
			case .text: self = .text(try c.decode(String.self, forKey: .text))
			case .result where try c.decodeIfPresent(Bool.self, forKey: .isInterrupted) == true:
				self = .interrupted
			case .result:
				self = .result(
					text: try c.decode(String.self, forKey: .text), isError: try c.decode(Bool.self, forKey: .isError),
					job: job, isDelegated: try c.decodeIfPresent(Bool.self, forKey: .isDelegated) ?? false)
			case .idle: self = .idle(seq: try c.decode(Int.self, forKey: .seq))
			case .mcpStatus:
				self = .mcpStatus(
					MCPStatusReport(
						servers: try c.decode([MCPStatusReport.Server].self, forKey: .servers),
						problems: try c.decode([MCPStatusReport.Problem].self, forKey: .problems)))
			case .control:
				self = .control(
					id: try c.decode(String.self, forKey: .id),
					action: try c.decode(ControlAction.self, forKey: .action))
			case .screen: self = .screen(reason: try c.decode(String.self, forKey: .reason), job: job)
			case .task:
				self = .task(
					job: try c.decode(String.self, forKey: .job), name: try c.decode(String.self, forKey: .name),
					status: try c.decode(TaskStatus.self, forKey: .status))
			case .skills: self = .skills(try c.decode([Skill].self, forKey: .skills))
			case .mcpSignIn:
				self = .mcpSignIn(
					name: try c.decode(String.self, forKey: .name),
					url: try c.decodeIfPresent(String.self, forKey: .url),
					error: try c.decodeIfPresent(String.self, forKey: .error))
			case .mcpSignInDone:
				self = .mcpSignInDone(
					name: try c.decode(String.self, forKey: .name), status: try c.decode(String.self, forKey: .status))
			case .log: self = .log(try c.decode(String.self, forKey: .msg))
			}
		}
	}

	private func send(command: Command) {
		if process == nil { start() }
		guard let stdin, var data = try? Self.encoder.encode(command) else { return }
		data.append(0x0A)
		stdin.write(data)
	}

	private func consume(data: Data) {
		buffer.append(data)
		while let newline = buffer.firstIndex(of: 0x0A) {
			let line = buffer.subdata(in: buffer.startIndex..<newline)
			buffer.removeSubrange(buffer.startIndex...newline)
			do {
				handle(message: try Self.decoder.decode(Message.self, from: line))
			} catch {
				Log.info(message: "brain: bad message \(String(decoding: line.prefix(200), as: UTF8.self)): \(error)")
			}
		}
	}

	private func handle(message: Message) {
		switch message {
		case .ready:
			restartCount = 0
			onEvent?(.ready)
		case .tool(let name, let summary, let job): onEvent?(.tool(name: name, summary: summary, job: job))
		case .text: break  // interim narration; only the final result is spoken
		case .result(let text, let isError, let job, let isDelegated):
			onEvent?(.result(text: text, isError: isError, job: job, isDelegated: isDelegated))
		case .interrupted: onEvent?(.interrupted)
		case .idle(let seq): onEvent?(.idle(seq: seq))
		case .control(let id, let action): onEvent?(.control(id: id, action: action))
		case .mcpStatus(let report): onEvent?(.mcpStatus(report))
		case .task(let job, let name, let status): onEvent?(.task(job: job, name: name, status: status))
		case .skills(let skills): onEvent?(.skills(skills))
		case .mcpSignIn(let name, let url, let error): onEvent?(.mcpSignIn(name: name, url: url, error: error))
		case .mcpSignInDone(let name, let status): onEvent?(.mcpSignInDone(name: name, status: status))
		case .screen(let reason, let job): onEvent?(.screen(reason: reason, job: job))
		case .log(let message): Log.info(message: "brain: \(message)")
		}
	}

	private func processExited(process stopped: Process) {
		guard process === stopped else { return }  // stopped on purpose
		Log.info(message: "brain: exited with \(stopped.terminationStatus)")
		process = nil
		stdin = nil
		onEvent?(.result(text: "My brain process stopped. Restarting it.", isError: true, job: nil, isDelegated: false))
		onEvent?(.restarted)
		restartCount += 1
		guard restartCount < Constants.maxBrainRestarts else { return }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
	}
}
