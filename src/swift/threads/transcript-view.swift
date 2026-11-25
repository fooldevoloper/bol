import AppKit
import SwiftUI

// MARK: - Header

struct ThreadHeader: View {
	let thread: ThreadSummary
	let transcript: ThreadTranscript?
	/// The conversation ⌘J talks in.
	let isCurrent: Bool
	let now: Date
	let talk: () -> Void

	var body: some View {
		HStack(alignment: .center, spacing: 16) {
			VStack(alignment: .leading, spacing: 5) {
				Text(thread.title).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.tail)
				HStack(spacing: 6) {
					Image(systemName: thread.isBackground ? "square.stack.3d.down.right" : "bubble.left")
						.font(.system(size: 10, weight: .medium))
					Text(thread.isBackground ? "Background task" : "Conversation")
					Text("·")
					Text("Started \(Format.dateTime(date: thread.startedAt))")
					if let model = transcript?.model {
						Text("·")
						Text(Format.model(id: model))
					}
				}
				.font(UI.caption)
				.foregroundStyle(.secondary)
			}
			Spacer(minLength: 0)
			if let transcript, let tokens = transcript.contextTokens {
				ContextMeter(tokens: tokens, window: Constants.contextWindow(model: transcript.model ?? ""))
			}
			TalkButton(isCurrent: isCurrent, isBusy: !isCurrent && thread.isLive(now: now), action: talk)
		}
		.padding(.horizontal, 24)
		.padding(.top, 12)
		.padding(.bottom, 14)
	}
}

/// Talk to Bol in this thread: the current one directly, an older one by continuing it.
private struct TalkButton: View {
	let isCurrent: Bool
	/// A background task still working: it can be continued once it's done.
	let isBusy: Bool
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: "mic").font(.system(size: 11, weight: .semibold))
				Text(isCurrent ? "Talk to Bol" : "Continue here").font(.system(size: 12.5, weight: .medium))
			}
			.foregroundStyle(.primary)
			.padding(.horizontal, 12)
			.frame(height: 28)
			.background(
				Capsule().fill(Color.primary.opacity(isHovering ? 0.14 : 0.09))
			)
			.overlay(Capsule().strokeBorder(UI.hairline))
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.disabled(isBusy)
		.opacity(isBusy ? 0.45 : 1)
		.onHover { isHovering = $0 }
		.help(
			isBusy
				? "Still working. You can continue it here once it's done."
				: isCurrent
					? "This is the current conversation. Talk to Bol here (\(ShortcutState.shared.talkText))."
					: "Make this the current conversation and talk to Bol about it. \(ShortcutState.shared.talkText) will continue here from now on."
		)
	}
}

/// How full the context window was on the latest request.
private struct ContextMeter: View {
	let tokens: Int
	let window: Int

	var body: some View {
		let fraction = min(1, Double(tokens) / Double(window))
		VStack(alignment: .trailing, spacing: 5) {
			Text("\(Format.tokens(tokens)) of \(Format.tokens(window)) context")
				.font(.system(size: 11, weight: .medium).monospacedDigit())
				.foregroundStyle(.secondary)
			ZStack(alignment: .leading) {
				Capsule().fill(Color.primary.opacity(0.08))
				Capsule().fill(Color.primary.opacity(0.55)).frame(width: max(3, 120 * fraction))
			}
			.frame(width: 120, height: 4)
		}
		.help(
			"Tokens in the conversation on its latest request. Antigravity compacts automatically as it nears the limit."
		)
	}
}

// MARK: - Timeline

/// How a thread's task cards find their task and open it.
struct TaskLinks {
	let task: (_ name: String) -> TaskSummary?
	let open: (_ taskId: String) -> Void
	let now: Date
}

struct TranscriptView: View {
	let threadId: String
	let transcript: ThreadTranscript
	let isLive: Bool
	/// nil inside a task: tasks don't start tasks.
	var taskLinks: TaskLinks? = nil
	@State private var isShowingInherited = false
	/// The end of the thread is on screen: new messages keep it there.
	@State private var isAtBottom = true

	private static let maxWidth: CGFloat = 736  // t3code's 46rem

	var body: some View {
		let entries = TimelineEntry.make(
			items: transcript.items, isLive: isLive, isShowingInherited: isShowingInherited)
		let dividers = TimelineEntry.timeDividers(entries: entries)
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 20) {
					ForEach(entries) { entry in
						if let date = dividers[entry.id] {
							Divided { Text(Format.dateTime(date: date)) }.padding(.top, 4)
						}
						EntryView(entry: entry, taskLinks: taskLinks, isShowingInherited: $isShowingInherited)
							.opacity(entry.isInherited ? 0.55 : 1)
					}
					if transcript.items.isEmpty {
						Text("Nothing in this thread yet.").font(UI.caption).foregroundStyle(.tertiary)
					}
					Color.clear.frame(height: 1).id("bottom")
						.onAppear { isAtBottom = true }
						.onDisappear { isAtBottom = false }
				}
				.frame(maxWidth: Self.maxWidth)
				.padding(.horizontal, 28)
				.padding(.top, 22)
				.padding(.bottom, 40)
				.frame(maxWidth: .infinity)
				.textSelection(.enabled)
			}
			.overlay(alignment: .bottom) {
				if !isAtBottom {
					ScrollToEndPill(isLive: isLive) {
						withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
					}
					.padding(.bottom, 14)
					.transition(.opacity.combined(with: .move(edge: .bottom)))
				}
			}
			.animation(.easeOut(duration: 0.15), value: isAtBottom)
			.onAppear { DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) } }
			.onChange(of: threadId) { _ in
				isShowingInherited = false
				DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
			}
			.onChange(of: transcript.lastActivity) { _ in
				// Follow a running task only while you're at the end; don't yank you away from reading.
				guard isAtBottom else { return }
				withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
			}
		}
	}
}

private struct ScrollToEndPill: View {
	let isLive: Bool
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 6) {
				Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
				Text(isLive ? "Scroll to end · Working" : "Scroll to end").font(.system(size: 12, weight: .medium))
			}
			.foregroundStyle(.secondary)
			.padding(.horizontal, 12)
			.frame(height: 28)
			.background(.regularMaterial, in: Capsule())
			.overlay(Capsule().strokeBorder(UI.hairline))
			.shadow(color: .black.opacity(isHovering ? 0.3 : 0.2), radius: 8, y: 3)
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}
}

private struct EntryView: View {
	let entry: TimelineEntry
	let taskLinks: TaskLinks?
	@Binding var isShowingInherited: Bool
	@State private var isSummaryExpanded = false

	var body: some View {
		switch entry {
		case .inherited(let count, let isShowing):
			Button {
				withAnimation(.easeOut(duration: 0.15)) { isShowingInherited.toggle() }
			} label: {
				Divided {
					Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .medium))
					Text(
						isShowing
							? "Hide the earlier conversation"
							: "Forked from the main conversation · show \(count) earlier message\(count == 1 ? "" : "s")"
					)
				}
			}
			.buttonStyle(.plain)
		case .prompt(let item):
			if case .user(let text, let notes) = item.kind { PromptView(text: text, notes: notes, date: item.date) }
		case .reply(let item):
			if case .assistant(let text) = item.kind {
				if item.isError {
					ErrorView(text: text, date: item.date)
				} else {
					ReplyView(text: text, date: item.date)
				}
			}
		case .work(let work):
			WorkView(work: work)
		case .task(let item):
			if case .task(let mention) = item.kind {
				TaskCard(mention: mention, date: item.date, links: taskLinks)
			}
		case .marker(let item):
			switch item.kind {
			case .compaction(let trigger, let tokensBefore):
				Divided {
					Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .medium))
					Text(
						"Context compacted\(trigger == "manual" ? "" : " automatically")"
							+ (tokensBefore.map { " · \(Format.tokens($0)) tokens summarized" } ?? ""))
				}
			case .summary(let text):
				Disclosure(title: "Summary carried forward", isExpanded: $isSummaryExpanded) {
					CodeBlock(text: text, limit: 6000)
				}
			case .user, .assistant, .tool, .task:
				EmptyView()
			}
		}
	}
}

/// What you said: a bubble on the right, with the notes Bol sent along above it.
private struct PromptView: View {
	let text: String
	let notes: [String]
	let date: Date?
	@State private var isHovering = false
	@State private var isExpanded = false

	/// Longer than this (a task's brief, a pasted document) shows its first lines until asked.
	private static let foldAt = 420
	private static let foldedLines = 5

	var body: some View {
		let isLong = text.count > Self.foldAt
		VStack(alignment: .trailing, spacing: 8) {
			ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
				if let described = TranscriptParser.describe(note: note) {
					NoteView(icon: described.icon, text: described.text, fullText: note)
				}
			}
			if !text.isEmpty {
				VStack(alignment: .trailing, spacing: 4) {
					VStack(alignment: .leading, spacing: 6) {
						Text(text)
							.font(.system(size: 13.5))
							.lineSpacing(2.5)
							.lineLimit(isLong && !isExpanded ? Self.foldedLines : nil)
						if isLong {
							Button(isExpanded ? "Show less" : "Show more") {
								withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
							}
							.buttonStyle(.plain)
							.font(.system(size: 11.5, weight: .medium))
							.foregroundStyle(.secondary)
						}
					}
					.padding(.horizontal, 13)
					.padding(.vertical, 9)
					.background(
						Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
					HStack(spacing: 4) {
						CopyButton(text: text)
						if let date { Text(Format.time(date: date)) }
					}
					.font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
					.opacity(isHovering ? 1 : 0)
				}
				.frame(maxWidth: 560, alignment: .trailing)
			}
		}
		.frame(maxWidth: .infinity, alignment: .trailing)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}

/// What Bol said: full-width markdown, no bubble.
private struct ReplyView: View {
	let text: String
	let date: Date?
	@State private var isHovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			MarkdownView(text: text)
			HStack(spacing: 4) {
				if let date { Text(Format.time(date: date)) }
				CopyButton(text: text)
			}
			.font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
			.opacity(isHovering ? 1 : 0)
		}
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}

/// A request that failed before Bol could answer (sign-in, rate limit, server error): Claude Code's message, marked.
private struct ErrorView: View {
	let text: String
	let date: Date?

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
				.foregroundStyle(Color.red.opacity(0.8))
			Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
			if let date {
				Text(Format.time(date: date)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.red.opacity(0.18)))
	}
}

/// A turn's steps. Folded to "Worked for 42s · 6 steps" once the turn is done; open, with a live
/// timer, while it runs.
private struct WorkView: View {
	let work: TimelineEntry.Work
	@State private var isExpanded: Bool
	@State private var isShowingAll = false
	@State private var isHovering = false

	/// A running turn shows only its latest steps until asked.
	private static let recentCount = 8

	init(work: TimelineEntry.Work) {
		self.work = work
		_isExpanded = State(initialValue: work.isRunning)
	}

	var body: some View {
		let calls = work.calls
		let failed = calls.filter { $0.result?.isError == true }.count
		VStack(alignment: .leading, spacing: 6) {
			Button {
				withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
			} label: {
				HStack(spacing: 7) {
					Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
						.rotationEffect(.degrees(isExpanded ? 90 : 0))
						.frame(width: 10)
					let steps = calls.isEmpty ? "" : " · \(calls.count) step\(calls.count == 1 ? "" : "s")"
					if work.isRunning {
						ProgressView().controlSize(.mini)
						RunningTime(since: work.startedAt, suffix: steps)
					} else {
						Text((work.duration.map { "Worked for \(Format.duration(seconds: $0))" } ?? "Worked") + steps)
					}
					if failed > 0 {
						HStack(spacing: 3) {
							Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
							Text("\(failed) failed")
						}
						.foregroundStyle(Color.red.opacity(0.75))
					}
					Spacer(minLength: 8)
					if let end = work.endedAt, !work.isRunning {
						Text(Format.time(date: end)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(
							.tertiary
						)
						.opacity(isHovering ? 1 : 0)
					}
				}
				.font(.system(size: 12.5))
				.foregroundStyle(isHovering ? .primary : .secondary)
				.frame(height: 24)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { isHovering = $0 }
			if isExpanded { steps }
		}
		.onChange(of: work.isRunning) { isRunning in
			// A finished turn folds away, as in t3code.
			if !isRunning { withAnimation(.easeOut(duration: 0.2)) { isExpanded = false } }
		}
	}

	private var steps: some View {
		let hidden = isShowingAll ? 0 : max(0, work.items.count - Self.recentCount)
		return VStack(alignment: .leading, spacing: 0) {
			if hidden > 0 {
				Button("Show \(hidden) earlier step\(hidden == 1 ? "" : "s")") { isShowingAll = true }
					.buttonStyle(.plain)
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(.secondary)
					.padding(.horizontal, 12)
					.frame(height: 28)
				Rectangle().fill(UI.hairline).frame(height: 1)
			}
			ForEach(Array(work.items.dropFirst(hidden).enumerated()), id: \.element.id) { index, item in
				if index > 0 { Rectangle().fill(UI.hairline).frame(height: 1).padding(.leading, 38) }
				switch item.kind {
				case .tool(let call):
					ToolRow(call: call, isRunning: work.isRunning && item.id == work.items.last?.id)
				case .assistant(let text):
					// What Bol said between steps.
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Image(systemName: "text.bubble").font(.system(size: 10.5)).frame(width: 18)
							.foregroundStyle(.tertiary)
						MarkdownView(text: text, fontSize: 12.5).foregroundStyle(.secondary)
					}
					.padding(.horizontal, 10)
					.padding(.vertical, 8)
				case .user, .compaction, .summary, .task:
					EmptyView()
				}
			}
		}
		.padding(.vertical, 2)
		.background(UI.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(UI.hairline))
	}
}

/// A task the thread started (a card that opens it), or a follow-up it sent one (a line).
private struct TaskCard: View {
	let mention: TaskMention
	let date: Date?
	let links: TaskLinks?
	@State private var isHovering = false

	private var task: TaskSummary? { links?.task(mention.name) }

	var body: some View {
		if mention.isRefused {
			HStack(spacing: 6) {
				Image(systemName: "square.stack.3d.up.slash").font(.system(size: 10.5))
				Text("“\(mention.name)” wasn't \(mention.isStart ? "started" : "messaged"): \(mention.reply ?? "")")
					.lineLimit(2)
			}
			.font(.system(size: 12)).foregroundStyle(.tertiary)
		} else if mention.isStart {
			card
		} else {
			followUp
		}
	}

	private var card: some View {
		Button {
			if let task { links?.open(task.id) }
		} label: {
			VStack(alignment: .leading, spacing: 7) {
				HStack(spacing: 8) {
					Image(systemName: "square.stack.3d.up").font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
					Text(mention.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
					Text("Task").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
					Spacer(minLength: 8)
					status
					Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold))
						.foregroundStyle(.tertiary)
				}
				Text(mention.text).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
					.multilineTextAlignment(.leading)
				if let result = task?.result, let links, task?.isLive(now: links.now) == false {
					Rectangle().fill(UI.hairline).frame(height: 1)
					Text(result).font(.system(size: 12.5)).lineLimit(3).multilineTextAlignment(.leading)
				}
			}
			.padding(12)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(Color.primary.opacity(isHovering ? 0.06 : 0.035))
			)
			.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.hairline))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(task == nil)
		.onHover { isHovering = $0 }
		.help(task == nil ? "This task's session isn't available" : "Open the task: see its work and message it")
	}

	@ViewBuilder private var status: some View {
		HStack(spacing: 5) {
			if let task, let links {
				if task.isLive(now: links.now) {
					ProgressView().controlSize(.mini)
					Text("Working")
				} else if let last = task.lastActivity {
					Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
					Text("Done · \(Format.compact(date: last, now: links.now))")
				} else {
					Text("Unavailable")
				}
			} else if let date, Date().timeIntervalSince(date) < 60 {
				ProgressView().controlSize(.mini)
				Text("Starting")
			}
		}
		.font(.system(size: 11).monospacedDigit())
		.foregroundStyle(.secondary)
	}

	private var followUp: some View {
		Button {
			if let task { links?.open(task.id) }
		} label: {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Image(systemName: "arrow.turn.down.right").font(.system(size: 10.5))
				Text("To \(mention.name):").fontWeight(.medium)
				Text(mention.text).lineLimit(2).multilineTextAlignment(.leading)
			}
			.font(.system(size: 12))
			.foregroundStyle(isHovering ? .primary : .secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(task == nil)
		.onHover { isHovering = $0 }
	}
}

/// A message box: Return sends, Option-Return adds a line.
struct Composer: View {
	let placeholder: String
	let onSend: (String) -> Void
	@State private var text = ""
	@State private var wasSent = false
	@FocusState private var isFocused: Bool

	private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

	var body: some View {
		HStack(alignment: .bottom, spacing: 8) {
			TextField(wasSent ? "Sent. Add more…" : placeholder, text: $text, axis: .vertical)
				.textFieldStyle(.plain)
				.font(.system(size: 13))
				.lineLimit(1...6)
				.focused($isFocused)
				.onSubmit(send)
				.padding(.vertical, 3)
			Button(action: send) {
				Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
					.foregroundStyle(trimmed.isEmpty ? Color.secondary : Color(nsColor: .windowBackgroundColor))
					.frame(width: 24, height: 24)
					.background(Circle().fill(trimmed.isEmpty ? Color.primary.opacity(0.08) : Color.primary))
			}
			.buttonStyle(.plain)
			.disabled(trimmed.isEmpty)
			.help("Send (Return)")
		}
		.padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
		.background(UI.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.strokeBorder(isFocused ? Color.primary.opacity(0.25) : UI.fieldStroke))
	}

	private func send() {
		let message = trimmed
		guard !message.isEmpty else { return }
		onSend(message)
		text = ""
		wasSent = true
	}
}

/// "Working for 12s", ticking.
private struct RunningTime: View {
	let since: Date?
	let suffix: String
	var body: some View {
		if let since {
			TimelineView(.periodic(from: since, by: 1)) { context in
				Text("Working for \(Format.duration(seconds: context.date.timeIntervalSince(since)))\(suffix)")
					.monospacedDigit()
			}
		} else {
			Text("Working\(suffix)")
		}
	}
}

private struct ToolRow: View {
	let call: ToolCall
	let isRunning: Bool
	@State private var isExpanded = false
	@State private var isHovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: ToolStyle.icon(name: call.name)).font(.system(size: 11)).frame(width: 18)
					.foregroundStyle(call.result?.isError == true ? Color.red.opacity(0.7) : .secondary)
				Text(call.label.isEmpty ? TranscriptParser.displayName(tool: call.name) : call.label)
					.font(.system(size: 12.5))
					.lineLimit(1).truncationMode(.tail)
				Spacer(minLength: 8)
				status
			}
			.frame(height: 28)
			.contentShape(Rectangle())
			.onTapGesture { withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() } }
			.onHover { isHovering = $0 }
			.help(call.summary)
			if isExpanded {
				VStack(alignment: .leading, spacing: 10) {
					if !call.input.isEmpty {
						Labeled(title: "Input · \(TranscriptParser.displayName(tool: call.name))") {
							CodeBlock(text: call.input, limit: 4000)
						}
					}
					if let result = call.result {
						Labeled(title: result.isError ? "Error" : "Result") {
							VStack(alignment: .leading, spacing: 8) {
								if !result.text.isEmpty { CodeBlock(text: result.text, limit: 4000) }
								ForEach(Array(result.images.enumerated()), id: \.offset) { _, data in
									ScreenshotView(base64: data)
								}
							}
						}
					}
				}
				.padding(.leading, 26)
				.padding(.bottom, 8)
			}
		}
		.padding(.horizontal, 10)
		.background(Color.primary.opacity(isHovering && !isExpanded ? 0.03 : 0))
	}

	@ViewBuilder private var status: some View {
		if let result = call.result {
			Image(systemName: result.isError ? "xmark" : "checkmark")
				.font(.system(size: 9.5, weight: .bold))
				.foregroundStyle(result.isError ? Color.red.opacity(0.8) : Color.secondary.opacity(0.6))
				.help(result.isError ? "Failed" : "Done")
		} else if isRunning {
			ProgressView().controlSize(.mini)
		} else {
			Image(systemName: "minus").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary)
				.help("No result recorded")
		}
	}
}

// MARK: - Pieces

/// A note Bol attached to a request (a task finished, a message sent to one), as a short line.
private struct NoteView: View {
	let icon: String
	let text: String
	/// The note as Bol sent it, on hover.
	let fullText: String

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: icon).font(.system(size: 10.5))
			Text(text).lineLimit(1).truncationMode(.tail)
		}
		.font(.system(size: 11.5))
		.foregroundStyle(.tertiary)
		.frame(maxWidth: .infinity, alignment: .trailing)
		.help(fullText)
	}
}

private struct ScreenshotView: View {
	let base64: String
	var body: some View {
		if let data = Data(base64Encoded: base64), let image = NSImage(data: data) {
			Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
				.frame(maxWidth: 520, maxHeight: 320, alignment: .leading)
				.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UI.hairline))
		}
	}
}

private struct Labeled<Content: View>: View {
	let title: String
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
				.tracking(0.4)
			content
		}
	}
}

/// Monospaced text, cut at `limit` characters until asked for the rest.
private struct CodeBlock: View {
	let text: String
	let limit: Int
	@State private var isShowingAll = false
	var body: some View {
		let isLong = text.count > limit
		VStack(alignment: .leading, spacing: 6) {
			Text(isLong && !isShowingAll ? String(text.prefix(limit)) + "…" : text)
				.font(.system(size: 11.5, design: .monospaced))
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
			if isLong {
				Button(isShowingAll ? "Show less" : "Show all \(text.count.formatted()) characters") {
					isShowingAll.toggle()
				}
				.buttonStyle(.plain)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(.secondary)
			}
		}
		.padding(10)
		.background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
		.overlay(alignment: .topTrailing) { CopyButton(text: text).padding(4) }
	}
}

private struct Disclosure<Content: View>: View {
	let title: String
	@Binding var isExpanded: Bool
	@ViewBuilder var content: Content
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Button {
				withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
						.rotationEffect(.degrees(isExpanded ? 90 : 0))
					Text(title).font(.system(size: 12, weight: .medium))
				}
				.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
			if isExpanded { content }
		}
	}
}

/// A centered caption between two hairlines.
private struct Divided<Content: View>: View {
	@ViewBuilder var content: Content
	var body: some View {
		HStack(spacing: 10) {
			Rectangle().fill(UI.hairline).frame(height: 1)
			HStack(spacing: 6) { content }.font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize()
			Rectangle().fill(UI.hairline).frame(height: 1)
		}
		.contentShape(Rectangle())
	}
}
