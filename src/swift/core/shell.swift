import Foundation

enum Shell {
	struct Result {
		let status: Int32
		let output: String
		var isSuccess: Bool { status == 0 }
	}

	/// PATH that GUI apps don't get by default.
	static var augmentedPath: String {
		let home = NSHomeDirectory()
		let extra = [
			"\(home)/.local/bin", "\(home)/.gemini/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
			"/usr/bin", "/bin",
			"/usr/sbin",
			"/sbin",
		]
		let existing = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
		var seen = Set<String>()
		return (extra + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
	}

	static var environment: [String: String] {
		var env = ProcessInfo.processInfo.environment
		env["PATH"] = augmentedPath
		return env
	}

	/// Runs a program to completion (or until the timeout kills it) and returns its stdout.
	@discardableResult
	static func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval = 60) async -> Result {
		await withCheckedContinuation { continuation in
			let process = Process()
			process.executableURL = executable
			process.arguments = arguments
			process.environment = environment
			let pipe = Pipe()
			process.standardOutput = pipe
			process.standardError = FileHandle.nullDevice
			let output = OutputBuffer()
			pipe.fileHandleForReading.readabilityHandler = { handle in output.append(data: handle.availableData) }
			process.terminationHandler = { finished in
				pipe.fileHandleForReading.readabilityHandler = nil
				output.append(data: pipe.fileHandleForReading.readDataToEndOfFile())
				continuation.resume(returning: Result(status: finished.terminationStatus, output: output.text))
			}
			do {
				try process.run()
			} catch {
				continuation.resume(returning: Result(status: -1, output: ""))
				return
			}
			DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
				if process.isRunning { process.terminate() }
			}
		}
	}

	static func which(name: String) -> URL? {
		augmentedPath.split(separator: ":")
			.map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
	}

	/// Collects a pipe's output from its reader thread.
	private final class OutputBuffer: @unchecked Sendable {
		private let lock = NSLock()
		private var data = Data()

		func append(data chunk: Data) {
			lock.lock()
			data.append(chunk)
			lock.unlock()
		}

		var text: String {
			lock.lock()
			defer { lock.unlock() }
			return String(decoding: data, as: UTF8.self)
		}
	}
}
