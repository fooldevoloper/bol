import AVFoundation
import AppKit
import ApplicationServices
import Speech

/// The macOS privacy permissions Bol uses. Child processes (the brain, Antigravity CLI, osascript)
/// inherit them from Bol.app. Automation prompts appear per app the first time Bol controls it.
enum MacPermission: String, CaseIterable, Identifiable {
	case microphone, speechRecognition, accessibility, screenRecording, systemAudio, folders, fullDiskAccess

	static var hasSpeechRecognition: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

	var id: String { rawValue }

	var title: String {
		switch self {
		case .microphone: return "Microphone"
		case .speechRecognition: return "Speech Recognition"
		case .accessibility: return "Accessibility"
		case .screenRecording: return "Screen Recording"
		case .systemAudio: return "System Audio Recording"
		case .folders: return "Desktop, Documents & Downloads"
		case .fullDiskAccess: return "Full Disk Access"
		}
	}

	var icon: String {
		switch self {
		case .microphone: return "mic"
		case .speechRecognition: return "waveform"
		case .accessibility: return "accessibility"
		case .screenRecording: return "rectangle.dashed"
		case .systemAudio: return "speaker.wave.2"
		case .folders: return "folder"
		case .fullDiskAccess: return "internaldrive"
		}
	}

	/// Why Bol asks, in a few words.
	var purpose: String {
		switch self {
		case .microphone: return "Hear you when you press \(ShortcutState.shared.talkText)"
		case .speechRecognition: return "Transcribe your voice with Apple Speech on your Mac"
		case .accessibility: return "Click, type and control apps for you"
		case .screenRecording: return "See your screen when a request needs it"
		case .systemAudio: return "Turn other apps down while you talk and Bol speaks"
		case .folders: return "Work with your files without stopping to ask mid-task"
		case .fullDiskAccess: return "Read Mail, Messages, Safari and other app data"
		}
	}

	enum Importance {
		/// Bol can't work without it.
		case required
		/// Bol works without it, but can't do much of what it's for.
		case recommended
		/// Extra reach for some requests.
		case optional

		var title: String {
			switch self {
			case .required: return "Required"
			case .recommended: return "Recommended"
			case .optional: return "Optional"
			}
		}
	}

	var importance: Importance {
		switch self {
		case .microphone: return .required
		case .accessibility, .screenRecording, .folders: return .recommended
		case .speechRecognition, .systemAudio, .fullDiskAccess: return .optional
		}
	}

	private var settingsAnchor: String {
		switch self {
		case .microphone: return "Privacy_Microphone"
		case .speechRecognition: return "Privacy_SpeechRecognition"
		case .accessibility: return "Privacy_Accessibility"
		case .screenRecording: return "Privacy_ScreenCapture"
		case .systemAudio: return "Privacy_AudioCapture"
		case .folders: return "Privacy_FilesAndFolders"
		case .fullDiskAccess: return "Privacy_AllFiles"
		}
	}

	/// The folders macOS guards with a per-app prompt. Bol's tools read them through Bol, so an
	/// unanswered prompt would silently stall a request (worst of all a background one).
	private static let guardedFolders = ["Desktop", "Documents", "Downloads"].map {
		URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0)
	}
	/// Checking a guarded folder shows the prompt, so it's only checked after Bol has asked once.
	private static let foldersRequestedKey = "hasRequestedFolderAccess"

	var isGranted: Bool {
		switch self {
		case .microphone:
			return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
		case .speechRecognition:
			return Self.hasSpeechRecognition
		case .accessibility:
			return AXIsProcessTrusted()
		case .screenRecording:
			return CGPreflightScreenCaptureAccess()
		case .systemAudio:
			return SystemAudioAccess.status() == .granted
		case .fullDiskAccess:
			// Can't be queried directly; the TCC database is only readable with it.
			let tcc = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db")
			return (try? FileHandle(forReadingFrom: tcc))?.readData(ofLength: 1).isEmpty == false
		case .folders:
			guard UserDefaults.standard.bool(forKey: Self.foldersRequestedKey) else { return false }
			return Self.guardedFolders.allSatisfy {
				(try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) != nil
			}
		}
	}

	/// Shows the system prompt where macOS has one, otherwise opens the right System Settings pane.
	func request() {
		switch self {
		case .microphone:
			switch AVCaptureDevice.authorizationStatus(for: .audio) {
			case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { _ in }
			case .denied, .restricted, .authorized: openSettings()
			@unknown default: openSettings()
			}
		case .speechRecognition:
			switch SFSpeechRecognizer.authorizationStatus() {
			case .notDetermined: SFSpeechRecognizer.requestAuthorization { _ in }
			case .denied, .restricted, .authorized: openSettings()
			@unknown default: openSettings()
			}
		case .accessibility:
			let isTrusted = AXIsProcessTrustedWithOptions(
				[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
			if !isTrusted { openSettings() }
		case .screenRecording:
			if !CGRequestScreenCaptureAccess() { openSettings() }
		case .systemAudio:
			switch SystemAudioAccess.status() {
			case .unknown: SystemAudioAccess.request()
			case .granted, .denied: openSettings()
			}
		case .folders:
			UserDefaults.standard.set(true, forKey: Self.foldersRequestedKey)
			// Each first read shows its prompt and waits for the answer, so ask off the main thread.
			DispatchQueue.global(qos: .userInitiated).async {
				for folder in Self.guardedFolders {
					_ = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
				}
				if !MacPermission.folders.isGranted {
					DispatchQueue.main.async { MacPermission.folders.openSettings() }
				}
			}
		case .fullDiskAccess:
			openSettings()
		}
	}

	func openSettings() {
		guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") else {
			return
		}
		NSWorkspace.shared.open(url)
	}
}

/// "System Audio Recording": what lets Bol turn other apps down (an audio tap of everything but
/// Bol). macOS has no public call to check or ask for it, so this uses TCC's own, as Apple's sample
/// code for audio taps does. A tap without it would hand Bol silence while muting the Mac.
enum SystemAudioAccess {
	enum Status { case granted, denied, unknown }

	private static let service = "kTCCServiceAudioCapture" as CFString
	private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
	private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
	private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

	static func status() -> Status {
		guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
		switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
		case 0: return .granted
		case 1: return .denied
		default: return .unknown
		}
	}

	/// Shows the system prompt (once; after that only System Settings can change it).
	static func request() {
		guard let symbol = dlsym(tcc, "TCCAccessRequest") else {
			MacPermission.systemAudio.openSettings()
			return
		}
		unsafeBitCast(symbol, to: Request.self)(service, nil) { isGranted in
			Log.info(message: "system audio access: \(isGranted ? "granted" : "denied")")
		}
	}
}

/// Which permissions are granted right now.
struct PermissionStatus: Equatable {
	let granted: Set<MacPermission>

	static func current() -> PermissionStatus {
		PermissionStatus(granted: Set(MacPermission.allCases.filter(\.isGranted)))
	}

	func isGranted(permission: MacPermission) -> Bool { granted.contains(permission) }
}
