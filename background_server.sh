#!/usr/bin/env bash
#
# background_server.sh — layer 1: run a start_server.sh conf detached in tmux.
#
#   background_server.sh <conf> start  [--auto-ports] [--source DIR] [--timeout S]
#   background_server.sh <conf> stop    [port=N db_port=N]
#   background_server.sh <conf> cleanup [port=N db_port=N]
#   background_server.sh <conf> status  [port=N db_port=N]
#   background_server.sh <conf> logs    [port=N db_port=N]
#   background_server.sh <conf> backup  [port=N db_port=N] [--out DIR] [--name N]
#   background_server.sh <conf> restore [port=N db_port=N] [stamp] [--list] [--dry-run]
#
# `start` runs `start_server.sh <conf> [port=… db_port=…]` in a detached tmux
# session named after the run, waits for /health, and prints one JSON line on
# stdout describing the stack (name, base_url, host_url, server_port, db_port,
# run_dir, tmux_session, server_log). Diagnostics go to stderr, so a caller
# can do `json=$(background_server.sh my.conf start --auto-ports)`.
#
# --auto-ports picks two free ports and passes them as overrides, so several
# runs of one conf can coexist; without it the conf's ports are used and a
# second `start` finds the session already running. A conf with debug = true
# is refused: --reload belongs in a terminal, not a detached session.
#
# `backup` and `restore` delegate to backup_server.sh and restore_server.sh,
# which take the same conf and overrides. Restore reads backup/ beside the
# scripts and never contacts a backup host: copying an archive there is a
# separate job.
#
# `stop` ends the run and its cluster; `cleanup` also deletes deployed/<name>/
# (the clone if one was made, the cluster, uploads and log). The conf's
# `source =` is a checkout, relative to the conf file, used in place and never
# deleted, or a git URL cloned at `ref`; --source replaces it with either.
#
# Works from any directory: the conf path is taken relative to the caller,
# the sibling scripts relative to this file.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib_conf.sh"

log() { printf '%s\n' "$*" >&2; }
usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" >&2; exit 1; }

[ $# -ge 2 ] || usage
CONF_ARG="$1"; VERB="$2"; shift 2
AUTO=false; SOURCE=""; TIMEOUT=180; overrides=(); passthru=()
while [ $# -gt 0 ]; do
    case "$1" in
        --auto-ports) AUTO=true ;;
        --source)     shift; SOURCE="$1" ;;
        --source=*)   SOURCE="${1#--source=}" ;;
        --timeout)    shift; TIMEOUT="$1" ;;
        --timeout=*)  TIMEOUT="${1#--timeout=}" ;;
        port=*|db_port=*) overrides+=("$1") ;;
        # backup and restore take their own flags (--out, --list, --dry-run, a
        # stamp); everything unrecognised is handed to them rather than refused
        # here, so the two scripts stay the one place that defines their surface.
        *) passthru+=("$1") ;;
    esac
    shift
done
case "$VERB" in start|stop|cleanup|status|logs|backup|restore) ;; *) log "ERROR: verb must be start, stop, cleanup, status, logs, backup or restore"; usage ;; esac

port_free() { ! ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
pick_free_port() {
    local p
    while :; do p=$(( 20000 + RANDOM % 40000 )); port_free "$p" && { echo "$p"; return; }; done
}
if [ "$AUTO" = true ]; then
    [ "$VERB" = start ] || { log "ERROR: --auto-ports only applies to start"; exit 1; }
    p1="$(pick_free_port)"; p2="$(pick_free_port)"; [ "$p1" = "$p2" ] && p2="$(pick_free_port)"
    overrides=("port=$p1" "db_port=$p2")
fi

conf_parse_args "$CONF_ARG" "${overrides[@]}"     # CONF (absolute), NAME, PORT, DB_PORT, RUN_DIR
HOST_URL="http://127.0.0.1:$PORT"
LOG_FILE="$RUN_DIR/server.log"

session_alive() { tmux has-session -t "$NAME" 2>/dev/null; }
health_ok()     { curl -sf -m 2 "$HOST_URL/health" >/dev/null 2>&1; }
describe() {
    printf '{"name": "%s", "base_url": "%s/v1", "host_url": "%s", "server_port": %s, "db_port": %s, "run_dir": "%s", "tmux_session": "%s", "server_log": "%s"}\n' \
        "$NAME" "$HOST_URL" "$HOST_URL" "$PORT" "$DB_PORT" "$RUN_DIR" "$NAME" "$LOG_FILE"
}
do_stop() {   # do_stop [--remove]
    tmux kill-session -t "$NAME" 2>/dev/null || true
    "$HERE/stop_server.sh" "$CONF" "${overrides[@]}" "$@"
}

case "$VERB" in
start)
    if [ "$(ini_get server debug "$CONF")" = "true" ]; then
        log "ERROR: $CONF has debug = true; run it in a terminal with start_server.sh, not detached."; exit 1
    fi
    if session_alive; then
        log "ERROR: tmux session $NAME is already running (stop it, or use --auto-ports)."; exit 1
    fi
    mkdir -p "$RUN_DIR"
    cmd="$(printf '%q ' "$HERE/start_server.sh" "$CONF" "${overrides[@]}")"
    [ -n "$SOURCE" ] && cmd+="$(printf '%q ' --source "$SOURCE")"
    inner="export PATH=$(printf '%q' "$PATH"); $cmd 2>&1 | tee $(printf '%q' "$LOG_FILE")"
    log "==> starting $NAME  server=$PORT  db=$DB_PORT"
    log "==> tmux session: $NAME   (attach: tmux attach -t $NAME)"
    log "==> log: $LOG_FILE"
    tmux new-session -d -s "$NAME" "$inner"
    deadline=$(( $(date +%s) + TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if health_ok; then log "    ready."; describe; exit 0; fi
        if ! session_alive; then
            log "ERROR: the session ended before the server became ready."; tail -n 40 "$LOG_FILE" >&2 || true
            do_stop; exit 1
        fi
        sleep 1
    done
    log "ERROR: no /health within ${TIMEOUT}s."; tail -n 40 "$LOG_FILE" >&2 || true; do_stop; exit 1 ;;
stop)    do_stop ;;
cleanup) do_stop --remove ;;
status)
    if session_alive && health_ok; then log "$NAME: running, /health ok"; describe; exit 0; fi
    log "$NAME: tmux $(session_alive && echo running || echo 'not running'), /health $(health_ok && echo ok || echo 'no answer')"; exit 1 ;;
logs)   [ -f "$LOG_FILE" ] || { log "no log at $LOG_FILE"; exit 1; }; tail -n 60 "$LOG_FILE" ;;
backup)  "$HERE/backup_server.sh"  "$CONF" "${overrides[@]}" ${passthru[@]+"${passthru[@]}"} ;;
restore) "$HERE/restore_server.sh" "$CONF" "${overrides[@]}" ${passthru[@]+"${passthru[@]}"} ;;
esac
