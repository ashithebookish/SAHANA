from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from sahana.api import create_app
from sahana.routines import ZONE
from scripts.demo import demonstrate
from scripts.demo_client import request
from scripts.replay import replay


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(tmp_path / "test.sqlite3"), base_url="http://127.0.0.1") as api:
        yield api


def event(identifier="breakfast", **changes):
    return {
        "id": identifier,
        "person": "ari",
        "kind": "breakfast",
        "observation": "completed",
        "source": "manual",
        "observed_at": "2026-11-21T09:35:00+08:00",
        **changes,
    }


def schedule(client, kind, **changes):
    return request(client, "POST", "/schedules", json={
        "person": "mei", "kind": kind, "label": f"Scheduled {kind}",
        "due_at": "2026-11-21T09:36:00+08:00", "deadline": "2026-11-21T09:37:00+08:00",
        **changes,
    })


def advance(client, seconds):
    return request(client, "POST", "/demo/clock", json={"seconds": seconds})["now"]


def checkins(client):
    return request(client, "GET", "/checkins")


def queue(client):
    return request(client, "GET", "/queue")


def update_task(client, task, action, **fields):
    return request(client, "PATCH", f"/tasks/{task['id']}", json={"action": action, **fields})


def local_time(hour, minute, second=0, *, day=21):
    return datetime(2026, 11, day, hour, minute, second, tzinfo=ZONE)


def advance_to(client, date):
    now = request(client, "GET", "/demo")["now"]
    seconds = int(date.timestamp()) - now
    if seconds:
        advance(client, seconds)


def movement_event(identifier, at, **fields):
    return event(identifier, **({"source": "optional_movement", "kind": "activity", "observation": "inactive",
                               "room": "Common room", "setting": "shared_space", "observed_at": at.isoformat()}
                              | fields))


def record_coverage(client, start, end, **fields):
    while start < end:
        observed = min(start + timedelta(minutes=1), end)
        advance_to(client, observed)
        stored = request(client, "POST", "/events", json={
            **movement_event(f"interval-{observed.isoformat()}", observed),
            "coverage_start": start.isoformat(),
            **fields,
        })
        start = observed
    return stored


def test_concurrent_retries_and_repeated_deviation_open_one_checkin(client):
    observation = event()
    with ThreadPoolExecutor(max_workers=4) as callers:
        responses = list(callers.map(
            lambda _: request(client, "POST", "/events", json=observation), range(4)
        ))
    assert sum(not item["duplicate"] for item in responses) == 1
    assert all(item["flagged"] for item in responses)

    collision = client.post("/events", json=event(person="mei"))
    assert collision.status_code == 409

    request(client, "POST", "/events", json=event("second-entry"))
    assert len(checkins(client)) == 1
    assert len(request(client, "GET", "/caregiver")["events"]) == 2

    advance(client, 121)
    advance(client, 60)
    assert len(queue(client)) == 1
    assert queue(client)[0]["reason"] == "Check-in unanswered."


def test_missing_observations_are_distinct_from_explicit_inactivity(client):
    missing = request(client, "POST", "/events", json=event("missing", kind="activity", observation="missing"))
    inactive = request(client, "POST", "/events", json=event("inactive", kind="activity", observation="inactive"))
    miss_breakfast = request(client, "POST", "/events", json=event("missing-breakfast", observation="missing"))

    assert missing["observation"] == "missing"
    assert "unknown" in missing["reason"].lower()
    assert "Inactivity observed" in inactive["reason"]
    assert miss_breakfast["flagged"] == 0
    assert checkins(client) == []
    assert queue(client) == []


def test_okay_cancels_checkin_after_snooze_without_creating_review(client):
    request(client, "POST", "/events", json=event())
    checkin = checkins(client)[0]
    path = f"/checkins/{checkin['id']}/response"
    assert checkin["prompt"] == "Would you like help?"
    assert request(client, "POST", path, json={"response": "snooze", "snooze_seconds": 40})["state"] == "snoozed"
    advance(client, 39)
    assert checkins(client)[0]["state"] == "snoozed"
    advance(client, 1)
    assert checkins(client)[0]["state"] == "open"
    assert request(client, "POST", path, json={"response": "okay"})["state"] == "okay"
    advance(client, 240)
    assert checkins(client)[0]["state"] == "okay"
    assert queue(client) == []
    assert request(client, "POST", path, json={"response": "okay"})["state"] == "okay"


def test_calibrated_common_room_observations_open_distinct_checkins(client):
    advance(client, 4 * 3600 + 40 * 60)
    activity = event("missing-common-room", room="Common room", kind="activity", observation="missing",
                     observed_at="2026-11-21T14:15:00+08:00")
    missing = request(client, "POST", "/events", json=activity)
    assert "unknown" in missing["reason"].lower()
    assert not missing["flagged"] and checkins(client) == []

    for identifier in ("inactive-1", "inactive-2"):
        inactive = request(client, "POST", "/events", json={
            **activity, "id": identifier, "observation": "inactive",
        })
        assert inactive["flagged"] and "inside the usual" in inactive["reason"]
    [checkin] = checkins(client)
    assert checkin["signal"] == "common_room_activity"

    absence = request(client, "POST", "/events", json={
        **activity, "id": "absence", "kind": "presence", "observation": "absent",
    })
    assert absence["flagged"] and "Absence observed in the common room" in absence["reason"]
    assert {row["signal"] for row in checkins(client)} == {"common_room_activity", "common_room_presence"}


def test_named_lunch_uses_its_own_window_on_a_day_with_breakfast_checkin(client):
    request(client, "POST", "/events", json=event())
    advance(client, 3 * 3600 + 5 * 60)
    lunch = request(client, "POST", "/events", json=event(
        "lunch", kind="routine", routine="Lunch", observed_at="2026-11-21T12:40:00+08:00",
    ))
    assert lunch["flagged"]
    assert lunch["reason"] == "Lunch recorded at 12:40, outside the usual 11:40–12:15 window."
    assert {row["signal"] for row in checkins(client)} == {"breakfast", "lunch"}


def test_checkin_help_closes_checkin_and_creates_one_review(client):
    request(client, "POST", "/events", json=event())
    path = f"/checkins/{checkins(client)[0]['id']}/response"
    for _ in range(2):
        assert request(client, "POST", path, json={"response": "help"})["state"] == "help"
    advance(client, 121)
    items = queue(client)
    assert len(items) == 1
    assert items[0]["kind"] == "review"
    assert items[0]["reason"] == "Asked for help during a check-in."
    assert len(request(client, "GET", "/notifications")) == 1


def test_configurable_checkin_timeout_creates_review_on_expiration(client):
    now = request(client, "POST", "/demo/reset", json={"response_seconds": 9})["now"]
    request(client, "POST", "/events", json=event())
    advance(client, 8)
    assert queue(client) == []
    advance(client, 10)
    assert checkins(client)[0]["state"] == "unanswered"
    review = queue(client)[0]
    assert review["created_at"] == now + 9
    assert review["wait_seconds"] == 9
    assert review["remaining_seconds"] == review["deadline"] - (now + 18)


def test_overdue_reminder_is_still_open_after_acknowledgement(client):
    medication = schedule(client, "medication")
    assert medication["status"] == "Upcoming"
    advance(client, 60)
    assert queue(client)[0]["status"] == "Due"
    acknowledged = update_task(client, medication, "acknowledge")
    assert acknowledged["status"] == "Due"
    assert acknowledged["acknowledged_at"] is not None
    advance(client, 61)
    [overdue] = queue(client)
    assert overdue["status"] == "Overdue"
    assert overdue["remaining_seconds"] == -1
    assert overdue["acknowledged_at"] == acknowledged["acknowledged_at"]
    assert overdue["resolved_at"] is None


def test_staff_confirmation_is_independent_of_medication_acknowledgement(client):
    medication = schedule(client, "medication")
    acknowledged = update_task(client, medication, "acknowledge")
    assert acknowledged["administered_at"] is None
    advance(client, 60)
    resolve = client.patch(f"/tasks/{medication['id']}", json={"action": "resolve"})
    assert resolve.status_code == 409
    assert len(queue(client)) == 1

    confirmed = update_task(client, medication, "confirm_medication")
    assert confirmed["status"] == "Completed"
    assert confirmed["administered_at"] == confirmed["resolved_at"]
    assert confirmed["acknowledged_at"] < confirmed["administered_at"]
    assert queue(client) == []
    advance(client, 10)
    assert update_task(client, medication, "confirm_medication")["administered_at"] == confirmed["administered_at"]


def test_staff_sorting_honors_priority_deadline_and_wait_time(client):
    older = schedule(client, "meal")
    advance(client, 15)
    newer = schedule(client, "hydration")
    earlier = schedule(client, "toileting", deadline="2026-11-21T09:36:30+08:00")
    assert [item["id"] for item in queue(client)] == [earlier["id"], older["id"], newer["id"]]
    assert queue(client)[1]["wait_seconds"] > queue(client)[2]["wait_seconds"]

    update_task(client, newer, "priority", priority=3)
    assert [item["id"] for item in queue(client)] == [newer["id"], earlier["id"], older["id"]]
    update_task(client, newer, "acknowledge")
    update_task(client, newer, "deadline", deadline="2026-11-21T09:36:15+08:00")
    assert queue(client)[0]["remaining_seconds"] == 60
    assert update_task(client, newer, "resolve")["status"] == "Completed"
    assert [item["id"] for item in queue(client)] == [earlier["id"], older["id"]]


def test_pause_preserves_manual_care_and_preview_contains_only_generic_copy(client):
    path = "/people/mei/monitoring"
    movement = movement_event("auto", local_time(9, 35), person="mei", observation="active")
    assert client.post("/events", json=movement).status_code == 409
    request(client, "PATCH", path, json={"movement": True})
    request(client, "POST", "/events", json=movement)
    assert request(client, "PATCH", path, json={"paused": True})["paused"]
    assert client.post("/events", json=movement | {"id": "auto2"}).status_code == 409

    ask = {"id": "help", "person": "mei", "kind": "toileting"}
    assert request(client, "POST", "/requests", json=ask)["submitted"]
    assert request(client, "POST", "/requests", json=ask)["submitted"]
    schedule(client, "medication")
    preview = request(client, "GET", "/notifications")
    assert len(preview) == 1
    assert set(preview[0]) == {"message", "created_at"}
    assert preview[0]["message"] == "Assistance requested"
    assert [task["label"] for task in queue(client)] == ["Scheduled medication", "Toileting assistance"]

    request(client, "POST", "/events", json=event("manual", person="mei"))
    assert request(client, "DELETE", path + "/history")["removed"] == 1
    assert [row["id"] for row in request(client, "GET", "/caregiver")["events"]] == ["manual"]


def test_opted_in_staged_facial_event_is_unconfirmed_and_never_creates_task(client):
    payload = event("facial", kind="facial", observation="movement", source="staged_facial", setting="shared_space")
    assert client.post("/events", json=payload).status_code == 409
    request(client, "PATCH", "/people/ari/monitoring", json={"facial": True})
    for setting in ("bathroom", "personal_care"):
        assert client.post("/events", json=payload | {"setting": setting}).status_code == 422
    stored = request(client, "POST", "/events", json=payload)
    assert "Unconfirmed" in stored["reason"]
    assert stored["room"] is None and not stored["flagged"]
    advance(client, 300)
    assert checkins(client) == []
    assert queue(client) == []


def test_scripted_acceptance_demo(client):
    stage = demonstrate(client)
    assert not stage["mei"]["flagged"]
    assert stage["ari"]["flagged"]
    assert [row["person"] for row in stage["checkins"]] == ["ari"]
    assert stage["acknowledged"]["status"] == "Due"
    assert stage["acknowledged"]["resolved_at"] is None
    assert stage["patient_acknowledged"]["acknowledged_at"] == stage["acknowledged"]["reminder_acknowledged_at"]
    assert [row["reason"] for row in stage["timed_queue"]] == ["Check-in unanswered.", "Scheduled care."]
    assert stage["timed_queue"][1]["status"] == "Overdue"
    assert stage["paused"]["paused"] and stage["request"]["submitted"]
    assert stage["preview"]["message"] == "Assistance requested"
    assert stage["queue"][0]["label"] == "Toileting assistance"


def test_pausing_cancels_pending_optional_checkin_and_history_clear_removes_copied_reason(client):
    settings = "/people/ari/monitoring"
    request(client, "PATCH", settings, json={"movement": True})
    record_coverage(client, local_time(14, 0), local_time(14, 10, 1))
    [answered] = checkins(client)
    request(client, "POST", f"/checkins/{answered['id']}/response", json={"response": "help"})
    record_coverage(client, local_time(14, 0, day=22), local_time(14, 10, 1, day=22))
    request(client, "PATCH", settings, json={"paused": True})
    advance(client, 120)

    assert {row["state"] for row in checkins(client)} == {"help", "cancelled"}
    [review] = queue(client)
    assert "common room" in review["event_reason"]
    assert request(client, "DELETE", settings + "/history")["removed"] == 22
    assert checkins(client) == []
    [review_without_observation] = queue(client)
    assert review_without_observation["reason"] == "Asked for help during a check-in."
    assert review_without_observation["event_reason"] is None


def test_camera_requires_opt_in_and_approved_zone_and_still_is_a_point_observation(client):
    at = local_time(14, 15)
    advance_to(client, at)
    payload = movement_event("still", at, source="camera", kind="motion", observation="still_in_view")
    assert client.post("/events", json=payload).status_code == 409
    request(client, "PATCH", "/people/ari/monitoring", json={"movement": True})
    for fields in ({"setting": "bathroom"}, {"setting": "personal_care"}, {"room": "Private room"}):
        assert client.post("/events", json=payload | fields).status_code == 422
    still = request(client, "POST", "/events", json=payload)
    assert still["observation"] == "still_in_view"
    assert not still["flagged"]
    inactive = movement_event("inactive-point", at, source="camera")
    assert not request(client, "POST", "/events", json=inactive)["flagged"]
    assert checkins(client) == []


def test_covered_inactivity_requires_over_ten_minutes_and_sends_generic_review(client):
    request(client, "PATCH", "/people/ari/monitoring", json={"movement": True})
    exact = record_coverage(client, local_time(14, 0), local_time(14, 10))
    assert not exact["flagged"] and checkins(client) == []
    over = record_coverage(client, local_time(14, 10), local_time(14, 10, 1))
    assert over["flagged"] and "10 min 01 sec" in over["reason"]
    record_coverage(client, local_time(14, 10, 1), local_time(14, 11, 1))
    assert len(checkins(client)) == 1
    assert request(client, "GET", "/notifications") == []
    advance(client, 120)
    [task] = queue(client)
    assert task["priority"] == 3 and task["reason"] == "Check-in unanswered."
    [preview] = request(client, "GET", "/notifications")
    assert preview == {"message": "High priority check-in review", "created_at": task["created_at"]}
    assert request(client, "DELETE", "/people/ari/monitoring/history")["removed"] == 12
    assert request(client, "GET", "/notifications") == []
    assert queue(client)[0]["event_reason"] is None


def test_missing_interval_and_pause_break_inactivity_coverage(client):
    settings = "/people/ari/monitoring"
    request(client, "PATCH", settings, json={"movement": True})
    record_coverage(client, local_time(14, 0), local_time(14, 6))
    missing = record_coverage(client, local_time(14, 6), local_time(14, 7), observation="missing")
    assert "unknown" in missing["reason"] and not missing["flagged"]
    assert not record_coverage(client, local_time(14, 7), local_time(14, 13))["flagged"]
    request(client, "PATCH", settings, json={"paused": True})
    advance_to(client, local_time(14, 14))
    request(client, "PATCH", settings, json={"paused": False})
    stale = movement_event("stale-capture", local_time(14, 14), coverage_start=local_time(14, 13).isoformat())
    assert client.post("/events", json=stale).status_code == 409
    assert not record_coverage(client, local_time(14, 14), local_time(14, 21))["flagged"]
    assert checkins(client) == []


def test_pause_racing_with_eligible_coverage_leaves_no_pending_checkin(client):
    settings = "/people/ari/monitoring"
    request(client, "PATCH", settings, json={"movement": True})
    record_coverage(client, local_time(14, 0), local_time(14, 10))
    advance_to(client, local_time(14, 10, 1))
    final = movement_event("last-second", local_time(14, 10, 1), coverage_start=local_time(14, 10).isoformat())
    with ThreadPoolExecutor(max_workers=2) as callers:
        upload = callers.submit(client.post, "/events", json=final)
        pause = callers.submit(client.patch, settings, json={"paused": True})
        assert upload.result().status_code in {200, 409}
        assert pause.result().json()["paused"] == 1
    assert all(row["state"] == "cancelled" for row in checkins(client))
    advance(client, 120)
    assert queue(client) == []
    assert request(client, "GET", "/notifications") == []


def test_missed_visit_requires_coverage_for_the_whole_personal_window(client):
    request(client, "PATCH", "/people/ari/monitoring", json={"movement": True})
    coverage = {"kind": "presence", "observation": "absent"}
    penultimate = record_coverage(client, local_time(13, 55), local_time(14, 29), **coverage)
    assert not penultimate["flagged"] and checkins(client) == []
    last = record_coverage(client, local_time(14, 29), local_time(14, 30), **coverage)
    assert last["flagged"] and "13:55–14:30" in last["reason"]
    assert [row["signal"] for row in checkins(client)] == ["common_room_presence"]


def test_patient_reminder_and_checkin_responses_are_scoped_and_redacted(client):
    assert client.get("/people", headers={"host": "care.example"}).status_code == 400
    meds = schedule(client, "medication", priority=1, self_managed=True, label="Staff-only detail")
    private = request(client, "GET", "/people/mei/patient")
    assert request(client, "GET", "/people/ari/patient")["reminders"] == []
    [reminder] = private["reminders"]
    assert reminder["id"] == meds["id"]
    assert set(reminder) == {"id", "due_at", "deadline", "acknowledged_at", "status"}
    assert client.post(f"/people/ari/reminders/{meds['id']}/acknowledge").status_code == 404
    path = f"/people/mei/reminders/{meds['id']}/acknowledge"
    advance(client, 60)
    patient_ack = request(client, "POST", path)
    [staff_task] = queue(client)
    assert patient_ack["acknowledged_at"] == staff_task["reminder_acknowledged_at"]
    assert staff_task["acknowledged_at"] is None and staff_task["administered_at"] is None
    assert request(client, "POST", path) == patient_ack
    assert update_task(client, meds, "confirm_medication")["status"] == "Completed"

    request(client, "POST", "/events", json=event())
    [checkin] = checkins(client)
    assert client.post(f"/people/mei/checkins/{checkin['id']}/response", json={"response": "okay"}).status_code == 404
    result = request(client, "POST", f"/people/ari/checkins/{checkin['id']}/response", json={"response": "okay"})
    assert result["state"] == "okay" and "reason" not in result


def test_held_out_replay_uses_identical_scenarios(client):
    report = replay(client)
    fixed, personalized = report["fixed"], report["personalized"]
    assert [row["scenario"] for row in fixed["scenarios"]] == [row["scenario"] for row in personalized["scenarios"]]
    assert fixed["scripted_deviations"] == personalized["scripted_deviations"] == 5
    assert fixed["detected_scripted_deviations"] == 2
    assert personalized["detected_scripted_deviations"] == 5
    assert fixed["false_caregiver_alerts"] == 1
    assert personalized["false_caregiver_alerts"] == 0
    assert fixed["median_seconds_to_flag_detected_deviations"] == 337.5
    assert personalized["median_seconds_to_flag_detected_deviations"] == 30
