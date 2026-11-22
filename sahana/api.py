"""SAHANA care coordination and consent-controlled camera API."""
import asyncio
import errno
import logging
import os
import sqlite3
from contextlib import asynccontextmanager, closing, contextmanager, suppress
from datetime import datetime
from ipaddress import ip_address
from pathlib import Path
from secrets import compare_digest
from time import time
from typing import Annotated, Literal
from uuid import uuid4

if os.name == "nt":
    import msvcrt
else:
    import fcntl

from fastapi import APIRouter, FastAPI, Header, HTTPException, Query, Request, Security
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

from .camera import CameraRelay, FRAME_HEADERS, LEASE_SECONDS, MAX_FRAME_BYTES, validate_jpeg
from .routines import (
    APPROVED_ROOM, BUILTIN_ROUTINES, MAX_COVERAGE_SECONDS, MOTION_LABELS, OPTIONAL_MOVEMENT_SOURCES,
    ZONE, explain, explain_optional, format_minutes, minutes, routine_signal, signal_for, window,
)
from .web import CAMERA_TEST_HEADERS, DOC_HEADERS, LOGO, WORDMARK, reference

START = int(datetime(2026, 11, 21, 9, 35, tzinfo=ZONE).timestamp())
PEOPLE = (("mei", "Mei", 1), ("ari", "Ari", 0))
ASSISTANCE_PREVIEW = "Assistance requested"
HIGH_REVIEW_PREVIEW = "High priority check-in review"
DETECTION_REVIEW = "Ten minutes of verified observation triggered a review."
RECENT_EVENTS = 250
LOGGER = logging.getLogger(__name__)
SCHEMA = Path(__file__).with_name("schema.sql").read_text()
CHECKIN_SCHEMA = next(statement for statement in SCHEMA.split(";")
                      if statement.lstrip().startswith("CREATE TABLE IF NOT EXISTS checkins "))
CareKind = Literal["medication", "meal", "hydration", "toileting"]
EventKind = Literal["presence", "activity", "breakfast", "routine", "facial", "motion"]
SEAT_TRANSITIONS = ("rise_from_seat", "lower_to_seat")
LocalTime = Annotated[str, Field(pattern=r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")]
CameraSessionHeader = Annotated[str | None, Header(alias="X-SAHANA-Camera-Session", max_length=100)]
EVENT_OBSERVATIONS = {
    "presence": {"present", "absent", "missing"},
    "activity": {"active", "inactive", "missing"},
    "breakfast": {"completed", "missing"},
    "routine": {"completed", "missing"},
    "facial": {"movement"},
    "motion": {*MOTION_LABELS, "missing"},
}


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Reset(Input):
    detector: Literal["fixed", "personalized"] = "personalized"
    response_seconds: int = Field(default=120, ge=1, le=86400)


class Clock(Input):
    seconds: int = Field(ge=1, le=86400 * 30)


class Event(Input):
    id: str = Field(min_length=1, max_length=100)
    person: str
    kind: EventKind
    observation: Literal[
        "present", "absent", "active", "inactive", "completed", "missing", "movement",
        "still_in_view", "seated_reposition", "reach_or_lean", "rise_from_seat", "lower_to_seat",
        "seated_transfer", "stepping", "other_expected_motion", "zone_enter", "zone_exit", "seated_travel",
    ]
    source: Literal["manual", "scripted", "optional_movement", "camera", "staged_facial"]
    observed_at: AwareDatetime
    coverage_start: AwareDatetime | None = Field(
        default=None, description="Start of a known or explicitly missing optional observation, up to 60 seconds before observed_at."
    )
    room: str | None = Field(default=None, max_length=100)
    routine: str | None = Field(default=None, min_length=1, max_length=100)
    setting: Literal["shared_space", "bathroom", "personal_care"] | None = None


class Monitoring(Input):
    movement: bool | None = None
    facial: bool | None = None
    paused: bool | None = None
    camera: bool | None = None
    recording: bool | None = None


class Profile(Input):
    name: str = Field(min_length=1, max_length=80)
    self_medication: bool = False
    breakfast_start: LocalTime | None = None
    breakfast_end: LocalTime | None = None


class RoutineWindow(Input):
    start: LocalTime
    end: LocalTime
    name: str | None = Field(default=None, min_length=1, max_length=100)


class ProfileName(Input):
    name: str = Field(min_length=1, max_length=80)


class Preference(Input):
    label: str = Field(min_length=1, max_length=100)
    at: LocalTime


class Chat(Input):
    sender: Literal["patient", "caregiver"]
    message: str = Field(min_length=1, max_length=500)
    id: str = Field(default_factory=lambda: uuid4().hex, min_length=1, max_length=100)


class CameraSession(Input):
    setting: Literal["shared_space"]


class Reply(Input):
    response: Literal["okay", "help", "snooze"]
    snooze_seconds: int = Field(default=60, ge=1, le=3600)


class Schedule(Input):
    person: str
    kind: CareKind
    label: str = Field(min_length=1, max_length=100)
    due_at: AwareDatetime
    deadline: AwareDatetime
    priority: int = Field(default=2, ge=1, le=3)
    self_managed: bool = False


class Help(Input):
    person: str
    kind: Literal["general", "toileting", "meal", "hydration", "medication"] = "general"
    id: str = Field(default_factory=lambda: uuid4().hex, min_length=1, max_length=100)


class TaskUpdate(Input):
    action: Literal["acknowledge", "priority", "resolve", "confirm_medication", "deadline"]
    priority: int | None = Field(default=None, ge=1, le=3)
    deadline: AwareDatetime | None = None


def fail(code, message):
    raise HTTPException(code, message)


def first(db, query, args=()):
    return db.execute(query, args).fetchone()


def require(db, table, identifier):
    # Table names are constants supplied by the routes.
    row = first(db, f"SELECT * FROM {table} WHERE id = ?", (identifier,))
    if row is None:
        fail(404, "Record not found.")
    return row


def seed(db, settings):
    for table in ("notifications", "tasks", "checkins", "events", "routine_windows", "chat_messages",
                  "routine_preferences", "people", "config"):
        db.execute(f"DELETE FROM {table}")
    db.execute("INSERT INTO config (id, now, detector, response_seconds) VALUES (1, ?, ?, ?)",
               (START, settings.detector, settings.response_seconds))
    db.executemany("INSERT INTO people (id, name, self_medication) VALUES (?, ?, ?)", PEOPLE)


def add_task(db, identifier, person, kind, label, reason, now, deadline, priority=2, due=None,
             event_reason=None, self_managed=False):
    db.execute(
        """INSERT OR IGNORE INTO tasks
        (id, person, kind, label, reason, priority, deadline, created_at, due_at, event_reason, self_managed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (identifier, person, kind, label, reason, priority, deadline, now, due, event_reason, self_managed),
    )


def preview(db, identifier, now, message=ASSISTANCE_PREVIEW):
    db.execute("INSERT OR IGNORE INTO notifications (id, created_at, message) VALUES (?, ?, ?)",
               (identifier, now, message))


def review(db, checkin, now, requested_help):
    identifier = "review-" + checkin["id"]
    reason = "Asked for help during a check-in." if requested_help else "Check-in unanswered."
    event = first(db, "SELECT source FROM events WHERE id = ?", (checkin["event_id"],))
    high = event is not None and event["source"] in OPTIONAL_MOVEMENT_SOURCES
    add_task(db, identifier, checkin["person"], "review", "Check-in review",
             reason, now, now + 300, priority=3 if high else 2, event_reason=checkin["reason"])
    if requested_help:
        db.execute("""UPDATE tasks SET reason = ?,
                   created_at = CASE WHEN resolved_at IS NOT NULL THEN ? ELSE created_at END,
                   deadline = CASE WHEN resolved_at IS NOT NULL THEN ? ELSE deadline END,
                   acknowledged_at = CASE WHEN resolved_at IS NOT NULL THEN NULL ELSE acknowledged_at END,
                   resolved_at = NULL WHERE id = ? AND reason = ?""",
                   (reason, now, now + 300, identifier, DETECTION_REVIEW))
        db.execute("UPDATE notifications SET message = ?, created_at = ? WHERE id = ? AND message = ?",
                   (ASSISTANCE_PREVIEW, now, identifier, HIGH_REVIEW_PREVIEW))
        preview(db, identifier, now)
    elif high:
        db.execute("UPDATE tasks SET reason = ? WHERE id = ? AND reason = ? AND resolved_at IS NULL",
                   (reason, identifier, DETECTION_REVIEW))
        preview(db, identifier, now, HIGH_REVIEW_PREVIEW)


def advance_checkins(db, now):
    for checkin in db.execute(
        "SELECT * FROM checkins WHERE state IN ('open', 'snoozed') AND expires_at <= ?", (now,)
    ).fetchall():
        # Use the actual expiration as the task's creation time on a clock jump.
        review(db, checkin, checkin["expires_at"], False)
        db.execute("UPDATE checkins SET state = 'unanswered' WHERE id = ?", (checkin["id"],))
    db.execute("UPDATE checkins SET state = 'open' WHERE state = 'snoozed' AND opens_at <= ?", (now,))


def record_checkin_reply(db, checkin, data):
    if checkin["state"] not in {"open", "snoozed"}:
        if checkin["state"] == data.response:
            return checkin
        fail(409, "Check-in is already closed.")
    config = require(db, "config", 1)
    now, identifier = config["now"], checkin["id"]
    if data.response == "snooze":
        if checkin["state"] == "snoozed":
            return checkin
        opens = now + data.snooze_seconds
        db.execute("UPDATE checkins SET state = 'snoozed', opens_at = ?, expires_at = ? WHERE id = ?",
                   (opens, opens + config["response_seconds"], identifier))
    else:
        if data.response == "help":
            review(db, checkin, now, True)
        else:
            db.execute("UPDATE tasks SET resolved_at = ? WHERE id = ? AND reason = ? AND resolved_at IS NULL",
                       (now, "review-" + identifier, DETECTION_REVIEW))
        db.execute("UPDATE checkins SET state = ? WHERE id = ?", (data.response, identifier))
    return require(db, "checkins", identifier)


def task_view(task, now):
    result = dict(task)
    result["wait_seconds"] = max(0, (task["resolved_at"] or now) - task["created_at"])
    result["remaining_seconds"] = task["deadline"] - now
    due = task["due_at"]
    if task["resolved_at"] is not None:
        status = "Completed"
    elif due is None:
        status = "Acknowledged" if task["acknowledged_at"] is not None else "Open"
    elif now < due:
        status = "Upcoming"
    elif now > task["deadline"]:
        status = "Overdue"
    else:
        status = "Due"
    result["status"] = status
    return result


def person_view(person, detector, windows=None):
    result = {key: person[key] for key in ("id", "name", "movement", "facial", "paused", "self_medication")}
    result.update(camera=bool(person["camera"]), recording=bool(person["recording"]))
    if windows is None:
        bounds = window(person["id"], detector)
    else:
        breakfast = windows.get("breakfast")
        bounds = breakfast[:2] if breakfast else None
        result["routine_windows"] = {
            signal: {"start": format_minutes(start), "end": format_minutes(end)} | ({"name": name} if name else {})
            for signal, (start, end, name) in windows.items()
        }
    result["breakfast_window"] = "–".join(map(format_minutes, bounds)) if bounds is not None else "Unconfigured"
    return result


def event_view(row):
    result = {key: row[key] for key in row.keys() if key not in {"movement_session", "cursor"}}
    if row["kind"] == "motion" and row["observation"] in MOTION_LABELS:
        result["movement_label"] = MOTION_LABELS[row["observation"]]
    return result


def checkin_view(row):
    return {"prompt": "Would you like help?", **dict(row)}


def patient_checkin_view(row):
    checkin = checkin_view(row)
    return {key: checkin[key] for key in ("id", "person", "state", "prompt", "opens_at", "expires_at")}


def reminder_view(task, now):
    return {"id": task["id"], "due_at": task["due_at"], "deadline": task["deadline"],
            "acknowledged_at": task["reminder_acknowledged_at"], "status": task_view(task, now)["status"]}


def add_column(db, table, name, declaration):
    if name in {row["name"] for row in db.execute(f"PRAGMA table_info({table})")}:
        return False
    db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")
    return True


def create_app(path=None, *, mode=None, token=None, clock=time, camera_relay=None, camera_test=False):
    mode = mode or os.environ.get("SAHANA_MODE", "demo")
    if mode not in {"live", "demo"}:
        raise ValueError("SAHANA_MODE must be live or demo.")
    live = mode == "live"
    if camera_test and not live:
        raise ValueError("The camera test requires the authenticated live API.")
    database = path or os.environ.get("SAHANA_DB") or ("sahana-live.sqlite3" if live else "sahana.sqlite3")
    token = token if token is not None else os.environ.get("SAHANA_API_TOKEN", "")
    if live and (len(token) < 24 or not token.isascii() or any(value.isspace() for value in token)):
        raise ValueError("Live mode requires a local SAHANA_API_TOKEN of at least 24 characters.")
    camera = camera_relay if camera_relay is not None else CameraRelay()
    bearer = HTTPBearer(auto_error=False, scheme_name="SAHANA local bearer")

    def local_client(request: Request):
        try:
            address = ip_address(request.client.host) if request.client else None
        except ValueError:
            address = None
        if address is None or not address.is_loopback:
            fail(403, "Open SAHANA on this computer using its loopback address.")

    def authorize(
        request: Request,
        response: Response,
        credential: Annotated[HTTPAuthorizationCredentials | None, Security(bearer)],
    ):
        local_client(request)
        if credential is None or not compare_digest(token.encode(), credential.credentials.encode()):
            raise HTTPException(401, "A valid local bearer token is required.",
                                headers={"WWW-Authenticate": "Bearer"})
        response.headers.update(FRAME_HEADERS)

    @contextmanager
    def transaction(*, tick=True):
        # Serializes clock, deduplication and state transitions across concurrent requests.
        db = sqlite3.connect(database, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            db.execute("PRAGMA foreign_keys = ON")
            db.execute("PRAGMA secure_delete = ON")
            db.execute("BEGIN IMMEDIATE")
            with db:
                if live and tick:
                    now = int(clock())
                    db.execute("UPDATE config SET now = ? WHERE id = 1 AND now != ?", (now, now))
                    advance_checkins(db, now)
                yield db
        finally:
            db.close()

    @contextmanager
    def database_guard():
        if not live:
            yield
            return
        filename = os.path.abspath(database)
        lock_path = filename + ".lock"
        no_follow = getattr(os, "O_NOFOLLOW", 0)
        lock = os.open(lock_path, os.O_CREAT | os.O_RDWR | no_follow, 0o600)
        try:
            try:
                if os.name == "nt":
                    msvcrt.locking(lock, msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno not in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
                    raise
                raise RuntimeError("A SAHANA live server already owns this database.") from error
            db_file = os.open(filename, os.O_CREAT | os.O_WRONLY | no_follow, 0o600)
            try:
                if hasattr(os, "fchmod"):
                    os.fchmod(db_file, 0o600)
            finally:
                os.close(db_file)
            yield
        finally:
            os.close(lock)

    def initialize():
        with closing(sqlite3.connect(database, timeout=10)) as db:
            if first(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'config'"):
                columns = {row[1] for row in db.execute("PRAGMA table_info(config)")}
                existing = first(db, "SELECT run_mode FROM config" if "run_mode" in columns else "SELECT 'demo' FROM config")
                if existing and existing[0] != mode:
                    raise RuntimeError("Use separate databases for live and demo modes.")
            db.executescript(SCHEMA)
        with transaction(tick=False) as db:
            add_column(db, "config", "run_mode", "TEXT NOT NULL DEFAULT 'demo'")
            add_column(db, "routine_windows", "name", "TEXT")
            add_column(db, "people", "camera", "INTEGER NOT NULL DEFAULT 0")
            add_column(db, "people", "recording", "INTEGER NOT NULL DEFAULT 0")
            if add_column(db, "people", "self_medication", "INTEGER NOT NULL DEFAULT 0"):
                db.execute("UPDATE people SET self_medication = 1 WHERE id = 'mei'")
            add_column(db, "people", "movement_session", "INTEGER NOT NULL DEFAULT 0")
            if add_column(db, "people", "movement_session_start", "INTEGER"):
                db.execute("""UPDATE people SET movement_session_start = (SELECT now FROM config WHERE id = 1)
                            WHERE movement = 1 AND paused = 0""")
            add_column(db, "events", "routine", "TEXT")
            if add_column(db, "events", "setting", "TEXT"):
                db.execute("UPDATE events SET setting = 'shared_space' WHERE source = 'staged_facial'")
            has_new_gate = add_column(db, "events", "coverage_start", "INTEGER")
            add_column(db, "events", "movement_session", "INTEGER")
            add_column(db, "tasks", "event_reason", "TEXT")
            add_column(db, "tasks", "self_managed", "INTEGER NOT NULL DEFAULT 0")
            add_column(db, "tasks", "reminder_acknowledged_at", "INTEGER")
            add_column(db, "notifications", "message", "TEXT NOT NULL DEFAULT 'Assistance requested'")
            if "signal" not in {row["name"] for row in db.execute("PRAGMA table_info(checkins)")}:
                db.execute("ALTER TABLE checkins RENAME TO legacy_checkins")
                db.execute(CHECKIN_SCHEMA)
                db.execute("""INSERT INTO checkins
                    SELECT legacy_checkins.*,
                      CASE events.kind WHEN 'presence' THEN 'common_room_presence'
                        WHEN 'activity' THEN 'common_room_activity' WHEN 'routine' THEN 'lunch'
                        ELSE 'breakfast' END
                    FROM legacy_checkins LEFT JOIN events ON legacy_checkins.event_id = events.id""")
                db.execute("DROP TABLE legacy_checkins")
            if has_new_gate:
                db.execute("""UPDATE checkins SET state = 'cancelled'
                    WHERE state IN ('open', 'snoozed') AND event_id IN
                    (SELECT id FROM events WHERE source = 'optional_movement')""")
            db.execute("""CREATE INDEX IF NOT EXISTS events_movement_session ON events
                        (person, movement_session, source, observed_at) WHERE optional = 1""")
            if first(db, "SELECT id FROM config") is None:
                if live:
                    db.execute("""INSERT INTO config (id, now, detector, response_seconds, run_mode)
                                  VALUES (1, ?, 'personalized', 120, 'live')""", (int(clock()),))
                else:
                    seed(db, Reset())

    def service_tick():
        camera.expire()
        with transaction():
            pass

    async def live_clock():
        while True:
            await asyncio.sleep(1)
            try:
                await asyncio.to_thread(service_tick)
            except sqlite3.Error:
                LOGGER.exception("Could not update the live care clock")

    @asynccontextmanager
    async def lifespan(_):
        with database_guard():
            initialize()
            ticker = asyncio.create_task(live_clock()) if live else None
            try:
                yield
            finally:
                if ticker:
                    ticker.cancel()
                    with suppress(asyncio.CancelledError):
                        await ticker

    app = FastAPI(title="SAHANA", description="Loopback care coordination and local camera controls.",
                  lifespan=lifespan, docs_url=None, redoc_url=None)
    app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]"])
    api = APIRouter(dependencies=[Security(authorize)] if live else [])

    def require_live():
        if not live:
            fail(404, "This feature is available in live mode.")

    def profile_windows(db, person):
        return {
            row["signal"]: (row["starts"], row["ends"], row["name"])
            for row in db.execute("SELECT signal, starts, ends, name FROM routine_windows WHERE person = ?", (person,))
        }

    def view_profile(db, row, detector):
        return person_view(row, detector, profile_windows(db, row["id"]) if live else None)

    def set_window(db, person, signal, start, end, name=None):
        starts, ends = minutes(start), minutes(end)
        if ends <= starts:
            fail(422, "The end of the routine window must be later on the same day.")
        db.execute("""INSERT INTO routine_windows (person, signal, starts, ends, name) VALUES (?, ?, ?, ?, ?)
                      ON CONFLICT(person, signal) DO UPDATE SET starts = excluded.starts, ends = excluded.ends,
                      name = COALESCE(excluded.name, routine_windows.name)""", (person, signal, starts, ends, name))

    @app.get("/", include_in_schema=False)
    def home():
        return RedirectResponse("/docs")

    @app.get("/docs", include_in_schema=False, response_class=HTMLResponse)
    def documentation(request: Request):
        return HTMLResponse(
            reference(app.openapi(), mode, str(request.base_url).rstrip("/"), camera_test=camera_test),
            headers=DOC_HEADERS,
        )

    if camera_test:
        @app.get("/camera-test", include_in_schema=False)
        def camera_test_page(request: Request):
            local_client(request)
            return FileResponse(Path(__file__).with_name("camera_test.html"), media_type="text/html",
                                headers=CAMERA_TEST_HEADERS)

        @app.get("/camera-test.js", include_in_schema=False)
        def camera_test_script(request: Request):
            local_client(request)
            return FileResponse(Path(__file__).with_name("camera_test.js"), media_type="text/javascript",
                                headers=FRAME_HEADERS)

    @app.get("/logo.png", include_in_schema=False)
    def logo():
        return FileResponse(LOGO, media_type="image/png", headers={"X-Content-Type-Options": "nosniff"})

    @app.get("/wordmark.png", include_in_schema=False)
    def wordmark():
        return FileResponse(WORDMARK, media_type="image/png", headers={"X-Content-Type-Options": "nosniff"})

    @app.get("/status", tags=["Service"])
    def status(request: Request):
        """Check service mode and its Asia/Shanghai clock without reading care records."""
        if live:
            local_client(request)
            now = int(clock())
        else:
            with transaction() as db:
                now = require(db, "config", 1)["now"]
        return {"mode": mode, "now": now, "timezone": str(ZONE)}

    @api.post("/demo/reset", tags=["Demo"], include_in_schema=not live)
    def reset(data: Reset):
        """Reset the synthetic database and clock."""
        if live:
            fail(404, "Live records cannot be reset from the API.")
        with transaction() as db:
            seed(db, data)
            return dict(require(db, "config", 1))

    @api.post("/demo/clock", tags=["Demo"], include_in_schema=not live)
    def advance(data: Clock):
        """Advance simulated time and process check-ins."""
        if live:
            fail(404, "Live mode uses the Mac's clock.")
        with transaction() as db:
            now = require(db, "config", 1)["now"] + data.seconds
            db.execute("UPDATE config SET now = ?", (now,))
            advance_checkins(db, now)
            return {"now": now}

    @api.get("/demo", tags=["Demo"], include_in_schema=not live)
    def demo_status():
        """Read the current demo clock, detector and check-in response window."""
        with transaction() as db:
            return dict(require(db, "config", 1)) | {"mode": mode}

    @api.get("/events", tags=["Routines"])
    def observations(
        person: str | None = None,
        kind: EventKind | None = None,
        before: Annotated[int | None, Query(gt=0)] = None,
        limit: Annotated[int, Query(ge=1, le=500)] = 100,
    ):
        """List observations newest first. Filter by person and kind=motion to review seat transitions and other movements."""
        with transaction() as db:
            filters, arguments = [], []
            if person is not None:
                require(db, "people", person)
                filters.append("person = ?")
                arguments.append(person)
            if kind is not None:
                filters.append("kind = ?")
                arguments.append(kind)
            if before is not None:
                filters.append("rowid < ?")
                arguments.append(before)
            where = " WHERE " + " AND ".join(filters) if filters else ""
            rows = db.execute("SELECT rowid AS cursor, * FROM events" + where + " ORDER BY rowid DESC LIMIT ?",
                              (*arguments, limit + 1)).fetchall()
            return {
                "events": [event_view(row) for row in rows[:limit]],
                "next_before": rows[limit - 1]["cursor"] if len(rows) > limit else None,
            }

    @api.post("/events", tags=["Routines"])
    def record(data: Event, camera_session: CameraSessionHeader = None):
        """Record observations, including rise_from_seat and lower_to_seat as distinct motion values. Camera observations require the active session header."""
        if live and data.source not in {"manual", "camera"}:
            fail(422, "Live mode accepts staff-entered or active camera observations.")
        if data.observation not in EVENT_OBSERVATIONS[data.kind]:
            fail(422, "Observation does not match its event kind.")
        if (data.kind == "facial") != (data.source == "staged_facial"):
            fail(422, "Facial observations use the staged_facial source.")
        optional_movement = data.source in OPTIONAL_MOVEMENT_SOURCES
        if optional_movement and data.kind not in {"presence", "activity", "motion"}:
            fail(422, "Optional movement sources record presence, activity and movement labels.")
        if data.kind == "motion" and not optional_movement:
            fail(422, "Movement labels use an optional movement source.")
        if data.routine is not None and data.kind != "routine":
            fail(422, "A routine name is accepted only for a routine event.")
        if data.kind == "facial" and (data.setting != "shared_space" or data.room is not None):
            fail(422, "Staged facial events require a shared-space setting and omit room details.")
        room = data.room
        if optional_movement:
            if data.setting != "shared_space" or (room or "").casefold() != APPROVED_ROOM.casefold():
                fail(422, "Optional movement is limited to the approved common room in a shared-space setting.")
            room = APPROVED_ROOM
        observed = int(data.observed_at.timestamp())
        began = None
        if data.coverage_start is not None:
            if not optional_movement or data.kind not in {"presence", "activity"}:
                fail(422, "Coverage intervals apply to optional presence and activity observations.")
            began = int(data.coverage_start.timestamp())
            if not 0 < observed - began <= MAX_COVERAGE_SECONDS:
                fail(422, f"A coverage interval must have a duration of 1 to {MAX_COVERAGE_SECONDS} seconds.")
        with transaction() as db:
            person = require(db, "people", data.person)
            config = require(db, "config", 1)
            now = config["now"]
            if observed > now:
                fail(422, "Observation is ahead of the service clock.")
            evidence_start = observed if began is None else began
            if live and data.source == "camera":
                started_at = camera.authorize(data.person, camera_session)
                if evidence_start < started_at:
                    fail(409, "Observation is from before the active camera session.")
            prior = first(db, "SELECT * FROM events WHERE id = ?", (data.id,))
            if prior:
                if (data.person, data.kind, data.observation, data.source, room, observed,
                    data.routine, data.setting, began) != tuple(
                    prior[key] for key in ("person", "kind", "observation", "source", "room", "observed_at",
                                           "routine", "setting", "coverage_start")
                ):
                    fail(409, "Event ID already belongs to a different observation.")
                return event_view(prior) | {"duplicate": True}
            optional = optional_movement or data.source == "staged_facial"
            if optional and (person["paused"] or not person["facial" if data.kind == "facial" else "movement"]):
                fail(409, "Optional monitoring is off or paused.")
            calibration = profile_windows(db, data.person) if live else {}

            def get_window(identifier, detector, signal):
                if live:
                    configured = calibration.get(signal)
                    return configured[:2] if configured else None
                return window(identifier, detector, signal)

            session = None
            if optional_movement:
                session = person["movement_session"]
                session_start = person["movement_session_start"]
                if session_start is None or evidence_start < session_start:
                    fail(409, "Observation is from before the active monitoring session.")
                evidence = []
                if began is not None and data.observation in {"absent", "inactive"}:
                    local = datetime.fromtimestamp(observed, ZONE)
                    midnight = int(local.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
                    evidence = db.execute("""SELECT kind, observation, coverage_start, observed_at FROM events
                        WHERE optional = 1 AND person = ? AND movement_session = ? AND source = ?
                          AND observed_at >= ? AND observed_at < ?""",
                        (data.person, session, data.source, midnight, midnight + 86400),
                    ).fetchall()
                    evidence.append({"kind": data.kind, "observation": data.observation,
                                     "coverage_start": began, "observed_at": observed})
                reason, flagged = explain_optional(
                    data.person, data.kind, data.observation, observed, config["detector"], evidence, get_window=get_window,
                    live=live,
                )
            else:
                calibrated = calibration.get(signal_for(data.kind, room, data.routine))
                reason, flagged = explain(data.person, data.kind, data.observation, observed, config["detector"],
                                          room=room, routine=data.routine, get_window=get_window,
                                          routine_name=calibrated[2] if calibrated else None,
                                          single_observation_alert=not live)
            db.execute("""INSERT INTO events
                (id, person, kind, observation, source, room, observed_at, recorded_at, reason, flagged, optional,
                 routine, setting, coverage_start, movement_session)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""", (
                data.id, data.person, data.kind, data.observation, data.source,
                room, observed, now, reason, flagged, optional, data.routine, data.setting, began, session,
            ))
            # Historical entries remain reviewable without opening a new check-in.
            day = datetime.fromtimestamp(observed, ZONE).date()
            timely = not optional_movement or now - observed <= MAX_COVERAGE_SECONDS
            if flagged and timely and day == datetime.fromtimestamp(now, ZONE).date():
                checkin_id = uuid4().hex
                opened = db.execute(
                    """INSERT INTO checkins VALUES (?, ?, ?, ?, ?, 'open', ?, ?, ?)
                    ON CONFLICT(person, routine_day, signal) DO NOTHING""",
                    (checkin_id, data.person, data.id, day.isoformat(), reason, now,
                     now + config["response_seconds"], signal_for(data.kind, room, data.routine)),
                ).rowcount
                if opened and live and optional_movement:
                    task_id = "review-" + checkin_id
                    add_task(db, task_id, data.person, "review", "Check-in review", DETECTION_REVIEW,
                             now, now + 300, priority=3, event_reason=reason)
                    preview(db, task_id, now, HIGH_REVIEW_PREVIEW)
            return event_view(require(db, "events", data.id)) | {"duplicate": False}

    @api.get("/checkins", tags=["Check-ins"])
    def checkins():
        """List check-ins and their response state."""
        with transaction() as db:
            return [checkin_view(row) for row in db.execute(
                "SELECT * FROM checkins ORDER BY opens_at, id"
            )]

    @api.post("/checkins/{identifier}/response", tags=["Check-ins"])
    def respond(identifier: str, data: Reply):
        """Accept okay, help or snooze for a pending check-in."""
        with transaction() as db:
            return dict(record_checkin_reply(db, require(db, "checkins", identifier), data))

    @api.patch("/people/{person}/monitoring", tags=["Privacy"])
    def monitoring(person: str, data: Monitoring):
        """Control optional movement, camera, and recording permissions, or pause monitoring."""
        if data.camera is not None or data.recording is not None:
            require_live()
        with transaction() as db:
            previous = require(db, "people", person)
            changes = data.model_dump(exclude_none=True)
            if live:
                if changes.get("recording") and not changes.get("camera", previous["camera"]):
                    fail(422, "Allow the live camera before approving recordings.")
                if changes.get("camera") is False:
                    changes["recording"] = False
            for field, value in changes.items():
                db.execute(f"UPDATE people SET {field} = ? WHERE id = ?", (value, person))
            state = require(db, "people", person)
            config = require(db, "config", 1)
            was_active = previous["movement"] and not previous["paused"]
            is_active = state["movement"] and not state["paused"]
            if is_active and not was_active:
                db.execute("""UPDATE people SET movement_session = movement_session + 1,
                            movement_session_start = ? WHERE id = ?""", (config["now"], person))
            if not is_active:
                db.execute("UPDATE people SET movement_session_start = NULL WHERE id = ?", (person,))
                db.execute(
                    """UPDATE checkins SET state = 'cancelled'
                    WHERE state IN ('open', 'snoozed') AND event_id IN
                    (SELECT id FROM events WHERE person = ? AND source IN ('optional_movement', 'camera'))""",
                    (person,),
                )
            if live and (state["paused"] or not state["camera"]):
                camera.revoke(person)
                db.execute("""UPDATE checkins SET state = 'cancelled'
                    WHERE state IN ('open', 'snoozed') AND event_id IN
                    (SELECT id FROM events WHERE person = ? AND source = 'camera')""", (person,))
            if live and (not is_active or not state["camera"]):
                db.execute("""UPDATE tasks SET resolved_at = ? WHERE reason = ? AND resolved_at IS NULL AND id IN (
                    SELECT 'review-' || id FROM checkins WHERE person = ? AND state = 'cancelled')""",
                           (config["now"], DETECTION_REVIEW, person))
            return view_profile(db, state, config["detector"])

    @api.get("/people/{person}/camera", tags=["Camera"], include_in_schema=live)
    def camera_status(person: str):
        """Read stream permissions and observations, with a separate latest_seat_transition when recorded in this session."""
        require_live()
        with transaction() as db:
            profile = require(db, "people", person)
            active, frame_available, started = camera.state(person)
            allowed = bool(profile["camera"] and not profile["paused"])
            latest = seat_transition = None
            movement_allowed = bool(allowed and profile["movement"])
            if active and movement_allowed:
                latest = first(db, """SELECT kind, observation, observed_at, reason FROM events
                    WHERE person = ? AND source = 'camera' AND kind IN ('motion', 'activity', 'presence') AND movement_session = ?
                    AND observed_at >= ? ORDER BY observed_at DESC, rowid DESC LIMIT 1""",
                               (person, profile["movement_session"], started))
                seat_transition = first(db, """SELECT kind, observation, observed_at, reason FROM events
                    WHERE person = ? AND source = 'camera' AND kind = 'motion' AND movement_session = ?
                    AND observed_at >= ? AND observation IN (?, ?) ORDER BY observed_at DESC, rowid DESC LIMIT 1""",
                                        (person, profile["movement_session"], started, *SEAT_TRANSITIONS))
            result = {
                "allowed": allowed, "recording_allowed": bool(allowed and profile["recording"]),
                "movement_allowed": movement_allowed,
                "active": active, "frame_available": frame_available,
                "latest_observation": dict(latest) if latest is not None else None,
            }
            if seat_transition is not None:
                result["latest_seat_transition"] = event_view(seat_transition)
            return result

    @api.post("/people/{person}/camera/session", tags=["Camera"], include_in_schema=live)
    def open_camera(person: str, session: CameraSession):
        """Acquire a local camera lease for an approved shared space."""
        require_live()
        with transaction() as db:
            profile = require(db, "people", person)
            if not profile["camera"] or profile["paused"]:
                fail(403, "This profile has not allowed live video or is paused.")
            now = require(db, "config", 1)["now"]
            identifier = camera.start(person, now)
            if profile["movement"]:
                db.execute("""UPDATE people SET movement_session = movement_session + 1,
                              movement_session_start = ? WHERE id = ?""", (now, person))
            return {"session_id": identifier, "expires_in_seconds": LEASE_SECONDS}

    @api.delete("/people/{person}/camera/session", tags=["Camera"], status_code=204, include_in_schema=live)
    def close_camera(person: str, camera_session: CameraSessionHeader = None):
        """Stop the owner's camera lease and discard its last frame."""
        require_live()
        camera.stop(person, camera_session)
        return Response(status_code=204, headers=FRAME_HEADERS)

    @api.put("/people/{person}/camera/frame", tags=["Camera"], status_code=204, include_in_schema=live,
             openapi_extra={"requestBody": {"required": True, "content": {
                 "image/jpeg": {"schema": {"type": "string", "format": "binary"}},
             }}})
    async def publish_frame(person: str, request: Request, camera_session: CameraSessionHeader = None):
        """Relay one JPEG of up to 512 KiB from a consented camera. Each frame replaces the previous one."""
        require_live()
        camera.authorize(person, camera_session)
        content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
        if content_type != "image/jpeg":
            fail(415, "Send a frame as image/jpeg.")
        contents = bytearray()
        async for chunk in request.stream():
            if len(contents) + len(chunk) > MAX_FRAME_BYTES:
                fail(413, "Resize the JPEG to 512 KiB or less.")
            contents.extend(chunk)
        image = bytes(contents)
        validate_jpeg(image)
        camera.put(person, camera_session, image)
        return Response(status_code=204, headers=FRAME_HEADERS)

    @api.get("/people/{person}/camera/frame", tags=["Camera"], include_in_schema=live, response_class=Response,
             responses={200: {"content": {"image/jpeg": {}}}, 204: {"description": "No fresh frame"}})
    def view_frame(person: str):
        """Read the latest camera frame for the selected profile, when fresh."""
        require_live()
        frame = camera.frame(person)
        if frame is None:
            return Response(status_code=204, headers=FRAME_HEADERS)
        return Response(frame[2], media_type="image/jpeg", headers=FRAME_HEADERS)

    @api.get("/people/{person}/camera/stream", tags=["Camera"], include_in_schema=live, response_class=StreamingResponse,
             responses={200: {"content": {"multipart/x-mixed-replace": {}}}, 204: {"description": "No active camera"}})
    async def view_stream(person: str):
        """Read live JPEG frames as a multipart stream while the profile's camera lease is active."""
        require_live()
        if not camera.state(person)[0]:
            return Response(status_code=204, headers=FRAME_HEADERS)

        async def images():
            sequence = None
            while camera.state(person)[0]:
                current = camera.frame(person)
                if current is not None and current[:2] != sequence:
                    sequence = current[:2]
                    frame = current[2]
                    yield b"--sahana\r\nContent-Type: image/jpeg\r\nContent-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + frame + b"\r\n"
                await asyncio.sleep(0.08)

        return StreamingResponse(images(), media_type="multipart/x-mixed-replace; boundary=sahana",
                                 headers=FRAME_HEADERS)

    @api.delete("/people/{person}/monitoring/history", tags=["Privacy"])
    def clear_history(person: str):
        """Clear optional event history and details copied into any follow-up."""
        with transaction() as db:
            profile = require(db, "people", person)
            if profile["movement"] and not profile["paused"]:
                now = require(db, "config", 1)["now"]
                db.execute("""UPDATE people SET movement_session = movement_session + 1,
                            movement_session_start = ? WHERE id = ?""", (now, person))
            db.execute(
                """DELETE FROM notifications WHERE message = ? AND id IN (
                    SELECT 'review-' || checkins.id FROM checkins JOIN events ON checkins.event_id = events.id
                    WHERE events.person = ? AND events.optional = 1
                )""",
                (HIGH_REVIEW_PREVIEW, person),
            )
            db.execute(
                """UPDATE tasks SET event_reason = NULL WHERE id IN (
                    SELECT 'review-' || checkins.id FROM checkins
                    JOIN events ON checkins.event_id = events.id
                    WHERE events.person = ? AND events.optional = 1
                )""",
                (person,),
            )
            db.execute(
                """DELETE FROM checkins WHERE event_id IN (
                    SELECT id FROM events WHERE person = ? AND optional = 1
                )""",
                (person,),
            )
            removed = db.execute("DELETE FROM events WHERE person = ? AND optional = 1", (person,)).rowcount
            return {"removed": removed}

    @api.post("/schedules", tags=["Daily care"])
    def schedule(data: Schedule):
        """Create a scheduled care occurrence and its staff-set response deadline."""
        due, deadline = int(data.due_at.timestamp()), int(data.deadline.timestamp())
        if deadline < due:
            fail(422, "Response deadline must be at or after the scheduled time.")
        with transaction() as db:
            profile = require(db, "people", data.person)
            if data.self_managed and not (data.kind == "medication" and data.priority == 1 and profile["self_medication"]):
                fail(422, "Self-managed reminders require a low-priority medication schedule for an opted-in profile.")
            now = require(db, "config", 1)["now"]
            identifier = "schedule-" + uuid4().hex
            add_task(db, identifier, data.person, data.kind, data.label, "Scheduled care.",
                     now, deadline, data.priority, due, self_managed=data.self_managed)
            return task_view(require(db, "tasks", identifier), now)

    @api.get("/schedules", tags=["Daily care"])
    def schedules():
        """List scheduled care, including completed entries and administration confirmation."""
        with transaction() as db:
            now = require(db, "config", 1)["now"]
            return [task_view(row, now) for row in db.execute(
                "SELECT * FROM tasks WHERE due_at IS NOT NULL ORDER BY due_at, id"
            )]

    @api.post("/requests", tags=["Daily care"])
    def request_help(data: Help):
        """Request manual assistance even while optional monitoring is paused."""
        with transaction() as db:
            require(db, "people", data.person)
            now = require(db, "config", 1)["now"]
            identifier = "request-" + data.id
            label = "Assistance request" if data.kind == "general" else f"{data.kind.title()} assistance"
            prior = first(db, "SELECT * FROM tasks WHERE id = ?", (identifier,))
            if prior and (prior["person"], prior["label"]) != (data.person, label):
                fail(409, "Request ID already belongs to another request.")
            add_task(db, identifier, data.person, "assistance", label, "Person requested assistance.",
                     now, now + 300)
            if prior is None:
                preview(db, identifier, now)
            return {"submitted": True}

    def active_notifications(db):
        return db.execute(
            """SELECT notifications.id, tasks.person, notifications.message, notifications.created_at
            FROM notifications JOIN tasks ON tasks.id = notifications.id
            WHERE tasks.resolved_at IS NULL ORDER BY notifications.created_at DESC, notifications.rowid DESC"""
        )

    @api.get("/notifications", tags=["Privacy"])
    def notifications():
        """Preview feed deliberately omits names, task IDs and care details."""
        with transaction() as db:
            return [{"message": row["message"], "created_at": row["created_at"]}
                    for row in active_notifications(db)]

    @api.get("/people", tags=["Patient"])
    def profiles():
        """List profile names for the local profile selector."""
        with transaction() as db:
            return [dict(row) for row in db.execute("SELECT id, name FROM people ORDER BY name")]

    @api.post("/people", tags=["Patient"], status_code=201, include_in_schema=live)
    def create_profile(data: Profile):
        """Create a live profile with camera and recording permissions turned off."""
        require_live()
        if (data.breakfast_start is None) != (data.breakfast_end is None):
            fail(422, "Provide both breakfast window times or leave both unset.")
        identifier = uuid4().hex
        with transaction() as db:
            db.execute("INSERT INTO people (id, name, self_medication) VALUES (?, ?, ?)",
                       (identifier, data.name, data.self_medication))
            if data.breakfast_start is not None:
                set_window(db, identifier, "breakfast", data.breakfast_start, data.breakfast_end)
            return view_profile(db, require(db, "people", identifier), "personalized")

    @api.put("/people/{person}/routines/{signal}", tags=["Routines"], include_in_schema=live)
    def set_routine(person: str, signal: str, data: RoutineWindow):
        """Set an existing or named custom routine window in Asia/Shanghai local time."""
        require_live()
        key = routine_signal(signal)
        if not 1 <= len(key) <= 100 or len(signal) > 100:
            fail(422, "Enter a routine name of up to 100 characters and include a letter or digit.")
        if data.name is not None and routine_signal(data.name) != key:
            fail(422, "The display name must match the routine identifier after normalization.")
        name = None if key in BUILTIN_ROUTINES else (data.name or (signal if signal != key else None))
        with transaction() as db:
            profile = require(db, "people", person)
            previous = profile_windows(db, person).get(key)
            set_window(db, person, key, data.start, data.end, name)
            bounds = (minutes(data.start), minutes(data.end))
            if (key in {"common_room_presence", "common_room_activity"}
                    and profile["movement"] and not profile["paused"]
                    and (previous is None or previous[:2] != bounds)):
                now = require(db, "config", 1)["now"]
                db.execute("""UPDATE people SET movement_session = movement_session + 1,
                              movement_session_start = ? WHERE id = ?""", (now, person))
            return view_profile(db, profile, "personalized")

    @api.patch("/people/{person}/profile", tags=["Patient"])
    def rename_profile(person: str, data: ProfileName):
        """Update the preferred display name while keeping the same profile and history."""
        with transaction() as db:
            require(db, "people", person)
            db.execute("UPDATE people SET name = ? WHERE id = ?", (data.name, person))
            return view_profile(db, require(db, "people", person), require(db, "config", 1)["detector"])

    def preference_view(row, now):
        local = datetime.fromtimestamp(now, ZONE)
        return {
            "id": row["id"], "label": row["label"], "at": format_minutes(row["due_minute"]),
            "due_today": local.hour * 60 + local.minute >= row["due_minute"],
            "completed_today": row["completed"] is not None,
        }

    @api.get("/people/{person}/preferences", tags=["Routines"])
    def preferences(person: str):
        """List daily preferences and today's completion state in Shanghai time."""
        with transaction() as db:
            require(db, "people", person)
            now = require(db, "config", 1)["now"]
            day = datetime.fromtimestamp(now, ZONE).date().isoformat()
            rows = db.execute(
                """SELECT p.*, l.routine_day AS completed FROM routine_preferences p
                LEFT JOIN routine_preference_logs l ON l.preference = p.id AND l.routine_day = ?
                WHERE p.person = ? ORDER BY p.due_minute, p.label, p.id""", (day, person)
            )
            return [preference_view(row, now) for row in rows]

    @api.post("/people/{person}/preferences", tags=["Routines"], status_code=201)
    def add_preference(person: str, data: Preference):
        """Add a daily routine preference at the person's chosen local time."""
        with transaction() as db:
            require(db, "people", person)
            identifier = uuid4().hex
            due = minutes(data.at)
            db.execute("INSERT INTO routine_preferences VALUES (?, ?, ?, ?)", (identifier, person, data.label, due))
            row = {"id": identifier, "label": data.label, "due_minute": due, "completed": None}
            return preference_view(row, require(db, "config", 1)["now"])

    def owned_preference(db, person, identifier):
        row = first(db, "SELECT * FROM routine_preferences WHERE id = ? AND person = ?", (identifier, person))
        if row is None:
            fail(404, "Routine preference not found.")
        return row

    @api.delete("/people/{person}/preferences/{identifier}", tags=["Routines"], status_code=204)
    def remove_preference(person: str, identifier: str):
        """Remove the daily preference and retain completed observations in care history."""
        with transaction() as db:
            owned_preference(db, person, identifier)
            db.execute("DELETE FROM routine_preferences WHERE id = ?", (identifier,))
        return Response(status_code=204)

    @api.post("/people/{person}/preferences/{identifier}/complete", tags=["Routines"])
    def complete_preference(person: str, identifier: str):
        """Record today's scheduled routine completion once its time is due."""
        with transaction() as db:
            preference = owned_preference(db, person, identifier)
            now = require(db, "config", 1)["now"]
            local = datetime.fromtimestamp(now, ZONE)
            if local.hour * 60 + local.minute < preference["due_minute"]:
                fail(409, "Today's routine is not due yet.")
            day = local.date().isoformat()
            if db.execute("INSERT OR IGNORE INTO routine_preference_logs VALUES (?, ?)", (identifier, day)).rowcount:
                db.execute(
                    """INSERT INTO events (id, person, kind, observation, source, observed_at, recorded_at,
                       reason, flagged, optional, routine) VALUES (?, ?, 'routine', 'completed', 'manual',
                       ?, ?, ?, 0, 0, ?)""",
                    ("preference-" + identifier + "-" + day, person, now, now,
                     f"{preference['label']} completed. Scheduled for {format_minutes(preference['due_minute'])}.",
                     preference["label"]),
                )
            return preference_view(dict(preference, completed=day), now)

    @api.get("/people/{person}/chat", tags=["Patient"])
    def chat_messages(person: str):
        """Read the latest 100 messages in the selected profile's local conversation."""
        with transaction() as db:
            require(db, "people", person)
            rows = db.execute(
                """SELECT id, sender, message, created_at FROM chat_messages WHERE person = ?
                ORDER BY rowid DESC LIMIT 100""", (person,)
            ).fetchall()
            return [dict(row) for row in reversed(rows)]

    @api.post("/people/{person}/chat", tags=["Patient"], status_code=201)
    def send_chat(person: str, data: Chat):
        """Send a message to the selected profile's local conversation."""
        with transaction() as db:
            require(db, "people", person)
            now = require(db, "config", 1)["now"]
            db.execute(
                "INSERT OR IGNORE INTO chat_messages (person, id, sender, message, created_at) VALUES (?, ?, ?, ?, ?)",
                (person, data.id, data.sender, data.message, now),
            )
            row = first(db, "SELECT id, sender, message, created_at FROM chat_messages WHERE person = ? AND id = ?",
                        (person, data.id))
            if (row["sender"], row["message"]) != (data.sender, data.message):
                fail(409, "Message ID already belongs to another message.")
            return dict(row)

    @api.get("/people/{person}/patient", tags=["Patient"])
    def patient(person: str):
        """Read a single profile's check-ins, optional history and discreet reminders."""
        with transaction() as db:
            profile = require(db, "people", person)
            config = require(db, "config", 1)
            checkins = db.execute(
                "SELECT * FROM checkins WHERE person = ? ORDER BY opens_at DESC, id", (person,),
            )
            reminders = db.execute("""SELECT * FROM tasks WHERE person = ? AND kind = 'medication'
                AND self_managed = 1 AND priority = 1 ORDER BY due_at, id""", (person,)) if profile["self_medication"] else ()
            return {
                "now": config["now"], "mode": mode,
                "person": view_profile(db, profile, config["detector"]),
                "checkins": [patient_checkin_view(row) for row in checkins],
                "events": [event_view(row) for row in db.execute(
                    """SELECT * FROM events WHERE person = ? AND optional = 1
                    ORDER BY recorded_at DESC, rowid DESC LIMIT ?""", (person, RECENT_EVENTS if live else -1),
                )],
                "reminders": [reminder_view(row, config["now"]) for row in reminders],
            }

    @api.post("/people/{person}/checkins/{identifier}/response", tags=["Patient"])
    def respond_as_patient(person: str, identifier: str, data: Reply):
        """Accept a response from the selected profile and return its check-in state."""
        with transaction() as db:
            checkin = first(db, "SELECT * FROM checkins WHERE id = ? AND person = ?", (identifier, person))
            if checkin is None:
                fail(404, "Check-in not found.")
            return patient_checkin_view(record_checkin_reply(db, checkin, data))

    @api.post("/people/{person}/reminders/{identifier}/acknowledge", tags=["Patient"])
    def acknowledge_reminder(person: str, identifier: str):
        """Record the person's reminder acknowledgement independently of staff actions."""
        with transaction() as db:
            profile = require(db, "people", person)
            task = first(db, """SELECT * FROM tasks WHERE id = ? AND person = ? AND kind = 'medication'
                AND self_managed = 1 AND priority = 1""", (identifier, person))
            if not profile["self_medication"] or task is None:
                fail(404, "Reminder not found.")
            now = require(db, "config", 1)["now"]
            if task["resolved_at"] is None:
                db.execute("""UPDATE tasks SET
                    reminder_acknowledged_at = COALESCE(reminder_acknowledged_at, ?) WHERE id = ?""",
                    (now, identifier),
                )
            return reminder_view(require(db, "tasks", identifier), now)

    @api.get("/queue", tags=["Caregiver"])
    def queue():
        """List open tasks ordered by priority, deadline and longest wait."""
        with transaction() as db:
            now = require(db, "config", 1)["now"]
            return [task_view(row, now) for row in db.execute(
                """SELECT * FROM tasks WHERE resolved_at IS NULL
                ORDER BY priority DESC, deadline, created_at, id"""
            )]

    @api.patch("/tasks/{identifier}", tags=["Caregiver"])
    def update_task(identifier: str, data: TaskUpdate):
        """Acknowledge, set priority or deadline, resolve, or confirm administration."""
        with transaction() as db:
            task = require(db, "tasks", identifier)
            now = require(db, "config", 1)["now"]
            action = data.action
            medication = task["kind"] == "medication"
            if task["resolved_at"] is not None:
                if (action == "resolve" and not medication) or (action == "confirm_medication" and medication):
                    return task_view(task, now)
                fail(409, "Task is already completed.")
            if action == "acknowledge":
                db.execute("UPDATE tasks SET acknowledged_at = COALESCE(acknowledged_at, ?) WHERE id = ?",
                           (now, identifier))
            elif action == "priority":
                if data.priority is None:
                    fail(422, "Specify a priority from 1 to 3.")
                db.execute("UPDATE tasks SET priority = ? WHERE id = ?", (data.priority, identifier))
            elif action == "deadline":
                if data.deadline is None:
                    fail(422, "Specify a response deadline.")
                deadline = int(data.deadline.timestamp())
                if task["due_at"] is not None and deadline < task["due_at"]:
                    fail(422, "Deadline cannot precede the scheduled time.")
                db.execute("UPDATE tasks SET deadline = ? WHERE id = ?", (deadline, identifier))
            elif action == "confirm_medication":
                if not medication:
                    fail(422, "Administration confirmation applies to medication schedules.")
                db.execute("UPDATE tasks SET administered_at = ?, resolved_at = ? WHERE id = ?",
                           (now, now, identifier))
            elif medication:
                fail(409, "Use staff administration confirmation to complete the medication task.")
            else:
                db.execute("UPDATE tasks SET resolved_at = ? WHERE id = ?", (now, identifier))
            if action in {"resolve", "confirm_medication"}:
                db.execute("DELETE FROM notifications WHERE id = ?", (identifier,))
            return task_view(require(db, "tasks", identifier), now)

    @api.get("/caregiver", tags=["Caregiver"])
    def caregiver():
        """Read the SwiftUI caregiver snapshot and review what was recorded."""
        with transaction() as db:
            config = require(db, "config", 1)
            return {
                "now": config["now"], "mode": mode,
                "detector": config["detector"],
                "people": [view_profile(db, row, config["detector"]) for row in db.execute(
                    "SELECT * FROM people ORDER BY name"
                )],
                "events": [event_view(row) for row in db.execute(
                    "SELECT * FROM events ORDER BY recorded_at DESC, rowid DESC LIMIT ?", (RECENT_EVENTS if live else -1,),
                )],
                "checkins": [checkin_view(row) for row in db.execute(
                    "SELECT * FROM checkins ORDER BY opens_at DESC, id"
                )],
                "queue": [task_view(row, config["now"]) for row in db.execute(
                    """SELECT * FROM tasks WHERE resolved_at IS NULL
                    ORDER BY priority DESC, deadline, created_at, id"""
                )],
                "notifications": [dict(row) for row in active_notifications(db)],
                "completed": [task_view(row, config["now"]) for row in db.execute(
                    "SELECT * FROM tasks WHERE resolved_at IS NOT NULL ORDER BY resolved_at DESC, id"
                )],
            }

    app.include_router(api)
    return app


app = create_app()
