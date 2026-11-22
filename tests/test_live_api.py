import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from stat import S_IMODE

import pytest
from fastapi.testclient import TestClient

from sahana.api import create_app
from sahana.camera import CameraRelay, MAX_FRAME_BYTES
from sahana.routines import ZONE


TOKEN = "test-only-token-do-not-deploy-1234"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@contextmanager
def live_client(path, clock, relay=None):
    app = create_app(path, mode="live", token=TOKEN, clock=clock, camera_relay=relay)
    with TestClient(app, base_url="http://127.0.0.1", client=("127.0.0.1", 12345), headers=AUTH) as client:
        yield client


@pytest.fixture
def service(tmp_path):
    wall = [datetime(2026, 11, 22, 9, 0, tzinfo=ZONE).timestamp()]
    steady = [50.0]
    database = tmp_path / "live.sqlite3"
    relay = CameraRelay(clock=lambda: steady[0])
    with live_client(database, lambda: wall[0], relay) as client:
        yield client, wall, steady, database


def person(client, name="Care profile", **kwargs):
    response = client.post("/people", json={"name": name, **kwargs})
    assert response.status_code == 201, response.text
    return response.json()["id"]


def test_live_mode_starts_empty_protects_records_and_serves_branded_docs(service):
    client, wall, _, database = service
    unauthed = {"Authorization": ""}
    assert client.get("/status", headers=unauthed).json() == {
        "mode": "live", "now": int(wall[0]), "timezone": "Asia/Shanghai",
    }
    assert client.get("/caregiver", headers=unauthed).status_code == 401
    assert client.get("/people", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert client.get("/people").json() == []
    assert client.post("/demo/reset", json={}).status_code == 404
    assert client.post("/demo/clock", json={"seconds": 60}).status_code == 404
    if os.name != "nt":
        assert S_IMODE(database.stat().st_mode) == 0o600
    assert client.get("/camera-test", headers=unauthed).status_code == 404
    docs = client.get("/docs", headers=unauthed)
    assert "SAHANA API" in docs.text and 'src="/wordmark.png"' in docs.text
    assert TOKEN not in docs.text
    logo = client.get("/logo.png", headers=unauthed)
    assert logo.content.startswith(b"\x89PNG")
    assert logo.headers["content-type"] == "image/png"
    spec = client.get("/openapi.json", headers=unauthed).json()
    assert spec["paths"]["/people"]["get"]["security"] == [{"SAHANA local bearer": []}]


def test_judge_camera_page_is_loopback_only_and_does_not_expose_credentials(tmp_path):
    app = create_app(tmp_path / "judge.sqlite3", mode="live", token=TOKEN, camera_test=True)
    with TestClient(app, base_url="http://127.0.0.1", client=("127.0.0.1", 12345)) as client:
        page = client.get("/camera-test")
        assert page.is_success
        assert "camera=(self)" in page.headers["permissions-policy"]
        assert "microphone=()" in page.headers["permissions-policy"]
        assert "frame-ancestors 'none'" in page.headers["content-security-policy"]
        assert "no-store" in page.headers["cache-control"]
        assert "camera-test.js" in page.text and TOKEN not in page.text
        script = client.get("/camera-test.js")
        assert script.is_success and script.headers["content-type"].startswith("text/javascript")
        assert "getUserMedia" in script.text and TOKEN not in script.text
        assert 'href="/camera-test"' in client.get("/docs").text
        assert client.get("/people").status_code == 401
        assert client.get("/people", headers=AUTH).json() == []

    with TestClient(app, base_url="http://127.0.0.1", client=("192.0.2.10", 12345)) as client:
        assert client.get("/camera-test").status_code == 403
        assert client.get("/camera-test.js").status_code == 403
        assert client.get("/people", headers=AUTH).status_code == 403


def test_live_routine_requires_profile_calibration_and_uses_actual_clock(service):
    client, wall, _, _ = service
    identifier = person(client)

    def breakfast(event_id):
        return client.post("/events", json={
            "person": identifier, "id": event_id, "kind": "breakfast", "observation": "completed",
            "source": "manual", "observed_at": datetime.fromtimestamp(wall[0], ZONE).isoformat(),
        }).json()

    first = breakfast("unconfigured")
    assert first["flagged"] == 0
    assert "No usual window" in first["reason"]
    route = f"/people/{identifier}/routines/breakfast"
    assert client.put(route, json={"start": "09:00", "end": "08:00"}).status_code == 422
    calibrated = client.put(route, json={"start": "07:00", "end": "08:00"}).json()
    assert calibrated["routine_windows"]["breakfast"] == {"start": "07:00", "end": "08:00"}
    assert breakfast("late")["flagged"] == 1
    assert client.get("/queue").json() == []
    wall[0] += 121
    queue = client.get("/queue").json()
    assert len(queue) == 1
    assert queue[0]["kind"] == "review"
    assert queue[0]["wait_seconds"] == 1
    assert client.get(f"/people/{identifier}/patient").json()["now"] == int(wall[0])
    latest = client.get("/events", params={"person": identifier, "limit": 1}).json()
    assert [item["id"] for item in latest["events"]] == ["late"]
    prior = client.get("/events", params={"person": identifier, "before": latest["next_before"]}).json()
    assert [item["id"] for item in prior["events"]] == ["unconfigured"]
    assert prior["next_before"] is None


@pytest.mark.parametrize("action, reason", [
    ("stepping", "Took steps recorded during optional monitoring."),
    ("still_in_view", "Still in view recorded during optional monitoring."),
    ("rise_from_seat", "Rose from a seat recorded during optional monitoring."),
    ("lower_to_seat", "Lowered onto a seat recorded during optional monitoring."),
])
def test_camera_frames_are_scoped_ephemeral_and_revoked_by_pause(service, action, reason):
    client, wall, steady, database = service
    first = person(client)
    second = person(client, "Second profile")
    profile = f"/people/{first}"
    camera = f"{profile}/camera"
    route = f"{camera}/session"
    assert client.get(f"{camera}/frame").status_code == 204
    assert client.post(route, json={"setting": "shared_space"}).status_code == 403
    assert client.patch(f"{profile}/monitoring", json={"recording": True}).status_code == 422
    assert client.patch(f"{profile}/monitoring", json={"camera": True}).is_success
    assert client.post(route, json={"setting": "bathroom"}).status_code == 422
    lease = client.post(route, json={"setting": "shared_space"}).json()["session_id"]
    assert client.patch(f"/people/{second}/monitoring", json={"camera": True}).is_success
    assert client.post(f"/people/{second}/camera/session", json={"setting": "shared_space"}).status_code == 409
    authorization = {"X-SAHANA-Camera-Session": lease, "Content-Type": "image/jpeg"}
    assert client.put(f"{camera}/frame", headers=authorization, content=b"invalid").status_code == 415
    assert client.put(f"{camera}/frame", headers=authorization, content=b"1" * (MAX_FRAME_BYTES + 1)).status_code == 413

    # An actual bundled JPEG is useful for testing a device-independent frame relay.
    jpeg = (Path(__file__).parent / "camera-frame.jpg").read_bytes()
    assert client.put(f"{camera}/frame", headers=authorization, content=jpeg).status_code == 204
    frame = client.get(f"{camera}/frame")
    assert frame.content == jpeg
    assert frame.headers["cache-control"] == "no-store, private"
    assert client.get(f"/people/{second}/camera/frame").status_code == 204
    assert jpeg not in database.read_bytes()

    event = {
        "person": first, "id": "camera-movement", "kind": "motion", "observation": action,
        "source": "camera", "room": "Common room", "setting": "shared_space",
        "observed_at": datetime.fromtimestamp(wall[0], ZONE).isoformat(),
    }
    assert client.post("/events", json=event).status_code == 403
    assert client.get(camera).json()["movement_allowed"] is False
    assert client.post("/events", json=event, headers={"X-SAHANA-Camera-Session": lease}).status_code == 409
    assert client.patch(f"{profile}/monitoring", json={"movement": True}).is_success
    assert client.get(camera).json()["movement_allowed"] is True
    motion = client.post("/events", json=event, headers={"X-SAHANA-Camera-Session": lease})
    assert motion.status_code == 200, motion.text
    assert motion.json()["reason"] == reason
    assert motion.json()["flagged"] == 0
    assert client.get(camera).json()["latest_observation"]["observation"] == action
    assert client.get("/queue").json() == []
    assert client.get("/notifications").json() == []
    steady[0] += 3
    assert client.get(f"{camera}/frame").status_code == 204
    assert client.get(camera).json()["active"] is True
    assert client.patch(f"{profile}/monitoring", json={"recording": True}).is_success
    assert client.get(camera).json()["recording_allowed"] is True
    assert client.patch(f"{profile}/monitoring", json={"paused": True}).is_success
    assert client.put(f"{camera}/frame", headers=authorization, content=jpeg).status_code == 409
    assert client.get(camera).json() == {
        "allowed": False, "recording_allowed": False, "movement_allowed": False, "active": False,
        "frame_available": False, "latest_observation": None,
    }
    assert client.post("/requests", json={"person": first}).status_code == 200
    assert client.get("/notifications").json()[0]["message"] == "Assistance requested"


def test_seat_transitions_remain_distinct_after_room_updates(service):
    client, wall, _, _ = service
    first = person(client)
    second = person(client, "Another profile")
    camera = f"/people/{first}/camera"
    assert client.patch(f"/people/{first}/monitoring", json={"camera": True, "movement": True}).is_success
    lease = client.post(f"{camera}/session", json={"setting": "shared_space"}).json()["session_id"]
    headers = {"X-SAHANA-Camera-Session": lease}

    for kind, action in (("motion", "rise_from_seat"), ("motion", "lower_to_seat"), ("presence", "present")):
        wall[0] += 1
        event = {
            "person": first, "id": action, "kind": kind, "observation": action, "source": "camera",
            "setting": "shared_space", "room": "Common room",
            "observed_at": datetime.fromtimestamp(wall[0], ZONE).isoformat(),
        }
        assert client.post("/events", headers=headers, json=event).is_success

    view = client.get(camera).json()
    assert view["latest_observation"]["observation"] == "present"
    assert view["latest_seat_transition"]["observation"] == "lower_to_seat"
    assert view["latest_seat_transition"]["movement_label"] == "Lowered onto a seat"
    assert "latest_seat_transition" not in client.get(f"/people/{second}/camera").json()
    history = client.get("/events", params={"person": first, "kind": "motion"}).json()["events"]
    assert [row["observation"] for row in history] == ["lower_to_seat", "rise_from_seat"]
    assert [row["movement_label"] for row in history] == ["Lowered onto a seat", "Rose from a seat"]
    assert client.get("/queue").json() == []
    assert client.delete(f"{camera}/session", headers=headers).status_code == 204
    assert "latest_seat_transition" not in client.get(camera).json()


def test_live_profiles_persist_but_camera_session_does_not(tmp_path):
    database = tmp_path / "live.sqlite3"
    with live_client(database, lambda: 1000) as client:
        identifier = person(client, breakfast_start="08:00", breakfast_end="08:30")
        profile = f"/people/{identifier}"
        assert client.patch(f"{profile}/monitoring", json={"camera": True}).is_success
        assert client.post(f"{profile}/camera/session", json={"setting": "shared_space"}).is_success
        with pytest.raises(RuntimeError, match="already owns"):
            with live_client(database, lambda: 1000):
                pass
    with live_client(database, lambda: 2000) as client:
        restored = client.get(f"{profile}/patient").json()["person"]
        assert restored["camera"] is True
        assert restored["breakfast_window"] == "08:00–08:30"
        assert client.get(f"{profile}/camera").json()["active"] is False

    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT run_mode FROM config").fetchone() == ("live",)
