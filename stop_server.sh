#!/usr/bin/env bash
# stop_server — stop the cluster of a run started by start_server, and kill a
# uvicorn still holding its port. Usage mirrors start_server:
#   ./stop_server.sh sample.conf [port=… db_port=…] [--remove]
# --remove also deletes deployed/<name>/ (the clone if one was made, cluster,
# uploads, log). A checkout named by --source / [product] source is never
# touched.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib_conf.sh"
REMOVE=false
args=()
for a in "$@"; do [ "$a" = "--remove" ] && REMOVE=true || args+=("$a"); done
conf_parse_args "${args[@]}"
echo "==> stop_server  $NAME"
pids="$(ss -ltnHp "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
for pid in $pids; do kill -TERM "-$(ps -o pgid= "$pid" | tr -d ' ')" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true; done
[ -n "$pids" ] && sleep 1
[ -d "$RUN_DIR/data" ] && "$HERE/start_db.sh" --stop --data-dir "$RUN_DIR/data" || true
if [ "$REMOVE" = true ]; then rm -rf "$RUN_DIR"; echo "    removed $RUN_DIR"; fi
