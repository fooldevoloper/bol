// Local JSONL transcript archiving under ~/.bol/threads/<sessionId>.jsonl for the Threads UI.
import { appendFileSync, mkdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { THREADS_DIR } from './constants'

type TranscriptContent =
	| { type: 'text'; text: string }
	| { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
	| { type: 'tool_result'; tool_use_id: string; content: string | unknown; is_error?: boolean }

type TranscriptEntry =
	| { type: 'user'; timestamp: string; message: { role: 'user'; content: string | TranscriptContent[] } }
	| {
			type: 'assistant'
			timestamp: string
			message: {
				role: 'assistant'
				model?: string
				usage?: Record<string, number>
				content: TranscriptContent[]
			}
	  }
	| { type: 'system'; timestamp: string; error?: string; level?: string }

function fileOf({ sessionId }: { sessionId: string }) {
	return join(THREADS_DIR, `${sessionId}.jsonl`)
}

/** Last time the thread had transcript activity on disk, or 0 if not found. */
export function lastActivity({ sessionId }: { sessionId: string }): number {
	try {
		return statSync(fileOf({ sessionId })).mtimeMs
	} catch {
		return 0
	}
}

export function makeThreadArchive({ sessionId }: { sessionId: string }) {
	mkdirSync(THREADS_DIR, { recursive: true })
	const path = fileOf({ sessionId })

	function write({ entry }: { entry: TranscriptEntry }) {
		try {
			appendFileSync(path, `${JSON.stringify(entry)}\n`)
		} catch {
			// Best-effort archival: don't fail a live turn if disk write fails.
		}
	}

	return {
		path,
		appendUser({ text }: { text: string }) {
			write({
				entry: {
					type: 'user',
					timestamp: new Date().toISOString(),
					message: { role: 'user', content: text },
				},
			})
		},
		appendAssistant({
			content,
			model,
			usage,
		}: {
			content: TranscriptContent[]
			model?: string
			usage?: Record<string, number>
		}) {
			if (content.length === 0) return
			write({
				entry: {
					type: 'assistant',
					timestamp: new Date().toISOString(),
					message: { role: 'assistant', model, usage, content },
				},
			})
		},
		appendToolResult({
			toolUseId,
			content,
			isError,
		}: {
			toolUseId: string
			content: string | unknown
			isError?: boolean
		}) {
			write({
				entry: {
					type: 'user',
					timestamp: new Date().toISOString(),
					message: {
						role: 'user',
						content: [{ type: 'tool_result', tool_use_id: toolUseId, content, is_error: isError }],
					},
				},
			})
		},
		appendError({ error }: { error: string }) {
			write({
				entry: {
					type: 'system',
					timestamp: new Date().toISOString(),
					level: 'error',
					error,
				},
			})
		},
	}
}
