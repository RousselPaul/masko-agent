<p align="center">
  <img src="Sources/Resources/Images/app-icon.png" width="128" />
</p>

<h1 align="center">Masko Agent</h1>

<p align="center">
  A mascot on your screen that your AI agent installs, drives and changes for you.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-work%20in%20progress-f95d02?style=flat-square" alt="Work in progress" />
  <img src="https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" />
</p>

---

## Where this comes from

This repository started in March 2026 as **Masko Code**: a mascot that floats above your windows, reacts to Claude Code and Codex, and lets you approve permissions and answer questions without going back to the terminal. Thanks to everyone who contributed to it.

It is now becoming **Masko Agent**. The code you see today is still the March 2026 version (v0.13). The new version is being built here, in the open.

## What Masko Agent will do

- **Your agent installs it.** One command, run by Claude Code, Codex or Cursor. No window to set up.
- **It shows what your agent is doing.** Each kind of tool gets its own state: the mascot works on the database when the agent uses Supabase, handles money when it uses Stripe, ships when it pushes to GitHub.
- **Your agent can talk to you through it.** A small local MCP gives the agent `ask_user` and `tell_user`, so you can answer from the mascot when you are away from the terminal.
- **Your agent changes the mascot.** Ask it for a new character and it makes one with the [Masko MCP](https://masko.ai) and puts it on your screen.
- **It works with the agents you use.** Claude Code, Codex, Cursor, Hermes, OpenCode, and more over time.

Star or watch the repository to follow along.

## The March 2026 version (Masko Code)

The rest of this page describes the code as it is today. It calls Masko services as they were in March 2026, so some parts may no longer work.

### Features

| | Feature | Description |
|---|---|---|
| 🎭 | **Animated overlay** | A mascot that floats above all windows and reacts to Claude Code + Codex state: click or hover to interact |
| 🔐 | **Permission handling** | Approve, deny, or defer tool use requests from a speech bubble: select with `⌘1-9`, permissions stack in a queue |
| 💬 | **Question answering** | Answer Claude's questions directly from the overlay |
| 📋 | **Plan review** | Review and approve plans without opening your terminal |
| 📊 | **Session tracking** | Monitor active sessions, subagents, and status at a glance |
| 🔔 | **Notification dashboard** | Priority levels, resolution tracking, color-coded activity feed |
| 🖥️ | **Find the right terminal** | Jump to the correct terminal tab: supports 13 terminals and IDEs including iTerm2, Ghostty, VS Code, Cursor, and more |
| 🔀 | **Session switcher** | Double-tap `⌘` to switch between assistant sessions |
| 😴 | **Snooze** | Right-click to hide the mascot for 15 min, 1 hour, or indefinitely |
| ↔️ | **Resizable** | Drag to resize or pick a preset (S / M / L / XL) from the context menu |
| 🔄 | **Auto-updates** | Built-in Sparkle updates: always on the latest version |

### How It Works

```
┌─────────────┐     hook events     ┌─────────────┐
│ Claude/Codex │ ──────────────────▶ │    Masko     │
│  (terminal)  │                     │  (menu bar)  │
└─────────────┘                     └─────────────┘
        │                                   │
        │  streams events from hooks/logs,  │  updates mascot animation,
        │  sessions, notifications          │  shows permission prompts,
        │                                   │  tracks sessions
        ▼                                   ▼
   ~/.claude/settings.json          local HTTP :49152
```

1. **Download the app**: Install the DMG. Lives in your menu bar, no dock clutter.
2. **Grant accessibility**: First launch installs Claude Code hooks automatically into `~/.claude/settings.json`.
3. **Pick a mascot**: Choose the default Masko or bring your own from [masko.ai](https://masko.ai).
4. **Start coding**: Open Claude Code or Codex (CLI/Desktop). Your mascot springs to life.

### Keyboard Shortcuts

All shortcuts work globally: no need to focus the app.

| Shortcut | Action |
|---|---|
| `⌘M` | Toggle dashboard (customizable in Settings) |
| `⌘1-9` | Select Nth pending permission |
| `⌘Enter` | Approve selected permission |
| `⌘Esc` | Deny / dismiss permission |
| `⌘L` | Collapse / defer topmost permission |
| `Double-tap ⌘` | Open session switcher (2+ sessions) |
| `↑ / ↓` | Navigate session switcher |
| `Tab / Shift+Tab` | Cycle sessions |
| `Enter` | Confirm session selection |
| `Esc` | Close session switcher |

The focus toggle shortcut can be rebound to any key combination in Settings.

Right-click the mascot to open the **context menu**: snooze, resize, or close the overlay.

### Custom Mascots

The default Masko fox is included. Want your own character? Create one on [masko.ai](https://masko.ai) with AI-generated animations for every state (idle, working, attention). Export and load it into the desktop app in one click.

### Supported Terminals & IDEs

Masko works with terminals that run Claude Code or Codex. Terminal focus (`⌘M`) support varies by app:

| Level | App | How |
|---|---|---|
| **Exact tab** | VS Code, VS Code Insiders, Cursor, Windsurf, Antigravity | IDE extension (auto-installed) |
| **Exact tab** | iTerm2, Terminal.app | AppleScript TTY matching |
| **App focus** | Ghostty, Kitty, WezTerm, Alacritty, Warp, Zed | Process activation |

Click a session in the dashboard or click the mascot overlay to jump to the right terminal.

### Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon or Intel Mac
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and/or [Codex CLI](https://github.com/openai/codex) installed

### Install

Download the latest `.dmg` from [**Releases**](https://github.com/RousselPaul/masko-agent/releases/latest).

### Build from Source

```bash
git clone https://github.com/RousselPaul/masko-agent.git
cd masko-agent
swift build
swift run
```

### Local Codex Smoke Test

Boot Masko from source in one terminal:

```bash
swift run masko-code
```

Run a live Codex mascot flow in another terminal:

```bash
scripts/codex-mascot-smoke.sh --manual
```

Run the automated 3-step integration check instead:

```bash
scripts/codex-mascot-smoke.sh --auto
```

The automated mode verifies that Masko ingests:
- a Codex question turn as `AskUserQuestion`
- an escalated approval turn with a persistent `prefix_rule` suggestion
- the final completion marker without blank notifications or question-only completion events

The automated mode drives Codex through its own PTY and verifies Masko ingestion. Use `--manual` if you want to inspect the overlay yourself while the prompts are live.

### Project Structure

```
Sources/
├── App/             # App entry point & lifecycle
├── Models/          # Data models (sessions, events, hooks)
├── Services/        # HTTP server, hook installer, update checker
├── Stores/          # Observable state (sessions, notifications)
├── Views/           # SwiftUI views (overlay, permission prompt, dashboard)
├── Utilities/       # Helpers
└── Resources/       # Assets, images, app icon
scripts/             # DMG packaging scripts
extensions/
├── vscode/          # VS Code/Cursor click-to-focus extension
└── jetbrains/       # JetBrains (PyCharm, IntelliJ, etc.) terminal focus plugin
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). New integrations with coding agents are especially welcome.

## License

[MIT License](LICENSE). Copyright (c) 2026 Masko.

---

> **Note:** This project has no cryptocurrency or token associated with it. Any coin using the Masko or Clippy name is not affiliated with us.
