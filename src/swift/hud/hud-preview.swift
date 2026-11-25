import AppKit
import SwiftUI

/// Debug aid: `Bol --render-hud <dir>` renders every voice-bar state to PNGs (the live bar is
/// excluded from screen capture, so this is how its design gets reviewed).
enum HUDPreview {
	@MainActor static func render(to dir: String) {
		let states: [(String, (HUDModel) -> Void)] = [
			(
				"1-listening-empty",
				{ m in
					m.phase = .listening
					m.status = "Listening"
				}
			),
			(
				"2-listening-text",
				{ m in
					m.phase = .listening
					m.status = "Listening"
					m.text = "turn on do not disturb and open my calendar for tomorrow"
				}
			),
			(
				"3-thinking",
				{ m in
					m.phase = .thinking
					m.status = "Working"
					m.text = "turn on do not disturb and open my calendar for tomorrow"
					m.activity = "Turning on Do Not Disturb"
					m.activityIcon = "terminal"
					m.steps = 3
					m.startedAt = Date().addingTimeInterval(-7)
				}
			),
			(
				"4-looking",
				{ m in
					m.phase = .looking
					m.status = "Looking at your screen"
					m.text = "what's this error?"
					m.activity = "Reading the error in Xcode"
					m.activityIcon = "eye"
					m.steps = 1
				}
			),
			(
				"5-speaking",
				{ m in
					m.phase = .speaking
					m.status = "Bol"
					m.context = "what's on my calendar tomorrow?"
					m.text =
						"You've got three things tomorrow: standup at 10, lunch with Priya at 1, and the design review at 4. Want me to block focus time in the morning?"
				}
			),
			(
				"6-followup",
				{ m in
					m.phase = .followUp
					m.status = "Listening for a follow-up"
					m.context =
						"You've got three things tomorrow: standup at 10, lunch with Priya at 1, and the design review at 4."
					m.deadline = Date().addingTimeInterval(4)
					m.deadlineTotal = 6
				}
			),
			(
				"9b-replied-long-markdown",
				{ m in
					m.phase = .replied
					m.isSilent = true
					m.status = "Bol"
					m.context = "Remove Bol confirmations"
					m.text = """
						I've removed the confirmation feature completely, and the new build is installed. Restart Bol to pick it up.

						- **What changed:** Antigravity now runs in full bypass mode, so every action goes ahead without a prompt.
						- **What I deleted:** the risky-command checker, the yes/no prompt in the voice bar, and the `Confirm risky actions` setting.
						- **Screen setting:** its "Ask first" option used the same prompt, so I removed it. If you had it on, it now counts as automatic.

						## Tests
						All 62 tests pass. Nothing is committed: your folder already had a lot of uncommitted work, so I left it for you to review.
						1. Open Settings
						2. Check the [Assistant pane](https://example.com)
						3. Restart Bol and try a risky command to confirm it just runs, then ask it something long enough that the reply has to scroll inside the voice bar.
						"""
					m.deadline = Date().addingTimeInterval(3)
					m.deadlineTotal = 5
				}
			),
			(
				"9c-listening-attachment",
				{ m in
					m.phase = .listening
					m.status = "Listening"
					m.attachments = [
						URL(fileURLWithPath: "/Users/me/Desktop/CleanShot 2026-11-18 at 6.50.03 PM@2x.png")
					]
				}
			),
			(
				"9d-drop-zone",
				{ m in
					m.phase = .dropZone
					m.status = "Bol"
					m.isDragActive = true
					m.isDropTargeted = true
				}
			),
			(
				"9-replied-silent",
				{ m in
					m.phase = .replied
					m.isSilent = true
					m.status = "Bol"
					m.context = "how much battery do I have?"
					m.text = "You're at 82%, about 6 hours left."
					m.deadline = Date().addingTimeInterval(3)
					m.deadlineTotal = 5
				}
			),
			(
				"10-notice",
				{ m in
					m.phase = .notice
					m.status = "Silent mode on"
					m.text = "Replies appear here without being spoken"
					m.noticeIcon = "speaker.slash.fill"
					m.deadline = Date().addingTimeInterval(1)
					m.deadlineTotal = 1.8
				}
			),
			(
				"11-error",
				{ m in
					m.phase = .error
					m.status = "Not signed in to Antigravity"
					m.text = "Run `agy acp --login` in a terminal."
					m.deadline = Date().addingTimeInterval(6)
					m.deadlineTotal = 8
				}
			),
			(
				"13-dictating",
				{ m in
					m.phase = .dictating
					m.status = "Dictating"
					m.context = "Slack"
					m.text = "sounds good, I'll send the deck over by Friday"
				}
			),
			(
				"14-dictating-locked",
				{ m in
					m.phase = .dictating
					m.status = "Dictating"
					m.context = "Notes"
					m.isDictationLocked = true
				}
			),
			(
				"12-hover",
				{ m in
					m.phase = .speaking
					m.isHovering = true
					m.status = "Bol"
					m.context = "summarize this page"
					m.text = "It's a launch post for a new note-taking app with offline sync and end-to-end encryption."
				}
			),
		]
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		for (name, setup) in states {
			let m = HUDModel()
			m.isVisible = true
			m.inputLevel = { 0.45 }
			m.outputLevel = { 0.5 }
			setup(m)
			let view = ZStack {
				LinearGradient(
					colors: [Color(red: 0.16, green: 0.32, blue: 0.48), Color(red: 0.36, green: 0.55, blue: 0.62)],
					startPoint: .top, endPoint: .bottom)
				HUDView(model: m)
			}
			.frame(width: 760, height: 520)
			let r = ImageRenderer(content: view)
			r.scale = 2
			if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
				let png = rep.representation(using: .png, properties: [:])
			{
				try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
			}
		}
		print("rendered \(states.count) states to \(dir)")
	}
}

extension HUDPreview {
	/// Dev aid: `Bol --render-hud-spec <spec.json> <dir>` renders custom voice-bar states on a transparent
	/// background (for video edits). spec = [{"name","phase","status","text","context","activity","icon","steps","scale"}].
	@MainActor static func renderSpec(specPath: String, to dir: String) {
		guard let data = FileManager.default.contents(atPath: specPath),
			let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
		else {
			print("bad spec")
			return
		}
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		let phases: [String: HUDPhase] = [
			"listening": .listening, "thinking": .thinking, "speaking": .speaking, "looking": .looking,
			"followUp": .followUp, "replied": .replied, "dictating": .dictating, "dropZone": .dropZone,
		]
		for it in items {
			let m = HUDModel()
			m.isVisible = true
			m.inputLevel = { 0.55 }
			m.outputLevel = { 0.55 }
			m.phase = phases[it["phase"] as? String ?? "listening"] ?? .listening
			m.status = it["status"] as? String ?? ""
			m.text = it["text"] as? String ?? ""
			m.context = it["context"] as? String ?? ""
			m.activity = it["activity"] as? String ?? ""
			m.activityIcon = it["icon"] as? String ?? "sparkle"
			m.steps = it["steps"] as? Int ?? 0
			m.startedAt = Date().addingTimeInterval(-(it["elapsed"] as? Double ?? 3))
			let view = HUDView(model: m).frame(width: 760).fixedSize(horizontal: false, vertical: true)
			let r = ImageRenderer(content: view)
			r.scale = it["scale"] as? Double ?? 3
			r.isOpaque = false
			if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
				let png = rep.representation(using: .png, properties: [:])
			{
				try? png.write(
					to: URL(fileURLWithPath: dir).appendingPathComponent("\(it["name"] as? String ?? "x").png"))
			}
		}
		print("rendered \(items.count) states to \(dir)")
	}
}
