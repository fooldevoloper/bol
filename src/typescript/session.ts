// Session and task lifecycle over Antigravity ACP (`agy acp`) + Bol's in-process HTTP MCP server.
import { randomUUID } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { basename, join } from 'node:path'
import { AcpClient, type AcpConfigOption, type AcpSessionUpdate, type AnyAcpMcpServer } from './acp-client'
import {
	AGY_MCP_CONFIG_FILES,
	AGY_SKILLS_DIRS,
	BOL_DIR,
	BOL_PROMPT,
	EFFORT,
	IDLE_CONVERSATION_MS,
	MEMORY_DIR,
	PROMPT_FILE,
	SAFETY_PROMPT,
	SESSION_FILE,
	TASKS_FILE,
	THREADS_FILE,
	WORKSPACE_DIR,
} from './constants'
import { loadAntigravityServerNames, loadCustomServers } from './mcp-config'
import { BolMcpServer } from './mcp-server'
import { findUrl, openInBrowser, signIn } from './mcp-sign-in'
import { emit, log } from './protocol'
import { makeBolTools } from './screen'
import {
	loadTaskRecords,
	makeThreadTools,
	recordTask,
	type TaskRecord,
	type TaskStatus,
	taskPrompt,
	THREAD_TASK_PROMPT,
} from './tasks'
import { lastActivity, makeThreadArchive } from './thread-archive'

type Origin = { kind: 'thread' } | { kind: 'task'; job: string; name: string }

type SkillInfo = {
	name: string
	description: string
	argumentHint?: string
}

const TASK_HANDOFF_TOOLS = new Set([
	'mcp_bol_start_task',
	'mcp_bol_message_task',
	'mcp__bol__start_task',
	'mcp__bol__message_task',
])

const MODEL_ENV = process.env.BOL_MODEL?.trim()
const PREFERRED_CWD =
	process.env.BOL_CWD != null && process.env.BOL_CWD.trim().length > 0 && existsSync(process.env.BOL_CWD.trim())
		? process.env.BOL_CWD.trim()
		: WORKSPACE_DIR

const mcpServer = new BolMcpServer()

type QueuedMessage = {
	text: string
	resolve: () => void
	reject: (err: Error) => void
}

function readOptionalFile({ path, maxBytes = 16_384 }: { path: string; maxBytes?: number }): string {
	try {
		if (!existsSync(path)) return ''
		const text = readFileSync(path, 'utf8').trim()
		return text.length > maxBytes ? `${text.slice(0, maxBytes)}\n…` : text
	} catch {
		return ''
	}
}

function buildSystemPrompt({ rolePrompt }: { rolePrompt: string }): string {
	const custom = readOptionalFile({ path: PROMPT_FILE, maxBytes: 32_768 })
	const base = custom.length > 0 ? custom : BOL_PROMPT
	const memory = readOptionalFile({ path: join(MEMORY_DIR, 'MEMORY.md'), maxBytes: 8_192 })
	const parts = [base.trim(), SAFETY_PROMPT.trim(), rolePrompt.trim()]
	if (memory.length > 0) {
		parts.push(`# Persistent Memory (${join(MEMORY_DIR, 'MEMORY.md')})\n${memory}`)
	}
	return parts.filter((p) => p.length > 0).join('\n\n')
}

function parseFrontmatterField({ content, field }: { content: string; field: string }): string | undefined {
	const fmMatch = content.match(/^---\s*\n([\s\S]*?)\n---/)
	if (fmMatch == null) return undefined
	const re = new RegExp(`^${field}:\\s*(.+)$`, 'm')
	const val = fmMatch[1]?.match(re)?.[1]?.trim()
	if (val == null || val.length === 0) return undefined
	return val.replace(/^['"]|['"]$/g, '')
}

function discoverSkills({ cwd }: { cwd: string }): SkillInfo[] {
	const byName = new Map<string, SkillInfo>()
	const dirs = [...AGY_SKILLS_DIRS, join(cwd, '.agents', 'skills'), join(cwd, '.gemini', 'skills')]
	for (const root of dirs) {
		try {
			if (!existsSync(root)) continue
			for (const entry of readdirSync(root, { withFileTypes: true })) {
				if (entry.name.startsWith('.')) continue
				if (entry.isDirectory() || entry.isSymbolicLink()) {
					const skillFile = join(root, entry.name, 'SKILL.md')
					if (!existsSync(skillFile)) continue
					const content = readOptionalFile({ path: skillFile, maxBytes: 4096 })
					const name = parseFrontmatterField({ content, field: 'name' }) ?? entry.name
					const description = parseFrontmatterField({ content, field: 'description' }) ?? ''
					byName.set(name, { name, description })
				} else if (entry.isFile() && entry.name.endsWith('.md')) {
					const name = basename(entry.name, '.md')
					const content = readOptionalFile({ path: join(root, entry.name), maxBytes: 4096 })
					const description = parseFrontmatterField({ content, field: 'description' }) ?? ''
					byName.set(name, { name, description })
				}
			}
		} catch {
			// Ignore unreadable skill directories.
		}
	}
	return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name))
}

function readStoredSessionId(): string | null {
	try {
		const raw = readFileSync(SESSION_FILE, 'utf8').trim()
		if (raw.length === 0) return null
		if (raw.startsWith('{')) {
			const parsed = JSON.parse(raw) as { sessionId?: string }
			return parsed.sessionId ?? null
		}
		return raw
	} catch {
		return null
	}
}

function writeStoredSessionId({ sessionId }: { sessionId: string | null }): void {
	try {
		mkdirSync(BOL_DIR, { recursive: true })
		writeFileSync(SESSION_FILE, sessionId ?? '')
	} catch (error) {
		log({ msg: `failed to write session file: ${error}` })
	}
}

function recordThread({ sessionId }: { sessionId: string }): void {
	try {
		mkdirSync(BOL_DIR, { recursive: true })
		let alreadyHas = false
		try {
			const lines = readFileSync(THREADS_FILE, 'utf8').split('\n')
			for (const line of lines) {
				if (line.trim().length === 0) continue
				const parsed = JSON.parse(line) as { sessionId?: string }
				if (parsed.sessionId === sessionId) {
					alreadyHas = true
					break
				}
			}
		} catch {
			// File may not exist yet.
		}
		if (alreadyHas) return
		appendFileSync(THREADS_FILE, `${JSON.stringify({ sessionId, at: new Date().toISOString() })}\n`, {
			mode: 0o600,
		})
	} catch (error) {
		log({ msg: `failed to update threads.jsonl: ${error}` })
	}
}

function removeStoredThread({ sessionId }: { sessionId: string }): void {
	try {
		const lines = readFileSync(THREADS_FILE, 'utf8').split('\n')
		const kept = lines.filter((line) => {
			if (line.trim().length === 0) return false
			try {
				const parsed = JSON.parse(line) as { sessionId?: string }
				return parsed.sessionId !== sessionId
			} catch {
				return false
			}
		})
		writeFileSync(THREADS_FILE, kept.length > 0 ? `${kept.join('\n')}\n` : '')
	} catch {
		// Ignore missing/invalid threads.jsonl.
	}
}

function cleanToolArgs({ args }: { args: Record<string, unknown> }): Record<string, unknown> {
	const cleaned: Record<string, unknown> = {}
	for (const [key, value] of Object.entries(args)) {
		if (key === 'toolSummary') continue
		cleaned[key] = value
	}
	return cleaned
}

function summarizeTool({ name, args }: { name: string; args: Record<string, unknown> }): string {
	if (typeof args.toolSummary === 'string' && args.toolSummary.trim().length > 0) {
		return args.toolSummary.trim()
	}
	const shortName = name.replace(/^mcp_bol_/, '').replace(/^mcp__bol__/, '')
	if (typeof args.command === 'string') return args.command.slice(0, 80)
	if (typeof args.CommandLine === 'string') return args.CommandLine.slice(0, 80)
	if (typeof args.file_path === 'string') return basename(args.file_path)
	if (typeof args.AbsolutePath === 'string') return basename(args.AbsolutePath)
	if (typeof args.TargetFile === 'string') return basename(args.TargetFile)
	if (typeof args.query === 'string') return args.query.slice(0, 60)
	if (typeof args.Query === 'string') return args.Query.slice(0, 60)
	if (typeof args.url === 'string') return args.url.slice(0, 60)
	if (typeof args.Url === 'string') return args.Url.slice(0, 60)
	if (typeof args.name === 'string') return args.name
	if (typeof args.application === 'string') return args.application
	return shortName
}

function extractToolResultText({ update }: { update: AcpSessionUpdate }): string {
	const parts: string[] = []
	if (Array.isArray(update.content)) {
		for (const item of update.content) {
			const c = (item as { content?: { type?: string; text?: string }; text?: string }) ?? {}
			if (typeof c.content?.text === 'string') parts.push(c.content.text)
			else if (typeof c.text === 'string') parts.push(c.text)
		}
	}
	if (parts.length > 0) return parts.join('\n')
	if (update.rawOutput != null) {
		if (typeof update.rawOutput === 'string') return update.rawOutput
		const out = update.rawOutput as { output?: unknown; text?: unknown }
		if (typeof out.output === 'string') return out.output
		if (typeof out.text === 'string') return out.text
		return JSON.stringify(update.rawOutput)
	}
	return ''
}

function chooseThoughtLevel({
	configOptions,
	desired,
}: {
	configOptions?: AcpConfigOption[]
	desired: string
}): string | null {
	const opt = configOptions?.find((o) => o.id === 'thought_level')
	if (opt == null) return null
	const values = new Set((opt.options ?? []).map((o) => o.value))
	if (values.size === 0) return desired
	if (values.has(desired)) return desired
	if (desired === 'max' && values.has('xhigh')) return 'xhigh'
	if ((desired === 'max' || desired === 'xhigh') && values.has('high')) return 'high'
	if (values.has('medium')) return 'medium'
	return opt.options?.[0]?.value ?? null
}

function chooseModelValue({
	configOptions,
	models,
	desired,
}: {
	configOptions?: AcpConfigOption[]
	models?: { availableModels?: { modelId: string }[] }
	desired?: string
}): string | null {
	if (desired == null || desired.length === 0 || desired === 'default' || desired === 'auto') return null
	const opt = configOptions?.find((o) => o.id === 'model')
	const optValues = (opt?.options ?? []).map((o) => o.value)
	const modelValues = (models?.availableModels ?? []).map((m) => m.modelId)
	const all = optValues.length > 0 ? optValues : modelValues
	if (all.length === 0 || all.includes(desired)) return desired
	const prefixMatch = all.find((m) => m.startsWith(desired))
	return prefixMatch ?? desired
}

class Conversation {
	readonly origin: Origin
	readonly mcpKey: string
	sessionId: string | null = null
	private client: AcpClient | null = null
	private startPromise: Promise<void> | null = null
	private queue: QueuedMessage[] = []
	private isRunningTurn = false
	private currentModel = MODEL_ENV ?? ''
	private archive: ReturnType<typeof makeThreadArchive> | null = null
	private readonly authUrls = new Map<string, string>()

	// Per-turn update tracking.
	private turnText = ''
	private turnSawHandoff = false
	private readonly seenTools = new Map<
		string,
		{ name: string; input: Record<string, unknown>; archivedResult: boolean }
	>()

	constructor({ origin, initialSessionId }: { origin: Origin; initialSessionId?: string | null }) {
		this.origin = origin
		this.mcpKey = origin.kind === 'thread' ? `thread-${randomUUID()}` : `task-${origin.job}`
		this.sessionId = initialSessionId ?? null
		if (this.sessionId != null) {
			this.archive = makeThreadArchive({ sessionId: this.sessionId })
		}
	}

	get isBusy(): boolean {
		return this.isRunningTurn || this.queue.length > 0
	}

	async ensureStarted({ resumeIfPossible = true }: { resumeIfPossible?: boolean } = {}): Promise<void> {
		if (this.client != null && this.sessionId != null) return
		if (this.startPromise != null) return this.startPromise
		this.startPromise = this.startInternal({ resumeIfPossible }).finally(() => {
			this.startPromise = null
		})
		return this.startPromise
	}

	private async startInternal({ resumeIfPossible }: { resumeIfPossible: boolean }): Promise<void> {
		const isThread = this.origin.kind === 'thread'
		const rolePrompt = isThread ? THREAD_TASK_PROMPT : taskPrompt({ name: this.origin.name })
		const appendSystemPrompt = buildSystemPrompt({ rolePrompt })

		const extraTools = isThread
			? makeThreadTools({
					handlers: {
						start: ({ name, brief }) => startTask({ name, brief }),
						message: ({ name, text }) => messageTaskByName({ name, text }),
						list: () => listTasksText(),
						stop: ({ name }) => stopTaskByName({ name }),
						signIn: ({ server }) => signIn({ name: server, authUrl: this.authUrls.get(server) }),
					},
				})
			: []

		const bolTools = makeBolTools({
			onScreen: ({ reason }) => {
				emit({ type: 'screen', reason, ...(this.origin.kind === 'task' ? { job: this.origin.job } : {}) })
			},
			extraTools,
		})
		const bolMcp = mcpServer.register({ key: this.mcpKey, name: 'bol', tools: bolTools })
		const custom = await loadCustomServers()
		const mcpServers: AnyAcpMcpServer[] = [bolMcp, ...Object.values(custom.servers)]

		const client = new AcpClient({
			cwd: PREFERRED_CWD,
			onUpdate: ({ update }) => this.handleUpdate({ update }),
			onElicitation: (params) => {
				const url =
					typeof params.url === 'string' ? params.url : findUrl({ text: String(params.message ?? '') })
				const serverName = typeof params.serverName === 'string' ? params.serverName : 'mcp'
				if (url != null) {
					this.authUrls.set(serverName, url)
					openInBrowser({ url })
					emit({ type: 'mcpSignIn', name: serverName, url, error: null })
				}
			},
			onExit: ({ code }) => {
				if (this.client === client) {
					log({ msg: `${this.originLabel()} ACP exited unexpectedly (${code})` })
					this.client = null
				}
			},
		})
		this.client = client

		await client.initialize()

		let info
		const wantedResume = resumeIfPossible && this.sessionId != null
		if (wantedResume && this.sessionId != null) {
			try {
				info = await client.resumeSession({
					sessionId: this.sessionId,
					cwd: PREFERRED_CWD,
					mcpServers,
					appendSystemPrompt,
				})
			} catch (error) {
				log({ msg: `resumeSession failed (${error}); starting new session` })
				this.sessionId = null
			}
		}
		if (info == null) {
			info = await client.newSession({
				cwd: PREFERRED_CWD,
				mcpServers,
				appendSystemPrompt,
			})
		}

		this.sessionId = info.sessionId
		this.currentModel = info.models?.currentModelId ?? this.currentModel
		this.archive = makeThreadArchive({ sessionId: info.sessionId })

		if (isThread) {
			writeStoredSessionId({ sessionId: info.sessionId })
			recordThread({ sessionId: info.sessionId })
		}

		const modelValue = chooseModelValue({
			configOptions: info.configOptions,
			models: info.models,
			desired: MODEL_ENV,
		})
		if (modelValue != null) {
			try {
				await client.setConfigOption({ sessionId: info.sessionId, configId: 'model', value: modelValue })
				this.currentModel = modelValue
			} catch (error) {
				log({ msg: `setConfigOption model=${modelValue} failed: ${error}` })
			}
		}

		const thoughtValue = chooseThoughtLevel({ configOptions: info.configOptions, desired: EFFORT })
		if (thoughtValue != null) {
			try {
				await client.setConfigOption({
					sessionId: info.sessionId,
					configId: 'thought_level',
					value: thoughtValue,
				})
			} catch (error) {
				log({ msg: `setConfigOption thought_level=${thoughtValue} failed: ${error}` })
			}
		}

		if (isThread) {
			emitSkills({ availableCommands: undefined })
		}
	}

	enqueue({ text }: { text: string }): Promise<void> {
		return new Promise((resolve, reject) => {
			this.queue.push({ text, resolve, reject })
			void this.drain()
		})
	}

	private async drain(): Promise<void> {
		if (this.isRunningTurn) return
		const next = this.queue.shift()
		if (next == null) return
		this.isRunningTurn = true
		try {
			await this.runTurn({ text: next.text })
			next.resolve()
		} catch (error) {
			next.reject(error instanceof Error ? error : new Error(String(error)))
		} finally {
			this.isRunningTurn = false
			if (this.queue.length > 0) {
				void this.drain()
			} else if (this.origin.kind === 'thread') {
				emit({ type: 'idle', seq: latestSeq })
			}
		}
	}

	private async runTurn({ text }: { text: string }): Promise<void> {
		await this.ensureStarted()
		if (this.client == null || this.sessionId == null) {
			throw new Error('ACP client failed to initialize')
		}

		this.turnText = ''
		this.turnSawHandoff = false
		this.seenTools.clear()
		this.archive?.appendUser({ text })

		let stopReason = 'end_turn'
		let usage: Record<string, number> | undefined
		const job = this.origin.kind === 'task' ? this.origin.job : undefined

		try {
			const res = await this.client.prompt({ sessionId: this.sessionId, text })
			stopReason = res.stopReason ?? 'end_turn'
			if (res.usage != null) {
				usage = Object.fromEntries(
					Object.entries(res.usage).filter(([, v]) => typeof v === 'number'),
				) as Record<string, number>
			}
		} catch (error) {
			const msg = error instanceof Error ? error.message : String(error)
			this.archive?.appendError({ error: msg })
			emit({
				type: 'result',
				text: msg,
				isError: true,
				...(job != null ? { job } : {}),
			})
			throw error
		}

		const finalText = this.turnText.trim()
		if (finalText.length > 0) {
			this.archive?.appendAssistant({
				content: [{ type: 'text', text: finalText }],
				model: this.currentModel || undefined,
				usage,
			})
		}

		const cancelled = stopReason === 'cancelled'
		if (this.origin.kind === 'thread') {
			if (cancelled) {
				emit({ type: 'result', text: '', isError: false, isInterrupted: true })
			} else {
				emit({
					type: 'result',
					text: finalText,
					isError: false,
					...(this.turnSawHandoff ? { isDelegated: true } : {}),
				})
			}
		} else {
			onTaskTurnDone({ job: this.origin.job, text: finalText, cancelled })
		}
	}

	private handleUpdate({ update }: { update: AcpSessionUpdate }): void {
		const kind = update.sessionUpdate
		if (kind === 'available_commands_update') {
			const cmds: SkillInfo[] = Array.isArray(update.availableCommands)
				? (update.availableCommands as { name?: string; description?: string }[])
						.filter((c) => typeof c.name === 'string' && c.name.length > 0)
						.map((c) => ({ name: c.name as string, description: c.description ?? '' }))
				: []
			if (this.origin.kind === 'thread') emitSkills({ availableCommands: cmds })
			return
		}

		if (kind === 'agent_message_chunk') {
			const content = update.content as { type?: string; text?: string } | undefined
			if (content?.type === 'text' && typeof content.text === 'string' && content.text.length > 0) {
				this.turnText += content.text
				if (this.origin.kind === 'thread') {
					emit({ type: 'text', text: content.text })
				}
			}
			return
		}

		if (kind === 'tool_call') {
			const callId = String(update.toolCallId ?? randomUUID())
			const rawName = String(update.name ?? update.title ?? 'tool')
			const rawArgs = (
				typeof update.args === 'object' && update.args != null
					? update.args
					: typeof update.rawInput === 'object' && update.rawInput != null
						? update.rawInput
						: {}
			) as Record<string, unknown>
			const input = cleanToolArgs({ args: rawArgs })
			if (TASK_HANDOFF_TOOLS.has(rawName)) this.turnSawHandoff = true

			if (!this.seenTools.has(callId)) {
				this.seenTools.set(callId, { name: rawName, input, archivedResult: false })
				const summary = summarizeTool({ name: rawName, args: rawArgs })
				emit({
					type: 'tool',
					name: rawName,
					summary,
					...(this.origin.kind === 'task' ? { job: this.origin.job } : {}),
				})
				this.archive?.appendAssistant({
					content: [{ type: 'tool_use', id: callId, name: rawName, input }],
					model: this.currentModel || undefined,
				})
			}
			return
		}

		if (kind === 'tool_call_update') {
			const callId = String(update.toolCallId ?? '')
			const status = String(update.status ?? '')
			if (status !== 'completed' && status !== 'failed') return
			const tracked = this.seenTools.get(callId)
			if (tracked?.archivedResult) return
			if (tracked != null) tracked.archivedResult = true
			const text = extractToolResultText({ update })
			if (status === 'failed') {
				const url = findUrl({ text })
				if (url != null && tracked != null) {
					const serverMatch = tracked.name.match(/^mcp_([^_]+)_/) ?? tracked.name.match(/^mcp__([^_]+)__/)
					if (serverMatch?.[1] != null) this.authUrls.set(serverMatch[1], url)
				}
			}
			if (callId.length > 0) {
				this.archive?.appendToolResult({
					toolUseId: callId,
					content: text,
					isError: status === 'failed',
				})
			}
		}
	}

	async interrupt(): Promise<void> {
		for (const q of this.queue) q.reject(new Error('Interrupted'))
		this.queue = []
		if (this.client != null && this.sessionId != null) {
			this.client.cancel({ sessionId: this.sessionId })
		}
	}

	async close(): Promise<void> {
		for (const q of this.queue) q.reject(new Error('Session closed'))
		this.queue = []
		mcpServer.unregister({ key: this.mcpKey })
		const client = this.client
		const sessionId = this.sessionId ?? undefined
		this.client = null
		if (client != null) {
			await client.close({ sessionId })
		}
	}

	private originLabel(): string {
		return this.origin.kind === 'thread' ? 'thread' : `task(${this.origin.name})`
	}
}

type TaskRuntime = {
	record: TaskRecord
	status: TaskStatus
	result: string
	conversation: Conversation
}

const taskMap = new Map<string, TaskRuntime>()
let foreground: Conversation | null = null
let cachedCommands: SkillInfo[] = []
let latestSeq = 0

function emitSkills({ availableCommands }: { availableCommands?: SkillInfo[] }): void {
	if (availableCommands != null) cachedCommands = availableCommands
	const local = discoverSkills({ cwd: PREFERRED_CWD })
	const byName = new Map<string, SkillInfo>()
	for (const cmd of cachedCommands) byName.set(cmd.name, cmd)
	for (const skill of local) byName.set(skill.name, skill)
	const skills = [...byName.values()].sort((a, b) => a.name.localeCompare(b.name))
	emit({ type: 'skills', skills })
}

function getOrCreateForeground({ forceNew = false }: { forceNew?: boolean } = {}): Conversation {
	if (!forceNew && foreground != null) {
		const sid = foreground.sessionId
		if (sid != null) {
			const at = lastActivity({ sessionId: sid })
			if (at > 0 && Date.now() - at > IDLE_CONVERSATION_MS) {
				void foreground.close()
				foreground = null
				writeStoredSessionId({ sessionId: null })
			}
		}
	}
	if (!forceNew && foreground != null) return foreground

	const storedId = forceNew ? null : readStoredSessionId()
	const validStored =
		storedId != null &&
		(lastActivity({ sessionId: storedId }) === 0 ||
			Date.now() - lastActivity({ sessionId: storedId }) <= IDLE_CONVERSATION_MS)
			? storedId
			: null

	if (validStored == null && storedId != null) {
		writeStoredSessionId({ sessionId: null })
	}

	foreground = new Conversation({ origin: { kind: 'thread' }, initialSessionId: validStored })
	return foreground
}

function emitTaskEvent({ runtime }: { runtime: TaskRuntime }): void {
	emit({
		type: 'task',
		job: runtime.record.taskId,
		name: runtime.record.name,
		status: runtime.status,
		sessionId: runtime.conversation.sessionId ?? runtime.record.sessionId,
	})
}

function onTaskTurnDone({ job, text, cancelled }: { job: string; text: string; cancelled: boolean }): void {
	const runtime = taskMap.get(job)
	if (runtime == null) return
	runtime.status = cancelled ? 'stopped' : 'done'
	runtime.result = text
	runtime.record.sessionId = runtime.conversation.sessionId ?? runtime.record.sessionId
	void recordTask(runtime.record)
	emitTaskEvent({ runtime })

	if (cancelled) {
		emit({ type: 'result', text: '', isError: false, isInterrupted: true, job })
	} else {
		emit({ type: 'result', text, isError: false, job })
	}

	if (!cancelled && text.length > 0 && foreground != null && !foreground.isBusy) {
		void foreground.enqueue({ text: `[Task "${runtime.record.name}" finished]: ${text}` }).catch((error) => {
			log({ msg: `task handoff note failed: ${error}` })
		})
	}
}

async function startTask({ name, brief }: { name: string; brief: string }): Promise<string> {
	const job = randomUUID()
	const conversation = new Conversation({ origin: { kind: 'task', job, name } })
	const record: TaskRecord = {
		taskId: job,
		name,
		sessionId: '',
		threadId: foreground?.sessionId ?? null,
		at: new Date().toISOString(),
	}
	const runtime: TaskRuntime = { record, status: 'running', result: '', conversation }
	taskMap.set(job, runtime)
	emitTaskEvent({ runtime })

	void conversation
		.ensureStarted({ resumeIfPossible: false })
		.then(async () => {
			record.sessionId = conversation.sessionId ?? ''
			await recordTask(record)
			emitTaskEvent({ runtime })
			await conversation.enqueue({ text: brief })
		})
		.catch((error) => {
			runtime.status = 'failed'
			runtime.result = error instanceof Error ? error.message : String(error)
			emitTaskEvent({ runtime })
			emit({ type: 'result', text: runtime.result, isError: true, job })
		})

	return `Started task "${name}".`
}

async function messageTaskByName({ name, text }: { name: string; text: string }): Promise<string> {
	const target = [...taskMap.values()].find((t) => t.record.name.toLowerCase() === name.trim().toLowerCase())
	if (target == null) return `No task named "${name}".`
	target.status = 'running'
	emitTaskEvent({ runtime: target })
	void target.conversation.enqueue({ text }).catch((error) => {
		target.status = 'failed'
		target.result = error instanceof Error ? error.message : String(error)
		emitTaskEvent({ runtime: target })
	})
	return `Sent message to task "${target.record.name}".`
}

async function listTasksText(): Promise<string> {
	if (taskMap.size === 0) return 'No tasks yet.'
	return [...taskMap.values()]
		.map((t) => `- ${t.record.name} [${t.status}]${t.result ? `: ${t.result}` : ''}`)
		.join('\n')
}

async function stopTaskByName({ name }: { name: string }): Promise<string> {
	const target = [...taskMap.values()].find((t) => t.record.name.toLowerCase() === name.trim().toLowerCase())
	if (target == null) return `No task named "${name}".`
	await target.conversation.interrupt()
	await target.conversation.close()
	target.status = 'stopped'
	emitTaskEvent({ runtime: target })
	return `Stopped task "${target.record.name}".`
}

export async function loadTasks(): Promise<void> {
	const records = await loadTaskRecords()
	for (const rec of records) {
		if (taskMap.has(rec.taskId)) continue
		const conv = new Conversation({
			origin: { kind: 'task', job: rec.taskId, name: rec.name },
			initialSessionId: rec.sessionId || null,
		})
		taskMap.set(rec.taskId, {
			record: rec,
			status: 'done',
			result: '',
			conversation: conv,
		})
	}
}

export function ensureSession(): void {
	const conv = getOrCreateForeground()
	void conv.ensureStarted().catch((error) => {
		log({ msg: `session pre-warm failed: ${error}` })
	})
}

export function say({ text, seq }: { text: string; seq: number }): void {
	latestSeq = seq
	const conv = getOrCreateForeground()
	void conv.enqueue({ text }).catch((error) => {
		log({ msg: `say failed: ${error}` })
	})
}

export function continueSession({ sessionId }: { sessionId: string }): void {
	void foreground?.close()
	writeStoredSessionId({ sessionId })
	foreground = new Conversation({ origin: { kind: 'thread' }, initialSessionId: sessionId })
	void foreground.ensureStarted({ resumeIfPossible: true }).catch((error) => {
		log({ msg: `continueSession failed: ${error}` })
	})
}

export async function interruptSession(): Promise<void> {
	await foreground?.interrupt()
}

export function closeSession(): void {
	void foreground?.close()
	foreground = null
	for (const runtime of taskMap.values()) {
		void runtime.conversation.close()
	}
	mcpServer.stop()
}

export function resetSession(): void {
	void foreground?.close()
	foreground = null
	writeStoredSessionId({ sessionId: null })
	const next = getOrCreateForeground({ forceNew: true })
	void next.ensureStarted({ resumeIfPossible: false }).catch((error) => {
		log({ msg: `resetSession failed: ${error}` })
	})
}

export async function reloadCustomServers(): Promise<void> {
	await requestMcpStatus()
	const active = foreground
	if (active != null && !active.isBusy) {
		const sid = active.sessionId
		await active.close()
		foreground = new Conversation({ origin: { kind: 'thread' }, initialSessionId: sid })
		void foreground.ensureStarted({ resumeIfPossible: true }).catch((error) => {
			log({ msg: `reloadCustomServers restart failed: ${error}` })
		})
	}
}

export async function requestMcpStatus(): Promise<void> {
	const custom = await loadCustomServers()
	const externalNames = await loadAntigravityServerNames({ files: AGY_MCP_CONFIG_FILES })
	const servers = [
		...Object.keys(custom.servers).map((name) => ({
			name,
			status: 'connected',
			error: null,
			source: 'dynamic',
			tools: null,
		})),
		...externalNames
			.filter((name) => !(name in custom.servers))
			.map((name) => ({
				name,
				status: 'connected',
				error: null,
				source: 'user',
				tools: null,
			})),
	]
	emit({ type: 'mcpStatus', servers, problems: custom.problems })
}

export async function signInToServer({ name }: { name: string }): Promise<void> {
	await signIn({ name })
}

export async function messageTask({ job, text }: { job: string; text: string }): Promise<void> {
	const target = taskMap.get(job)
	if (target == null) return
	target.status = 'running'
	emitTaskEvent({ runtime: target })
	void target.conversation.enqueue({ text }).catch((error) => {
		target.status = 'failed'
		target.result = error instanceof Error ? error.message : String(error)
		emitTaskEvent({ runtime: target })
		emit({ type: 'result', text: target.result, isError: true, job })
	})
}

export async function forgetThread({ sessionId }: { sessionId: string }): Promise<void> {
	removeStoredThread({ sessionId })
	for (const [job, runtime] of [...taskMap.entries()]) {
		if (runtime.record.threadId === sessionId) {
			await runtime.conversation.interrupt()
			await runtime.conversation.close()
			taskMap.delete(job)
			try {
				appendFileSync(TASKS_FILE, `${JSON.stringify({ taskId: job, isDeleted: true })}\n`)
			} catch {
				// Best effort cleanup.
			}
		}
	}
	if (foreground?.sessionId === sessionId) {
		resetSession()
	}
}

export async function stopTask({ job }: { job: string }): Promise<void> {
	const target = taskMap.get(job)
	if (target == null) return
	await target.conversation.interrupt()
	await target.conversation.close()
	target.status = 'stopped'
	emitTaskEvent({ runtime: target })
}
