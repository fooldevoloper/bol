import Foundation

/// What Bol's brain needs: the Antigravity CLI (`agy`) installed, and signed in.
struct EngineStatus: Equatable {
	struct Step: Equatable, Identifiable {
		let id: String
		let title: String
		let isDone: Bool
		let detail: String
		let fixHint: String
		let fixCommand: String
	}

	var agyVersion: String?
	var account: AntigravityAuth.Account?

	var isInstalled: Bool { agyVersion != nil }
	var isSignedIn: Bool { account != nil }
	var isReady: Bool { isInstalled && isSignedIn }

	var steps: [Step] {
		[
			Step(
				id: "install", title: "Antigravity CLI installed", isDone: isInstalled,
				detail: agyVersion.map { "Version \($0)" } ?? "Not installed",
				fixHint: "Install Antigravity CLI:", fixCommand: AntigravityCLI.installCommand),
			Step(
				id: "login", title: "Signed in to Antigravity", isDone: isSignedIn,
				detail: account?.detail ?? "Not signed in",
				fixHint: "Sign in with your Google account:",
				fixCommand: AntigravityAuth.loginCommand),
		]
	}

	static func check() async -> EngineStatus {
		async let version = AntigravityCLI.version()
		async let account = AntigravityAuth.account()
		return EngineStatus(agyVersion: await version, account: await account)
	}
}
