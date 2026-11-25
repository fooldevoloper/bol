// look_at_screen: an in-process MCP tool that screenshots the frontmost window.

import { readFile, unlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { z } from 'zod'
import { SCREEN_MODE } from './constants'
import { controlTools } from './control'
import { type BolTool, tool } from './mcp-server'
import { sh } from './utils'

/** Frontmost app, window title and (for browsers) the current URL. */
async function frontmostContext(): Promise<{ app: string; title: string; url: string; bounds: number[] | null }> {
	const info = await sh({
		cmd: [
			'osascript',
			'-e',
			`
    tell application "System Events"
      set p to first process whose frontmost is true
      set appName to name of p
      set winTitle to ""
      set b to ""
      try
        set w to front window of p
        set winTitle to name of w
        set {x, y} to position of w
        set {ww, hh} to size of w
        set b to (x as text) & "," & (y as text) & "," & (ww as text) & "," & (hh as text)
      end try
      return appName & linefeed & winTitle & linefeed & b
    end tell`,
		],
	})
	const [app = '', title = '', b = ''] = info.split('\n')
	let url = ''
	try {
		if (/chrome/i.test(app))
			url = await sh({
				cmd: ['osascript', '-e', 'tell application "Google Chrome" to get URL of active tab of front window'],
			})
		else if (/safari/i.test(app))
			url = await sh({ cmd: ['osascript', '-e', 'tell application "Safari" to get URL of front document'] })
		else if (/arc/i.test(app))
			url = await sh({
				cmd: ['osascript', '-e', 'tell application "Arc" to get URL of active tab of front window'],
			})
	} catch {}
	const nums = b.split(',').map(Number)
	return { app, title, url, bounds: nums.length === 4 && nums.every((n) => Number.isFinite(n)) ? nums : null }
}

const makeLookAtScreen = ({ onScreen }: { onScreen: (event: { reason: string }) => void }) =>
	tool(
		'look_at_screen',
		'See what the user is looking at on their Mac right now: returns a screenshot plus the frontmost app, window title and browser URL. ' +
			"Use it when the request refers to something on screen or needs visual context. Prefer scope 'window' (the frontmost window); use 'screen' for the whole display.",
		{
			reason: z.string().describe('A few words on why you need to look, shown to the user'),
			scope: z.enum(['window', 'screen']).optional().describe('Default: window'),
		},
		async ({ reason, scope }) => {
			onScreen({ reason })
			const ctx = await frontmostContext()
			const file = join(tmpdir(), `bol-screen-${Date.now()}.jpg`)
			const args = ['screencapture', '-x', '-t', 'jpg']
			if ((scope ?? 'window') === 'window' && ctx.bounds != null) args.push('-R', ctx.bounds.join(','))
			args.push(file)
			await sh({ cmd: args })
			let image = ''
			try {
				await sh({ cmd: ['sips', '-Z', '1600', file] }) // keep it readable but small
				image = (await readFile(file)).toString('base64')
			} catch {}
			await unlink(file).catch(() => {})
			const lines = [`Frontmost app: ${ctx.app === '' ? 'unknown' : ctx.app}`]
			if (ctx.title !== '') lines.push(`Window: ${ctx.title}`)
			if (ctx.url !== '') lines.push(`URL: ${ctx.url}`)
			const text = lines.join('\n')
			if (image === '') {
				return {
					content: [
						{
							type: 'text',
							text: text + '\n(Screenshot failed: Bol may need Screen Recording permission.)',
						},
					],
					isError: true,
				}
			}
			return {
				content: [
					{ type: 'text', text },
					{ type: 'image', data: image, mimeType: 'image/jpeg' },
				],
			}
		},
	)

/** Bol's own tools, registered on `BolMcpServer` for each conversation or task. */
export function makeBolTools({
	onScreen,
	extraTools,
}: {
	onScreen: (event: { reason: string }) => void
	/** The thread's task tools. */
	extraTools: BolTool[]
}): BolTool[] {
	return [...(SCREEN_MODE === 'off' ? [] : [makeLookAtScreen({ onScreen }), ...controlTools]), ...extraTools]
}
