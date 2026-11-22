from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from sahana.api import create_app
from sahana.camera import CameraRelay
from sahana.routines import ZONE


@pytest.fixture
def monitor(tmp_path):
    now = [int(datetime(2026, 11, 22, 9, 0, tzinfo=ZONE).timestamp())]
    token = "local-monitoring-test-token-1234"
    app = create_app(tmp_path / "live.sqlite3", mode="live", token=token,
                     clock=lambda: now[0], camera_relay=CameraRelay(clock=lambda: 0))
    with TestClient(app, base_url="http://127.0.0.1", client=("127.0.0.1", 12345),
                    headers={"Authorization": f"Bearer {token}"}) as client:
        profile = client.post("/people", json={"name": "Care profile"})
        profile.raise_for_status()
        yield client, now, profile.json()["id"]


def configure_window(client, person, signal, **overrides):
    response = client.put(f"/people/{person}/routines/{signal}", json={
        "start": "09:00", "end": "09:45", **overrides,
    })
    response.raise_for_status()
    return response.json()["routine_windows"]


def open_camera(client, person):
    path = f"/people/{person}"
    client.patch(f"{path}/monitoring", json={"camera": True, "movement": True, "paused": False}).raise_for_status()
    response = client.post(f"{path}/camera/session", json={"setting": "shared_space"})
    response.raise_for_status()
    return {"X-SAHANA-Camera-Session": response.json()["session_id"]}


def timestamp(epoch):
    return datetime.fromtimestamp(epoch, ZONE).isoformat()


def event(person, epoch, **overrides):
    return {"person": person, "id": f"event-{epoch}", "kind": "activity", "observation": "inactive",
            "room": "Common room", "source": "camera", "setting": "shared_space",
            "observed_at": timestamp(epoch), **overrides}


def interval(client, now, person, camera, duration, **overrides):
    begins = now[0]
    now[0] += duration
    response = client.post("/events", headers=camera, json=event(person, now[0], **{
        "coverage_start": timestamp(begins), **overrides,
    }))
    response.raise_for_status()
    return response.json()


@pytest.mark.parametrize(("kind", "observation"), [("presence", "absent"), ("activity", "inactive")])
def test_ten_covered_minutes_create_one_immediate_review_and_preview(monitor, kind, observation):
    client, now, person = monitor
    configure_window(client, person, f"common_room_{kind}")
    camera = open_camera(client, person)
    manual = client.post("/events", json=event(person, now[0], source="manual", kind=kind, observation=observation))
    assert manual.json()["flagged"] == 0 and "Duration is unknown" in manual.json()["reason"]
    for duration in [60] * 9 + [59]:
        assert not interval(client, now, person, camera, duration, kind=kind, observation=observation)["flagged"]
    assert client.get("/queue").json() == client.get("/notifications").json() == []
    qualifying = interval(client, now, person, camera, 1, kind=kind, observation=observation)
    assert qualifying["flagged"] and "10 min 00 sec" in qualifying["reason"]

    [checkin] = client.get("/checkins").json()
    [review] = client.get("/queue").json()
    assert review["id"] == "review-" + checkin["id"]
    assert review["priority"] == 3
    assert review["event_reason"] == qualifying["reason"]
    preview = client.get("/notifications").json()
    assert len(preview) == 1 and preview[0]["message"] == "High priority check-in review"
    interval(client, now, person, camera, 30, kind=kind, observation=observation)
    now[0] += 121
    [follow_up] = client.get("/queue").json()
    assert follow_up["id"] == review["id"] and follow_up["reason"] == "Check-in unanswered."
    assert client.get("/notifications").json() == preview


def test_unknown_gap_and_pause_never_count_as_observed_inactivity(monitor):
    client, now, person = monitor
    configure_window(client, person, "common_room_activity")
    camera = open_camera(client, person)
    for _ in range(5):
        interval(client, now, person, camera, 60)
    unknown = interval(client, now, person, camera, 1, observation="missing")
    assert "unknown" in unknown["reason"]
    for _ in range(5):
        assert not interval(client, now, person, camera, 60)["flagged"]
    client.patch(f"/people/{person}/monitoring", json={"paused": True}).raise_for_status()
    assert client.post("/events", headers=camera, json=event(person, now[0], id="paused-camera")).status_code == 409
    now[0] += 1
    new_camera = open_camera(client, person)
    before_session = event(person, now[0], coverage_start=timestamp(now[0] - 1))
    assert client.post("/events", headers=new_camera, json=before_session).status_code == 409
    for _ in range(5):
        assert not interval(client, now, person, new_camera, 60)["flagged"]
    assert client.get("/checkins").json() == []
    assert client.get("/notifications").json() == []


def test_patient_okay_closes_an_immediate_observation_review(monitor):
    client, now, person = monitor
    configure_window(client, person, "common_room_activity")
    camera = open_camera(client, person)
    for _ in range(10):
        interval(client, now, person, camera, 60)
    [checkin] = client.get("/checkins").json()
    response = client.post(f"/people/{person}/checkins/{checkin['id']}/response", json={"response": "okay"})
    assert response.json()["state"] == "okay"
    assert client.get("/queue").json() == []


def test_calibrate_an_additional_named_routine_and_camera_action(monitor):
    client, now, person = monitor
    named = configure_window(client, person, "afternoon_reading", start="08:00", end="08:30", name="Afternoon reading")
    assert named["afternoon_reading"] == {"start": "08:00", "end": "08:30", "name": "Afternoon reading"}
    completion = client.post("/events", json=event(
        person, now[0], kind="routine", routine="Afternoon Reading", observation="completed", source="manual",
    )).json()
    assert completion["flagged"] and "Afternoon reading recorded at 09:00" in completion["reason"]
    [checkin] = client.get("/checkins").json()
    assert checkin["signal"] == "afternoon_reading"

    configure_window(client, person, "stepping", start="08:00", end="08:30")
    camera = open_camera(client, person)
    motion = client.post("/events", headers=camera, json=event(
        person, now[0], id="observed-action", kind="motion", observation="stepping",
    )).json()
    assert "outside the configured movement window" in motion["reason"]
    assert motion["flagged"] == 0
    assert client.get("/checkins").json() == [checkin]
