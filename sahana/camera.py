"""A short-lived, consent-controlled camera frame relay."""

from dataclasses import dataclass
from secrets import compare_digest, token_urlsafe
from threading import Lock
from time import monotonic

from fastapi import HTTPException


LEASE_SECONDS = 10
FRAME_SECONDS = 2
MAX_FRAME_BYTES = 512 * 1024
JPEG_SOF = {0xC0, 0xC1, 0xC2}
FRAME_HEADERS = {"Cache-Control": "no-store, private", "X-Content-Type-Options": "nosniff"}


def validate_jpeg(frame: bytes):
    """Require a bounded JPEG, with supported dimensions in its frame header."""
    if not frame.startswith(b"\xff\xd8") or not frame.endswith(b"\xff\xd9"):
        raise HTTPException(415, "A JPEG frame is required.")
    pos = 2
    while pos + 4 < len(frame) and frame[pos] == 0xFF:
        marker = frame[pos + 1]
        if marker in {0xDA, 0xD9}:
            break
        if marker == 0xFF:
            pos += 1
            continue
        length = int.from_bytes(frame[pos + 2:pos + 4], "big")
        if length < 2 or pos + 2 + length > len(frame):
            break
        if marker in JPEG_SOF and length >= 8:
            height = int.from_bytes(frame[pos + 5:pos + 7], "big")
            width = int.from_bytes(frame[pos + 7:pos + 9], "big")
            if not 0 < min(width, height) <= 1080 or max(width, height) > 1920:
                raise HTTPException(422, "Resize the JPEG frame to 1920 by 1080 or smaller.")
            return
        pos += 2 + length
    raise HTTPException(415, "The JPEG frame header is invalid.")


@dataclass
class Lease:
    person: str
    token: str
    started_at: int
    expires_at: float
    sequence: int = 0
    frame: bytes | None = None
    frame_at: float = 0


class CameraRelay:
    """Hold one local camera lease and its newest frame for the current viewer."""

    def __init__(self, clock=monotonic):
        self._lease: Lease | None = None
        self._lock = Lock()
        self._clock = clock

    def _current(self, now):
        if self._lease and self._lease.expires_at <= now:
            self._lease = None
        elif self._lease and self._lease.frame_at + FRAME_SECONDS <= now:
            self._lease.frame = None
        return self._lease

    def start(self, person: str, now: int) -> str:
        with self._lock:
            current = self._clock()
            if self._current(current):
                raise HTTPException(409, "SAHANA already has an active camera session.")
            token = token_urlsafe(32)
            self._lease = Lease(person, token, now, current + LEASE_SECONDS)
            return token

    def _authorize(self, person: str, token: str | None, now: float):
        lease = self._current(now)
        if lease is None or lease.person != person:
            raise HTTPException(409, "The camera session has ended.")
        if token is None or not compare_digest(lease.token.encode(), token.encode()):
            raise HTTPException(403, "The camera session credential does not match.")
        return lease

    def authorize(self, person: str, token: str | None):
        with self._lock:
            return self._authorize(person, token, self._clock()).started_at

    def put(self, person: str, token: str | None, frame: bytes):
        with self._lock:
            now = self._clock()
            lease = self._authorize(person, token, now)
            lease.sequence += 1
            lease.frame = frame
            lease.frame_at = now
            lease.expires_at = now + LEASE_SECONDS

    def state(self, person: str):
        with self._lock:
            lease = self._current(self._clock())
            if lease is None or lease.person != person:
                return False, False, None
            return True, lease.frame is not None, lease.started_at

    def frame(self, person: str):
        with self._lock:
            lease = self._current(self._clock())
            if lease is None or lease.person != person or lease.frame is None:
                return None
            return lease.token, lease.sequence, lease.frame

    def stop(self, person: str, token: str | None):
        with self._lock:
            now = self._clock()
            lease = self._current(now)
            if lease is not None and lease.person == person:
                self._authorize(person, token, now)
                self._lease = None

    def revoke(self, person: str):
        with self._lock:
            if self._lease is not None and self._lease.person == person:
                self._lease = None

    def expire(self):
        with self._lock:
            self._current(self._clock())
