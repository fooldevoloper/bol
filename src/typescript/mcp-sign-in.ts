// Browser sign-in helper for MCP servers that expose an auth URL in an elicitation or problem note.
import { spawn } from 'node:child_process'
import { emit, log } from './protocol'

const URL_IN_TEXT = /https?:\/\/[^\s<>"')\]]+/

export function findUrl({ text }: { text: string }): string | undefined {
	const match = text.match(URL_IN_TEXT)
	return match?.[0]
}

export function openInBrowser({ url }: { url: string }): boolean {
	try {
		const child = spawn('open', [url], { stdio: 'ignore', detached: true })
		child.unref()
		return true
	} catch (error) {
		log({ msg: `open url failed: ${error}` })
		return false
	}
}

export async function signIn({ name, authUrl }: { name: string; authUrl?: string }): Promise<string> {
	if (authUrl != null && openInBrowser({ url: authUrl })) {
		emit({ type: 'mcpSignIn', name, url: authUrl, error: null })
		emit({ type: 'mcpSignInDone', name, status: 'needs-auth' })
		return `Opened sign-in page for "${name}" in Chrome. Ask the user to finish signing in there.`
	}
	const error = 'No sign-in URL available; configure credentials via `agy mcp` or `~/.bol/mcp.json`.'
	emit({ type: 'mcpSignIn', name, url: null, error })
	emit({ type: 'mcpSignInDone', name, status: 'failed' })
	return error
}
