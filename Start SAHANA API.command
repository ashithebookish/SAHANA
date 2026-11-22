#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -f "$project/scripts/judge_api.py" ]]; then
    project="$(dirname "$project")"
fi
cd "$project"

if [[ "${1:-}" == "--demo" ]]; then
    exec "$project/Start SAHANA.command" --api-only "$@"
fi

if [[ ! -x .venv/bin/python ]]; then
    python3 -m venv .venv
fi
if ! .venv/bin/python -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
    .venv/bin/python -m pip install -r requirements.txt
fi

exec .venv/bin/python -m scripts.judge_api "$@"
