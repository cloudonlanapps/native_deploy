#!/usr/bin/env bash
#
# start_db.sh — start a native PostgreSQL instance for local development.
#
# Replaces Docker-based postgres — no VM, no Docker daemon. Just a native
# postgres process with its own isolated data directory.
#
# Usage:
#   ./start_db.sh                          # defaults: port 5437, data ~/.local/share/club_server/dev
#   ./start_db.sh --db-port 5440           # custom port
#   ./start_db.sh --data-dir /tmp/mydata   # custom data directory (project isolation)
#   ./start_db.sh --reset                  # drop all public tables
#   ./start_db.sh --stop                   # stop the postgres instance
#
# Prerequisites:
#   macOS:  brew install postgresql@16
#   Linux:  sudo apt install postgresql  (or equivalent)

set -e

# ── Defaults ──────────────────────────────────────────────────────────────────
DB_PORT=5437
POSTGRES_DB="myclub"
POSTGRES_USER="myclub"
# The cluster is created with --auth=trust (see initdb below), so this value
# never authenticates anything — it only fills in the DATABASE_URL string.
# tests/conftest.py hardcodes the same default. Override via the environment
# if you need a specific value; do not reintroduce a secret-store lookup, or
# starting and *stopping* a throwaway local DB depends on the store.
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-devpass}"
DATA_DIR="${START_DEV_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/club_server/dev}"
RESET_DB=false
STOP_ONLY=false

# ── Parse args ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case $1 in
        --db-port)    shift; DB_PORT="$1" ;;
        --db-port=*)  DB_PORT="${1#*=}" ;;
        --data-dir)   shift; DATA_DIR="$1" ;;
        --data-dir=*) DATA_DIR="${1#*=}" ;;
        --reset)      RESET_DB=true ;;
        --stop)       STOP_ONLY=true ;;
        -h|--help)    sed -n '3,16p' "$0"; exit 0 ;;
        *)            echo "Unknown option: $1 (use --help)" >&2; exit 1 ;;
    esac
    shift
done

# Normalize to absolute path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$DATA_DIR" != /* ]]; then
    DATA_DIR="$SCRIPT_DIR/$DATA_DIR"
fi

DB_DIR="$DATA_DIR/db"
LOG_FILE="$DATA_DIR/postgres.log"

# ── Locate PostgreSQL binaries ────────────────────────────────────────────────
# 1. Check PATH (works on Linux, or if user added Homebrew to PATH)
# 2. Homebrew on Apple Silicon: /opt/homebrew/opt/postgresql@16/bin
# 3. Homebrew on Intel Mac:     /usr/local/opt/postgresql@16/bin
# 4. Linux Debian/Ubuntu:       /usr/lib/postgresql/<version>/bin
# 5. Linux RHEL/Fedora:         /usr/pgsql-<version>/bin
#
# The Linux fallbacks matter when start_db.sh is invoked from a non-login,
# non-interactive shell (e.g. tmux new-session -d) where ~/.bashrc returns
# early and the user's PATH additions never run.
find_pg_bin() {
    if command -v pg_ctl >/dev/null 2>&1; then
        PG_BIN="$(dirname "$(command -v pg_ctl)")"
    elif [ -x "/opt/homebrew/opt/postgresql@16/bin/pg_ctl" ]; then
        PG_BIN="/opt/homebrew/opt/postgresql@16/bin"
    elif [ -x "/usr/local/opt/postgresql@16/bin/pg_ctl" ]; then
        PG_BIN="/usr/local/opt/postgresql@16/bin"
    elif [ -x "/usr/lib/postgresql/17/bin/pg_ctl" ]; then
        PG_BIN="/usr/lib/postgresql/17/bin"
    elif [ -x "/usr/lib/postgresql/16/bin/pg_ctl" ]; then
        PG_BIN="/usr/lib/postgresql/16/bin"
    elif [ -x "/usr/lib/postgresql/15/bin/pg_ctl" ]; then
        PG_BIN="/usr/lib/postgresql/15/bin"
    elif [ -x "/usr/lib/postgresql/14/bin/pg_ctl" ]; then
        PG_BIN="/usr/lib/postgresql/14/bin"
    elif [ -x "/usr/pgsql-17/bin/pg_ctl" ]; then
        PG_BIN="/usr/pgsql-17/bin"
    elif [ -x "/usr/pgsql-16/bin/pg_ctl" ]; then
        PG_BIN="/usr/pgsql-16/bin"
    elif [ -x "/usr/pgsql-15/bin/pg_ctl" ]; then
        PG_BIN="/usr/pgsql-15/bin"
    else
        echo "ERROR: PostgreSQL not found." >&2
        echo "" >&2
        echo "Install it:" >&2
        echo "  macOS:  brew install postgresql@16" >&2
        echo "  Ubuntu: sudo apt install postgresql-16" >&2
        echo "  Fedora: sudo dnf install postgresql-server" >&2
        exit 1
    fi
}

find_pg_bin

PG_CTL="$PG_BIN/pg_ctl"
INITDB="$PG_BIN/initdb"
PSQL="$PG_BIN/psql"
CREATEDB="$PG_BIN/createdb"

# ── Stop mode ─────────────────────────────────────────────────────────────────
if [ "$STOP_ONLY" = true ]; then
    if "$PG_CTL" status -D "$DB_DIR" >/dev/null 2>&1; then
        echo "==> Stopping PostgreSQL (data: $DB_DIR)..."
        "$PG_CTL" stop -D "$DB_DIR" -m fast
        echo "    Stopped."
    else
        echo "    PostgreSQL is not running (data: $DB_DIR)."
    fi
    exit 0
fi

echo "==> start_db"
echo "    port:     $DB_PORT"
echo "    data:     $DB_DIR"
echo "    database: $POSTGRES_DB"
echo "    user:     $POSTGRES_USER"
echo "    reset:    $RESET_DB"

# ── Initialize data directory on first use ────────────────────────────────────
if [ ! -f "$DB_DIR/PG_VERSION" ]; then
    echo ""
    echo "==> Initializing new PostgreSQL data directory..."
    mkdir -p "$DB_DIR"
    "$INITDB" -D "$DB_DIR" --username="$POSTGRES_USER" --auth=trust --no-locale -E UTF8
    echo "    Initialized at $DB_DIR"
fi

# ── Start postgres if not already running ─────────────────────────────────────
if "$PG_CTL" status -D "$DB_DIR" >/dev/null 2>&1; then
    # Verify it's reachable on the expected port
    if "$PSQL" -U "$POSTGRES_USER" -d postgres -h localhost -p "$DB_PORT" -tAc "SELECT 1" >/dev/null 2>&1; then
        echo ""
        echo "==> PostgreSQL is already running on port $DB_PORT."
    else
        echo ""
        echo "WARNING: PostgreSQL is running from $DB_DIR but not reachable on port $DB_PORT." >&2
        echo "         Restarting on port $DB_PORT..." >&2
        "$PG_CTL" stop -D "$DB_DIR" -m fast
        mkdir -p "$DATA_DIR"
        "$PG_CTL" start -D "$DB_DIR" -l "$LOG_FILE" -o "-p $DB_PORT -k /tmp"
        echo "    Restarted on port $DB_PORT."
    fi
else
    echo ""
    echo "==> Starting PostgreSQL on port $DB_PORT..."
    mkdir -p "$DATA_DIR"
    "$PG_CTL" start -D "$DB_DIR" -l "$LOG_FILE" -o "-p $DB_PORT -k /tmp"
    echo "    Started. Log: $LOG_FILE"
fi

# ── Wait for ready ────────────────────────────────────────────────────────────
echo "==> Waiting for PostgreSQL to accept connections..."
for _ in $(seq 1 30); do
    if "$PSQL" -U "$POSTGRES_USER" -d postgres -h localhost -p "$DB_PORT" -c "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! "$PSQL" -U "$POSTGRES_USER" -d postgres -h localhost -p "$DB_PORT" -c "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: PostgreSQL did not become ready within 15s." >&2
    echo "       Check log: $LOG_FILE" >&2
    exit 1
fi
echo "    Ready."

# ── Create database if it doesn't exist ───────────────────────────────────────
if ! "$PSQL" -U "$POSTGRES_USER" -h localhost -p "$DB_PORT" -lqt | cut -d\| -f1 | grep -qw "$POSTGRES_DB"; then
    echo "==> Creating database '$POSTGRES_DB'..."
    "$CREATEDB" -U "$POSTGRES_USER" -h localhost -p "$DB_PORT" "$POSTGRES_DB"
    echo "    Created."
else
    echo "==> Database '$POSTGRES_DB' already exists."
fi

# ── Reset (drop all public tables) ───────────────────────────────────────────
if [ "$RESET_DB" = true ]; then
    echo "==> Dropping all tables (--reset)..."
    "$PSQL" -U "$POSTGRES_USER" -h localhost -p "$DB_PORT" -d "$POSTGRES_DB" -c "
DO \$\$
DECLARE
    r RECORD;
BEGIN
    FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
        EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
    END LOOP;
END \$\$;
"
    echo "    All tables dropped."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==> PostgreSQL is running."
# Mask the password: this output routinely ends up in CI logs, tee'd test logs
# and pasted terminal transcripts.
echo "    DATABASE_URL=postgresql+asyncpg://${POSTGRES_USER}:***@localhost:${DB_PORT}/${POSTGRES_DB}"
echo "    Stop with: $0 --stop --data-dir $DATA_DIR"
