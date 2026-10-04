#!/usr/bin/env bash
# restore_server — load a backup into a native run, replacing its database,
# uploaded media and static tree. Usage mirrors the other scripts:
#   ./restore_server.sh sample.conf [port=… db_port=…] [<stamp>] [--list] [--dry-run]
#                       [--backup-dir DIR]
#
# Reads backup/ beside this script and NOTHING ELSE. It does not contact a
# backup host and needs no credentials for one — a restore target is often the
# public-facing machine, and giving it reach into the backup store is the wrong
# trade. Copying an archive here is a separate job, done by a person or an
# rsync from the backup side.
#
#   backup/<name>-<stamp>.tar.gz   the database archive
#   backup/files/uploads/          uploaded media
#   backup/files/static/           static tree
#
# DESTRUCTIVE: the run's database is dropped and recreated, and its uploads and
# static trees are replaced. Use --dry-run first; it resolves everything and
# touches nothing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib_conf.sh"

BACKUP_DIR=""; SEL=""; LIST=false; DRY=false
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list)           LIST=true ;;
        --dry-run)        DRY=true ;;
        --backup-dir)     shift; BACKUP_DIR="$1" ;;
        --backup-dir=*)   BACKUP_DIR="${1#--backup-dir=}" ;;
        port=*|db_port=*) args+=("$1") ;;
        -*)               echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
        *)                if [ ${#args[@]} -eq 0 ]; then args+=("$1"); else SEL="$1"; fi ;;
    esac
    shift
done
conf_parse_args "${args[@]}"     # CONF, NAME, PORT, DB_PORT, RUN_DIR
BACKUP_DIR="${BACKUP_DIR:-$HERE/backup}"

DB_NAME="$(ini_get server db_name "$CONF")"; DB_NAME="${DB_NAME:-myclub}"
DB_USER="$(ini_get server db_user "$CONF")"; DB_USER="${DB_USER:-myclub}"
ADMIN_URL="postgresql://$DB_USER@localhost:$DB_PORT/postgres"
DB_URL="postgresql://$DB_USER@localhost:$DB_PORT/$DB_NAME"

if [ "$LIST" = true ]; then
    echo "Archives in $BACKUP_DIR:"
    found=0
    while read -r f; do
        [ -z "$f" ] && continue
        found=1
        printf '  %-40s %8s  %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
            "$(date -r "$f" '+%Y-%m-%d %H:%M')"
    done < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null || true)
    if [ "$found" != 1 ]; then
        echo "  (none)"
        echo
        echo "Copy a backup here first — nothing in this script fetches one."
        echo "Expected:"
        echo "  <name>-<stamp>.tar.gz   the database archive"
        echo "  files/uploads/          uploaded media"
        echo "  files/static/           static tree"
    fi
    [ -d "$BACKUP_DIR/files" ] && echo && echo "File tree: $BACKUP_DIR/files (present)"
    exit 0
fi

# --- Resolve the archive -----------------------------------------------------
if [ -n "$SEL" ]; then
    if   [ -f "$SEL" ];                          then SRC="$SEL"
    elif [ -f "$BACKUP_DIR/$SEL" ];              then SRC="$BACKUP_DIR/$SEL"
    else SRC="$(ls -1 "$BACKUP_DIR"/*"$SEL"*.tar.gz 2>/dev/null | head -1 || true)"; fi
    [ -n "${SRC:-}" ] && [ -f "$SRC" ] || { echo "ERROR: no archive matching '$SEL' in $BACKUP_DIR" >&2; exit 1; }
else
    SRC="$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)"
    [ -n "$SRC" ] || { echo "ERROR: no *.tar.gz in $BACKUP_DIR. Copy one here first — nothing fetches it." >&2; exit 1; }
    echo "==> No archive given; using the newest: $(basename "$SRC")"
fi
FILES_DIR="$(dirname "$SRC")/files"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
gzip -dc "$SRC" > "$WORK/dump.tar" 2>/dev/null \
    || { echo "ERROR: $SRC is not gzip." >&2; exit 1; }

# --- Schema guard ------------------------------------------------------------
# Restoring an archive whose schema does not match the running code leaves a
# database the server cannot use. Deploy the matching code rather than forcing.
# Read the value out of the COPY block rather than pattern-matching it. Half
# the revision ids in club_server are not hex (i9d0e1f2a3b4, g1h2i3j4k5l6),
# and alembic does not promise a length either, so a character class here
# silently matches nothing — and an empty result skips the guard below, which
# is precisely the check it exists to make.
ARCHIVE_REV="$(pg_restore --data-only -t alembic_version -f - "$WORK/dump.tar" 2>/dev/null \
    | awk '/^COPY .*alembic_version/ {c=1; next} c && /^\\\./ {exit} c && NF {print; exit}' || true)"
TARGET_REV="$(psql "$DB_URL" -tAc "select version_num from alembic_version" 2>/dev/null | tr -d ' ' || true)"

echo "conf      : $CONF"
echo "run       : $NAME  (server $PORT, db $DB_PORT)"
echo "archive   : $SRC"
echo "files     : $FILES_DIR $([ -d "$FILES_DIR" ] && echo "(present)" || echo "(absent — database only)")"
echo "schema    : archive ${ARCHIVE_REV:-unknown}  target ${TARGET_REV:-none}"

if [ -n "$ARCHIVE_REV" ] && [ -n "$TARGET_REV" ] && [ "$ARCHIVE_REV" != "$TARGET_REV" ]; then
    echo "ERROR: schema revision mismatch. Deploy the code matching $ARCHIVE_REV first." >&2
    exit 1
fi

if [ "$DRY" = true ]; then echo; echo "--dry-run: resolved everything, changed nothing."; exit 0; fi

# --- Restore -----------------------------------------------------------------
echo "==> [1/3] Recreating $DB_NAME"
psql "$ADMIN_URL" -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='$DB_NAME' and pid <> pg_backend_pid();" >/dev/null
psql "$ADMIN_URL" -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null
psql "$ADMIN_URL" -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null

echo "==> [2/3] pg_restore"
pg_restore --no-owner --no-acl -d "$DB_URL" "$WORK/dump.tar" 2>&1 | tail -3 || true
echo "    tables=$(psql "$DB_URL" -tAc 'select count(*) from pg_stat_user_tables')" \
     "rows=$(psql "$DB_URL" -tAc 'select coalesce(sum(n_live_tup),0) from pg_stat_user_tables')"

echo "==> [3/3] Files"
if [ -d "$FILES_DIR" ]; then
    for d in uploads static; do
        if [ -d "$FILES_DIR/$d" ]; then
            mkdir -p "$RUN_DIR/data/$d"
            rsync -a --delete --exclude='.keep' "$FILES_DIR/$d/" "$RUN_DIR/data/$d/"
            echo "    $d: $(find "$RUN_DIR/data/$d" -type f | wc -l) files"
        fi
    done
else
    echo "    no files/ beside the archive — database only, media left as it was"
fi

echo "==> done. Restart the stack so it picks the restored data up:"
echo "    ./background_server.sh $CONF stop && ./background_server.sh $CONF start"
