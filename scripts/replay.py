"""Replay identical held-out cases and measure actual detector and queue outcomes."""
import argparse
import json
from datetime import datetime
from pathlib import Path
from statistics import median

from sahana.routines import ZONE
from scripts.demo_client import demo_client, epoch, request

CASES = Path(__file__).resolve().parents[1] / "fixtures" / "held_out.json"
RESPONSE_SECONDS = 120
DETECTORS = ("fixed", "personalized")


def advance_to(client, now, target):
    if target < now:
        raise ValueError("Held-out observations must be in chronological order.")
    if target == now:
        return now
    return request(client, "POST", "/demo/clock", json={"seconds": target - now})["now"]


def case_observations(case):
    payload = {
        key: case[key]
        for key in ("id", "person", "kind", "observation", "observed_at", "room", "routine")
        if key in case
    } | {"source": case.get("source", "scripted")}
    if payload["source"] == "camera":
        payload["setting"] = "shared_space"
    end = epoch(case["observed_at"])
    minutes = case.get("coverage_minutes", 0)
    if not minutes:
        return end, [(end + case["intake_delay_seconds"], payload)]
    start = end - minutes * 60
    observations = []
    for minute in range(1, minutes + 1):
        sample_end = start + minute * 60
        observation = "missing" if minute == case.get("missing_minute") else payload["observation"]
        sample = payload | {
            "id": f"{case['id']}-{minute}",
            "observed_at": datetime.fromtimestamp(sample_end, ZONE).isoformat(),
            "coverage_start": datetime.fromtimestamp(sample_end - 60, ZONE).isoformat(),
            "observation": observation,
        }
        observations.append((sample_end, sample))
    return start, observations


def replay(client):
    cases = json.loads(CASES.read_text())
    outputs = {}
    for detector in DETECTORS:
        now = request(client, "POST", "/demo/reset", json={
            "detector": detector, "response_seconds": RESPONSE_SECONDS,
        })["now"]
        observations = []
        for case in cases:
            onset, samples = case_observations(case)
            if case.get("source") == "camera":
                now = advance_to(client, now, onset)
                request(client, "PATCH", f"/people/{case['person']}/monitoring", json={"movement": True})
            events = []
            for intake_at, payload in samples:
                now = advance_to(client, now, intake_at)
                events.append(request(client, "POST", "/events", json=payload))
            event = next((row for row in events if row["flagged"]), events[-1])
            checkin = next((
                row for row in request(client, "GET", "/checkins") if row["event_id"] == event["id"]
            ), None)
            if checkin and case["checkin_response"]:
                request(client, "POST", f"/checkins/{checkin['id']}/response", json={
                    "response": case["checkin_response"],
                })
            observations.append((case, onset, event, checkin))
        # Advance both passes far enough for every unanswered check-in to expire.
        request(client, "POST", "/demo/clock", json={"seconds": RESPONSE_SECONDS})
        queue = request(client, "GET", "/queue")
        rows = []
        for case, onset, event, checkin in observations:
            review = next((
                task for task in queue
                if checkin and task["id"] == f"review-{checkin['id']}"
            ), None)
            rows.append({
                "scenario": case["id"],
                "scripted_deviation": case["scripted_deviation"],
                "sample_count": case.get("coverage_minutes", 1),
                "reason": event["reason"],
                "flagged": bool(event["flagged"]),
                "checkin_opened": checkin is not None,
                "caregiver_alert": review is not None,
                "caregiver_priority": review["priority"] if review else None,
                "seconds_to_flag": event["recorded_at"] - onset if event["flagged"] else None,
                "seconds_to_caregiver_alert": review["created_at"] - onset if review else None,
            })
        flag_delays = [
            row["seconds_to_flag"] for row in rows if row["scripted_deviation"] and row["flagged"]
        ]
        outputs[detector] = {
            "scenarios": rows,
            "scripted_deviations": sum(row["scripted_deviation"] for row in rows),
            "detected_scripted_deviations": sum(
                row["scripted_deviation"] and row["flagged"] for row in rows
            ),
            "false_checkins": sum(not row["scripted_deviation"] and row["checkin_opened"] for row in rows),
            "false_caregiver_alerts": sum(
                not row["scripted_deviation"] and row["caregiver_alert"] for row in rows
            ),
            "median_seconds_to_flag_detected_deviations": median(flag_delays) if flag_delays else None,
        }
    return outputs


def report(outputs):
    fixed, personalized = [outputs[key] for key in DETECTORS]
    measures = (
        ("Scripted deviations detected", "detected_scripted_deviations"),
        ("False check-ins", "false_checkins"),
        ("False caregiver alerts", "false_caregiver_alerts"),
        ("Median time to flag detected deviations", "median_seconds_to_flag_detected_deviations"),
    )

    def measure(detector, key):
        value = detector[key]
        if key == "detected_scripted_deviations":
            return f"{value} of {detector['scripted_deviations']}"
        if key == "median_seconds_to_flag_detected_deviations":
            return f"{value:g} s" if value is not None else "None"
        return str(value)

    def timing(row):
        return " / ".join("—" if value is None else f"{value} s" for value in (
            row["seconds_to_flag"], row["seconds_to_caregiver_alert"],
        ))

    lines = [
        "SAHANA held-out detector replay",
        "",
        f"Both detectors received the same {len(fixed['scenarios'])} synthetic scenarios and responses.",
        "Calibration used five separate days, 16–20 November 2026. Held-out cases",
        "span 21–27 November 2026 in Asia/Shanghai. All camera-source events were",
        "scripted. No video or model inference was used in this measurement.",
        "",
        f"{'Measure':<46} {'Fixed':<12} Personalized",
    ]
    for label, key in measures:
        lines.append(f"{label:<46} {measure(fixed, key):<12} {measure(personalized, key)}")
    lines.extend(("", f"{'Scenario':<40} {'Expected':<11} {'Fixed flag/review':<21} Personal flag/review"))
    for left, right in zip(fixed["scenarios"], personalized["scenarios"], strict=True):
        expected = "Deviation" if left["scripted_deviation"] else "No flag"
        lines.append(f"{left['scenario']:<40} {expected:<11} {timing(left):<21} {timing(right)}")
    lines.extend((
        "",
        "Time starts at the logged event for point observations and at the first",
        "interval start for coverage cases. Intake was delayed by 0–30 seconds for",
        "point events. For coverage cases, time to flag includes the observation",
        "period needed by the rule. Check-ins expired after 120 seconds.",
        "",
        "The fixed breakfast window was 07:30–08:30. Personalized windows were",
        "09:10–09:50 for Mei and 07:40–08:20 for Ari. The fixed common-room visit",
        "window was 14:00–15:00. Ari’s personalized visit window was 13:55–14:30.",
        "The missed-visit scenario covers Ari’s entire window. The blocked-view",
        "scenario interrupts the inactivity evidence with one unknown minute.",
        "",
        "Case-level reasons and review priorities are in detector-results.json.",
        "These results apply only to the supplied synthetic cases.",
    ))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", help="Use and reset an existing loopback demo API.")
    parser.add_argument("--output", type=Path, help="Write the JSON results to this file.")
    parser.add_argument("--report", type=Path, help="Write a readable summary to this file.")
    options = parser.parse_args()
    with demo_client(options.url) as client:
        results = replay(client)
    rendered = json.dumps(results, indent=2, ensure_ascii=False) + "\n"
    if options.output:
        options.output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")
    if options.report:
        options.report.write_text(report(results), encoding="utf-8")


if __name__ == "__main__":
    main()
