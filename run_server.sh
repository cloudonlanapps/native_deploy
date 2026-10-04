#!/usr/bin/env bash
#
# run_server — layer 3: run club_server natively from the environment alone.
#
# Everything comes from environment variables; nothing is defaulted here.
# `start_server.sh <conf>` (layer 2) exports them from a conf file; this script
# is what runs when every one of them is set by hand instead.
#
# Its own variables:
#   SERVER_DIR          club_server checkout (holds pyproject.toml, alembic/)
#   SERVER_PORT         port uvicorn listens on
#   DB_PORT             PostgreSQL port
#   DATA_DIR            directory for the cluster, uploads, static and logs
#   BOOTSTRAP_PASSWORD  password of the `sudo` super-admin it creates
#   DEBUG               "true" runs uvicorn with --reload (optional)
#
# Plus whatever club_server's Settings require (DATABASE_URL, SECRET_KEY,
# UPLOAD_DIR, STATIC_DIR, CORS_ALLOWED_ORIGINS, the club identity and the
# email settings); the server refuses to start without them, and so does this.
#
# Steps: start the cluster (start_db.sh, carried here), uv sync, alembic
# upgrade head, club_bootstrap, uvicorn in the foreground. Ctrl+C stops
# uvicorn and then the cluster.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

required=(SERVER_DIR SERVER_PORT DB_PORT DATA_DIR BOOTSTRAP_PASSWORD
          DATABASE_URL SECRET_KEY UPLOAD_DIR STATIC_DIR CORS_ALLOWED_ORIGINS
          CLUB_NAME CLUB_SHORT_NAME LOGIN_URL SERVER_BASE_URL
          EMAIL_FROM_TRANSACTIONAL EMAIL_FROM_BROADCAST EMAIL_THEME_COLOR)
missing=()
for v in "${required[@]}"; do
    [ -n "${!v:-}" ] || missing+=("$v")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: run_server needs these environment variables set: ${missing[*]}" >&2
    exit 1
fi
[ -f "$SERVER_DIR/pyproject.toml" ] || { echo "ERROR: SERVER_DIR=$SERVER_DIR is not a club_server checkout" >&2; exit 1; }

echo "==> run_server"
echo "    server:   http://localhost:$SERVER_PORT   (debug: ${DEBUG:-false})"
echo "    db port:  $DB_PORT"
echo "    data:     $DATA_DIR"
echo "    source:   $SERVER_DIR"
mkdir -p "$UPLOAD_DIR" "$STATIC_DIR"

"$HERE/start_db.sh" --db-port "$DB_PORT" --data-dir "$DATA_DIR"
trap '"$HERE/start_db.sh" --stop --data-dir "$DATA_DIR"' EXIT

cd "$SERVER_DIR"
echo "==> uv sync";            uv sync --frozen
echo "==> alembic upgrade";    uv run --frozen alembic upgrade head
echo "==> bootstrap sudo";     uv run --frozen club_bootstrap "$BOOTSTRAP_PASSWORD"

args=(club_server.main:app --host 0.0.0.0 --port "$SERVER_PORT")
[ "${DEBUG:-false}" = "true" ] && args+=(--reload)
echo "==> uvicorn ${args[*]}"
uv run --frozen uvicorn "${args[@]}"
