// In-process Streamable HTTP MCP server for Bol's tools (computer control, screen capture, tasks) driven by `agy acp`.
import { randomUUID } from 'node:crypto'
import type { z } from 'zod'

export type ToolResultContent = { type: 'text'; text: string } | { type: 'image'; data: string; mimeType: string }

export type ToolResult = {
	content: ToolResultContent[]
	isError?: boolean
}

export type BolTool<TShape extends z.ZodRawShape = any> = {
	name: string
	description: string
	shape: TShape
	schema: z.ZodObject<TShape>
	inputSchema: Record<string, unknown>
	handler: (args: z.infer<z.ZodObject<TShape>>) => Promise<ToolResult> | ToolResult
}

/** HTTP MCP config shape expected by `agy acp` in `mcpServers`. */
export type AcpHttpMcpServer = {
	type: 'http'
	name: string
	url: string
	headers: { name: string; value: string }[]
}

function normalizeJsonSchema({ schema }: { schema: unknown }): unknown {
	if (Array.isArray(schema)) {
		return schema.map((item) => normalizeJsonSchema({ schema: item }))
	}
	if (schema == null || typeof schema !== 'object') {
		return schema
	}
	const out: Record<string, unknown> = {}
	const src = schema as Record<string, unknown>
	for (const [key, value] of Object.entries(src)) {
		if (key === '$schema') continue
		if (key === 'prefixItems') continue
		if (key === 'items' && value === false) continue
		out[key] = normalizeJsonSchema({ schema: value })
	}
	if (out.type === 'array' && out.items == null) {
		const prefix = Array.isArray(src.prefixItems) ? src.prefixItems[0] : undefined
		out.items = prefix != null ? normalizeJsonSchema({ schema: prefix }) : { type: 'number' }
	}
	return out
}

export function tool<TShape extends z.ZodRawShape>(
	name: string,
	description: string,
	shape: TShape,
	handler: (args: z.infer<z.ZodObject<TShape>>) => Promise<ToolResult> | ToolResult,
): BolTool<TShape> {
	const zModule = require('zod') as typeof import('zod')
	const schema = zModule.z.object(shape)
	const inputSchema = normalizeJsonSchema({ schema: zModule.z.toJSONSchema(schema) }) as Record<string, unknown>
	return { name, description, shape, schema, inputSchema, handler }
}

type EndpointEntry = {
	toolsByName: Map<string, BolTool>
	list: { name: string; description: string; inputSchema: Record<string, unknown> }[]
}

type JsonRpcRequest = {
	jsonrpc?: string
	id?: string | number | null
	method?: string
	params?: Record<string, unknown>
}

const PROTOCOL_VERSION = '2025-03-26'

function jsonRpcResult({ id, result }: { id: string | number | null | undefined; result: unknown }) {
	return { jsonrpc: '2.0', id: id ?? null, result }
}

function jsonRpcError({
	id,
	code,
	message,
}: {
	id: string | number | null | undefined
	code: number
	message: string
}) {
	return { jsonrpc: '2.0', id: id ?? null, error: { code, message } }
}

export class BolMcpServer {
	private readonly token = randomUUID()
	private readonly endpoints = new Map<string, EndpointEntry>()
	private readonly server: ReturnType<typeof Bun.serve>

	constructor() {
		this.server = Bun.serve({
			hostname: '127.0.0.1',
			port: 0,
			fetch: (req) => this.handleRequest(req),
		})
	}

	get port(): number {
		return this.server.port ?? 0
	}

	register({ key, name, tools }: { key: string; name: string; tools: BolTool[] }): AcpHttpMcpServer {
		const toolsByName = new Map<string, BolTool>()
		const list: { name: string; description: string; inputSchema: Record<string, unknown> }[] = []
		for (const entry of tools) {
			toolsByName.set(entry.name, entry)
			list.push({
				name: entry.name,
				description: entry.description,
				inputSchema: entry.inputSchema,
			})
		}
		this.endpoints.set(key, { toolsByName, list })
		return {
			type: 'http',
			name,
			url: `http://127.0.0.1:${this.port}/mcp/${encodeURIComponent(key)}`,
			headers: [{ name: 'Authorization', value: `Bearer ${this.token}` }],
		}
	}

	unregister({ key }: { key: string }): void {
		this.endpoints.delete(key)
	}

	stop(): void {
		this.server.stop(true)
	}

	private async handleRequest(req: Request): Promise<Response> {
		if (req.headers.get('authorization') !== `Bearer ${this.token}`) {
			return new Response('Unauthorized', { status: 401 })
		}
		const url = new URL(req.url)
		if (!url.pathname.startsWith('/mcp/')) {
			return new Response('Not Found', { status: 404 })
		}
		const key = decodeURIComponent(url.pathname.slice('/mcp/'.length))
		const endpoint = this.endpoints.get(key)
		if (endpoint == null) {
			return new Response('Unknown MCP endpoint', { status: 404 })
		}
		if (req.method === 'DELETE') {
			return new Response(null, { status: 204 })
		}
		if (req.method === 'GET') {
			return new Response('Method Not Allowed', { status: 405 })
		}
		if (req.method !== 'POST') {
			return new Response('Method Not Allowed', { status: 405 })
		}

		let body: unknown
		try {
			body = await req.json()
		} catch {
			return Response.json(jsonRpcError({ id: null, code: -32700, message: 'Parse error' }), { status: 400 })
		}

		if (Array.isArray(body)) {
			const responses: unknown[] = []
			for (const item of body) {
				const res = await this.dispatch({ rpc: item as JsonRpcRequest, endpoint })
				if (res != null) responses.push(res)
			}
			if (responses.length === 0) return new Response(null, { status: 202 })
			return Response.json(responses, { headers: { 'mcp-protocol-version': PROTOCOL_VERSION } })
		}

		const res = await this.dispatch({ rpc: body as JsonRpcRequest, endpoint })
		if (res == null) return new Response(null, { status: 202 })
		return Response.json(res, { headers: { 'mcp-protocol-version': PROTOCOL_VERSION } })
	}

	private async dispatch({
		rpc,
		endpoint,
	}: {
		rpc: JsonRpcRequest
		endpoint: EndpointEntry
	}): Promise<Record<string, unknown> | null> {
		const method = rpc.method ?? ''
		const isNotification = rpc.id === undefined || method.startsWith('notifications/')
		if (isNotification) return null

		if (method === 'server/discover' || method === 'ping') {
			return jsonRpcResult({ id: rpc.id, result: {} })
		}

		if (method === 'initialize') {
			return jsonRpcResult({
				id: rpc.id,
				result: {
					protocolVersion: PROTOCOL_VERSION,
					capabilities: { tools: {} },
					serverInfo: { name: 'bol', version: '1.0.0' },
				},
			})
		}

		if (method === 'tools/list') {
			return jsonRpcResult({
				id: rpc.id,
				result: { tools: endpoint.list },
			})
		}

		if (method === 'tools/call') {
			const params = (rpc.params ?? {}) as { name?: string; arguments?: Record<string, unknown> }
			const name = params.name ?? ''
			const registered = endpoint.toolsByName.get(name)
			if (registered == null) {
				return jsonRpcError({ id: rpc.id, code: -32601, message: `Unknown tool: ${name}` })
			}
			const parsed = registered.schema.safeParse(params.arguments ?? {})
			if (!parsed.success) {
				return jsonRpcResult({
					id: rpc.id,
					result: {
						content: [{ type: 'text', text: `Invalid arguments for ${name}: ${parsed.error.message}` }],
						isError: true,
					},
				})
			}
			try {
				const result = await registered.handler(parsed.data)
				return jsonRpcResult({ id: rpc.id, result })
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error)
				return jsonRpcResult({
					id: rpc.id,
					result: {
						content: [{ type: 'text', text: message }],
						isError: true,
					},
				})
			}
		}

		return jsonRpcError({ id: rpc.id, code: -32601, message: `Method not found: ${method}` })
	}
}
