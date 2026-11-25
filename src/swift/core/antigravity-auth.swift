import Foundation

/// The Antigravity authentication state on this Mac (`~/.gemini/google_accounts.json` and OAuth/keychain
/// credentials, or Gemini API / ADC environment credentials).
enum AntigravityAuth {
	struct Account: Equatable {
		/// Active signed-in email when available, e.g. "user@gmail.com".
		let email: String?
		let detail: String
	}

	static var loginCommand: String { "\(AntigravityCLI.shellPath) acp --login" }

	private static let geminiDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini")
	private static let securityTool = URL(fileURLWithPath: "/usr/bin/security")

	/// The signed-in Antigravity account, or nil when no active credentials are present.
	static func account() async -> Account? {
		if let email = activeGoogleAccountEmail(), await hasOAuthCredentials() {
			return Account(email: email, detail: email)
		}
		if hasGeminiEnvAuth() {
			return Account(email: nil, detail: "Gemini API / ADC")
		}
		return nil
	}

	private static func activeGoogleAccountEmail() -> String? {
		let accountsFile = geminiDirectory.appendingPathComponent("google_accounts.json")
		guard let data = try? Data(contentsOf: accountsFile),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let active = object["active"] as? String
		else { return nil }
		let trimmed = active.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private static func hasOAuthCredentials() async -> Bool {
		let fm = FileManager.default
		let oauthFile = geminiDirectory.appendingPathComponent("oauth_creds.json")
		if fm.fileExists(atPath: oauthFile.path),
			let attrs = try? fm.attributesOfItem(atPath: oauthFile.path),
			(attrs[.size] as? NSNumber)?.intValue ?? 0 > 2
		{
			return true
		}
		let standaloneToken = geminiDirectory.appendingPathComponent("jetski-standalone-oauth-token")
		if fm.fileExists(atPath: standaloneToken.path),
			let attrs = try? fm.attributesOfItem(atPath: standaloneToken.path),
			(attrs[.size] as? NSNumber)?.intValue ?? 0 > 2
		{
			return true
		}
		let keychainCheck = await Shell.run(
			executable: securityTool, arguments: ["find-generic-password", "-s", "gemini"],
			timeoutSeconds: 5)
		return keychainCheck.isSuccess
	}

	private static func hasGeminiEnvAuth() -> Bool {
		let env = ProcessInfo.processInfo.environment
		if let key = env["GEMINI_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return true
		}
		return env["AGY_ADC_AUTH"] == "true"
	}
}
