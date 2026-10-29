# Capri — MVP v1.0 / Technical Design

**Status:** baseline specification (2026-10-26)  
**Product:** local-first native macOS character companion and coding-agent control center.  
**Primary user:** single developer; optional public/open-source later.

## 1. Product intent

Capri is an animated desktop character that is also a fast, unified interface to Codex, Claude Code, local/remote tmux sessions, SSH servers, projects, and Telegram. It offers text chat and a dedicated push-to-talk hotkey. It informs the user when an agent finishes, fails, needs approval/input, or encounters a verified usage limit. It is **not** an autonomous operator by default. No unsolicited destructive actions, no generalized browser automation in MVP.

### Agreed choices
- Discover existing sessions **and** create managed sessions.
- macOS Core is authoritative; on an existing server a small remote relay is permitted solely for Telegram and remote-only operations if the Mac is asleep/offline.
- Character freely roams the desktop and can rest near the MacBook notch. User can scale, quiet, hide for one hour, pin, switch to notch-only, mute and pause animation.
- Separate Capri push-to-talk shortcut, powered by an adapter to Tima Transcriber.
- Telegram allows session browsing, commands, input, approvals (when reliably supported), and remote status.
- Codex and Claude Code are P0; Hermes/Ollama/provider adapters are optional. Browser extension, wake word, dynamic TTS, other CLIs are out of initial scope.

## 2. MVP definition of done
1. On a notched MacBook, Capri starts at login, can wander, drag, return to notch; transparency is hit-test safe and does not eat background clicks. A menu controls size, activity, mute, hide for 1 hour, quiet, full-screen behavior and per-app exceptions.
2. Click Capri to open a text chat displaying current projects/sessions. The user can ask about a selected session, request a summary and give it an instruction.
3. Codex adapter starts/resumes managed threads using `codex app-server`, streams turns and tool events, surfaces permission requests, stops/interrupts and account rate limits; login is handled through supported ChatGPT authentication.
4. Claude Code adapter monitors existing CLI sessions via installed hooks; created/manageable sessions use a documented CLI/SDK-backed launch mode. The app does not claim it can take control of every live, externally started TUI; unsafe operations require an explicit controlled tmux workflow.
5. A session registry enumerates local and designated remote tmux hosts via SSH config, differentiating read-only observed, controllable tmux, and fully managed agent sessions.
6. Event to UI chain reliably distinguishes running, thinking, waiting for user, completed, error, usage limit, suspected stall, disconnected and unknown. Notifications deduplicate.
7. Push-to-talk enters a text prompt through a local Tima Transcriber bridge, with a usable fallback if the transcriber is offline.
8. Persistent project memory is local Markdown; ephemeral events/session metadata live in SQLite; no passwords or tokens in model prompts/Markdown.
9. Telegram bot and compact Mini App show sessions and alert status and send user-requested commands. If Mac is offline, it accurately indicates offline and can view/control only remote sessions reachable by a deliberately deployed restricted relay.
10. Reconnect, restarts, permission timeouts, network loss, full-screen apps, multiple displays and sleep/wake are handled without crashing or false 'completed' states.

## 3. Architecture

```text
               ┌────────── macOS GUI ────────────┐
               │ SwiftUI Settings/Chat/Notch      │
               │ AppKit NSPanel overlay + WKWebView│
               │ (ported WebGL sprite animation)  │
               └──────────────┬───────────────────┘
                              │ local Unix socket / loopback IPC
                  ┌───────────▼────────────┐
                  │ Capri Core (TypeScript)│  launchd managed
                  │ event bus + session DB │
                  │ router + memory + auth │
                  └──────┬──────────┬──────┘
             ┌───────────▼───┐   ┌──▼─────────────────┐
             │ Agent adapters│   │ UX integrations    │
             │ Codex app-srv │   │ Tima STT bridge    │
             │ Claude hooks  │   │ pre-recorded voice │
             │ tmux / SSH    │   │ macOS notifications│
             └───────┬───────┘   └────────────────────┘
                     │
              local SSH/tmux hosts

      Mac Core ─ outbound authenticated connection ──► Telegram Gateway
                                                       (existing VPS)
           if Mac is offline, gateway limited to remote-only session scope
```

### Technology decisions
- GUI: Swift 6 / SwiftUI + AppKit NSPanel / NSWindow. Use small/bounded transparent panels rather than one permanent full-screen WebView to reduce hit-testing problems and unnecessary compositing.
- Animation: transplant suitable `sprite.js`, `acting.js`, `capri.js`, `fx.js` ideas/assets from `mochiiwuff/capri-desktop` into a dedicated JS/WebGL renderer hosted by `WKWebView`, with a host bridge. Treat WebGL transparency/performance as a feasibility spike; native rendering later if required.
- Core: TypeScript on current supported Node.js LTS; launchd service; JSON event stream over Unix domain socket (or authenticated local loopback if a service needs HTTP). Use a small contract shared with GUI.
- Data: SQLite (sessions, host metadata, event cursors, permission requests, delivery and dedup); Markdown (SOUL.md, USER.md, MEMORY.md, project notes). Search via SQLite FTS / indexes as needed.
- SSH: OpenSSH + `~/.ssh/config` host aliases, per-host least-privilege identity. Termius is not a database/interface dependency.
- Voice: Tima Transcriber via a **proposed** local socket/XPC/CLI adapter; MCP as an optional outward-facing tool integration, not low-latency local audio transport.
- Telegram: gateway via Bot API, minimal Mini App/dashboard; verify signed initData, restrict user IDs, and apply device pairing with expiring keys.

## 4. Session ownership model (critical)

Three levels, clearly shown in UI:

| Level | How found | Supported actions |
|---|---|---|
| Observed | process/tmux enumeration and logs | status, bounded read of output, open terminal, summary; no guaranteed prompt injection or approval |
| Controllable tmux | user pairs a specific existing session, Capri verifies readiness | same as observed + explicit send-input where safe; one active writer; no blind keystrokes |
| Managed | launched by Capri through app-server/CLI/SDK and recorded | thread/turn lifecycle, prompt, approvals where supported, interrupt/resume, complete event stream |

**Do not confuse** `tmux capture-pane` with structured agent state. Silence is not proof of a stall. When an external Codex or Claude Code terminal cannot be safely attached, show `Observed` and offer `Open in Terminal` or `Adopt Session` (explicit, capability-checked).

## 5. Normalized event contract

```ts
type AgentKind = 'codex' | 'claude';
type SessionControl = 'observed' | 'tmux-controlled' | 'managed';
type SessionState =
  | 'starting' | 'running' | 'thinking' | 'needs_input'
  | 'permission_required' | 'completed' | 'error'
  | 'rate_limited' | 'suspected_stall' | 'disconnected' | 'unknown';

type CapriEvent = {
  id: string;             // stable dedupe ID
  ts: string;             // ISO timestamp
  source: AgentKind | 'tmux' | 'ssh' | 'system';
  hostId: string;
  projectId?: string;
  sessionId: string;
  turnId?: string;
  state: SessionState;
  kind: string;           // lifecycle, tool, permission, rate-limit, etc.
  summary?: string;       // redact sensitive details before remote delivery
  requiresResponse?: boolean;
  approvalId?: string;   // one-time, expiring request ref
  confidence: 'event' | 'inferred';
};
```

Precedence: `permission_required` / `needs_input` > `rate_limited` / `error` > `completed` > `running`/`thinking` > `suspected_stall`. `disconnected` is a connectivity state and must not overwrite a known completed turn. Caprice animations react to transitions, not every tool event; use cooldowns and notification aggregation.

## 6. Adapter details

### Codex
- Boot and initialize `codex app-server`; implement `thread/start`, `thread/resume`, `turn/start`, `turn/steer`, `turn/interrupt`, event stream and structured approvals; model discovery rather than hard-coded names.
- Use `account/login/start` (local-supported ChatGPT) and `account/rateLimits/read` / `account/rateLimits/updated`; never extract/reuse raw Codex credential files.
- App-server authentication is currently documented for local/open-source; a future hosted/commercial distribution must assess Sign in with ChatGPT program instead of silently reusing local auth.
- Existing CLI sessions: metadata/history discovery can work, but control of an actively running TUI is not equivalent to ownership of its app-server connection.

### Claude Code
- Install narrowly scoped hook handlers for `SessionStart`, `Stop`, `Notification`, `PermissionRequest`, `PostToolUseFailure`, etc., keeping existing user hooks intact, reversible via uninstall.
- Hook body -> lightweight local event bridge. For approvals, only implement a supported blocking/decision path, with timeout and fallback to original prompt; never auto-approve high-risk tools.
- For created/managable sessions, integrate CLI or Agent SDK with explicit authentication; do not assume another application's subscription login grants third-party distributable access. Confirm currently applicable provider terms.

### tmux/SSH
- Enumerate configured SSH hosts; `tmux list-sessions`, `list-panes`, bounded `capture-pane`; optionally deploy a tiny hook/event forwarder to remote hosts when precise events matter.
- Do not execute unescaped strings or build SSH commands through interpolation. Cap output sizes and sanitize credentials before sending to an LLM or Telegram.
- Distinguish network-down, tmux missing, pane closed, process exited, agent completed, and request waiting. Single-writer locks for tmux input.

## 7. Character engine and preferences

Events map to animation clips: idle, wander, eye-follow, jump, sit-window, drop, teleport, notch-peek, sleep, working, thinking, asks-input, needs-approval, success, error, rate-limit and disconnected. Each animation has conditions, cooldown, priority and an optional short recorded audio sample.

- User settings: size (small/medium/large), screen choice, roaming bounds, activity frequency, notch-only mode, drag lock, hide for one hour, sleep/quiet, sound, DND, reduced-motion, battery-save mode and per-app full-screen exclusions.
- GUI never blocks clicks outside character/panel hotspots. Avoid permanent full-screen input windows.
- Pause animations on sleep/fullscreen/power-saving where appropriate; continue core event tracking if allowed.
- Dynamic TTS, wake-word, arbitrary screen control and a browser extension are explicitly **not MVP**.

## 8. Voice and memory

- Dedicated hotkey -> record -> Tima Transcriber -> recognized text -> Capri chat composer -> optional send confirmation. If Tima unavailable: display actionable state and offer typing, not silently fail.
- Initial audio: tagged pre-recorded phrases with per-event cooldown, priority and mute; separate assets from copyrighted anime dialogue.
- `~/.capri/SOUL.md`, `USER.md`, `MEMORY.md`, `projects/*.md`, `memory/YYYY-MM-DD.md`; SQLite holds sessions/events/delivery. Memory writes summarize durable facts, show provenance and allow editing/deletion. Project notes are only retrieved when relevant.

## 9. Telegram + offline behavior

- A bot and minimal Mini App provide dashboard, `sessions`, session details, last action, contextual send-input, approve/deny where genuine approvals are pending, /mute and notification preferences.
- Gateway runs on a user-controlled existing server. Mac Core maintains outbound authenticated connection for online state. When Mac is asleep/offline, the gateway returns `Mac offline` and permits only remote operations for hosts explicitly configured on the gateway; it **cannot** see Mac-local sessions or perform Mac-local actions.
- Secure by Telegram user allowlist + pairing, validated `initData`, mTLS or suitable authenticated transport, one-time expiring permission IDs, a minimal command allowlist, logging/auditing, redaction, no root SSH keys; never expose an unauthenticated shell over the internet.

## 10. Proposed repository layout

```text
capri/
  apps/
    macos/                    # SwiftUI/AppKit, notch, chat, settings
    telegram-mini-app/        # minimal web UI
  packages/
    core/                     # TypeScript daemon, routing, event bus
    protocol/                 # event schemas / DTOs
    agent-codex/              # app-server
    agent-claude/             # hooks, managed runner
    session-discovery/        # tmux and SSH observers
    character-renderer/      # WebGL/JS sprites & behavior
    memory/                  # Markdown + SQLite
    voice-bridge/            # Tima Transcriber adapter
    telegram-gateway/         # bot, pairing, bridge
  assets/
    character/               # licensed/original art only for distribution
    sound/
  scripts/
  docs/
    ADR/                    # architectural decisions
    PROTOCOL.md
    PERMISSIONS.md
```

## 11. Implementation phases and gates

**P0 — validation prototypes**
- Port *one* Capri sprite and a teleport animation into a native transparent macOS window with reliable click-through and reasonable power use.
- Receive 1 Codex app-server completion event and 1 Claude Code hook event; detect 1 remote tmux host.
- Exit: no blockers in WebGL/Swift bridge, Mac permissions and agent auth.

**P1 — character shell**
- Notch / wander / drag / size / temporary hide / mute / fullscreen handling / persistent settings / launch at login.
- Exit: enjoyable stable pet without any agent connected.

**P2 — local Core + coding agents**
- Event protocol, SQLite registry, Codex managed sessions, Claude managed/hooked sessions, session chat and required approvals.
- Exit: ask about a chosen session, start/continue a task, receive completion/permission notifications.

**P3 — discover & adopt**
- Discover external local/remote tmux sessions, differentiate observational vs managed, optionally adopt explicitly verified sessions.
- Exit: safely list and summarize an existing session, and operate a managed remote one.

**P4 — personality + voice**
- Markdown memory, contextual response, dedicated PTT via Tima bridge, pre-recorded audio triggers.
- Exit: Capri remembers user-edited project context and can accept voice instructions.

**P5 — Telegram remote**
- Bot, minimal Mini App, authenticated gateway, remote relay fallback.
- Exit: get status, send to controllable session, receive approval request, and reliably see offline/remote-only status when Mac sleeps.

**P6 — stabilization**
- Reconnect, sleep/wake, multi-monitor, reduced motion, dedupe, no secret leakage, app notarization if distributed, documented permissions and license audit.

## 12. High-risk checks

1. External active CLI TUI cannot always be managed through app-server/SDK. Support truthful capability levels.
2. Full-screen transparent WKWebView can cause performance and hit-test issues: validate a bounded overlay before investing in animation port.
3. Security: Telegram approval actions are time-bound and associated with a specific session/tool input; never cache permanent 'approve all'.
4. Source code licenses and anime character artwork/voice are separate. Capri fan-art assets are not included under source MIT license; public distribution requires asset rights or a separately licensed character pack.
5. Official provider authentication terms can change; local/open-source Codex usage vs commercial hosted deployment and Claude third-party distribution have distinct requirements.

## 13. Reference implementations
- Capri renderer and art pipeline: https://github.com/mochiiwuff/capri-desktop
- Mac notch / event UX: https://github.com/Louis-CFM/coucou
- Remote session operations: https://github.com/Ark0N/Codeman
- Alternative desktop behavior reference: https://github.com/TheAgencyMGE/capri-companion
- Codex app-server docs: https://learn.chatgpt.com/docs/app-server
- Claude Code hook docs: https://code.claude.com/docs/en/hooks
- Telegram Mini Apps: https://core.telegram.org/bots/webapps

## 14. First development ticket

**CAPRI-001: Native sprite proof of concept**

- Create a SwiftUI/AppKit macOS menu-bar app and a borderless, transparent, draggable floating panel.
- Host a tiny WKWebView rendering a single transparent Capri animated sprite with no Electron runtime.
- Add native hit-testing (background clicks pass through; sprite hitbox handles drag/click), simple cross-bridge `setState('idle'|'teleport')`, and `Hide for 1 hour` setting.
- Instrument CPU/memory/energy impact and test notch, external monitor, fullscreen and sleep/wake.
- Acceptance: character behaves correctly without stealing focus or blocking unrelated clicks; teleport and panel work after wake; technical unknowns recorded before extending the engine.
