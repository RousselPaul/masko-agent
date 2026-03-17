# Masko Code Linux Port — Design Spec

## Overview

Port [Masko Code](https://github.com/RousselPaul/masko-code) (a macOS SwiftUI animated mascot companion for Claude Code) to Linux. The port preserves all features: animated overlay mascot, permission management, session tracking, notifications, and a dashboard.

## Architecture

Split architecture: **C overlay renderer** + **Python backend** + **web dashboard**.

```
┌─────────────────────────────────┐
│  Claude Code (hooks → curl)     │
└────────────┬────────────────────┘
             │ HTTP POST :49152
┌────────────▼────────────────────┐
│  Python Backend (masko-backend) │
│  • HTTP server (aiohttp)        │
│  • Event processing & routing   │
│  • State machine engine         │
│  • Session/permission stores    │
│  • Serves web dashboard :49153  │
└──────┬──────────────┬───────────┘
  Unix │ socket    HTTP│ + WebSocket
┌──────▼──────┐  ┌────▼───────────┐
│ C Overlay   │  │ Web Dashboard  │
│ (masko-ovl) │  │ (browser)      │
└─────────────┘  └────────────────┘
```

**Why this split:** The backend processes ~1-10 events/minute from Claude Code — no performance sensitivity, so Python gives fast iteration and easy porting of the original Swift logic. The overlay must decode video and composite at 30fps on a transparent X11 surface — this is the only hot path and belongs in C.

**IPC:** Unix domain socket at `/tmp/masko-overlay.sock`. Line-delimited JSON in both directions. Backend→overlay: display commands. Overlay→backend: user interactions.

**Overlay lifecycle:** Backend spawns the overlay as a child process. Backend waits for `{"event": "ready"}` on the Unix socket before sending commands. If the overlay dies (detected via SIGCHLD + socket EOF), backend respawns it after a 1-second delay, up to 5 retries. If a permission prompt was active, backend auto-denies it on overlay death to unblock Claude Code. Any active session switcher is silently discarded.

## Component 1: C Overlay Renderer (`masko-overlay`)

### X11 Window

- On startup: check for Composite extension via `XCompositeQueryExtension`. If absent, print a clear error ("Masko overlay requires X11 Composite extension") and exit 1.
- `XCreateWindow` with 32-bit ARGB visual (Composite extension required)
- `override_redirect = True` — bypasses window manager, no decorations, no taskbar entry
- `_NET_WM_WINDOW_TYPE_DOCK` + `_NET_WM_STATE_ABOVE` for always-on-top stacking
- XShape extension for click-through on transparent regions (only opaque mascot area receives input)
- Draggable by clicking on the mascot body

### Render Loop

- Single-threaded event loop using `select()` on X11 connection fd + Unix socket fd
- When idle: no redraws, minimal CPU
- During animation transitions: decode video frames via libav, render at 30fps
- Double-buffered: draw to offscreen Cairo surface, `XCopyArea` to window

### Video Decoding

- FFmpeg libav (libavformat, libavcodec, libswscale) decodes HEVC/WebM video files
- Decoded frames → `cairo_image_surface_create_for_data` → composite onto window
- Videos are pre-cached locally by the Python backend

### Permission UI

- Rendered directly on the overlay surface via Cairo + Pango (no toolkit)
- Speech bubble with rounded rect background, tool name, permission details, action buttons
- Mouse hit-testing: track button bounding rects, compare against `ButtonPress` coordinates
- Buttons: Approve (green), Deny (red), Collapse/Defer
- Visual feedback on hover (PointerMotion) and press

### Session Switcher UI

- Rendered on the overlay surface (same Cairo + Pango approach as permission UI)
- Vertical list of active sessions: session name/cwd, model, status indicator
- Highlighted selection row, navigable via arrow keys or mouse
- Triggered by double-tap Super; dismissed by Escape or clicking outside
- On confirm: backend focuses the selected session's terminal via terminal_focus module

### Active Card Priority

The overlay can show multiple UI elements. Priority determines which "card" owns keyboard input (highest wins):
1. Session switcher (highest)
2. Permission prompt
3. Toast notification
4. None (mascot only)

Escape always dismisses the topmost card (no modifier required). When a card is dismissed, input falls through to the next card or to the mascot.

### Global Hotkeys

- `XGrabKey` for system-wide keyboard shortcuts
- Default modifier: Super (configurable in settings)
- Bindings:
  - Super+M: toggle overlay visibility
  - Super+Enter: approve permission / confirm session switcher selection
  - Super+Escape: deny permission (Escape alone also dismisses topmost card)
  - Super+L: collapse permission prompt
  - Super+1-9: select session
  - Double-tap Super: session switcher
  - Arrow Up/Down: navigate session switcher list
  - Tab/Shift+Tab: navigate session switcher list (alternative)

### IPC Protocol (overlay side)

Receives from backend (JSON per line):
- `{"cmd": "play", "video": "/path/to/video.webm", "loop": true}`
- `{"cmd": "frame", "node": "idle"}` — jump to static frame of a node
- `{"cmd": "permission", "tool": "Bash", "input": "rm -rf /", "id": "abc123"}`
- `{"cmd": "hide"}` / `{"cmd": "show"}`
- `{"cmd": "move", "x": 100, "y": 100}`
- `{"cmd": "resize", "w": 200, "h": 200}`
- `{"cmd": "toast", "text": "Session finished", "duration": 3000}`
- `{"cmd": "session_switcher", "sessions": [{"id": "abc", "cwd": "/project", "model": "opus", "phase": "working"}], "selected": 0}`
- `{"cmd": "session_switcher_nav", "direction": "next"}` / `"prev"` / `"confirm"` / `"dismiss"`

Sends to backend (JSON per line):
- `{"event": "ready"}` — overlay is initialized and accepting commands
- `{"event": "permission_response", "id": "abc123", "action": "approve"}`
- `{"event": "hotkey", "key": "toggle"}`
- `{"event": "hotkey", "key": "session_switcher"}`
- `{"event": "position", "x": 150, "y": 200}` — after drag
- `{"event": "error", "msg": "video decode failed: corrupted.webm"}`

### Dependencies

libX11, libXext (XShape), libXcomposite, libXfixes, libcairo, libpango, libavformat, libavcodec, libavutil, libswscale (FFmpeg >= 5.0, targeting the `avcodec_send_packet`/`avcodec_receive_frame` API)

## Component 2: Python Backend (`masko-backend`)

### Hook Integration

Ported from `HookInstaller.swift`. Installs:
- Bash hook script at `~/.masko-desktop/hooks/hook-sender.sh` (reads port from `~/.config/masko-desktop/config.json` at invocation time, so port changes take effect on next hook fire)
- Registers in `~/.claude/settings.json` for 17 event types: PreToolUse, PostToolUse, PostToolUseFailure, Stop, Notification, SessionStart, SessionEnd, TaskCompleted, PermissionRequest, UserPromptSubmit, SubagentStart, SubagentStop, PreCompact, ConfigChange, TeammateIdle, WorktreeCreate, WorktreeRemove

The hook script:
- Checks server health via `curl GET /health`
- Sends event via `curl POST /hook` with JSON body
- For PermissionRequest: blocks on curl with `--max-time 120` (2 minute timeout). On timeout, sends deny response back to Claude Code. Backend holds the TCP connection until the user responds via overlay or timeout fires.

### HTTP Server (aiohttp)

Port 49152 (Claude Code facing):
- `GET /health` — returns 200
- `POST /hook` — receives ClaudeEvent JSON, routes to event processor
- `POST /input` — custom state machine inputs

Port 49153 (dashboard):
- Serves static HTML/JS/CSS for web dashboard
- WebSocket endpoint `/ws` for live push updates

### Event Processor

Ported from `EventProcessor.swift`. Receives events, routes to stores:
- SessionStore: session lifecycle (start, end, model info, working directory)
- PendingPermissionStore: holds open HTTP connections for permission requests
- NotificationStore: generates app notifications from events
- EventStore: recent event log

Bridges events to state machine inputs:
- SessionStart → `claudeCode::isWorking = true`
- SessionEnd → `claudeCode::isIdle = true`
- PermissionRequest → `claudeCode::isAlert = true`
- PreCompact → `claudeCode::isCompacting = true`

### State Machine

Ported from `OverlayStateMachine.swift`. Loads mascot JSON configs defining:
- **Nodes**: named animation states (e.g., "Idle", "Working", "Alert")
- **Edges**: transitions between nodes with condition expressions and video URLs
- **Conditions**: identical semantics to the original `OverlayStateMachine.swift`. Expression language supports: `==`, `!=`, `>`, `<`, `>=`, `<=` operators over boolean and numeric inputs. Logical combinators: `and`, `or`, `not`. Inputs are namespaced strings (e.g., `claudeCode::isWorking`).

On input change: evaluates all outgoing edges from current node, fires first matching transition, tells overlay to play the transition video, then sets new current node.

### Stores

**SessionStore**: active sessions keyed by session_id. Fields: id, cwd, model, start_time, event_count, terminal_pid, shell_pid, phase (idle/working/permission_pending).

**PendingPermissionStore**: maps tool_use_id → held HTTP response object. When user responds via overlay, writes the response and closes the connection (unblocking the hook script).

**NotificationStore**: list of AppNotification objects with priority, category, read/unread state, timestamps.

**MascotStore**: loads bundled mascot configs from `resources/mascots/*.json`, supports fetching remote configs from masko.ai API. Persists user's selected mascot and saved collection.

**SessionSwitcherStore**: tracks the session switcher UI state — whether it's open, which session is selected, the session list snapshot. Populated by SessionStore data when the switcher is opened.

**SessionFinishedStore**: detects session completion events and triggers toast notifications via the overlay. Auto-dismiss after configurable duration (default 5 seconds).

### Video Cache

Downloads remote mascot videos to `~/.cache/masko-desktop/videos/`. Resolves video URLs: if cached locally, returns local path; otherwise fetches. Evicts files older than 30 days.

### Configuration

JSON config at `~/.config/masko-desktop/config.json`:
```json
{
  "selected_mascot": "masko",
  "overlay": {"x": 100, "y": 100, "width": 150, "height": 150},
  "hotkeys": {"modifier": "Super", "toggle": "m", "approve": "Return", "deny": "Escape"},
  "server": {"hook_port": 49152, "dashboard_port": 49153, "permission_timeout": 120},
  "notifications": {"system_notify": true}
}
```

## Component 3: Web Dashboard

Single-page app served by the Python backend. Vanilla JS + CSS, no framework.

### Pages

- **Sessions**: list of active/recent Claude Code sessions with status indicators, click to see detail (events, model, working directory)
- **Activity Feed**: chronological event stream across all sessions
- **Notifications**: notification list with unread badge, dismiss/clear actions
- **Settings**: mascot picker (visual grid of available mascots), hotkey configuration, overlay position/size, hook management

### Live Updates

WebSocket connection to backend pushes:
- New session events
- Permission requests (read-only mirror — permissions can only be responded to via the overlay or hotkeys, not the dashboard, to avoid race conditions)
- Notification updates
- Session state changes

## Component 4: Terminal Focus

- Primary: `xdotool windowactivate --sync <window_id>` using terminal PID → window ID mapping via `xdotool search --pid <pid>`
- VS Code, Cursor, VS Code Insiders, Windsurf, Antigravity: bundle and auto-install the `masko-terminal-focus.vsix` extension (already cross-platform). Backend checks installed extension version on startup and upgrades if bundled version is newer.
- Fallback: `wmctrl -ia <window_id>`

## Component 5: System Notifications

- `libnotify` via `notify-send` subprocess call for desktop notifications
- Triggered on: session complete, permission timeout, errors

## Packaging & Installation

### Install

```bash
git clone https://github.com/<user>/masko-linux
cd masko-linux
./install.sh  # builds C overlay, creates Python venv, installs hooks
```

### Runtime

- `masko-backend`: Python daemon, managed via systemd user service
- `masko-overlay`: C binary, launched by the backend on startup
- Dashboard: user opens `http://localhost:49153` in browser

### System Dependencies (apt)

```
libx11-dev libxext-dev libxcomposite-dev libxfixes-dev
libcairo2-dev libpango1.0-dev
libavformat-dev libavcodec-dev libavutil-dev libswscale-dev
python3 python3-venv
xdotool wmctrl
```

### File Layout

```
masko-linux/
├── overlay/              # C overlay renderer
│   ├── main.c            # entry point, event loop
│   ├── window.c/h        # X11 window setup, ARGB, always-on-top
│   ├── render.c/h        # Cairo drawing, double buffering
│   ├── video.c/h         # FFmpeg decode, frame extraction
│   ├── permission_ui.c/h # Permission prompt rendering, hit-testing
│   ├── session_switcher.c/h # Session switcher rendering, navigation
│   ├── card_stack.c/h    # Active card priority management
│   ├── hotkeys.c/h       # XGrabKey management
│   ├── ipc.c/h           # Unix socket client, JSON parse (cJSON)
│   ├── toast.c/h         # Toast notification rendering
│   └── Makefile
├── backend/              # Python backend
│   ├── server.py         # aiohttp HTTP server
│   ├── event_processor.py
│   ├── state_machine.py  # animation state machine engine
│   ├── stores/
│   │   ├── session.py
│   │   ├── permission.py
│   │   ├── notification.py
│   │   ├── event.py
│   │   └── mascot.py
│   ├── hook_installer.py
│   ├── video_cache.py
│   ├── config.py
│   ├── ipc.py            # Unix socket server
│   └── terminal_focus.py
├── dashboard/            # Web dashboard static files
│   ├── index.html
│   ├── app.js
│   └── style.css
├── resources/
│   ├── mascots/          # bundled mascot JSON configs
│   ├── hooks/            # hook-sender.sh template
│   └── extensions/       # VS Code extension .vsix
├── install.sh
├── masko.service         # systemd user service
└── masko-desktop.desktop # autostart entry
```

## Deliberate Simplifications

- **No onboarding wizard.** The install script handles hook installation, dependency checks, and initial config. First-run mascot selection happens via the web dashboard settings page.

## Non-Goals

- Wayland support (X11 only for now; Wayland's security model makes transparent overlays harder)
- macOS/Windows support (this is a Linux-specific port)
- Custom mascot creation UI (use masko.ai or edit JSON directly)
- Auto-updates (install from source, update via git pull)
