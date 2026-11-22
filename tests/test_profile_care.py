from fastapi.testclient import TestClient

from sahana.api import create_app


def demo_client(path):
    return TestClient(create_app(path, mode="demo"), base_url="http://127.0.0.1")


def test_rename_and_chat_are_persistent_and_profile_scoped(tmp_path):
    path = tmp_path / "demo.db"
    with demo_client(path) as client:
        reply = client.patch("/people/ari/profile", json={"name": " Asha "})
        assert reply.is_success and reply.json()["name"] == "Asha"
        assert reply.json()["id"] == "ari"
        assert client.patch("/people/ari/profile", json={"name": " "}).status_code == 422
        assert client.patch("/people/other/profile", json={"name": "Asha"}).status_code == 404
        chat = "/people/ari/chat"
        message = {"id": "msg-1", "sender": "patient", "message": "Good morning"}
        original = client.post(chat, json=message)
        assert original.status_code == 201
        assert client.post(chat, json=message).json() == original.json()
        assert client.post(chat, json=message | {"message": "Changed"}).status_code == 409
        assert client.post(chat, json={"sender": "caregiver", "message": "Good morning, Asha."}).is_success
        assert client.get("/people/mei/chat").json() == []
        assert client.get("/notifications").json() == []

    with demo_client(path) as client:
        assert client.get("/people/ari/patient").json()["person"]["name"] == "Asha"
        assert [row["message"] for row in client.get("/people/ari/chat").json()] == [
            "Good morning", "Good morning, Asha.",
        ]


def test_daily_preference_logs_once_per_shanghai_day_and_keeps_history(tmp_path):
    with demo_client(tmp_path / "demo.db") as client:
        base = "/people/ari/preferences"
        routine = client.post(base, json={"label": "Morning reading", "at": "09:36"}).json()
        identifier = routine["id"]
        assert not routine["due_today"]
        assert client.get("/people/mei/preferences").json() == []
        assert client.post(f"/people/mei/preferences/{identifier}/complete").status_code == 404
        complete = f"{base}/{identifier}/complete"
        assert client.post(complete).status_code == 409

        assert client.post("/demo/clock", json={"seconds": 60}).is_success
        assert client.post(complete).json()["completed_today"]
        assert client.post(complete).json()["completed_today"]
        assert len(client.get("/caregiver").json()["events"]) == 1

        assert client.post("/demo/clock", json={"seconds": 86400}).is_success
        assert not client.get(base).json()[0]["completed_today"]
        assert client.post(complete).json()["completed_today"]
        assert client.delete(f"{base}/{identifier}").status_code == 204
        assert client.get(base).json() == []
        assert len(client.get("/caregiver").json()["events"]) == 2


def test_all_profile_notifications_stay_visible_until_each_request_is_resolved(tmp_path):
    with demo_client(tmp_path / "demo.db") as client:
        first = {"id": "one", "person": "ari", "kind": "hydration"}
        second = {"id": "two", "person": "mei", "kind": "toileting"}
        for request in (first, second):
            assert client.post("/requests", json=request).is_success

        notices = client.get("/caregiver").json()["notifications"]
        assert {row["person"] for row in notices} == {"ari", "mei"}
        assert {row["id"] for row in notices} == {"request-one", "request-two"}
        assert len(client.get("/notifications").json()) == 2
        assert all(set(row) == {"message", "created_at"} for row in client.get("/notifications").json())

        assert client.patch("/tasks/request-one", json={"action": "resolve"}).is_success
        assert client.post("/requests", json=first).is_success
        assert [row["person"] for row in client.get("/caregiver").json()["notifications"]] == ["mei"]
        assert len(client.get("/notifications").json()) == 1
        assert client.patch("/tasks/request-two", json={"action": "resolve"}).is_success
        assert client.get("/notifications").json() == []


def test_demo_replays_both_seat_actions_and_serves_its_wordmark(tmp_path):
    with demo_client(tmp_path / "demo.db") as client:
        html = client.get("/docs").text
        assert 'class="emblem" src="/logo.png"' in html
        assert 'class="wordmark"><img src="/wordmark.png"' in html
        assert 'alt="SAHANA"' in html
        mark = client.get("/wordmark.png")
        assert mark.headers["content-type"] == "image/png"
        assert mark.content.startswith(b"\x89PNG")
        assert client.patch("/people/ari/monitoring", json={"movement": True}).is_success
        for action in ("rise_from_seat", "lower_to_seat"):
            payload = {
                "person": "ari", "id": action, "kind": "motion", "observation": action,
                "source": "optional_movement", "setting": "shared_space", "room": "Common room",
                "observed_at": "2026-11-21T09:35:00+08:00",
            }
            response = client.post("/events", json=payload)
            assert response.is_success and response.json()["observation"] == action
        events = client.get("/events?person=ari&kind=motion").json()["events"]
        assert [row["observation"] for row in events] == ["lower_to_seat", "rise_from_seat"]
        assert all(row["source"] == "optional_movement" for row in events)
        assert client.get("/notifications").json() == []
