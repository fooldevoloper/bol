import Foundation

/// One Claude Code session transcript (`~/.claude/projects/<cwd>/<session id>.jsonl`), reduced to what
/// the Threads window shows: what the user said, what Bol said, the tools it ran and their results.
struct ThreadTranscript: Equatable {
	var items: [TranscriptItem] = []
	var model: String? = nil
	/// Tokens in the context window on the latest request (input + cache read + cache write).
	var contextTokens: Int? = nil
	var lastActivity: Date? = nil

	/// What was said, and what each step did, for the sidebar's search.
	var searchableText: String {
		items.map { item in
			switch item.kind {
			case .user(let text, let notes): return ([text] + notes).joined(separator: "\n")
			case .assistant(let text), .summary(let text): return text
			case .tool(let call): return call.label + "\n" + call.summary
			case .task(let mention): return mention.name + "\n" + mention.text
			case .compaction: return ""
			}
		}.joined(separator: "\n")
	}

	/// What Bol (or a task) said last.
	var lastReply: String? {
		for item in items.reversed() {
			if case .assistant(let text) = item.kind { return text }
		}
		return nil
	}

	/// What the thread is about: the first thing the user asked.
	var title: String? {
		for item in items {
			if case .user(let text, _) = item.kind, !text.isEmpty { return text }
		}
		return nil
	}
}

struct TranscriptItem: Identifiable, Equatable {
	let id: String
	let date: Date?
	/// Copied from the conversation this thread was forked from, before it started.
	var isInherited = false
	/// Claude Code's stand-in for a failed API call ("Failed to authenticate…"), not something Bol said.
	var isError = false
	var kind: Kind

	enum Kind: Equatable {
		/// What the user said, plus the bracketed notes Bol sent along with it (background task updates…).
		case user(text: String, notes: [String])
		case assistant(text: String)
		case tool(ToolCall)
		/// Bol started a task, or sent one a follow-up.
		case task(TaskMention)
		/// Claude Code compacted the conversation here: everything before is replaced by a summary.
		case compaction(trigger: String, tokensBefore: Int?)
		case summary(text: String)
	}
}

struct ToolCall: Equatable {
	let id: String
	let name: String
	let input: String
	var result: ToolResult? = nil
	/// The tool's input as one line: the command's description, the file, the query…
	let summary: String
	/// What the step did, as a short phrase: "Read hud.swift", "Searched for “TODO”".
	var label = ""
}

/// A task the thread started (`start_task`) or messaged (`message_task`).
struct TaskMention: Equatable {
	let name: String
	/// The brief, or the follow-up.
	let text: String
	let isStart: Bool
	/// What the tool answered ("Started task…", or why it didn't).
	var reply: String? = nil
	var isRefused: Bool { reply.map { !$0.hasPrefix("Started") && !$0.hasPrefix("Sent") } ?? false }
}

struct ToolResult: Equatable {
	let text: String
	/// Base64 image data (screenshots), decoded only when shown.
	let images: [String]
	let isError: Bool
}

enum TranscriptParser {
	/// Parses a transcript file's contents. Entries older than `since` (a fork's copied history) are
	/// marked inherited.
	static func parse(data: Data, since: Date? = nil) -> ThreadTranscript {
		var transcript = ThreadTranscript()
		var toolIndex: [String: Int] = [:]
		for line in data.split(separator: UInt8(ascii: "\n")) {
			guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
			if entry["isSidechain"] as? Bool == true { continue }  // subagent chatter
			let uuid = entry["uuid"] as? String ?? UUID().uuidString
			let date = (entry["timestamp"] as? String).flatMap(parseDate)
			if let date { transcript.lastActivity = max(transcript.lastActivity ?? date, date) }
			let inherited = isInheritedEntry(date: date, since: since)
			let message = entry["message"] as? [String: Any]

			let isError = entry["isApiErrorMessage"] as? Bool == true
			func append(id: String, kind: TranscriptItem.Kind) {
				transcript.items.append(
					TranscriptItem(id: id, date: date, isInherited: inherited, isError: isError, kind: kind))
			}

			switch entry["type"] as? String {
			case "system":
				guard entry["subtype"] as? String == "compact_boundary" else { break }
				let meta = entry["compactMetadata"] as? [String: Any]
				append(
					id: uuid,
					kind: .compaction(
						trigger: meta?["trigger"] as? String ?? "auto", tokensBefore: meta?["preTokens"] as? Int))
			case "assistant":
				guard let message else { break }
				if let model = message["model"] as? String, model != "<synthetic>" { transcript.model = model }
				if let usage = message["usage"] as? [String: Any] {
					let total = [
						"input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
						"inputTokens", "cachedReadTokens", "cachedWriteTokens",
					]
					.compactMap { usage[$0] as? Int }.reduce(0, +)
					if total > 0 { transcript.contextTokens = total }
				}
				for (i, block) in blocks(message["content"]).enumerated() {
					switch block["type"] as? String {
					case "text":
						let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
						if !text.isEmpty { append(id: "\(uuid)-\(i)", kind: .assistant(text: text)) }
					case "tool_use":
						let id = block["id"] as? String ?? "\(uuid)-\(i)"
						let name = block["name"] as? String ?? "tool"
						let input = block["input"] as? [String: Any] ?? [:]
						toolIndex[id] = transcript.items.count
						if name == "mcp_bol_start_task" || name == "mcp_bol_message_task"
							|| name == "mcp__bol__start_task" || name == "mcp__bol__message_task"
						{
							let isStart = name == "mcp_bol_start_task" || name == "mcp__bol__start_task"
							append(
								id: id,
								kind: .task(
									TaskMention(
										name: input["name"] as? String ?? "Task",
										text: input[isStart ? "brief" : "text"] as? String ?? "", isStart: isStart)))
							continue
						}
						append(
							id: id,
							kind: .tool(
								ToolCall(
									id: id, name: name, input: prettyJSON(input),
									summary: summarize(name: name, input: input), label: label(name: name, input: input)
								)))
					default: break  // thinking (empty on current models), redacted thinking
					}
				}
			case "user":
				guard let message, entry["isMeta"] as? Bool != true else { break }
				if entry["isCompactSummary"] as? Bool == true {
					append(id: uuid, kind: .summary(text: plainText(message["content"])))
					break
				}
				if let text = message["content"] as? String {
					appendUser(text: text, id: uuid, append: append)
					break
				}
				var texts: [String] = []
				for block in blocks(message["content"]) {
					switch block["type"] as? String {
					case "tool_result":
						guard let id = block["tool_use_id"] as? String, let index = toolIndex[id] else { continue }
						switch transcript.items[index].kind {
						case .tool(var call):
							call.result = toolResult(block: block)
							transcript.items[index].kind = .tool(call)
						case .task(var mention):
							mention.reply = toolResult(block: block).text
							transcript.items[index].kind = .task(mention)
						case .user, .assistant, .compaction, .summary:
							break
						}
					case "text":
						if let text = block["text"] as? String { texts.append(text) }
					default: break
					}
				}
				if !texts.isEmpty { appendUser(text: texts.joined(separator: "\n\n"), id: uuid, append: append) }
			default: break  // attachments, bookkeeping lines
			}
		}
		return transcript
	}

	/// The first thing the user asked, read from the start of a transcript without parsing all of it.
	static func title(data: Data) -> String? {
		if let given = givenTitle(data: data) { return given }
		for line in data.split(separator: UInt8(ascii: "\n"), maxSplits: 400).prefix(400) {
			guard line.count < 200_000,
				let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
				entry["type"] as? String == "user", entry["isMeta"] as? Bool != true,
				entry["isCompactSummary"] as? Bool != true,
				let message = entry["message"] as? [String: Any]
			else { continue }
			let text =
				(message["content"] as? String)
				?? blocks(message["content"]).filter { $0["type"] as? String == "text" }
				.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
			let (request, _) = splitNotes(text: text)
			if !request.isEmpty { return request }
		}
		return nil
	}

	/// The latest title a session was given (`custom-title`, or Claude Code's own `ai-title`), read from the end.
	static func givenTitle(data: Data) -> String? {
		for (type, key) in [("custom-title", "customTitle"), ("ai-title", "aiTitle")] {
			guard let match = data.range(of: Data("\"type\":\"\(type)\"".utf8), options: .backwards) else {
				continue
			}
			let newline = UInt8(ascii: "\n")
			let start = data[..<match.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
			let end = data[match.upperBound...].firstIndex(of: newline) ?? data.endIndex
			guard let entry = (try? JSONSerialization.jsonObject(with: data[start..<end])) as? [String: Any],
				let title = (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
			else { continue }
			return title
		}
		return nil
	}

	/// A note Bol sent along with a request, as the window shows it: what happened, not the instructions
	/// it gave the model. nil for notes that are only instructions.
	static func describe(note: String) -> (icon: String, text: String)? {
		func quoted(_ text: String) -> [String] {
			text.components(separatedBy: "\"").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
		}
		if note.hasPrefix("You are running this one request as a background task") { return nil }
		if note.hasPrefix("The user started a background task") {
			return ("square.stack.3d.up", "Started a background task")
		}
		if note.hasPrefix("A background task finished") { return ("checkmark.circle", "A background task finished") }
		if note.hasPrefix("Task \""), let name = quoted(note).first {
			let isFailed = note.hasPrefix("Task \"\(name)\" failed")
			return (isFailed ? "xmark.circle" : "checkmark.circle", "\(name) \(isFailed ? "failed" : "finished")")
		}
		if note.hasPrefix("The user sent task \""), let name = quoted(note).first {
			let message = quoted(note).dropFirst().first.map { ": \($0)" } ?? ""
			return ("arrow.turn.down.right", "You messaged \(name)\(message)")
		}
		return ("info.circle", note)
	}

	/// Bol sends notes ("[A background task finished…]") ahead of what the user said, as separate
	/// bracketed paragraphs. Returns the request without them, and the notes.
	static func splitNotes(text: String) -> (request: String, notes: [String]) {
		var notes: [String] = []
		var rest: [String] = []
		for paragraph in text.components(separatedBy: "\n\n") {
			let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty { continue }
			if rest.isEmpty, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
				notes.append(String(trimmed.dropFirst().dropLast()))
			} else {
				rest.append(trimmed)
			}
		}
		return (rest.joined(separator: "\n\n"), notes)
	}

	/// A tool's display name: `mcp_bol_screenshot` / `mcp__bol__screenshot` → "screenshot".
	static func displayName(tool name: String) -> String {
		if name.hasPrefix("mcp_bol_") {
			return String(name.dropFirst("mcp_bol_".count)).replacingOccurrences(of: "_", with: " ")
		}
		if name.hasPrefix("mcp__bol__") {
			return String(name.dropFirst("mcp__bol__".count)).replacingOccurrences(of: "_", with: " ")
		}
		let doubleParts = name.components(separatedBy: "__")
		if doubleParts.count >= 3, doubleParts[0] == "mcp" {
			return "\(doubleParts[1]) · \(doubleParts[2...].joined(separator: "__"))"
		}
		if name.hasPrefix("mcp_") {
			let parts = name.dropFirst("mcp_".count).split(separator: "_", maxSplits: 1).map(String.init)
			if parts.count == 2 { return "\(parts[0]) · \(parts[1])" }
		}
		return name
	}

	/// A step as a short phrase, the way t3code's work log reads: "Read hud.swift", "Edited config.swift",
	/// "Searched for “TODO”". Commands use their description; other tools fall back to name and summary.
	static func label(name: String, input: [String: Any]) -> String {
		func string(_ key: String) -> String? {
			guard let value = input[key] as? String, !value.isEmpty else { return nil }
			return oneLine(value.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
		}
		func file(_ key: String) -> String? { string(key).map { ($0 as NSString).lastPathComponent } }
		let summary = summarize(name: name, input: input)
		switch name {
		case "Bash": return string("description") ?? string("command").map { "Ran \($0)" } ?? "Ran a command"
		case "run_command":
			return string("CommandLine").map { "Ran \($0)" } ?? "Ran a command"
		case "Read": return file("file_path").map { "Read \($0)" } ?? "Read a file"
		case "view_file": return file("AbsolutePath").map { "Read \($0)" } ?? "Read a file"
		case "Edit", "MultiEdit", "NotebookEdit": return file("file_path").map { "Edited \($0)" } ?? "Edited a file"
		case "edit_file", "replace_file_content", "multi_replace_file_content":
			return file("TargetFile").map { "Edited \($0)" } ?? "Edited a file"
		case "Write": return file("file_path").map { "Wrote \($0)" } ?? "Wrote a file"
		case "create_file", "write_to_file":
			return (file("TargetFile") ?? file("file_path")).map { "Wrote \($0)" } ?? "Wrote a file"
		case "Grep", "grep_search":
			return (string("pattern") ?? string("Query")).map { "Searched for “\($0)”" } ?? "Searched files"
		case "Glob", "find_by_name", "find_file", "list_dir", "list_directory":
			return (string("pattern") ?? string("Pattern")).map { "Listed \($0)" } ?? "Listed files"
		case "WebSearch", "search_web":
			return (string("query") ?? string("Query")).map { "Searched the web for “\($0)”" } ?? "Searched the web"
		case "WebFetch", "read_url_content":
			let host = (string("url") ?? string("Url")).flatMap { URL(string: $0)?.host }
			return host.map { "Read \($0)" } ?? "Read a web page"
		case "Agent", "Task", "invoke_subagent", "start_subagent":
			return (string("description") ?? string("Role")).map { "Agent: \($0)" } ?? "Ran an agent"
		case "TodoWrite": return "Updated the plan"
		case "ToolSearch": return "Looked up tools"
		default:
			let display = displayName(tool: name)
			return summary.isEmpty ? display.prefix(1).uppercased() + display.dropFirst() : "\(display) · \(summary)"
		}
	}

	// MARK: - Helpers

	private static func appendUser(
		text: String, id: String, append: (_ id: String, _ kind: TranscriptItem.Kind) -> Void
	) {
		let (request, notes) = splitNotes(text: text)
		if request.isEmpty, notes.isEmpty { return }
		append(id, .user(text: request, notes: notes))
	}

	private static func isInheritedEntry(date: Date?, since: Date?) -> Bool {
		guard let date, let since else { return false }
		return date < since
	}

	private static func blocks(_ content: Any?) -> [[String: Any]] {
		content as? [[String: Any]] ?? []
	}

	private static func plainText(_ content: Any?) -> String {
		if let text = content as? String { return text }
		return blocks(content).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
	}

	private static func toolResult(block: [String: Any]) -> ToolResult {
		var texts: [String] = []
		var images: [String] = []
		if let text = block["content"] as? String { texts.append(text) }
		for part in blocks(block["content"]) {
			switch part["type"] as? String {
			case "text": if let text = part["text"] as? String { texts.append(text) }
			case "image":
				if let source = part["source"] as? [String: Any], let data = source["data"] as? String {
					images.append(data)
				}
			case "tool_reference":
				if let name = part["tool_name"] as? String { texts.append("Loaded \(displayName(tool: name))") }
			default: break
			}
		}
		return ToolResult(
			text: texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), images: images,
			isError: block["is_error"] as? Bool == true)
	}

	private static func summarize(name: String, input: [String: Any]) -> String {
		let home = NSHomeDirectory()
		func string(_ key: String) -> String? {
			guard let value = input[key] as? String, !value.isEmpty else { return nil }
			return value.replacingOccurrences(of: home, with: "~")
		}
		if let actions = input["actions"] as? [[String: Any]] {
			// computer_batch: "click → type “https://…” → screenshot"
			return oneLine(
				actions.map { action in
					let name = (action["action"] as? String ?? "?").replacingOccurrences(of: "_", with: " ")
					guard let text = action["text"] as? String, !text.isEmpty else { return name }
					return "\(name) “\(oneLine(text))”"
				}.joined(separator: " → "))
		}
		let preferred = [
			"description", "file_path", "path", "query", "url", "pattern", "command", "text", "app", "prompt", "action",
		]
		for key in preferred { if let value = string(key) { return oneLine(value) } }
		if let first = input.keys.sorted().compactMap({ string($0) }).first { return oneLine(first) }
		return ""
	}

	private static func oneLine(_ text: String) -> String {
		let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
		return line.count > 160 ? String(line.prefix(160)) + "…" : line
	}

	private static func prettyJSON(_ object: [String: Any]) -> String {
		guard !object.isEmpty,
			let data = try? JSONSerialization.data(
				withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
			let text = String(data: data, encoding: .utf8)
		else { return "" }
		return text
	}

	private static let dateFormatter: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	static func parseDate(_ text: String) -> Date? { dateFormatter.date(from: text) }
}
