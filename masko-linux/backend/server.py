import json
from aiohttp import web
from backend.models import ClaudeEvent
from backend.stores.event import EventStore
from backend.stores.session import SessionStore
from backend.stores.notification import NotificationStore
from backend.stores.permission import PendingPermissionStore
from backend.config import Config


def create_app(config=None):
    app = web.Application()
    app["config"] = config or Config()
    app["event_store"] = EventStore()
    app["session_store"] = SessionStore()
    app["notification_store"] = NotificationStore()
    app["permission_store"] = PendingPermissionStore()
    app["state_machine"] = None

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
        from backend.state_machine import ConditionValue
        name = data.get("name", "")
        value = data.get("value")
        sm.set_input(name, ConditionValue(value))

    return web.Response(text="ok")
