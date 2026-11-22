#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

export SAHANA_MODE=live
api_only=false
reduced_actions=false
for option in "$@"; do
    case "$option" in
        --demo) SAHANA_MODE=demo ;;
        --api-only) api_only=true ;;
        --reduced-actions) reduced_actions=true ;;
        *) echo "Usage: $0 [--api-only] [--demo | --reduced-actions]" >&2; exit 2 ;;
    esac
done

if [[ "$reduced_actions" == true ]]; then
    if [[ "$SAHANA_MODE" != live || "$api_only" == true ]]; then
        echo "--reduced-actions starts the live app with the installed reduced-scope model." >&2
        exit 2
    fi
    reduced_model="$PWD/training/models/reduced/SAHANAMovementReduced.mlmodelc"
    if [[ ! -d "$reduced_model" || ! -f "$PWD/training/models/reduced/model-info.json" ]]; then
        echo "The evaluated reduced-scope model needs to be installed before launch." >&2
        exit 1
    fi
    export SAHANA_ACTION_MODEL="$reduced_model"
fi

umask 077
runtime="${SAHANA_RUNTIME_DIR:-$PWD/.sahana-runtime/$SAHANA_MODE}"
mkdir -p "$runtime"
export SAHANA_DB="${SAHANA_DB:-$PWD/sahana-$SAHANA_MODE.sqlite3}"

if [[ ! -x .venv/bin/python ]]; then
    if command -v python3.13 >/dev/null; then
        python3.13 -m venv .venv
    else
        python3 -m venv .venv
    fi
fi

if ! .venv/bin/python -c 'import fastapi, uvicorn' >/dev/null 2>&1; then
    .venv/bin/python -m pip install -r requirements.txt
fi

if [[ "$SAHANA_MODE" == live ]]; then
    installed="$PWD/training/models/live/SAHANAMovement.mlmodelc"
    if [[ "$reduced_actions" == false && -d "$installed" && -f "$PWD/training/models/live/model-info.json" ]]; then
        export SAHANA_ACTION_MODEL="$installed"
    fi
    if [[ -z "${SAHANA_PORT:-}" && -s "$runtime/url" && -s "$runtime/token" ]]; then
        read -r existing_url < "$runtime/url"
        read -r existing_token < "$runtime/token"
        if [[ "$existing_url" =~ ^http://127\.0\.0\.1:[0-9]{4,5}$ ]] &&
            curl --noproxy '*' -fsS --max-time 2 -H "Authorization: Bearer $existing_token" \
                "$existing_url/people" >/dev/null 2>&1; then
            export SAHANA_API_URL="$existing_url" SAHANA_API_TOKEN="$existing_token"
            if [[ "$api_only" == false ]]; then ./caregiver/run.sh; fi
            echo "SAHANA is already running at $SAHANA_API_URL/docs"
            exit 0
        fi
    fi
    export SAHANA_API_TOKEN="${SAHANA_API_TOKEN:-$(.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(32))')}"
fi

port="${SAHANA_PORT:-8000}"
if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1024 || 10#$port > 65535 )); then
    echo "SAHANA_PORT must be a port between 1024 and 65535." >&2
    exit 1
fi
port=$((10#$port))
while /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
    if [[ -n "${SAHANA_PORT:-}" ]] || (( port == 8010 )); then
        echo "Port $port is already in use. Set SAHANA_PORT to an available local port." >&2
        exit 1
    fi
    port=$((port + 1))
done
export SAHANA_API_URL="http://127.0.0.1:$port"
health_url="$SAHANA_API_URL/status"

.venv/bin/python -m uvicorn sahana.api:app --host 127.0.0.1 --port "$port" --no-access-log &
api_pid=$!
trap 'kill "$api_pid" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

ready=false
for attempt in {1..40}; do
    if ! kill -0 "$api_pid" 2>/dev/null; then
        break
    fi
    if curl --noproxy '*' -fsS --max-time 1 "$health_url" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.25
done

if [[ "$ready" != true ]]; then
    echo "SAHANA's API did not start. Check the error above." >&2
    exit 1
fi

if [[ "$SAHANA_MODE" == live ]]; then
    printf '%s\n' "$SAHANA_API_TOKEN" > "$runtime/token"
    printf '%s\n' "$SAHANA_API_URL" > "$runtime/url"
fi
if [[ "$api_only" == false ]]; then
    ./caregiver/run.sh
fi
echo "SAHANA API is running at $SAHANA_API_URL/docs"
echo "Keep this Terminal window open. Press Control-C to stop the API."
wait "$api_pid"
