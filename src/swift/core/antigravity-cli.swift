import Foundation

/// The Antigravity CLI (`agy`) installed on this Mac. Bol's brain runs its ACP harness on it.
enum AntigravityCLI {
	/// The official installer, shown to the user before it runs.
	static let installCommand = "curl -fsSL https://antigravity.google/cli/install.sh | bash"

	static var executable: URL? { Shell.which(name: "agy") }

	/// The installed path for typing into a shell, short and readable: `~/.local/bin/agy`.
	static var shellPath: String {
		guard let path = executable?.path else { return "agy" }
		let short = path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
		return short.contains(" ") ? "\"\(path)\"" : short
	}

	/// e.g. "1.5.17"; nil when not installed or not runnable.
	static func version() async -> String? {
		guard let executable else { return nil }
		let result = await Shell.run(executable: executable, arguments: ["--version"], timeoutSeconds: 10)
		guard result.isSuccess else { return nil }
		return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
			.split(separator: " ")
			.first
			.map(String.init)
	}
}
