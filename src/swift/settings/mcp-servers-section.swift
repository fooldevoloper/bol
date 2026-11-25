import AppKit
import SwiftUI

// MARK: - MCP servers (Settings → Assistant)

/// The user's own MCP servers: live status, on/off, add, paste a config, remove. Servers configured
/// globally in Antigravity (`~/.gemini/.../mcp_config.json`) are listed too, read-only.
struct MCPServersSection: View {
	@ObservedObject var model: SettingsModel
	@State private var sheet: Sheet?
	@State private var error: String?

	private enum Sheet: String, Identifiable {
		case add, paste
		var id: String { rawValue }
	}

	/// Servers the brain reports that aren't in mcp.json: Antigravity's own servers.
	private var otherServers: [MCPStatusReport.Server] {
		let mine = Set(model.mcpEntries.map(\.name))
		return (model.mcpReport?.servers ?? []).filter { !mine.contains($0.name) && $0.source != "dynamic" }
	}

	var body: some View {
		SettingsGroup(
			title: "MCP servers",
			footer:
				"Extra tools for Bol, kept in ~/.bol/mcp.json in the standard MCP format (HTTP or stdio). Changes apply right away, even mid-conversation.",
			trailing: AnyView(IconButton(symbol: "arrow.clockwise", help: "Check again") { model.refreshMCP() })
		) {
			ForEach(model.mcpEntries) { entry in
				let status = entry.isEnabled ? model.mcpReport?.servers.first(where: { $0.name == entry.name }) : nil
				ServerRow(
					name: entry.name, summary: entry.summary, kind: entry.kind.title, status: status,
					problem: model.mcpReport?.problems.first(where: { $0.name == entry.name })?.error,
					isEnabled: entry.isEnabled, isSigningIn: model.signingIn.contains(entry.name)
				) {
					signInButton(name: entry.name, status: status)
					Toggle(
						"",
						isOn: Binding(
							get: { entry.isEnabled },
							set: { isOn in
								run { try MCPConfig.setEnabled(name: entry.name, isEnabled: isOn) }
							})
					)
					.labelsHidden().toggleStyle(.switch).controlSize(.small)
					IconButton(symbol: "trash", help: "Remove \(entry.name)") { confirmRemove(name: entry.name) }
				}
			}
			ForEach(model.mcpReport?.problems.filter { $0.name == "mcp.json" } ?? [], id: \.name) { problem in
				Label("mcp.json \(problem.error)", systemImage: "exclamationmark.triangle.fill")
					.font(UI.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.vertical, 10)
			}
			ForEach(otherServers, id: \.name) { server in
				ServerRow(
					name: server.name, summary: Self.describe(source: server.source), kind: nil, status: server,
					problem: nil, isEnabled: true, isSigningIn: model.signingIn.contains(server.name)
				) { signInButton(name: server.name, status: server) }
			}
			if model.mcpEntries.isEmpty, otherServers.isEmpty {
				Text("No servers yet. Add one, or paste a config from Cursor, Antigravity or a server's README.")
					.font(UI.caption).foregroundStyle(.secondary)
					.padding(.horizontal, 14).padding(.vertical, 12)
			}
			HStack(spacing: 8) {
				Button("Add Server…") { sheet = .add }.buttonStyle(SubtleButtonStyle(isProminent: true))
				Button("Paste JSON…") { sheet = .paste }.buttonStyle(SubtleButtonStyle())
				Spacer()
				Button("Open mcp.json") { openFile() }.buttonStyle(SubtleButtonStyle())
			}
			.padding(.horizontal, 14).padding(.vertical, 10)
			if let error {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.font(UI.caption).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 10)
			}
		}
		.onAppear { model.refreshMCP() }
		.sheet(item: $sheet) { sheet in
			switch sheet {
			case .add: AddServerSheet(model: model, isPresented: binding(for: .add))
			case .paste: PasteServersSheet(model: model, isPresented: binding(for: .paste))
			}
		}
	}

	/// Shown while a server needs the user to sign in: opens its sign-in page in the browser.
	@ViewBuilder private func signInButton(name: String, status: MCPStatusReport.Server?) -> some View {
		if status?.status == "needs-auth" {
			if model.signingIn.contains(name) {
				HStack(spacing: 6) {
					ProgressView().controlSize(.mini)
					Button("Open Again") { model.signIn(server: name) }.buttonStyle(SubtleButtonStyle())
				}
			} else {
				Button("Sign In") { model.signIn(server: name) }.buttonStyle(SubtleButtonStyle(isProminent: true))
			}
		}
	}

	private func binding(for kind: Sheet) -> Binding<Bool> {
		Binding(get: { sheet == kind }, set: { if !$0 { sheet = nil } })
	}

	private func run(change: () throws -> Void) {
		do {
			try model.changeMCP(change: change)
			error = nil
		} catch let failure as MCPConfig.ConfigError {
			error = failure.message
		} catch {
			self.error = "Couldn't save mcp.json: \(error.localizedDescription)"
		}
	}

	private func confirmRemove(name: String) {
		let alert = NSAlert()
		alert.messageText = "Remove “\(name)”?"
		alert.informativeText = "It's deleted from ~/.bol/mcp.json and disconnected right away."
		alert.addButton(withTitle: "Remove")
		alert.addButton(withTitle: "Cancel")
		alert.buttons.first?.hasDestructiveAction = true
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		run { try MCPConfig.remove(name: name) }
	}

	/// Opens the file in the user's editor, creating an empty config first if there's none.
	private func openFile() {
		if !FileManager.default.fileExists(atPath: MCPConfig.file.path) {
			run { try MCPConfig.add(servers: [:]) }
		}
		NSWorkspace.shared.open(MCPConfig.file)
	}

	static func describe(source: String?) -> String {
		switch source {
		case "user": return "From Antigravity (~/.gemini config)"
		case "project", "local": return "From workspace MCP config"
		case "plugin": return "From an Antigravity plugin"
		case "managed", "enterprise": return "Managed by your organization"
		default: return "From Antigravity"
		}
	}
}

/// One server: status, name, what it runs, and its controls.
private struct ServerRow<Controls: View>: View {
	let name: String
	let summary: String
	let kind: String?
	let status: MCPStatusReport.Server?
	let problem: String?
	let isEnabled: Bool
	/// Its sign-in page is open in the browser.
	let isSigningIn: Bool
	@ViewBuilder var controls: Controls

	var body: some View {
		HStack(alignment: .center, spacing: 12) {
			statusIcon.frame(width: 16)
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 6) {
					Text(name).font(UI.bodyMedium).foregroundStyle(isEnabled ? .primary : .secondary)
					if let kind {
						Text(kind).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
							.padding(.horizontal, 5).padding(.vertical, 1)
							.background(Color.primary.opacity(0.07), in: Capsule())
					}
				}
				Text(summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
					.lineLimit(1).truncationMode(.middle)
				if let detail {
					Text(detail).font(UI.caption).foregroundStyle(detailColor).lineLimit(3)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 8)
			controls
		}
		.padding(.horizontal, 14).padding(.vertical, 9)
		.help(status?.error ?? problem ?? "")
	}

	private var statusIcon: some View {
		Group {
			if problem != nil {
				Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			} else if !isEnabled {
				Circle().strokeBorder(Color.secondary.opacity(0.6)).frame(width: 7, height: 7)
			} else if status?.status == "pending" || status == nil {
				ProgressView().controlSize(.mini)
			} else {
				Circle().fill(color).frame(width: 7, height: 7)
			}
		}
		.font(.system(size: 11))
	}

	private var color: Color {
		switch status?.status {
		case "connected": return .green
		case "needs-auth": return .orange
		case "failed": return .red
		default: return .secondary
		}
	}

	private var detail: String? {
		if let problem { return "Not loaded: \(problem)" }
		guard isEnabled, let status else { return isEnabled ? nil : "Off" }
		switch status.status {
		case "connected": return status.tools.map { "Connected · \($0) tool\($0 == 1 ? "" : "s")" } ?? "Connected"
		case "needs-auth":
			return isSigningIn
				? "Waiting for you to finish signing in, in your browser…"
				: "Needs sign-in. You can also say “sign me in to \(name)”"
		case "failed": return "Failed: \(status.error ?? "couldn't connect")"
		case "pending": return "Connecting…"
		default: return status.status.capitalized
		}
	}

	private var detailColor: Color {
		switch status?.status {
		case "failed": return .red
		case "needs-auth": return .orange
		default: return problem != nil ? .orange : .secondary
		}
	}
}

// MARK: - Add a server

private struct AddServerSheet: View {
	@ObservedObject var model: SettingsModel
	@Binding var isPresented: Bool
	@State private var name = ""
	@State private var kind = MCPConfig.Kind.command
	@State private var commandLine = ""
	@State private var url = ""
	@State private var pairs = ""
	@State private var error: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text("Add an MCP server").font(.system(size: 16, weight: .semibold))
			LabeledField(
				label: "Name",
				help: "Letters, digits, - and _. Tools show up as mcp__\(name.isEmpty ? "name" : name)__…"
			) {
				Field(placeholder: "github", text: $name)
			}
			LabeledField(label: "Type", help: kindHelp) {
				Picker("", selection: $kind) {
					ForEach(MCPConfig.Kind.allCases) { Text($0.title).tag($0) }
				}
				.pickerStyle(.segmented).labelsHidden().frame(width: UI.controlWidth)
			}
			switch kind {
			case .command:
				LabeledField(label: "Command", help: "The full command line; quotes work as in a shell") {
					Field(
						placeholder: "npx -y @modelcontextprotocol/server-github", text: $commandLine,
						isMonospaced: true)
				}
				LabeledField(label: "Environment", help: "One KEY=value per line, for tokens and settings") {
					PairsEditor(text: $pairs, placeholder: "GITHUB_PERSONAL_ACCESS_TOKEN=ghp_…")
				}
			case .http, .sse:
				LabeledField(label: "URL", help: "The server's endpoint") {
					Field(placeholder: "https://mcp.example.com/mcp", text: $url, isMonospaced: true)
				}
				LabeledField(label: "Headers", help: "One Name: value per line, e.g. for an API key") {
					PairsEditor(text: $pairs, placeholder: "Authorization: Bearer …")
				}
			}
			if let error {
				Label(error, systemImage: "exclamationmark.triangle.fill").font(UI.caption).foregroundStyle(.orange)
			}
			HStack {
				Text("Saved to ~/.bol/mcp.json").font(UI.caption).foregroundStyle(.tertiary)
				Spacer()
				Button("Cancel") { isPresented = false }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(
					.cancelAction)
				Button("Add") { add() }.buttonStyle(SubtleButtonStyle(isProminent: true)).keyboardShortcut(
					.defaultAction)
			}
		}
		.padding(22)
		.frame(width: 560)
		.onChange(of: kind) { _ in pairs = "" }
	}

	private var kindHelp: String {
		switch kind {
		case .command: return "A program Bol starts on this Mac (most servers)"
		case .http: return "A remote server over Streamable HTTP"
		case .sse: return "A remote server over Server-Sent Events (older)"
		}
	}

	private func add() {
		let name = name.trimmingCharacters(in: .whitespaces)
		do {
			let server = try MCPConfig.server(kind: kind, commandLine: commandLine, url: url, pairs: pairs)
			try MCPConfig.validate(name: name, server: server)
			guard !model.mcpEntries.contains(where: { $0.name == name }) else {
				throw MCPConfig.ConfigError(message: "There's already a server called “\(name)”.")
			}
			try model.changeMCP { try MCPConfig.add(servers: [name: server]) }
			isPresented = false
		} catch let failure as MCPConfig.ConfigError {
			error = failure.message
		} catch {
			self.error = "Couldn't save: \(error.localizedDescription)"
		}
	}
}

// MARK: - Paste a config

private struct PasteServersSheet: View {
	@ObservedObject var model: SettingsModel
	@Binding var isPresented: Bool
	@State private var text = ""
	@State private var name = ""
	@State private var error: String?

	private var isSingleServer: Bool {
		guard let data = text.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return false }
		return object["command"] is String || object["url"] is String
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Paste MCP config").font(.system(size: 16, weight: .semibold))
			Text(
				"Paste from Cursor, Antigravity or a server's README: a whole {\"mcpServers\": {…}} block, several servers, or a single one."
			)
			.font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			PairsEditor(
				text: $text,
				placeholder:
					"{\n  \"mcpServers\": {\n    \"filesystem\": {\n      \"command\": \"npx\",\n      \"args\": [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"/Users/me/Documents\"]\n    }\n  }\n}",
				height: 220)
			if isSingleServer {
				LabeledField(label: "Name", help: "This is a single server, so it needs a name") {
					Field(placeholder: "my-server", text: $name)
				}
			}
			if let error {
				Label(error, systemImage: "exclamationmark.triangle.fill").font(UI.caption).foregroundStyle(.orange)
			}
			HStack {
				Text("Servers with the same name are replaced").font(UI.caption).foregroundStyle(.tertiary)
				Spacer()
				Button("Cancel") { isPresented = false }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(
					.cancelAction)
				Button("Import") { importServers() }.buttonStyle(SubtleButtonStyle(isProminent: true))
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(22)
		.frame(width: 560)
		.onAppear {
			// Start from the clipboard when it holds something that looks like a config.
			if let clip = NSPasteboard.general.string(forType: .string), clip.contains("{"),
				clip.contains("command") || clip.contains("url")
			{
				text = clip
			}
		}
	}

	private func importServers() {
		do {
			let servers = try MCPConfig.servers(pasted: text, name: name)
			try model.changeMCP { try MCPConfig.add(servers: servers) }
			isPresented = false
		} catch let failure as MCPConfig.ConfigError {
			error = failure.message
		} catch {
			self.error = "Couldn't save: \(error.localizedDescription)"
		}
	}
}

// MARK: - Pieces

private struct LabeledField<Content: View>: View {
	let label: String
	let help: String
	@ViewBuilder var content: Content

	var body: some View {
		HStack(alignment: .top, spacing: 14) {
			VStack(alignment: .leading, spacing: 2) {
				Text(label).font(UI.body)
				Text(help).font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
			.frame(width: 200, alignment: .leading)
			Spacer(minLength: 0)
			content
		}
	}
}

/// A small monospaced editor with a placeholder, for env lines, headers and JSON.
private struct PairsEditor: View {
	@Binding var text: String
	let placeholder: String
	var height: CGFloat = 76
	@FocusState private var isFocused: Bool

	var body: some View {
		ZStack(alignment: .topLeading) {
			if text.isEmpty {
				Text(placeholder).font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
					.padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
			}
			TextEditor(text: $text)
				.font(.system(size: 12, design: .monospaced))
				.scrollContentBackground(.hidden)
				.focused($isFocused)
				.padding(.horizontal, 8).padding(.vertical, 6)
		}
		.frame(width: height > 100 ? nil : UI.controlWidth, height: height)
		.frame(maxWidth: height > 100 ? .infinity : nil)
		.background(UI.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 7, style: .continuous)
				.strokeBorder(
					isFocused ? Color.accentColor.opacity(0.8) : UI.fieldStroke, lineWidth: isFocused ? 1.5 : 1)
		)
	}
}
