"""Run the browser camera test against a fresh local SAHANA API."""

import argparse
from pathlib import Path
from secrets import token_urlsafe
from tempfile import TemporaryDirectory


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8012, help="Loopback port (default: 8012).")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("--port must be between 1024 and 65535.")

    import uvicorn

    from sahana.api import create_app

    token = token_urlsafe(32)
    with TemporaryDirectory(prefix="sahana-judge-") as directory:
        app = create_app(Path(directory) / "camera.sqlite3", mode="live", token=token, camera_test=True)
        print(f"Camera test: http://127.0.0.1:{args.port}/camera-test", flush=True)
        print(f"Local test token: {token}", flush=True)
        print("Paste the token into the camera test page. Keep this Terminal window open.", flush=True)
        uvicorn.run(app, host="127.0.0.1", port=args.port, access_log=False, proxy_headers=False)


if __name__ == "__main__":
    main()
