import Foundation

enum ToolStyle {
	/// Monochrome SF Symbols per kind of tool.
	static func icon(name: String) -> String {
		let lower = name.lowercased()
		if name == "Bash" || name.hasPrefix("Bash") || name == "run_command" || name == "command_status"
			|| name == "send_command_input"
		{
			return "terminal"
		}
		if name == "Read" || name == "view_file" || name == "view_file_outline" || name == "view_code_item" {
			return "doc.text"
		}
		if name == "Write" || name == "Edit" || name == "MultiEdit" || name == "NotebookEdit" || name == "write_to_file"
			|| name == "create_file" || name == "replace_file_content" || name == "multi_replace_file_content"
			|| name == "edit_file"
		{
			return "square.and.pencil"
		}
		if name == "Glob" || name == "Grep" || name == "ToolSearch" || name == "find_by_name" || name == "find_file"
			|| name == "grep_search" || name == "search_directory" || name == "list_dir" || name == "list_directory"
		{
			return "magnifyingglass"
		}
		if name == "WebSearch" || name == "WebFetch" || name == "search_web" || name == "read_url_content" {
			return "globe"
		}
		if name == "Agent" || name == "Task" || name == "invoke_subagent" || name == "start_subagent"
			|| lower.contains("start_task") || lower.contains("message_task")
		{
			return "person.2"
		}
		if name == "TodoWrite" { return "checklist" }
		if lower.contains("chrome") { return "safari" }
		if lower.contains("screenshot") || lower.contains("look_at_screen") || lower.contains("zoom") {
			return "camera.viewfinder"
		}
		if lower.contains("click") || lower.contains("scroll") || lower.contains("drag") || lower.contains("mouse") {
			return "cursorarrow"
		}
		if lower.contains("type") || lower.contains("key") { return "keyboard" }
		if lower.contains("clipboard") { return "doc.on.clipboard" }
		if lower.contains("open_application") { return "app" }
		if lower.contains("memory") { return "tray.full" }
		return "wrench.and.screwdriver"
	}
}

enum Format {
	static func tokens(_ count: Int) -> String {
		if count >= 1_000_000 {
			let millions = Double(count) / 1_000_000
			return millions == millions.rounded() ? "\(Int(millions))M" : String(format: "%.1fM", millions)
		}
		if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))k" }
		return "\(count)"
	}

	static func model(id: String) -> String {
		// e.g. gemini-4-hydrogen -> Gemini 4 Hydrogen, claude-opus-5-5 -> Opus 5.5
		if id.hasPrefix("claude-") {
			let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
			guard let family = parts.first else { return id }
			let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
			return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " \(version)")
		}
		return id.split(separator: "-")
			.map { $0.prefix(1).uppercased() + $0.dropFirst() }
			.joined(separator: " ")
	}

	static func relative(date: Date, now: Date) -> String {
		let seconds = now.timeIntervalSince(date)
		if seconds < 60 { return "just now" }
		if Calendar.current.isDate(date, inSameDayAs: now) {
			let formatter = RelativeDateTimeFormatter()
			formatter.unitsStyle = .abbreviated
			return formatter.localizedString(for: date, relativeTo: now)
		}
		return dateTime(date: date)
	}

	/// The sidebar's time column: "now", "5m", "3h", "2d", then the date.
	static func compact(date: Date, now: Date) -> String {
		let seconds = max(0, now.timeIntervalSince(date))
		if seconds < 60 { return "now" }
		if seconds < 3600 { return "\(Int(seconds / 60))m" }
		if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
		if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
		let formatter = DateFormatter()
		formatter.setLocalizedDateFormatFromTemplate("MMMd")
		return formatter.string(from: date)
	}

	/// How long a turn took: "42s", "3m 12s", "1h 4m".
	static func duration(seconds: TimeInterval) -> String {
		let total = Int(seconds.rounded())
		if total < 60 { return "\(total)s" }
		if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
		return "\(total / 3600)h \(total % 3600 / 60)m"
	}

	static func dateTime(date: Date) -> String {
		let formatter = DateFormatter()
		formatter.doesRelativeDateFormatting = true
		formatter.dateStyle = .medium
		formatter.timeStyle = .short
		return formatter.string(from: date)
	}

	/// "Wednesday 18 Nov", with the year when it isn't this one.
	static func day(date: Date) -> String {
		let formatter = DateFormatter()
		let isThisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
		formatter.setLocalizedDateFormatFromTemplate(isThisYear ? "EEEEdMMM" : "EEEEdMMMy")
		return formatter.string(from: date)
	}

	static func time(date: Date) -> String {
		let formatter = DateFormatter()
		formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
		formatter.timeStyle = .short
		return formatter.string(from: date)
	}

	static func markdown(_ text: String) -> AttributedString {
		(try? AttributedString(
			markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
			?? AttributedString(text)
	}
}

/// The sidebar's groups, in order: what's running, then by when it was last active.
enum ThreadSection: CaseIterable {
	case working, today, yesterday, week, older

	var title: String {
		switch self {
		case .working: return "Working"
		case .today: return "Today"
		case .yesterday: return "Yesterday"
		case .week: return "Previous 7 days"
		case .older: return "Older"
		}
	}

	static func of(thread: ThreadSummary, now: Date) -> ThreadSection {
		if thread.isLive(now: now) { return .working }
		let calendar = Calendar.current
		if calendar.isDate(thread.lastActivity, inSameDayAs: now) { return .today }
		if calendar.isDateInYesterday(thread.lastActivity) { return .yesterday }
		if now.timeIntervalSince(thread.lastActivity) < 7 * 86_400 { return .week }
		return .older
	}
}
