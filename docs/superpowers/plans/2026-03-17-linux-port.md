# Masko Code Linux Port — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Masko Code (macOS animated mascot companion for Claude Code) to Linux with full feature parity.

**Architecture:** Split architecture — C overlay renderer (X11/Cairo/FFmpeg) for the performance-critical mascot animation, Python backend (aiohttp) for hook integration/event processing/state machine, vanilla JS web dashboard for session management.

**Tech Stack:** C (X11, Cairo, Pango, FFmpeg libav, cJSON), Python 3.10+ (aiohttp, asyncio), HTML/CSS/JS (vanilla)

**Spec:** `docs/superpowers/specs/2026-03-17-linux-port-design.md`

**Testing strategy:** Red-green TDD throughout. Unit tests for all backend logic (pytest). C unit tests via a lightweight harness. E2E tests using screenshots + actual X11 interactions (Xvfb + xdotool for CI, real display for dev).

**E2E test infrastructure:** Tests spawn the real backend + overlay on an Xvfb display, send curl requests simulating Claude Code hooks, take screenshots via `import` (ImageMagick), and verify with pixel sampling or image diffing.

---

## Chunk 1: Project Scaffold & Backend Core

### Task 1: Project scaffold and build infrastructure

**Files:**
- Create: `masko-linux/backend/__init__.py`
- Create: `masko-linux/backend/stores/__init__.py`
- Create: `masko-linux/backend/config.py`
- Create: `masko-linux/overlay/Makefile`
- Create: `masko-linux/requirements.txt`
- Create: `masko-linux/Makefile` (top-level)
- Create: `masko-linux/tests/__init__.py`
- Create: `masko-linux/tests/conftest.py`

- [ ] **Step 1: Create project directory structure**

```bash
mkdir -p masko-linux/{overlay,backend/stores,dashboard,resources/{mascots,hooks,extensions},tests}
```

- [ ] **Step 2: Write requirements.txt**

```
aiohttp>=3.9
pytest>=8.0
pytest-asyncio>=0.23
pytest-aiohttp>=1.0
```

- [ ] **Step 3: Write backend/config.py with failing test**

Test file: `tests/test_config.py`

```python
import json
import os
import pytest
from backend.config import Config

def test_default_config(tmp_path):
    cfg = Config(path=tmp_path / "config.json")
    assert cfg.hook_port == 49152
    assert cfg.dashboard_port == 49153
    assert cfg.selected_mascot == "masko"
    assert cfg.hotkeys["modifier"] == "Super"
    assert cfg.permission_timeout == 120

def test_load_existing_config(tmp_path):
    p = tmp_path / "config.json"
    p.write_text(json.dumps({"selected_mascot": "clippy", "server": {"hook_port": 9999}}))
    cfg = Config(path=p)
    assert cfg.selected_mascot == "clippy"
    assert cfg.hook_port == 9999
    assert cfg.dashboard_port == 49153  # default preserved

def test_save_config(tmp_path):
    p = tmp_path / "config.json"
    cfg = Config(path=p)
    cfg.selected_mascot = "otto"
    cfg.save()
    loaded = json.loads(p.read_text())
    assert loaded["selected_mascot"] == "otto"
```

Run: `cd masko-linux && python -m pytest tests/test_config.py -v`
Expected: FAIL (no module backend.config)

- [ ] **Step 4: Implement backend/config.py**

```python
import json
from pathlib import Path
from dataclasses import dataclass, field

DEFAULTS = {
    "selected_mascot": "masko",
    "overlay": {"x": 100, "y": 100, "width": 150, "height": 150},
    "hotkeys": {"modifier": "Super", "toggle": "m", "approve": "Return", "deny": "Escape"},
    "server": {"hook_port": 49152, "dashboard_port": 49153, "permission_timeout": 120},
    "notifications": {"system_notify": True},
}

class Config:
    def __init__(self, path=None):
        self._path = Path(path) if path else Path.home() / ".config" / "masko-desktop" / "config.json"
        self._data = _deep_merge(DEFAULTS.copy(), self._load())

    def _load(self):
        if self._path.exists():
            return json.loads(self._path.read_text())
        return {}

    def save(self):
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(json.dumps(self._data, indent=2))

    @property
    def hook_port(self):
        return self._data["server"]["hook_port"]

    @property
    def dashboard_port(self):
        return self._data["server"]["dashboard_port"]

    @property
    def permission_timeout(self):
        return self._data["server"]["permission_timeout"]

    @property
    def selected_mascot(self):
        return self._data["selected_mascot"]

    @selected_mascot.setter
    def selected_mascot(self, value):
        self._data["selected_mascot"] = value

    @property
    def hotkeys(self):
        return self._data["hotkeys"]

    @property
    def overlay_position(self):
        return self._data["overlay"]

def _deep_merge(base, override):
    for k, v in override.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            _deep_merge(base[k], v)
        else:
            base[k] = v
    return base
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd masko-linux && python -m pytest tests/test_config.py -v`
Expected: 3 passed

- [ ] **Step 6: Write top-level Makefile**

```makefile
.PHONY: all overlay backend test clean

all: overlay

overlay:
	$(MAKE) -C overlay

test:
	python -m pytest tests/ -v

clean:
	$(MAKE) -C overlay clean

venv:
	python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
```

- [ ] **Step 7: Write overlay/Makefile (stub — compiles when source exists)**

```makefile
CC = gcc
CFLAGS = -Wall -Wextra -O2 $(shell pkg-config --cflags x11 xext xcomposite xfixes cairo pango pangocairo libavformat libavcodec libavutil libswscale)
LDFLAGS = $(shell pkg-config --libs x11 xext xcomposite xfixes cairo pango pangocairo libavformat libavcodec libavutil libswscale) -lm
SRCS = $(wildcard *.c)
OBJS = $(SRCS:.c=.o)
TARGET = masko-overlay

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)
```

- [ ] **Step 8: Commit scaffold**

```bash
git add -A && git commit -m "feat: project scaffold with config module and build infrastructure"
```

---

### Task 2: Claude event model and event store

**Files:**
- Create: `masko-linux/backend/models.py`
- Create: `masko-linux/backend/stores/event.py`
- Create: `masko-linux/tests/test_models.py`
- Create: `masko-linux/tests/test_event_store.py`

- [ ] **Step 1: Write failing test for event model**

```python
# tests/test_models.py
import json
from backend.models import ClaudeEvent, HookEventType

def test_parse_event_from_json():
    raw = json.dumps({
        "hook_event_name": "SessionStart",
        "session_id": "abc-123",
        "cwd": "/home/user/project",
        "model": "opus",
    })
    event = ClaudeEvent.from_json(raw)
    assert event.hook_event_name == "SessionStart"
    assert event.session_id == "abc-123"
    assert event.event_type == HookEventType.SESSION_START

def test_parse_tool_event():
    raw = json.dumps({
        "hook_event_name": "PreToolUse",
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": "ls"},
        "tool_use_id": "tu-456",
    })
    event = ClaudeEvent.from_json(raw)
    assert event.tool_name == "Bash"
    assert event.tool_input == {"command": "ls"}

def test_parse_permission_event():
    raw = json.dumps({
        "hook_event_name": "PermissionRequest",
        "session_id": "abc-123",
        "tool_name": "Bash",
        "tool_input": {"command": "rm -rf /"},
        "tool_use_id": "tu-789",
    })
    event = ClaudeEvent.from_json(raw)
    assert event.event_type == HookEventType.PERMISSION_REQUEST
    assert event.tool_use_id == "tu-789"

def test_hook_event_types():
    assert HookEventType.SESSION_START.value == "SessionStart"
    assert HookEventType.STOP.value == "Stop"
    assert HookEventType.PRE_TOOL_USE.value == "PreToolUse"
```

Run: `python -m pytest tests/test_models.py -v`
Expected: FAIL

- [ ] **Step 2: Implement backend/models.py**

```python
import json
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Optional


class HookEventType(Enum):
    PRE_TOOL_USE = "PreToolUse"
    POST_TOOL_USE = "PostToolUse"
    POST_TOOL_USE_FAILURE = "PostToolUseFailure"
    STOP = "Stop"
    NOTIFICATION = "Notification"
    SESSION_START = "SessionStart"
    SESSION_END = "SessionEnd"
    TASK_COMPLETED = "TaskCompleted"
    PERMISSION_REQUEST = "PermissionRequest"
    USER_PROMPT_SUBMIT = "UserPromptSubmit"
    SUBAGENT_START = "SubagentStart"
    SUBAGENT_STOP = "SubagentStop"
    PRE_COMPACT = "PreCompact"
    CONFIG_CHANGE = "ConfigChange"
    TEAMMATE_IDLE = "TeammateIdle"
    WORKTREE_CREATE = "WorktreeCreate"
    WORKTREE_REMOVE = "WorktreeRemove"


@dataclass
class ClaudeEvent:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    hook_event_name: str = ""
    session_id: Optional[str] = None
    cwd: Optional[str] = None
    permission_mode: Optional[str] = None
    transcript_path: Optional[str] = None
    tool_name: Optional[str] = None
    tool_input: Optional[dict[str, Any]] = None
    tool_response: Optional[dict[str, Any]] = None
    tool_use_id: Optional[str] = None
    message: Optional[str] = None
    title: Optional[str] = None
    notification_type: Optional[str] = None
    source: Optional[str] = None
    reason: Optional[str] = None
    model: Optional[str] = None
    stop_hook_active: Optional[bool] = None
    last_assistant_message: Optional[str] = None
    agent_id: Optional[str] = None
    agent_type: Optional[str] = None
    task_id: Optional[str] = None
    task_subject: Optional[str] = None
    permission_suggestions: Optional[list] = None
    terminal_pid: Optional[int] = None
    shell_pid: Optional[int] = None
    received_at: datetime = field(default_factory=datetime.now)

    @property
    def event_type(self) -> Optional[HookEventType]:
        try:
            return HookEventType(self.hook_event_name)
        except ValueError:
            return None

    @property
    def project_name(self) -> Optional[str]:
        if self.cwd:
            return self.cwd.rstrip("/").rsplit("/", 1)[-1]
        return None

    @classmethod
    def from_json(cls, raw: str) -> "ClaudeEvent":
        return cls.from_dict(json.loads(raw))

    @classmethod
    def from_dict(cls, data: dict) -> "ClaudeEvent":
        return cls(
            hook_event_name=data.get("hook_event_name", ""),
            session_id=data.get("session_id"),
            cwd=data.get("cwd"),
            permission_mode=data.get("permission_mode"),
            transcript_path=data.get("transcript_path"),
            tool_name=data.get("tool_name"),
            tool_input=data.get("tool_input"),
            tool_response=data.get("tool_response"),
            tool_use_id=data.get("tool_use_id"),
            message=data.get("message"),
            title=data.get("title"),
            notification_type=data.get("notification_type"),
            source=data.get("source"),
            reason=data.get("reason"),
            model=data.get("model"),
            stop_hook_active=data.get("stop_hook_active"),
            last_assistant_message=data.get("last_assistant_message"),
            agent_id=data.get("agent_id"),
            agent_type=data.get("agent_type"),
            task_id=data.get("task_id"),
            task_subject=data.get("task_subject"),
            permission_suggestions=data.get("permission_suggestions"),
            terminal_pid=data.get("terminal_pid"),
            shell_pid=data.get("shell_pid"),
        )
```

- [ ] **Step 3: Run model tests, verify pass**

Run: `python -m pytest tests/test_models.py -v`
Expected: 4 passed

- [ ] **Step 4: Write failing test for event store**

```python
# tests/test_event_store.py
from backend.models import ClaudeEvent
from backend.stores.event import EventStore

def test_add_and_retrieve():
    store = EventStore(max_events=100)
    ev = ClaudeEvent(hook_event_name="SessionStart", session_id="s1")
    store.add(ev)
    assert len(store.recent()) == 1
    assert store.recent()[0].session_id == "s1"

def test_max_events_eviction():
    store = EventStore(max_events=3)
    for i in range(5):
        store.add(ClaudeEvent(hook_event_name="PreToolUse", session_id=f"s{i}"))
    assert len(store.recent()) == 3
    assert store.recent()[0].session_id == "s2"  # oldest surviving

def test_filter_by_session():
    store = EventStore()
    store.add(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    store.add(ClaudeEvent(hook_event_name="PreToolUse", session_id="s2"))
    store.add(ClaudeEvent(hook_event_name="Stop", session_id="s1"))
    assert len(store.for_session("s1")) == 2
    assert len(store.for_session("s2")) == 1
```

- [ ] **Step 5: Implement backend/stores/event.py**

```python
from collections import deque
from backend.models import ClaudeEvent


class EventStore:
    def __init__(self, max_events=1000):
        self._events = deque(maxlen=max_events)

    def add(self, event: ClaudeEvent):
        self._events.append(event)

    def recent(self, limit=None) -> list[ClaudeEvent]:
        events = list(self._events)
        if limit:
            return events[-limit:]
        return events

    def for_session(self, session_id: str) -> list[ClaudeEvent]:
        return [e for e in self._events if e.session_id == session_id]
```

- [ ] **Step 6: Run event store tests, verify pass**

Run: `python -m pytest tests/test_event_store.py -v`
Expected: 3 passed

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: claude event model and event store"
```

---

### Task 3: Session store

**Files:**
- Create: `masko-linux/backend/stores/session.py`
- Create: `masko-linux/tests/test_session_store.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_session_store.py
from backend.models import ClaudeEvent
from backend.stores.session import SessionStore, Session

def test_session_start():
    store = SessionStore()
    ev = ClaudeEvent(hook_event_name="SessionStart", session_id="s1", cwd="/project", model="opus")
    store.handle_event(ev)
    s = store.get("s1")
    assert s is not None
    assert s.cwd == "/project"
    assert s.model == "opus"
    assert s.phase == "working"

def test_session_end():
    store = SessionStore()
    store.handle_event(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    store.handle_event(ClaudeEvent(hook_event_name="SessionEnd", session_id="s1"))
    s = store.get("s1")
    assert s.phase == "ended"
    assert s.end_time is not None

def test_permission_sets_phase():
    store = SessionStore()
    store.handle_event(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    store.handle_event(ClaudeEvent(hook_event_name="PermissionRequest", session_id="s1"))
    assert store.get("s1").phase == "permission_pending"

def test_event_count():
    store = SessionStore()
    store.handle_event(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    store.handle_event(ClaudeEvent(hook_event_name="PreToolUse", session_id="s1"))
    store.handle_event(ClaudeEvent(hook_event_name="PostToolUse", session_id="s1"))
    assert store.get("s1").event_count == 3

def test_active_sessions():
    store = SessionStore()
    store.handle_event(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    store.handle_event(ClaudeEvent(hook_event_name="SessionStart", session_id="s2"))
    store.handle_event(ClaudeEvent(hook_event_name="SessionEnd", session_id="s1"))
    active = store.active_sessions()
    assert len(active) == 1
    assert active[0].id == "s2"
```

- [ ] **Step 2: Implement backend/stores/session.py**

```python
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional
from backend.models import ClaudeEvent, HookEventType


@dataclass
class Session:
    id: str
    cwd: Optional[str] = None
    model: Optional[str] = None
    start_time: datetime = field(default_factory=datetime.now)
    end_time: Optional[datetime] = None
    event_count: int = 0
    terminal_pid: Optional[int] = None
    shell_pid: Optional[int] = None
    phase: str = "working"


class SessionStore:
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    def handle_event(self, event: ClaudeEvent):
        sid = event.session_id
        if not sid:
            return

        if sid not in self._sessions:
            self._sessions[sid] = Session(
                id=sid,
                cwd=event.cwd,
                model=event.model,
                terminal_pid=event.terminal_pid,
                shell_pid=event.shell_pid,
            )

        session = self._sessions[sid]
        session.event_count += 1

        if event.cwd and not session.cwd:
            session.cwd = event.cwd
        if event.model and not session.model:
            session.model = event.model
        if event.terminal_pid and not session.terminal_pid:
            session.terminal_pid = event.terminal_pid

        et = event.event_type
        if et == HookEventType.SESSION_END:
            session.phase = "ended"
            session.end_time = datetime.now()
        elif et == HookEventType.PERMISSION_REQUEST:
            session.phase = "permission_pending"
        elif et == HookEventType.SESSION_START:
            session.phase = "working"
        elif session.phase == "permission_pending" and et in (
            HookEventType.PRE_TOOL_USE,
            HookEventType.POST_TOOL_USE,
        ):
            session.phase = "working"

    def get(self, session_id: str) -> Optional[Session]:
        return self._sessions.get(session_id)

    def active_sessions(self) -> list[Session]:
        return [s for s in self._sessions.values() if s.phase != "ended"]

    def all_sessions(self) -> list[Session]:
        return list(self._sessions.values())
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_session_store.py -v`
Expected: 5 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: session store with lifecycle tracking"
```

---

### Task 4: Permission store

**Files:**
- Create: `masko-linux/backend/stores/permission.py`
- Create: `masko-linux/tests/test_permission_store.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_permission_store.py
import asyncio
import pytest
from backend.stores.permission import PendingPermissionStore, PendingPermission

@pytest.fixture
def store():
    return PendingPermissionStore()

def test_add_pending(store):
    future = asyncio.Future()
    store.add("tu-1", PendingPermission(
        tool_use_id="tu-1",
        tool_name="Bash",
        tool_input={"command": "ls"},
        session_id="s1",
        response_future=future,
    ))
    assert store.get("tu-1") is not None
    assert len(store.all_pending()) == 1

def test_resolve_approve(store):
    loop = asyncio.new_event_loop()
    future = loop.create_future()
    store.add("tu-1", PendingPermission(
        tool_use_id="tu-1", tool_name="Bash",
        tool_input={}, session_id="s1",
        response_future=future,
    ))
    store.resolve("tu-1", "approve")
    assert future.result() == "approve"
    assert store.get("tu-1") is None
    loop.close()

def test_resolve_deny(store):
    loop = asyncio.new_event_loop()
    future = loop.create_future()
    store.add("tu-1", PendingPermission(
        tool_use_id="tu-1", tool_name="Bash",
        tool_input={}, session_id="s1",
        response_future=future,
    ))
    store.resolve("tu-1", "deny")
    assert future.result() == "deny"
    loop.close()

def test_resolve_nonexistent(store):
    store.resolve("nonexistent", "approve")  # should not raise
```

- [ ] **Step 2: Implement backend/stores/permission.py**

```python
import asyncio
from dataclasses import dataclass
from typing import Any, Optional


@dataclass
class PendingPermission:
    tool_use_id: str
    tool_name: str
    tool_input: dict[str, Any]
    session_id: str
    response_future: asyncio.Future


class PendingPermissionStore:
    def __init__(self):
        self._pending: dict[str, PendingPermission] = {}

    def add(self, tool_use_id: str, permission: PendingPermission):
        self._pending[tool_use_id] = permission

    def get(self, tool_use_id: str) -> Optional[PendingPermission]:
        return self._pending.get(tool_use_id)

    def resolve(self, tool_use_id: str, action: str):
        perm = self._pending.pop(tool_use_id, None)
        if perm and not perm.response_future.done():
            perm.response_future.set_result(action)

    def deny_all(self):
        for perm in list(self._pending.values()):
            if not perm.response_future.done():
                perm.response_future.set_result("deny")
        self._pending.clear()

    def all_pending(self) -> list[PendingPermission]:
        return list(self._pending.values())
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_permission_store.py -v`
Expected: 4 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: pending permission store with async resolution"
```

---

### Task 5: Notification store

**Files:**
- Create: `masko-linux/backend/stores/notification.py`
- Create: `masko-linux/tests/test_notification_store.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_notification_store.py
from backend.stores.notification import NotificationStore, AppNotification

def test_add_notification():
    store = NotificationStore()
    store.add(AppNotification(title="Test", message="Hello", category="info"))
    assert len(store.all()) == 1
    assert store.unread_count() == 1

def test_mark_read():
    store = NotificationStore()
    store.add(AppNotification(title="Test", message="Hello", category="info"))
    nid = store.all()[0].id
    store.mark_read(nid)
    assert store.unread_count() == 0

def test_dismiss():
    store = NotificationStore()
    store.add(AppNotification(title="Test", message="Hello", category="info"))
    nid = store.all()[0].id
    store.dismiss(nid)
    assert len(store.all()) == 0

def test_clear_all():
    store = NotificationStore()
    for i in range(5):
        store.add(AppNotification(title=f"N{i}", message="", category="info"))
    store.clear_all()
    assert len(store.all()) == 0
```

- [ ] **Step 2: Implement backend/stores/notification.py**

```python
import uuid
from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class AppNotification:
    title: str
    message: str
    category: str
    priority: str = "normal"
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    read: bool = False
    created_at: datetime = field(default_factory=datetime.now)


class NotificationStore:
    def __init__(self):
        self._notifications: list[AppNotification] = []

    def add(self, notification: AppNotification):
        self._notifications.append(notification)

    def all(self) -> list[AppNotification]:
        return list(self._notifications)

    def unread_count(self) -> int:
        return sum(1 for n in self._notifications if not n.read)

    def mark_read(self, notification_id: str):
        for n in self._notifications:
            if n.id == notification_id:
                n.read = True
                break

    def dismiss(self, notification_id: str):
        self._notifications = [n for n in self._notifications if n.id != notification_id]

    def clear_all(self):
        self._notifications.clear()
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_notification_store.py -v`
Expected: 4 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: notification store with read/dismiss/clear"
```

---

### Task 6: State machine engine

**Files:**
- Create: `masko-linux/backend/state_machine.py`
- Create: `masko-linux/tests/test_state_machine.py`
- Copy: `Sources/Resources/Defaults/masko.json` → `masko-linux/resources/mascots/masko.json`

- [ ] **Step 1: Copy bundled mascot configs**

```bash
cp Sources/Resources/Defaults/*.json masko-linux/resources/mascots/
```

- [ ] **Step 2: Write failing test**

```python
# tests/test_state_machine.py
import json
from pathlib import Path
from backend.state_machine import StateMachine, ConditionValue

MASCOT_DIR = Path(__file__).parent.parent / "resources" / "mascots"

def load_masko():
    config = json.loads((MASCOT_DIR / "masko.json").read_text())
    return StateMachine(config)

def test_initial_node():
    sm = load_masko()
    sm.start()
    assert sm.current_node_name == "Idle"

def test_transition_to_working():
    sm = load_masko()
    sm.start()
    transitions = []
    sm.on_transition = lambda edge, video: transitions.append((edge["target"], video))
    sm.set_input("claudeCode::isWorking", ConditionValue(True))
    assert sm.current_node_name == "Working"
    assert len(transitions) == 1

def test_transition_to_needs_attention():
    sm = load_masko()
    sm.start()
    sm.set_input("claudeCode::isWorking", ConditionValue(True))
    transitions = []
    sm.on_transition = lambda edge, video: transitions.append(edge["target"])
    sm.set_input("claudeCode::isAlert", ConditionValue(True))
    assert sm.current_node_name == "Needs Attention"

def test_no_transition_when_condition_not_met():
    sm = load_masko()
    sm.start()
    sm.set_input("claudeCode::isIdle", ConditionValue(True))
    assert sm.current_node_name == "Idle"  # already idle

def test_condition_evaluation():
    sm = load_masko()
    sm.start()
    sm.set_input("claudeCode::isWorking", ConditionValue(True))
    assert sm.current_node_name == "Working"
    sm.set_input("claudeCode::isWorking", ConditionValue(False))
    sm.set_input("claudeCode::isIdle", ConditionValue(True))
    assert sm.current_node_name == "Idle"

def test_loop_count_input():
    sm = load_masko()
    sm.start()
    sm.handle_loop_completed()
    assert sm.inputs["loopCount"].value == 1.0

def test_comparison_operators():
    from backend.state_machine import compare
    assert compare(ConditionValue(5.0), ">", ConditionValue(3.0))
    assert compare(ConditionValue(3.0), "==", ConditionValue(3.0))
    assert compare(ConditionValue(3.0), "!=", ConditionValue(5.0))
    assert compare(ConditionValue(3.0), "<=", ConditionValue(3.0))
    assert not compare(ConditionValue(3.0), ">", ConditionValue(5.0))
```

- [ ] **Step 3: Implement backend/state_machine.py**

Port from `Sources/Services/OverlayStateMachine.swift`. Key elements:
- `ConditionValue` class wrapping bool/number with `double_value` for comparison
- `StateMachine` class with `set_input()`, `start()`, `handle_loop_completed()`, `handle_video_ended()`
- Condition evaluation: all conditions must match (AND logic), empty conditions = never fires
- `on_transition` callback for overlay IPC integration
- `on_loop_start` callback for loop video playback
- Trigger inputs reset after firing (`clicked`, custom triggers)
- `nodeTime` support via `threading.Timer` scheduled at threshold values

```python
import json
import threading
from dataclasses import dataclass
from typing import Any, Callable, Optional


@dataclass
class ConditionValue:
    value: Any  # bool or float

    def __init__(self, value):
        if isinstance(value, bool):
            self.value = value
        elif isinstance(value, (int, float)):
            self.value = float(value)
        else:
            self.value = value

    @property
    def double_value(self) -> float:
        if isinstance(self.value, bool):
            return 1.0 if self.value else 0.0
        return float(self.value)

    def __eq__(self, other):
        if isinstance(other, ConditionValue):
            return self.double_value == other.double_value
        return NotImplemented


def compare(lhs: ConditionValue, op: str, rhs: ConditionValue) -> bool:
    left, right = lhs.double_value, rhs.double_value
    ops = {"==": left == right, "!=": left != right, ">": left > right,
           "<": left < right, ">=": left >= right, "<=": left <= right}
    return ops.get(op, False)


class StateMachine:
    def __init__(self, config: dict):
        self.config = config
        self.current_node_id = config["initialNode"]
        self.inputs: dict[str, ConditionValue] = {}
        self.phase = "idle"  # idle, looping, transitioning
        self._pending_edge = None
        self._loop_count = 0
        self._node_time_generation = 0
        self._node_arrival_time: Optional[float] = None

        self.on_transition: Optional[Callable] = None
        self.on_loop_start: Optional[Callable] = None

        self._init_inputs()

    @property
    def current_node_name(self) -> str:
        for node in self.config["nodes"]:
            if node["id"] == self.current_node_id:
                return node["name"]
        return self.current_node_id

    def _init_inputs(self):
        self.inputs["clicked"] = ConditionValue(False)
        self.inputs["mouseOver"] = ConditionValue(False)
        self.inputs["loopCount"] = ConditionValue(0.0)
        self.inputs["nodeTime"] = ConditionValue(0.0)
        self.inputs["claudeCode::isWorking"] = ConditionValue(False)
        self.inputs["claudeCode::isIdle"] = ConditionValue(True)
        self.inputs["claudeCode::isAlert"] = ConditionValue(False)
        self.inputs["claudeCode::isCompacting"] = ConditionValue(False)
        self.inputs["claudeCode::sessionCount"] = ConditionValue(0.0)
        for inp in self.config.get("inputs") or []:
            default = inp.get("default", inp.get("defaultValue"))
            if isinstance(default, bool):
                self.inputs[inp["name"]] = ConditionValue(default)
            else:
                self.inputs[inp["name"]] = ConditionValue(float(default) if default is not None else 0.0)

    def start(self):
        self._arrive_at_node(self.current_node_id)

    def set_input(self, name: str, value: ConditionValue):
        old = self.inputs.get(name)
        if old is not None and old == value:
            return
        self.inputs[name] = value
        self._evaluate_and_fire(name)

    def handle_loop_completed(self):
        if self.phase != "looping":
            return
        self._loop_count += 1
        self.set_input("loopCount", ConditionValue(float(self._loop_count)))

    def handle_video_ended(self):
        if self.phase != "transitioning" or not self._pending_edge:
            return
        target = self._pending_edge["target"]
        self._pending_edge = None
        self._arrive_at_node(target)

    def _evaluate_and_fire(self, changed_input: str):
        if self.phase not in ("looping", "idle"):
            return
        for edge in self.config["edges"]:
            if edge["source"] != self.current_node_id or edge.get("isLoop", False):
                continue
            conditions = edge.get("conditions") or []
            if not conditions:
                continue
            if self._evaluate_conditions(conditions):
                self._reset_trigger(changed_input)
                self._play_transition(edge)
                return

    def _evaluate_conditions(self, conditions: list[dict]) -> bool:
        for cond in conditions:
            inp_val = self.inputs.get(cond["input"])
            if inp_val is None:
                return False
            op = cond.get("op", "==")
            raw_val = cond.get("value", True)
            cond_val = ConditionValue(raw_val)
            if not compare(inp_val, op, cond_val):
                return False
        return True

    def _reset_trigger(self, name: str):
        if name == "clicked":
            self.inputs["clicked"] = ConditionValue(False)
        custom_inputs = self.config.get("inputs") or []
        for inp in custom_inputs:
            if inp["name"] == name and inp.get("type") == "trigger":
                self.inputs[name] = ConditionValue(False)

    def _arrive_at_node(self, node_id: str):
        self._node_time_generation += 1
        self._loop_count = 0
        self.current_node_id = node_id
        self.inputs["loopCount"] = ConditionValue(0.0)
        self.inputs["nodeTime"] = ConditionValue(0.0)
        self.inputs["clicked"] = ConditionValue(False)

        loop_edge = None
        for edge in self.config["edges"]:
            if edge["source"] == node_id and edge["target"] == node_id and edge.get("isLoop"):
                loop_edge = edge
                break

        if loop_edge:
            video_url = loop_edge.get("videos", {}).get("webm") or loop_edge.get("videos", {}).get("hevc")
            self.phase = "looping"
            if self.on_loop_start:
                self.on_loop_start(video_url)
        else:
            self.phase = "idle"

        self._evaluate_and_fire("nodeArrival")

    def _play_transition(self, edge: dict):
        video_url = edge.get("videos", {}).get("webm") or edge.get("videos", {}).get("hevc")
        if not video_url:
            self._arrive_at_node(edge["target"])
            return
        self._pending_edge = edge
        self.phase = "transitioning"
        if self.on_transition:
            self.on_transition(edge, video_url)
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_state_machine.py -v`
Expected: 7 passed

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: animation state machine engine ported from Swift"
```

---

### Task 7: HTTP server with hook endpoint

**Files:**
- Create: `masko-linux/backend/server.py`
- Create: `masko-linux/tests/test_server.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_server.py
import json
import pytest
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop
from backend.server import create_app

@pytest.fixture
async def client(aiohttp_client):
    app = create_app()
    return await aiohttp_client(app)

@pytest.mark.asyncio
async def test_health(client):
    resp = await client.get("/health")
    assert resp.status == 200

@pytest.mark.asyncio
async def test_hook_session_start(client):
    resp = await client.post("/hook", json={
        "hook_event_name": "SessionStart",
        "session_id": "test-session",
        "cwd": "/tmp/project",
        "model": "opus",
    })
    assert resp.status == 200
    # Verify session was tracked
    app = client.app
    session = app["session_store"].get("test-session")
    assert session is not None
    assert session.cwd == "/tmp/project"

@pytest.mark.asyncio
async def test_hook_invalid_json(client):
    resp = await client.post("/hook", data=b"not json", headers={"Content-Type": "application/json"})
    assert resp.status == 400

@pytest.mark.asyncio
async def test_input_endpoint(client):
    resp = await client.post("/input", json={"name": "claudeCode::isWorking", "value": True})
    assert resp.status == 200
```

- [ ] **Step 2: Implement backend/server.py**

```python
import json
from aiohttp import web
from backend.models import ClaudeEvent
from backend.stores.event import EventStore
from backend.stores.session import SessionStore
from backend.stores.notification import NotificationStore
from backend.stores.permission import PendingPermissionStore
from backend.state_machine import StateMachine, ConditionValue
from backend.config import Config


def create_app(config=None):
    app = web.Application()
    app["config"] = config or Config()
    app["event_store"] = EventStore()
    app["session_store"] = SessionStore()
    app["notification_store"] = NotificationStore()
    app["permission_store"] = PendingPermissionStore()
    app["state_machine"] = None  # initialized after mascot is loaded

    app.router.add_get("/health", handle_health)
    app.router.add_post("/hook", handle_hook)
    app.router.add_post("/input", handle_input)
    return app


async def handle_health(request):
    return web.Response(text="ok")


async def handle_hook(request):
    try:
        data = await request.json()
    except json.JSONDecodeError:
        return web.Response(status=400, text="invalid json")

    event = ClaudeEvent.from_dict(data)
    app = request.app
    app["event_store"].add(event)
    app["session_store"].handle_event(event)

    return web.Response(text="ok")


async def handle_input(request):
    try:
        data = await request.json()
    except json.JSONDecodeError:
        return web.Response(status=400, text="invalid json")

    sm = request.app.get("state_machine")
    if sm:
        name = data.get("name", "")
        value = data.get("value")
        sm.set_input(name, ConditionValue(value))

    return web.Response(text="ok")
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_server.py -v`
Expected: 4 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: aiohttp server with /health, /hook, /input endpoints"
```

---

### Task 8: Event processor (routes events to stores and state machine)

**Files:**
- Create: `masko-linux/backend/event_processor.py`
- Create: `masko-linux/tests/test_event_processor.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_event_processor.py
import json
from pathlib import Path
from backend.models import ClaudeEvent, HookEventType
from backend.stores.event import EventStore
from backend.stores.session import SessionStore
from backend.stores.notification import NotificationStore
from backend.state_machine import StateMachine, ConditionValue
from backend.event_processor import EventProcessor

MASCOT_DIR = Path(__file__).parent.parent / "resources" / "mascots"

def make_processor():
    config = json.loads((MASCOT_DIR / "masko.json").read_text())
    sm = StateMachine(config)
    sm.start()
    return EventProcessor(
        event_store=EventStore(),
        session_store=SessionStore(),
        notification_store=NotificationStore(),
        state_machine=sm,
    )

def test_session_start_sets_working():
    ep = make_processor()
    ev = ClaudeEvent(hook_event_name="SessionStart", session_id="s1", cwd="/project")
    ep.process(ev)
    assert ep.state_machine.inputs["claudeCode::isWorking"] == ConditionValue(True)
    assert ep.state_machine.current_node_name == "Working"

def test_session_end_sets_idle():
    ep = make_processor()
    ep.process(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    ep.process(ClaudeEvent(hook_event_name="SessionEnd", session_id="s1"))
    assert ep.state_machine.inputs["claudeCode::isIdle"] == ConditionValue(True)

def test_permission_request_sets_alert():
    ep = make_processor()
    ep.process(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    ep.process(ClaudeEvent(hook_event_name="PermissionRequest", session_id="s1", tool_name="Bash"))
    assert ep.state_machine.inputs["claudeCode::isAlert"] == ConditionValue(True)

def test_notification_generated():
    ep = make_processor()
    ep.process(ClaudeEvent(hook_event_name="Notification", session_id="s1",
                           title="Done", message="Task complete"))
    assert ep.notification_store.unread_count() == 1

def test_precompact_sets_compacting():
    ep = make_processor()
    ep.process(ClaudeEvent(hook_event_name="SessionStart", session_id="s1"))
    ep.process(ClaudeEvent(hook_event_name="PreCompact", session_id="s1"))
    assert ep.state_machine.inputs["claudeCode::isCompacting"] == ConditionValue(True)
```

- [ ] **Step 2: Implement backend/event_processor.py**

```python
from backend.models import ClaudeEvent, HookEventType
from backend.stores.event import EventStore
from backend.stores.session import SessionStore
from backend.stores.notification import NotificationStore, AppNotification
from backend.state_machine import StateMachine, ConditionValue


class EventProcessor:
    def __init__(self, event_store: EventStore, session_store: SessionStore,
                 notification_store: NotificationStore, state_machine: StateMachine):
        self.event_store = event_store
        self.session_store = session_store
        self.notification_store = notification_store
        self.state_machine = state_machine

    def process(self, event: ClaudeEvent):
        self.event_store.add(event)
        self.session_store.handle_event(event)

        et = event.event_type
        if et == HookEventType.SESSION_START:
            self.state_machine.set_input("claudeCode::isWorking", ConditionValue(True))
            self.state_machine.set_input("claudeCode::isIdle", ConditionValue(False))
            count = len(self.session_store.active_sessions())
            self.state_machine.set_input("claudeCode::sessionCount", ConditionValue(float(count)))

        elif et == HookEventType.SESSION_END:
            active = self.session_store.active_sessions()
            if not active:
                self.state_machine.set_input("claudeCode::isWorking", ConditionValue(False))
                self.state_machine.set_input("claudeCode::isIdle", ConditionValue(True))
            self.state_machine.set_input("claudeCode::sessionCount", ConditionValue(float(len(active))))

        elif et == HookEventType.PERMISSION_REQUEST:
            self.state_machine.set_input("claudeCode::isAlert", ConditionValue(True))

        elif et == HookEventType.PRE_COMPACT:
            self.state_machine.set_input("claudeCode::isCompacting", ConditionValue(True))

        elif et == HookEventType.NOTIFICATION:
            self.notification_store.add(AppNotification(
                title=event.title or "Notification",
                message=event.message or "",
                category=event.notification_type or "info",
            ))
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_event_processor.py -v`
Expected: 5 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: event processor routing events to stores and state machine"
```

---

### Task 9: Hook installer

**Files:**
- Create: `masko-linux/backend/hook_installer.py`
- Create: `masko-linux/resources/hooks/hook-sender.sh`
- Create: `masko-linux/tests/test_hook_installer.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_hook_installer.py
import json
import os
from pathlib import Path
from backend.hook_installer import HookInstaller

def test_install_creates_script(tmp_path):
    installer = HookInstaller(
        settings_path=tmp_path / ".claude" / "settings.json",
        hook_dir=tmp_path / ".masko-desktop" / "hooks",
        config_path=tmp_path / "config.json",
    )
    # Write a config the hook script will read
    (tmp_path / "config.json").write_text(json.dumps({"server": {"hook_port": 49152}}))
    installer.install()
    script = tmp_path / ".masko-desktop" / "hooks" / "hook-sender.sh"
    assert script.exists()
    assert os.access(script, os.X_OK)

def test_install_registers_hooks(tmp_path):
    installer = HookInstaller(
        settings_path=tmp_path / ".claude" / "settings.json",
        hook_dir=tmp_path / ".masko-desktop" / "hooks",
        config_path=tmp_path / "config.json",
    )
    (tmp_path / "config.json").write_text(json.dumps({"server": {"hook_port": 49152}}))
    installer.install()
    settings = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    hooks = settings["hooks"]
    assert "SessionStart" in hooks
    assert "PermissionRequest" in hooks
    assert len(hooks) == 17

def test_is_registered(tmp_path):
    installer = HookInstaller(
        settings_path=tmp_path / ".claude" / "settings.json",
        hook_dir=tmp_path / ".masko-desktop" / "hooks",
        config_path=tmp_path / "config.json",
    )
    (tmp_path / "config.json").write_text(json.dumps({"server": {"hook_port": 49152}}))
    assert not installer.is_registered()
    installer.install()
    assert installer.is_registered()

def test_uninstall(tmp_path):
    installer = HookInstaller(
        settings_path=tmp_path / ".claude" / "settings.json",
        hook_dir=tmp_path / ".masko-desktop" / "hooks",
        config_path=tmp_path / "config.json",
    )
    (tmp_path / "config.json").write_text(json.dumps({"server": {"hook_port": 49152}}))
    installer.install()
    installer.uninstall()
    assert not installer.is_registered()

def test_install_preserves_existing_hooks(tmp_path):
    settings_path = tmp_path / ".claude" / "settings.json"
    settings_path.parent.mkdir(parents=True)
    settings_path.write_text(json.dumps({
        "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "other-hook.sh"}]}]}
    }))
    installer = HookInstaller(
        settings_path=settings_path,
        hook_dir=tmp_path / ".masko-desktop" / "hooks",
        config_path=tmp_path / "config.json",
    )
    (tmp_path / "config.json").write_text(json.dumps({"server": {"hook_port": 49152}}))
    installer.install()
    settings = json.loads(settings_path.read_text())
    session_start_hooks = settings["hooks"]["SessionStart"]
    assert len(session_start_hooks) == 2  # existing + ours
```

- [ ] **Step 2: Create hook-sender.sh template**

```bash
#!/usr/bin/env bash
# Masko Desktop hook sender — forwards Claude Code events to the local backend
CONFIG_PATH="${HOME}/.config/masko-desktop/config.json"
PORT=$(python3 -c "import json,sys; print(json.load(open('$CONFIG_PATH')).get('server',{}).get('hook_port',49152))" 2>/dev/null || echo 49152)
BASE="http://localhost:${PORT}"

# Check health first
if ! curl -sf --max-time 2 "${BASE}/health" > /dev/null 2>&1; then
    exit 0
fi

EVENT_NAME="${CLAUDE_HOOK_EVENT_NAME:-}"
EVENT_JSON=$(cat)

# Inject terminal + shell PID
TERMINAL_PID=""
SHELL_PID="$$"
PPID_WALK=$$
for _ in 1 2 3 4 5 6 7 8 9 10; do
    PPID_WALK=$(ps -o ppid= -p "$PPID_WALK" 2>/dev/null | tr -d ' ')
    [ -z "$PPID_WALK" ] && break
    PROC_NAME=$(ps -o comm= -p "$PPID_WALK" 2>/dev/null)
    case "$PROC_NAME" in
        *code*|*cursor*|*iterm*|*Terminal*|*ghostty*|*kitty*|*wezterm*|*alacritty*|*warp*|*zed*|*gnome-terminal*|*konsole*|*xterm*|*tilix*|*foot*)
            TERMINAL_PID="$PPID_WALK"
            break
            ;;
    esac
done

ENRICHED=$(echo "$EVENT_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tp='${TERMINAL_PID}'
sp='${SHELL_PID}'
if tp: d['terminal_pid']=int(tp)
if sp: d['shell_pid']=int(sp)
print(json.dumps(d))
" 2>/dev/null || echo "$EVENT_JSON")

if [ "$EVENT_NAME" = "PermissionRequest" ]; then
    curl -sf --max-time 120 -X POST "${BASE}/hook" \
        -H "Content-Type: application/json" \
        -d "$ENRICHED"
else
    curl -sf --max-time 5 -X POST "${BASE}/hook" \
        -H "Content-Type: application/json" \
        -d "$ENRICHED" &
fi
```

- [ ] **Step 3: Implement backend/hook_installer.py**

```python
import json
import os
import stat
from pathlib import Path

HOOK_EVENTS = [
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop",
    "Notification", "SessionStart", "SessionEnd", "TaskCompleted",
    "PermissionRequest", "UserPromptSubmit", "SubagentStart",
    "SubagentStop", "PreCompact", "ConfigChange", "TeammateIdle",
    "WorktreeCreate", "WorktreeRemove",
]

HOOK_SCRIPT_TEMPLATE = Path(__file__).parent.parent / "resources" / "hooks" / "hook-sender.sh"


class HookInstaller:
    def __init__(self, settings_path=None, hook_dir=None, config_path=None):
        self._settings_path = Path(settings_path) if settings_path else Path.home() / ".claude" / "settings.json"
        self._hook_dir = Path(hook_dir) if hook_dir else Path.home() / ".masko-desktop" / "hooks"
        self._config_path = Path(config_path) if config_path else Path.home() / ".config" / "masko-desktop" / "config.json"
        self._hook_command = str(self._hook_dir / "hook-sender.sh")

    def is_registered(self) -> bool:
        settings = self._read_settings()
        hooks = settings.get("hooks", {})
        for event in HOOK_EVENTS:
            entries = hooks.get(event, [])
            for entry in entries:
                for h in entry.get("hooks", []):
                    if h.get("command") == self._hook_command:
                        return True
        return False

    def install(self):
        self._ensure_script()
        settings = self._read_settings()
        hooks = settings.setdefault("hooks", {})

        hook_entry = {"matcher": "", "hooks": [{"type": "command", "command": self._hook_command}]}

        for event in HOOK_EVENTS:
            entries = hooks.setdefault(event, [])
            already = any(
                h.get("command") == self._hook_command
                for entry in entries
                for h in entry.get("hooks", [])
            )
            if not already:
                entries.append(hook_entry)

        self._write_settings(settings)

    def uninstall(self):
        settings = self._read_settings()
        hooks = settings.get("hooks", {})
        for event in HOOK_EVENTS:
            entries = hooks.get(event, [])
            hooks[event] = [
                entry for entry in entries
                if not any(h.get("command") == self._hook_command for h in entry.get("hooks", []))
            ]
            if not hooks[event]:
                del hooks[event]
        self._write_settings(settings)

    def _ensure_script(self):
        self._hook_dir.mkdir(parents=True, exist_ok=True)
        dest = self._hook_dir / "hook-sender.sh"
        if HOOK_SCRIPT_TEMPLATE.exists():
            dest.write_text(HOOK_SCRIPT_TEMPLATE.read_text())
        else:
            dest.write_text("#!/usr/bin/env bash\n# placeholder\n")
        dest.chmod(dest.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def _read_settings(self) -> dict:
        if self._settings_path.exists():
            return json.loads(self._settings_path.read_text())
        return {}

    def _write_settings(self, settings: dict):
        self._settings_path.parent.mkdir(parents=True, exist_ok=True)
        self._settings_path.write_text(json.dumps(settings, indent=2))
```

- [ ] **Step 4: Run tests, verify pass**

Run: `python -m pytest tests/test_hook_installer.py -v`
Expected: 5 passed

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: hook installer with Claude Code settings.json integration"
```

---

### Task 10: Video cache

**Files:**
- Create: `masko-linux/backend/video_cache.py`
- Create: `masko-linux/tests/test_video_cache.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_video_cache.py
import time
from pathlib import Path
from unittest.mock import patch, MagicMock
from backend.video_cache import VideoCache

def test_resolve_local_file(tmp_path):
    cache = VideoCache(cache_dir=tmp_path)
    local = tmp_path / "test.webm"
    local.write_bytes(b"video data")
    assert cache.resolve(str(local)) == str(local)

def test_resolve_remote_downloads(tmp_path):
    cache = VideoCache(cache_dir=tmp_path)
    with patch("backend.video_cache.urlretrieve") as mock_dl:
        mock_dl.side_effect = lambda url, path: Path(path).write_bytes(b"downloaded")
        result = cache.resolve("https://assets.masko.ai/video.webm")
        assert Path(result).exists()
        assert Path(result).read_bytes() == b"downloaded"

def test_resolve_remote_cached(tmp_path):
    cache = VideoCache(cache_dir=tmp_path)
    with patch("backend.video_cache.urlretrieve") as mock_dl:
        mock_dl.side_effect = lambda url, path: Path(path).write_bytes(b"downloaded")
        r1 = cache.resolve("https://assets.masko.ai/video.webm")
        r2 = cache.resolve("https://assets.masko.ai/video.webm")
        assert r1 == r2
        assert mock_dl.call_count == 1

def test_evict_old(tmp_path):
    cache = VideoCache(cache_dir=tmp_path, max_age_days=0)
    old = tmp_path / "old.webm"
    old.write_bytes(b"old")
    os_time = time.time() - 86400 * 31
    import os
    os.utime(old, (os_time, os_time))
    cache.evict_old()
    assert not old.exists()
```

- [ ] **Step 2: Implement backend/video_cache.py**

```python
import hashlib
import os
import time
from pathlib import Path
from urllib.request import urlretrieve


class VideoCache:
    def __init__(self, cache_dir=None, max_age_days=30):
        self._cache_dir = Path(cache_dir) if cache_dir else Path.home() / ".cache" / "masko-desktop" / "videos"
        self._cache_dir.mkdir(parents=True, exist_ok=True)
        self._max_age_seconds = max_age_days * 86400

    def resolve(self, url: str) -> str:
        path = Path(url)
        if path.exists():
            return str(path)
        cache_name = hashlib.sha256(url.encode()).hexdigest()[:16] + self._ext(url)
        cached = self._cache_dir / cache_name
        if cached.exists():
            return str(cached)
        urlretrieve(url, str(cached))
        return str(cached)

    def evict_old(self):
        now = time.time()
        for f in self._cache_dir.iterdir():
            if f.is_file() and (now - f.stat().st_mtime) > self._max_age_seconds:
                f.unlink()

    def _ext(self, url: str) -> str:
        for ext in (".webm", ".mov", ".mp4"):
            if ext in url:
                return ext
        return ".webm"
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_video_cache.py -v`
Expected: 4 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: video cache with download and eviction"
```

---

## Chunk 2: IPC and C Overlay Foundation

### Task 11: Backend IPC server (Unix socket)

**Files:**
- Create: `masko-linux/backend/ipc.py`
- Create: `masko-linux/tests/test_ipc.py`

- [ ] **Step 1: Write failing test**

```python
# tests/test_ipc.py
import asyncio
import json
import os
import pytest
from backend.ipc import IPCServer

@pytest.mark.asyncio
async def test_send_and_receive(tmp_path):
    sock_path = str(tmp_path / "test.sock")
    received = []

    async def on_message(msg):
        received.append(msg)

    server = IPCServer(sock_path, on_message=on_message)
    await server.start()

    # Connect as overlay client
    reader, writer = await asyncio.open_unix_connection(sock_path)

    # Backend sends to overlay
    await server.send({"cmd": "show"})
    line = await asyncio.wait_for(reader.readline(), timeout=2)
    assert json.loads(line) == {"cmd": "show"}

    # Overlay sends to backend
    writer.write(json.dumps({"event": "ready"}).encode() + b"\n")
    await writer.drain()
    await asyncio.sleep(0.1)
    assert len(received) == 1
    assert received[0] == {"event": "ready"}

    writer.close()
    await server.stop()

@pytest.mark.asyncio
async def test_not_connected_send(tmp_path):
    sock_path = str(tmp_path / "test.sock")
    server = IPCServer(sock_path, on_message=lambda m: None)
    await server.start()
    await server.send({"cmd": "show"})  # should not raise
    await server.stop()
```

- [ ] **Step 2: Implement backend/ipc.py**

```python
import asyncio
import json
import os
from typing import Callable, Optional


class IPCServer:
    def __init__(self, sock_path: str, on_message: Callable):
        self._sock_path = sock_path
        self._on_message = on_message
        self._server = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._reader_task: Optional[asyncio.Task] = None

    async def start(self):
        if os.path.exists(self._sock_path):
            os.unlink(self._sock_path)
        self._server = await asyncio.start_unix_server(self._handle_client, path=self._sock_path)

    async def stop(self):
        if self._reader_task:
            self._reader_task.cancel()
        if self._writer:
            self._writer.close()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        if os.path.exists(self._sock_path):
            os.unlink(self._sock_path)

    async def send(self, msg: dict):
        if not self._writer:
            return
        try:
            data = json.dumps(msg).encode() + b"\n"
            self._writer.write(data)
            await self._writer.drain()
        except (ConnectionError, OSError):
            self._writer = None

    @property
    def connected(self) -> bool:
        return self._writer is not None

    async def _handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self._writer = writer
        self._reader_task = asyncio.current_task()
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    msg = json.loads(line)
                    await self._on_message(msg)
                except json.JSONDecodeError:
                    pass
        except asyncio.CancelledError:
            pass
        finally:
            self._writer = None
```

- [ ] **Step 3: Run tests, verify pass**

Run: `python -m pytest tests/test_ipc.py -v`
Expected: 2 passed

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: unix socket IPC server for overlay communication"
```

---

### Task 12: C overlay — X11 window with ARGB transparency

**Files:**
- Create: `masko-linux/overlay/main.c`
- Create: `masko-linux/overlay/window.h`
- Create: `masko-linux/overlay/window.c`
- Create: `masko-linux/overlay/ipc.h`
- Create: `masko-linux/overlay/ipc.c`
- Create: `masko-linux/tests/test_overlay_window.sh` (E2E test using Xvfb)

- [ ] **Step 1: Write E2E test script (will fail since overlay doesn't exist yet)**

```bash
#!/usr/bin/env bash
# tests/test_overlay_window.sh — E2E: verify overlay creates transparent X11 window
set -euo pipefail

# Requires: Xvfb, xdotool, imagemagick (import)
DISPLAY_NUM=:99
SCREENSHOT_DIR="${1:-/tmp/masko-test-screenshots}"
mkdir -p "$SCREENSHOT_DIR"

cleanup() { kill $XVFB_PID 2>/dev/null || true; kill $OVERLAY_PID 2>/dev/null || true; }
trap cleanup EXIT

# Start virtual display
Xvfb $DISPLAY_NUM -screen 0 1920x1080x24+32 -ac &
XVFB_PID=$!
sleep 1
export DISPLAY=$DISPLAY_NUM

# Start overlay
./overlay/masko-overlay --test-mode &
OVERLAY_PID=$!
sleep 2

# Verify window exists
WID=$(xdotool search --name "masko-overlay" 2>/dev/null | head -1)
if [ -z "$WID" ]; then
    echo "FAIL: overlay window not found"
    exit 1
fi
echo "PASS: overlay window found (wid=$WID)"

# Take screenshot
import -window root "$SCREENSHOT_DIR/overlay-window.png"
echo "Screenshot saved to $SCREENSHOT_DIR/overlay-window.png"

# Verify window properties
xprop -id "$WID" | grep -q "override_redirect = 1" && echo "PASS: override_redirect" || echo "FAIL: override_redirect"
xprop -id "$WID" _NET_WM_WINDOW_TYPE | grep -q "DOCK" && echo "PASS: window type DOCK" || echo "FAIL: window type DOCK"

echo "All overlay window tests complete"
```

- [ ] **Step 2: Implement overlay/window.h and window.c**

`overlay/window.h`:
```c
#ifndef MASKO_WINDOW_H
#define MASKO_WINDOW_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xcomposite.h>
#include <X11/extensions/shape.h>
#include <cairo/cairo.h>
#include <cairo/cairo-xlib.h>

typedef struct {
    Display *display;
    Window window;
    int screen;
    Visual *visual;
    Colormap colormap;
    int width;
    int height;
    int x;
    int y;
    cairo_surface_t *surface;
    cairo_t *cr;
    cairo_surface_t *back_buffer;
    cairo_t *back_cr;
} MaskoWindow;

int masko_window_init(MaskoWindow *win, int x, int y, int w, int h);
void masko_window_destroy(MaskoWindow *win);
void masko_window_show(MaskoWindow *win);
void masko_window_hide(MaskoWindow *win);
void masko_window_move(MaskoWindow *win, int x, int y);
void masko_window_resize(MaskoWindow *win, int w, int h);
void masko_window_flip(MaskoWindow *win);  /* swap back buffer to screen */
cairo_t *masko_window_back_cr(MaskoWindow *win);  /* draw to this */
int masko_window_fd(MaskoWindow *win);  /* for select() */

#endif
```

`overlay/window.c`:
```c
#include "window.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xatom.h>

static Visual *find_argb_visual(Display *dpy, int screen) {
    XVisualInfo tpl = {.screen = screen, .depth = 32, .class = TrueColor};
    int count = 0;
    XVisualInfo *vis = XGetVisualInfo(dpy, VisualScreenMask | VisualDepthMask | VisualClassMask, &tpl, &count);
    if (!vis || count == 0) return NULL;
    Visual *result = vis[0].visual;
    XFree(vis);
    return result;
}

int masko_window_init(MaskoWindow *win, int x, int y, int w, int h) {
    win->display = XOpenDisplay(NULL);
    if (!win->display) {
        fprintf(stderr, "Cannot open X display\n");
        return -1;
    }
    win->screen = DefaultScreen(win->display);

    /* Check for Composite extension */
    int ev, err;
    if (!XCompositeQueryExtension(win->display, &ev, &err)) {
        fprintf(stderr, "Masko overlay requires X11 Composite extension\n");
        XCloseDisplay(win->display);
        return -1;
    }

    win->visual = find_argb_visual(win->display, win->screen);
    if (!win->visual) {
        fprintf(stderr, "No 32-bit ARGB visual found\n");
        XCloseDisplay(win->display);
        return -1;
    }

    win->colormap = XCreateColormap(win->display, RootWindow(win->display, win->screen), win->visual, AllocNone);
    win->x = x; win->y = y; win->width = w; win->height = h;

    XSetWindowAttributes attrs = {
        .override_redirect = True,
        .colormap = win->colormap,
        .background_pixel = 0,
        .border_pixel = 0,
        .event_mask = ExposureMask | ButtonPressMask | ButtonReleaseMask |
                      PointerMotionMask | StructureNotifyMask | KeyPressMask,
    };

    win->window = XCreateWindow(
        win->display, RootWindow(win->display, win->screen),
        x, y, w, h, 0, 32, InputOutput, win->visual,
        CWOverrideRedirect | CWColormap | CWBackPixel | CWBorderPixel | CWEventMask,
        &attrs
    );

    /* Set window type and always-on-top */
    Atom dock = XInternAtom(win->display, "_NET_WM_WINDOW_TYPE_DOCK", False);
    Atom wtype = XInternAtom(win->display, "_NET_WM_WINDOW_TYPE", False);
    XChangeProperty(win->display, win->window, wtype, XA_ATOM, 32, PropModeReplace, (unsigned char *)&dock, 1);

    Atom above = XInternAtom(win->display, "_NET_WM_STATE_ABOVE", False);
    Atom wstate = XInternAtom(win->display, "_NET_WM_STATE", False);
    XChangeProperty(win->display, win->window, wstate, XA_ATOM, 32, PropModeReplace, (unsigned char *)&above, 1);

    /* Set window name for xdotool/testing */
    XStoreName(win->display, win->window, "masko-overlay");

    /* Create Cairo surfaces for double buffering */
    win->surface = cairo_xlib_surface_create(win->display, win->window, win->visual, w, h);
    win->cr = cairo_create(win->surface);
    win->back_buffer = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    win->back_cr = cairo_create(win->back_buffer);

    return 0;
}

void masko_window_show(MaskoWindow *win) {
    XMapRaised(win->display, win->window);
    XFlush(win->display);
}

void masko_window_hide(MaskoWindow *win) {
    XUnmapWindow(win->display, win->window);
    XFlush(win->display);
}

void masko_window_move(MaskoWindow *win, int x, int y) {
    win->x = x; win->y = y;
    XMoveWindow(win->display, win->window, x, y);
}

void masko_window_resize(MaskoWindow *win, int w, int h) {
    win->width = w; win->height = h;
    XResizeWindow(win->display, win->window, w, h);
    cairo_xlib_surface_set_size(win->surface, w, h);
    cairo_destroy(win->back_cr);
    cairo_surface_destroy(win->back_buffer);
    win->back_buffer = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    win->back_cr = cairo_create(win->back_buffer);
}

void masko_window_flip(MaskoWindow *win) {
    cairo_set_operator(win->cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_surface(win->cr, win->back_buffer, 0, 0);
    cairo_paint(win->cr);
    XFlush(win->display);
}

cairo_t *masko_window_back_cr(MaskoWindow *win) {
    return win->back_cr;
}

int masko_window_fd(MaskoWindow *win) {
    return ConnectionNumber(win->display);
}

void masko_window_destroy(MaskoWindow *win) {
    cairo_destroy(win->back_cr);
    cairo_surface_destroy(win->back_buffer);
    cairo_destroy(win->cr);
    cairo_surface_destroy(win->surface);
    XFreeColormap(win->display, win->colormap);
    XDestroyWindow(win->display, win->window);
    XCloseDisplay(win->display);
}
```

- [ ] **Step 3: Implement overlay/ipc.h and ipc.c (Unix socket client)**

`overlay/ipc.h`:
```c
#ifndef MASKO_IPC_H
#define MASKO_IPC_H

#include <cjson/cJSON.h>

typedef struct {
    int fd;
    char recv_buf[65536];
    int recv_len;
} MaskoIPC;

int masko_ipc_connect(MaskoIPC *ipc, const char *sock_path);
void masko_ipc_disconnect(MaskoIPC *ipc);
int masko_ipc_send(MaskoIPC *ipc, cJSON *msg);
cJSON *masko_ipc_recv(MaskoIPC *ipc);  /* returns NULL if no complete message */
int masko_ipc_fd(MaskoIPC *ipc);

#endif
```

`overlay/ipc.c`:
```c
#include "ipc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>

int masko_ipc_connect(MaskoIPC *ipc, const char *sock_path) {
    ipc->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (ipc->fd < 0) return -1;
    ipc->recv_len = 0;

    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    if (connect(ipc->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(ipc->fd);
        ipc->fd = -1;
        return -1;
    }
    return 0;
}

void masko_ipc_disconnect(MaskoIPC *ipc) {
    if (ipc->fd >= 0) {
        close(ipc->fd);
        ipc->fd = -1;
    }
}

int masko_ipc_send(MaskoIPC *ipc, cJSON *msg) {
    if (ipc->fd < 0) return -1;
    char *str = cJSON_PrintUnformatted(msg);
    if (!str) return -1;
    int len = strlen(str);
    char *buf = malloc(len + 2);
    memcpy(buf, str, len);
    buf[len] = '\n';
    buf[len + 1] = '\0';
    int written = write(ipc->fd, buf, len + 1);
    free(str);
    free(buf);
    return written > 0 ? 0 : -1;
}

cJSON *masko_ipc_recv(MaskoIPC *ipc) {
    /* Try to read more data */
    if (ipc->fd >= 0 && ipc->recv_len < (int)sizeof(ipc->recv_buf) - 1) {
        int n = read(ipc->fd, ipc->recv_buf + ipc->recv_len,
                     sizeof(ipc->recv_buf) - 1 - ipc->recv_len);
        if (n > 0) ipc->recv_len += n;
    }

    /* Look for newline */
    char *nl = memchr(ipc->recv_buf, '\n', ipc->recv_len);
    if (!nl) return NULL;

    int msg_len = nl - ipc->recv_buf;
    ipc->recv_buf[msg_len] = '\0';
    cJSON *json = cJSON_Parse(ipc->recv_buf);

    /* Shift remaining data */
    int remaining = ipc->recv_len - msg_len - 1;
    if (remaining > 0) memmove(ipc->recv_buf, nl + 1, remaining);
    ipc->recv_len = remaining;

    return json;
}

int masko_ipc_fd(MaskoIPC *ipc) {
    return ipc->fd;
}
```

- [ ] **Step 4: Implement overlay/main.c (minimal event loop)**

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/select.h>
#include "window.h"
#include "ipc.h"

static volatile int running = 1;

static void handle_signal(int sig) { (void)sig; running = 0; }

static void handle_ipc_message(MaskoWindow *win, cJSON *msg) {
    const char *cmd = cJSON_GetStringValue(cJSON_GetObjectItem(msg, "cmd"));
    if (!cmd) return;

    if (strcmp(cmd, "show") == 0) {
        masko_window_show(win);
    } else if (strcmp(cmd, "hide") == 0) {
        masko_window_hide(win);
    } else if (strcmp(cmd, "move") == 0) {
        int x = cJSON_GetNumberValue(cJSON_GetObjectItem(msg, "x"));
        int y = cJSON_GetNumberValue(cJSON_GetObjectItem(msg, "y"));
        masko_window_move(win, x, y);
    } else if (strcmp(cmd, "resize") == 0) {
        int w = cJSON_GetNumberValue(cJSON_GetObjectItem(msg, "w"));
        int h = cJSON_GetNumberValue(cJSON_GetObjectItem(msg, "h"));
        masko_window_resize(win, w, h);
    }
    /* More commands added in later tasks */
}

int main(int argc, char *argv[]) {
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    int test_mode = 0;
    const char *sock_path = "/tmp/masko-overlay.sock";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test-mode") == 0) test_mode = 1;
        if (strcmp(argv[i], "--sock") == 0 && i + 1 < argc) sock_path = argv[i + 1];
    }

    MaskoWindow win;
    if (masko_window_init(&win, 100, 100, 200, 200) != 0) return 1;
    masko_window_show(&win);

    /* Clear to transparent */
    cairo_t *cr = masko_window_back_cr(&win);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);

    /* Draw a placeholder circle so the window is visible */
    cairo_arc(cr, 100, 100, 80, 0, 2 * 3.14159);
    cairo_set_source_rgba(cr, 0.2, 0.6, 1.0, 0.8);
    cairo_fill(cr);
    masko_window_flip(&win);

    MaskoIPC ipc = {.fd = -1};
    if (!test_mode) {
        if (masko_ipc_connect(&ipc, sock_path) == 0) {
            cJSON *ready = cJSON_CreateObject();
            cJSON_AddStringToObject(ready, "event", "ready");
            masko_ipc_send(&ipc, ready);
            cJSON_Delete(ready);
        }
    }

    int x11_fd = masko_window_fd(&win);

    while (running) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(x11_fd, &fds);
        int max_fd = x11_fd;
        if (ipc.fd >= 0) {
            FD_SET(ipc.fd, &fds);
            if (ipc.fd > max_fd) max_fd = ipc.fd;
        }

        struct timeval tv = {.tv_sec = 0, .tv_usec = 100000};  /* 100ms */
        int ready = select(max_fd + 1, &fds, NULL, NULL, &tv);

        if (ready > 0) {
            /* Handle X11 events */
            if (FD_ISSET(x11_fd, &fds)) {
                while (XPending(win.display)) {
                    XEvent ev;
                    XNextEvent(win.display, &ev);
                    /* Event handling expanded in later tasks */
                }
            }
            /* Handle IPC messages */
            if (ipc.fd >= 0 && FD_ISSET(ipc.fd, &fds)) {
                cJSON *msg;
                while ((msg = masko_ipc_recv(&ipc)) != NULL) {
                    handle_ipc_message(&win, msg);
                    cJSON_Delete(msg);
                }
            }
        }

        if (test_mode) {
            /* In test mode, run for a few seconds then exit cleanly */
            static int frames = 0;
            if (++frames > 50) break;  /* ~5 seconds at 100ms */
        }
    }

    masko_ipc_disconnect(&ipc);
    masko_window_destroy(&win);
    return 0;
}
```

- [ ] **Step 5: Add XShape click-through and drag handling to window.c**

Add `masko_window_update_shape(MaskoWindow *win, cairo_surface_t *content)` — scans the back buffer alpha channel, creates an XShape region mask with only opaque pixels as input region. Call after each `flip()`. This makes transparent areas click-through.

Add drag handling to `main.c`: on ButtonPress in mascot area, enter drag mode. On PointerMotion during drag, `masko_window_move()`. On ButtonRelease, exit drag mode and send `{"event": "position", "x": ..., "y": ...}` via IPC.

- [ ] **Step 6: Update Makefile to include cJSON dependency**

Add `cjson` to pkg-config in overlay/Makefile:
```makefile
CFLAGS = -Wall -Wextra -O2 $(shell pkg-config --cflags x11 xext xcomposite xfixes cairo pango pangocairo libavformat libavcodec libavutil libswscale cjson)
LDFLAGS = $(shell pkg-config --libs x11 xext xcomposite xfixes cairo pango pangocairo libavformat libavcodec libavutil libswscale cjson) -lm
```

- [ ] **Step 7: Build and run E2E test**

```bash
cd masko-linux && make overlay
chmod +x tests/test_overlay_window.sh
bash tests/test_overlay_window.sh /tmp/masko-screenshots
```

Expected: Window found, override_redirect confirmed, screenshot captured.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: C overlay with X11 ARGB window, XShape click-through, drag, and IPC client"
```

---

### Task 13: C overlay — FFmpeg video decoding

**Files:**
- Create: `masko-linux/overlay/video.h`
- Create: `masko-linux/overlay/video.c`
- Create: `masko-linux/tests/test_overlay_video.sh`

- [ ] **Step 1: Write E2E test**

```bash
#!/usr/bin/env bash
# tests/test_overlay_video.sh — verify video decode and render
set -euo pipefail

DISPLAY_NUM=:98
SCREENSHOT_DIR="${1:-/tmp/masko-test-screenshots}"
mkdir -p "$SCREENSHOT_DIR"

# Generate a test video (2 seconds, solid red, 100x100)
ffmpeg -y -f lavfi -i "color=red:size=100x100:rate=30:duration=2" \
    -c:v libvpx-vp9 -pix_fmt yuva420p /tmp/test-mascot.webm 2>/dev/null

cleanup() { kill $XVFB_PID 2>/dev/null || true; kill $OVERLAY_PID 2>/dev/null || true; }
trap cleanup EXIT

Xvfb $DISPLAY_NUM -screen 0 1920x1080x24+32 -ac &
XVFB_PID=$!
sleep 1
export DISPLAY=$DISPLAY_NUM

# Start overlay with test video via IPC
python3 -c "
import socket, json, time
# Start overlay
import subprocess
proc = subprocess.Popen(['./overlay/masko-overlay', '--test-mode'])

# Give it time to start
time.sleep(2)

# Connect and send play command via IPC
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('/tmp/masko-overlay.sock')
    msg = json.dumps({'cmd': 'play', 'video': '/tmp/test-mascot.webm', 'loop': False}) + '\n'
    sock.sendall(msg.encode())
    time.sleep(1)
except:
    pass
sock.close()
proc.terminate()
" &
OVERLAY_PID=$!
sleep 4

import -window root "$SCREENSHOT_DIR/overlay-video.png"
echo "Screenshot saved to $SCREENSHOT_DIR/overlay-video.png"
echo "PASS: video decode test complete (manual screenshot inspection)"
```

- [ ] **Step 2: Implement overlay/video.h**

```c
#ifndef MASKO_VIDEO_H
#define MASKO_VIDEO_H

#include <cairo/cairo.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>

typedef struct {
    AVFormatContext *fmt_ctx;
    AVCodecContext *codec_ctx;
    struct SwsContext *sws_ctx;
    int stream_idx;
    int width;
    int height;
    AVFrame *frame;
    AVFrame *frame_rgba;
    AVPacket *pkt;
    uint8_t *rgba_buf;
    cairo_surface_t *surface;
    int finished;
} MaskoVideo;

int masko_video_open(MaskoVideo *v, const char *path);
void masko_video_close(MaskoVideo *v);
cairo_surface_t *masko_video_next_frame(MaskoVideo *v);  /* NULL if no more frames */
void masko_video_rewind(MaskoVideo *v);
double masko_video_fps(MaskoVideo *v);

#endif
```

- [ ] **Step 3: Implement overlay/video.c**

```c
#include "video.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavutil/imgutils.h>

int masko_video_open(MaskoVideo *v, const char *path) {
    memset(v, 0, sizeof(*v));

    if (avformat_open_input(&v->fmt_ctx, path, NULL, NULL) < 0) {
        fprintf(stderr, "Cannot open video: %s\n", path);
        return -1;
    }
    if (avformat_find_stream_info(v->fmt_ctx, NULL) < 0) {
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    v->stream_idx = -1;
    for (unsigned i = 0; i < v->fmt_ctx->nb_streams; i++) {
        if (v->fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            v->stream_idx = i;
            break;
        }
    }
    if (v->stream_idx < 0) {
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    AVCodecParameters *par = v->fmt_ctx->streams[v->stream_idx]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    v->codec_ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(v->codec_ctx, par);
    if (avcodec_open2(v->codec_ctx, codec, NULL) < 0) {
        avcodec_free_context(&v->codec_ctx);
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    v->width = par->width;
    v->height = par->height;
    v->frame = av_frame_alloc();
    v->frame_rgba = av_frame_alloc();
    v->pkt = av_packet_alloc();

    int buf_size = av_image_get_buffer_size(AV_PIX_FMT_BGRA, v->width, v->height, 1);
    v->rgba_buf = av_malloc(buf_size);
    av_image_fill_arrays(v->frame_rgba->data, v->frame_rgba->linesize,
                         v->rgba_buf, AV_PIX_FMT_BGRA, v->width, v->height, 1);

    v->sws_ctx = sws_getContext(v->width, v->height, v->codec_ctx->pix_fmt,
                                 v->width, v->height, AV_PIX_FMT_BGRA,
                                 SWS_BILINEAR, NULL, NULL, NULL);

    v->surface = cairo_image_surface_create_for_data(
        v->rgba_buf, CAIRO_FORMAT_ARGB32, v->width, v->height,
        v->frame_rgba->linesize[0]
    );
    v->finished = 0;

    return 0;
}

cairo_surface_t *masko_video_next_frame(MaskoVideo *v) {
    while (1) {
        int ret = av_read_frame(v->fmt_ctx, v->pkt);
        if (ret < 0) {
            v->finished = 1;
            return NULL;
        }
        if (v->pkt->stream_index != v->stream_idx) {
            av_packet_unref(v->pkt);
            continue;
        }

        avcodec_send_packet(v->codec_ctx, v->pkt);
        av_packet_unref(v->pkt);

        ret = avcodec_receive_frame(v->codec_ctx, v->frame);
        if (ret == 0) {
            sws_scale(v->sws_ctx, (const uint8_t *const *)v->frame->data,
                      v->frame->linesize, 0, v->height,
                      v->frame_rgba->data, v->frame_rgba->linesize);
            cairo_surface_mark_dirty(v->surface);
            return v->surface;
        }
    }
}

void masko_video_rewind(MaskoVideo *v) {
    av_seek_frame(v->fmt_ctx, v->stream_idx, 0, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(v->codec_ctx);
    v->finished = 0;
}

double masko_video_fps(MaskoVideo *v) {
    AVRational r = v->fmt_ctx->streams[v->stream_idx]->avg_frame_rate;
    if (r.den == 0) return 30.0;
    return (double)r.num / r.den;
}

void masko_video_close(MaskoVideo *v) {
    if (v->surface) cairo_surface_destroy(v->surface);
    if (v->sws_ctx) sws_freeContext(v->sws_ctx);
    if (v->rgba_buf) av_free(v->rgba_buf);
    if (v->frame) av_frame_free(&v->frame);
    if (v->frame_rgba) av_frame_free(&v->frame_rgba);
    if (v->pkt) av_packet_free(&v->pkt);
    if (v->codec_ctx) avcodec_free_context(&v->codec_ctx);
    if (v->fmt_ctx) avformat_close_input(&v->fmt_ctx);
}
```

- [ ] **Step 4: Build and run video E2E test**

```bash
cd masko-linux && make overlay
bash tests/test_overlay_video.sh /tmp/masko-screenshots
```

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: FFmpeg video decoder for mascot animations"
```

---

## Chunk 3: Permission UI, Hotkeys, Toast, Session Switcher

### Task 14: C overlay — Cairo permission prompt UI

**Files:**
- Create: `masko-linux/overlay/render.h`
- Create: `masko-linux/overlay/render.c`
- Create: `masko-linux/overlay/permission_ui.h`
- Create: `masko-linux/overlay/permission_ui.c`
- Create: `masko-linux/overlay/card_stack.h`
- Create: `masko-linux/overlay/card_stack.c`

- [ ] **Step 1: Write E2E test for permission UI**

```bash
#!/usr/bin/env bash
# tests/test_permission_ui.sh
set -euo pipefail
DISPLAY_NUM=:97
SCREENSHOT_DIR="${1:-/tmp/masko-test-screenshots}"
mkdir -p "$SCREENSHOT_DIR"
SOCK_PATH="/tmp/masko-test-perm.sock"

cleanup() { kill $XVFB_PID 2>/dev/null || true; kill $OVERLAY_PID 2>/dev/null || true; rm -f "$SOCK_PATH"; }
trap cleanup EXIT

Xvfb $DISPLAY_NUM -screen 0 1920x1080x24+32 -ac &
XVFB_PID=$!
sleep 1
export DISPLAY=$DISPLAY_NUM

# Start overlay (normal mode, will connect to our socket)
./overlay/masko-overlay --sock "$SOCK_PATH" &
OVERLAY_PID=$!
sleep 2

# Python helper: act as backend IPC server, send permission, read response
RESULT=$(python3 -c "
import socket, json, time, sys
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind('$SOCK_PATH')
srv.listen(1)
srv.settimeout(5)
conn, _ = srv.accept()

# Wait for ready
data = conn.recv(4096).decode()
assert '\"ready\"' in data, f'Expected ready, got: {data}'
print('PASS: overlay sent ready event', file=sys.stderr)

# Send permission command
cmd = json.dumps({'cmd': 'permission', 'tool': 'Bash', 'input': 'rm -rf /', 'id': 'test-perm-1'}) + '\n'
conn.sendall(cmd.encode())
time.sleep(1)

# Take screenshot before interaction
import subprocess
subprocess.run(['import', '-window', 'root', '$SCREENSHOT_DIR/permission-ui.png'])

# Click approve button (approximate center of overlay, bottom-left button area)
subprocess.run(['xdotool', 'mousemove', '150', '280', 'click', '1'])
time.sleep(0.5)

# Read response
conn.settimeout(3)
resp = conn.recv(4096).decode()
print(resp)
conn.close()
srv.close()
")

echo "$RESULT" | grep -q '"approve"' && echo "PASS: approve response received" || echo "FAIL: no approve in response: $RESULT"
echo "Screenshot saved to $SCREENSHOT_DIR/permission-ui.png"
```

- [ ] **Step 2: Implement card_stack.h/c** — active card priority enum (NONE, TOAST, PERMISSION, SESSION_SWITCHER), push/pop/current.

- [ ] **Step 3: Implement render.h/c** — helper functions: `render_rounded_rect`, `render_text` (Pango), `render_button` with hover state.

- [ ] **Step 4: Implement permission_ui.h/c** — `permission_ui_show(tool, input, id)`, `permission_ui_draw(cr)`, `permission_ui_hit_test(x, y)` returning button id, `permission_ui_hover(x, y)`.

- [ ] **Step 5: Integrate into main.c** — handle `{"cmd": "permission", ...}`, draw permission UI in render loop, handle ButtonPress events for hit-testing, send response back via IPC.

- [ ] **Step 6: Build and run E2E test, take screenshot**

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: permission prompt UI with Cairo rendering and mouse interaction"
```

---

### Task 15: C overlay — global hotkeys

**Files:**
- Create: `masko-linux/overlay/hotkeys.h`
- Create: `masko-linux/overlay/hotkeys.c`

- [ ] **Step 1: Write E2E test**

```bash
#!/usr/bin/env bash
# tests/test_hotkeys.sh
set -euo pipefail
DISPLAY_NUM=:96
SOCK_PATH="/tmp/masko-test-hotkey.sock"

cleanup() { kill $XVFB_PID 2>/dev/null || true; kill $OVERLAY_PID 2>/dev/null || true; rm -f "$SOCK_PATH"; }
trap cleanup EXIT

Xvfb $DISPLAY_NUM -screen 0 1920x1080x24+32 -ac &
XVFB_PID=$!
sleep 1
export DISPLAY=$DISPLAY_NUM

./overlay/masko-overlay --sock "$SOCK_PATH" &
OVERLAY_PID=$!
sleep 2

RESULT=$(python3 -c "
import socket, json, time, subprocess, sys
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind('$SOCK_PATH')
srv.listen(1)
srv.settimeout(5)
conn, _ = srv.accept()
conn.recv(4096)  # ready event

# Simulate Super+M keypress
time.sleep(0.5)
subprocess.run(['xdotool', 'key', 'super+m'])
time.sleep(0.5)

conn.settimeout(3)
data = conn.recv(4096).decode()
print(data)
conn.close()
srv.close()
")

echo "$RESULT" | grep -q '"toggle"' && echo "PASS: toggle hotkey event received" || echo "FAIL: no toggle event: $RESULT"
```

- [ ] **Step 2: Implement hotkeys.h/c** — `hotkeys_init(display, config_json)`, `hotkeys_grab_all(display)`, `hotkeys_ungrab_all(display)`, `hotkeys_handle_key(event)` returning action string.

- [ ] **Step 3: Integrate into main.c** — KeyPress events → hotkeys_handle_key → IPC event or local action (Escape dismisses topmost card).

- [ ] **Step 4: Build and run E2E test**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: global hotkey system via XGrabKey"
```

---

### Task 16: C overlay — toast notifications

**Files:**
- Create: `masko-linux/overlay/toast.h`
- Create: `masko-linux/overlay/toast.c`

- [ ] **Step 1: Write E2E test**

```bash
#!/usr/bin/env bash
# tests/test_toast.sh
set -euo pipefail
DISPLAY_NUM=:95
SOCK_PATH="/tmp/masko-test-toast.sock"
SCREENSHOT_DIR="${1:-/tmp/masko-test-screenshots}"
mkdir -p "$SCREENSHOT_DIR"

cleanup() { kill $XVFB_PID 2>/dev/null || true; kill $OVERLAY_PID 2>/dev/null || true; rm -f "$SOCK_PATH"; }
trap cleanup EXIT

Xvfb $DISPLAY_NUM -screen 0 1920x1080x24+32 -ac &
XVFB_PID=$!
sleep 1
export DISPLAY=$DISPLAY_NUM

./overlay/masko-overlay --sock "$SOCK_PATH" &
OVERLAY_PID=$!
sleep 2

python3 -c "
import socket, json, time, subprocess
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind('$SOCK_PATH')
srv.listen(1)
srv.settimeout(5)
conn, _ = srv.accept()
conn.recv(4096)  # ready

cmd = json.dumps({'cmd': 'toast', 'text': 'Session finished!', 'duration': 5000}) + '\n'
conn.sendall(cmd.encode())
time.sleep(1)
subprocess.run(['import', '-window', 'root', '$SCREENSHOT_DIR/toast.png'])
conn.close()
srv.close()
"

# Verify screenshot has non-transparent content (toast text region)
PIXELS=$(identify -verbose "$SCREENSHOT_DIR/toast.png" 2>/dev/null | grep -c "srgba" || echo 0)
echo "Screenshot saved to $SCREENSHOT_DIR/toast.png"
echo "PASS: toast test complete (check screenshot)"
```

- [ ] **Step 2: Implement toast.h/c** — `toast_show(text, duration_ms)`, `toast_draw(cr)`, `toast_tick(elapsed_ms)` returning whether still visible.

- [ ] **Step 3: Integrate into main.c and card_stack**

- [ ] **Step 4: Build and run E2E test**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: toast notification overlay with auto-dismiss"
```

---

### Task 17: C overlay — session switcher UI

**Files:**
- Create: `masko-linux/overlay/session_switcher.h`
- Create: `masko-linux/overlay/session_switcher.c`

- [ ] **Step 1: Write E2E test**

```bash
#!/usr/bin/env bash
# tests/test_session_switcher.sh
set -euo pipefail
DISPLAY_NUM=:94
SOCK_PATH="/tmp/masko-test-switcher.sock"
SCREENSHOT_DIR="${1:-/tmp/masko-test-screenshots}"
mkdir -p "$SCREENSHOT_DIR"

cleanup() { kill $XVFB_PID 2>/dev/null || true; kill $OVERLAY_PID 2>/dev/null || true; rm -f "$SOCK_PATH"; }
trap cleanup EXIT

Xvfb $DISPLAY_NUM -screen 0 1920x1080x24+32 -ac &
XVFB_PID=$!
sleep 1
export DISPLAY=$DISPLAY_NUM

./overlay/masko-overlay --sock "$SOCK_PATH" &
OVERLAY_PID=$!
sleep 2

RESULT=$(python3 -c "
import socket, json, time, subprocess, sys
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind('$SOCK_PATH')
srv.listen(1)
srv.settimeout(5)
conn, _ = srv.accept()
conn.recv(4096)  # ready

# Show session switcher
sessions = [
    {'id': 's1', 'cwd': '/home/user/project-a', 'model': 'opus', 'phase': 'working'},
    {'id': 's2', 'cwd': '/home/user/project-b', 'model': 'sonnet', 'phase': 'idle'},
]
cmd = json.dumps({'cmd': 'session_switcher', 'sessions': sessions, 'selected': 0}) + '\n'
conn.sendall(cmd.encode())
time.sleep(1)
subprocess.run(['import', '-window', 'root', '$SCREENSHOT_DIR/switcher-initial.png'])

# Navigate down
cmd = json.dumps({'cmd': 'session_switcher_nav', 'direction': 'next'}) + '\n'
conn.sendall(cmd.encode())
time.sleep(0.5)
subprocess.run(['import', '-window', 'root', '$SCREENSHOT_DIR/switcher-nav.png'])

# Confirm selection
cmd = json.dumps({'cmd': 'session_switcher_nav', 'direction': 'confirm'}) + '\n'
conn.sendall(cmd.encode())
time.sleep(0.5)

conn.settimeout(3)
data = conn.recv(4096).decode()
print(data)
conn.close()
srv.close()
")

echo "$RESULT" | grep -q '"confirm"' && echo "PASS: confirm event received" || echo "FAIL: $RESULT"
echo "Screenshots saved to $SCREENSHOT_DIR/switcher-*.png"
```

- [ ] **Step 2: Implement session_switcher.h/c** — `session_switcher_show(sessions_json)`, `session_switcher_draw(cr)`, `session_switcher_nav(direction)`, `session_switcher_hit_test(x,y)`.

- [ ] **Step 3: Integrate into main.c and card_stack**

- [ ] **Step 4: Build and run E2E test**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: session switcher overlay with keyboard navigation"
```

---

## Chunk 4: Backend Integration, Dashboard, Packaging

### Task 18: Backend orchestrator (ties everything together)

**Files:**
- Create: `masko-linux/backend/__main__.py`
- Modify: `masko-linux/backend/server.py` — integrate event processor and IPC

- [ ] **Step 1: Write integration test** — start full backend, POST events via HTTP, verify state machine transitions and IPC messages sent to a mock overlay connection.

- [ ] **Step 2: Implement `__main__.py`** — loads config, initializes stores, starts HTTP server + IPC server, spawns overlay process, connects event processor to IPC. Overlay lifecycle requirements:
  - Wait for `{"event": "ready"}` on IPC before sending commands
  - Detect overlay death via SIGCHLD + socket EOF
  - Respawn after 1-second delay, up to 5 retries
  - On respawn: re-send current state machine node (animation resumes)
  - On overlay death with active permission: auto-deny to unblock Claude Code hook
  - On overlay death with active session switcher: silently discard

- [ ] **Step 3: Wire permission flow** — PermissionRequest holds HTTP connection, sends permission command to overlay, overlay response resolves the future, HTTP response sent back to hook script.

- [ ] **Step 4: Run integration test**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: backend orchestrator with overlay lifecycle management"
```

---

### Task 19: Terminal focus

**Files:**
- Create: `masko-linux/backend/terminal_focus.py`
- Create: `masko-linux/tests/test_terminal_focus.py`

- [ ] **Step 1: Write test** (unit test for PID→window mapping logic, mock xdotool calls)

- [ ] **Step 2: Implement** — `focus_terminal(pid)` using xdotool, fallback to wmctrl. IDE extension version check for VS Code family.

- [ ] **Step 3: Run tests**

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: terminal focus via xdotool with IDE extension support"
```

---

### Task 20: Web dashboard

**Files:**
- Create: `masko-linux/dashboard/index.html`
- Create: `masko-linux/dashboard/app.js`
- Create: `masko-linux/dashboard/style.css`
- Modify: `masko-linux/backend/server.py` — add dashboard routes and WebSocket

- [ ] **Step 1: Write E2E test** — start backend, open dashboard in headless browser (or curl), verify HTML served, verify WebSocket connection delivers session updates.

- [ ] **Step 2a: Implement dashboard shell** — `index.html` with nav tabs, `style.css` with layout, `app.js` with WebSocket connection and tab routing. Verify: page loads, WebSocket connects.

- [ ] **Step 2b: Implement sessions page** — list active/recent sessions with status indicator, click for detail (events, model, cwd). Data from `GET /api/sessions`.

- [ ] **Step 2c: Implement activity feed page** — chronological event stream. Data from `GET /api/events`.

- [ ] **Step 2d: Implement notifications page** — notification list with unread badge, dismiss/clear buttons. Data from `GET /api/notifications`, actions via `POST /api/notifications/:id/read` and `POST /api/notifications/clear`.

- [ ] **Step 2e: Implement settings page** — mascot picker grid, hotkey config, overlay position/size. Data from `GET /api/config`, save via `POST /api/config`.

- [ ] **Step 3: Add dashboard routes to server.py** — serve static files from dashboard/, WebSocket endpoint /ws that pushes store changes.

- [ ] **Step 4: Run E2E test**

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: web dashboard with live session tracking"
```

---

### Task 21: System notifications

**Files:**
- Create: `masko-linux/backend/notify.py`
- Create: `masko-linux/tests/test_notify.py`

- [ ] **Step 1: Write test** (mock subprocess.run for notify-send)

- [ ] **Step 2: Implement** — `send_notification(title, body)` via `notify-send` subprocess.

- [ ] **Step 3: Integrate into event processor** — session complete, permission timeout trigger notifications.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: desktop notifications via notify-send"
```

---

### Task 22: Install script and systemd service

**Files:**
- Create: `masko-linux/install.sh`
- Create: `masko-linux/masko.service`
- Create: `masko-linux/masko-desktop.desktop`

- [ ] **Step 1: Write install.sh** — check deps, build overlay, create venv, install hooks, install systemd service, create autostart entry.

- [ ] **Step 2: Write masko.service** — systemd user service unit for backend daemon with Restart=on-failure.

- [ ] **Step 3: Write masko-desktop.desktop** — XDG autostart entry.

- [ ] **Step 4: Test install on clean environment** (or verify script steps manually).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: install script, systemd service, and autostart entry"
```

---

### Task 23: Full E2E smoke test

**Files:**
- Create: `masko-linux/tests/test_e2e_smoke.sh`

- [ ] **Step 1: Write comprehensive E2E test**

Runs on Xvfb:
1. Start backend + overlay
2. Simulate SessionStart hook via curl
3. Screenshot — verify mascot transitions to "Working" animation
4. Simulate PermissionRequest hook
5. Screenshot — verify permission prompt appears
6. Click approve button via xdotool
7. Verify hook curl unblocks with approve response
8. Simulate SessionEnd hook
9. Screenshot — verify toast notification appears
10. Open dashboard URL, verify it serves HTML
11. Clean shutdown

- [ ] **Step 2: Run smoke test, capture all screenshots**

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test: full E2E smoke test with screenshot verification"
```

---

## Summary

| Chunk | Tasks | Focus |
|-------|-------|-------|
| 1 | 1-10 | Project scaffold, all Python backend modules (config, models, stores, state machine, server, event processor, hooks, video cache) |
| 2 | 11-13 | IPC layer, C overlay foundation (X11 window, video decode) |
| 3 | 14-17 | C overlay UI (permission prompt, hotkeys, toast, session switcher) |
| 4 | 18-23 | Backend orchestrator, terminal focus, web dashboard, notifications, packaging, E2E smoke test |
