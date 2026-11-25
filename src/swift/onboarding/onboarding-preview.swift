import AppKit
import SwiftUI

/// Debug aid: `Bol --render-onboarding <dir>` renders each setup step (in key states) to PNGs.
enum OnboardingPreview {
	@MainActor static func render(to directory: String) {
		let states:
			[(
				name: String, step: OnboardingStep, antigravityCLI: AntigravityCLICheck, account: AccountCheck,
				speech: SpeechTest, dictationApps: [DictationApp]?
			)] = [
				("1-welcome", .welcome, .checking, .checking, .idle, nil),
				("2-agy-missing", .antigravityCLI, .missing, .checking, .idle, nil),
				("3-agy-installed", .antigravityCLI, .installed(version: "1.5.17"), .checking, .idle, nil),
				("4-account-signed-out", .account, .installed(version: "1.5.17"), .signedOut, .idle, nil),
				(
					"5-account-ready", .account, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"), .idle,
					nil
				),
				(
					"6-mic-listening", .microphone, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.listening(heard: "Hello Bol, what time"), nil
				),
				(
					"7-mic-passed", .microphone, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello Bol, what time is it?"), nil
				),
				(
					"8-voice", .voice, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), nil
				),
				(
					"9-dictation", .dictation, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), []
				),
				(
					"9b-dictation-other-apps", .dictation, .installed(version: "1.5.17"),
					.ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), [DictationApps.known[0], DictationApps.known[1]]
				),
				(
					"10-permissions", .permissions, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), nil
				),
				(
					"11-autonomy", .autonomy, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), nil
				),
				(
					"13-terms", .terms, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), nil
				),
				(
					"12-ready", .ready, .installed(version: "1.5.17"), .ready(detail: "user@gmail.com"),
					.passed(heard: "Hello"), nil
				),
			]
		try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
		for state in states {
			let settings = SettingsModel(config: Config())
			let model = OnboardingModel(settings: settings)
			model.setPreviewState(
				step: state.step, antigravityCLI: state.antigravityCLI, account: state.account, microphone: .authorized,
				speechTest: state.speech, dictationApps: state.dictationApps)
			let host = NSHostingView(
				rootView: OnboardingView(model: model, settings: settings)
					.background(Color(nsColor: .windowBackgroundColor))
					.environment(\.colorScheme, .dark))
			host.appearance = NSAppearance(named: .darkAqua)
			host.frame = NSRect(x: 0, y: 0, width: 880, height: 600)
			let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
			window.appearance = NSAppearance(named: .darkAqua)
			window.backgroundColor = .windowBackgroundColor
			window.contentView = host
			host.layoutSubtreeIfNeeded()
			RunLoop.current.run(until: Date().addingTimeInterval(0.4))
			guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
			host.cacheDisplay(in: host.bounds, to: rep)
			let url = URL(fileURLWithPath: directory).appendingPathComponent("\(state.name).png")
			try? rep.representation(using: .png, properties: [:])?.write(to: url)
		}
		print("rendered \(states.count) setup steps to \(directory)")
	}
}
