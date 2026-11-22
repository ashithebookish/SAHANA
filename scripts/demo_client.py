"""Use the same API requests against an isolated demo or a running local server."""
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory

from fastapi.testclient import TestClient
from httpx import Client, URL

from sahana.api import create_app


@contextmanager
def demo_client(url):
    if url:
        address = URL(url)
        if address.scheme != "http" or address.host not in {"localhost", "127.0.0.1", "::1"}:
            raise ValueError("Use an HTTP loopback URL for the resettable synthetic demo.")
        with Client(base_url=url, timeout=10, trust_env=False) as client:
            yield client
    else:
        with TemporaryDirectory() as directory:
            with TestClient(create_app(Path(directory) / "demo.sqlite3"),
                            base_url="http://127.0.0.1") as client:
                yield client


def request(client, method, path, **kwargs):
    response = client.request(method, path, **kwargs)
    response.raise_for_status()
    return response.json()


def epoch(iso_timestamp):
    return int(datetime.fromisoformat(iso_timestamp).timestamp())
