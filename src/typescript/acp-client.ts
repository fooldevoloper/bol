// JSON-RPC 2.0 NDJSON client over stdio for `agy acp` sessions.
import { AGY_BINARY } from './constants'
import { type AcpMcpServer } from './mcp-config'
import type { AcpHttpMcpServer } from './mcp-server'
import { log } from './protocol'

export type AnyAcpMcpServer = AcpMcpServer | AcpHttpMcpServer

export type AcpConfigOption = {
	id: string
	currentValue?: string
	options?: { value: string; name?: string }[]
}

export type AcpUsage = {
	inputTokens?: number
	outputTokens?: number
	cachedReadTokens?: number
	cachedWriteTokens?: number
	thoughtTokens?: number
	totalTokens?: number
}

export type AcpSessionInfo = {
	sessionId: string
	models?: { availableModels?: { modelId: string; name?: string }[]; currentModelId?: string }
	configOptions?: AcpConfigOption[]
}

export type AcpSessionUpdate = {
	sessionUpdate?: string
	[key: string]: unknown
}

type PendingRequest = {
	resolve: (result: unknown) => void
	reject: (err: Error) => void
}

type JsonRpcMessage = {
	jsonrpc?: string
	id?: string | number | null
	method?: string
	params?: Record<string, unknown>
	result?: unknown
	error?: { code?: number; message?: string; data?: unknown }
}

function chooseAllowOption({ options }: { options: unknown }): string | null {
	if (!Array.isArray(options)) return null
	const list = options as { optionId?: string; kind?: string }[]
	const preferred =
		list.find((o) => o.kind === 'allow_always') ??
		list.find((o) => o.kind === 'allow_once') ??
		list.find((o) => o.optionId?.startsWith('allow')) ??
		list[0]
	return preferred?.optionId ?? null
}

export class AcpClient {
	private readonly proc: ReturnType<typeof Bun.spawn<'pipe', 'pipe', 'pipe'>>
	private readonly pending = new Map<number, PendingRequest>()
	private readonly onUpdate: (event: { sessionId: string; update: AcpSessionUpdate }) => void
	private readonly onExit?: (event: { code: number | null }) => void
	private readonly onElicitation?: (params: Record<string, unknown>) => void
	private nextId = 1
	private isClosed = false

	constructor({
		cwd,
		onUpdate,
		onExit,
		onElicitation,
	}: {
		cwd: string
		onUpdate: (event: { sessionId: string; update: AcpSessionUpdate }) => void
		onExit?: (event: { code: number | null }) => void
		onElicitation?: (params: Record<string, unknown>) => void
	}) {
		this.onUpdate = onUpdate
		this.onExit = onExit
		this.onElicitation = onElicitation

		const env = { ...process.env }
		this.proc = Bun.spawn(
			[AGY_BINARY, 'acp', '--dangerously-skip-permissions', '--disable-telemetry', '--process-per-session'],
			{
				cwd,
				env,
				stdin: 'pipe',
				stdout: 'pipe',
				stderr: 'pipe',
			},
		)

		void this.readStdout()
		void this.readStderr()
		void this.proc.exited.then((code) => {
			this.rejectAll({ message: `Antigravity ACP exited with code ${code}` })
			if (!this.isClosed) this.onExit?.({ code })
		})
	}

	async initialize(): Promise<Record<string, unknown>> {
		return (await this.request({
			method: 'initialize',
			params: {
				protocolVersion: 1,
				clientCapabilities: {},
				clientInfo: { name: 'bol-brain', version: '0.1.0' },
			},
		})) as Record<string, unknown>
	}

	async newSession({
		cwd,
		mcpServers,
		appendSystemPrompt,
	}: {
		cwd: string
		mcpServers: AnyAcpMcpServer[]
		appendSystemPrompt?: string
	}): Promise<AcpSessionInfo> {
		const params: Record<string, unknown> = { cwd, mcpServers }
		if (appendSystemPrompt != null && appendSystemPrompt.trim().length > 0) {
			params._meta = { antigravity: { systemPrompt: { append: appendSystemPrompt } } }
		}
		return (await this.request({ method: 'session/new', params })) as AcpSessionInfo
	}

	async resumeSession({
		sessionId,
		cwd,
		mcpServers,
		appendSystemPrompt,
	}: {
		sessionId: string
		cwd: string
		mcpServers: AnyAcpMcpServer[]
		appendSystemPrompt?: string
	}): Promise<AcpSessionInfo> {
		const params: Record<string, unknown> = { sessionId, cwd, mcpServers }
		if (appendSystemPrompt != null && appendSystemPrompt.trim().length > 0) {
			params._meta = { antigravity: { systemPrompt: { append: appendSystemPrompt } } }
		}
		return (await this.request({ method: 'session/resume', params })) as AcpSessionInfo
	}

	async setConfigOption({
		sessionId,
		configId,
		value,
	}: {
		sessionId: string
		configId: string
		value: string
	}): Promise<void> {
		await this.request({
			method: 'session/set_config_option',
			params: { sessionId, configId, value },
		})
	}

	async prompt({
		sessionId,
		text,
	}: {
		sessionId: string
		text: string
	}): Promise<{ stopReason?: string; usage?: AcpUsage }> {
		return (await this.request({
			method: 'session/prompt',
			params: {
				sessionId,
				prompt: [{ type: 'text', text }],
			},
		})) as { stopReason?: string; usage?: AcpUsage }
	}

	cancel({ sessionId }: { sessionId: string }): void {
		this.send({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } })
	}

	async close({ sessionId }: { sessionId?: string }): Promise<void> {
		this.isClosed = true
		if (sessionId != null) {
			try {
				await Promise.race([
					this.request({ method: 'session/close', params: { sessionId } }),
					new Promise((resolve) => setTimeout(resolve, 1000)),
				])
			} catch {
				// Ignore close errors when tearing down.
			}
		}
		this.rejectAll({ message: 'ACP session closed' })
		try {
			this.proc.kill()
		} catch {
			// Process may already have exited.
		}
	}

	private request({ method, params }: { method: string; params: Record<string, unknown> }): Promise<unknown> {
		if (this.isClosed) return Promise.reject(new Error(`ACP client is closed (${method})`))
		const id = this.nextId++
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject })
			this.send({ jsonrpc: '2.0', id, method, params })
		})
	}

	private send(payload: Record<string, unknown>): void {
		try {
			this.proc.stdin.write(`${JSON.stringify(payload)}\n`)
			void this.proc.stdin.flush()
		} catch (error) {
			log({ msg: `acp stdin write failed: ${error}` })
		}
	}

	private rejectAll({ message }: { message: string }): void {
		const err = new Error(message)
		for (const entry of this.pending.values()) entry.reject(err)
		this.pending.clear()
	}

	private async readStdout(): Promise<void> {
		await this.readLines({
			stream: this.proc.stdout,
			onLine: (line) => {
				if (line.length === 0) return
				let msg: JsonRpcMessage
				try {
					msg = JSON.parse(line) as JsonRpcMessage
				} catch {
					log({ msg: `acp non-json line: ${line.slice(0, 200)}` })
					return
				}
				this.handleMessage({ msg })
			},
		})
	}

	private async readStderr(): Promise<void> {
		await this.readLines({
			stream: this.proc.stderr,
			onLine: (line) => {
				if (line.length === 0) return
				log({ msg: `[agy] ${line}` })
			},
		})
	}

	private async readLines({
		stream,
		onLine,
	}: {
		stream: ReadableStream<Uint8Array>
		onLine: (line: string) => void
	}): Promise<void> {
		const reader = stream.getReader()
		const decoder = new TextDecoder()
		let buffer = ''
		try {
			while (true) {
				const { value, done } = await reader.read()
				if (done) break
				buffer += decoder.decode(value, { stream: true })
				let nl = buffer.indexOf('\n')
				while (nl !== -1) {
					onLine(buffer.slice(0, nl).trim())
					buffer = buffer.slice(nl + 1)
					nl = buffer.indexOf('\n')
				}
			}
			const tail = (buffer + decoder.decode()).trim()
			if (tail.length > 0) onLine(tail)
		} catch (error) {
			if (!this.isClosed) log({ msg: `acp stream read error: ${error}` })
		} finally {
			reader.releaseLock()
		}
	}

	private handleMessage({ msg }: { msg: JsonRpcMessage }): void {
		if (msg.method === 'session/update' && msg.params != null) {
			const sessionId = typeof msg.params.sessionId === 'string' ? msg.params.sessionId : ''
			const update = (msg.params.update ?? {}) as AcpSessionUpdate
			this.onUpdate({ sessionId, update })
			return
		}

		// Server-to-client RPC request needing a response.
		if (msg.id != null && msg.method != null) {
			this.handleServerRequest({ id: msg.id, method: msg.method, params: msg.params ?? {} })
			return
		}

		// Response to one of our outgoing requests.
		if (typeof msg.id === 'number') {
			const entry = this.pending.get(msg.id)
			if (entry == null) return
			this.pending.delete(msg.id)
			if (msg.error != null) {
				entry.reject(new Error(msg.error.message ?? JSON.stringify(msg.error)))
			} else {
				entry.resolve(msg.result)
			}
		}
	}

	private handleServerRequest({
		id,
		method,
		params,
	}: {
		id: string | number
		method: string
		params: Record<string, unknown>
	}): void {
		if (method === 'session/request_permission') {
			const optionId = chooseAllowOption({ options: params.options })
			this.send({
				jsonrpc: '2.0',
				id,
				result: {
					outcome: optionId != null ? { outcome: 'selected', optionId } : { outcome: 'cancelled' },
				},
			})
			return
		}

		if (method === 'elicitation/create') {
			this.onElicitation?.(params)
			this.send({
				jsonrpc: '2.0',
				id,
				result: { action: 'accept' },
			})
			return
		}

		this.send({
			jsonrpc: '2.0',
			id,
			error: { code: -32601, message: `Unsupported client method: ${method}` },
		})
	}
}
