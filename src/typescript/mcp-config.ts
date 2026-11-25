// The user's own MCP servers, from ~/.bol/mcp.json.
//
// Formatted cleanly for Antigravity ACP (`http` and `stdio` transports) while keeping the
// standard `~/.bol/mcp.json` schema (`env` and `headers` as string maps) so existing configs work.

import { watch } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { basename } from 'node:path'
import { z } from 'zod'
import { BOL_DIR, MCP_FILE, RESERVED_MCP_NAMES } from './constants'
import { log } from './protocol'

const common = {
	timeout: z.number().optional(),
	alwaysLoad: z.boolean().optional(),
	disabled: z.boolean().optional(),
}

const Stdio = z.object({
	type: z.literal('stdio').optional(),
	command: z.string().min(1, 'needs a command'),
	args: z.array(z.string()).optional(),
	env: z.record(z.string(), z.string()).optional(),
	...common,
})

const Remote = z.object({
	// "streamable-http" is what some clients call http; a url with no type is http too.
	type: z.enum(['http', 'sse', 'streamable-http']).optional(),
	url: z.url('needs a valid url'),
	headers: z.record(z.string(), z.string()).optional(),
	...common,
})

const NAME = /^[A-Za-z0-9_-]{1,64}$/

export type AcpStdioMcpServer = {
	name: string
	command: string
	args: string[]
	env: { name: string; value: string }[]
}

export type AcpHttpMcpServer = {
	type: 'http'
	name: string
	url: string
	headers: { name: string; value: string }[]
}

export type AcpMcpServer = AcpStdioMcpServer | AcpHttpMcpServer

export type CustomServers = {
	servers: Record<string, AcpMcpServer>
	/** Entries that couldn't be used, with why: shown in Settings. */
	problems: { name: string; error: string }[]
}

function toNamedList(record?: Record<string, string>): { name: string; value: string }[] {
	if (record == null) return []
	return Object.entries(record).map(([name, value]) => ({ name, value }))
}

function toConfig(name: string, entry: z.infer<typeof Stdio> | z.infer<typeof Remote>): AcpMcpServer | null {
	if ('command' in entry) {
		return {
			name,
			command: entry.command,
			args: entry.args ?? [],
			env: toNamedList(entry.env),
		}
	}
	if (entry.type === 'sse') return null
	return {
		type: 'http',
		name,
		url: entry.url,
		headers: toNamedList(entry.headers),
	}
}

export async function loadCustomServers(): Promise<CustomServers> {
	const result: CustomServers = { servers: {}, problems: [] }
	let raw: string
	try {
		raw = await readFile(MCP_FILE, 'utf8')
	} catch {
		return result // no file: no custom servers
	}
	let parsed: unknown
	try {
		parsed = JSON.parse(raw)
	} catch (e) {
		result.problems.push({ name: 'mcp.json', error: `isn't valid JSON: ${(e as Error).message}` })
		return result
	}
	const entries = (parsed as { mcpServers?: unknown })?.mcpServers
	if (entries == null || typeof entries !== 'object' || Array.isArray(entries)) {
		result.problems.push({ name: 'mcp.json', error: 'needs a top-level "mcpServers" object' })
		return result
	}
	for (const [name, value] of Object.entries(entries)) {
		if (!NAME.test(name)) {
			result.problems.push({ name, error: 'names can only use letters, digits, - and _' })
			continue
		}
		if (RESERVED_MCP_NAMES.includes(name)) {
			result.problems.push({ name, error: 'this name is used by Bol itself; pick another' })
			continue
		}
		const isRemote = typeof value === 'object' && value != null && 'url' in value
		const entry = (isRemote ? Remote : Stdio).safeParse(value)
		if (!entry.success) {
			result.problems.push({ name, error: entry.error.issues.map((i) => i.message).join('; ') })
			continue
		}
		if (entry.data.disabled === true) continue
		const config = toConfig(name, entry.data)
		if (config == null) {
			result.problems.push({ name, error: 'SSE transport is not supported by Antigravity (use http or stdio)' })
			continue
		}
		result.servers[name] = config
	}
	return result
}

/** Reads server names configured globally in Antigravity so Settings can list them alongside ~/.bol/mcp.json. */
export async function loadAntigravityServerNames({ files }: { files: string[] }): Promise<string[]> {
	const names = new Set<string>()
	for (const file of files) {
		try {
			const parsed = JSON.parse(await readFile(file, 'utf8')) as { mcpServers?: unknown }
			if (
				parsed?.mcpServers != null &&
				typeof parsed.mcpServers === 'object' &&
				!Array.isArray(parsed.mcpServers)
			) {
				for (const name of Object.keys(parsed.mcpServers)) names.add(name)
			}
		} catch {
			// File may not exist or be empty.
		}
	}
	return [...names]
}

/** Calls `onChange` (debounced) whenever mcp.json is written, created or deleted. */
export function watchCustomServers({ onChange }: { onChange: () => void }) {
	let timer: ReturnType<typeof setTimeout> | null = null
	try {
		// The directory, not the file: editors replace files on save, which ends a watch on the file.
		watch(BOL_DIR, (_event, file) => {
			if (file != null && file !== basename(MCP_FILE)) return
			if (timer != null) clearTimeout(timer)
			timer = setTimeout(onChange, 300)
		})
	} catch (e) {
		log({ msg: `can't watch ${MCP_FILE}: ${e}` })
	}
}
