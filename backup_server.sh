#!/usr/bin/env bash
# backup_server — point-in-time backup of a native run: its database, its
# uploaded media and its static tree. Usage mirrors the other scripts:
#   ./backup_server.sh sample.conf [port=… db_port=…] [--out DIR] [--name NAME]
#
# Runs where the server is. It only reads — the stack keeps serving throughout.
#
# Output (default --out is backup/ beside this script):
#   <out>/<name>-<UTC stamp>.tar.gz   pg_dump -Ft --no-owner --no-privileges, gzipped
#   <out>/files/uploads/              verbatim copy
#   <out>/files/static/               verbatim copy
#   <out>/MANIFEST.txt                source, schema revision, row counts, sizes
#
# That is the layout restore_server.sh reads, and the same one
# server_hosting_scripts/restore-backup.sh reads for Docker deployments — an
# archive taken here restores there and vice versa. The dump is tar format
# gzipped rather than custom format precisely for that: restore does
# `gzip -dc` into a tar and hands it to pg_restore.
#
# Getting the result to a backup host is a separate job. Nothing here pushes.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib_conf.sh"

OUT=""; ARCHIVE_NAME=""
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out)     shift; OUT="$1" ;;
        --out=*)   OUT="${1#--out=}" ;;
        --name)    shift; ARCHIVE_NAME="$1" ;;
        --name=*)  ARCHIVE_NAME="${1#--name=}" ;;
        *)         args+=("$1") ;;
    esac
    shift
done
conf_parse_args "${args[@]}"     # CONF, NAME, PORT, DB_PORT, RUN_DIR

OUT="${OUT:-$HERE/backup}"
# The conf's basename, so an archive says which stack it came from.
[ -n "$ARCHIVE_NAME" ] || ARCHIVE_NAME="$(basename "${CONF%.conf}")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DB_NAME="$(ini_get server db_name "$CONF")"; DB_NAME="${DB_NAME:-myclub}"
DB_USER="$(ini_get server db_user "$CONF")"; DB_USER="${DB_USER:-myclub}"
DB_URL="postgresql://$DB_USER@localhost:$DB_PORT/$DB_NAME"

echo "==> backup_server  $NAME"
echo "    database: $DB_NAME on 127.0.0.1:$DB_PORT"
echo "    out:      $OUT"

command -v pg_dump >/dev/null || { echo "ERROR: pg_dump not on PATH." >&2; exit 1; }
psql "$DB_URL" -tAc "select 1" >/dev/null 2>&1 \
    || { echo "ERROR: cannot reach $DB_URL — is the stack running?" >&2; exit 1; }

mkdir -p "$OUT/files"
ARCHIVE="$OUT/$ARCHIVE_NAME-$STAMP.tar.gz"

echo "==> [1/3] Dumping the database"
pg_dump "$DB_URL" -Ft --no-owner --no-privileges | gzip > "$ARCHIVE"
# A truncated dump is worse than none: it looks like a backup and restores to
# nothing. Prove it reads back before calling it done. `gzip -t` rather than
# piping into head: under pipefail, head exiting early sends gzip SIGPIPE and
# the check fails on a perfectly good archive.
gzip -t "$ARCHIVE" 2>/dev/null \
    || { echo "ERROR: $ARCHIVE is not a valid gzip archive." >&2; rm -f "$ARCHIVE"; exit 1; }
pg_restore --list "$ARCHIVE" >/dev/null 2>&1 || {
    # pg_restore reads gzipped tar directly; if it cannot, the dump is unusable.
    gzip -dc "$ARCHIVE" > "$ARCHIVE.tmp" && pg_restore --list "$ARCHIVE.tmp" >/dev/null 2>&1 \
        || { echo "ERROR: $ARCHIVE is not a restorable pg_dump archive." >&2; rm -f "$ARCHIVE" "$ARCHIVE.tmp"; exit 1; }
    rm -f "$ARCHIVE.tmp"
}
echo "    $(basename "$ARCHIVE")  $(du -h "$ARCHIVE" | cut -f1)"

echo "==> [2/3] Copying uploads and static, verbatim"
for d in uploads static; do
    if [ -d "$RUN_DIR/data/$d" ]; then
        mkdir -p "$OUT/files/$d"
        rsync -a --delete "$RUN_DIR/data/$d/" "$OUT/files/$d/"
        # _pending stages a video for the conversion worker: work in progress,
        # not data, and the server recreates it when it needs it.
        rm -rf "$OUT/files/$d/media/_pending"
        # An empty tree is a fact worth keeping — it says the directory was
        # backed up and had nothing in it, rather than being overlooked. The
        # .keep also survives a `find -type d -empty -delete` sweep.
        find "$OUT/files/$d" -type d -empty -exec touch {}/.keep \;
        echo "    $d: $(find "$OUT/files/$d" -type f ! -name .keep | wc -l) files, $(du -sh "$OUT/files/$d" | cut -f1)"
    fi
done

echo "==> [3/3] Manifest"
REV="$(psql "$DB_URL" -tAc "select version_num from alembic_version" 2>/dev/null || echo unknown)"
{
    echo "$ARCHIVE_NAME backup"
    echo
    echo "Taken   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Stamp   : $STAMP"
    echo "Source  : native_deploy run \"$NAME\" on $(hostname)"
    echo "          server 127.0.0.1:$PORT, postgres 127.0.0.1:$DB_PORT, db \"$DB_NAME\""
    echo "          $RUN_DIR"
    echo "Schema  : alembic $REV"
    echo
    echo "Contents"
    echo "  $(basename "$ARCHIVE")  $(du -h "$ARCHIVE" | cut -f1)  pg_dump -Ft --no-owner --no-privileges, gzipped"
    for d in uploads static; do
        [ -d "$OUT/files/$d" ] && printf '  files/%-9s %6s  %s files\n' \
            "$d/" "$(du -sh "$OUT/files/$d" | cut -f1)" "$(find "$OUT/files/$d" -type f ! -name .keep | wc -l)"
    done
    echo
    echo "Row counts at capture"
    psql "$DB_URL" -tAc "select '  ' || relname || '=' || n_live_tup from pg_stat_user_tables where n_live_tup > 0 order by relname" 2>/dev/null || true
    echo
    echo "To restore"
    echo "  Copy this directory's contents into the target's backup/ directory,"
    echo "  then run, on the target:"
    echo "      ./restore_server.sh <conf> $STAMP        # native"
    echo "      just restore-backup <env> $STAMP         # docker deployment"
    echo
    echo "  Uploads are ciphertext under the SOURCE environment's encryption_key."
    echo "  The target's key must match, or media will not decrypt."
} > "$OUT/MANIFEST.txt"

echo "==> done"
echo "    $OUT"
