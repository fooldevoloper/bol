import SwiftUI

// MARK: - Skills (Settings → Assistant)

/// The Antigravity skills Bol can use: your own (~/.gemini/skills, ~/.agents/skills), plugins' and your
/// workspace's. Ask for one by name ("use my release skill"), or just ask: Bol picks a skill when a request fits it.
struct SkillsSection: View {
	@ObservedObject var model: SettingsModel
	@State private var isShowingAll = false
	private static let shownCount = 6

	var body: some View {
		let skills = model.skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		SettingsGroup(
			title: "Skills",
			footer:
				"Your Antigravity skills, plugins' and workspace skills. Say “use my <name> skill”, or just ask: Bol uses one when it fits. Add skills in ~/.gemini/skills or ~/.agents/skills."
		) {
			if skills.isEmpty {
				Text("No skills found yet. They're listed once Bol has started.")
					.font(UI.caption).foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 14).padding(.vertical, 12)
			}
			ForEach(isShowingAll ? skills : Array(skills.prefix(Self.shownCount))) { skill in
				HStack(alignment: .firstTextBaseline, spacing: 12) {
					Image(systemName: "wand.and.stars").font(.system(size: 11)).foregroundStyle(.secondary)
						.frame(width: 16)
					VStack(alignment: .leading, spacing: 2) {
						Text(skill.name).font(UI.bodyMedium)
						if !skill.description.isEmpty {
							Text(skill.description).font(UI.caption).foregroundStyle(.secondary).lineLimit(2)
								.fixedSize(horizontal: false, vertical: true)
						}
					}
					Spacer(minLength: 0)
				}
				.padding(.horizontal, 14).padding(.vertical, 8)
			}
			if skills.count > Self.shownCount {
				Button(isShowingAll ? "Show fewer" : "Show all \(skills.count)") { isShowingAll.toggle() }
					.buttonStyle(.plain).font(UI.caption).foregroundStyle(.secondary)
					.padding(.horizontal, 14).padding(.vertical, 9)
			}
		}
	}
}
