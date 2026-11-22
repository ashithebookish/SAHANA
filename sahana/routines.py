"""Explainable time-of-day comparison using independent calibration samples."""
import json
import re
from datetime import datetime
from pathlib import Path
from unicodedata import normalize
from zoneinfo import ZoneInfo

CALIBRATION = json.loads(
    (Path(__file__).resolve().parent.parent / "fixtures/calibration.json").read_text()
)
ZONE = ZoneInfo(CALIBRATION["timezone"])
OPTIONAL_MOVEMENT_SOURCES = {"optional_movement", "camera"}
MOTION_LABELS = {
    "still_in_view": "Still in view",
    "seated_reposition": "Repositioned while seated",
    "reach_or_lean": "Reached or leaned",
    "rise_from_seat": "Rose from a seat",
    "lower_to_seat": "Lowered onto a seat",
    "seated_transfer": "Transferred between seats",
    "stepping": "Took steps",
    "other_expected_motion": "Other movement observed",
    "zone_enter": "Entered the observed area",
    "zone_exit": "Left the observed area",
    "seated_travel": "Moved through the observed area while seated",
}
MAX_COVERAGE_SECONDS = 60
INACTIVITY_SECONDS = 600
APPROVED_ROOM = "Common room"
BUILTIN_ROUTINES = {"breakfast", "lunch", "common_room_presence", "common_room_activity"}


def minutes(hhmm):
    hour, minute = map(int, hhmm.split(":"))
    return hour * 60 + minute


def format_minutes(value):
    hour, minute = divmod(value, 60)
    return f"{hour:02d}:{minute:02d}"


def routine_signal(name):
    return re.sub(r"[\W_]+", "_", normalize("NFC", name).casefold()).strip("_")


def window(person, detector, signal="breakfast"):
    if signal == "breakfast":
        shared = ("07:30", "08:30")
        values = [row[person] for row in CALIBRATION["samples"]]
    else:
        calibration = CALIBRATION["other_signals"].get(signal)
        if calibration is None:
            return None
        shared = calibration["shared_window"]
        values = calibration[person]
    if detector == "fixed":
        return tuple(map(minutes, shared))
    samples = list(map(minutes, values))
    return min(samples) - 10, max(samples) + 10


def signal_for(kind, room, routine):
    if kind == "breakfast":
        return "breakfast"
    if kind == "routine" and routine:
        signal = routine_signal(routine)
        if signal and signal not in {"common_room_presence", "common_room_activity"}:
            return signal
    if kind in {"presence", "activity"} and (room or "").casefold() == "common room":
        return f"common_room_{kind}"
    return None


def explain(person, kind, observation, observed_at, detector, *, room=None, routine=None, get_window=window,
            routine_name=None, single_observation_alert=True):
    """Return an explanation and whether the evidence supports a check-in."""
    if observation == "missing":
        return "Observation missing. Activity is unknown.", False
    if kind == "facial":
        return "Unconfirmed staged facial movement.", False
    local = datetime.fromtimestamp(observed_at, ZONE)
    minute = local.hour * 60 + local.minute
    baseline = "the usual" if detector == "personalized" else "the shared"
    signal = signal_for(kind, room, routine)
    if signal and kind in {"breakfast", "routine"}:
        title = signal.title() if signal in BUILTIN_ROUTINES else (routine_name or routine.replace("_", " "))
        bounds = get_window(person, detector, signal)
        if bounds is None:
            return f"{title} recorded at {local:%H:%M}. No usual window is configured.", False
        start, end = bounds
        outside = not start <= minute <= end
        relation = "outside" if outside else "inside"
        return (
            f"{title} recorded at {local:%H:%M}, {relation} {baseline} "
            f"{format_minutes(start)}–{format_minutes(end)} window.",
            outside,
        )
    if signal and observation in {"absent", "inactive"}:
        bounds = get_window(person, detector, signal)
        if bounds is None:
            return "Common room observation recorded. No usual window is configured.", False
        start, end = bounds
        inside = start <= minute <= end
        relation = "inside" if inside else "outside"
        description = "Absence" if observation == "absent" else "Inactivity"
        coverage = " Duration is unknown." if not single_observation_alert else ""
        return (
            f"{description} observed in the common room at {local:%H:%M}, {relation} {baseline} "
            f"{format_minutes(start)}–{format_minutes(end)} {kind} window.{coverage}",
            inside and single_observation_alert,
        )
    return {
        "present": "Presence recorded.",
        "absent": "Absence observed.",
        "active": "Activity observed.",
        "inactive": "Inactivity observed.",
        "completed": "Routine completion recorded.",
    }[observation], False


def interrupts_coverage(event, kind):
    observed_kind, observation = event["kind"], event["observation"]
    if observation == "missing":
        return True
    if observed_kind == "motion":
        return kind == "presence" or observation != "still_in_view"
    if kind == "presence":
        return observed_kind == "activity" or observation == "present"
    return observation in {"absent", "active"}


def coverage_start(events, kind, target, start, end):
    """Find the uninterrupted known interval ending at the time under review."""
    earliest = start
    for event in events:
        observed = event["observed_at"]
        began = event["coverage_start"]
        if began is None:
            began = observed
        if began <= end and interrupts_coverage(event, kind):
            earliest = max(earliest, min(end, observed))

    cursor = end
    for event in sorted(events, key=lambda row: row["observed_at"], reverse=True):
        if event["observed_at"] < cursor:
            break
        began = event["coverage_start"]
        if (event["kind"] == kind and event["observation"] == target
                and began is not None and began <= cursor):
            cursor = max(began, earliest)
    return cursor


def explain_optional(person, kind, observation, observed_at, detector, events, *, get_window=window, live=False):
    """Evaluate covered intervals and report individual observations neutrally."""
    if observation == "missing":
        return "Observation missing. Activity is unknown.", False
    if kind == "motion":
        title = MOTION_LABELS[observation]
        bounds = get_window(person, detector, observation)
        if bounds is None:
            return f"{title} recorded during optional monitoring.", False
        local = datetime.fromtimestamp(observed_at, ZONE)
        minute = local.hour * 60 + local.minute
        start, end = bounds
        relation = "inside" if start <= minute <= end else "outside"
        return (
            f"{title} at {local:%H:%M}, {relation} the configured movement window "
            f"({format_minutes(start)}–{format_minutes(end)}).", False,
        )

    signal = signal_for(kind, APPROVED_ROOM, None)
    target = "absent" if kind == "presence" else "inactive"
    if observation != target:
        return explain(person, kind, observation, observed_at, detector, room=APPROVED_ROOM, get_window=get_window)

    local = datetime.fromtimestamp(observed_at, ZONE)
    midnight = int(local.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
    bounds = get_window(person, detector, signal)
    if bounds is None:
        return "Common room observation recorded. No usual window is configured.", False
    start, end = bounds
    window_start, window_end = midnight + start * 60, midnight + end * 60
    anchor = min(observed_at, window_end)
    baseline = "usual" if detector == "personalized" else "shared"
    hours = f"{format_minutes(start)}–{format_minutes(end)}"
    began = coverage_start(events, kind, target, window_start, anchor) if anchor > window_start else anchor
    seconds_observed = anchor - began
    if not live and kind == "presence" and observed_at >= window_end and began == window_start:
        return f"No visit was observed during the {baseline} common room window ({hours}).", True
    ready = (
        seconds_observed >= INACTIVITY_SECONDS if live
        else kind == "activity" and seconds_observed > INACTIVITY_SECONDS
    )
    if ready:
        minutes_observed, remaining = divmod(seconds_observed, 60)
        length = f"{minutes_observed} min {remaining:02d} sec"
        description = "No visit" if kind == "presence" else "No activity"
        return (
            f"{description} was observed for {length} during the {baseline} common room "
            f"{kind} window ({hours}).", True,
        )
    description = "Absence" if kind == "presence" else "Inactivity"
    return f"{description} observed at {local:%H:%M}. More known coverage or routine time is needed.", False

