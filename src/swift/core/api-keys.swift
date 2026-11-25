import Foundation

/// Third-party API keys. One key can serve several providers (OpenAI: speech-to-text and voice).
enum APIKeyID: String, CaseIterable, Identifiable {
	case openai, gemini, noiz

	var id: String { rawValue }

	var title: String {
		switch self {
		case .openai: return "OpenAI"
		case .gemini: return "Google Gemini"
		case .noiz: return "Noiz AI"
		}
	}

	/// A cheap authenticated request that tells whether the key works.
	fileprivate func validationRequest(key: String) -> URLRequest {
		var request: URLRequest
		switch self {
		case .openai:
			request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-4o-mini-tts")!)
			request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		case .gemini:
			request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!)
			request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
		case .noiz:
			request = URLRequest(url: URL(string: "https://noiz.ai/v1/voices?voice_type=built-in&limit=1")!)
			request.setValue(key, forHTTPHeaderField: "Authorization")  // Noiz takes the raw key
		}
		request.timeoutInterval = 12
		return request
	}
}

/// Keys are either absent (nil) or non-empty: empty strings never get stored.
struct APIKeys: Codable, Equatable {
	private var openai: String? = nil
	private var gemini: String? = nil
	private var noiz: String? = nil

	subscript(id: APIKeyID) -> String? {
		get {
			switch id {
			case .openai: return openai
			case .gemini: return gemini
			case .noiz: return noiz
			}
		}
		set {
			let key = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
			let normalized = key?.isEmpty == true ? nil : key
			switch id {
			case .openai: openai = normalized
			case .gemini: gemini = normalized
			case .noiz: noiz = normalized
			}
		}
	}
}

enum KeyValidation: Equatable {
	case missing, checking, valid
	case invalid(reason: String)
}

extension APIKeyID {
	func validate(key: String) async -> KeyValidation {
		do {
			let (data, response) = try await URLSession.shared.data(for: validationRequest(key: key))
			let status = (response as? HTTPURLResponse)?.statusCode ?? 0
			// Noiz reports errors in the body ("code") with HTTP 200.
			let apiCode = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? Int
			if status == 400 || status == 401 || status == 403 || apiCode == 401 {
				return .invalid(reason: "Key was rejected")
			}
			if status == 429 || apiCode == 429 { return .valid }  // rate-limited but authenticated
			if status == 200, apiCode == nil || apiCode == 0 || apiCode == 200 { return .valid }
			return .invalid(reason: "Unexpected response (\(status))")
		} catch {
			return .invalid(reason: "Couldn't reach the service")
		}
	}
}

/// What a speech provider needs before it can run.
enum ProviderCredential: Equatable {
	case none
	case apiKey(APIKeyID)

	func isSatisfied(by config: Config) -> Bool {
		switch self {
		case .none: return true
		case .apiKey(let id): return config.apiKeys[id] != nil
		}
	}
}
