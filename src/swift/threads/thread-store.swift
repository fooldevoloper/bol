import Foundation

/// A Bol conversation: the foreground one, or a background job (a fork that ran on its own).
struct ThreadSummary: Identifiable, Equatable {
	let id: String
	var job: String?
	var forkedFrom: String?
	var startedAt: Date
	let transcriptURL: URL
	var title: String
	var lastActivity: Date

	var isBackground: Bool { job != nil }
	/// Written to in the last few seconds: Bol is probably still working on it.
	func isLive(now: Date) -> Bool { now.timeIntervalSince(lastActivity) < ThreadStore.liveSeconds }
}

/// A task a thread started: a session of its own, shown as a card in the thread and opened from there.
struct TaskSummary: Identifiable, Equatable {
	/// The brain's task id, for messaging it.
	let id: String
	let name: String
	let threadId: String?
	let sessionId: String
	let startedAt: Date
	var transcriptURL: URL?
	var lastActivity: Date?
	/// What it said last: its result, when it's done.
	var result: String?

	func isLive(now: Date) -> Bool {
		lastActivity.map { now.timeIntervalSince($0) < ThreadStore.liveSeconds } ?? false
	}
}

/// ~/.bol/tasks.jsonl: one line per task session (a task gets a new line if its session changes).
enum TaskIndex {
	struct Record: Equatable {
		let taskId: String
		let name: String
		let sessionId: String
		let threadId: String?
		let at: Date
	}

	/// The latest line per task, oldest task first.
	static func records(text: String) -> [Record] {
		var byId: [String: Record] = [:]
		var order: [String] = []
		for line in text.split(whereSeparator: \.isNewline) {
			guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
				continue
			}
			if object["isDeleted"] as? Bool == true, let taskId = object["taskId"] as? String {
				byId[taskId] = nil  // deleted with its thread
				order.removeAll { $0 == taskId }
				continue
			}
			guard let taskId = object["taskId"] as? String, let name = object["name"] as? String,
				let sessionId = object["sessionId"] as? String,
				let at = (object["at"] as? String).flatMap(TranscriptParser.parseDate)
			else { continue }
			if byId[taskId] == nil { order.append(taskId) }
			byId[taskId] = Record(
				taskId: taskId, name: name, sessionId: sessionId, threadId: object["threadId"] as? String,
				at: byId[taskId]?.at ?? at)
		}
		return order.compactMap { byId[$0] }
	}
}

/// Which Claude Code sessions are Bol's, read from the brain's threads index and, for sessions from
/// before it existed, Bol's log. Transcripts are Claude Code's own files; nothing here writes.
enum ThreadIndex {
	struct Record: Equatable {
		let sessionId: String
		let job: String?
		let forkedFrom: String?
		let at: Date
		/// A title Bol gave the thread (`{"sessionId", "title"}` lines); nil on other lines.
		var title: String? = nil
	}

	/// Merges records per session: the first start wins, the latest job wins (a foreground request
	/// later moved to the background becomes a job), the first known fork parent wins, the latest title wins.
	static func merge(records: [Record]) -> [String: Record] {
		var merged: [String: Record] = [:]
		for record in records.sorted(by: { $0.at < $1.at }) {
			guard let existing = merged[record.sessionId] else {
				merged[record.sessionId] = record
				continue
			}
			merged[record.sessionId] = Record(
				sessionId: record.sessionId, job: record.job ?? existing.job,
				forkedFrom: existing.forkedFrom ?? record.forkedFrom, at: existing.at,
				title: record.title ?? existing.title)
		}
		return merged
	}

	/// Threads the user deleted: their lines (`"isDeleted": true`) outlast the log lines that name them.
	static func deletedIds(indexText: String) -> Set<String> {
		Set(
			indexText.split(whereSeparator: \.isNewline).compactMap { line in
				guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
					object["isDeleted"] as? Bool == true
				else { return nil }
				return object["sessionId"] as? String
			})
	}

	static func records(indexText: String) -> [Record] {
		indexText.split(whereSeparator: \.isNewline).compactMap { line in
			guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
				object["isDeleted"] as? Bool != true,
				let id = object["sessionId"] as? String,
				let at = (object["at"] as? String).flatMap(TranscriptParser.parseDate)
			else { return nil }
			let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
			return Record(
				sessionId: id, job: object["job"] as? String, forkedFrom: object["forkedFrom"] as? String, at: at,
				title: title?.isEmpty == false ? title : nil)
		}
	}

	/// `[2026-11-17 14:10:50.933] brain: session <id> model=… effort=… job=<job>` lines.
	static func records(logText: String) -> [Record] {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
		return logText.split(whereSeparator: \.isNewline).compactMap { line in
			guard line.contains("brain: session "), line.hasPrefix("["), line.count > 25 else { return nil }
			let stamp = String(line.dropFirst().prefix(23))
			let words = line.split(separator: " ")
			guard let date = formatter.date(from: stamp),
				let index = words.firstIndex(of: "session"), index + 1 < words.count,
				words.dropFirst(index + 2).contains(where: { $0.hasPrefix("model=") })
			else { return nil }
			let id = String(words[index + 1])
			guard id.count == 36 else { return nil }
			let job = words.first(where: { $0.hasPrefix("job=") }).map { String($0.dropFirst(4)) }
			return Record(sessionId: id, job: job, forkedFrom: nil, at: date)
		}
	}
}

/// Feeds the Threads window. Reloads the list and the open thread while the window is visible, so a
/// running task streams in.
@MainActor final class ThreadStore: ObservableObject {
	nonisolated static let liveSeconds: TimeInterval = 8
	static let refreshSeconds: TimeInterval = 1.5

	@Published private(set) var threads: [ThreadSummary] = []
	/// Sessions Bol knows about whose transcripts Claude Code has since deleted (cleanupPeriodDays).
	@Published private(set) var missingCount = 0
	@Published private(set) var hasLoadedList = false
	@Published var selectedId: String? {
		didSet {
			guard selectedId != oldValue else { return }
			if openTaskId != nil {
				openTaskId = nil  // loads the thread
			} else {
				loadViewed(isForced: true)
			}
		}
	}
	/// Every task, oldest first.
	@Published private(set) var tasks: [TaskSummary] = []
	/// The task opened from its card, shown instead of its thread.
	@Published var openTaskId: String? {
		didSet { if openTaskId != oldValue { loadViewed(isForced: true) } }
	}
	/// The transcript on screen: the open task's, or the selected thread's.
	@Published private(set) var transcript: ThreadTranscript?
	@Published private(set) var isLoadingTranscript = false
	@Published private(set) var now = Date()
	/// The sidebar's search: matches titles at once, and what was said in each thread a moment later.
	@Published var query = "" {
		didSet { if query != oldValue { searchContent() } }
	}
	/// Threads whose messages or steps contain the query.
	@Published private(set) var contentMatches: Set<String> = []
	@Published private(set) var isSearchingContent = false
	/// The thread Bol is talking in now (the brain's saved session).
	@Published private(set) var currentId: String?

	private var timer: Timer?
	private var loadedVersion: (id: String, modified: Date)?
	private var titleCache: [URL: (modified: Date, title: String)] = [:]
	/// Each task's last words, by transcript, rebuilt when the file changes.
	private var resultCache: [URL: (modified: Date, result: String?)] = [:]
	private var isRefreshing = false
	private let queue = DispatchQueue(label: "bol.threads", qos: .userInitiated)
	/// Searchable text per transcript, rebuilt when the file changes.
	private var searchCache: [URL: (modified: Date, text: String)] = [:]
	private var searchTask: Task<Void, Never>?

	var selected: ThreadSummary? { threads.first { $0.id == selectedId } }
	var openTask: TaskSummary? { tasks.first { $0.id == openTaskId } }

	/// The thread's task with this name (the latest, if it was started twice).
	func task(named name: String, threadId: String) -> TaskSummary? {
		tasks.last { $0.threadId == threadId && $0.name.caseInsensitiveCompare(name) == .orderedSame }
	}

	private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

	/// The threads the sidebar shows, newest activity first.
	var visibleThreads: [ThreadSummary] {
		let query = trimmedQuery
		guard !query.isEmpty else { return threads }
		let taskMatches = Set(
			tasks.filter { $0.name.localizedCaseInsensitiveContains(query) }.compactMap(\.threadId))
		return threads.filter {
			$0.title.localizedCaseInsensitiveContains(query) || contentMatches.contains($0.id)
				|| taskMatches.contains($0.id)
		}
	}

	/// The tasks a thread started, newest first.
	func tasks(threadId: String) -> [TaskSummary] {
		tasks.filter { $0.threadId == threadId }.reversed()
	}

	/// Opens a task in the detail pane, selecting its thread.
	func show(task: TaskSummary) {
		if let threadId = task.threadId, threadId != selectedId { selectedId = threadId }
		openTaskId = task.id
	}

	/// Moves the selection up (-1) or down (+1) the sidebar.
	func selectAdjacent(offset: Int) {
		let visible = visibleThreads
		guard !visible.isEmpty else { return }
		let index = visible.firstIndex { $0.id == selectedId }.map { $0 + offset } ?? 0
		selectedId = visible[min(max(index, 0), visible.count - 1)].id
	}

	private func searchContent() {
		searchTask?.cancel()
		let query = trimmedQuery
		guard !query.isEmpty else {
			contentMatches = []
			isSearchingContent = false
			return
		}
		isSearchingContent = true
		searchTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: 220_000_000)  // wait for typing to pause
			guard let self, !Task.isCancelled else { return }
			// A task's words count for the thread that started it.
			let sources =
				self.threads.map { (id: $0.id, url: $0.transcriptURL, modified: $0.lastActivity) }
				+ self.tasks.compactMap { task -> (id: String, url: URL, modified: Date)? in
					guard let threadId = task.threadId, let url = task.transcriptURL, let modified = task.lastActivity
					else { return nil }
					return (threadId, url, modified)
				}
			let cache = self.searchCache
			let (matches, updated) = await withCheckedContinuation { continuation in
				self.queue.async {
					continuation.resume(returning: Self.search(query: query, sources: sources, cache: cache))
				}
			}
			guard self.timer != nil else { return }  // the window closed meanwhile
			// Keep what was read even when a newer search took over, so it doesn't read every file again.
			self.searchCache.merge(updated) { $0.modified >= $1.modified ? $0 : $1 }
			guard !Task.isCancelled else { return }
			self.contentMatches = matches
			self.isSearchingContent = false
		}
	}

	nonisolated private static func search(
		query: String, sources: [(id: String, url: URL, modified: Date)], cache: [URL: (modified: Date, text: String)]
	) -> (Set<String>, [URL: (modified: Date, text: String)]) {
		var cache = cache
		var matches: Set<String> = []
		for source in sources where !matches.contains(source.id) {
			let text: String
			if let cached = cache[source.url], cached.modified == source.modified {
				text = cached.text
			} else {
				let data = (try? Data(contentsOf: source.url, options: .mappedIfSafe)) ?? Data()
				text = TranscriptParser.parse(data: data).searchableText
				cache[source.url] = (source.modified, text)
			}
			if text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
				matches.insert(source.id)
			}
		}
		return (matches, cache)
	}

	func start() {
		refreshList()
		timer?.invalidate()
		let timer = Timer(timeInterval: Self.refreshSeconds, repeats: true) { [weak self] _ in
			Task { @MainActor in
				self?.now = Date()
				self?.refreshList()
			}
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	/// The window closed: stop refreshing and let go of what's only needed on screen (the open transcript with
	/// its screenshots, the search text of every thread). `start()` loads them again.
	func stop() {
		timer?.invalidate()
		timer = nil
		searchTask?.cancel()
		searchTask = nil
		query = ""
		searchCache = [:]
		transcript = nil
		loadedVersion = nil
		isLoadingTranscript = false
	}

	private func refreshList() {
		guard !isRefreshing else { return }
		isRefreshing = true
		let cache = titleCache
		let results = resultCache
		queue.async {
			let (threads, missing, cache) = Self.scan(titleCache: cache)
			let (tasks, updatedResults) = Self.scanTasks(resultCache: results)
			let current = (try? String(contentsOf: Constants.sessionFile, encoding: .utf8))?
				.trimmingCharacters(in: .whitespacesAndNewlines)
			Task { @MainActor in
				self.isRefreshing = false
				let currentId = current?.isEmpty == false ? current : nil
				if self.currentId != currentId { self.currentId = currentId }
				self.titleCache = cache
				self.resultCache = updatedResults
				if self.tasks != tasks { self.tasks = tasks }
				let taskSessions = Set(tasks.map(\.sessionId))
				let threads = threads.filter { !taskSessions.contains($0.id) }
				if self.threads != threads { self.threads = threads }
				self.missingCount = missing
				self.hasLoadedList = true
				if self.selectedId == nil || !threads.contains(where: { $0.id == self.selectedId }) {
					self.selectedId = threads.first?.id
				} else {
					self.loadViewed(isForced: false)
				}
			}
		}
	}

	/// Parses what's on screen (the open task, or the selected thread) again when its file changed, or
	/// always when switching.
	private func loadViewed(isForced: Bool) {
		let viewed: (id: String, url: URL, modified: Date, since: Date?)?
		if let task = openTask {
			viewed = task.transcriptURL.map { (task.id, $0, task.lastActivity ?? task.startedAt, nil) }
		} else if let thread = selected {
			let since = thread.forkedFrom == nil ? nil : thread.startedAt
			viewed = (thread.id, thread.transcriptURL, thread.lastActivity, since)
		} else {
			viewed = nil
		}
		guard let viewed else {
			transcript = nil
			loadedVersion = nil
			isLoadingTranscript = openTaskId != nil  // a task whose session hasn't started yet
			return
		}
		if !isForced, let loaded = loadedVersion, loaded.id == viewed.id, loaded.modified == viewed.modified {
			return
		}
		if isForced {
			transcript = nil
			isLoadingTranscript = true
		}
		loadedVersion = (viewed.id, viewed.modified)
		queue.async {
			let data = (try? Data(contentsOf: viewed.url)) ?? Data()
			let parsed = TranscriptParser.parse(data: data, since: viewed.since)
			Task { @MainActor in
				guard (self.openTaskId ?? self.selectedId) == viewed.id else { return }
				self.isLoadingTranscript = false
				if self.transcript != parsed { self.transcript = parsed }
			}
		}
	}

	// MARK: - Scanning (off the main thread)

	/// At launch: copies Bol's threads that only Claude Code still holds into ~/.bol/threads.
	nonisolated static func keepThreads() {
		DispatchQueue.global(qos: .utility).async {
			adopt(sessionIds: Array(records().keys), files: transcriptFiles())
		}
	}

	nonisolated private static func records() -> [String: ThreadIndex.Record] {
		let indexText = (try? String(contentsOf: Constants.threadsFile, encoding: .utf8)) ?? ""
		let logText = (try? String(contentsOf: Constants.logFile, encoding: .utf8)) ?? ""
		let deleted = ThreadIndex.deletedIds(indexText: indexText)
		return ThreadIndex.merge(
			records: ThreadIndex.records(logText: logText) + ThreadIndex.records(indexText: indexText)
		).filter { !deleted.contains($0.key) }
	}

	// MARK: - Deleting

	/// Deletes a thread and the tasks it started from this Mac: Bol's copies, Claude Code's transcripts, and
	/// their lines in the indexes (marked deleted, so the log can't bring them back). Call `forget(thread:)` on
	/// the brain first; the files go a moment later, once it has let go of them.
	func delete(threadId: String) {
		let taskIds = tasks.filter { $0.threadId == threadId }.map(\.id)
		let sessions = [threadId] + tasks.filter { $0.threadId == threadId }.map(\.sessionId)
		threads.removeAll { $0.id == threadId }
		tasks.removeAll { $0.threadId == threadId }
		if selectedId == threadId { selectedId = visibleThreads.first?.id }
		queue.asyncAfter(deadline: .now() + 1) {
			Self.deleteFiles(sessionIds: sessions)
			let at = ISO8601DateFormatter().string(from: Date())
			Self.append(
				line: #"{"sessionId":"\#(threadId)","isDeleted":true,"at":"\#(at)"}"#, to: Constants.threadsFile)
			for taskId in taskIds {
				Self.append(line: #"{"taskId":"\#(taskId)","isDeleted":true,"at":"\#(at)"}"#, to: Constants.tasksFile)
			}
			Log.info(message: "threads: deleted \(threadId) and \(taskIds.count) task(s)")
			Task { @MainActor in self.refreshList() }
		}
	}

	nonisolated private static func deleteFiles(sessionIds: [String]) {
		let manager = FileManager.default
		for id in sessionIds where id.count == 36 {
			try? manager.removeItem(at: Constants.threadsDirectory.appendingPathComponent("\(id).jsonl"))
			try? manager.removeItem(at: Constants.threadsDirectory.appendingPathComponent(id))
		}
	}

	/// Appends a line with O_APPEND, so it can't interleave with the brain's own appends.
	nonisolated private static func append(line: String, to url: URL) {
		let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
		guard fd >= 0 else { return }
		defer { close(fd) }
		let data = Array((line + "\n").utf8)
		_ = data.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
	}

	nonisolated private static func scanTasks(resultCache: [URL: (modified: Date, result: String?)]) -> (
		[TaskSummary], [URL: (modified: Date, result: String?)]
	) {
		let text = (try? String(contentsOf: Constants.tasksFile, encoding: .utf8)) ?? ""
		let files = transcriptFiles()
		var cache = resultCache
		let tasks = TaskIndex.records(text: text).map { record in
			var task = TaskSummary(
				id: record.taskId, name: record.name, threadId: record.threadId, sessionId: record.sessionId,
				startedAt: record.at)
			guard let url = files[record.sessionId] else { return task }
			let modified =
				((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
				?? record.at
			task.transcriptURL = url
			task.lastActivity = modified
			if let cached = cache[url], cached.modified == modified {
				task.result = cached.result
			} else {
				let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
				task.result = TranscriptParser.parse(data: data).lastReply
				cache[url] = (modified, task.result)
			}
			return task
		}
		return (tasks, cache)
	}

	nonisolated private static func scan(titleCache: [URL: (modified: Date, title: String)]) -> (
		[ThreadSummary], Int, [URL: (modified: Date, title: String)]
	) {
		let records = records()
		let files = transcriptFiles()
		adopt(sessionIds: Array(records.keys), files: files)
		var cache = titleCache
		var threads: [ThreadSummary] = []
		var missing = 0
		for record in records.values {
			guard let url = files[record.sessionId] else {
				missing += 1
				continue
			}
			let modified =
				((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
				?? record.at
			let title: String
			if record.job == nil, record.forkedFrom == nil {
				// The conversation runs all day across topics: it's named for the day it started.
				title = Format.day(date: record.at)
			} else if let given = record.title {
				title = given
			} else if let cached = cache[url], cached.modified == modified {
				title = cached.title
			} else {
				title =
					(try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(TranscriptParser.title(data:))
					?? "Untitled"
				cache[url] = (modified, title)
			}
			threads.append(
				ThreadSummary(
					id: record.sessionId, job: record.job, forkedFrom: record.forkedFrom, startedAt: record.at,
					transcriptURL: url, title: title, lastActivity: modified))
		}
		return (threads.sorted { $0.lastActivity > $1.lastActivity }, missing, cache)
	}

	/// Every transcript, by session id: Bol's own copies (~/.bol/threads).
	nonisolated private static func transcriptFiles() -> [String: URL] {
		let manager = FileManager.default
		var files: [String: URL] = [:]
		let own =
			(try? manager.contentsOfDirectory(at: Constants.threadsDirectory, includingPropertiesForKeys: nil)) ?? []
		for file in own where file.pathExtension == "jsonl" {
			files[file.deletingPathExtension().lastPathComponent] = file
		}
		return files
	}

	nonisolated private static func adopt(sessionIds: [String], files: [String: URL]) {}
}
