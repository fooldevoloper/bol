// Bol brain: a long-lived Antigravity ACP session driven over stdio.
// The Swift menu-bar app spawns this process and talks to it with JSON lines (see protocol.ts).

import { mkdir, writeFile } from 'node:fs/promises'
import { createInterface } from 'node:readline'
import { AGY_BINARY, BOL_PROMPT, DEFAULT_PROMPT_FILE, MEMORY_DIR, THREADS_DIR, WORKSPACE_DIR } from './constants'
import { resolveControl } from './control'
import { watchCustomServers } from './mcp-config'
import { Command, emit, log } from './protocol'
import {
	closeSession,
	continueSession,
	ensureSession,
	forgetThread,
	interruptSession,
	loadTasks,
	messageTask,
	reloadCustomServers,
	requestMcpStatus,
	resetSession,
	say,
	signInToServer,
	stopTask,
} from './session'
import { exhaustiveGuard } from './utils'

await Promise.all([MEMORY_DIR, THREADS_DIR, WORKSPACE_DIR].map((dir) => mkdir(dir, { recursive: true })))
await writeFile(DEFAULT_PROMPT_FILE, BOL_PROMPT.trim() + '\n').catch(() => {})

const rl = createInterface({ input: process.stdin })

rl.on('line', async (line) => {
	let cmd: Command
	try {
		cmd = Command.parse(JSON.parse(line))
	} catch (e) {
		log({ msg: `bad command ${line.slice(0, 200)}: ${e}` })
		return
	}
	switch (cmd.type) {
		case 'say':
			say({ text: cmd.text, seq: cmd.seq ?? 0 })
			break
		case 'messageTask':
			messageTask({ job: cmd.job, text: cmd.text })
			break
		case 'stopTask':
			stopTask({ job: cmd.job })
			break
		case 'interrupt':
			await interruptSession().catch((e) => log({ msg: `interrupt failed: ${e}` }))
			break
		case 'reset':
			resetSession()
			log({ msg: 'conversation reset' })
			break
		case 'continue':
			continueSession({ sessionId: cmd.sessionId })
			break
		case 'mcpStatus':
			await requestMcpStatus()
			break
		case 'mcpSignIn':
			await signInToServer({ name: cmd.name })
			break
		case 'forgetThread':
			await forgetThread({ sessionId: cmd.sessionId })
			break
		case 'controlResult':
			resolveControl({ id: cmd.id, text: cmd.text, isError: cmd.isError, images: cmd.images })
			break
		default:
			exhaustiveGuard(cmd)
	}
})

rl.on('close', () => {
	closeSession()
	process.exit(0)
})

log({ msg: `agy: ${AGY_BINARY}` })
await loadTasks()
ensureSession()
watchCustomServers({ onChange: () => void reloadCustomServers() })
emit({ type: 'ready' })
