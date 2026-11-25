import AppKit
import SwiftUI

// MARK: - Window content

/// A read-only view of Bol's threads: what was asked, what Bol said, and every step it took.
/// There is deliberately no composer: you talk to Bol with ⌘J.
/// What the Threads window can ask the rest of the app to do.
struct ThreadsActions {
	/// Start talking to Bol in the current conversation (⌘J).
	var talk: () -> Void = {}
	/// Make this thread the conversation again, and listen.
	var continueThread: (_ sessionId: String) -> Void = { _ in }
	/// A follow-up typed into a task.
	var messageTask: (_ taskId: String, _ text: String) -> Void = { _, _ in }
	/// The user is deleting this thread: the brain lets go of it before its files go.
	var forgetThread: (_ sessionId: String) -> Void = { _ in }
	var openSettings: () -> Void = {}
}

/// Bol's main window: every conversation and background task, read-only, with Talk and Settings at hand.
struct ThreadsView: View {
	@ObservedObject var store: ThreadStore
	@ObservedObject private var shortcuts = ShortcutState.shared
	var actions = ThreadsActions()
	@FocusState private var isSearchFocused: Bool

	var body: some View {
		HStack(spacing: 0) {
			sidebar
			Rectangle().fill(UI.hairline).frame(width: 1).ignoresSafeArea(edges: .top)
			detail.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(minWidth: 780, idealWidth: 1080, minHeight: 480, idealHeight: 740)
		.background(Color(nsColor: .windowBackgroundColor))
		.background(keyboardShortcuts)
	}

	/// ⌘⇧[ / ⌘⇧] (as in t3code) and ⌘↑ / ⌘↓ move between threads; ⌘F searches.
	private var keyboardShortcuts: some View {
		ZStack {
			Button("") { store.selectAdjacent(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
			Button("") { store.selectAdjacent(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
			Button("") { store.selectAdjacent(offset: -1) }.keyboardShortcut(.upArrow, modifiers: .command)
			Button("") { store.selectAdjacent(offset: 1) }.keyboardShortcut(.downArrow, modifiers: .command)
			Button("") { isSearchFocused = true }.keyboardShortcut("f", modifiers: .command)
			Button("") { if let thread = store.selected { confirmDelete(thread: thread) } }
				.keyboardShortcut(.delete, modifiers: .command)
		}
		.buttonStyle(.plain)
		.opacity(0)
		.frame(width: 0, height: 0)
		.accessibilityHidden(true)
	}

	// MARK: Sidebar

	private var sidebar: some View {
		let visible = store.visibleThreads
		let sections = ThreadSection.allCases.compactMap { section -> (ThreadSection, [ThreadSummary])? in
			let threads = visible.filter { ThreadSection.of(thread: $0, now: store.now) == section }
			return threads.isEmpty ? nil : (section, threads)
		}
		return VStack(alignment: .leading, spacing: 0) {
			Spacer().frame(height: 12)
			HStack(alignment: .center, spacing: 6) {
				VStack(alignment: .leading, spacing: 1) {
					Text("Threads").font(.system(size: 15, weight: .bold, design: .rounded))
					Text("Your conversations with Bol").font(UI.caption).foregroundStyle(.secondary).lineLimit(1)
				}
				Spacer(minLength: 0)
				ToolbarIcon(
					symbol: "mic",
					help: shortcuts.settings.talk.map { "Talk to Bol (\($0.plainText))" } ?? "Talk to Bol",
					action: actions.talk)
				ToolbarIcon(symbol: "gearshape", help: "Settings (⌘,)", action: actions.openSettings)
			}
			.padding(.leading, 18)
			.padding(.trailing, 12)
			.padding(.bottom, 12)
			SearchField(text: $store.query, isFocused: $isSearchFocused).padding(.horizontal, 12).padding(.bottom, 6)
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
					ForEach(sections, id: \.0) { section, threads in
						Text(section.title.uppercased())
							.font(.system(size: 10, weight: .semibold)).tracking(0.5)
							.foregroundStyle(.tertiary)
							.padding(.horizontal, 10)
							.padding(.top, 12)
							.padding(.bottom, 4)
						ForEach(threads) { thread in
							let isSelected = thread.id == store.selectedId
							ThreadRow(
								thread: thread, isSelected: isSelected && store.openTaskId == nil,
								isCurrent: thread.id == store.currentId, now: store.now
							) {
								store.openTaskId = nil
								store.selectedId = thread.id
							}
							.contextMenu {
								Button("Delete Thread…") { confirmDelete(thread: thread) }
									.disabled(thread.isLive(now: store.now))
							}
							// The selected thread lists all its tasks; others only the ones still working.
							ForEach(
								store.tasks(threadId: thread.id).filter { isSelected || $0.isLive(now: store.now) }
							) { task in
								TaskRow(task: task, isSelected: task.id == store.openTaskId, now: store.now) {
									store.show(task: task)
								}
							}
						}
					}
					searchStatus(isEmpty: visible.isEmpty)
				}
				.padding(.horizontal, 10)
				.padding(.bottom, 10)
			}
		}
		.frame(width: 290)
		.background(Color.black.opacity(0.12))
	}

	@ViewBuilder private func searchStatus(isEmpty: Bool) -> some View {
		let isSearching = !store.query.trimmingCharacters(in: .whitespaces).isEmpty
		if isSearching, store.isSearchingContent {
			HStack(spacing: 6) {
				ProgressView().controlSize(.mini)
				Text("Searching messages…")
			}
			.font(UI.caption).foregroundStyle(.tertiary)
			.frame(maxWidth: .infinity)
			.padding(.top, 14)
		} else if store.hasLoadedList, isEmpty {
			Text(isSearching ? "No threads found" : "No threads yet")
				.font(UI.caption).foregroundStyle(.tertiary)
				.frame(maxWidth: .infinity)
				.padding(.top, 24)
		}
	}

	// MARK: Detail

	@ViewBuilder private var detail: some View {
		if let task = store.openTask {
			taskDetail(task: task)
		} else if let thread = store.selected {
			VStack(spacing: 0) {
				ThreadHeader(
					thread: thread, transcript: store.transcript, isCurrent: thread.id == store.currentId,
					now: store.now
				) {
					if thread.id == store.currentId { actions.talk() } else { actions.continueThread(thread.id) }
				}
				Rectangle().fill(UI.hairline).frame(height: 1)
				if let transcript = store.transcript {
					TranscriptView(
						threadId: thread.id, transcript: transcript, isLive: thread.isLive(now: store.now),
						taskLinks: TaskLinks(
							task: { name in store.task(named: name, threadId: thread.id) },
							open: { id in store.openTaskId = id }, now: store.now))
				} else {
					centered { ProgressView().controlSize(.small) }
				}
				Rectangle().fill(UI.hairline).frame(height: 1)
				footer
			}
		} else if store.hasLoadedList {
			centered {
				VStack(spacing: 8) {
					Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28, weight: .light))
						.foregroundStyle(.tertiary)
					Text("No threads yet").font(UI.bodyMedium)
					Group {
						if let talk = shortcuts.settings.talk {
							HStack(spacing: 6) {
								Text("Press")
								KeyCaps(shortcut: talk, size: 10)
								Text("and talk to Bol; conversations show up here.")
							}
						} else {
							Text("Talk to Bol from the menu bar; conversations show up here.")
						}
					}
					.font(UI.caption)
					.foregroundStyle(.secondary)
				}
			}
		} else {
			centered { ProgressView().controlSize(.small) }
		}
	}

	/// A task opened from its card: its own transcript, and a box to message it.
	private func taskDetail(task: TaskSummary) -> some View {
		let isLive = task.isLive(now: store.now)
		let thread = store.threads.first { $0.id == task.threadId }
		return VStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 8) {
				Button {
					store.openTaskId = nil
				} label: {
					HStack(spacing: 4) {
						Image(systemName: "chevron.left").font(.system(size: 9.5, weight: .semibold))
						Text(thread?.title ?? "Back to the thread").lineLimit(1)
					}
					.font(.system(size: 11.5, weight: .medium))
					.foregroundStyle(.secondary)
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("Back to the thread (Esc)")
				.keyboardShortcut(.cancelAction)
				HStack(spacing: 10) {
					Image(systemName: "square.stack.3d.up").font(.system(size: 14, weight: .medium))
						.foregroundStyle(.secondary)
					Text(task.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
					Spacer(minLength: 0)
					HStack(spacing: 5) {
						if isLive {
							ProgressView().controlSize(.mini)
							Text("Working")
						} else if let last = task.lastActivity {
							Text("Last active \(Format.relative(date: last, now: store.now))")
						}
					}
					.font(UI.caption).foregroundStyle(.secondary)
				}
				Text("Task · started \(Format.dateTime(date: task.startedAt))")
					.font(UI.caption).foregroundStyle(.secondary)
			}
			.padding(.horizontal, 24)
			.padding(.top, 12)
			.padding(.bottom, 14)
			Rectangle().fill(UI.hairline).frame(height: 1)
			if let transcript = store.transcript {
				TranscriptView(threadId: task.id, transcript: transcript, isLive: isLive)
			} else {
				centered { ProgressView().controlSize(.small) }
			}
			Rectangle().fill(UI.hairline).frame(height: 1)
			Composer(placeholder: isLive ? "Add to this task…" : "Message this task to pick it up again…") { text in
				actions.messageTask(task.id, text)
			}
			.frame(maxWidth: 736)
			.padding(.horizontal, 24)
			.padding(.vertical, 12)
			.frame(maxWidth: .infinity)
		}
	}

	private var footer: some View {
		HStack(spacing: 6) {
			Image(systemName: "lock").font(.system(size: 10, weight: .medium))
			Text("Read-only. \(shortcuts.talkText) talks in the current thread")
			Spacer().frame(width: 10)
			KeyCaps(glyphs: [.command, .shift, KeyGlyph(label: "[")], size: 9.5)
			KeyCaps(glyphs: [.command, .shift, KeyGlyph(label: "]")], size: 9.5)
			Text("switch threads")
		}
		.font(UI.caption)
		.foregroundStyle(.tertiary)
		.frame(maxWidth: .infinity)
		.frame(height: 34)
	}

	/// Asks first: deleting removes the thread and its tasks from this Mac for good.
	private func confirmDelete(thread: ThreadSummary) {
		guard !thread.isLive(now: store.now) else { return }  // still working: it would write the files back
		let taskCount = store.tasks.filter { $0.threadId == thread.id }.count
		let alert = NSAlert()
		alert.messageText = "Delete “\(thread.title.count > 60 ? thread.title.prefix(60) + "…" : thread.title)”?"
		alert.informativeText =
			"The conversation\(taskCount == 0 ? "" : " and its \(taskCount) task\(taskCount == 1 ? "" : "s")") will be deleted from Bol's archive on this Mac. This can't be undone."
			+ (thread.id == store.currentId ? " Bol starts a new conversation." : "")
		alert.addButton(withTitle: "Delete")
		alert.addButton(withTitle: "Cancel")
		alert.buttons.first?.hasDestructiveAction = true
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		actions.forgetThread(thread.id)
		store.delete(threadId: thread.id)
	}

	private func centered<Content: View>(@ViewBuilder content: () -> Content) -> some View {
		content().frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

private struct SearchField: View {
	@Binding var text: String
	var isFocused: FocusState<Bool>.Binding

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
			TextField("Search threads and messages", text: $text).textFieldStyle(.plain).font(UI.body)
				.focused(isFocused)
				.onExitCommand { text = "" }
			if !text.isEmpty {
				Button {
					text = ""
				} label: {
					Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 8)
		.frame(height: 28)
		.background(UI.fieldFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(UI.fieldStroke))
	}
}

/// One line per thread: kind, title, and when it was last active (or that it's working).
private struct ThreadRow: View {
	let thread: ThreadSummary
	let isSelected: Bool
	/// The conversation ⌘J talks in.
	let isCurrent: Bool
	let now: Date
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 9) {
				Image(systemName: thread.isBackground ? "square.stack.3d.down.right" : "bubble.left")
					.font(.system(size: 10.5, weight: .medium))
					.foregroundStyle(isSelected ? .secondary : .tertiary)
					.frame(width: 14)
				Text(thread.title)
					.font(.system(size: 13, weight: isSelected ? .medium : .regular))
					.foregroundStyle(isSelected ? .primary : .secondary)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 6)
				if isCurrent {
					Image(systemName: "mic.fill").font(.system(size: 8.5)).foregroundStyle(.tertiary)
						.help("Current conversation: \(ShortcutState.shared.talkText) talks here")
				}
				if thread.isLive(now: now) {
					LiveDot()
				} else {
					Text(Format.compact(date: thread.lastActivity, now: now))
						.font(.system(size: 11).monospacedDigit())
						.foregroundStyle(.tertiary)
				}
			}
			.padding(.horizontal, 10)
			.frame(height: 30)
			.background(
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(Color.primary.opacity(isSelected ? 0.10 : isHovering ? 0.05 : 0))
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.animation(.easeOut(duration: 0.1), value: isHovering)
		.help(
			"\(thread.title)\n\(thread.isBackground ? "Background task" : "Conversation") · \(Format.dateTime(date: thread.lastActivity))"
		)
	}
}

/// A task under its thread: status, name, and when it last did anything.
private struct TaskRow: View {
	let task: TaskSummary
	let isSelected: Bool
	let now: Date
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		let isLive = task.isLive(now: now)
		Button(action: action) {
			HStack(spacing: 8) {
				Group {
					if isLive {
						ProgressView().controlSize(.mini).scaleEffect(0.8)
					} else if task.lastActivity == nil {
						Image(systemName: "circle.dashed")
					} else {
						Image(systemName: "checkmark")
					}
				}
				.font(.system(size: 9, weight: .semibold))
				.foregroundStyle(.tertiary)
				.frame(width: 14)
				Text(task.name)
					.font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
					.foregroundStyle(isSelected ? .primary : .secondary)
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer(minLength: 6)
				if !isLive, let last = task.lastActivity {
					Text(Format.compact(date: last, now: now))
						.font(.system(size: 11).monospacedDigit())
						.foregroundStyle(.tertiary)
				}
			}
			.padding(.leading, 30)
			.padding(.trailing, 10)
			.frame(height: 26)
			.background(
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(Color.primary.opacity(isSelected ? 0.10 : isHovering ? 0.05 : 0))
			)
			.overlay(alignment: .leading) {
				Rectangle().fill(UI.hairline).frame(width: 1).padding(.leading, 16)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.animation(.easeOut(duration: 0.1), value: isHovering)
		.help("\(task.name)\nTask · \(isLive ? "working" : task.lastActivity == nil ? "not started" : "done")")
	}
}

/// A borderless icon button for the sidebar's header.
private struct ToolbarIcon: View {
	let symbol: String
	let help: String
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 12.5, weight: .medium))
				.foregroundStyle(isHovering ? .primary : .secondary)
				.frame(width: 28, height: 28)
				.background(
					RoundedRectangle(cornerRadius: 7, style: .continuous)
						.fill(Color.primary.opacity(isHovering ? 0.08 : 0))
				)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.help(help)
	}
}

private struct LiveDot: View {
	@State private var isDim = false
	var body: some View {
		Circle().fill(Color.primary).frame(width: 6, height: 6)
			.opacity(isDim ? 0.25 : 0.9)
			.onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { isDim = true } }
			.help("Working")
	}
}

// MARK: - Window

final class ThreadsWindowController: NSObject, NSWindowDelegate {
	private let store: ThreadStore
	private let actions: ThreadsActions
	private var window: NSWindow?

	@MainActor init(actions: ThreadsActions) {
		store = ThreadStore()
		self.actions = actions
		super.init()
	}

	@MainActor func show() {
		if window == nil {
			let w = NSWindow(
				contentViewController: NSHostingController(rootView: ThreadsView(store: store, actions: actions)))
			w.title = "Bol"
			w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
			w.titlebarAppearsTransparent = true
			w.titleVisibility = .hidden
			w.isReleasedWhenClosed = false
			w.setFrameAutosaveName("BolThreads")
			w.delegate = self
			if !w.setFrameUsingName("BolThreads") {
				w.setContentSize(NSSize(width: 1080, height: 740))
				w.center()
			}
			window = w
		}
		store.start()
		if let window { AppPresence.show(window: window) }
	}

	func windowWillClose(_ notification: Notification) {
		MainActor.assumeIsolated { store.stop() }
		AppPresence.windowClosed()
		// Let the window and its views go; `show()` builds a new one at the saved frame.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.window?.isVisible != true else { return }
			self.window?.delegate = nil
			self.window = nil
		}
	}
}
