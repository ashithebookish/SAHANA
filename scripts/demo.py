"""Walk through the required SAHANA acceptance scenario using the local API."""
import argparse

from scripts.demo_client import demo_client, request


def demonstrate(client):
    stage = {}
    request(client, "POST", "/demo/reset", json={"detector": "personalized", "response_seconds": 120})
    common_event = {
        "kind": "breakfast", "observation": "completed", "source": "scripted",
        "observed_at": "2026-11-21T09:35:00+08:00",
    }
    for person in ("mei", "ari"):
        stage[person] = request(client, "POST", "/events", json={
            **common_event, "id": "demo-breakfast-" + person, "person": person,
        })
    stage["checkins"] = request(client, "GET", "/checkins")

    medication = request(client, "POST", "/schedules", json={
        "person": "mei", "kind": "medication", "label": "Scheduled demo medication",
        "due_at": "2026-11-21T09:36:00+08:00", "deadline": "2026-11-21T09:36:30+08:00",
        "priority": 1, "self_managed": True,
    })
    stage["upcoming"] = medication
    med_path = f"/tasks/{medication['id']}"
    request(client, "POST", "/demo/clock", json={"seconds": 60})
    stage["patient_acknowledged"] = request(
        client, "POST", f"/people/mei/reminders/{medication['id']}/acknowledge",
    )
    stage["acknowledged"] = request(client, "PATCH", med_path, json={"action": "acknowledge"})
    request(client, "POST", "/demo/clock", json={"seconds": 60})
    stage["timed_queue"] = request(client, "GET", "/queue")

    settings_path = "/people/mei/monitoring"
    request(client, "PATCH", settings_path, json={"movement": True})
    stage["paused"] = request(client, "PATCH", settings_path, json={"paused": True})
    stage["request"] = request(client, "POST", "/requests", json={
        "id": "demo-toileting", "person": "mei", "kind": "toileting",
    })
    stage["preview"] = request(client, "GET", "/notifications")[0]
    request(client, "PATCH", "/tasks/request-demo-toileting", json={"action": "priority", "priority": 3})
    stage["queue"] = request(client, "GET", "/queue")
    return stage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="Use and reset an existing loopback demo API, leaving this scenario loaded.")
    options = parser.parse_args()
    with demo_client(options.url) as client:
        stage = demonstrate(client)
    print("09:35  Mei  " + stage["mei"]["reason"])
    print("09:35  Ari  " + stage["ari"]["reason"])
    for checkin in stage["checkins"]:
        print(f"       {checkin['person'].title()} receives “{checkin['prompt']}”")
    print(f"09:35  Medication reminder is {stage['upcoming']['status'].lower()}.")
    ack = stage["acknowledged"]
    print(f"09:36  Medication reminder is {ack['status'].lower()}. "
          f"Patient acknowledged {stage['patient_acknowledged']['acknowledged_at'] is not None}, "
          f"staff acknowledged {ack['acknowledged_at'] is not None}, "
          f"completed {ack['resolved_at'] is not None}.")
    for item in stage["timed_queue"]:
        print(f"09:37  {item['label']} | {item['status']} | {item['reason']}")
    print(f"       Optional monitoring paused for Mei: {bool(stage['paused']['paused'])}")
    print("       Notification preview displays “" + stage["preview"]["message"] + "”")
    print("       Caregiver queue")
    for item in stage["queue"]:
        print(f"       Priority {item['priority']} | {item['label']} | {item['reason']} | "
              f"Waited {item['wait_seconds']}s | {item['remaining_seconds']}s to deadline")


if __name__ == "__main__":
    main()
